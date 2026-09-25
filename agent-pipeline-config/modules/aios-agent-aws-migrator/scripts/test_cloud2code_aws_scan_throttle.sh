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
# Mock jq to always return something valid for resources
if [[ "$*" == *".resources"* ]]; then
  echo '{"resources":[{"mode":"managed","type":"aws_vpc","instances":[{}]}]}'
else
  # Pass-through or mock notes handling
  if [[ "$1" == "--arg" ]]; then
    # Fake notes insertion
    echo "{}"
  else
    echo "1"
  fi
fi
MOCK
cat > "$TEST_ROOT/bin/aws" << 'MOCK'
#!/usr/bin/env bash
echo '{"UserId":"mock","Account":"123","Arn":"mock"}'
MOCK
cat > "$TEST_ROOT/bin/cloud2code" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"get-supported-resources"* ]]; then
  echo " - aws_cloudwatch_log_group"
  echo " - aws_alb"
  exit 0
fi

# The mock state file
mkdir -p "$CLOUD2CODE_OUTPUT_DIR"
touch "$CLOUD2CODE_OUTPUT_DIR/terraform.tfstate"

# Fail first time with rate limit, then succeed if excluded
if [[ "$*" != *"--exclude aws_cloudwatch_log_group"* ]]; then
  echo "Error: could not import from aws: scan aborted due to API rate limiting: error while reading the resources of type: aws_cloudwatch_log_group: ThrottlingException: Rate exceeded" >&2
  exit 1
else
  echo "Success" >&2
  exit 0
fi
MOCK

chmod +x "$TEST_ROOT/bin/"*

# Speed up test backoffs
export CLOUD2CODE_THROTTLE_BACKOFF_SECONDS=1

echo "Testing cloud2code throttle auto-exclude..."
bash "$SCAN_SCRIPT" "wf-test" "us-east-1" > "$TEST_ROOT/scan.out" 2>&1 || true

cat "$TEST_ROOT/scan.out"

if ! grep -q "cloud2code_throttle_skipped=aws_cloudwatch_log_group" "$TEST_ROOT/scan.out"; then
  fail "Did not output throttle skipped sentinel"
fi
if ! grep -q "cloud2code_scan_ok: \"true\"" "$TEST_ROOT/scan.out"; then
  fail "Scan did not succeed after exclude"
fi

echo "PASS: test_cloud2code_aws_scan_throttle.sh"
