# TASKS.md — progress tracker

Tick a box only after its **Done when** check has passed. Details for each stage are in `PLAN.md`.

**Now:** Wave 3: push, then fix CI until green (see `plans/agent-workflow-planning.md`)

| Stage | Est. | Status |
|---|---|---|
| 0 Bootstrap | 20 m | ✅ |
| 1 App + tests | 1 h | ✅ |
| 2 Container | 45 m | ⬜ |
| 3 Helm + k3d | 1.5 h | ✅ |
| 4 CI pipeline | 2–3 h | ⬜ |
| 5 AI diagnosis (done last) | 1.5 h | ⬜ |
| 6 Terraform deploy | 45 m | ⬜ |
| 7 Docs | 1.5 h | ⬜ |
| 8 Diagram | 30 m | ⬜ |

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
- [ ] **2.2** Write the multi-stage `Dockerfile` and `.dockerignore`. Add `make build`.
  - Done when: the image is ≤ ~70 MB and `docker run` + `curl /health` returns 200. ⚠️ NOT MET: image is 79.8 MB. The distroless python3-debian13 base alone is 72.7 MB; the app adds 7.1 MB. Run test passed (read-only, uid 65532, /health 200, XFF ok, graceful SIGTERM ~1 s). Needs a human call on the size bar.
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

- [ ] **4.1** Write `ci.yml` jobs 1–3: lint → test → build. Add concurrency, permissions, timeouts, and SHA-pinned actions.
  - Done when: these jobs are green on push.
- [ ] **4.2** Add jobs 4–5: scan (SARIF + SBOM artifact) and push to GHCR.
  - Done when: the image `:<sha>` is on GHCR and the SARIF is in the Security tab.
- [ ] **4.3** Manual step: set the GHCR package to public.
  - Done when: `docker pull ghcr.io/<owner>/whatsmyip:<sha>` works while logged out.
- [ ] **4.4** Add jobs 6–7: helm-lint, then deploy + smoke on k3d in the runner.
  - Done when: the whole pipeline is green end to end.
- [ ] **4.5** Add job 8 (notify: commit status + job summary) and `make secrets`.
  - Done when: the commit shows the `ci/pipeline` status, and the run summary shows the table.

## Stage 5: AI failure diagnosis (done last, after Stage 8; Anthropic only)

- [ ] **5.1** Write `scripts/ai_diagnose.py`: fetch failed-job logs, select the provider (`auto|anthropic|github`), call the LLM, write the summary + PR comment.
  - Done when: a local dry run against an old failed run prints a diagnosis.
- [ ] **5.2** Add one test for provider selection, and add job 9 `ai-diagnose` (`if: failure()`).
  - Done when: the test passes and the job appears in the workflow graph.
- [ ] **5.3** Open demo PR `demo/ai-diagnosis` with a deliberate bug.
  - Done when: the PR has an AI comment naming the failing test.
- [ ] **5.4** Verify both providers: run with the Anthropic key, then with `LLM_PROVIDER=github`.
  - Done when: both runs produced a diagnosis.

## Stage 6: Terraform deploy (namespace + app)

- [x] **6.1** Write `infra/` (`kubernetes_namespace` + `helm_release`, providers pinned, lock file committed). `make deploy` runs `terraform apply`. `make cluster-delete` also removes local state.
  - Done when: `make cluster-create deploy` gives 2 Running pods in `staging`, and a second `terraform plan` shows no changes. ✅ `Plan: 2 to add` → apply OK; second plan exit 0 (no changes). Namespace resource is `kubernetes_namespace_v1`
- [ ] **6.2** CI deploy job installs pinned, checksum-verified Terraform and runs the same `make deploy`.
  - Done when: the CI `deploy` job is green.

## Stage 7: Docs

- [ ] **7.1** Write `README.md` covering every item in CLAUDE.md's "README must cover" list, including the failed-run link.
  - Done when: every item on that list is checked off.
- [ ] **7.2** Write the ADHD-friendly HTML explainer covering the architecture and how to run the project.
  - Done when: it opens in a browser and the quick-start commands work.

## Stage 8: Diagram

- [ ] **8.1** Run `/archify` for the architecture diagram (CI flow + runtime topology).
  - Done when: it is linked from the README and the HTML.

---

## Final acceptance check (from the PDF)

- [ ] App, tests and README are present.
- [ ] CI builds, scans, pushes, deploys and smoke-tests on push/PR, and all of it passes.
- [ ] The Dockerfile is multi-stage and produces a compact image.
- [ ] The Helm chart has configurable probes and resources, and `helm lint` passes.
- [ ] The scan/SBOM is produced and documented.
- [ ] The AI step works on a failed run, and the README links to that run.
