#!/usr/bin/env bash
set -euo pipefail

# Args: $1 = workflow_run_id
# Refuse literal '{{workflow_run_id}}' (session b2177674); fall back to WORKFLOW_RUN_ID.
WF_ID_ARG="${1:-}"
resolve_workflow_run_id() {
  local id="${1:-}"
  case "$id" in
    '' | *'{{'* | *'}}'* | *'{'* | *'}'*)
      id="${WORKFLOW_RUN_ID:-}"
      ;;
  esac
  case "$id" in
    '' | *'{{'* | *'}}'* | *'{'* | *'}'*)
      return 1
      ;;
  esac
  printf '%s' "$id"
}

if ! WF_ID="$(resolve_workflow_run_id "$WF_ID_ARG")"; then
  echo 'blocked:remote_runner_workflow_run_id_unresolved: "true"'
  echo "preflight_workflow_run_id_arg=${WF_ID_ARG:-<empty>}"
  echo "hint=replace {{workflow_run_id}} with the real id from the stagerunner [Workflow execution] header"
  exit 1
fi
export WORKFLOW_RUN_ID="$WF_ID"

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
echo "preflight_workflow_run_id=$WF_ID"

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

# SCM github vault sync exposes `token`, not GIT_TOKEN (session 8da4f049).
# Alias into git/gh env and install a durable credential helper so later
# execute_series shells (including hand-rolled git clone) can authenticate.
# Prefer $HOME/.aws-migrator/bin — $HOME/.local/bin is often not writable on ACA
# (session 6dac05f9: Permission denied).
_git_tok="${GIT_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-${token:-}}}}"
if [ -n "$_git_tok" ]; then
  export GIT_TOKEN="$_git_tok" GH_TOKEN="${GH_TOKEN:-$_git_tok}" GITHUB_TOKEN="${GITHUB_TOKEN:-$_git_tok}"
  export GIT_TERMINAL_PROMPT=0
  _cred_dir="${HOME}/.aws-migrator/bin"
  mkdir -p "$_cred_dir"
  cat >"${_cred_dir}/git-credential-stackgen" <<'GCEOF'
#!/bin/sh
case "$1" in
get)
  tok="${GIT_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-${token:-}}}}"
  [ -n "$tok" ] || exit 0
  printf "username=x-access-token\npassword=%s\n" "$tok"
  ;;
esac
GCEOF
  chmod 0755 "${_cred_dir}/git-credential-stackgen"
  git config --global credential.helper "${_cred_dir}/git-credential-stackgen"
  unset _cred_dir
fi
unset _git_tok

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

if [ ! -d "$SCRIPT_PACK_DIR" ] || [ ! -f "$SCRIPT_PACK_DIR/stage-runner.sh" ] || [ ! -f "$SCRIPT_PACK_DIR/ingest-bootstrap.sh" ] || [ ! -f "$SCRIPT_PACK_DIR/iac-pr-bootstrap.sh" ] || [ ! -f "$SCRIPT_PACK_DIR/converge-bootstrap.sh" ] || [ ! -f "$SCRIPT_PACK_DIR/cloud2code-aws-scan.sh" ] || [ ! -f "$SCRIPT_PACK_DIR/run-destination-stage.sh" ] || [ ! -x "$SCRIPT_PACK_DIR/pack-entry.sh" ]; then
  emit_blocked "blocked:remote_runner_script_pack_missing" "script_pack_missing"
fi

mirror_note "runner_capability_preflight_ok" "true"
mirror_note "script_pack_ready" "true"
mirror_note "stage_summary:runner-capability-preflight" "ok"
mirror_note "script_pack_preload_dir" "$SCRIPT_PACK_DIR"
echo 'runner_capability_preflight_ok: "true"'
echo 'script_pack_ready: "true"'
echo "script_pack_preload_dir=$SCRIPT_PACK_DIR"
echo 'stage_summary:runner-capability-preflight=ok'
