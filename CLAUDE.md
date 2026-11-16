# CLAUDE.md — BigID DevOps Home Assignment

> Rule: anything marked **[OPEN]** is not decided yet. Do not implement it until the human confirms.
> Implementation order and details live in `PLAN.md`. Progress is tracked in `TASKS.md`.

## Project

Home assignment for the BigID DevOps Engineer role. The brief is at `instructions/DevOpsHome_assignment.pdf`. It must never be committed, because the repo is public.

Build a tiny web app that returns the client's originating IP. Wrap it in a CI pipeline (order exactly as in the PDF "Deliverables" section):

lint → test → build → scan → push → helm lint → deploy (staging) → smoke test

Two more CI requirements sit outside that sequence:
- **Notification on success or failure.** Source: the PDF "CI" section, last bullet: "Send a simple notification on success/failure (Slack, GitHub status, or similar)."
- **AI diagnosis, only when the pipeline fails.** Source: the PDF "AI component" section.

Grading = the acceptance checklist in the PDF. The last item is easy to forget: **the README must link to a failed CI run where the AI diagnosis worked.**

## Working rules

- **Human decides, agent proposes.** Never mark a decision as made unless the human said so explicitly. Present options plus a recommendation, then wait.
- **Track progress in `TASKS.md`.** Tick a box only after the task's "Done when" check actually passed. Do this in the same change as the work.
- **`make` is the local entrypoint.** `make all` deploys the whole project on a fresh computer (for testing and the presentation). CI calls the same make targets for every step that also runs locally.
  - Exception: steps that only make sense in CI live in workflow YAML only. These are the registry push, the commit-status notification and the AI-diagnosis wiring. Pushing a branch or an image is never a make target.
- **CI completeness is mandatory.** Every step the PDF requires must exist in CI and actually work:
  - lint, unit tests (fail on failure), build tagged with the commit SHA, vulnerability scan or SBOM, push to a registry
  - helm lint, deploy to `staging`, smoke test (fail on failure)
  - success/failure notification, AI diagnosis on failure
  - No step may be skipped or stubbed.
- **Tests: sufficient, not bloated.** This is a separate rule from CI completeness.
  - Unit tests cover the app's real behaviour: IP extraction (header present, missing, multiple hops) and each endpoint (`/`, `/health`, `/ready`).
  - Keep test LOC at or below app LOC.
  - The post-deploy smoke test is the integration test. Add no extra test layers (no chart unit tests, no e2e framework).
- **Pin everything.** That covers tool versions in the Makefile/CI, GitHub Actions by commit SHA, and Python deps via the lock file.
- **No secrets in code, ever.** That includes the repo, the chart, the Makefile and workflow YAML.
  - The user supplies every secret at run time through a make target that pushes it to its destination. Example: `make secrets` runs `gh secret set ANTHROPIC_API_KEY`, which reads the value from a hidden prompt or stdin. The value never lands in a file.
  - `.env.example` lists variable names only. `.env` is gitignored.
  - The README documents every secret: what it is for, whether it is required, and the command that sets it.

## Stack

| Concern | Choice | Status |
|---|---|---|
| App language | Python 3.13, pinned everywhere: local venv, lock files, CI, builder image, distroless runtime | decided |
| Web framework | Flask + gunicorn (smallest dependency set = smallest attack surface) | decided |
| Lint / format | ruff (superset of flake8 rules) | decided based on pdf |
| Tests | pytest | decided based on app language |
| Container | multi-stage → distroless Python runtime, non-root | requirement in pdf |
| Local + CI cluster | k3d with Traefik **disabled**. The Service is `type: LoadBalancer`, served by k3s's built-in ServiceLB. The chart keeps an optional Ingress, off by default | decided |
| Packaging | Helm chart in `charts/`. `helm lint` uses the Helm v4 CLI (same version pinned in CI) | decided |
| Deploy | Terraform in `infra/`: `kubernetes_namespace` (staging) + `helm_release` (the chart). `make deploy` runs `terraform apply`, locally and in CI. Terraform never creates the cluster; `make cluster-create` does (k3d CLI) | decided |
| CI | GitHub Actions; public repo `bigid-devops-assignment` | decided |
| Registry | GHCR (`ghcr.io/<owner>/<image>`), auth via `GITHUB_TOKEN`, public package | decided |
| Image scan / SBOM | Trivy (fail on fixable HIGH/CRITICAL, SARIF to Security tab) + SBOM artifact | decided, implemented |
| Notification | GitHub commit status `ci/pipeline` + job summary, no third-party apps (no Slack) | decided |
| AI failure diagnosis | Anthropic API only. `ANTHROPIC_API_KEY` is an optional secret: without it the AI step is skipped and nothing breaks. Built last, after everything else works | decided |

### LLM provider (decided 2026-11-16)

Anthropic only. GitHub Models was retired on 2026-07-30, so there is no keyless fallback and no `LLM_PROVIDER` switch. The secret `ANTHROPIC_API_KEY` (set with `make secrets`) is optional. If it is set, the AI step runs. If it is missing (including on fork PRs), the step is skipped and the pipeline result is unchanged. An Anthropic API error is logged as a warning and never fails the job (decided 2026-11-16). It is built last, after the rest of the pipeline works.

## Planned layout

```
big-id/
├── CLAUDE.md, AGENTS.md -> CLAUDE.md, README.md, TASKS.md, PLAN.md
├── Makefile                 # local entrypoint: all venv lint test run build scan scan-sarif sbom cluster-create cluster-delete helm-lint deploy smoke trace-hops secrets
├── app/                     # Python app
├── tests/                   # unit tests (pytest)
├── Dockerfile, .dockerignore
├── charts/<app>/            # Deployment, Service, optional Ingress, values.yaml
├── k3d-config.yaml
├── infra/                   # Terraform: staging namespace + helm_release of the chart
├── scripts/ai_diagnose.py   # fetch failed-job logs → LLM → PR comment / summary
└── .github/workflows/ci.yml
```

## App contract

- `GET /` returns the client's originating IP.
- `GET /health` is liveness. It returns 200 if the process is up.
- `GET /ready` is readiness. It returns 200 when the app is ready to serve.
- Client IP: return the first (left-most) `X-Forwarded-For` entry. Fall back to the socket peer address.
  - Clients can spoof this header. That is a known limit, not implemented now; the README covers the hardening.

## Security (decided)

**Implement:**
- **Pod hardening:**
  - Non-root, `readOnlyRootFilesystem`, drop all capabilities.
  - `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`.
  - No shell in the runtime image.
- **Secrets:** follow the "No secrets in code, ever" rule above.
  - The chart has no hardcoded secrets.
  - The chart supports an `existingSecret` reference through `envFrom`.
- **CI permissions:** least privilege, set per job (`contents: read` by default). Grant `packages: write` and `pull-requests: write` only to the jobs that need them.

**Document only, in the README "Security hardening" section. Do not implement:**
- `X-Forwarded-For` spoofing: trust only N proxy hops (Werkzeug `ProxyFix(x_for=N)`) or restrict which proxy IPs are trusted.
- Fork PRs: no secrets, push or deploy for fork code. Never combine `pull_request_target` with a checkout of PR code.
- AI step: logs are untrusted input (prompt injection). Redact token-like strings, cap the size, post the output as text only and never execute it.
- Secret managers beyond plain k8s Secrets: sealed-secrets, External Secrets Operator.

## Reliability (decided: implement and document in the README)

- Liveness, readiness and startup probes, plus resource requests/limits. All are configurable in `values.yaml` with sensible defaults.
- 2 replicas.
- Deploy with Terraform `helm_release` using `atomic = true`, `wait = true` and a `timeout`, so a failed rollout rolls back automatically.
- gunicorn shuts down gracefully on SIGTERM.
- CI uses a `concurrency` group per ref (cancel superseded runs) and a `timeout-minutes` on every job.
- Image tag = commit SHA. Never deploy `latest`. On a PR this is the PR head commit, never GitHub's synthetic merge commit (see PLAN.md Stage 4).

## README must cover

Split (decided 2026-11-16): `README.md` is short (run locally, how CI works, where the image is published, repo layout, links to `docs/*.html` and `README-EXTENDED.md`). Every other item below lives only in `README-EXTENDED.md`.

- How to run locally
- How CI works
- Where the image is published
- Every secret and the command that sets it
- How Trivy is implemented (already written and I like how it is written)
- Scan/SBOM output and where to find it
- Link to the failed run where the AI diagnosis worked
- The decided security measures, plus the "Security hardening" section (document-only items)
- Reliability measures
- Why Traefik is disabled (see PLAN.md Stage 3)

## Out of scope

Unless the human asks:

- Go rewrite (the human's later, separate project for fun)
- ArgoCD/GitOps
- Multi-env promotion
- Cloud resources
- Monitoring stack
- Creating the cluster with Terraform. The only k3d Terraform provider crash-looped k3s (spike, 2026-11-16), so `make cluster-create` uses the k3d CLI.
