SHELL := /bin/bash
.DEFAULT_GOAL := help

EXTRA ?=

.PHONY: help install provision provision-role acceptance check

help:
	@echo "Make targets:"
	@echo "  install     Install required Ansible collections"
	@echo "  provision   Run full provisioning playbook (use EXTRA=\"--limit host\" etc.)"
	@echo "  provision-role ROLE=<tag>  Run only the specified role/tag (EXTRA applies)"
	@echo "  acceptance  Run acceptance tag only (EXTRA to pass additional args)"
	@echo "  check       Provision in Ansible --check (dry-run) mode"

install:
	ansible-galaxy collection install -r ansible/collections/requirements.yml

provision: install
	./scripts/provision.sh $(EXTRA)

provision-role: install
	@if [ -z "$(ROLE)" ]; then \
	  echo "ROLE must be specified, e.g. make provision-role ROLE=bootstrap"; \
	  exit 1; \
	fi
	./scripts/provision.sh --tags $(ROLE) $(EXTRA)

acceptance:
	./scripts/acceptance.sh $(EXTRA)

check: install
	./scripts/provision.sh --check $(EXTRA)
