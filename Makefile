# Local entrypoint. `make all` deploys the whole project on a fresh computer.
# Must run on GNU Make 3.81 (the macOS default): no .ONESHELL, .SHELLFLAGS or `!=`.

SHELL := /bin/bash

# GHCR needs a lowercase owner. CI overrides IMAGE and passes the full commit SHA.
IMAGE ?= ghcr.io/dorzvulun/whatsmyip
GIT_SHA ?= $(shell git rev-parse --short HEAD)
PYTHON_VERSION := 3.13

.DEFAULT_GOAL := all
.PHONY: all
all: venv lint test build scan cluster-create deploy smoke

# Temporary split for parallel work (Waves 1-2): each agent owns one mk/*.mk file.
# Merged back into this file at the end of Wave 2.
include $(wildcard mk/*.mk)
