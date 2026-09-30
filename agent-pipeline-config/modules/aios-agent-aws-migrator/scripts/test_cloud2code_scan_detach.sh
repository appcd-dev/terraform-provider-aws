#!/usr/bin/env bash
# Detach wrapper: a short caller must not kill the import, and a second call
# must resume the same pid instead of starting another scan.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETACH="$SCRIPT_DIR/cloud2code-scan-detach.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home" "$TEST_ROOT/pack"
cp "$SCRIPT_DIR/workflow-run-id.sh" "$TEST_ROOT/pack/workflow-run-id.sh"
export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
export HOME="$TEST_ROOT/home"
export RUNNER_WORK_HOME="$TEST_ROOT/home"
export CLOUD2CODE_SCAN_CALL_BUDGET_SECONDS=1

cat >"$TEST_ROOT/bin/setsid" <<'EOF'
#!/usr/bin/env bash
# Record that the wrapper asked for a new session, then run the child.
echo "$$" >"${SETSID_PID_FILE:?}"
exec "$@"
EOF
chmod +x "$TEST_ROOT/bin/setsid"
export SETSID_PID_FILE="$TEST_ROOT/setsid.pid"

cat >"$TEST_ROOT/pack/cloud2code-aws-scan.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "scan_argv3_unused=${3:-}"
echo "exclude=${CLOUD2CODE_EXCLUDE:-}"
echo "region=${2:-}"
sleep "${MOCK_SCAN_SLEEP:-3}"
echo 'cloud2code_scan_ok: "true"'
echo "cloud2code_tfstate_path=/tmp/terraform.tfstate"
exit 0
EOF
chmod +x "$TEST_ROOT/pack/cloud2code-aws-scan.sh"
cp "$DETACH" "$TEST_ROOT/pack/cloud2code-scan-detach.sh"
chmod +x "$TEST_ROOT/pack/cloud2code-scan-detach.sh"

out1="$(CLOUD2CODE_EXCLUDE=aws_glue_catalog_table bash "$TEST_ROOT/pack/cloud2code-scan-detach.sh" wf-detach-test us-east-1)"
printf '%s\n' "$out1" | grep -q 'cloud2code_scan_running: "true"' || fail "first call did not report running: $out1"
printf '%s\n' "$out1" | grep -q 'cloud2code_scan_detached=true' || fail "first call did not detach: $out1"
pid="$(printf '%s\n' "$out1" | sed -n 's/^cloud2code_scan_pid=//p' | head -1)"
[ -n "$pid" ] || fail "missing pid"
kill -0 "$pid" 2>/dev/null || fail "detached pid $pid is not alive"

out2="$(CLOUD2CODE_EXCLUDE=aws_glue_catalog_table bash "$TEST_ROOT/pack/cloud2code-scan-detach.sh" wf-detach-test us-east-1)"
printf '%s\n' "$out2" | grep -q 'cloud2code_scan_detached_already_running=true' || fail "second call started a new scan: $out2"
printf '%s\n' "$out2" | grep -q "cloud2code_scan_pid=${pid}" || fail "second call lost pid $pid: $out2"

mismatch="$(CLOUD2CODE_EXCLUDE=aws_s3_bucket bash "$TEST_ROOT/pack/cloud2code-scan-detach.sh" wf-detach-test us-east-1 || true)"
printf '%s\n' "$mismatch" | grep -q 'blocked:cloud2code_scan_already_running: "true"' || fail "fingerprint mismatch was not blocked: $mismatch"

# Wait out the mock import and confirm the replay includes the real sentinel.
for _ in 1 2 3 4 5 6 7 8; do
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 1
done
out3="$(CLOUD2CODE_EXCLUDE=aws_glue_catalog_table bash "$TEST_ROOT/pack/cloud2code-scan-detach.sh" wf-detach-test us-east-1)"
printf '%s\n' "$out3" | grep -q 'cloud2code_scan_ok: "true"' || fail "finished scan was not replayed: $out3"
printf '%s\n' "$out3" | grep -q 'exclude=aws_glue_catalog_table' || fail "exclude was not forwarded to the detached scan: $out3"

# pack-entry must pass argv 3 into CLOUD2CODE_EXCLUDE before detach.
entry="$SCRIPT_DIR/pack-entry.sh"
if ! grep -q 'export CLOUD2CODE_EXCLUDE="${_scan_exclude}"' "$entry"; then
  fail "pack-entry does not export the scan exclude argument"
fi

bad="$(WORKFLOW_RUN_ID= bash "$TEST_ROOT/pack/cloud2code-scan-detach.sh" '/tmp/not-a-workflow' us-east-1 || true)"
printf '%s\n' "$bad" | grep -q 'blocked:cloud2code_workflow_run_id_unresolved: "true"' || fail "path workflow id was accepted: $bad"
dotted="$(WORKFLOW_RUN_ID= bash "$TEST_ROOT/pack/cloud2code-scan-detach.sh" 'wf-aws.cloud' us-east-1 || true)"
printf '%s\n' "$dotted" | grep -q 'blocked:cloud2code_workflow_run_id_unresolved: "true"' || fail "dotted workflow id was accepted: $dotted"
placeholder="$(bash "$TEST_ROOT/pack/cloud2code-scan-detach.sh" '{{workflow_run_id}}' us-east-1 || true)"
printf '%s\n' "$placeholder" | grep -q 'blocked:cloud2code_workflow_run_id_unresolved: "true"' || fail "placeholder workflow id was accepted: $placeholder"
good="$(WORKFLOW_RUN_ID=wf-aws-cloud-discovery-abc bash "$TEST_ROOT/pack/cloud2code-scan-detach.sh" '{{workflow_run_id}}' us-east-1 || true)"
printf '%s\n' "$good" | grep -q 'cloud2code_scan_running: "true"' || fail "env fallback did not accept a real id: $good"

echo "PASS: test_cloud2code_scan_detach.sh"
