# whatsmyip

A tiny Flask app that returns the client's originating IP, shipped through a full CI pipeline into a local k3d cluster.

| Endpoint | Returns |
|---|---|
| `GET /` | Client IP: the left-most `X-Forwarded-For` entry, else the socket peer address |
| `GET /health` | 200 while the process is up (liveness) |
| `GET /ready` | 200 when ready to serve (readiness) |

Contents: [Run locally](#run-locally) · [How CI works](#how-ci-works) · [Deploy](#deploy) · [Image](#where-the-image-is-published) · [Secrets](#secrets) · [Trivy](#image-vulnerability-scan-trivy) · [Scan and SBOM output](#scan-and-sbom-output) · [AI diagnosis](#ai-failure-diagnosis) · [Networking](#networking-why-traefik-is-disabled) · [Security](#security) · [Reliability](#reliability) · [Limitations](#limitations) · [Architecture](#architecture) · [Layout](#repo-layout)

## Run locally

Prerequisites:

| Tool | Version |
|---|---|
| Docker | any recent |
| k3d | v5.9.0 |
| Terraform | ~> 1.17 |
| Helm | v4 (only for `helm lint`) |
| uv | 0.11.28 (creates the Python 3.13 venv) |
| Trivy | 0.76.2 |
| GNU make | macOS `/usr/bin/make` 3.81 works |

```bash
make all             # venv lint test build scan cluster-create deploy smoke
make cluster-delete  # tear down the cluster, Terraform state and kubeconfig
```

The app is then on `http://localhost:8080`. The cluster's kubeconfig is `~/.kube/big-id-k3d-config.yaml`; k3d never touches your default kubeconfig:

```bash
KUBECONFIG=~/.kube/big-id-k3d-config.yaml kubectl -n staging get pods
```

Locally, `/` without an `X-Forwarded-For` header returns a cluster-internal address such as `10.42.0.1`, not your IP. See [Limitations](#local-requests-show-a-cluster-internal-ip).

| Target | Does |
|---|---|
| `venv` | Create `.venv` from the hashed `requirements-dev.txt` |
| `lint` | `ruff check` and `ruff format --check` |
| `test` | `pytest` |
| `run` | Run the app with gunicorn on port 8080, without Docker |
| `build` | `docker build`, tagged with the short commit SHA |
| `scan` / `scan-sarif` / `sbom` | Trivy gate, SARIF report, CycloneDX SBOM |
| `cluster-create` | Create the k3d cluster `bigid` and write its kubeconfig |
| `helm-lint` | `helm lint --strict charts/whatsmyip` |
| `deploy` | Import the image into k3d, then `terraform apply` |
| `smoke` | Check `/health`, `/ready`, and that `/` echoes a forwarded IP |
| `cluster-delete` | Delete the cluster, Terraform state and kubeconfig |

## How CI works

Workflow: `.github/workflows/ci.yml`. Triggers: push to `main`, `pull_request`, `workflow_dispatch`. Every job calls the same `make` targets used locally.

| Job | Needs | What it does |
|---|---|---|
| `lint` | | `make venv lint` |
| `test` | lint | `make venv test` (fails the run on a test failure) |
| `build` | test | `make build`, saves the image as a run artifact |
| `scan` | build | Trivy gate, SARIF upload, SBOM artifact (see [Trivy](#image-vulnerability-scan-trivy)) |
| `push` | scan | `docker push` to GHCR |
| `helm-lint` | push | `make helm-lint` |
| `deploy` | helm-lint | Creates a k3d cluster on the runner, `make deploy` (from GHCR), then `make smoke` in the same job, because the cluster disappears when the job ends |
| `notify` | all, `if: always()` | Sets commit status `ci/pipeline` and writes a job summary table |

- **Image tag = commit SHA.** On a pull request it is the PR head commit, not the synthetic merge commit. `latest` is never used.
- **Concurrency.** One group per ref; a newer run cancels the superseded one. Every job has `timeout-minutes`.
- **Least privilege.** The workflow default is `contents: read`. Only `scan` gets `security-events: write`, `push` gets `packages: write`, and `notify` gets `statuses: write`.
- **Supply chain.** Third-party actions are pinned by full commit SHA. Tool binaries (Trivy, k3d, Helm, Terraform, uv) are pinned by version and verified against a sha256 before use, so a tampered release or a moved tag cannot silently run in the pipeline.
- **Notification.** Commit status `ci/pipeline` (success or failure) plus a job summary. No third-party apps.

## Deploy

Deploying is a Helm release driven by Terraform (`infra/`):

- `kubernetes_namespace_v1` creates the `staging` namespace.
- `helm_release` installs `charts/whatsmyip` with the image repository and the commit SHA as tag. It uses `atomic = true`, `wait = true` and `timeout = 180`, so a failed rollout rolls back.
- Terraform does **not** create the cluster. The k3d Terraform provider crash-looped k3s in a spike, so `make cluster-create` uses the k3d CLI (`k3d-config.yaml`: 1 server, 1 agent, port `8080:80`, Traefik off).

## Where the image is published

`ghcr.io/dorzvulun/whatsmyip:<commit sha>`. The package is public, so `docker pull` works without login.

## Secrets

| Secret | Purpose | Required | Set with |
|---|---|---|---|
| `GITHUB_TOKEN` | GHCR push, commit status, SARIF upload | Automatic, per run | Nothing to set |
| `ANTHROPIC_API_KEY` | AI failure diagnosis (added in the final stage) | Yes, for the AI step | `make secrets` (runs `gh secret set ANTHROPIC_API_KEY`, hidden prompt; the value never lands in a file) |

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

A job that runs only when the pipeline fails. It sends the failed-job logs to the Anthropic API and posts the diagnosis as a PR comment or run summary. It needs the `ANTHROPIC_API_KEY` secret (see [Secrets](#secrets)). Added in the final stage.

Link to the failed run where the diagnosis worked: _added after the demo run_

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

Opening `http://localhost:8080` in a browser returns an address like `10.42.0.1`. That is the node's bridge gateway, not a pod and not the client. Each hop on the local path replaces the source address:

1. The browser connects to `127.0.0.1:8080`.
2. Docker Desktop forwards the port into its VM, so the source becomes the VM's gateway.
3. The k3d load balancer (nginx, plain TCP proxy) opens a new connection, so the source becomes its container IP.
4. ServiceLB and kube-proxy (`externalTrafficPolicy: Cluster`) apply SNAT, so the source becomes the node gateway.

Even with every hop preserved, the best result locally would be `127.0.0.1` or Docker's gateway: the browser and the server run on the same machine, so there is no public client IP to see.

The app itself is correct. In production it sits behind an internet-facing load balancer or ingress that sets `X-Forwarded-For`, and it returns the left-most entry. `make smoke` tests exactly that path by sending the header.

## Architecture

- Diagram (CI flow and runtime topology): [docs/architecture.html](docs/architecture.html)
- Step-by-step explainer (run it, request path, CI, troubleshooting): [docs/explainer.html](docs/explainer.html)

## Repo layout

```
Makefile              single entrypoint
app/                  Flask app and pinned requirements
tests/                pytest unit tests
Dockerfile            multi-stage, distroless runtime
charts/whatsmyip/     Helm chart
infra/                Terraform: staging namespace + helm_release
k3d-config.yaml       local cluster definition
.github/workflows/    ci.yml
```
