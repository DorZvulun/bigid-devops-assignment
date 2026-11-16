#!/usr/bin/env bash
# Trace one request through every local network hop and print the source address each hop sees.
# Needs a running cluster (make cluster-create) with the app deployed (make deploy).
set -euo pipefail

CLUSTER=${CLUSTER:-bigid}
URL=${SMOKE_URL:-http://localhost:8080}
NETSHOOT=${NETSHOOT:-nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70}
# Only the first packet of each TCP connection (SYN without ACK).
FILTER='tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn'

lb=k3d-$CLUSTER-serverlb
nodes=$(docker ps --filter "label=k3d.cluster=$CLUSTER" --format '{{.Names}} {{.Label "k3d.role"}}' |
  awk '$2 == "server" || $2 == "agent" { print $1 }')
[ -n "$nodes" ] || { echo "trace-hops: cluster $CLUSTER not running (make cluster-create deploy)" >&2; exit 1; }

cleanup() { for c in $lb $nodes; do docker rm -f "trace-$c" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

# One tcpdump per container, sharing that container's network namespace.
for c in $lb $nodes; do
  docker run -d --rm --name "trace-$c" --net "container:$c" --cap-add NET_ADMIN --cap-add NET_RAW \
    "$NETSHOOT" tcpdump -lnni any "$FILTER" >/dev/null
done
for c in $lb $nodes; do
  for _ in $(seq 40); do docker logs "trace-$c" 2>&1 | grep -q 'listening on' && break; sleep 0.25; done
done

answer=$(curl -fsS "$URL/")
sleep 1
packets() { docker logs "trace-$1" 2>/dev/null; } # stdout only: one line per captured SYN

# tcpdump line: TIME IFACE DIR IP SRC.PORT > DST.PORT: Flags [S], seq N, ...
addr() { echo "${1%.*}"; }                                      # 10.42.0.1.49896 -> 10.42.0.1
hostport() { local a=${1%:}; echo "${a%.*}:${a##*.}"; }        # 10.42.0.6.8080: -> 10.42.0.6:8080
read -r _ _ _ _ client _ lb_in _ < <(packets "$lb" | awk '$3 == "In" && $7 ~ /\.80:$/' | head -1) || true
read -r _ _ _ _ lb_src _ node_dst _ _ _ tcp_seq _ < <(packets "$lb" | awk '$3 == "Out" && $7 ~ /\.80:$/' | head -1) || true
[ -n "${tcp_seq:-}" ] || { echo "trace-hops: no request captured at $lb" >&2; exit 1; }

echo "Request: curl $URL/  ->  $answer"
echo
printf '%-44s %s\n' "1. Docker port forward -> k3d load balancer" "$(addr "$client") -> $(hostport "$lb_in")"
printf '%-44s %s   (new TCP connection, seq %s)\n' "2. load balancer (nginx) -> node" "$(addr "$lb_src") -> $(hostport "$node_dst")" "${tcp_seq%,}"

# Same seq on the nodes = same connection after NAT. cni0/flannel.1 lines show the rewritten source.
hops=$(for n in $nodes; do
  packets "$n" | awk -v s="$tcp_seq" -v n="$n" '$11 == s && ($2 == "cni0" || $2 == "flannel.1") { print $1, n, $2, $3, $5, $7 }'
done | sort)
[ -n "$hops" ] || { echo "trace-hops: request not seen on any node" >&2; exit 1; }
i=3
last=""
while read -r _ node iface dir src dst; do
  note="same connection, forwarded"
  [ "$i" = 3 ] && note="same seq, source rewritten: SNAT"
  printf '%-44s %s   (%s)\n' "$i. ${node#k3d-} $iface $dir" "$(addr "$src") -> $(hostport "$dst")" "$note"
  last=$(addr "$src")
  i=$((i + 1))
done <<<"$hops"

echo
echo "Node addresses (cni0 = pod bridge gateway, flannel.1 = cross-node overlay):"
for n in $nodes; do
  printf '  %-20s %s\n' "${n#k3d-}" "$(docker run --rm --net "container:$n" "$NETSHOOT" ip -4 -br addr |
    awk '$1 == "cni0" || $1 == "flannel.1" { printf "%s %s  ", $1, $3 }')"
done

echo
if [[ $answer == *"\"$last\""* ]]; then
  echo "OK: the app answered $last, the source address of the last hop."
else
  echo "trace-hops: app answered $answer, expected $last" >&2
  exit 1
fi
