# CI setup. `make secrets` pushes run-time settings to GitHub. Secret values never land in a file.
#   LLM_PROVIDER      repo variable: auto (default) | anthropic | github. Override: make secrets LLM_PROVIDER=github
#   ANTHROPIC_API_KEY repo secret, optional: with LLM_PROVIDER=auto, CI falls back to GitHub Models without it.

.PHONY: secrets
secrets:
	gh variable set LLM_PROVIDER --body "$${LLM_PROVIDER:-auto}"
	@echo "ANTHROPIC_API_KEY is optional: without it, LLM_PROVIDER=auto uses GitHub Models."
	@echo "Paste the key at the hidden prompt, or press Ctrl-C to skip it."
	gh secret set ANTHROPIC_API_KEY
