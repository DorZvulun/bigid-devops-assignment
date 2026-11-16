.PHONY: build scan scan-sarif sbom

build:
	docker build -t $(IMAGE):$(GIT_SHA) .

# Gate: fail on fixable HIGH/CRITICAL.
scan:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $(IMAGE):$(GIT_SHA)

scan-sarif:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --format sarif --output trivy.sarif $(IMAGE):$(GIT_SHA)

sbom:
	trivy image --format cyclonedx --output sbom.cdx.json $(IMAGE):$(GIT_SHA)
