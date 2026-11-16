# PLAN.md — BigID DevOps Home Assignment

Rules and decisions live in `CLAUDE.md`. Checkboxes live in `TASKS.md`. This file covers **how** each stage is built, plus the gotchas to expect.

Names (decided):
- GitHub repo: `bigid-devops-assignment`
- App, chart and image: `whatsmyip`, published as `ghcr.io/<owner>/whatsmyip:<sha>`

---

## Architecture (one picture)

```
 developer ──git push / PR──▶ GitHub Actions (ci.yml)
                                │
   lint ─▶ test ─▶ build ─▶ scan ─▶ push ─▶ helm-lint ─▶ deploy+smoke ─▶ ai-diagnose (on failure) ─▶ notify (always)
                                │ push                                    │
                                ▼                                         ▼
                          ghcr.io/<owner>/whatsmyip:<sha>      LLM (Anthropic | GitHub Models)
                                │ pull                                    │
                                ▼                                         ▼
   k3d cluster (in runner / on laptop)                     PR comment + job summary
     client ─▶ k3d LB (:8080) ─▶ Service (LoadBalancer, ServiceLB) ─▶ Deployment (2 pods, ns: staging)
```

Run locally, the flow is the same: `make all` (venv lint test build scan cluster-create deploy smoke) builds the image and imports it into k3d instead of pulling it from GHCR.

---

## Stage 0: Bootstrap (≈20 min)

- Install the scanner: `brew install trivy`. Trivy produces the SBOM too, so Syft is not needed.
- `git init` in `big-id/` (done: commit `a6be1a3`).
- `.gitignore` covers `instructions/`, `.last_session_id`, `.env`, `.venv/`, `__pycache__/`, `*.tfstate*`, `.terraform/`, `sbom*.json` and `trivy*.sarif`.
- `.env.example` holds variable names only (`ANTHROPIC_API_KEY`, `LLM_PROVIDER`).
- `gh repo create bigid-devops-assignment --public --source . --push`.

## Stage 1: App + unit tests (≈1 h)

Python is pinned to **3.13** everywhere: `uv venv --python 3.13`, `uv pip compile --python-version 3.13`, `actions/setup-python` with `3.13` in CI, and the builder/runtime images in Stage 2.

Files:
- `app/whatsmyip.py`: Flask app (about 30 lines)
- `app/requirements.txt`: hash-locked runtime deps (`flask`, `gunicorn`), generated with `uv pip compile --python-version 3.13 --generate-hashes`
- `requirements-dev.txt`: hash-locked `pytest`, `ruff`
- Every install uses `pip install --require-hashes`.
- `pyproject.toml`: tool config only, no packaging. `[tool.pytest.ini_options] pythonpath = ["app", "scripts"]` lets the tests import `whatsmyip` and `ai_diagnose`. `[tool.ruff]` sets `target-version = "py313"`.
- `tests/test_app.py`

Behaviour:
- `GET /` returns `{"ip": "<client ip>"}`.
  - The IP is the left-most `X-Forwarded-For` entry, stripped of whitespace.
  - The fallback is `request.remote_addr`.
- `GET /health` returns `{"status": "ok"}` with 200. This is the liveness probe.
- `GET /ready` returns `{"status": "ready"}` with 200. This is the readiness probe.

Unit tests (sufficient, and test LOC ≤ app LOC):
- No `X-Forwarded-For` header → returns `remote_addr`.
- Single `X-Forwarded-For` value → returns it.
- Multi-hop `"a, b, c"` → returns `a`.
- Whitespace in the header is handled.
- `/health` and `/ready` return 200.

Make targets:
- `make venv` creates `.venv` and installs the dev deps.
- `make lint` runs `ruff check` and `ruff format --check`.
- `make test` runs `pytest`, which exits non-zero on failure.
- `make run` starts gunicorn on `:8080`.

## Stage 2: Container (≈45 min)

Multi-stage `Dockerfile`:
1. **builder** (`python:3.13-slim-trixie`, pinned by digest) runs `pip install --no-cache-dir --target /deps -r app/requirements.txt`.
2. **runtime** (`gcr.io/distroless/python3-debian13:nonroot`, pinned by digest; Debian 13 ships Python 3.13, confirm in task 2.1) copies `/deps` and `app/`, then sets `PYTHONPATH=/deps`.
   - Entrypoint: `python3 -m gunicorn -b 0.0.0.0:8080 --worker-tmp-dir /dev/shm whatsmyip:app`.

Gotchas:
- The builder's Python minor version **must equal** the distroless Python version. Compiled wheels such as `markupsafe` break if they differ. Check the distroless version first and pick the matching builder tag.
- `--worker-tmp-dir /dev/shm` is required because of `readOnlyRootFilesystem` (gunicorn's heartbeat files).
- `.dockerignore` keeps the build context small: everything except `app/`.

Make targets (the image is tagged with `GIT_SHA ?= $(shell git rev-parse --short HEAD)`):
- `make build` runs `docker build -t $(IMAGE):$(GIT_SHA) .`
- `make scan` runs `trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $(IMAGE):$(GIT_SHA)`.
- `make sbom` runs `trivy image --format cyclonedx --output sbom.cdx.json $(IMAGE):$(GIT_SHA)`.
- `make scan-sarif` runs the same scan as `make scan` with `--format sarif --output trivy.sarif` and no `--exit-code`. CI uploads it to the Security tab.

Done when: the image is ≤ ~80 MB (the distroless Python base alone is 72.7 MB), `make scan` passes, and `docker run` + `curl localhost:8080/health` returns 200.

## Stage 3: Helm chart + local k3d deploy (≈1.5 h)

`k3d-config.yaml`:
- Cluster `bigid`, 1 server + 1 agent.
- Traefik disabled: `--disable=traefik` on the servers, set via `options.k3s.extraArgs` with `nodeFilters: [server:*]`.
- Port `8080:80@loadbalancer`. It forwards to the chart's `LoadBalancer` Service through k3s's built-in ServiceLB.
- k3s version pinned.

`charts/whatsmyip/` holds `Chart.yaml`, `values.yaml`, `templates/{deployment,service,ingress,_helpers.tpl,NOTES.txt}`.

`values.yaml` exposes:
- `image.repository`, `image.tag`, `image.pullPolicy`
- `replicaCount: 2`
- `resources`: requests `50m`/`64Mi`, limits `200m`/`128Mi`
- `livenessProbe` → `/health`, `readinessProbe` → `/ready`, `startupProbe` → `/health`. Every timing field is overridable.
- `podSecurityContext` and `securityContext`:
  - `runAsNonRoot`, `readOnlyRootFilesystem`
  - drop `ALL` capabilities, `allowPrivilegeEscalation: false`
  - `seccompProfile: RuntimeDefault`
- `service.type` (default `LoadBalancer`), `service.port: 80`
- `ingress.enabled` (default `false`), `ingress.className: ""`, `ingress.host: ""` (no host means match any). Kept so the chart works on clusters that have an ingress controller.
- `existingSecret: ""`. When set, the Deployment adds `envFrom: secretRef`. Nothing secret lives in the chart.
- `env: {}` for plain non-secret env vars.

Make targets:
- `make cluster-create` runs `k3d cluster create --config k3d-config.yaml`. It is idempotent.
- `make helm-lint` runs `helm lint charts/whatsmyip`.
- `make deploy` (Terraform, see Stage 6):
  - Runs `terraform -chdir=infra init -input=false` then `terraform -chdir=infra apply -auto-approve -input=false -var image_repository=$(IMAGE) -var image_tag=$(GIT_SHA)`.
  - Locally it runs `k3d image import` first, using `IMAGE_SOURCE=local|registry`.
- `make smoke` (base URL is `SMOKE_URL ?= http://localhost:8080`, so another cluster or port can override it):
  - `curl -fsS $(SMOKE_URL)/health` and `/ready`.
  - `curl -fsS -H 'X-Forwarded-For: 203.0.113.7' $(SMOKE_URL)/` and assert that `203.0.113.7` is in the body.
  - Retries for up to 30 s.
- `make cluster-delete` runs `k3d cluster delete bigid`.
- `make all` runs `venv lint test build scan cluster-create deploy smoke`. It is the one command for a fresh computer.

Why Traefik is disabled (the README explains this too):
- By default, Traefik does not trust `X-Forwarded-*` headers from untrusted IPs. It replaces them with its own.
- The k3d load balancer forwards plain TCP, so Traefik would see the load balancer's container IP as the client.
- So with Traefik in the path, `/` would return that internal Docker IP, not the client's IP, and the smoke test's XFF check would fail.
- ServiceLB forwards connections without touching HTTP headers, so the client's `X-Forwarded-For` reaches the app unchanged. This is also exactly the spoofing risk the README explains.

Done when: `make cluster-create build deploy smoke` passes from a clean laptop state, and `helm lint` is clean.

## Stage 4: CI pipeline (≈2–3 h incl. debugging)

`.github/workflows/ci.yml`:
- Triggers: `push` to `main` only, `pull_request`, `workflow_dispatch`. With `push` on every branch, each PR commit would run twice (two refs, so concurrency does not merge them), and both runs would push and deploy.
- `concurrency: ci-${{ github.ref }}` with `cancel-in-progress: true`.
- Top-level `permissions: contents: read`.
- `timeout-minutes` on every job.
- Actions pinned by commit SHA. Trivy is installed by pinned version with checksum verification, not via a mutable tag. Supply-chain attacks on CI actions are real; the README explains why.

| # | Job | Does | Needs | Extra permissions |
|---|---|---|---|---|
| 1 | `lint` | `make lint` | – | – |
| 2 | `test` | `make test` | lint | – |
| 3 | `build` | `make build`, `docker save` → artifact | test | – |
| 4 | `scan` | load the image, SARIF + SBOM steps with `if: always()`, then the `make scan` gate. Upload SARIF + SBOM artifact | build | `security-events: write` |
| 5 | `push` | YAML only (no make target): download the image artifact, `docker load`, log in to GHCR, push `:<sha>` | scan | `packages: write` |
| 6 | `helm-lint` | `make helm-lint` | push | – |
| 7 | `deploy` | install k3d + Terraform (pinned, checksum-verified), `make cluster-create`, `make deploy IMAGE_SOURCE=registry`, `make smoke` | helm-lint | – |
| 8 | `ai-diagnose` | `if: failure()`: see Stage 5 | jobs 1–7 | `actions: read`, `pull-requests: write`, `models: read` |
| 9 | `notify` | `if: always()`: commit status `ci/pipeline` on the head SHA + job summary table. On failure the status `target_url` points at the run summary, which holds the AI diagnosis | all | `statuses: write` |

Notes:
- The jobs run strictly in the PDF's order, so the GitHub UI graph shows the required flow.
- Deploy and smoke share one job because the cluster disappears when the job ends.
- Image tag = the commit the image is built from: `SHA = github.event.pull_request.head.sha || github.sha`, full length. Locally the short SHA is fine.
  - On `pull_request`, `github.sha` is GitHub's synthetic test-merge commit (`refs/pull/N/merge`). It is on no branch. So PR jobs check out `ref: <head sha>` and tag with it. The image then matches the PR's last commit exactly.
  - On `push` to `main`, `github.sha` is the pushed commit (the merge/squash result), so main gets its own image.
  - `notify` sets the commit status on the same SHA.
- **One-time manual step:** after the first push, set the GHCR package visibility to **public** in the GitHub UI. The cluster can then pull without an `imagePullSecret`. The README documents this.

`make secrets` (the user runs it once, values never land in a file):
- `gh secret set ANTHROPIC_API_KEY`. This opens a hidden prompt and is optional, because `auto` falls back to GitHub Models.
- `gh variable set LLM_PROVIDER --body auto`.

Done when: a push to `main` turns every job green, the image is visible on GHCR, and SARIF shows up in the Security tab.

## Stage 5: AI failure diagnosis (≈1.5 h), done last

Human decision 2026-11-16: this stage runs after Stage 8. The provider is Anthropic only (GitHub Models was retired on 2026-07-30), so the `LLM_PROVIDER` switch and the `github` path in agent E's script are removed in this stage. Agent E's script (branch `worktree-agent-a5ade5687d7763460`) is kept for this stage. The `ai-diagnose` CI job and `make secrets` are added here too.

`scripts/ai_diagnose.py` uses the stdlib only (`urllib`), so it adds no dependencies:
1. Lists the jobs of the current run via the GitHub API (`GITHUB_TOKEN`). It keeps the jobs whose `conclusion == failure`.
   - `gh run view --log-failed` can't be used: it only works once the whole run has finished.
2. Downloads each failed job's log and keeps the last ~300 lines.
3. Picks the provider from `LLM_PROVIDER`:
   - `anthropic`: Anthropic Messages API.
   - `github`: GitHub Models chat completions.
   - `auto`: Anthropic if `ANTHROPIC_API_KEY` is set, otherwise GitHub Models.
   - Model IDs are configurable via env, and the defaults are checked when implementing.
4. Prompt: "Return: failing step, likely root cause, suggested fix. Max 15 lines, markdown."
5. Writes the result to `$GITHUB_STEP_SUMMARY` and prints it.
   - On a PR it also posts a PR comment with `gh pr comment`.

Tests: one small test for provider selection (`auto` with/without a key, explicit values).

Demo: open PR `demo/ai-diagnosis` with a deliberate bug (`/health` returns 500).
- The unit test fails, AI diagnoses it, and the PR comment appears.
- Keep the PR open and link the failed run and the comment in the README. The PDF requires this link.

Done when: the demo PR has an AI comment that names the failing test, and the run link has been copied into the README.

## Stage 6: Terraform deploy (namespace + app)

Decided 2026-11-16: Terraform replaces the `helm upgrade` CLI deploy. It does **not** create the cluster: the spike showed the only k3d provider (`pvotal-tech/k3d` 0.0.7) crash-looping k3s, so `make cluster-create` keeps using the k3d CLI.

`infra/`:
- `versions.tf`: `required_version` pinned to the local Terraform (1.17.x). Providers `hashicorp/kubernetes` and `hashicorp/helm` pinned to exact versions. `.terraform.lock.hcl` is committed.
- Providers read `~/.kube/config` with context `var.kube_context` (default `k3d-bigid`).
- `kubernetes_namespace` `staging`. Use the non-deprecated resource name of the pinned provider version (`kubernetes_namespace` or `kubernetes_namespace_v1`).
- `helm_release` `whatsmyip`:
  - `chart = "../charts/whatsmyip"` and `namespace` taken from the namespace resource, so the namespace always comes first.
  - `atomic = true`, `wait = true`, `timeout = 180`.
  - Sets `image.repository` and `image.tag` from `var.image_repository` and `var.image_tag`.
- Variables: `image_repository`, `image_tag` (required, no default), `kube_context`, `namespace` (default `staging`).

Gotchas:
- **State is local and gitignored.** A deleted cluster leaves stale state, and the next apply would fail. So `make cluster-delete` also removes `infra/terraform.tfstate*`. In CI, the state disappears with the runner, together with the cluster.
- The kubernetes provider needs a reachable cluster at plan time. `make cluster-create` always runs before `make deploy`.
- `helm_release` with a local chart path only sees changes through its values or chart version. Every commit changes `image.tag`, so each deploy is a real upgrade. A chart-only change on the same SHA needs a chart `version` bump.
- The PDF says "deploy using Helm". `helm_release` is Helm, driven by Terraform. The README says so.

## Stage 7: Docs (≈1.5 h)

- `README.md` covers every item in CLAUDE.md's "README must cover" list.
- An ADHD-friendly HTML explainer covers the architecture and how to run the project. It is written with the `i-have-adhd` skill and links to the diagram from Stage 8.

## Stage 8: Architecture diagram (≈30 min)

- Generate the diagram with `/archify` from the real repo (CI flow plus runtime topology).
- Link it from the README and the HTML.

---

## Total estimate

- Core (Stages 0–5): ≈ 7–8 h
- Bonus + docs (Stages 6–8): ≈ 3 h

## Top risks

1. **Distroless/builder Python version mismatch** breaks the container at run time. Both are pinned to 3.13; confirm the distroless version in task 2.1.
2. **Pulling from GHCR fails in CI** if the package is private. Stage 4 has the one-time manual visibility step.
3. **Debugging CI loops are slow.** Use `act` for quick checks of the `lint`/`test` jobs, and use `workflow_dispatch` reruns.
