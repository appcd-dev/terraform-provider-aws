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
  else
    printf '{"aws_region":"us-east-1"}\n'
  fi
elif [[ "$*" == *"--arg k aws_region"* ]]; then
  echo "us-east-1"
elif [[ "$*" == *"--arg k cloud2code_allow_partial"* ]]; then
  if [ -f "$HOME/.wf-test/.work/cloud2code-inputs.json" ] && grep -q 'allow_partial.*true' "$HOME/.wf-test/.work/cloud2code-inputs.json"; then echo true; fi
elif [[ "$*" == *"--arg k"* ]]; then
  exit 0
elif [[ "$*" == *"length"* ]]; then
  echo "1"
elif [[ "$*" == *".resources"* ]]; then
  echo '{"resources":[{"mode":"managed","type":"aws_vpc","instances":[{}]}]}'
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


# Separate mock verifies the explicit opt-in reaches Cloud2Code and output is
# clearly labelled partial rather than represented as a complete inventory.
cat > "$TEST_ROOT/bin/cloud2code" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then echo "0.5.6"; exit 0; fi
if [[ "$*" == *"get-supported-resources"* ]]; then
  echo " - aws_cloudwatch_log_group"
  exit 0
fi
if [[ "$*" != *"--allow-partial"* ]]; then
  echo "allow-partial flag was not forwarded" >&2
  exit 2
fi
mkdir -p "$CLOUD2CODE_OUTPUT_DIR"
printf '{"resources":[{"mode":"managed","type":"aws_vpc","instances":[{}]}]}\n' > "$CLOUD2CODE_OUTPUT_DIR/terraform.tfstate"
echo 'scan integrity: listed=10 imported=9 import_state_skipped=0 read_skipped=0 read_failed=0 throttled_types=0' >&2
exit 0
MOCK
chmod +x "$TEST_ROOT/bin/cloud2code"
printf '{"cloud2code_allow_partial":"true"}\n' > "$TEST_ROOT/work/.wf-test/.work/cloud2code-inputs.json"
if ! bash "$SCAN_SCRIPT" "wf-test" "us-east-1" > "$TEST_ROOT/partial.out" 2>&1; then
  cat "$TEST_ROOT/partial.out"
  fail "explicit partial scan should run"
fi
if ! grep -q 'cloud2code_scan_ok: "true"' "$TEST_ROOT/partial.out"; then
  cat "$TEST_ROOT/partial.out"
  fail "explicit partial scan should complete when provider succeeds"
fi
if ! grep -q -- '--allow-partial' "$TEST_ROOT/work/.wf-test/.work/cloud2code-command.txt"; then
  fail "explicit allow-partial opt-in was not forwarded to Cloud2Code"
fi

echo "PASS: test_cloud2code_aws_scan_throttle.sh"
