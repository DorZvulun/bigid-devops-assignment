from ai_diagnose import cap, redact


def test_redact_hides_secrets_and_keeps_the_error():
    log = (
        "ghp_"
        + "a" * 36
        + " sk-ant-api03-xyz123456789 password=hunter2 AssertionError: 500 != 200"
    )
    out = redact(log)
    assert "ghp_" not in out and "sk-ant" not in out and "hunter2" not in out
    assert "AssertionError: 500 != 200" in out


def test_cap_keeps_the_tail():
    assert cap("abcdef", limit=3) == "[...truncated...]\ndef"
    assert cap("abc", limit=3) == "abc"
