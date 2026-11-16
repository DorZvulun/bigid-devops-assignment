# whatsmyip: extended documentation

Short version: [README.md](README.md). Diagram: [docs/architecture.html](docs/architecture.html). Explainer: [docs/explainer.html](docs/explainer.html).

Contents: [Deploy](#deploy) · [Secrets](#secrets) · [Image vulnerability scan (Trivy)](#image-vulnerability-scan-trivy) · [AI failure diagnosis](#ai-failure-diagnosis) · [Networking: why Traefik is disabled](#networking-why-traefik-is-disabled) · [Security](#security) · [Reliability](#reliability) · [Limitations](#limitations)

## Deploy

Deploying is a Helm release driven by Terraform (`infra/`):

- `kubernetes_namespace_v1` creates the `staging` namespace.
- `helm_release` installs `charts/whatsmyip` with the image repository and the commit SHA as tag. It uses `atomic = true`, `wait = true` and `timeout = 180`, so a failed rollout rolls back.
- Terraform does **not** create the cluster. The k3d Terraform provider crash-looped k3s in a spike, so `make cluster-create` uses the k3d CLI (`k3d-config.yaml`: 1 server, 1 agent, port `8080:80`, Traefik off).

## Secrets

| Secret | Purpose | Required | Set with |
|---|---|---|---|
| `GITHUB_TOKEN` | GHCR push, commit status, SARIF upload | Automatic, per run | Nothing to set |
| `ANTHROPIC_API_KEY` | AI failure diagnosis (added in the final stage) | No. Without it the AI step is skipped and the pipeline is unaffected | `make secrets` (runs `gh secret set ANTHROPIC_API_KEY`, hidden prompt; the value never lands in a file) |

Nothing secret is in the repo, chart, Makefile or workflow. `.env.example` lists variable names only and `.env` is not tracked. App secrets reach the pod through the chart's `existingSecret`, a pre-existing Kubernetes Secret injected with `envFrom`. The chart never creates secrets. For production, use sealed-secrets or External Secrets Operator.

## Image vulnerability scan (Trivy)

[Trivy](https://trivy.dev) is a command-line scanner that runs **next to** the image, never inside it. It reads the image layers from Docker, lists every OS package and Python package, and checks them against a CVE database. Kubernetes is not involved.

| Where | When | How |
|---|---|---|
| Laptop | `make scan` after `make build` | `brew install trivy` |
| CI runner (`scan` job) | after `build`, **before** `push` | Pinned Trivy binary, checksum-verified; runs the same `make scan` |

### What the `scan` job does

1. **Load.** `docker load` imports the image that the `build` job saved as an artifact.
2. **Gate.** `trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 whatsmyip:<sha>` prints a CVE table to the log.
   - It exits `1` if any HIGH or CRITICAL CVE with a fix exists. The job fails, so `push` never runs and a vulnerable image never reaches GHCR.
   - `--ignore-unfixed` skips CVEs with no patch yet. Nothing can be done about those.
3. **Annotate.** The same scan runs with `--format sarif`, and the result is uploaded to the repo's **Security → Code scanning** tab. Findings are visible there without reading logs. This step and the SBOM step run with `if: always()`, so they still upload when the gate in step 2 failed. That is the case where the findings matter most.
4. **SBOM.** `trivy image --format cyclonedx` writes `sbom.cdx.json`, a list of every package in the image. It is saved as a run artifact.
5. **Cache.** Trivy downloads its CVE database (~60 MB) on each run. `actions/cache` keeps it, so later runs are faster.

The image is distroless with only Flask and gunicorn installed, so the expected result is zero or near-zero findings. If one appears, the fix is usually to bump the base image or a pinned dependency.


### Scan and SBOM output

| What | Where |
|---|---|
| CVE table | `scan` job log |
| SARIF findings | **Security → Code scanning**, category `trivy` |
| SBOM | Run artifact `sbom`, file `sbom.cdx.json` (CycloneDX) |

## AI failure diagnosis

The `ai-diagnose` job runs only when a job before it failed (`if: failure()`). It runs `scripts/ai_diagnose.py`:

1. Lists the run's jobs through the GitHub REST API and downloads the log of each failed job (last 300 lines). The run is still in progress, so `gh run view --log-failed` cannot be used.
2. Redacts token-like strings (GitHub and Anthropic tokens, AWS key IDs, JWTs, bearer tokens, `password=`/`token=` values) and keeps at most the last 60,000 characters.
3. Sends the logs to Claude (`claude-opus-5-5`, override with `ANTHROPIC_MODEL`) through the official `anthropic` Python SDK. The system prompt marks the logs as untrusted data. Server-side fallbacks are on, so a safety refusal is retried on a fallback model.
4. Writes the answer (failing step, root cause, suggested fix) to the job summary and, on a PR, posts it as a PR comment. `@` mentions are neutralized so the text cannot ping anyone. The output is text only and never executed.

It never breaks the pipeline:

- No `ANTHROPIC_API_KEY` (not set, or a fork PR): the job writes "Skipped" to the summary and passes.
- Any error (GitHub API, Anthropic API, refusal): it prints a `::warning::` and passes.
- `notify` waits for it, but does not count it toward the `ci/pipeline` status.

Permissions: `contents: read`, `actions: read` (logs), `pull-requests: write` (comment). The SDK is hash-locked in `requirements-dev.txt`, installed with the same `make venv` as the other jobs.

Link to the failed run where the diagnosis worked: [run 43920128766](https://github.com/DorZvulun/bigid-devops-assignment/actions/runs/43920128766). Demo PR [#1](https://github.com/DorZvulun/bigid-devops-assignment/pull/1) breaks `/health` on purpose; the diagnosis named the failing test `test_probes[/health-ok]`, quoted the assertion and suggested the fix. See the [PR comment](https://github.com/DorZvulun/bigid-devops-assignment/pull/1#issuecomment-6924338410). Attempt 1 of the same run, before the key was set, shows the "Skipped" path.

## Networking: why Traefik is disabled

k3d ships the Traefik ingress controller by default. This project turns it off and exposes the app through a `LoadBalancer` Service instead, served by k3s's built-in ServiceLB. The PDF lists the Ingress as optional, and the chart still has one (`ingress.enabled: false` by default).

With Traefik in the path, the app could not see the client's IP:

- By default, Traefik does not trust `X-Forwarded-*` headers that come from untrusted IPs. It drops them and sets its own ([forwarded headers](https://doc.traefik.io/traefik/routing/entrypoints/#forwarded-headers)).
- The k3d load balancer forwards plain TCP, so the only peer Traefik sees is that load balancer's internal Docker IP.
- So `/` would return an internal cluster IP instead of the client's IP.

ServiceLB forwards connections without touching HTTP headers. The client's `X-Forwarded-For` reaches the app unchanged.

## Security
### Implemented

- **Pod hardening:** non-root (uid 65532), `readOnlyRootFilesystem`, all capabilities dropped, `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`.
- **Image:** multi-stage build into distroless Python `nonroot`. No shell in the runtime image. Base images are pinned by digest and dependencies by hash (`--require-hashes`).
- **CI:** least-privilege permissions per job, actions pinned by SHA, checksum-verified tool binaries.
- **Secrets:** none in code; supplied at run time (see [Secrets](#secrets)).
- **Kubeconfig** lives outside the repo (`~/.kube/big-id-k3d-config.yaml`, mode 600).

### Public repo and image: what changes if the repo is private

This repo and its GHCR image are **public**, so the cluster pulls the image without credentials.

If the repo were private:

- **Image pulls need credentials.** The GHCR package would be private too, so the cluster would pull with an **image pull secret**. The deploy job would create it from the job's own token, with no stored secret, and the chart would reference it through an `imagePullSecrets` value:

  ```bash
  kubectl create secret docker-registry ghcr -n staging \
    --docker-server=ghcr.io --docker-username="$GITHUB_ACTOR" --docker-password="$GITHUB_TOKEN"
  ```

- **Scan results have no Security tab.** Uploading Trivy's SARIF results to **Security → Code scanning** on a private repo requires a paid GitHub subscription (GitHub Advanced Security / Code Security). The SARIF file would stay available as a run artifact only.

### Security hardening (not implemented)

Documented only:

- **`X-Forwarded-For` spoofing.** Clients can forge the header. Trust only N proxy hops (Werkzeug `ProxyFix(x_for=N)`) or restrict which proxy IPs are trusted.
- **Fork PRs.** Give fork code no secrets, push or deploy. Never combine `pull_request_target` with a checkout of PR code.
- **AI step.** Logs are untrusted input (prompt injection). Redact token-like strings, cap the size, post the output as text only and never execute it.
- **Secret managers.** Beyond plain Kubernetes Secrets: sealed-secrets or External Secrets Operator.

## Reliability

- **Probes:** liveness `/health`, readiness `/ready`, startup `/health`. All configurable in `values.yaml`, along with resource requests and limits.
- **2 replicas.**
- **Atomic deploys:** the Terraform `helm_release` uses `atomic` and `wait`, so a failed rollout rolls back automatically.
- **Graceful shutdown:** gunicorn drains on SIGTERM (`terminationGracePeriodSeconds: 30`). Because the root filesystem is read-only, gunicorn runs with `--no-control-socket` and worker temp files in `/dev/shm`.
- **CI:** concurrency group per ref, `timeout-minutes` on every job.
- **Image tag = commit SHA**, never `latest`.

## Limitations

### One environment only (`staging`)

The brief asks for a deploy to `staging`, and multi-environment promotion is out of scope. The namespace is a variable (`make deploy NAMESPACE=<name>`, Terraform `var.namespace`), but setting it does **not** add a second environment:

- **One Terraform state.** `infra/terraform.tfstate` tracks a single namespace. Changing `NAMESPACE` makes Terraform destroy `staging` and create the new namespace in its place.
- **One port 80.** Every release creates a `LoadBalancer` Service on port 80. ServiceLB binds each node port once, so a second Service would stay `<pending>`.

To add environments: one Terraform workspace (or state file) per environment, a different `service.port` per environment (or an Ingress that routes by host), and a CI deploy job per environment.

### Local requests show a cluster-internal IP

Opening `http://localhost:8080` in a browser returns an address like `10.42.0.1`. That is a node's address (its pod bridge gateway, or its overlay address when the pod runs on the other node), not a pod and not the client. Each hop on the local path replaces the source address:

1. The browser connects to `127.0.0.1:8080`.
2. Docker Desktop forwards the port into its VM, so the source becomes the VM's gateway.
3. The k3d load balancer (nginx, plain TCP proxy) opens a new connection, so the source becomes its container IP.
4. ServiceLB and kube-proxy (`externalTrafficPolicy: Cluster`) apply SNAT, so the source becomes the node gateway.

Even with every hop preserved, the best result locally would be `127.0.0.1` or Docker's gateway: the browser and the server run on the same machine, so there is no public client IP to see.

#### Proof: `make trace-hops`

`make trace-hops` runs `tcpdump` (pinned `nicolaka/netshoot` image) inside the load balancer and node containers, sends one `curl`, and prints the source address at each hop. It follows the request by its TCP sequence number: a new number means a new connection (a proxy), and the same number with a new source means NAT. It exits 1 if the app's answer does not match the last hop. Measured on Docker Desktop for Mac:

| Hop | Seen by `tcpdump` | What it proves |
|---|---|---|
| Browser → Docker | `docker ps`: `0.0.0.0:8080->80/tcp` on `k3d-bigid-serverlb` | Docker publishes the load balancer's port 80 on the Mac |
| Docker Desktop → k3d load balancer | `192.168.65.1 → 172.26.0.5:80` | The client is already replaced by the Docker Desktop VM gateway |
| Load balancer (nginx) → node | `172.26.0.5 → 172.26.0.3:80`, **new** sequence number | nginx opens a new TCP connection from its own IP |
| Node → pod, same node | `10.42.0.1 → 10.42.0.6:8080` on `cni0`, **same** sequence number | kube-proxy SNAT: the source becomes the node's `cni0` gateway |
| Node → pod, other node | `10.42.0.0 → 10.42.1.3:8080` on `flannel.1`, then `cni0` | Same SNAT, but the source is the sending node's `flannel.1` address |
| App | `{"ip":"10.42.0.1"}` (or `10.42.1.1`, `10.42.0.0`, `10.42.1.0`) | The app reports exactly the last hop's source address |

The k3d load balancer picks a node per connection and the Service picks a pod, so repeated runs show all four node addresses.

The app itself is correct. In production it sits behind an internet-facing load balancer or ingress that sets `X-Forwarded-For`, and it returns the left-most entry. `make smoke` tests exactly that path by sending the header.
