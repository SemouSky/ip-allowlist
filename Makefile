.PHONY: test test-unit test-bats test-integration test-images hooks lint unit integration install uninstall clean help

VERSION := $(shell cat version.txt)
DISTRO ?= ubuntu-24.04
ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)

help:
	@echo "ip-allowlist Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  test              Lint plus unit and integration tests"
	@echo "  test-unit         Run unit tests (bats, falls back to tests/unit.sh)"
	@echo "  test-bats         Run the bats suite directly"
	@echo "  test-integration  Run integration tests only (podman/docker)"
	@echo "  test-images       Pre-build the per-distro test images"
	@echo "  hooks             Install the pre-commit git hook"
	@echo "  lint              Run shellcheck and bash syntax checks"
	@echo "  install           Install ip-allowlist system-wide"
	@echo "  uninstall         Uninstall ip-allowlist"
	@echo "  clean             Remove build artifacts"

test: lint
	@./tests/run.sh

lint:
	@./tests/lint.sh

test-unit:
	@./tests/run.sh --unit

test-bats:
	@bats tests/bats/*.bats

unit: test-unit

test-integration:
	@./tests/run.sh --integration --distro $(DISTRO)

integration: test-integration

test-images:
	@for d in ubuntu-22.04 ubuntu-24.04 fedora rocky; do \
		echo "building ip-allowlist-test:$$d"; \
		$(ENGINE) build -t ip-allowlist-test:$$d tests/docker/$$d || exit 1; \
	done

hooks:
	@mkdir -p .git/hooks
	@printf '#!/bin/sh\nmake lint test-unit\n' > .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "installed .git/hooks/pre-commit"

install:
	@./install.sh

uninstall:
	@./uninstall.sh

clean:
	@rm -rf dist
	@echo "Cleaned build artifacts"
