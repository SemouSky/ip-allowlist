.PHONY: test lint unit integration install uninstall clean help

VERSION := $(shell cat version.txt)
DISTRO ?= ubuntu-24.04

help:
	@echo "ip-allowlist Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  test          Lint plus unit and integration tests"
	@echo "  lint          Run shellcheck and bash syntax checks"
	@echo "  unit          Run unit tests only"
	@echo "  integration   Run integration tests only (uses podman/docker)"
	@echo "  install       Install ip-allowlist system-wide"
	@echo "  uninstall     Uninstall ip-allowlist"
	@echo "  clean         Remove build artifacts"
	@echo "  help          Show this help"

test: lint
	@./tests/run.sh

lint:
	@./tests/lint.sh

unit:
	@./tests/run.sh --unit

integration:
	@./tests/run.sh --integration --distro $(DISTRO)

install:
	@./install.sh

uninstall:
	@./uninstall.sh

clean:
	@rm -rf dist
	@echo "Cleaned build artifacts"
