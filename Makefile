# Nile-Factory developer shortcuts. Run from repo root.
REPO_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS_DIR := $(REPO_ROOT)agent-pipeline-config/modules/aios-agent-aws-migrator/scripts
CATALOG_SCRIPT := $(REPO_ROOT)agent-pipeline-config/scripts/generate-script-catalog.sh
CATALOG_OUT := $(REPO_ROOT)docs/11-script-and-stage-catalog.md

.PHONY: test catalog catalog-check help

help:
	@echo "Targets:"
	@echo "  make test          Run Python unit tests in the script pack"
	@echo "  make catalog       Regenerate docs/11-script-and-stage-catalog.md"
	@echo "  make catalog-check Fail if the catalog is out of date"

test:
	@set -e; \
	for f in $(SCRIPTS_DIR)/test_*.py; do \
		echo "==> python3 $$f"; \
		python3 "$$f"; \
	done; \
	if [ -f "$(SCRIPTS_DIR)/test_ensure_cloud2code.sh" ]; then \
		echo "==> bash $(SCRIPTS_DIR)/test_ensure_cloud2code.sh"; \
		bash "$(SCRIPTS_DIR)/test_ensure_cloud2code.sh"; \
	fi; \
	if [ -f "$(SCRIPTS_DIR)/test_cloud2code_scan_detach.sh" ]; then \
		echo "==> bash $(SCRIPTS_DIR)/test_cloud2code_scan_detach.sh"; \
		bash "$(SCRIPTS_DIR)/test_cloud2code_scan_detach.sh"; \
	fi

catalog:
	@bash "$(CATALOG_SCRIPT)"

catalog-check:
	@set -e; \
	tmp=$$(mktemp); \
	OUT="$$tmp" bash "$(CATALOG_SCRIPT)"; \
	diff -u "$(CATALOG_OUT)" "$$tmp"; \
	rm -f "$$tmp"
