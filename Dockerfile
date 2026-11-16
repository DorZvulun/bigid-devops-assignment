# Builder Python 3.13.18 and runtime Python 3.13.5: same minor, so compiled wheels (markupsafe) load.

# python:3.13-slim-trixie
FROM python@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS builder
WORKDIR /build
COPY app/requirements.txt app/requirements.txt
RUN pip install --no-cache-dir --require-hashes --target /deps -r app/requirements.txt

# gcr.io/distroless/python3-debian13:nonroot (no shell, uid 65532)
FROM gcr.io/distroless/python3-debian13@sha256:6c4cb3bfa4b555429dd19541796a6ba6b30c84675b460bd0bd5072f7d5bdae71
LABEL org.opencontainers.image.source=https://github.com/DorZvulun/bigid-devops-assignment
COPY --from=builder /deps /deps
COPY app/whatsmyip.py /app/whatsmyip.py
ENV PYTHONPATH=/deps PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["python3", "-m", "gunicorn", "-b", "0.0.0.0:8080", "--worker-tmp-dir", "/dev/shm", "--no-control-socket", "--chdir", "/app", "whatsmyip:app"]
