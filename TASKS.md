# TASKS.md — progress tracker

Tick a box only after its **Done when** check has passed. Details for each stage are in `PLAN.md`.

**Now:** all stages done. Final check against the PDF acceptance checklist.

| Stage | Est. | Status |
|---|---|---|
| 0 Bootstrap | 20 m | ✅ |
| 1 App + tests | 1 h | ✅ |
| 2 Container | 45 m | ✅ |
| 3 Helm + k3d | 1.5 h | ✅ |
| 4 CI pipeline | 2–3 h | ✅ |
| 5 AI diagnosis (done last) | 1.5 h | ✅ |
| 6 Terraform deploy | 45 m | ✅ |
| 7 Docs | 1.5 h | ✅ |
| 8 Diagram | 30 m | ✅ |

---

## Stage 0: Bootstrap

- [x] **0.1** Install Trivy: `brew install trivy`.
  - Done when: `trivy --version` prints a version. ✅ 0.76.2
- [x] **0.2** Create `.gitignore` that ignores `instructions/` (the assignment PDF).
  - Done when: `.gitignore` contains `instructions/`. ✅
- [x] **0.3** Run `git init`. Extend `.gitignore` with `.env`, `.venv/`, `__pycache__/`, `*.tfstate*`, `.terraform/`, `sbom*.json`, `trivy*.sarif`. Add `.env.example`.
  - Done when: `git status` shows no `.env` and no PDF. ✅
- [x] **0.4** Create the public repo `bigid-devops-assignment` and push it (`gh repo create bigid-devops-assignment --public --source . --push`).
  - Done when: the repo URL opens in a browser. ✅ https://github.com/DorZvulun/bigid-devops-assignment

## Stage 1: App + unit tests

- [x] **1.1** Add `requirements-dev.txt` and the Makefile targets `venv lint test run`.
  - Done when: `make venv` creates `.venv` with ruff and pytest installed. ✅ ruff 0.17.5, pytest 9.2.0, Python 3.13.18
- [x] **1.2** Write `app/whatsmyip.py` with `/`, `/health` and `/ready`. Write `app/requirements.txt` with pinned versions.
  - Done when: `make run` + `curl -H 'X-Forwarded-For: 1.2.3.4' localhost:8080/` returns `{"ip":"1.2.3.4"}`. ✅ flask 3.1.3, gunicorn 27.0.1
- [x] **1.3** Write `tests/test_app.py`: the XFF cases plus all 3 endpoints.
  - Done when: `make lint test` passes, and test LOC ≤ app LOC. ✅ 6 passed; test 17 LOC ≤ app 22 LOC

## Stage 2: Container

- [x] **2.1** Check the distroless Python version and pick the matching builder tag.
  - Done when: both versions are noted in a Dockerfile comment. ✅ builder python:3.13-slim-trixie (3.13.18), runtime distroless python3-debian13 (3.13.5), both digest-pinned
- [x] **2.2** Write the multi-stage `Dockerfile` and `.dockerignore`. Add `make build`.
  - Done when: the image is ≤ ~80 MB and `docker run` + `curl /health` returns 200. ✅ 79.8 MB (distroless base 72.7 MB + app 7.1 MB; bar raised from ~70 MB by the human). Run test: read-only, uid 65532, /health 200, XFF ok, graceful SIGTERM ~1 s
- [x] **2.3** Add `make scan` and `make sbom`, both using Trivy.
  - Done when: `make scan` exits 0, and `sbom.cdx.json` is created. ✅ `make scan` exit 0 (0 fixable HIGH/CRITICAL); `sbom.cdx.json` + `trivy.sarif` written

## Stage 3: Helm chart + local k3d

- [x] **3.1** Write `k3d-config.yaml` and the targets `make cluster-create` / `make cluster-delete`.
  - Done when: `kubectl get nodes` shows 2 nodes Ready. ✅ k3d-bigid-server-0 + agent-0 Ready, v1.35.5+k3s1, 0 traefik pods
- [x] **3.2** Write the chart `charts/whatsmyip`: Deployment, Service (`LoadBalancer`), optional Ingress (off by default), values for probes/resources/securityContext/existingSecret.
  - Done when: `make helm-lint` passes with 0 warnings. ✅ `1 chart(s) linted, 0 chart(s) failed`
- [x] **3.3** Add `make deploy` (Terraform apply from Stage 6, local image import).
  - Done when: 2 pods are Running in `staging`. ✅ Terraform apply: 2 added; 2/2 pods Running in `staging`
- [x] **3.4** Add `make smoke` (`/health`, `/ready`, and the XFF assert via the LoadBalancer Service on `SMOKE_URL`).
  - Done when: `make smoke` passes, and it fails if you scale to 0. ✅ `smoke ok`; at 0 replicas `smoke: /ready failed`, exit 2

## Stage 4: CI pipeline

- [x] **4.1** Write `ci.yml` jobs 1–3: lint → test → build. Add concurrency, permissions, timeouts, and SHA-pinned actions.
  - Done when: these jobs are green on push. ✅ [run](https://github.com/DorZvulun/bigid-devops-assignment/actions/runs/43902297256): lint 10s, test 9s, build 32s
- [x] **4.2** Add jobs 4–5: scan (SARIF + SBOM artifact) and push to GHCR.
  - Done when: the image `:<sha>` is on GHCR and the SARIF is in the Security tab. ✅ image `:b1fc598…` on GHCR; Code scanning shows tool Trivy, category `trivy`, 0 results; artifact `sbom` 9 KB
- [x] **4.3** Manual step: set the GHCR package to public.
  - Done when: `docker pull ghcr.io/<owner>/whatsmyip:<sha>` works while logged out. ✅ not needed: the package inherited public visibility from the public repo. Anonymous manifest fetch returned HTTP 200
- [x] **4.4** Add jobs 6–7: helm-lint, then deploy + smoke on k3d in the runner.
  - Done when: the whole pipeline is green end to end. ✅ all 8 jobs green; deploy (k3d + Terraform + smoke) 75s
- [x] **4.5** Add job 8 (notify: commit status + job summary).
  - Done when: the commit shows the `ci/pipeline` status, and the run summary shows the table. ✅ commit status `ci/pipeline` = success, job summary table written. `make secrets` moved to 5.2.

## Stage 5: AI failure diagnosis (done last; Anthropic only)

GitHub Models was retired on 2026-07-30, so there is no provider switch: no `LLM_PROVIDER`, no `github` path.

- [x] **5.1** Finish `scripts/ai_diagnose.py` from agent E's branch (`worktree-agent-a5ade5687d7763460`). Remove the GitHub Models path and `LLM_PROVIDER`. It fetches the failed-job logs, redacts token-like strings, caps the size, calls the Anthropic API, and writes the diagnosis to the job summary and a PR comment (text only, never executed).
  - Done when: a local dry run against a past failed run prints a diagnosis. ✅ CI run [43920128766](https://github.com/DorZvulun/bigid-devops-assignment/actions/runs/43920128766) attempt 3: diagnosis printed and posted (`claude-opus-5-5`, SDK 2.9.0). Local: no key → "Skipped", exit 0; bad token → `::warning::`, exit 0. No local key, so the real call was verified in CI.
- [x] **5.2** Add `make secrets` (`gh secret set ANTHROPIC_API_KEY`, hidden prompt).
  - Done when: `gh secret list` shows `ANTHROPIC_API_KEY`, and no file in the repo contains the value. ✅ secret set 2026-11-16T17:46:10Z; the job log shows `ANTHROPIC_API_KEY: ***`. `make secrets` refuses to run without a terminal (a `!` run stored an empty value once).
- [x] **5.3** Add one small test for the script's pure logic (redaction and size cap). Add CI job `ai-diagnose` (`if: failure()`, `actions: read`, `pull-requests: write`, `timeout-minutes`), and make `notify` depend on it. The key is optional: with no `ANTHROPIC_API_KEY` the step is skipped (summary note, exit 0), and an API error is a warning, never a failure.
  - Done when: the test passes, actionlint is clean, on a green run the job shows as skipped, and a failed run without the key still shows `ai-diagnose` green with the "skipped: no key" note. ✅ 8 tests pass, actionlint clean. Green run [43919437412](https://github.com/DorZvulun/bigid-devops-assignment/actions/runs/43919437412): `ai-diagnose=skipped`. Failed run without key [43920128766](https://github.com/DorZvulun/bigid-devops-assignment/actions/runs/43920128766): `ai-diagnose=success`, summary "Skipped: no `ANTHROPIC_API_KEY` secret."
- [x] **5.4** Open demo PR `demo/ai-diagnosis` with a deliberate bug (a failing test).
  - Done when: the run fails, and the PR has an AI comment naming the failing test. ✅ PR #1, run [43920128766](https://github.com/DorZvulun/bigid-devops-assignment/actions/runs/43920128766): `test` failed, `ai-diagnose` named `test_probes[/health-ok]` in a [PR comment](https://github.com/DorZvulun/bigid-devops-assignment/pull/1#issuecomment-6924338410).
- [x] **5.5** Replace the placeholders in `README.md` (How CI works) and `README-EXTENDED.md` (AI failure diagnosis) with the link to that failed run. Change the "planned" AI labels in `docs/architecture.html` and `docs/explainer.html` to built.
  - Done when: the README link opens the failed run, and 7.1 is ticked. ✅ both READMEs link the run and the comment; the diagram's AI node is no longer "planned" and its edge now reads `ai-diagnose → notify` (it had `notify → ai-diagnose`); explainer updated.

## Stage 6: Terraform deploy (namespace + app)

- [x] **6.1** Write `infra/` (`kubernetes_namespace` + `helm_release`, providers pinned, lock file committed). `make deploy` runs `terraform apply`. `make cluster-delete` also removes local state.
  - Done when: `make cluster-create deploy` gives 2 Running pods in `staging`, and a second `terraform plan` shows no changes. ✅ `Plan: 2 to add` → apply OK; second plan exit 0 (no changes). Namespace resource is `kubernetes_namespace_v1`
- [x] **6.2** CI deploy job installs pinned, checksum-verified Terraform and runs the same `make deploy`.
  - Done when: the CI `deploy` job is green. ✅ CI deploy job green with Terraform 1.17.1 (checksum-verified)

## Stage 7: Docs

- [x] **7.1** Write `README.md` covering every item in CLAUDE.md's "README must cover" list, including the failed-run link.
  - Done when: every item on that list is checked off. ✅ split into `README.md` (short) + `README-EXTENDED.md`; failed-run link in both.
- [x] **7.2** Write the ADHD-friendly HTML explainer covering the architecture and how to run the project.
  - Done when: it opens in a browser and the quick-start commands work. ✅ `docs/explainer.html`; renders in headless Chrome; from a clean state `make all` exit 0 in 41 s (warm caches), curl returns the forwarded IP, `make cluster-delete` works

## Stage 8: Diagram

- [x] **8.1** Run `/archify` for the architecture diagram (CI flow + runtime topology).
  - Done when: it is linked from the README and the HTML. ✅ `docs/architecture.html`, linked from README (Architecture) and the explainer

---

## Final acceptance check (from the PDF)

- [ ] App, tests and README are present.
- [ ] CI builds, scans, pushes, deploys and smoke-tests on push/PR, and all of it passes.
- [ ] The Dockerfile is multi-stage and produces a compact image.
- [ ] The Helm chart has configurable probes and resources, and `helm lint` passes.
- [ ] The scan/SBOM is produced and documented.
- [ ] The AI step works on a failed run, and the README links to that run.
