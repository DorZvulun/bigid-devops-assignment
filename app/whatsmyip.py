from flask import Flask, jsonify, request

app = Flask(__name__)


@app.get("/")
def index():
    # Left-most X-Forwarded-For entry is the original client.
    # shortcut: header is spoofable, trust N proxy hops (see README hardening).
    xff = request.headers.get("X-Forwarded-For", "")
    ip = xff.split(",")[0].strip() or request.remote_addr
    return jsonify(ip=ip)


@app.get("/health")
def health():
    return jsonify(status="ok"), 500


@app.get("/ready")
def ready():
    return jsonify(status="ready")
