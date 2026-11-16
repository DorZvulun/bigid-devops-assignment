# whatsmyip

A tiny Flask app that returns the client's originating IP, shipped through a full CI pipeline into a local k3d cluster.

| Endpoint | Returns |
|---|---|
| `GET /` | Client IP: the left-most `X-Forwarded-For` entry, else the socket peer address |
| `GET /health` | 200 while the process is up (liveness) |
| `GET /ready` | 200 when ready to serve (readiness) |

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

Locally, `/` without an `X-Forwarded-For` header returns a cluster-internal address such as `10.42.0.1`, not your IP. `make trace-hops` shows why. See [Limitations](README-EXTENDED.md#local-requests-show-a-cluster-internal-ip).

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
| `trace-hops` | Capture one request at every network hop and print the source address each hop sees |
| `cluster-delete` | Delete the cluster, Terraform state and kubeconfig |
| `secrets` | Set the optional `ANTHROPIC_API_KEY` GitHub secret from a hidden prompt (run it in a terminal) |

## How CI works

Workflow: `.github/workflows/ci.yml`. Triggers: push to `main`, `pull_request`, `workflow_dispatch`. Every job calls the same `make` targets used locally.

| Job | Needs | What it does |
|---|---|---|
| `lint` | | `make venv lint` |
| `test` | lint | `make venv test` (fails the run on a test failure) |
| `build` | test | `make build`, saves the image as a run artifact |
| `scan` | build | Trivy gate, SARIF upload, SBOM artifact (see [Trivy](README-EXTENDED.md#image-vulnerability-scan-trivy)) |
| `push` | scan | `docker push` to GHCR |
| `helm-lint` | push | `make helm-lint` |
| `deploy` | helm-lint | Creates a k3d cluster on the runner, `make deploy` (from GHCR), then `make smoke` in the same job, because the cluster disappears when the job ends |
| `ai-diagnose` | all, `if: failure()` | Sends the failed jobs' logs to Claude, posts the diagnosis to the run summary and the PR. Skips without `ANTHROPIC_API_KEY`; never fails |
| `notify` | all, `if: always()` | Sets commit status `ci/pipeline` and writes a job summary table |

- **Image tag = commit SHA.** On a pull request it is the PR head commit, not the synthetic merge commit. `latest` is never used.
- **Concurrency.** One group per ref; a newer run cancels the superseded one. Every job has `timeout-minutes`.
- **Least privilege.** The workflow default is `contents: read`. Only `scan` gets `security-events: write`, `push` gets `packages: write`, `ai-diagnose` gets `actions: read` and `pull-requests: write`, and `notify` gets `statuses: write`.
- **Supply chain.** Third-party actions are pinned by full commit SHA. Tool binaries (Trivy, k3d, Helm, Terraform, uv) are pinned by version and verified against a sha256 before use, so a tampered release or a moved tag cannot silently run in the pipeline.
- **AI failure diagnosis.** On a failed run, an AI step diagnoses the failure ([details](README-EXTENDED.md#ai-failure-diagnosis)). Failed run where it worked: [run 43920128766](https://github.com/DorZvulun/bigid-devops-assignment/actions/runs/43920128766) (demo PR #1, `/health` returns 500), and the resulting [PR comment](https://github.com/DorZvulun/bigid-devops-assignment/pull/1#issuecomment-6924338410).
- **Notification.** Commit status `ci/pipeline` (success or failure) plus a job summary. No third-party apps.

## Where the image is published

`ghcr.io/dorzvulun/whatsmyip:<commit sha>`. The package is public, so `docker pull` works without login.

## More

- [README-EXTENDED.md](README-EXTENDED.md): deploy (Terraform), secrets, Trivy scan and SBOM, AI failure diagnosis, networking, security, reliability, limitations
- [docs/explainer.html](docs/explainer.html): step-by-step explainer (run it, request path, CI, troubleshooting)
- [docs/architecture.html](docs/architecture.html): architecture diagram (CI flow and runtime topology)

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
scripts/              ai_diagnose.py (CI ai-diagnose job), trace_hops.sh (make trace-hops)
docs/                 explainer.html, architecture.html
README-EXTENDED.md    everything not in this README
```
