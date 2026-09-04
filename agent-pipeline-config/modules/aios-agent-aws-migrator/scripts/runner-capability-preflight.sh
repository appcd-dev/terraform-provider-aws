#!/usr/bin/env bash
set -euo pipefail

# Args: $1 = workflow_run_id
WF_ID="${1:?workflow_run_id required}"

# Prefer the directory this script lives in (script pack), then env, then default.
SCRIPT_PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_WORK_HOME="${RUNNER_WORK_HOME:-/home/runner}"

export HOME="$RUNNER_WORK_HOME"
ABS_WORK_ROOT="${RUNNER_WORK_HOME}/.${WF_ID}"
WORK_ROOT="$ABS_WORK_ROOT"
NOTES_JSON="$WORK_ROOT/notes.json"

mkdir -p "$WORK_ROOT/.work"
chmod 700 "$WORK_ROOT" 2>/dev/null || true
[ -f "$NOTES_JSON" ] || echo '{}' >"$NOTES_JSON"

mirror_note() {
  local key="${1:?KEY}"
  local value="${2:-}"
  local tmp
  tmp="$(mktemp "${NOTES_JSON}.XXXXXX")"
  jq --arg k "$key" --arg v "$value" '. + {($k): $v}' "$NOTES_JSON" >"$tmp" \
    && mv "$tmp" "$NOTES_JSON"
}

emit_blocked() {
  local sentinel="${1:?SENTINEL}"
  local summary="${2:-$sentinel}"
  if command -v jq >/dev/null 2>&1 && [ -f "$NOTES_JSON" ]; then
    mirror_note "$sentinel" "true"
    mirror_note "stage_summary:runner-capability-preflight" "blocked:$summary"
  fi
  echo "${sentinel}: \"true\""
  echo "stage_summary:runner-capability-preflight=blocked:$summary"
  exit 1
}

# jq is required for note mirroring; fail first if absent (cannot mirror_note).
if ! command -v jq >/dev/null 2>&1; then
  echo 'blocked:remote_runner_jq_missing: "true"'
  echo 'stage_summary:runner-capability-preflight=blocked:jq_missing'
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  emit_blocked "blocked:remote_runner_awscli_missing" "awscli_missing"
fi

if ! command -v python3 >/dev/null 2>&1; then
  emit_blocked "blocked:remote_runner_python3_missing" "python3_missing"
fi

if ! command -v git >/dev/null 2>&1; then
  emit_blocked "blocked:remote_runner_git_missing" "git_missing"
fi

if ! command -v tofu >/dev/null 2>&1 && ! command -v terraform >/dev/null 2>&1; then
  emit_blocked "blocked:remote_runner_tofu_missing" "tofu_missing"
fi

if ! command -v opa >/dev/null 2>&1; then
  emit_blocked "blocked:remote_runner_opa_missing" "opa_missing"
fi

# Prefer pack-local ensure_cloud2code.sh (same directory as this script).
if [ -f "$SCRIPT_PACK_DIR/ensure_cloud2code.sh" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_PACK_DIR/ensure_cloud2code.sh"
fi

if ! ensure_cloud2code; then
  emit_blocked "blocked:remote_runner_cloud2code_missing" "cloud2code_install_failed"
fi

if [ ! -d "$SCRIPT_PACK_DIR" ] || [ ! -f "$SCRIPT_PACK_DIR/stage-runner.sh" ] || [ ! -f "$SCRIPT_PACK_DIR/ingest-bootstrap.sh" ] || [ ! -f "$SCRIPT_PACK_DIR/run-destination-stage.sh" ]; then
  emit_blocked "blocked:remote_runner_script_pack_missing" "script_pack_missing"
fi

mirror_note "runner_capability_preflight_ok" "true"
mirror_note "stage_summary:runner-capability-preflight" "ok"
mirror_note "script_pack_preload_dir" "$SCRIPT_PACK_DIR"
echo 'runner_capability_preflight_ok: "true"'
echo "script_pack_preload_dir=$SCRIPT_PACK_DIR"
echo 'stage_summary:runner-capability-preflight=ok'
