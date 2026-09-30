#!/usr/bin/env bash
# Survive the remote-runner execute_* default timeout.
#
# Guild/aiden-runner shell tools default to 30s when the agent omits
# timeout_seconds, then SIGKILL the whole process group (Setpgid). A us-east-1
# cloud2code import cannot finish in that window, and a same-group background
# child dies with the parent. This wrapper double-forks into its own session
# (setsid when present) so the import keeps writing state after the tool call
# is killed.
#
# Re-invoking the wrapper is the resume path. It does not start a second import
# for the same workflow. It reports running, or replays the scan script stdout
# once that import has exited.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_SCRIPT="${SCRIPT_DIR}/cloud2code-aws-scan.sh"

# Leave headroom under a 30s tool timeout so status is flushed before SIGKILL.
# A caller that set timeout_seconds=3600 must block until the import exits
# inside that call. Returning cloud2code_scan_running after 20s made the scan
# loop finish on a live pid (session 3b08e860).
CALL_BUDGET="${CLOUD2CODE_SCAN_CALL_BUDGET_SECONDS:-20}"
case "$CALL_BUDGET" in
  ''|*[!0-9]*) CALL_BUDGET=20 ;;
esac

WF_ID_ARG="${1:-}"
AWS_REGION_ARG="${2:-}"
RUNNER_WORK_HOME="${RUNNER_WORK_HOME:-${HOME:-/home/runner}}"

# shellcheck source=workflow-run-id.sh
. "${SCRIPT_DIR}/workflow-run-id.sh"

if ! WF_ID="$(resolve_workflow_run_id "$WF_ID_ARG")"; then
  echo 'blocked:cloud2code_workflow_run_id_unresolved: "true"'
  echo "cloud2code_workflow_run_id_arg=${WF_ID_ARG:-<empty>}"
  echo "hint=pass the stagerunner workflow id (wf-aws-cloud-discovery-<hex>) or export WORKFLOW_RUN_ID; do not pass a path or an unexpanded {{workflow_run_id}}"
  exit 1
fi

if [ ! -f "$SCAN_SCRIPT" ]; then
  echo 'blocked:remote_runner_script_pack_missing: "true"'
  echo "cloud2code_scan_script_missing=${SCAN_SCRIPT}"
  exit 1
fi

WORK_ROOT="${RUNNER_WORK_HOME}/.${WF_ID}"
WORK_DIR="${WORK_ROOT}/.work"
PID_FILE="${WORK_DIR}/cloud2code-scan.pid"
STDOUT_LOG="${WORK_DIR}/cloud2code-scan.stdout"
FINGERPRINT_FILE="${WORK_DIR}/cloud2code-scan.fingerprint"
LOCK_DIR="${WORK_DIR}/cloud2code-scan.lock"

mkdir -p "$WORK_DIR" "$WORK_ROOT/cloud2code" "$WORK_ROOT/state" || {
  echo 'blocked:cloud2code_scan_detach_unavailable: "true"'
  echo "cloud2code_work_root_unwritable=${WORK_ROOT}"
  exit 1
}
chmod 700 "$WORK_ROOT" 2>/dev/null || true

fingerprint="$(printf '%s|%s|%s|%s|%s' \
  "$WF_ID" \
  "${AWS_REGION_ARG:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}" \
  "${CLOUD2CODE_EXCLUDE:-}" \
  "${CLOUD2CODE_INCLUDE:-}" \
  "${CLOUD2CODE_TAGS:-}")"

pid_alive() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

read_pid() {
  [ -f "$PID_FILE" ] || return 1
  tr -cd '0-9' <"$PID_FILE"
}

release_lock() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
  local tries=0 holder
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    holder="$(read_pid || true)"
    if [ "$tries" -ge 50 ]; then
      # A killed holder can leave the directory. Reclaim only if no scan is live.
      if [ -n "$holder" ] && pid_alive "$holder"; then
        echo "cloud2code_scan_lock=busy pid=${holder}"
        return 1
      fi
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
    sleep 0.1
  done
  return 0
}

emit_running() {
  local pid="${1:-}"
  echo 'cloud2code_scan_running: "true"'
  echo "cloud2code_scan_pid=${pid}"
  echo "cloud2code_workflow_run_id=${WF_ID}"
  echo "cloud2code_work_root=${WORK_ROOT}"
  echo "cloud2code_scan_stdout=${STDOUT_LOG}"
  echo "cloud2code_scan_resume=re-paste the same scan command; do not start a second import"
  if [ -f "${WORK_DIR}/cloud2code.log" ]; then
    echo "cloud2code_log_tail_begin"
    tail -n 20 "${WORK_DIR}/cloud2code.log" 2>/dev/null || true
    echo "cloud2code_log_tail_end"
  fi
}

stdout_is_terminal() {
  [ -s "$STDOUT_LOG" ] || return 1
  grep -q 'cloud2code_scan_ok: "true"\|blocked:cloud2code_' "$STDOUT_LOG" 2>/dev/null
}

replay_stdout() {
  if stdout_is_terminal || [ -s "$STDOUT_LOG" ]; then
    cat "$STDOUT_LOG"
    return 0
  fi
  echo 'blocked:cloud2code_scan_failed: "true"'
  echo "cloud2code_scan_detached_finished_without_stdout=${STDOUT_LOG}"
  return 1
}

spawn_detached() {
  : >"$STDOUT_LOG" || return 1
  # Reparenting is not enough: Guild shellutils kills the execute_* process
  # group. setsid (util-linux, installed in the runner image) starts a new
  # session before the scan script runs. A forked setsid is not a process-group
  # leader, so the call succeeds and the recorded pid survives the tool timeout.
  if ! command -v setsid >/dev/null 2>&1; then
    echo 'blocked:cloud2code_scan_detach_unavailable: "true"'
    echo "hint=setsid is missing; set timeout_seconds to the stage budget (3600) on execute_series so the import is not SIGKILLed at 30s"
    return 1
  fi
  setsid bash "$SCAN_SCRIPT" "$WF_ID" "$AWS_REGION_ARG" >"$STDOUT_LOG" 2>&1 &
  local leader="$!"
  printf '%s\n' "$leader" >"$PID_FILE"
  printf '%s\n' "$fingerprint" >"$FINGERPRINT_FILE"
  # Drop the job so this shell exiting cannot SIGHUP the new session.
  disown "$leader" 2>/dev/null || true

  local tries=0
  while [ "$tries" -lt 25 ]; do
    if pid_alive "$leader"; then
      echo "cloud2code_scan_detached=true pid=${leader}"
      return 0
    fi
    if [ -s "$STDOUT_LOG" ]; then
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done

  # Exited before we observed it (missing region, missing binary, or a tiny
  # account). Replay the scan script's own sentinels.
  if [ -s "$STDOUT_LOG" ]; then
    cat "$STDOUT_LOG"
    return 0
  fi
  echo 'blocked:cloud2code_scan_detach_unavailable: "true"'
  echo "cloud2code_scan_spawn_failed=leader_not_alive"
  return 1
}

existing="$(read_pid || true)"
if stdout_is_terminal && { [ -z "$existing" ] || ! pid_alive "$existing"; }; then
  replay_stdout
  exit $?
fi

if ! acquire_lock; then
  existing="$(read_pid || true)"
  emit_running "$existing"
  exit 0
fi
trap release_lock EXIT

existing="$(read_pid || true)"
if [ -n "$existing" ] && pid_alive "$existing"; then
  stored="$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)"
  if [ -n "$stored" ] && [ "$stored" != "$fingerprint" ]; then
    echo 'blocked:cloud2code_scan_already_running: "true"'
    echo "cloud2code_scan_pid=${existing}"
    echo "cloud2code_scan_fingerprint_mismatch=true"
    echo "hint=a scan with different region/include/exclude/tags is still running for this workflow; wait for it or use a new workflow_run_id"
    exit 1
  fi
  echo "cloud2code_scan_detached_already_running=true pid=${existing}"
else
  if ! spawn_detached; then
    exit 1
  fi
  # spawn_detached replays and returns 0 when the import already exited.
  if ! pid_alive "$(read_pid || true)"; then
    exit 0
  fi
  existing="$(read_pid || true)"
fi

deadline=$((SECONDS + CALL_BUDGET))
while pid_alive "$existing"; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    emit_running "$existing"
    exit 0
  fi
  sleep 1
done

replay_stdout
exit $?
