import pytest
from whatsmyip import app

CASES = [(None, "9.9.9.9"), ("1.2.3.4", "1.2.3.4"), ("1.1.1.1, 2.2.2.2", "1.1.1.1")]


@pytest.mark.parametrize("xff, want", CASES + [(" 5.5.5.5 ,6", "5.5.5.5")])
def test_ip(xff, want):
    h = {"X-Forwarded-For": xff} if xff else {}
    r = app.test_client().get("/", headers=h, environ_base={"REMOTE_ADDR": "9.9.9.9"})
    assert r.get_json() == {"ip": want}


@pytest.mark.parametrize("path, body", [("/health", "ok"), ("/ready", "ready")])
def test_probes(path, body):
    r = app.test_client().get(path)
    assert (r.status_code, r.get_json()) == (200, {"status": body})
