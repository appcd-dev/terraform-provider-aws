#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_SCRIPT="$SCRIPT_DIR/cloud2code-aws-scan.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/work/.wf-test"
export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
export HOME="$TEST_ROOT/work"
export RUNNER_WORK_HOME="$TEST_ROOT/work"

# Mock required tools
cat > "$TEST_ROOT/bin/jq" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"--arg r"* ]]; then
  if [ -f "$HOME/.wf-test/.work/cloud2code-inputs.json" ] && grep -q 'allow_partial.*true' "$HOME/.wf-test/.work/cloud2code-inputs.json"; then
    printf '{"aws_region":"us-east-1","cloud2code_allow_partial":"true"}\n'
  elif [ -f "$HOME/.wf-test/.work/cloud2code-inputs.json" ] && grep -q 'allow_partial.*false' "$HOME/.wf-test/.work/cloud2code-inputs.json"; then
    printf '{"aws_region":"us-east-1","cloud2code_allow_partial":"false"}\n'
  elif [ -f "$HOME/.wf-test/.work/cloud2code-inputs.json" ] && grep -q 'cloud2code_exclude.*aws_s3_bucket' "$HOME/.wf-test/.work/cloud2code-inputs.json"; then
    printf '{"aws_region":"us-east-1","cloud2code_exclude":"aws_s3_bucket"}\n'
  else
    printf '{"aws_region":"us-east-1"}\n'
  fi
elif [[ "$*" == *"--arg k aws_region"* ]]; then
  echo "us-east-1"
elif [[ "$*" == *"--arg k cloud2code_allow_partial"* ]]; then
  if [ -f "$HOME/.wf-test/.work/cloud2code-inputs.json" ]; then
    if grep -q 'allow_partial.*true' "$HOME/.wf-test/.work/cloud2code-inputs.json"; then echo true; elif grep -q 'allow_partial.*false' "$HOME/.wf-test/.work/cloud2code-inputs.json"; then echo false; fi
  fi
elif [[ "$*" == *"--arg k cloud2code_exclude"* ]]; then
  if [ -f "$HOME/.wf-test/.work/cloud2code-inputs.json" ]; then
    sed -n 's/.*"cloud2code_exclude"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.wf-test/.work/cloud2code-inputs.json"
  fi
elif [[ "$*" == *"--arg k"* ]]; then
  exit 0
elif [[ "$*" == *"length"* ]]; then
  echo "${MOCK_STATE_COUNT:-1}"
elif [[ "$*" == *".resources"* ]]; then
  count="${MOCK_STATE_COUNT:-1}"
  printf '{"resources":[{"mode":"managed","type":"aws_vpc","instances":['
  for ((i=0; i<count; i++)); do [ "$i" -gt 0 ] && printf ','; printf '{}'; done
  printf ']}]}\n'
elif [[ "$*" == *"--arg"* ]]; then
  echo "{}"
else
  echo "1"
fi
MOCK
cat > "$TEST_ROOT/bin/aws" << 'MOCK'
#!/usr/bin/env bash
echo '{"UserId":"mock","Account":"123","Arn":"mock"}'
MOCK
cat > "$TEST_ROOT/bin/cloud2code" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then
  echo "0.5.6"
  exit 0
fi
if [[ "$*" == *"get-supported-resources"* ]]; then
  echo " - aws_cloudwatch_log_group"
  echo " - aws_alb"
  exit 0
fi

echo "Error: could not import from aws: scan aborted due to API rate limiting: error while reading the resources of type: aws_cloudwatch_log_group: ThrottlingException: Rate exceeded" >&2
exit 1
MOCK

chmod +x "$TEST_ROOT/bin/"*

# Speed up test backoffs
export CLOUD2CODE_THROTTLE_BACKOFF_SECONDS=1

echo "Testing cloud2code throttle fails closed..."
if bash "$SCAN_SCRIPT" "wf-test" "us-east-1" > "$TEST_ROOT/scan.out" 2>&1; then
  fail "throttled scan should block by default"
fi
if ! grep -q 'blocked:cloud2code_scan_failed: "true"' "$TEST_ROOT/scan.out"; then
  cat "$TEST_ROOT/scan.out"
  fail "Did not emit the failed-scan sentinel"
fi
if grep -q 'cloud2code_scan_ok: "true"' "$TEST_ROOT/scan.out"; then
  fail "throttled partial inventory was incorrectly marked successful"
fi


# Explicit scan exclusions must override a stale value in workflow inputs.
cat > "$TEST_ROOT/bin/cloud2code" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then echo "0.5.6"; exit 0; fi
if [[ "$*" == *"get-supported-resources"* ]]; then
  echo " - aws_glue_catalog_table"
  exit 0
fi
printf '%s\n' "$*" >"$MOCK_CLOUD2CODE_ARGS"
mkdir -p "$CLOUD2CODE_OUTPUT_DIR"
printf '{"resources":[{"mode":"managed","type":"aws_vpc","instances":[{}]}]}\n' >"$CLOUD2CODE_OUTPUT_DIR/terraform.tfstate"
MOCK
chmod +x "$TEST_ROOT/bin/cloud2code"
export MOCK_CLOUD2CODE_ARGS="$TEST_ROOT/partial-cloud2code-args"
printf '{"aws_region":"us-east-1","cloud2code_exclude":"aws_s3_bucket"}\n' \
  > "$TEST_ROOT/work/.wf-test/.work/cloud2code-inputs.json"
export CLOUD2CODE_EXCLUDE_OVERRIDE=aws_glue_catalog_table
if ! bash "$SCAN_SCRIPT" "wf-test" "us-east-1" > "$TEST_ROOT/exclude-override.out" 2>&1; then
  cat "$TEST_ROOT/exclude-override.out"
  fail "explicit exclusion override should complete scan"
fi
if ! grep -q -- '--exclude aws_glue_catalog_table' "$MOCK_CLOUD2CODE_ARGS"; then
  cat "$MOCK_CLOUD2CODE_ARGS"
  fail "explicit workflow exclusion did not override stale input exclusion"
fi
unset CLOUD2CODE_EXCLUDE_OVERRIDE

# A non-throttling per-resource Read failure should continue with any valid,
# non-empty partial state, even below the former coverage floor.
export MOCK_STATE_COUNT=2
cat > "$TEST_ROOT/bin/cloud2code" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then echo "0.5.6"; exit 0; fi
if [[ "$*" == *"get-supported-resources"* ]]; then
  echo " - aws_cloudwatch_log_group"
  exit 0
fi
if [[ "$*" != *"--allow-partial"* ]]; then
  echo "allow-partial was not enabled by default" >&2
  exit 2
fi
if [[ "$*" != *"--log-type=json"* ]]; then
  echo "structured JSON logging was not enabled" >&2
  exit 2
fi
mkdir -p "$CLOUD2CODE_OUTPUT_DIR"
count="${MOCK_STATE_COUNT:-2}"
if [ "$count" -gt 0 ]; then
  instances=""
  for ((i=0; i<count; i++)); do instances+="${instances:+,}{}"; done
  printf '{"resources":[{"mode":"managed","type":"aws_vpc","instances":[%s]}]}\n' "$instances" > "$CLOUD2CODE_OUTPUT_DIR/terraform.tfstate"
else
  printf '{"resources":[]}\n' > "$CLOUD2CODE_OUTPUT_DIR/terraform.tfstate"
fi
echo 'Error: could not import from aws: scan incomplete' >&2
echo "type aws_cloudwatch_log_group listed=10 imported=$count skipped=$((10-count)) permission_skipped=0 filtered=0 nil_state=0 read_failed=$((10-count))" >&2
echo "scan integrity: listed=10 imported=$count import_state_skipped=0 read_skipped=0 read_failed=$((10-count)) throttled_types=0" >&2
exit 1
MOCK
chmod +x "$TEST_ROOT/bin/cloud2code"
rm -f "$TEST_ROOT/work/.wf-test/.work/cloud2code-inputs.json"
if ! bash "$SCAN_SCRIPT" "wf-test" "us-east-1" > "$TEST_ROOT/partial.out" 2>&1; then
  cat "$TEST_ROOT/partial.out"
  fail "permission-skipped partial scan should continue by default"
fi
if ! grep -q 'cloud2code_scan_ok: "true"' "$TEST_ROOT/partial.out"; then
  cat "$TEST_ROOT/partial.out"
  fail "partial scan should be marked usable when one type has read_failed"
fi
if ! grep -q 'cloud2code_partial_scan: "true"' "$TEST_ROOT/partial.out"; then
  cat "$TEST_ROOT/partial.out"
  fail "partial scan must be clearly identified"
fi
if ! grep -q 'read_failed=8' "$TEST_ROOT/partial.out"; then
  cat "$TEST_ROOT/partial.out"
  fail "partial scan integrity counters were not emitted"
fi
if ! grep -q -- '--allow-partial' "$TEST_ROOT/work/.wf-test/.work/cloud2code-command.txt"; then
  fail "allow-partial was not enabled by default"
fi

# A read-failure-only scan with no successfully imported resources remains unusable.
export MOCK_STATE_COUNT=0
if bash "$SCAN_SCRIPT" "wf-test" "us-east-1" > "$TEST_ROOT/zero-import.out" 2>&1; then
  fail "partial scan with zero imported resources must block"
fi
if ! grep -q 'blocked:cloud2code_scan_failed: "true"' "$TEST_ROOT/zero-import.out"; then
  cat "$TEST_ROOT/zero-import.out"
  fail "zero-import partial scan did not block"
fi

# Explicit strict mode blocks even a usable non-empty partial state.
printf '{"cloud2code_allow_partial":"false"}\n' > "$TEST_ROOT/work/.wf-test/.work/cloud2code-inputs.json"
export MOCK_STATE_COUNT=2
if bash "$SCAN_SCRIPT" "wf-test" "us-east-1" > "$TEST_ROOT/strict.out" 2>&1; then
  fail "explicit strict scan should block read failures"
fi
if ! grep -q 'blocked:cloud2code_scan_failed: "true"' "$TEST_ROOT/strict.out"; then
  cat "$TEST_ROOT/strict.out"
  fail "explicit strict mode did not block the read failure"
fi
if grep -q -- '--allow-partial' "$TEST_ROOT/work/.wf-test/.work/cloud2code-command.txt"; then
  fail "explicit strict mode still enabled allow-partial"
fi

echo "PASS: test_cloud2code_aws_scan_throttle.sh"
