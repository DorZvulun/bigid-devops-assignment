# whatsmyip

> Work in progress. The remaining sections are written in Stage 7 (see `TASKS.md`).

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

## Networking: why Traefik is disabled

k3d ships the Traefik ingress controller by default. This project turns it off and exposes the app through a `LoadBalancer` Service instead, served by k3s's built-in ServiceLB. The PDF lists the Ingress as optional, and the chart still has one (`ingress.enabled: false` by default).

With Traefik in the path, the app could not see the client's IP:

- By default, Traefik does not trust `X-Forwarded-*` headers that come from untrusted IPs. It drops them and sets its own ([forwarded headers](https://doc.traefik.io/traefik/routing/entrypoints/#forwarded-headers)).
- The k3d load balancer forwards plain TCP, so the only peer Traefik sees is that load balancer's internal Docker IP.
- So `/` would return an internal cluster IP instead of the client's IP.

ServiceLB forwards connections without touching HTTP headers. The client's `X-Forwarded-For` reaches the app unchanged.

## Security

### Public repo and image: what changes if the repo is private

This repo and its GHCR image are **public**, so the cluster pulls the image without credentials.

If the repo were private:

- **Image pulls need credentials.** The GHCR package would be private too, so the cluster would pull with an **image pull secret**. The deploy job would create it from the job's own token, with no stored secret, and the chart would reference it through an `imagePullSecrets` value:

  ```bash
  kubectl create secret docker-registry ghcr -n staging \
    --docker-server=ghcr.io --docker-username="$GITHUB_ACTOR" --docker-password="$GITHUB_TOKEN"
  ```

- **Scan results have no Security tab.** Uploading Trivy's SARIF results to **Security → Code scanning** on a private repo requires a paid GitHub subscription (GitHub Advanced Security / Code Security). The SARIF file would stay available as a run artifact only.
