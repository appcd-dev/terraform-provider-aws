#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
RULES_DIR="$ROOT_DIR/rules"

if ! command -v opa >/dev/null 2>&1; then
  echo "opa not installed; skipping local OPA validation"
  echo "rules validation completed"
  exit 0
fi

# Format gate across every Rego file.
find "$RULES_DIR" -type f -name '*.rego' -print0 | xargs -0 -r opa fmt --fail --list

# Parse/type-check per package so policy_test.rego can see deny from policy.rego.
# Checking *_test.rego in isolation yields false "var deny is unsafe" errors.
while IFS= read -r -d '' policy; do
  pkg_dir=$(dirname "$policy")
  echo "opa check ${pkg_dir#"$ROOT_DIR"/}"
  # shellcheck disable=SC2086
  opa check "$pkg_dir"/*.rego
done < <(find "$RULES_DIR" -type f -name 'policy.rego' -print0 | sort -z)

# Unit tests per package that ships policy_test.rego.
while IFS= read -r -d '' policy; do
  pkg_dir=$(dirname "$policy")
  if [ -f "$pkg_dir/policy_test.rego" ]; then
    echo "opa test ${pkg_dir#"$ROOT_DIR"/}"
    opa test "$pkg_dir/policy.rego" "$pkg_dir/policy_test.rego"
  fi
done < <(find "$RULES_DIR" -type f -name 'policy.rego' -print0 | sort -z)

echo "rules validation completed"
