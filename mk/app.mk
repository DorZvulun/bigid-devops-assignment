VENV := .venv

.PHONY: venv lint test run

venv: $(VENV)/.stamp

$(VENV)/.stamp: requirements-dev.txt
	uv venv --python $(PYTHON_VERSION) $(VENV)
	uv pip install --python $(VENV) --require-hashes -r requirements-dev.txt
	touch $@

lint: venv
	$(VENV)/bin/ruff check .
	$(VENV)/bin/ruff format --check .

test: venv
	$(VENV)/bin/pytest

run: venv
	$(VENV)/bin/gunicorn --bind 0.0.0.0:8080 --chdir app whatsmyip:app
