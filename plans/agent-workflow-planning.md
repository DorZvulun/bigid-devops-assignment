# Agent workflow planning: parallel execution of PLAN.md

Status: **ready for Wave 0**. All open decisions are resolved.

The work splits into **4 waves**. At most **5 agents can run in parallel**, all in Wave 1. The rest has to run in order.

Time estimates are agent wall-clock, not human hours.

## Wave 0: main session, sequential (~5 min)

- **0.3:** `git init`, extend `.gitignore`, add `.env.example`.
- **Makefile skeleton (temporary split, decided):** root `Makefile` defines `IMAGE` and `GIT_SHA`, then `include mk/*.mk`.
  - Each agent owns one `mk/*.mk` file, so no two agents edit the same file.
  - The split is temporary. It is merged back into one `Makefile` at the end of Wave 2.
- **0.4:** `gh repo create bigid-devops-assignment --public --source . --push`.
  - Approved by the human.

## Wave 1: 5 agents in parallel, each in its own git worktree

| # | Agent | Task | Model | Effort | Est. |
|---|---|---|---|---|---|
| A | app | Stage 1: `app/whatsmyip.py`, pinned `requirements*.txt`, unit tests, `mk/app.mk` (`venv lint test run`) | sonnet | lower | 5–8 min |
| C | chart | Stage 3.1–3.2: `k3d-config.yaml`, `charts/whatsmyip/`, `mk/k8s.mk` (`cluster down helm-lint deploy smoke`). Verified up to `helm lint` passing and 2 nodes Ready | sonnet | default | 15–20 min |
| D | ci | Stage 4 draft: `.github/workflows/ci.yml` with all 9 jobs, actions pinned by SHA, Trivy installed with checksum verification, `make secrets` | opus | higher | 20–25 min |
| E | ai | Stage 5.1–5.2: `scripts/ai_diagnose.py` (stdlib only), provider-selection test, real model IDs checked | opus | default | 15–20 min |
| F | tf | Stage 6.1: Terraform k3d provider spike, time-boxed at 20 min. Uses cluster `bigid-tf` on port `8081`, so it does not clash with agent C | sonnet | default | 20 min |

## Wave 2: sequential, after A and C are merged

| # | Agent | Task | Model | Effort | Est. |
|---|---|---|---|---|---|
| B | container | Stage 2: check the distroless Python version, write `Dockerfile` and `.dockerignore`, `mk/container.mk` (`build scan sbom`) | sonnet | default | 10–15 min |
| — | main session | Stage 3.3–3.4: local `make cluster build deploy smoke`. Needs B's image and C's chart | — | — | 10 min |
| — | main session | Makefile merge: fold `mk/*.mk` back into one `Makefile` (see below) | — | — | 2–5 min |

### Makefile merge (last step of Wave 2)

1. Before merging, save `make -n <target>` output for every target.
2. Paste the `mk/*.mk` files into `Makefile` in pipeline order: app, container, k8s, ci, tf.
3. Delete the `include mk/*.mk` line and the `mk/` directory.
4. Run `make -n <target>` again for every target. The output must match step 1.
5. Re-run `make lint test build scan` as a final check.

From Wave 3 on, every change goes into the single `Makefile`.
This includes the `tf-up` / `tf-down` targets from Stage 6.2, which come after agent F's spike.

## Wave 3: CI loop plus docs

| # | Agent | Task | Model | Effort | Est. |
|---|---|---|---|---|---|
| — | main session | Stage 4.1–4.5 and 5.3–5.4: push, fix red CI jobs, make the GHCR package public (manual step), open the demo failure PR | — | — | 30–60 min (mostly waiting on CI) |
| G | docs | Stage 7.1: README. Keeps the existing Trivy section unchanged. The failed-run link is added last | sonnet | default | 10 min |
| H | diagram | Stage 8.1: `/archify` on the real repo | sonnet | lower | 10 min |

- G and H run in parallel with each other.
- Only the failed-run link in the README waits for Stage 5.3.
- Stage 7.2 (HTML explainer) runs after the diagram exists, because it links to it.

## Totals

- Wall-clock: about 1.5–2.5 h, against 10–11 h in `PLAN.md`.
- Most of the remaining time is waiting on CI runs.

## Rules for every agent

- Every subagent loads the `caveman` and `ponytail` skills as its first action (Skill tool: `caveman:caveman`, `ponytail:ponytail`). Each agent prompt states this explicitly.
  - Caveman covers chat output only. Files the agent writes (code, comments, docs, commit messages) stay in normal prose.
- Agents never tick boxes in `TASKS.md`. The main session ticks each box after it re-runs that task's "Done when" check during the merge.
- Agents touch only the files listed in their task, plus their own `mk/*.mk` file.
- Agent F must not use cluster name `bigid` or port `8080`.

## Risks

- **Unverified lookups:** the action SHAs (agent D) and the model IDs (agent E) are found by the agents. Re-check them at merge.
- **Laptop contention:** agents C and F both run Docker and k3d at the same time and compete for CPU and memory.

## Open decisions (human)

1. ~~**Makefile structure.**~~ Decided: split into `mk/*.mk` for Waves 1–2, then merge back into one `Makefile` at the end of Wave 2.
2. ~~**"proposed" stack items.**~~ Decided in `CLAUDE.md`: ruff, pytest, multi-stage distroless non-root container, Trivy + SBOM.
   - GHCR also decided. Auth uses the automatic per-run `GITHUB_TOKEN` (`packages: write` on the `push` job only), so no stored secret is needed. Pulls need no auth once the package is public.
3. ~~**Test location.**~~ Decided: `tests/` at the repo root (`tests/test_app.py`, plus the AI provider-selection test).
4. ~~**Stage 0.4.**~~ Decided: OK to create the public repo with `gh repo create bigid-devops-assignment --public`.
5. ~~**App / chart / image name.**~~ Decided: `whatsmyip` for the Python module, chart, Helm release, Kubernetes objects and image (`ghcr.io/<owner>/whatsmyip:<sha>`).
6. ~~**AI script name.**~~ Decided: `scripts/ai_diagnose.py`. A hyphen would block `import` from the test.
7. ~~**Python lock file.**~~ Decided: hash-locked requirements, generated with `uv pip compile --generate-hashes` (or `pip-compile`) and installed with `pip install --require-hashes`. Applies to both runtime and dev deps.
