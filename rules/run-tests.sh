#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
RULES_DIR="$ROOT_DIR/rules"

if command -v opa >/dev/null 2>&1; then
  find "$RULES_DIR" -type f -name '*.rego' -print0 | xargs -0 -r opa fmt --fail --list
  find "$RULES_DIR" -type f -name '*.rego' -print0 | xargs -0 -r -n 1 opa check
else
  echo "opa not installed; skipping local OPA validation"
fi

echo "rules validation completed"
