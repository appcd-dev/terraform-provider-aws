#!/usr/bin/env bash
# aws-migrator stage runner — invoke ONLY via _embed_dbsplit_run (DBSPLIT_EMBEDDED=1).
# Direct `bash $WORK_ROOT/scripts/stage-runner.sh` is rejected (agent script drift).
# Usage: DBSPLIT_EMBEDDED=1 bash -s <command> [args...] << 'DBSPLIT_STAGE_RUNNER' ... DBSPLIT_STAGE_RUNNER
set -euo pipefail

SCRIPT_PACK_VERSION="20260930.06"
DBSPLIT_DEFAULT_STRATEGY="${DBSPLIT_DEFAULT_STRATEGY:-tfstate_monolith_decomposer}"
DBSPLIT_DEFAULT_CAP="${DBSPLIT_DEFAULT_CAP:-0}"
REQUIRED_ALLOCATE_MARKER="def merge_small_by_seed"
REQUIRED_DECOMPOSER_MARKER="def cmd_layered_split"
DBSPLIT_MAX_TUNING_ITERATIONS="${DBSPLIT_MAX_TUNING_ITERATIONS:-10}"
DBSPLIT_RUN_TTL_HOURS="${DBSPLIT_RUN_TTL_HOURS:-48}"
# Age alone does not bound disk: a day of back-to-back runs leaves every work
# root inside the TTL while each one holds provider plugins and per-group state
# worth several GB, which evicts the runner for ephemeral-storage pressure.
DBSPLIT_RUN_KEEP="${DBSPLIT_RUN_KEEP:-3}"
DBSPLIT_LOCK_TIMEOUT_SECONDS="${DBSPLIT_LOCK_TIMEOUT_SECONDS:-60}"
DBSPLIT_LOCK_STALE_SECONDS="${DBSPLIT_LOCK_STALE_SECONDS:-1800}"
# Converge visits must finish inside the nile-runner 30m result-wait window
# (trace 1c64c4a5: a full 83-group hydrate overran the tool call, so the result
# spilled and the visit was re-run concurrently, racing .git/index.lock). The
# matrix defers remaining groups and emits converge_batch_incomplete so the
# loop resumes on the next visit instead of losing the whole batch.
DBSPLIT_HYDRATE_VISIT_BUDGET_SECONDS="${DBSPLIT_HYDRATE_VISIT_BUDGET_SECONDS:-1200}"
# tfstate is committed to the discovery PR (user requirement) — the repo
# .gitignore allowlists aws/** tfstate, but keep force-add so a stale clone
# ignore rule can never silently drop the monolith or shards again.
DBSPLIT_GIT_FORCE_ADD_TFSTATE="${DBSPLIT_GIT_FORCE_ADD_TFSTATE:-1}"

mark_run_activity() {
  local work_root="${1:?WORK_ROOT}"
  mkdir -p "$work_root"
  touch "${work_root}/.last_touch" 2>/dev/null || true
}

mark_run_active() {
  local work_root="${1:?WORK_ROOT}"
  mkdir -p "${work_root}/.work/locks"
  chmod 700 "$work_root" 2>/dev/null || true
  touch "${work_root}/.stackgen-run-root" "${work_root}/.active" "${work_root}/.last_touch" 2>/dev/null || true
}

mark_run_complete() {
  local work_root="${1:?WORK_ROOT}"
  mkdir -p "$work_root"
  rm -f "${work_root}/.active" 2>/dev/null || true
  touch "${work_root}/.complete" "${work_root}/.last_touch" 2>/dev/null || true
}

mtime_epoch() {
  local path="${1:?PATH}"
  stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo 0
}

try_reclaim_run_lock() {
  local lock_dir="${1:?LOCK_DIR}" name="${2:?LOCK_NAME}"
  local now lock_mtime holder_pid guard quarantine
  guard="${lock_dir}.reclaim-guard"
  # Serialize reclaimers and re-read owner metadata under the guard. This keeps
  # two contenders from both deciding that the same lock is stale. The guard
  # also has an owner so SIGKILL cannot strand recovery indefinitely.
  if ! mkdir "$guard" 2>/dev/null; then
    local guard_pid guard_mtime guard_quarantine
    guard_pid="$(sed -n 's/^pid=//p' "${guard}/holder" 2>/dev/null | head -1 | tr -d '[:space:]')"
    guard_mtime="$(mtime_epoch "$guard")"
    if [ -n "$guard_pid" ] && [[ "$guard_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$guard_pid" 2>/dev/null; then
      guard_quarantine="${guard}.reclaim.$$.$(date +%s)"
      if mv "$guard" "$guard_quarantine" 2>/dev/null; then
        rm -rf "$guard_quarantine" 2>/dev/null || true
      fi
    elif [ -z "$guard_pid" ] && [ "$guard_mtime" -gt 0 ] && \
      [ $(( $(date +%s) - guard_mtime )) -gt "$DBSPLIT_LOCK_STALE_SECONDS" ]; then
      guard_quarantine="${guard}.reclaim.$$.$(date +%s)"
      if mv "$guard" "$guard_quarantine" 2>/dev/null; then
        rm -rf "$guard_quarantine" 2>/dev/null || true
      fi
    fi
    mkdir "$guard" 2>/dev/null || return 1
  fi
  printf 'pid=%s\n' "$$" >"${guard}/holder" 2>/dev/null || true
  now="$(date +%s)"
  lock_mtime="$(mtime_epoch "$lock_dir")"
  holder_pid=""
  if [ -f "${lock_dir}/holder" ]; then
    holder_pid="$(sed -n 's/^pid=//p' "${lock_dir}/holder" 2>/dev/null | head -1 | tr -d '[:space:]')"
  fi

  if [ -n "$holder_pid" ] && [[ "$holder_pid" =~ ^[0-9]+$ ]]; then
    # A valid live owner is never evicted based on age. PID reuse is
    # conservative (it can delay recovery, never steal a live lock).
    if kill -0 "$holder_pid" 2>/dev/null; then
      rmdir "$guard" 2>/dev/null || true
      return 1
    fi
    quarantine="${lock_dir}.reclaim.$$.$now"
    if mv "$lock_dir" "$quarantine" 2>/dev/null; then
      echo "lock_reclaimed=dead_holder name=${name} pid=${holder_pid} path=${lock_dir}" >&2
      rm -rf "$quarantine" 2>/dev/null || true
      rmdir "$guard" 2>/dev/null || true
      return 0
    fi
  elif [ "$lock_mtime" -gt 0 ] && [ $((now - lock_mtime)) -gt "$DBSPLIT_LOCK_STALE_SECONDS" ]; then
    # Missing/corrupt owner record can only be reclaimed after the long TTL.
    # Never use a short age-only grace: a contender may be between mkdir and
    # writing holder, and stealing that lock can overlap a live writer.
    quarantine="${lock_dir}.reclaim.$$.$now"
    if mv "$lock_dir" "$quarantine" 2>/dev/null; then
      echo "lock_reclaimed=stale_unowned name=${name} age=$((now - lock_mtime))s path=${lock_dir}" >&2
      rm -rf "$quarantine" 2>/dev/null || true
      rmdir "$guard" 2>/dev/null || true
      return 0
    fi
  fi
  rmdir "$guard" 2>/dev/null || true
  return 1
}

acquire_run_lock() {
  local work_root="${1:?WORK_ROOT}"
  local name="${2:?LOCK_NAME}"
  local lock_root="${work_root}/.work/locks"
  local lock_dir="${lock_root}/${name}.lock"
  local start now
  mkdir -p "$lock_root"
  start="$(date +%s)"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    now="$(date +%s)"
    # SIGKILL/OOM: holder never runs release_run_lock. Reclaim only after
    # atomically serializing contenders and re-checking owner metadata.
    if try_reclaim_run_lock "$lock_dir" "$name"; then
      continue
    fi
    if [ $((now - start)) -ge "$DBSPLIT_LOCK_TIMEOUT_SECONDS" ]; then
      echo "lock_error=timeout name=${name} path=${lock_dir}" >&2
      echo "blocked:split_lock_timeout: \"true\"" >&2
      return 1
    fi
    sleep 1
  done
  printf 'pid=%s\ncreated_at=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${lock_dir}/holder" 2>/dev/null || true
  printf '%s' "$lock_dir"
}

release_run_lock() {
  local lock_dir="${1:-}"
  if [ -n "$lock_dir" ]; then
    rm -rf "$lock_dir" 2>/dev/null || true
  fi
}

# A converge visit killed at the nile-runner 30m tool timeout can die mid
# `git add`/`git commit` and leave .git/index.lock behind; the next visit then
# fails with "Unable to create '.git/index.lock': File exists" (trace 1c64c4a5).
# Remove it only when no live git process is running in this clone.
clear_stale_git_index_lock() {
  local repo_dir="${1:-$(pwd)}"
  local lock_file="${repo_dir}/.git/index.lock"
  if [ ! -f "$lock_file" ]; then
    return 0
  fi
  if pgrep -x git >/dev/null 2>&1; then
    echo "git_index_lock=busy path=${lock_file}" >&2
    return 0
  fi
  rm -f "$lock_file" 2>/dev/null || true
  echo "git_index_lock_cleared=stale path=${lock_file}"
}

mirror_note() {
  local work_root="${1:?WORK_ROOT}"
  local key="${2:?KEY}"
  # Allow empty values (${3:?} rejects null). Session c38ad01b: after a killed
  # split, count_reconciliation_ok was empty and aborted with "3: VALUE".
  local value="${3-}"
  local notes="${work_root}/notes.json"
  local lock tmp rc
  mkdir -p "$work_root"
  mark_run_activity "$work_root"
  lock="$(acquire_run_lock "$work_root" "notes")" || return 1
  [ -f "$notes" ] || echo '{}' >"$notes"
  tmp="$(mktemp "${notes}.XXXXXX")"
  if jq --arg k "$key" --arg v "$value" '. + {($k): $v}' "$notes" >"$tmp"; then
    mv "$tmp" "$notes"
    rc=0
  else
    rm -f "$tmp"
    rc=1
  fi
  release_run_lock "$lock"
  return "$rc"
}

read_note() {
  local work_root="${1:?WORK_ROOT}"
  local key="${2:?KEY}"
  local notes="${work_root}/notes.json"
  [ -f "$notes" ] || return 1
  jq -r --arg k "$key" '.[$k] // empty' "$notes"
}

note_or_default() {
  local work_root="${1:?WORK_ROOT}"
  local key="${2:?KEY}"
  local default="${3:?DEFAULT}"
  local val
  val="$(read_note "$work_root" "$key" 2>/dev/null || true)"
  if [ -n "$val" ]; then
    printf '%s' "$val"
    return 0
  fi
  printf '%s' "$default"
}

_runner_dir() {
  cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || printf '%s' "."
}

sha256_file() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

require_embedded_invocation() {
  if [ "${DBSPLIT_EMBEDDED:-}" = "1" ]; then
    return 0
  fi
  if [ "${DBSPLIT_ALLOW_DIRECT:-}" = "1" ]; then
    return 0
  fi
  local sibling="${1:-$(_runner_dir)/allocate_manifest.py}"
  if [ -f "$sibling" ] && grep -q "$REQUIRED_ALLOCATE_MARKER" "$sibling" 2>/dev/null; then
    return 0
  fi
  echo "script_pack_error=invoke_via_embed_dbsplit_run_set_DBSPLIT_EMBEDDED=1" >&2
  return 1
}

verify_allocate_manifest_py() {
  local py_path="${1:?PY}"
  if [ ! -f "$py_path" ]; then
    echo "script_pack_error=missing_allocate_manifest path=${py_path}" >&2
    return 1
  fi
  if ! grep -q "$REQUIRED_ALLOCATE_MARKER" "$py_path" 2>/dev/null; then
    echo "script_pack_error=stale_allocate_manifest_missing_merge_small_by_seed" >&2
    return 1
  fi
  if [ -n "${DBSPLIT_ALLOCATE_SHA256:-}" ]; then
    local actual expected="${DBSPLIT_ALLOCATE_SHA256}"
    actual="$(sha256_file "$py_path")"
    if [ "$actual" != "$expected" ]; then
      echo "script_pack_error=allocate_sha256_mismatch expected=${expected} actual=${actual}" >&2
      return 1
    fi
  fi
  return 0
}

verify_decomposer_py() {
  local py_path="${1:?PY}"
  if [ ! -f "$py_path" ]; then
    echo "script_pack_error=missing_tfstate_monolith_decomposer path=${py_path}" >&2
    return 1
  fi
  if ! grep -q "$REQUIRED_DECOMPOSER_MARKER" "$py_path" 2>/dev/null; then
    echo "script_pack_error=stale_tfstate_monolith_decomposer_missing_cmd_layered_split" >&2
    return 1
  fi
  if [ -n "${DBSPLIT_DECOMPOSER_SHA256:-}" ]; then
    local actual expected="${DBSPLIT_DECOMPOSER_SHA256}"
    actual="$(sha256_file "$py_path")"
    if [ "$actual" != "$expected" ]; then
      echo "script_pack_error=decomposer_sha256_mismatch expected=${expected} actual=${actual}" >&2
      return 1
    fi
  fi
  return 0
}

write_script_pack_stamp() {
  local work_root="${1:?WORK_ROOT}"
  local py_path="${work_root}/scripts/allocate_manifest.py"
  local decomposer_path="${work_root}/scripts/tfstate_monolith_decomposer.py"
  mkdir -p "${work_root}/scripts"
  printf '%s\n' "$SCRIPT_PACK_VERSION" >"${work_root}/scripts/.script_pack_version"
  if [ -f "$py_path" ]; then
    sha256_file "$py_path" >"${work_root}/scripts/.allocate_sha256"
  fi
  if [ -f "$decomposer_path" ]; then
    sha256_file "$decomposer_path" >"${work_root}/scripts/.decomposer_sha256"
  fi
  mirror_note "$work_root" "script_pack_version" "$SCRIPT_PACK_VERSION"
}

resolve_allocate_py() {
  local work_root="${1:?WORK_ROOT}"
  local dest="${work_root}/scripts/allocate_manifest.py"
  mkdir -p "$(dirname "$dest")"

  if [ -f "$dest" ] && verify_allocate_manifest_py "$dest"; then
    write_script_pack_stamp "$work_root" >/dev/null
    printf '%s' "$dest"
    return 0
  fi

  local sibling
  sibling="$(_runner_dir)/allocate_manifest.py"
  if [ -f "$sibling" ] && grep -q "$REQUIRED_ALLOCATE_MARKER" "$sibling" 2>/dev/null; then
    cp "$sibling" "$dest"
    verify_allocate_manifest_py "$dest"
    write_script_pack_stamp "$work_root" >/dev/null
    printf '%s' "$dest"
    return 0
  fi

  echo "allocate_manifest_error=missing_or_unverified_allocate_manifest.py" >&2
  return 1
}

resolve_decomposer_py() {
  local work_root="${1:?WORK_ROOT}"
  local dest="${work_root}/scripts/tfstate_monolith_decomposer.py"
  mkdir -p "$(dirname "$dest")"

  if [ -f "$dest" ] && verify_decomposer_py "$dest"; then
    write_script_pack_stamp "$work_root" >/dev/null
    printf '%s' "$dest"
    return 0
  fi

  local sibling
  sibling="$(_runner_dir)/tfstate_monolith_decomposer.py"
  if [ -f "$sibling" ] && grep -q "$REQUIRED_DECOMPOSER_MARKER" "$sibling" 2>/dev/null; then
    cp "$sibling" "$dest"
    verify_decomposer_py "$dest"
    write_script_pack_stamp "$work_root" >/dev/null
    printf '%s' "$dest"
    return 0
  fi

  echo "decomposer_error=missing_or_unverified_tfstate_monolith_decomposer.py" >&2
  return 1
}

run_py() {
  local work_root="${1:?WORK_ROOT}"
  shift
  local py log_file quiet
  py="$(resolve_allocate_py "$work_root")"
  quiet="${DBSPLIT_QUIET_PY:-}"
  log_file="${work_root}/.py-run.log"
  if [ "$quiet" = "1" ]; then
    python3 "$py" "$@" >>"$log_file" 2>&1
    return $?
  fi
  python3 "$py" "$@"
}

run_decomposer_py() {
  local work_root="${1:?WORK_ROOT}"
  shift
  local py log_file quiet
  py="$(resolve_decomposer_py "$work_root")"
  quiet="${DBSPLIT_QUIET_PY:-}"
  log_file="${work_root}/.decomposer-run.log"
  if [ "$quiet" = "1" ]; then
    python3 "$py" "$@" >>"$log_file" 2>&1
    return $?
  fi
  python3 "$py" "$@"
}

emit_ingest_handoff_summary() {
  local work_root="${1:?WORK_ROOT}"
  local notes="${work_root}/notes.json"
  local handoff_dir="${work_root}/.work"
  local handoff_file="${handoff_dir}/ingest-handoff.txt"
  if [ ! -f "$notes" ]; then
    echo "handoff_error=missing_notes_json"
    return 1
  fi
  mkdir -p "$handoff_dir"
  jq -r '
    "count_reconciliation_ok=\(.count_reconciliation_ok // "false")",
    "logical_group_count=\(.logical_group_count // "0")",
    "logical_group_manifest_path=\(.logical_group_manifest_path // "")",
    "group_state_paths=\(.group_state_paths // "")",
    "monolith_resource_count=\(.monolith_resource_count // "0")",
    "aggregate_group_resource_count=\(.aggregate_group_resource_count // "0")",
    "split_quality_score=\(.split_quality_score // "0")",
    "split_quality_pass=\(.split_quality_pass // "false")",
    "split_quality_status=\(.split_quality_status // "not_available")",
    "split_quality_report=\(.split_quality_report // "")",
    "readiness_suggestions_path=\(.readiness_suggestions_path // "")",
    "split_tuning_iterations=\(.split_tuning_iterations // "0")",
    "tfstate_decomposer_orphan_count=\(.tfstate_decomposer_orphan_count // "0")",
    "monolith_state_local_path=\(.monolith_state_local_path // "")",
    "script_pack_version=\(.script_pack_version // "")",
    "script_pack_verify_ok=\(.script_pack_verify_ok // "false")"
  ' "$notes" | tee "$handoff_file"
  mirror_note "$work_root" "ingest_handoff_path" "$handoff_file"
  echo "ingest_handoff_path=${handoff_file}"
}

managed_instance_count() {
  local state_path="${1:?STATE}"
  jq '[.resources[]? | select(.mode=="managed") | .instances[]?] | length' "$state_path" 2>/dev/null \
    || jq '[.resources[]? | select(.mode=="managed")] | length' "$state_path"
}

is_stackgen_run_dir() {
  local dir="${1:?DIR}"
  local base
  [ -d "$dir" ] || return 1
  base="$(basename "$dir")"
  case "$base" in
    .|..|.ssh|.aws|.cache|.config|.local|.terraform.d|.npm|.docker|.kube|.git)
      return 1
      ;;
  esac
  if [ -f "${dir}/.stackgen-run-root" ]; then
    return 0
  fi
  # Legacy work roots created before .stackgen-run-root existed.
  if [[ "$base" == .* ]] && [ ${#base} -ge 9 ] && [ -f "${dir}/notes.json" ] && [ -d "${dir}/.work" ]; then
    return 0
  fi
  return 1
}

# remove_run_dir deletes a finished work root together with the terraform
# runtime data it left on the shared runtime base. The data dirs are keyed by
# run name and live outside the work root, so deleting only the root would leak
# a provider-sized directory per run until the node runs out of disk.
remove_run_dir() {
  local dir="${1:?DIR}"
  local runtime_base
  runtime_base="$(terraform_runtime_base "$dir" 2>/dev/null || true)"
  if [ -n "$runtime_base" ]; then
    rm -rf "${runtime_base}/data/$(safe_runtime_component "$(basename "$dir")")" 2>/dev/null || true
  fi
  rm -rf "$dir" 2>/dev/null || true
}

cmd_cleanup_old_runs() {
  local current_work_root="${1:-${WORK_ROOT:-}}"
  local runner_home="${2:-${HOME:-/home/runner}}"
  local ttl_hours="${3:-$DBSPLIT_RUN_TTL_HOURS}"
  local now ttl_seconds scanned=0 deleted=0 skipped=0 dry_run
  local keep="${DBSPLIT_RUN_KEEP}"
  if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then
    keep=3
  fi
  if ! [[ "$ttl_hours" =~ ^[0-9]+$ ]] || [ "$ttl_hours" -lt 1 ]; then
    ttl_hours="$DBSPLIT_RUN_TTL_HOURS"
  fi
  ttl_seconds=$((ttl_hours * 3600))
  now="$(date +%s)"
  dry_run="${DBSPLIT_CLEANUP_DRY_RUN:-false}"

  if [ -z "$runner_home" ] || [ ! -d "$runner_home" ]; then
    echo "cleanup_error=runner_home_missing path=${runner_home}"
    return 1
  fi

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    scanned=$((scanned + 1))
    if [ -n "$current_work_root" ] && [ "$(cd "$dir" 2>/dev/null && pwd)" = "$(cd "$current_work_root" 2>/dev/null && pwd)" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    if ! is_stackgen_run_dir "$dir"; then
      skipped=$((skipped + 1))
      continue
    fi

    local ref age active_recent
    ref="$dir"
    [ -f "${dir}/.last_touch" ] && ref="${dir}/.last_touch"
    age=$((now - $(mtime_epoch "$ref")))
    active_recent=false
    if [ -f "${dir}/.active" ] && [ "$age" -lt "$ttl_seconds" ]; then
      active_recent=true
    fi
    if [ "$active_recent" = "true" ] || [ "$age" -lt "$ttl_seconds" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$dry_run" = "true" ]; then
      echo "cleanup_candidate=${dir} age_seconds=${age}"
    else
      remove_run_dir "$dir"
      echo "cleanup_deleted=${dir} age_seconds=${age}"
    fi
    deleted=$((deleted + 1))
  done < <(find "$runner_home" -mindepth 1 -maxdepth 1 -type d -name '.*' -print 2>/dev/null | sort)

  # Retention pass: whatever survived the TTL is still bounded by count, newest
  # first, so a burst of runs inside the TTL window cannot fill the disk.
  local surviving=0 pruned=0 candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    is_stackgen_run_dir "$candidate" || continue
    if [ -n "$current_work_root" ] && [ "$(cd "$candidate" 2>/dev/null && pwd)" = "$(cd "$current_work_root" 2>/dev/null && pwd)" ]; then
      continue
    fi
    surviving=$((surviving + 1))
    [ "$surviving" -ge "$keep" ] || continue
    if [ "$dry_run" = "true" ]; then
      echo "cleanup_retention_candidate=${candidate}"
    else
      remove_run_dir "$candidate"
      echo "cleanup_retention_deleted=${candidate}"
    fi
    pruned=$((pruned + 1))
  done < <(find "$runner_home" -mindepth 1 -maxdepth 1 -type d -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

  echo "cleanup_summary=scanned:${scanned},deleted:${deleted},retention_deleted:${pruned},skipped:${skipped},ttl_hours:${ttl_hours},keep:${keep},dry_run:${dry_run}"
}

cmd_preflight() {
  local work_root="${1:?WORK_ROOT}"
  require_embedded_invocation || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    echo "preflight_error=python3_missing"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "preflight_error=jq_missing"
    return 1
  fi
  mark_run_active "$work_root"
  mkdir -p "${work_root}/state" "${work_root}/scripts" "${work_root}/groups"
  touch "${work_root}/.write_test" && rm "${work_root}/.write_test"
  [ -f "${work_root}/notes.json" ] || echo '{}' >"${work_root}/notes.json"
  mirror_note "$work_root" "scratch_root" "$work_root"
  mirror_note "$work_root" "script_pack_version" "$SCRIPT_PACK_VERSION"
  if [ "${DBSPLIT_RUN_CLEANUP_ON_PREFLIGHT:-1}" = "1" ]; then
    cmd_cleanup_old_runs "$work_root" "$(dirname "$work_root")" "$DBSPLIT_RUN_TTL_HOURS" >/dev/null || true
  fi
  echo "preflight_ok=true"
  echo "work_root_created=true"
  echo "script_pack_version=${SCRIPT_PACK_VERSION}"
}

# normalize_state_uri strips a `key=` prefix and surrounding quotes/whitespace
# from a state URI. Agents hand this value off by copying a stage's final line
# verbatim, so it commonly arrives as `monolith_state_uri=/home/runner/...`.
# Without this, the value is not recognized as a local path and download falls
# through to curl, which rejects it with "No host part in the URL".
normalize_state_uri() {
  local uri="${1:-}"
  local pass
  # Two passes: a value can be quoted around the prefix ("key=/path") or the
  # prefix can wrap a quoted value (key="/path").
  for pass in 1 2; do
    uri="$(printf '%s' "$uri" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    uri="${uri%\"}"
    uri="${uri#\"}"
    uri="${uri%\'}"
    uri="${uri#\'}"
    uri="${uri#monolith_state_uri=}"
    uri="${uri#cloud2code_tfstate_path=}"
    uri="${uri#tfstate_file=}"
  done
  printf '%s' "$uri"
}

resolve_state_uri() {
  local uri="${1:-}"
  if [ -z "$uri" ] && [ -n "${TFSTATE_FILE:-}" ]; then
    uri="$TFSTATE_FILE"
  fi
  if [ -z "$uri" ] && [ -n "${MONOLITH_STATE_URI:-}" ]; then
    uri="$MONOLITH_STATE_URI"
  fi
  if [ -z "$uri" ] && [ -n "${MONOLITH_URI:-}" ]; then
    uri="$MONOLITH_URI"
  fi
  normalize_state_uri "$uri"
}

# ensure_monolith_uri_from_work_root loads MONOLITH_URI from spawn pre-write file or notes.json.
# Exists so ingest-and-split survives runners that paste the embed without export (trace 8c7ea4ad).
ensure_monolith_uri_from_work_root() {
  local work_root="${1:?WORK_ROOT}"
  if [ -n "${MONOLITH_URI:-}" ]; then
    return 0
  fi
  local uri_file="${work_root}/.work/spawn_monolith_uri"
  if [ -f "$uri_file" ]; then
    local spawned
    spawned="$(normalize_state_uri "$(tr -d '\n\r' <"$uri_file")")"
    if [ -n "$spawned" ]; then
      export MONOLITH_URI="$spawned"
      echo "MONOLITH_URI_from_spawn_file=true"
      return 0
    fi
  fi
  if [ -f "${work_root}/notes.json" ]; then
    local raw
    raw="$(jq -r '.monolith_state_uri // .cloud2code_tfstate_path // .tfstate_file // empty' "${work_root}/notes.json" 2>/dev/null || true)"
    raw="$(normalize_state_uri "$raw")"
    if [ -n "$raw" ]; then
      export MONOLITH_URI="$raw"
      echo "MONOLITH_URI_from_notes_fallback=true"
      return 0
    fi
  fi
  return 1
}

download_google_drive() {
  local uri="$1"
  local dest="$2"
  local file_id=""
  file_id="$(printf '%s' "$uri" | sed -nE 's#.*/d/([a-zA-Z0-9_-]+)/?.*#\1#p' | head -1)"
  if [ -z "$file_id" ]; then
    file_id="$(printf '%s' "$uri" | sed -nE 's#.*[?&]id=([a-zA-Z0-9_-]+).*#\1#p' | head -1)"
  fi
  if [ -z "$file_id" ]; then
    echo "download_error=google_drive_file_id_not_found uri=${uri}" >&2
    return 1
  fi
  if command -v gdown >/dev/null 2>&1; then
    gdown --id "$file_id" -O "$dest" || gdown --fuzzy "$uri" -O "$dest"
    return 0
  fi
  curl -LfsS "https://drive.google.com/uc?export=download&id=${file_id}&confirm=t" -o "$dest"
}

cmd_download_state() {
  local work_root="${1:?WORK_ROOT}"
  local state_uri
  state_uri="$(resolve_state_uri "${2:-}")"
  local dest="${work_root}/state/terraform.tfstate"
  mkdir -p "$(dirname "$dest")"

  if [ -z "$state_uri" ]; then
    echo "download_error=missing_monolith_state_uri_or_tfstate_file"
    return 1
  fi

  mirror_note "$work_root" "monolith_state_uri" "$state_uri"

  if [[ "$state_uri" == file://* ]]; then
    cp "${state_uri#file://}" "$dest"
  elif [ -f "$state_uri" ]; then
    cp "$state_uri" "$dest"
  elif [[ "$state_uri" == *drive.google.com* ]]; then
    download_google_drive "$state_uri" "$dest"
  elif [[ "$state_uri" == s3://* ]]; then
    aws s3 cp "$state_uri" "$dest"
  elif [[ "$state_uri" == gs://* ]]; then
    gcloud storage cp "$state_uri" "$dest"
  else
    curl -LfsS "$state_uri" -o "$dest"
  fi

  if [ ! -s "$dest" ]; then
    echo "download_error=empty_state_file uri=${state_uri}"
    return 1
  fi
  if ! jq -e '.resources' "$dest" >/dev/null 2>&1; then
    echo "download_error=invalid_tfstate_json uri=${state_uri}"
    return 1
  fi

  local count
  count="$(managed_instance_count "$dest")"
  if [ "${count:-0}" -eq 0 ]; then
    echo "download_warning=zero_managed_resources uri=${state_uri}"
  fi
  mirror_note "$work_root" "monolith_state_local_path" "$dest"
  mirror_note "$work_root" "monolith_resource_count" "$count"
  mirror_note "$work_root" "ingest_stage_progress" "download_complete"

  local strategy cap
  strategy="$(read_note "$work_root" "grouping_strategy" || true)"
  cap="$(read_note "$work_root" "max_resources_per_appstack" || true)"

  if [ "$count" -gt 5000 ] && [ -z "$strategy" ]; then
    strategy="${DBSPLIT_DEFAULT_STRATEGY}"
    cap="${DBSPLIT_DEFAULT_CAP}"
    mirror_note "$work_root" "grouping_strategy" "$strategy"
    mirror_note "$work_root" "max_resources_per_appstack" "$cap"
    echo "auto_promoted_grouping=true strategy=${strategy} cap=${cap}"
  fi

  echo "monolith_state_local_path=${dest}"
  echo "monolith_resource_count=${count}"
}

cmd_discover_anchors() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:-${work_root}/state/terraform.tfstate}"

  if [ ! -f "$state_path" ]; then
    echo "discover_error=state_file_missing path=${state_path}"
    return 1
  fi

  run_decomposer_py "$work_root" inventory "$state_path" "$work_root"

  local seed_count inv_count
  seed_count="$(read_note "$work_root" "anchor_seeds_extracted" || jq 'length' "${work_root}/logical_group_seeds.json")"
  inv_count="$(jq 'length' "${work_root}/db_anchor_inventory.json")"
  mirror_note "$work_root" "logical_group_seeds_path" "${work_root}/logical_group_seeds.json"
  mirror_note "$work_root" "db_anchor_inventory_path" "${work_root}/db_anchor_inventory.json"
  mirror_note "$work_root" "anchor_seeds_extracted" "$seed_count"

  echo "logical_group_seeds_path=${work_root}/logical_group_seeds.json"
  echo "db_anchor_inventory_path=${work_root}/db_anchor_inventory.json"
  echo "anchor_seeds_extracted=${seed_count}"
  echo "db_anchor_inventory_count=${inv_count}"
}

cmd_allocate_manifest() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:-${work_root}/state/terraform.tfstate}"
  local strategy cap
  strategy="$(note_or_default "$work_root" "grouping_strategy" "$DBSPLIT_DEFAULT_STRATEGY")"
  cap="$(note_or_default "$work_root" "max_resources_per_appstack" "$DBSPLIT_DEFAULT_CAP")"
  if [ -n "${3:-}" ]; then
    strategy="$3"
  fi
  if [ -n "${4:-}" ]; then
    cap="$4"
  fi

  if [ ! -f "$state_path" ]; then
    echo "allocate_error=state_file_missing path=${state_path}"
    return 1
  fi

  run_py "$work_root" allocate "$work_root" "$state_path" "$strategy" "$cap"
  _mirror_manifest_notes "$work_root" "$strategy" "$cap"
}

_mirror_manifest_notes() {
  local work_root="$1"
  local strategy="$2"
  local cap="$3"
  local manifest_path="${work_root}/logical_group_manifest.json"
  local group_count aggregate reconcile_path monolith_count reconcile_ok
  group_count="$(jq 'length' "$manifest_path")"
  aggregate="$(jq '[.[]] | add' "${work_root}/per_group_resource_counts.json")"
  reconcile_path="${work_root}/reconcile_result.json"
  if [ -f "$reconcile_path" ]; then
    monolith_count="$(jq -r '.monolith_resource_count // empty' "$reconcile_path")"
    reconcile_ok="$(jq -r '.count_reconciliation_ok // empty' "$reconcile_path")"
    aggregate="$(jq -r '.aggregate_group_resource_count // empty' "$reconcile_path")"
  fi

  mirror_note "$work_root" "logical_group_manifest_path" "$manifest_path"
  mirror_note "$work_root" "shard_manifest_path" "${work_root}/shard_manifest.json"
  mirror_note "$work_root" "per_group_resource_counts_path" "${work_root}/per_group_resource_counts.json"
  mirror_note "$work_root" "grouping_strategy" "$strategy"
  mirror_note "$work_root" "max_resources_per_appstack" "$cap"
  mirror_note "$work_root" "logical_group_count" "$group_count"
  mirror_note "$work_root" "aggregate_group_resource_count" "$aggregate"
  if [ -n "${monolith_count:-}" ]; then
    mirror_note "$work_root" "monolith_resource_count" "$monolith_count"
  fi
  if [ -n "${reconcile_ok:-}" ]; then
    mirror_note "$work_root" "count_reconciliation_ok" "$reconcile_ok"
  fi

  echo "logical_group_manifest_path=${manifest_path}"
  echo "logical_group_count=${group_count}"
}

cmd_extract_group_states() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:-${work_root}/state/terraform.tfstate}"
  local manifest_path="${work_root}/logical_group_manifest.json"

  if [ ! -f "$manifest_path" ]; then
    echo "extract_error=missing_logical_group_manifest"
    return 1
  fi

  run_py "$work_root" extract-states "$state_path" "$work_root" "$manifest_path"
  mirror_note "$work_root" "group_state_paths" "${work_root}/group_state_paths.json"
  echo "group_state_paths=${work_root}/group_state_paths.json"
}

cmd_materialize_tfstate_splitter_sop_scripts() {
  local work_root="${1:?WORK_ROOT}"
  local sop_workspace="${2:-}"
  if [ -z "$sop_workspace" ]; then
    sop_workspace="$(cmd_resolve_tfstate_splitter_workspace "$work_root")"
  fi
  local cleanup_py="${sop_workspace}/cleanup.py"
  local split_py="${sop_workspace}/split_state.py"
  local verify_py="${sop_workspace}/verify_split.py"
  mkdir -p "$work_root" "$sop_workspace"

  cat >"$cleanup_py" <<'PY'
#!/usr/bin/env python3
"""Phase 0 from aws-migrator-tfstate-splitter-sop: remove stale split artifacts."""
import os
import shutil
import sys

workspace = sys.argv[1] if len(sys.argv) > 1 else "/home/ubuntu/workspace"
split_dir = os.path.join(workspace, "split-projects")
if os.path.isdir(split_dir):
    shutil.rmtree(split_dir)
    print(f"Removed {split_dir}")
for name in ["split_state.py", "verify_split.py", "generate_iac.py", "validate.py", "push.py", "cleanup.py"]:
    path = os.path.join(workspace, name)
    if os.path.isfile(path):
        os.remove(path)
        print(f"Removed {path}")
git_dir = os.path.join(workspace, ".git")
if os.path.isdir(git_dir):
    shutil.rmtree(git_dir)
    print(f"Removed {git_dir}")
print("Cleanup complete - workspace is clean for a fresh run")
PY

  cat >"$split_py" <<'PY'
#!/usr/bin/env python3
"""aws-migrator-tfstate-splitter-sop split_state.py.

Implements the attached SOP phases against /home/ubuntu/workspace-style inputs:
clean/analyze/exclude/split/generate/validate, while also emitting normalized
workflow artifacts under WORK_ROOT for downstream reverse-IaC stages.
"""
from __future__ import annotations

import copy
import json
import os
import re
import sys
import uuid
from collections import defaultdict


APP_TAGS = ("app", "project", "service", "stack", "application", "Application")
EXCLUDED_TYPES = {"aws_iam_service_linked_role"}
SERVICE_RULES = (
    ("networking", ("vpc", "subnet", "route", "internet_gateway", "nat_gateway", "network")),
    ("eks", ("eks", "kubernetes")),
    ("database", ("rds", "db_")),
    ("storage", ("s3",)),
    ("iam", ("iam",)),
    ("containers", ("ecr", "ecs")),
    ("serverless", ("lambda", "api_gateway")),
    ("compute", ("autoscaling", "launch")),
    ("security", ("security_group",)),
)


def sanitize(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_-]+", "-", str(value).strip().lower())
    value = re.sub(r"-+", "-", value).strip("-")
    return value or "shared"


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def instance_address(res: dict, inst: dict) -> str:
    if inst.get("address"):
        return inst["address"]
    if res.get("address"):
        base = res["address"]
    else:
        module = (res.get("module") or "").strip()
        base = f"{res.get('type', 'unknown')}.{res.get('name', 'x')}"
        if module:
            base = f"{module}.{base}"
    idx = inst.get("index_key")
    if idx is None:
        return base
    if isinstance(idx, int):
        return f"{base}[{idx}]"
    return f'{base}["{idx}"]'


def iter_managed_instances(state: dict):
    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        if is_excluded(res):
            continue
        insts = res.get("instances") or [{}]
        for inst in insts:
            if inst.get("deposed"):
                continue
            yield res, inst, instance_address(res, inst)


def is_excluded(res: dict) -> bool:
    rtype = res.get("type", "")
    if rtype in EXCLUDED_TYPES:
        return True
    if rtype.startswith("aws_db_parameter_group") and res.get("name") == "default":
        return True
    return False


def first_attrs(res: dict) -> dict:
    for inst in res.get("instances") or []:
        attrs = inst.get("attributes") or {}
        if attrs:
            return attrs
    return {}


def tags_for(res: dict) -> dict:
    attrs = first_attrs(res)
    for key in ("tags", "tags_all", "default_tags"):
        val = attrs.get(key)
        if isinstance(val, dict) and val:
            return val
    return {}


def vpc_key(res: dict) -> str:
    attrs = first_attrs(res)
    for key in ("vpc_id", "vpc", "vpc_id_input"):
        val = attrs.get(key)
        if val:
            return f"vpc-{sanitize(val)}"
    return ""


def app_key(res: dict) -> str:
    tags = tags_for(res)
    for key in APP_TAGS:
        val = tags.get(key)
        if val:
            return f"app-{sanitize(val)}"
    return ""


def name_key(res: dict) -> str:
    attrs = first_attrs(res)
    candidates = [
        attrs.get("name"),
        attrs.get("bucket"),
        attrs.get("function_name"),
        attrs.get("cluster_identifier"),
        attrs.get("id"),
        res.get("name"),
    ]
    for val in candidates:
        if not val:
            continue
        token = re.split(r"[-_./]", str(val))[0]
        if token and len(token) >= 3:
            return f"name-{sanitize(token)}"
    return ""


def service_key(res: dict) -> str:
    rtype = res.get("type", "")
    for group, needles in SERVICE_RULES:
        if any(needle in rtype for needle in needles):
            return group
    return "shared"


def group_for(res: dict, strategy: str) -> str:
    strategy = (strategy or "sop_default").strip()
    if strategy in ("service_category", "type_chunk"):
        return service_key(res)
    if strategy in ("app_tags", "tag_seeded_connectivity", "tag_seeded_connectivity_capped"):
        return app_key(res) or vpc_key(res) or service_key(res)
    if strategy in ("vpc_isolation", "connectivity", "connectivity_capped"):
        return vpc_key(res) or app_key(res) or service_key(res)
    if strategy in ("naming", "name_prefix"):
        return name_key(res) or app_key(res) or service_key(res)
    return vpc_key(res) or app_key(res) or name_key(res) or service_key(res)


def split_by_cap(groups: dict[str, list[dict]], cap: int) -> dict[str, list[dict]]:
    if cap <= 0:
        return groups
    out: dict[str, list[dict]] = {}
    for group, resources in sorted(groups.items()):
        if len(resources) <= cap:
            out[group] = resources
            continue
        for idx in range(0, len(resources), cap):
            out[f"{group}-{idx // cap + 1:03d}"] = resources[idx : idx + cap]
    return out


def resource_instance_addresses(resources: list[dict]) -> list[str]:
    addrs: list[str] = []
    for res in resources:
        insts = res.get("instances") or [{}]
        for inst in insts:
            if inst.get("deposed"):
                continue
            addrs.append(instance_address(res, inst))
    return sorted(addrs)


def write_group_states(state: dict, groups: dict[str, list[dict]], work_root: str, sop_workspace: str, strategy: str, cap: int) -> None:
    base_meta = {k: state.get(k) for k in ("version", "terraform_version", "serial", "lineage") if k in state}
    split_projects = os.path.join(sop_workspace, "split-projects")
    work_groups = os.path.join(work_root, "groups")
    os.makedirs(split_projects, exist_ok=True)
    os.makedirs(work_groups, exist_ok=True)
    manifest = {}
    counts = {}
    paths = {}
    for group, resources in sorted(groups.items()):
        shard = {
            **base_meta,
            "serial": 0,
            "lineage": str(uuid.uuid4()),
            "outputs": {},
            "resources": copy.deepcopy(resources),
        }
        addresses = resource_instance_addresses(resources)
        manifest[group] = {
            "cloud_hint": "aws",
            "resource_addresses": addresses,
            "notes": {
                "source_runbook": "aws-migrator-tfstate-splitter-sop",
                "grouping_strategy": strategy,
                "max_resources_per_appstack": cap,
            },
        }
        counts[group] = len(addresses)
        for root in (split_projects, work_groups):
            d = os.path.join(root, group)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "terraform.tfstate"), "w", encoding="utf-8") as fh:
                json.dump(shard, fh, indent=2)
        paths[group] = os.path.join(work_groups, group, "terraform.tfstate")
        print(f"{group}: {len(resources)} resources")
    with open(os.path.join(work_root, "logical_group_manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
    with open(os.path.join(work_root, "shard_manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
    with open(os.path.join(work_root, "per_group_resource_counts.json"), "w", encoding="utf-8") as fh:
        json.dump(counts, fh, indent=2, sort_keys=True)
    with open(os.path.join(work_root, "group_state_paths.json"), "w", encoding="utf-8") as fh:
        json.dump(paths, fh, indent=2, sort_keys=True)
    all_original = {addr for _res, _inst, addr in iter_managed_instances(state)}
    all_allocated = {addr for entry in manifest.values() for addr in entry["resource_addresses"]}
    result = {
        "count_reconciliation_ok": all_original == all_allocated,
        "monolith_resource_count": len(all_original),
        "aggregate_group_resource_count": len(all_allocated),
        "duplicate_address_count": sum(len(v["resource_addresses"]) for v in manifest.values()) - len(all_allocated),
        "unallocated_resource_count": len(all_original - all_allocated),
        "unknown_address_count": len(all_allocated - all_original),
        "unallocated_sample": sorted(all_original - all_allocated)[:10],
    }
    with open(os.path.join(work_root, "reconcile_result.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, sort_keys=True)


def main() -> int:
    if len(sys.argv) < 5:
        print("usage: split_state.py WORK_ROOT STATE_FILE GROUPING_STRATEGY MAX_RESOURCES_PER_APPSTACK", file=sys.stderr)
        return 2
    work_root, state_file, strategy, cap_s = sys.argv[1:5]
    sop_workspace = os.environ.get("TFSTATE_SPLITTER_WORKSPACE") or os.path.dirname(state_file)
    try:
        cap = int(cap_s or "0")
    except ValueError:
        cap = 0

    state = load(state_file)
    groups: dict[str, list[dict]] = defaultdict(list)
    excluded = 0
    for res in state.get("resources", []):
        if res.get("mode") != "managed":
            continue
        if is_excluded(res):
            excluded += 1
            continue
        groups[group_for(res, strategy)].append(res)
    groups = split_by_cap(dict(groups), cap)
    write_group_states(state, groups, work_root, sop_workspace, strategy, cap)
    print(f"Total groups: {len(groups)}, Total resources: {sum(len(v) for v in groups.values())}, Excluded resources: {excluded}")
    print(f"tfstate_splitter_sop=completed script=split_state.py strategy={strategy} cap={cap}")
    print(f"split_projects_dir={os.path.join(sop_workspace, 'split-projects')}")
    print(f"split_project_count={len(groups)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

  cat >"$verify_py" <<'PY'
#!/usr/bin/env python3
"""Verify aws-migrator-tfstate-splitter-sop accounting for split-projects and manifest artifacts."""
import json
import os
import sys

EXCLUDED_TYPES = {"aws_iam_service_linked_role"}


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def is_excluded(res):
    rtype = res.get("type", "")
    if rtype in EXCLUDED_TYPES:
        return True
    if rtype.startswith("aws_db_parameter_group") and res.get("name") == "default":
        return True
    return False


def instance_address(res, inst):
    if inst.get("address"):
        return inst["address"]
    if res.get("address"):
        base = res["address"]
    else:
        module = (res.get("module") or "").strip()
        base = f"{res.get('type', 'unknown')}.{res.get('name', 'x')}"
        if module:
            base = f"{module}.{base}"
    idx = inst.get("index_key")
    if idx is None:
        return base
    if isinstance(idx, int):
        return f"{base}[{idx}]"
    return f'{base}["{idx}"]'


def managed_addresses(state):
    out = set()
    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        if is_excluded(res):
            continue
        insts = res.get("instances") or [{}]
        for inst in insts:
            if inst.get("deposed"):
                continue
            out.add(instance_address(res, inst))
    return out


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: verify_split.py WORK_ROOT STATE_FILE", file=sys.stderr)
        return 2
    work_root, state_file = sys.argv[1:3]
    original = managed_addresses(load(state_file))
    manifest = load(os.path.join(work_root, "logical_group_manifest.json"))
    allocated = []
    for entry in manifest.values():
        allocated.extend(entry.get("resource_addresses") or [])
    allocated_set = set(allocated)
    dupes = len(allocated) - len(allocated_set)
    missing = sorted(original - allocated_set)
    extra = sorted(allocated_set - original)
    sop_workspace = os.environ.get("TFSTATE_SPLITTER_WORKSPACE") or work_root
    split_projects = os.path.join(sop_workspace, "split-projects")
    project_count = 0
    if os.path.isdir(split_projects):
        project_count = sum(
            1
            for name in os.listdir(split_projects)
            if os.path.isfile(os.path.join(split_projects, name, "terraform.tfstate"))
        )
    ok = dupes == 0 and not missing and not extra and project_count == len(manifest)
    print(f"tfstate_splitter_sop_verify_ok={str(ok).lower()}")
    print(f"original_count={len(original)} split_count={len(allocated_set)} duplicate_count={dupes} missing_count={len(missing)} extra_count={len(extra)} split_project_count={project_count}")
    if missing:
        print("missing_sample=" + json.dumps(missing[:10]))
    if extra:
        print("extra_sample=" + json.dumps(extra[:10]))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
PY

  chmod +x "$cleanup_py" "$split_py" "$verify_py"
  cp "$cleanup_py" "${work_root}/cleanup.py"
  cp "$split_py" "${work_root}/split_state.py"
  cp "$verify_py" "${work_root}/verify_split.py"
  mirror_note "$work_root" "tfstate_splitter_sop" "aws-migrator-tfstate-splitter-sop"
  mirror_note "$work_root" "tfstate_splitter_workspace" "$sop_workspace"
  mirror_note "$work_root" "tfstate_splitter_cleanup_script_path" "$cleanup_py"
  mirror_note "$work_root" "tfstate_splitter_script_path" "$split_py"
  mirror_note "$work_root" "tfstate_splitter_verify_script_path" "$verify_py"
  echo "tfstate_splitter_sop=aws-migrator-tfstate-splitter-sop"
  echo "tfstate_splitter_workspace=${sop_workspace}"
  echo "tfstate_splitter_cleanup_script_path=${cleanup_py}"
  echo "tfstate_splitter_script_path=${split_py}"
  echo "tfstate_splitter_verify_script_path=${verify_py}"
}

cmd_resolve_tfstate_splitter_workspace() {
  local work_root="${1:?WORK_ROOT}"
  local configured="${DBSPLIT_TFSTATE_SPLITTER_WORKSPACE:-/home/ubuntu/workspace}"
  if mkdir -p "$configured" 2>/dev/null; then
    printf '%s' "$configured"
    return 0
  fi
  local fallback="${work_root}/tfstate-splitter-workspace"
  mkdir -p "$fallback"
  printf '%s' "$fallback"
}

cmd_run_tfstate_splitter_sop_script() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:?STATE_PATH}"
  local strategy="${3:?STRATEGY}"
  local cap="${4:?CAP}"
  local sop_workspace cleanup_py split_py verify_py sop_state
  sop_workspace="$(cmd_resolve_tfstate_splitter_workspace "$work_root")"
  cleanup_py="${sop_workspace}/cleanup.py"
  split_py="${sop_workspace}/split_state.py"
  verify_py="${sop_workspace}/verify_split.py"
  sop_state="${sop_workspace}/terraform.tfstate"
  if [ ! -f "$cleanup_py" ] || [ ! -f "$split_py" ] || [ ! -f "$verify_py" ]; then
    cmd_materialize_tfstate_splitter_sop_scripts "$work_root" "$sop_workspace" >/dev/null
  fi
  cp "$state_path" "$sop_state"
  TFSTATE_SPLITTER_WORKSPACE="$sop_workspace" python3 "$cleanup_py" "$sop_workspace"
  cmd_materialize_tfstate_splitter_sop_scripts "$work_root" "$sop_workspace" >/dev/null
  cp "$state_path" "$sop_state"
  TFSTATE_SPLITTER_WORKSPACE="$sop_workspace" python3 "$split_py" "$work_root" "$sop_state" "$strategy" "$cap"
  TFSTATE_SPLITTER_WORKSPACE="$sop_workspace" python3 "$verify_py" "$work_root" "$sop_state"
}

normalize_decomposer_cap() {
  local cap="${1:-0}"
  if ! [[ "$cap" =~ ^[0-9]+$ ]]; then
    printf '0'
    return 0
  fi
  printf '%s' "$cap"
}

normalize_bool_note() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

materialize_json_note() {
  local work_root="${1:?WORK_ROOT}"
  local note_key="${2:?NOTE_KEY}"
  local filename="${3:?FILENAME}"
  local raw path
  raw="$(read_note "$work_root" "$note_key" 2>/dev/null || true)"
  if [ -z "$raw" ]; then
    return 0
  fi
  path="${work_root}/${filename}"
  if printf '%s' "$raw" | jq . >"$path" 2>"${path}.err"; then
    mirror_note "$work_root" "${note_key%_json}_path" "$path"
    printf '%s' "$path"
    return 0
  fi
  mirror_note "$work_root" "decomposer_input_warning:${note_key}" "invalid_json"
  rm -f "$path"
  return 0
}

resolve_decomposer_overrides_path() {
  local work_root="${1:?WORK_ROOT}"
  local path
  path="$(read_note "$work_root" "tfstate_decomposer_overrides_path" 2>/dev/null || true)"
  if [ -n "$path" ] && [ -f "$path" ]; then
    printf '%s' "$path"
    return 0
  fi
  materialize_json_note "$work_root" "tfstate_decomposer_overrides_json" "overrides.json"
}

materialize_decomposer_taxonomy() {
  local work_root="${1:?WORK_ROOT}"
  materialize_json_note "$work_root" "tfstate_decomposer_layer_taxonomy_json" "layer_taxonomy.json" >/dev/null
}

cmd_run_tfstate_monolith_decomposer() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:?STATE_PATH}"
  local cap="${3:?CAP}"
  local env_scope="${4:?ENV_SCOPE}"
  local env_tag_keys="${5:-}"
  local layer3_tag_keys="${6:-}"
  local skip_unknown="${7:-false}"
  local overrides_path="${8:-}"
  local args

  cap="$(normalize_decomposer_cap "$cap")"
  env_scope="${env_scope:-all}"
  skip_unknown="$(normalize_bool_note "$skip_unknown")"
  materialize_decomposer_taxonomy "$work_root"
  rm -f \
    "${work_root}/logical_group_manifest.json" \
    "${work_root}/shard_manifest.json" \
    "${work_root}/per_group_resource_counts.json" \
    "${work_root}/group_state_paths.json" \
    "${work_root}/reconcile_result.json" \
    "${work_root}/review_items.json" \
    "${work_root}/layer_summary.json" \
    "${work_root}/upstream_refs.json" \
    "${work_root}/registry_mapping_report.json" \
    "${work_root}/orphans_bundle.json"
  rm -rf "${work_root}/groups"

  args=(split "$work_root" "$state_path" "$cap" --env-scope "$env_scope")
  if [ -n "$env_tag_keys" ]; then
    args+=(--env-tag-keys "$env_tag_keys")
  fi
  if [ -n "$layer3_tag_keys" ]; then
    args+=(--layer3-tag-keys "$layer3_tag_keys")
  fi
  if [ -n "$overrides_path" ] && [ -f "$overrides_path" ]; then
    args+=(--overrides "$overrides_path")
  fi
  if [ "$skip_unknown" = "true" ]; then
    args+=(--skip-unknown-type-review)
  fi

  local split_rc=0
  set +e
  DBSPLIT_QUIET_PY=1 run_decomposer_py "$work_root" "${args[@]}"
  split_rc=$?
  set -e

  # Scaffold immediately so the quality score can include orphan count.
  DBSPLIT_QUIET_PY=1 run_decomposer_py "$work_root" scaffold-registry "$work_root" || true

  mirror_note "$work_root" "tfstate_splitter_sop" "aws-migrator-tfstate-splitter-sop"
  mirror_note "$work_root" "tfstate_decomposer_script_path" "${work_root}/scripts/tfstate_monolith_decomposer.py"
  mirror_note "$work_root" "tfstate_decomposer_env_scope" "$env_scope"
  mirror_note "$work_root" "tfstate_decomposer_skip_unknown_type_review" "$skip_unknown"
  if [ -n "$env_tag_keys" ]; then
    mirror_note "$work_root" "tfstate_decomposer_env_tag_keys" "$env_tag_keys"
  fi
  if [ -n "$layer3_tag_keys" ]; then
    mirror_note "$work_root" "tfstate_decomposer_layer3_tag_keys" "$layer3_tag_keys"
  fi
  if [ -f "${work_root}/review_items.json" ]; then
    mirror_note "$work_root" "review_items_path" "${work_root}/review_items.json"
  fi
  if [ -f "${work_root}/layer_summary.json" ]; then
    mirror_note "$work_root" "layer_summary_path" "${work_root}/layer_summary.json"
  fi
  if [ -f "${work_root}/upstream_refs.json" ]; then
    mirror_note "$work_root" "upstream_refs_path" "${work_root}/upstream_refs.json"
  fi
  if [ -f "${work_root}/orphans_bundle.json" ]; then
    mirror_note "$work_root" "orphans_bundle" "${work_root}/orphans_bundle.json"
    # Explicit empty-bundle markers so the orphans stage can verify handoff without
    # re-reading the file through invented shell.
    local orphan_len
    orphan_len="$(jq 'if type=="array" then length else (.orphans // .items // []) | length end' "${work_root}/orphans_bundle.json" 2>/dev/null || echo 1)"
    if [ "$orphan_len" = "0" ]; then
      mirror_note "$work_root" "orphans_bundle_empty" "true"
      mirror_note "$work_root" "orphans_handoff_verified" "true"
      echo 'orphans_bundle_empty: "true"'
      echo 'orphans_handoff_verified: "true"'
    else
      mirror_note "$work_root" "orphans_bundle_empty" "false"
      echo 'orphans_bundle_empty: "false"'
    fi
  fi
  return "$split_rc"
}

cmd_evaluate_split_quality() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:?STATE_PATH}"
  local strategy="${3:?STRATEGY}"
  local cap="${4:?CAP}"
  local attempt="${5:?ATTEMPT}"
  local archive_dir="${work_root}/.work/split-quality/candidate-${attempt}"
  local report_path="${archive_dir}/split_quality_report.json"
  mkdir -p "$archive_dir"

  python3 - "$work_root" "$state_path" "$strategy" "$cap" "$attempt" "$report_path" <<'PY'
import json
import os
import statistics
import sys

work_root, state_path, strategy, cap_s, attempt_s, report_path = sys.argv[1:7]

def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return default

def as_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default

manifest = load_json(os.path.join(work_root, "logical_group_manifest.json"), {})
counts = load_json(os.path.join(work_root, "per_group_resource_counts.json"), {})
reconcile = load_json(os.path.join(work_root, "reconcile_result.json"), {})
review = load_json(os.path.join(work_root, "review_items.json"), {})
layer_summary = load_json(os.path.join(work_root, "layer_summary.json"), {})
orphans_bundle = load_json(os.path.join(work_root, "orphans_bundle.json"), [])
run_notes = load_json(os.path.join(work_root, "notes.json"), {})
cap = as_int(cap_s, 0)
attempt = as_int(attempt_s, 1)

def as_bool(value, default=False):
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    return str(value).strip().lower() in {"true", "1", "yes", "y"}

def orphan_count(value):
    if isinstance(value, list):
        return len(value)
    if isinstance(value, dict):
        for key in ("orphans", "items", "addresses"):
            if isinstance(value.get(key), list):
                return len(value[key])
        return len(value)
    return 0

group_sizes = [as_int(v, 0) for v in counts.values()]
group_count = len(group_sizes)
monolith_count = as_int(reconcile.get("monolith_resource_count"), sum(group_sizes))
aggregate_count = as_int(reconcile.get("aggregate_group_resource_count"), sum(group_sizes))
count_ok = bool(reconcile.get("count_reconciliation_ok"))
duplicate_count = as_int(reconcile.get("duplicate_address_count"), 0)
unallocated_count = as_int(reconcile.get("unallocated_resource_count"), 0)
largest = max(group_sizes) if group_sizes else 0
smallest = min(group_sizes) if group_sizes else 0
avg = round(sum(group_sizes) / group_count, 2) if group_count else 0
median = statistics.median(group_sizes) if group_sizes else 0
singletons = sum(1 for n in group_sizes if n <= 1)
singleton_ratio = round(singletons / group_count, 4) if group_count else 0
oversized = sum(1 for n in group_sizes if cap > 0 and n > cap)
review_summary = review.get("summary") if isinstance(review, dict) else {}
total_review = as_int(review_summary.get("total_review"), 0)
high_impact_count = as_int(review_summary.get("high_impact_count"), 0)
batch_rule_count = as_int(review_summary.get("batch_rule_count"), 0)
auto_assigned_count = as_int(review_summary.get("auto_assigned_count"), 0)
orphans = orphan_count(orphans_bundle)
stale_overrides = len(layer_summary.get("stale_overrides") or []) if isinstance(layer_summary, dict) else 0
cross_env_promotions = len(layer_summary.get("cross_env_promotions") or []) if isinstance(layer_summary, dict) else 0
env_scope = str(layer_summary.get("env_scope") or run_notes.get("tfstate_decomposer_env_scope") or "all")
skip_unknown = as_bool(layer_summary.get("skip_unknown_type_review", run_notes.get("tfstate_decomposer_skip_unknown_type_review")), False)
env_tag_keys = str(run_notes.get("tfstate_decomposer_env_tag_keys") or "")
layer3_tag_keys = str(run_notes.get("tfstate_decomposer_layer3_tag_keys") or "")

cross_refs = 0
shared_refs = 0
bfs_splits = 0
type_chunks = 0
shared_groups = 0
ungrouped_hairball = False
for gid, entry in manifest.items():
    entry_notes = entry.get("notes") or {}
    cross_refs += len(entry_notes.get("cross_shard_refs") or [])
    shared_refs += len(entry_notes.get("shared_refs") or [])
    upstream_refs = entry_notes.get("upstream_refs") or []
    if isinstance(upstream_refs, list):
        shared_refs += len(upstream_refs)
    partition = entry_notes.get("partition")
    if partition == "bfs-cap-split":
        bfs_splits += 1
    if partition == "greedy-chunk":
        type_chunks += 1
    if partition == "shared-hub":
        shared_groups += 1
    if gid == "ungrouped" and group_count == 1 and monolith_count > 500:
        ungrouped_hairball = True

issues = []
hard = False
if not count_ok:
    hard = True
    issues.append("count_reconciliation_failed")
if duplicate_count:
    hard = True
    issues.append("duplicate_addresses")
if unallocated_count:
    hard = True
    issues.append("unallocated_addresses")
if group_count == 0:
    hard = True
    issues.append("no_logical_groups")
if oversized:
    hard = True
    issues.append("cap_violated")
if orphans:
    issues.append("orphaned_resources")
if ungrouped_hairball or (group_count == 1 and monolith_count > 5000):
    issues.append("single_large_hairball")
if type_chunks:
    issues.append("type_chunk_low_quality")
if cap <= 0 and largest > 500:
    issues.append("large_component_without_size_cap")
if cap > 0 and cross_refs > max(10, group_count):
    issues.append("cross_shard_refs_high")
if singleton_ratio > 0.75 and group_count > 50:
    issues.append("overfragmented_singletons")
if group_count > 500 and avg < 10:
    issues.append("too_many_tiny_groups")
if high_impact_count:
    issues.append("high_impact_review_items")
if stale_overrides:
    issues.append("stale_overrides")

score = 100
if not count_ok:
    score -= 100
if group_count == 0:
    score -= 100
if oversized:
    score -= min(60, oversized * 10)
if duplicate_count:
    score -= min(60, duplicate_count * 10)
if unallocated_count:
    score -= min(60, unallocated_count * 10)
if orphans:
    score -= min(45, orphans * 3)
if "single_large_hairball" in issues:
    score -= 35
if "large_component_without_size_cap" in issues:
    score -= 20
if type_chunks:
    score -= 25
if "cross_shard_refs_high" in issues:
    score -= min(30, int(cross_refs / max(group_count, 1) * 10))
if "overfragmented_singletons" in issues:
    score -= 20
if "too_many_tiny_groups" in issues:
    score -= 15
if high_impact_count:
    score -= min(20, high_impact_count)
if batch_rule_count:
    score -= min(8, batch_rule_count)
if auto_assigned_count:
    score -= min(12, max(1, auto_assigned_count // 25))
if stale_overrides:
    score -= min(15, stale_overrides * 3)
score = max(0, min(100, score))

recommended = None
if not count_ok:
    if not skip_unknown:
        recommended = {"strategy": "tfstate_monolith_decomposer", "cap": str(cap), "env_scope": env_scope, "skip_unknown_type_review": True, "reason": "allow provisional unknown-type placement and retry count reconciliation"}
    elif env_scope == "all":
        recommended = {"strategy": "tfstate_monolith_decomposer", "cap": str(cap), "env_scope": "l2l3", "skip_unknown_type_review": True, "reason": "reduce cross-environment L1 fragmentation after reconcile failure"}
    elif cap != 0:
        recommended = {"strategy": "tfstate_monolith_decomposer", "cap": "0", "env_scope": env_scope, "skip_unknown_type_review": True, "reason": "remove cap split as a reconciliation variable"}
elif duplicate_count or unallocated_count:
    recommended = {"strategy": "tfstate_monolith_decomposer", "cap": "0", "env_scope": "all", "skip_unknown_type_review": True, "reason": "retry without cap and with provisional placement to eliminate duplicate/unallocated addresses"}
elif orphans and env_scope == "all":
    recommended = {"strategy": "tfstate_monolith_decomposer", "cap": str(cap), "env_scope": "l2l3", "skip_unknown_type_review": skip_unknown, "reason": "reduce orphaned resources by scoping application/platform layers by environment while keeping foundation global"}
elif orphans and env_scope == "l2l3":
    recommended = {"strategy": "tfstate_monolith_decomposer", "cap": str(cap), "env_scope": "l2", "skip_unknown_type_review": skip_unknown, "reason": "try platform-only environment scoping to lower orphan count"}
elif high_impact_count and not skip_unknown:
    recommended = {"strategy": "tfstate_monolith_decomposer", "cap": str(cap), "env_scope": env_scope, "skip_unknown_type_review": True, "reason": "treat unknown-type placements as provisional so the candidate can be scored against orphan count"}
elif "single_large_hairball" in issues or "large_component_without_size_cap" in issues:
    if cap == 0:
        recommended = {"strategy": "tfstate_monolith_decomposer", "cap": "120", "env_scope": env_scope, "skip_unknown_type_review": skip_unknown, "reason": "split oversized layered group with deterministic cap partitioning"}
elif "cross_shard_refs_high" in issues or "overfragmented_singletons" in issues:
    if cap != 0:
        recommended = {"strategy": "tfstate_monolith_decomposer", "cap": "0", "env_scope": env_scope, "skip_unknown_type_review": skip_unknown, "reason": "remove cap split to reduce cross-shard references and singleton fragmentation"}
elif "type_chunk_low_quality" in issues:
    recommended = {"strategy": "tfstate_monolith_decomposer", "cap": "0", "env_scope": env_scope, "skip_unknown_type_review": skip_unknown, "reason": "replace type chunking with layered decomposition"}

quality_pass = bool(count_ok and not hard and score >= 80 and not recommended)
report = {
    "attempt": attempt,
    "strategy": "tfstate_monolith_decomposer",
    "algorithm": "layered_three_tier",
    "max_resources_per_appstack": cap,
    "quality_score": score,
    "quality_pass": quality_pass,
    "issues": issues,
    "recommendation": recommended,
    "tuning_inputs": {
        "env_scope": env_scope,
        "env_tag_keys": env_tag_keys,
        "layer3_tag_keys": layer3_tag_keys,
        "skip_unknown_type_review": skip_unknown,
        "overrides_path": run_notes.get("tfstate_decomposer_overrides_path") or "",
        "layer_taxonomy_path": os.path.join(work_root, "layer_taxonomy.json") if os.path.isfile(os.path.join(work_root, "layer_taxonomy.json")) else "",
    },
    "metrics": {
        "count_reconciliation_ok": count_ok,
        "monolith_resource_count": monolith_count,
        "aggregate_group_resource_count": aggregate_count,
        "duplicate_address_count": duplicate_count,
        "unallocated_resource_count": unallocated_count,
        "group_count": group_count,
        "largest_group_size": largest,
        "smallest_group_size": smallest,
        "average_group_size": avg,
        "median_group_size": median,
        "singleton_group_count": singletons,
        "singleton_ratio": singleton_ratio,
        "oversized_group_count": oversized,
        "cross_shard_ref_count": cross_refs,
        "shared_ref_count": shared_refs,
        "bfs_cap_split_group_count": bfs_splits,
        "type_chunk_group_count": type_chunks,
        "shared_group_count": shared_groups,
        "orphan_count": orphans,
        "review_total_count": total_review,
        "high_impact_review_count": high_impact_count,
        "batch_rule_count": batch_rule_count,
        "auto_assigned_count": auto_assigned_count,
        "stale_override_count": stale_overrides,
        "cross_env_promotion_count": cross_env_promotions,
    },
}
with open(report_path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, sort_keys=True)

for name in (
    "logical_group_manifest.json",
    "shard_manifest.json",
    "per_group_resource_counts.json",
    "group_state_paths.json",
    "reconcile_result.json",
    "review_items.json",
    "layer_summary.json",
    "upstream_refs.json",
    "registry_mapping_report.json",
    "orphans_bundle.json",
):
    src = os.path.join(work_root, name)
    if os.path.isfile(src):
        dst = os.path.join(os.path.dirname(report_path), name)
        with open(src, "rb") as fh_src, open(dst, "wb") as fh_dst:
            fh_dst.write(fh_src.read())

print(report_path)
PY
}

cmd_tuned_split_manifest() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:?STATE_PATH}"
  local strategy="${3:?STRATEGY}"
  local cap="${4:?CAP}"
  local split_lock
  local attempt=1
  local max_attempts
  max_attempts="$(note_or_default "$work_root" "tfstate_decomposer_max_tuning_iterations" "$DBSPLIT_MAX_TUNING_ITERATIONS")"
  if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || [ "$max_attempts" -lt 1 ]; then
    max_attempts="$DBSPLIT_MAX_TUNING_ITERATIONS"
  fi
  local env_scope env_tag_keys layer3_tag_keys skip_unknown overrides_path
  env_scope="$(note_or_default "$work_root" "tfstate_decomposer_env_scope" "all")"
  env_tag_keys="$(read_note "$work_root" "tfstate_decomposer_env_tag_keys" 2>/dev/null || true)"
  layer3_tag_keys="$(read_note "$work_root" "tfstate_decomposer_layer3_tag_keys" 2>/dev/null || true)"
  skip_unknown="$(normalize_bool_note "$(read_note "$work_root" "tfstate_decomposer_skip_unknown_type_review" 2>/dev/null || true)")"
  overrides_path="$(resolve_decomposer_overrides_path "$work_root" || true)"
  cap="$(normalize_decomposer_cap "$cap")"
  strategy="tfstate_monolith_decomposer"

  local seen="|${strategy}:${cap}:${env_scope}:${skip_unknown}:${env_tag_keys}:${layer3_tag_keys}:${overrides_path}|"
  local best_score=-1
  local best_orphans=999999
  local best_strategy="tfstate_monolith_decomposer"
  local best_cap="$cap"
  local best_env_scope="$env_scope"
  local best_skip_unknown="$skip_unknown"
  local current_strategy="tfstate_monolith_decomposer"
  local current_cap="$cap"
  local current_env_scope="$env_scope"
  local current_skip_unknown="$skip_unknown"
  local final_report=""
  local history_path="${work_root}/split_tuning_history.json"

  split_lock="$(acquire_run_lock "$work_root" "split")" || {
    echo 'blocked:split_lock_timeout: "true"'
    return 1
  }
  # Non-SIGKILL paths must drop the lock; SIGKILL relies on dead-pid reclaim above.
  # shellcheck disable=SC2064
  trap 'release_run_lock "'"$split_lock"'"' EXIT
  mkdir -p "${work_root}/.work/split-quality"
  echo '[]' >"$history_path"
  resolve_decomposer_py "$work_root" >/dev/null

  while [ "$attempt" -le "$max_attempts" ]; do
    local split_rc=0
    set +e
    cmd_run_tfstate_monolith_decomposer "$work_root" "$state_path" "$current_cap" "$current_env_scope" "$env_tag_keys" "$layer3_tag_keys" "$current_skip_unknown" "$overrides_path"
    split_rc=$?
    set -e

    local report_path score pass orphan_count rec_strategy rec_cap rec_reason rec_env_scope rec_skip key
    report_path="$(cmd_evaluate_split_quality "$work_root" "$state_path" "$current_strategy" "$current_cap" "$attempt")"
    final_report="$report_path"
    jq --slurpfile r "$report_path" '. + [$r[0]]' "$history_path" >"${history_path}.tmp" && mv "${history_path}.tmp" "$history_path"
    score="$(jq -r '.quality_score' "$report_path")"
    pass="$(jq -r '.quality_pass' "$report_path")"
    orphan_count="$(jq -r '.metrics.orphan_count // 999999' "$report_path")"
    rec_strategy="$(jq -r '.recommendation.strategy // empty' "$report_path")"
    rec_cap="$(jq -r '.recommendation.cap // empty' "$report_path")"
    rec_reason="$(jq -r '.recommendation.reason // empty' "$report_path")"
    rec_env_scope="$(jq -r '.recommendation.env_scope // empty' "$report_path")"
    rec_skip="$(jq -r '.recommendation.skip_unknown_type_review // empty' "$report_path")"

    if [ "$score" -gt "$best_score" ] || { [ "$score" -eq "$best_score" ] && [ "$orphan_count" -lt "$best_orphans" ]; }; then
      best_score="$score"
      best_orphans="$orphan_count"
      best_strategy="$current_strategy"
      best_cap="$current_cap"
      best_env_scope="$current_env_scope"
      best_skip_unknown="$current_skip_unknown"
    fi

    echo "split_tuning_attempt=${attempt} strategy=${current_strategy} cap=${current_cap} env_scope=${current_env_scope} skip_unknown=${current_skip_unknown} score=${score} orphan_count=${orphan_count} pass=${pass} split_rc=${split_rc}"
    if [ "$pass" = "true" ] || [ -z "$rec_strategy" ] || [ -z "$rec_cap" ]; then
      break
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      break
    fi
    rec_strategy="${rec_strategy:-tfstate_monolith_decomposer}"
    rec_env_scope="${rec_env_scope:-$current_env_scope}"
    rec_skip="$(normalize_bool_note "${rec_skip:-$current_skip_unknown}")"
    rec_cap="$(normalize_decomposer_cap "$rec_cap")"
    key="|${rec_strategy}:${rec_cap}:${rec_env_scope}:${rec_skip}:${env_tag_keys}:${layer3_tag_keys}:${overrides_path}|"
    if [[ "$seen" == *"$key"* ]]; then
      echo "split_tuning_stop=repeat_recommendation strategy=${rec_strategy} cap=${rec_cap} env_scope=${rec_env_scope} skip_unknown=${rec_skip}"
      break
    fi
    seen="${seen}${rec_strategy}:${rec_cap}:${rec_env_scope}:${rec_skip}:${env_tag_keys}:${layer3_tag_keys}:${overrides_path}|"
    echo "split_tuning_rerun=true next_strategy=${rec_strategy} next_cap=${rec_cap} next_env_scope=${rec_env_scope} next_skip_unknown=${rec_skip} reason=${rec_reason}"
    current_strategy="$rec_strategy"
    current_cap="$rec_cap"
    current_env_scope="$rec_env_scope"
    current_skip_unknown="$rec_skip"
    attempt=$((attempt + 1))
  done

  if [ "$current_strategy" != "$best_strategy" ] || [ "$current_cap" != "$best_cap" ] || [ "$current_env_scope" != "$best_env_scope" ] || [ "$current_skip_unknown" != "$best_skip_unknown" ]; then
    echo "split_tuning_restore_best=true strategy=${best_strategy} cap=${best_cap} env_scope=${best_env_scope} skip_unknown=${best_skip_unknown} score=${best_score} orphan_count=${best_orphans}"
    cmd_run_tfstate_monolith_decomposer "$work_root" "$state_path" "$best_cap" "$best_env_scope" "$env_tag_keys" "$layer3_tag_keys" "$best_skip_unknown" "$overrides_path" || true
    final_report="$(cmd_evaluate_split_quality "$work_root" "$state_path" "$best_strategy" "$best_cap" "selected")"
  fi

  cp "$final_report" "${work_root}/split_quality_report.json"
  jq '
    . as $r
    | (($r.issues // []) | map(select(. == "count_reconciliation_failed" or . == "no_logical_groups" or . == "cap_violated" or . == "duplicate_addresses" or . == "unallocated_addresses")) | length) as $hard_issue_count
    | if (($r.quality_pass // false) == false and ($r.quality_score // 0) >= 70 and $hard_issue_count == 0) then
        . + {
          quality_pass: true,
          selection_reason: "best_candidate_after_bounded_tuning",
          residual_issues: (.issues // []),
          recommendation: null
        }
      else
        .
      end
  ' "${work_root}/split_quality_report.json" >"${work_root}/split_quality_report.json.tmp" \
    && mv "${work_root}/split_quality_report.json.tmp" "${work_root}/split_quality_report.json"
  mirror_note "$work_root" "split_quality_report" "${work_root}/split_quality_report.json"
  mirror_note "$work_root" "split_tuning_history" "$history_path"
  mirror_note "$work_root" "split_quality_score" "$(jq -r '.quality_score' "${work_root}/split_quality_report.json")"
  mirror_note "$work_root" "split_quality_pass" "$(jq -r '.quality_pass' "${work_root}/split_quality_report.json")"
  mirror_note "$work_root" "split_tuning_iterations" "$(jq 'length' "$history_path")"
  mirror_note "$work_root" "grouping_strategy" "tfstate_monolith_decomposer"
  mirror_note "$work_root" "max_resources_per_appstack" "$best_cap"
  mirror_note "$work_root" "tfstate_decomposer_env_scope" "$best_env_scope"
  mirror_note "$work_root" "tfstate_decomposer_skip_unknown_type_review" "$best_skip_unknown"
  mirror_note "$work_root" "tfstate_decomposer_orphan_count" "$(jq -r '.metrics.orphan_count // 0' "${work_root}/split_quality_report.json")"
  if [ "$(jq -r '.metrics.orphan_count // 0' "${work_root}/split_quality_report.json")" = "0" ]; then
    mirror_note "$work_root" "orphans_bundle_empty" "true"
    mirror_note "$work_root" "orphans_handoff_verified" "true"
    echo 'orphans_bundle_empty: "true"'
    echo 'orphans_handoff_verified: "true"'
  fi
  echo "split_quality_report=${work_root}/split_quality_report.json"
  echo "split_tuning_history=${history_path}"
  release_run_lock "$split_lock"
  trap - EXIT
}

cmd_ingest_and_split() {
  local work_root="${1:?WORK_ROOT}"
  local state_uri="${2:-}"
  local strategy="${3:-}"
  local cap="${4:-}"

  cmd_preflight "$work_root" >/dev/null
  ensure_monolith_uri_from_work_root "$work_root" || true
  state_uri="$(resolve_state_uri "$state_uri")"
  if [ -z "$state_uri" ]; then
    echo "download_error=missing_monolith_state_uri_or_tfstate_file"
    return 1
  fi
  export MONOLITH_URI="$state_uri"
  cmd_download_state "$work_root" "$state_uri" >/dev/null
  mirror_note "$work_root" "ingest_stage_progress" "split_start"

  local state_path="${work_root}/state/terraform.tfstate"
  if [ -z "$strategy" ]; then
    strategy="$(note_or_default "$work_root" "grouping_strategy" "$DBSPLIT_DEFAULT_STRATEGY")"
  fi
  if [ -z "$cap" ]; then
    cap="$(note_or_default "$work_root" "max_resources_per_appstack" "$DBSPLIT_DEFAULT_CAP")"
  fi

  cmd_split_manifest "$work_root" "$state_path" "$strategy" "$cap"
}

cmd_split_manifest() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:-${work_root}/state/terraform.tfstate}"
  local strategy cap
  strategy="$(note_or_default "$work_root" "grouping_strategy" "$DBSPLIT_DEFAULT_STRATEGY")"
  cap="$(note_or_default "$work_root" "max_resources_per_appstack" "$DBSPLIT_DEFAULT_CAP")"
  if [ -n "${3:-}" ]; then
    strategy="$3"
  fi
  if [ -n "${4:-}" ]; then
    cap="$4"
  fi

  require_embedded_invocation || return 1

  if [ ! -f "$state_path" ]; then
    echo "split_error=state_file_missing path=${state_path}"
    return 1
  fi

  local readiness_rc=0
  set +e
  cmd_tuned_split_manifest "$work_root" "$state_path" "$strategy" "$cap"
  readiness_rc=$?
  set -e

  # Grouping analysis helps reviewers, but it is not required to generate
  # valid Terraform. Continue when the actual split outputs are complete.
  if [ ! -s "${work_root}/logical_group_manifest.json" ] || [ ! -s "${work_root}/group_state_paths.json" ]; then
    echo "split_error=required_group_files_missing"
    return 1
  fi

  strategy="$(read_note "$work_root" "grouping_strategy" 2>/dev/null || printf '%s' "$strategy")"
  cap="$(read_note "$work_root" "max_resources_per_appstack" 2>/dev/null || printf '%s' "$cap")"

  _mirror_manifest_notes "$work_root" "$strategy" "$cap"

  local ok
  ok="$(read_note "$work_root" "count_reconciliation_ok" 2>/dev/null || true)"
  if [ -z "$ok" ] && [ -f "${work_root}/reconcile_result.json" ]; then
    ok="$(jq -r '.count_reconciliation_ok' "${work_root}/reconcile_result.json")"
  fi
  ok="$(printf '%s' "$ok" | tr '[:upper:]' '[:lower:]')"
  mirror_note "$work_root" "count_reconciliation_ok" "$ok"
  mirror_note "$work_root" "group_state_paths" "${work_root}/group_state_paths.json"
  mirror_note "$work_root" "logical_group_seeds_path" "${work_root}/logical_group_seeds.json"
  mirror_note "$work_root" "db_anchor_inventory_path" "${work_root}/db_anchor_inventory.json"

  local quality_pass quality_status readiness_path
  quality_pass="$(read_note "$work_root" "split_quality_pass" 2>/dev/null || echo false)"
  readiness_path="${work_root}/readiness-suggestions.md"
  if [ "$readiness_rc" -eq 0 ] && [ -s "${work_root}/split_quality_report.json" ]; then
    quality_status="available"
  else
    quality_status="not_available"
    cat >"$readiness_path" <<'EOF'
# Ways to improve readiness

The Terraform files can still be generated and validated. This optional
analysis was not available for this run.

- Add consistent application, environment, and owner tags to related resources.
- Review whether shared networking and security resources belong in separate folders.
- Run a zero-change Terraform plan with AWS read credentials before using the files.
EOF
    mirror_note "$work_root" "readiness_suggestions_path" "$readiness_path"
  fi
  mirror_note "$work_root" "split_quality_status" "$quality_status"
  # Quoted sentinels so agent "not produced" prose cannot false-FINISH the loop
  # (session c38ad01b: "count_reconciliation_ok=true … were not produced").
  echo "count_reconciliation_ok: \"${ok}\""
  echo "count_reconciliation_ok=${ok}"
  echo "split_quality_pass=${quality_pass}"
  echo "split_quality_status=${quality_status}"
  emit_script_pack_verify "$work_root"
  emit_ingest_handoff_summary "$work_root"

  if [ "$ok" != "true" ]; then
    mirror_note "$work_root" "stage_summary:ingest-and-split" "blocked:count_reconciliation_failed"
    echo 'stage_summary:ingest-and-split=blocked:count_reconciliation_failed'
    return 1
  fi
  mirror_note "$work_root" "stage_summary:ingest-and-split" "ok"
  if [ "$quality_status" = "not_available" ]; then
    echo "readiness_warning=optional_grouping_analysis_not_available"
  fi
  echo 'stage_summary:ingest-and-split=ok'
}

# emit_script_pack_verify records script-pack SHA verification and warns on single ungrouped hairballs.
emit_script_pack_verify() {
  local work_root="${1:?WORK_ROOT}"
  local py_path="${work_root}/scripts/allocate_manifest.py"
  local decomposer_path="${work_root}/scripts/tfstate_monolith_decomposer.py"
  local verify_ok="false"

  if verify_allocate_manifest_py "$py_path" && verify_decomposer_py "$decomposer_path"; then
    verify_ok="true"
  fi

  mirror_note "$work_root" "script_pack_verify_ok" "$verify_ok"
  mirror_note "$work_root" "script_pack_version" "$SCRIPT_PACK_VERSION"
  echo "script_pack_verify_ok: \"${verify_ok}\""
  echo "script_pack_verify_ok=${verify_ok}"
  echo "script_pack_version=${SCRIPT_PACK_VERSION}"

  if [ "$verify_ok" != "true" ]; then
    mirror_note "$work_root" "blocked:ingest_script_pack_failed" "true"
    echo 'blocked:ingest_script_pack_failed: "true"'
    return 1
  fi

  local group_count monolith_count only_group
  group_count="$(read_note "$work_root" "logical_group_count" 2>/dev/null || true)"
  monolith_count="$(read_note "$work_root" "monolith_resource_count" 2>/dev/null || true)"
  if [ "${group_count:-0}" = "1" ] && [ "${monolith_count:-0}" -gt 5000 ]; then
    only_group="$(jq -r 'keys[0] // empty' "${work_root}/logical_group_manifest.json" 2>/dev/null || true)"
    if [ "$only_group" = "ungrouped" ]; then
      mirror_note "$work_root" "script_pack_drift_possible" "true"
      echo 'script_pack_drift_possible: "true"'
    fi
  fi

  return 0
}

cmd_count_reconcile() {
  local work_root="${1:?WORK_ROOT}"
  local state_path="${2:-${work_root}/state/terraform.tfstate}"
  local manifest_path="${work_root}/logical_group_manifest.json"

  if [ ! -f "$manifest_path" ]; then
    echo "reconcile_error=missing_logical_group_manifest"
    return 1
  fi

  local result ok
  result="$(run_decomposer_py "$work_root" reconcile "$state_path" "$manifest_path")"
  echo "$result"

  ok="$(printf '%s' "$result" | jq -r '.count_reconciliation_ok')"
  local monolith_count aggregate dupes unallocated
  monolith_count="$(printf '%s' "$result" | jq -r '.monolith_resource_count')"
  aggregate="$(printf '%s' "$result" | jq -r '.aggregate_group_resource_count')"
  dupes="$(printf '%s' "$result" | jq -r '.duplicate_address_count')"
  unallocated="$(printf '%s' "$result" | jq -r '.unallocated_resource_count')"

  mirror_note "$work_root" "monolith_resource_count" "$monolith_count"
  mirror_note "$work_root" "count_reconciliation_ok" "$ok"
  mirror_note "$work_root" "aggregate_group_resource_count" "$aggregate"
  mirror_note "$work_root" "duplicate_address_groups" "$dupes"
  mirror_note "$work_root" "unallocated_resource_count" "$unallocated"

  echo "count_reconciliation_ok=${ok}"
  echo "monolith_resource_count=${monolith_count}"
  echo "aggregate_group_resource_count=${aggregate}"
}

# SCM github vault sync injects `token` (not GIT_TOKEN/GH_TOKEN). Accept all aliases.
resolve_git_token() {
  printf '%s' "${GIT_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-${token:-}}}}"
}

bootstrap_gh() {
  local git_token
  git_token="$(resolve_git_token)"
  export GIT_TOKEN="$git_token" GH_TOKEN="$git_token" GITHUB_TOKEN="$git_token"
  export GIT_TERMINAL_PROMPT=0
  if [ -z "$git_token" ]; then
    echo "gh_env_present=false"
    return 1
  fi
  echo "gh_env_present=true"
  # The runner HOME is shared by concurrent workflows. `gh auth setup-git`
  # and `git config --global` both rewrite ~/.gitconfig and race on its lock.
  # Use environment-scoped git config inherited by this process and its children.
  local config_count="${GIT_CONFIG_COUNT:-0}"
  case "$config_count" in ''|*[!0-9]*) config_count=0 ;; esac
  export "GIT_CONFIG_KEY_${config_count}=user.name"
  export "GIT_CONFIG_VALUE_${config_count}=stackgen-aws-migrator"
  config_count=$((config_count + 1))
  export "GIT_CONFIG_KEY_${config_count}=user.email"
  export "GIT_CONFIG_VALUE_${config_count}=aws-migrator@stackgen.local"
  export GIT_CONFIG_COUNT="$((config_count + 1))"
}

git_clone_url() {
  local url="${1:?REPO_CLONE_URL}"
  local git_token
  git_token="$(resolve_git_token)"
  if [[ "$url" =~ ^git@ ]]; then
    printf '%s' "$url"
    return 0
  fi
  if [[ "$url" =~ ^https://[^/@]+@ ]]; then
    printf '%s' "$url"
    return 0
  fi
  if [ -n "$git_token" ] && [[ "$url" =~ ^https://github\.com/ ]]; then
    printf 'https://x-access-token:%s@github.com/%s' "$git_token" "${url#https://github.com/}"
    return 0
  fi
  printf '%s' "$url"
}

resolve_repo_dir() {
  local work_root="${1:?WORK_ROOT}"
  local repo_dir="$work_root/repo"
  local legacy_dir="$work_root/repo_clone"
  if [ -d "$repo_dir/.git" ]; then
    printf '%s' "$repo_dir"
    return 0
  fi
  if [ -d "$legacy_dir/.git" ]; then
    ln -sfn "$legacy_dir" "$repo_dir" 2>/dev/null || true
    mirror_note "$work_root" "repo_clone_path" "$repo_dir"
    printf '%s' "$repo_dir"
    return 0
  fi
  printf '%s' "$repo_dir"
}

repo_full_name_from_url() {
  local url="${1:?URL}"
  url="${url%.git}"
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s' "$url"
}

sanitize_branch_component() {
  local value="${1:-run}"
  value="$(printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$value" ]; then
    value="run"
  fi
  printf '%s' "$value"
}

git_branch_or_pr_exists() {
  local repo_full="${1:-}"
  local branch="${2:?BRANCH}"
  if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
    return 0
  fi
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$repo_full" ] && command -v gh >/dev/null 2>&1; then
    local pr_count
    pr_count="$(gh pr list --repo "$repo_full" --state all --head "$branch" --json number -q 'length' 2>/dev/null || echo 0)"
    case "$pr_count" in
      ''|*[!0-9]*) pr_count=0 ;;
    esac
    if [ "$pr_count" -gt 0 ]; then
      return 0
    fi
  fi
  return 1
}

allocate_unique_pr_branch() {
  local repo_full="${1:-}"
  local prefix="${2:?PREFIX}"
  local workflow_run_id="${3:-run}"
  local safe_run_id base branch stamp i

  safe_run_id="$(sanitize_branch_component "$workflow_run_id")"
  base="${prefix}/${safe_run_id}"
  if ! git_branch_or_pr_exists "$repo_full" "$base"; then
    printf '%s' "$base"
    return 0
  fi

  stamp="$(date -u +%Y%m%d%H%M%S)-$$"
  for i in $(seq 1 20); do
    if [ "$i" -eq 1 ]; then
      branch="${base}-${stamp}"
    else
      branch="${base}-${stamp}-${i}"
    fi
    if ! git_branch_or_pr_exists "$repo_full" "$branch"; then
      printf '%s' "$branch"
      return 0
    fi
  done

  printf '%s-%s-%s' "$base" "$stamp" "$(date +%s%N 2>/dev/null || date +%s)"
}

# Commit pathspecs that have changes. Returns 0 when a commit was created,
# 2 when there was nothing to commit (caller may treat as non-fatal skip).
git_commit_paths_if_changed() {
  local message="${1:?COMMIT_MESSAGE}"
  shift
  if [ "$#" -lt 1 ]; then
    return 2
  fi
  local path
  for path in "$@"; do
    if [ -e "$path" ] || git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
      # --force so a global *.tfstate ignore rule can never silently drop the
      # monolith / shard state the discovery PR must carry (trace 1c64c4a5:
      # aws/artifacts/cloud2code/*/terraform.tfstate was skipped by gitignore).
      git add -A --force -- "$path" 2>/dev/null || git add --force -- "$path" 2>/dev/null || true
    fi
  done
  if git diff --cached --quiet; then
    return 2
  fi
  # Quiet commit: hundreds of "create mode" lines flood dbsplit_run_stage's
  # transcript tail and push gcp_pr_url / azure_pr_url past the model truncation
  # window (false missing_runner_evidence after a successful PR).
  local shortstat
  shortstat="$(git diff --cached --shortstat | tr -d '\n' || true)"
  git commit --quiet -m "$message" || return 1
  echo "git_commit_ok message=${message} ${shortstat}"
  return 0
}

# Push current HEAD and open a PR. Prints pr_url to stdout on success.
git_push_and_open_pr() {
  local repo_full="${1:?REPO}"
  local default_branch="${2:?BASE}"
  local branch="${3:?HEAD}"
  local pr_title="${4:?TITLE}"
  local pr_body_file="${5:?BODY_FILE}"
  local err_dir="${6:?ERR_DIR}"

  mkdir -p "$err_dir"
  # Keep stdout clean for callers that capture pr_url — push chatter goes to stderr only.
  if ! git push -u origin "$branch" >/dev/null 2>"${err_dir}/push.err"; then
    cat "${err_dir}/push.err" >&2 || true
    return 1
  fi
  local pr_url=""
  if ! pr_url="$(gh pr create --repo "$repo_full" --base "$default_branch" --head "$branch" \
    --title "$pr_title" --body-file "$pr_body_file" 2>"${err_dir}/pr-create.err")"; then
    cat "${err_dir}/pr-create.err" >&2 || true
    return 1
  fi
  # gh may print warnings before the URL; keep only the pull URL line.
  pr_url="$(printf '%s\n' "$pr_url" | grep -Eo 'https://github.com/[^[:space:]]+/pull/[0-9]+' | tail -1 || true)"
  if [ -z "$pr_url" ]; then
    echo "pr_create_error=no_url_in_gh_output" >&2
    cat "${err_dir}/pr-create.err" >&2 || true
    return 1
  fi
  printf '%s' "$pr_url"
}

write_destination_todo_md() {
  local work_root="${1:?WORK_ROOT}"
  local cloud="${2:?CLOUD}" # azure|gcp
  local out_file="${work_root}/${cloud}/artifacts/TODO.md"
  local review_src="${work_root}/${cloud}/artifacts/review-needed.md"
  local validation_src="${work_root}/${cloud}/artifacts/validation-report.json"
  local gen_src="${work_root}/${cloud}/artifacts/generation-summary.json"
  local blueprint_src="${work_root}/${cloud}/artifacts/migration-blueprint.json"
  local cloud_title groups review_count validation_ok plan_status plan_key
  local static_fail plan_fail emission_full emission_iam emission_none emission_profile
  local infra_rate app_iam_rate mode live_ids fail_ids empty_skip_count
  local start_blocker=""

  cloud_title="$(printf '%s' "$cloud" | tr '[:lower:]' '[:upper:]')"
  groups="$(jq -r '.generated_group_count // .group_count // "unknown"' "$gen_src" 2>/dev/null || echo unknown)"
  review_count="$(jq -r '.review_needed_count // "unknown"' "$blueprint_src" 2>/dev/null || echo unknown)"
  if [ "$cloud" = "azure" ]; then
    plan_key="azure_plan_status"
  else
    plan_key="gcp_plan_status"
  fi
  validation_ok="$(jq -r '.validation_ok // "unknown"' "$validation_src" 2>/dev/null || echo unknown)"
  plan_status="$(jq -r --arg k "$plan_key" '.[$k] // "unknown"' "$validation_src" 2>/dev/null || echo unknown)"
  static_fail="$(jq -r '.static_fail_count // 0' "$validation_src" 2>/dev/null || echo 0)"
  plan_fail="$(jq -r '.plan_fail_count // 0' "$validation_src" 2>/dev/null || echo 0)"
  emission_full="$(jq -r '.emission_counts.full_scaffold // 0' "$gen_src" 2>/dev/null || echo 0)"
  emission_iam="$(jq -r '.emission_counts.managed_identity_rbac_scaffold // 0' "$gen_src" 2>/dev/null || echo 0)"
  emission_none="$(jq -r '.emission_counts.none // 0' "$gen_src" 2>/dev/null || echo 0)"
  emission_profile="$(jq -r '.emission_counts.profile_scaffold // 0' "$gen_src" 2>/dev/null || echo 0)"
  infra_rate="$(jq -r '.infra_conversion_rate // "unknown"' "$gen_src" 2>/dev/null || echo unknown)"
  app_iam_rate="$(jq -r '.app_iam_conversion_rate // "unknown"' "$gen_src" 2>/dev/null || echo unknown)"
  mode="$(jq -r '.mode // "review_candidate"' "$gen_src" 2>/dev/null || echo review_candidate)"
  live_ids="$(jq -r '[.groups[]? | select((.plan_status // "") | tostring | test("success"))] | map(.group_id) | join(", ")' "$validation_src" 2>/dev/null || true)"
  fail_ids="$(jq -r '[.groups[]? | select(.validate == false or .validate == "false")] | map(.group_id) | .[0:12] | join(", ")' "$validation_src" 2>/dev/null || true)"
  empty_skip_count="$(jq -r '[.groups[]? | select((.validate // "") | tostring | test("empty_scaffold"))] | length' "$validation_src" 2>/dev/null || echo 0)"

  local gov_note_ok
  gov_note_ok="$(read_note "$work_root" "${cloud}_iac_governance_ok" 2>/dev/null || true)"
  if [ "$gov_note_ok" != "true" ] \
    && { [ -f "${work_root}/${cloud}/artifacts/governance-opa-findings.json" ] \
      || [ -f "${work_root}/${cloud}/artifacts/governance-conformance-report.json" ]; }; then
    start_blocker="Governance/OPA residuals remain — clear them from governance-opa-fix-hints.md / governance-exceptions.md before merge (see Nile governance section)."
  elif [ "$static_fail" != "0" ] && [ "$static_fail" != "unknown" ]; then
    start_blocker="Fix static validate failures first (${static_fail} group(s))."
  elif printf '%s' "$plan_status" | grep -Eq 'missing_credentials|skipped:missing'; then
    start_blocker="Static HCL may look fine, but there is no live plan sample — attach ${cloud_title} credentials and re-run validate before trusting apply-shape."
  elif [ "$validation_ok" = "false" ]; then
    start_blocker="validation_ok=false — treat this PR as blocked for merge until static/live findings are cleared or explicitly accepted."
  else
    start_blocker="No hard validate blocker recorded — still review-candidate IaC; do not apply until the checklist below is done."
  fi

  mkdir -p "$(dirname "$out_file")"
  {
    echo "# ${cloud_title} migration TODO"
    echo
    echo "> **Mode:** \`${mode}\` — review-candidate only. **Do not apply** until placeholders, IAM translations, and review-needed items are resolved."
    echo
    echo "${start_blocker}"
    echo
    echo "## Contents"
    echo
    echo "1. [Start here](#start-here)"
    echo "2. [Run snapshot](#run-snapshot)"
    echo "3. [Blockers and attention](#blockers-and-attention)"
    echo "4. [How to review (shape vs permissions vs defer)](#how-to-review-shape-vs-permissions-vs-defer)"
    echo "5. [Review-needed index](#review-needed-index)"
    echo "6. [Lint / security harden](#lint--security-harden)"
    echo "7. [Nile governance / OPA residuals](#nile-governance--opa-residuals)"
    echo "8. [Validation detail](#validation-detail)"
    echo "9. [Artifact map](#artifact-map)"
    echo "10. [Sign-off checklist](#sign-off-checklist)"
    echo
    echo "## Start here"
    echo
    echo "Work top-down. Stop if a higher item fails."
    echo
    echo "1. **Read this file + the PR body** — confirm this PR is for the intended AWS source branch/PR."
    echo "2. **Clear blockers** in [Blockers and attention](#blockers-and-attention) and [Nile governance / OPA](#nile-governance--opa-residuals) (static fails, missing live plan, OPA denies)."
    echo "3. **Ambiguous first** — LB L4/L7, engine choice, EKS/ECS/VM/Lambda, etc. (mandatory HITL)."
    echo "4. **Permissions next** (\`${emission_iam}\` IAM scaffolds) — translate AWS actions → cloud RBAC; comments are not permissions."
    echo "5. **Shape spot-check** (\`${emission_full}\` full_scaffold) — CIDR/SKU/naming/wiring; catalog bumps cleared many of these from mandatory review."
    echo "6. **Defer stubs** (\`${emission_none}\` none / non_applicable) unless production depends on them."
    echo "7. **Use** [\`review-needed.md\`](./review-needed.md) for per-group why — do not treat conversion_rate=\`${infra_rate}\` as estate coverage."
    echo
    echo "## Run snapshot"
    echo
    echo "| Item | Value |"
    echo "| --- | --- |"
    echo "| Generated groups | \`${groups}\` |"
    echo "| Review-needed groups | \`${review_count}\` |"
    echo "| validation_ok | \`${validation_ok}\` |"
    echo "| plan_status | \`${plan_status}\` |"
    echo "| static_fail_count | \`${static_fail}\` |"
    echo "| plan_fail_count | \`${plan_fail}\` |"
    echo "| empty_scaffold skips | \`${empty_skip_count}\` |"
    echo "| emission full_scaffold | \`${emission_full}\` |"
    echo "| emission managed_identity_rbac_scaffold | \`${emission_iam}\` |"
    echo "| emission none | \`${emission_none}\` |"
    echo "| emission profile_scaffold | \`${emission_profile}\` |"
    echo "| infra_conversion_rate (mapped eligible only) | \`${infra_rate}\` |"
    echo "| app_iam_conversion_rate | \`${app_iam_rate}\` |"
    echo
    echo "## Blockers and attention"
    echo
    if [ -n "$fail_ids" ]; then
      echo "### Static validate failures"
      echo
      echo "- Groups: \`${fail_ids}\`"
      echo "- Open each group under \`${cloud}/groups/<id>/\` and fix HCL (or accept and document)."
      echo "- Details: \`validation-report.json\` → \`groups[].validate_error\`."
      echo
    else
      echo "- No \`validate=false\` groups in the validation report."
      echo
    fi
    if printf '%s' "$plan_status" | grep -Eq 'missing_credentials|skipped:missing'; then
      echo "### Live plan missing"
      echo
      echo "- Status: \`${plan_status}\`"
      if [ "$cloud" = "azure" ]; then
        echo "- Next: ensure runner has \`ARM_*\` (or Azure integration secrets), re-run \`azure-iac-validate\`, confirm a diversified sample includes platform + at least one app group."
      else
        echo "- Next: ensure runner has GCP ADC / \`GOOGLE_*\`, re-run \`gcp-iac-validate\`, confirm sample includes platform + app groups."
      fi
      echo
    elif [ -n "$live_ids" ]; then
      echo "### Live plan sample present"
      echo
      echo "- Groups planned successfully: \`${live_ids}\`"
      echo "- Confirm creates-only (no deletes/replaces) in \`validation-report.json\` \`plan_counts\`."
      echo
    else
      echo "- No successful live plan groups recorded."
      echo
    fi
    echo "### Metric caveats (read before celebrating 1.0 rates)"
    echo
    echo "- \`infra_conversion_rate\` / \`app_iam_conversion_rate\` only cover catalog-eligible mapped types — they exclude \`none\` / non-applicable."
    echo "- Healthy **shape** groups may clear \`review_needed\` after catalog confidence bumps; that is intentional — still spot-check platform roots."
    echo "- Identity scaffolds are not finished IAM — translate actions before apply."
    echo
    echo "## How to review (shape vs permissions vs defer)"
    echo
    echo "| Lane | Meaning | Action |"
    echo "| --- | --- | --- |"
    echo "| **ambiguous** | Real product/engine/topology choice (LB L4/L7, RDS engine, EKS, …) | Mandatory HITL before merge |"
    echo "| **permissions** | \`managed_identity_rbac_scaffold\` — AWS actions are HCL comments | Translate to cloud RBAC or defer with owner |"
    echo "| **shape** | Well-templated \`full_scaffold\` (subnet/SG/NAT/DNS/SQS/…) | Spot-check CIDR/SKU/naming; often not \`review_needed\` |"
    echo "| **defer** | \`none\` / non_applicable companions | Usually skip; accept or handle outside generated roots |"
    echo
    echo "| Priority | What | Where |"
    echo "| --- | --- | --- |"
    echo "| P0 | Static fails / missing credentials | sections above |"
    echo "| P1 | Ambiguous groups | [\`review-needed.md\`](./review-needed.md) Ambiguous index |"
    echo "| P2 | Permissions / IAM scaffolds (\`${emission_iam}\`) | \`${cloud}/groups/\` + review-needed Permissions |"
    echo "| P3 | Shape spot-check (\`${emission_full}\` full_scaffold, esp. platform/app) | \`${cloud}/groups/\` |"
    echo "| P4 | Defer stubs (\`${emission_none}\`) | accept or external |"
    echo
    echo "## Review-needed index"
    echo
    if [ -f "$review_src" ]; then
      echo "- Full per-group detail: [\`review-needed.md\`](./review-needed.md) — open the file outline, or jump via links below."
      echo "- Count: \`${review_count}\` groups (do **not** paste the whole file into chat)."
      echo
      if [ -f "$blueprint_src" ] && command -v jq >/dev/null 2>&1; then
        echo "### Lane counts (from blueprint)"
        echo
        echo "| Lane | Groups (primary) |"
        echo "| --- | --- |"
        echo "| ambiguous | \`$(jq -r '.hitl_lane_counts.ambiguous // 0' "$blueprint_src")\` |"
        echo "| permissions | \`$(jq -r '.hitl_lane_counts.permissions // 0' "$blueprint_src")\` |"
        echo "| shape | \`$(jq -r '.hitl_lane_counts.shape // 0' "$blueprint_src")\` |"
        echo "| defer | \`$(jq -r '.hitl_lane_counts.defer // 0' "$blueprint_src")\` |"
        echo
        echo "### Skim first — ambiguous + permissions review-needed"
        echo
        jq -r '
          [.groups[]?
            | select(.review_needed == true)
            | select((.primary_hitl_lane // "") == "ambiguous" or (.primary_hitl_lane // "") == "permissions")
            | .group_id
          ] | .[0:25][]
          | "- [`" + . + "`](./review-needed.md#" + . + ")"
        ' "$blueprint_src" 2>/dev/null || true
        echo
      fi
      if [ -f "$gen_src" ] && command -v jq >/dev/null 2>&1; then
        echo "### Optional — review-needed still carrying \`full_scaffold\`"
        echo
        jq -r '
          [.groups[]?
            | select(.review_needed == true)
            | select((.emissions // []) | index("full_scaffold"))
            | .group_id
          ] | .[0:15][]
          | "- [`" + . + "`](./review-needed.md#" + . + ")"
        ' "$gen_src" 2>/dev/null || true
        full_n="$(jq -r '[.groups[]? | select(.review_needed == true) | select((.emissions // []) | index("full_scaffold"))] | length' "$gen_src" 2>/dev/null || echo 0)"
        echo
        echo "_Showing up to 15 of \`${full_n}\` full_scaffold review-needed groups (often mixed with ambiguous/permissions)._"
        echo
      else
        echo "### First groups listed (skim these first)"
        echo
        awk '
          BEGIN { n=0 }
          /^## / {
            id=$0; sub(/^## /,"",id);
            if (id ~ /Contents|Summary|How to navigate|Index|Actionable|Non-applicable|Ambiguous|Permissions|Shape|Defer/) next;
            n++;
            if (n<=15) printf("- [`%s`](./review-needed.md#%s)\n", id, id);
          }
        ' "$review_src" || true
        echo
        echo "_…see \`review-needed.md\` for the rest._"
        echo
      fi
    else
      echo "- No \`review-needed.md\` was generated for this run."
      echo
    fi
    echo "## Lint / security harden"
    echo
    local harden_report="${work_root}/${cloud}/artifacts/harden-report.json"
    local harden_md="${work_root}/${cloud}/artifacts/harden-findings.md"
    if [ -f "$harden_report" ]; then
      echo "- Report: [\`harden-report.json\`](./harden-report.json)"
      if [ -f "$harden_md" ]; then
        echo "- Findings summary: [\`harden-findings.md\`](./harden-findings.md)"
      fi
      echo
      echo "| Metric | Value |"
      echo "| --- | --- |"
      echo "| Autofixes | \`$(jq -r '.autofix_count // 0' "$harden_report")\` |"
      echo "| Residual findings | \`$(jq -r '.residual_count // .finding_count // 0' "$harden_report")\` |"
      echo "| fmt failures | \`$(jq -r '.fmt_fail_count // 0' "$harden_report")\` |"
      echo "| tflint failures | \`$(jq -r '.lint_fail_count // 0' "$harden_report")\` |"
      echo "| Scanner finding groups | \`$(jq -r '.scanner_finding_groups // 0' "$harden_report")\` |"
      echo
      echo "- Autofixes already applied under \`${cloud}/groups/\` (same PR). Review residual high findings only."
      echo
    else
      echo "- Harden stage has not run yet (or report missing). After \`${cloud}-iac-harden\`, autofixes + scanner findings appear here."
      echo
    fi
    echo "Agents refresh Governance-and-Policy each run and author a validator from **this-run** docs (not a frozen catalog). They must remediate mechanical OPA denies (labels/tags/flags named in deny messages) before finishing the governance loop."
    echo
    emit_governance_residual_md "$work_root" "$cloud"
    echo "## Validation detail"
    echo
    echo "- Report file: [\`validation-report.json\`](./validation-report.json)"
    echo "- Generation summary: [\`generation-summary.json\`](./generation-summary.json)"
    if command -v jq >/dev/null 2>&1 && [ -f "$validation_src" ]; then
      echo
      echo '```json'
      jq --arg pk "$plan_key" '{
        validation_ok,
        plan_status: .[$pk],
        group_count,
        static_fail_count,
        plan_fail_count,
        live_success_groups: [ .groups[]? | select((.plan_status // "") | tostring | test("success")) | {group_id, plan_status, plan_counts} ],
        static_fail_groups: [ .groups[]? | select(.validate == false or .validate == "false") | {group_id, validate_error} ]
      }' "$validation_src" 2>/dev/null || true
      echo '```'
      echo
    fi
    echo "## Artifact map"
    echo
    echo "| Path | Use |"
    echo "| --- | --- |"
    echo "| \`${cloud}/artifacts/TODO.md\` | This checklist |"
    echo "| \`${cloud}/artifacts/review-needed.md\` | Per-group review reasons |"
    echo "| \`${cloud}/artifacts/harden-report.json\` | Lint/security autofix rollup |"
    echo "| \`${cloud}/artifacts/harden-findings.md\` | Residual harden findings |"
    echo "| \`${cloud}/artifacts/governance-source.json\` | Living governance repo/ref/SHA used this run |"
    echo "| \`${cloud}/artifacts/resource-inventory.json\` | Per-resource type/file inventory |"
    echo "| \`${cloud}/artifacts/governance-decision-tree.json\` | This-run tree derived from current docs |"
    echo "| \`${cloud}/artifacts/governance-validator.py\` | Agent-authored validator from that tree |"
    echo "| \`${cloud}/artifacts/governance-findings.json\` | Per-resource control findings |"
    echo "| \`${cloud}/artifacts/governance-conformance-report.json\` | Rollup + iteration + gov SHA |"
    echo "| \`${cloud}/artifacts/governance-exceptions.md\` | Validator blocking residuals |"
    echo "| \`${cloud}/artifacts/governance-opa-findings.json\` | OPA deny rollup |"
    echo "| \`${cloud}/artifacts/governance-opa-fix-hints.md\` | Mechanical HCL fix hints from OPA |"
    echo "| \`${cloud}/artifacts/validation-report.json\` | Static + live plan matrix |"
    echo "| \`${cloud}/artifacts/generation-summary.json\` | Emission + conversion counters |"
    echo "| \`${cloud}/artifacts/mapping-decisions.json\` | Full mapping table by group |"
    echo "| \`${cloud}/artifacts/migration-blueprint.json\` | Blueprint + review_needed_count |"
    echo "| \`${cloud}/groups/<id>/\` | OpenTofu root to inspect/edit |"
    echo
    echo "## Sign-off checklist"
    echo
    echo "- [ ] Confirmed AWS source PR/branch matches this destination PR"
    echo "- [ ] Static validate failures resolved or explicitly accepted"
    echo "- [ ] Harden residual high findings reviewed (or accepted)"
    echo "- [ ] Nile Priority-1 + OPA residuals cleared (see \`governance-exceptions.md\` / \`governance-opa-fix-hints.md\`); SHA in \`governance-source.json\`"
    echo "- [ ] Live plan sample reviewed (or credentials gap accepted with follow-up ticket)"
    echo "- [ ] Sampled plans show expected creates only (no deletes/replaces)"
    echo "- [ ] Ambiguous HITL groups resolved (or accepted with owner)"
    echo "- [ ] Permissions / IAM scaffolds: translated or deferred with owner"
    echo "- [ ] Shape spot-check done for platform/app full_scaffold roots"
    echo "- [ ] Defer / non-applicable groups understood (marker vs missing work)"
    echo "- [ ] **Not** treating infra/app-IAM conversion 1.0 as \"fully migrated\""
    echo "- [ ] Apply gated behind human approval / separate change window"
    echo
  } >"$out_file"
}

write_aws_discovery_todo_md() {
  local work_root="${1:?WORK_ROOT}"
  local artifacts_dir="${2:-${work_root}/aws/artifacts}"
  local out_file="${artifacts_dir}/TODO.md"
  local quality_src="${artifacts_dir}/split_quality_report.json"
  local review_src="${artifacts_dir}/review_items.json"
  local group_count resource_count recon quality_pass quality_score orphan_count
  local high_impact residual start_blocker=""

  group_count="$(read_note "$work_root" "logical_group_count" 2>/dev/null || echo unknown)"
  resource_count="$(read_note "$work_root" "monolith_resource_count" 2>/dev/null || echo unknown)"
  recon="$(read_note "$work_root" "count_reconciliation_ok" 2>/dev/null || echo unknown)"
  quality_pass="$(read_note "$work_root" "split_quality_pass" 2>/dev/null || echo unknown)"
  orphan_count="$(read_note "$work_root" "tfstate_decomposer_orphan_count" 2>/dev/null || echo unknown)"
  if [ -f "$quality_src" ] && command -v jq >/dev/null 2>&1; then
    quality_score="$(jq -r '.quality_score // "unknown"' "$quality_src" 2>/dev/null || echo unknown)"
    high_impact="$(jq -r '.metrics.high_impact_review_count // (.review_summary.high_impact_count // "unknown")' "$quality_src" 2>/dev/null || echo unknown)"
    residual="$(jq -r '(.residual_issues // []) | join(", ")' "$quality_src" 2>/dev/null || true)"
  else
    quality_score="unknown"
    high_impact="unknown"
    residual=""
  fi
  if [ "$recon" != "true" ]; then
    start_blocker="Some scanned resources are missing or duplicated. Fix that before using these files."
  elif [ "$quality_pass" != "true" ]; then
    start_blocker="Terraform generation can continue. Optional grouping analysis was unavailable or found improvements."
  else
    start_blocker="Terraform generation can continue. Review the readiness suggestions when convenient."
  fi

  mkdir -p "$(dirname "$out_file")"
  {
    echo "# AWS cloud discovery TODO"
    echo
    echo "> Source-cloud split PR. Destination Azure/GCP PRs inherit this grouping — fix segregation issues here first."
    echo
    echo "${start_blocker}"
    echo
    echo "## Contents"
    echo
    echo "1. [Start here](#start-here)"
    echo "2. [Run snapshot](#run-snapshot)"
    echo "3. [Blockers and attention](#blockers-and-attention)"
    echo "4. [How to review](#how-to-review)"
    echo "5. [Handoff to Azure / GCP](#handoff-to-azure--gcp)"
    echo "6. [Artifact map](#artifact-map)"
    echo "7. [Sign-off checklist](#sign-off-checklist)"
    echo
    echo "## Start here"
    echo
    echo "1. Confirm region/account and scan completeness in \`discovery-report.md\`."
    echo "2. Review \`cloud2code-scan-report.md\` for resource types, observed skip reasons, unknowns, and reconciliation checks; do not treat unknown as zero or infer a cause from a sample warning."
    echo "3. Confirm \`count_reconciliation_ok=true\` and group count looks right (\`${group_count}\` groups / \`${resource_count}\` resources)."
    echo "4. If present, review \`split_quality_report.json\` for optional grouping suggestions."
    echo "5. Review high-impact items (\`${high_impact}\`) in \`review_items.json\`."
    echo "6. Spot-check a few \`aws/groups/*\` roots (foundation, platform, one app)."
    echo "7. Only then trigger \`azure-migration-pr\` / \`gcp-migration-pr\` with \`source_pr=<this PR number>\`."
    echo
    echo "## Run snapshot"
    echo
    echo "| Item | Value |"
    echo "| --- | --- |"
    echo "| logical_group_count | \`${group_count}\` |"
    echo "| monolith_resource_count | \`${resource_count}\` |"
    echo "| count_reconciliation_ok | \`${recon}\` |"
    echo "| split_quality_pass | \`${quality_pass}\` |"
    echo "| quality_score | \`${quality_score}\` |"
    echo "| orphan_count | \`${orphan_count}\` |"
    echo "| high_impact_review_count | \`${high_impact}\` |"
    if [ -n "$residual" ]; then
      echo "| residual_issues | \`${residual}\` |"
    fi
    echo
    echo "## Blockers and attention"
    echo
    if [ "$recon" != "true" ]; then
      echo "- **Count reconciliation failed** — inspect \`per_group_resource_counts.json\` vs monolith."
    else
      echo "- Count reconciliation OK."
    fi
    if [ "$quality_pass" != "true" ]; then
      echo "- Optional grouping analysis was unavailable or found improvements. Terraform checks still run."
    else
      echo "- Split quality gate passed (still review provisional/low-confidence assignments)."
    fi
    if [ -f "$review_src" ]; then
      echo "- High-impact / batch / auto-assigned detail: \`review_items.json\`."
    fi
    echo
    echo "## How to review"
    echo
    echo "| Priority | What | Where |"
    echo "| --- | --- | --- |"
    echo "| P0 | Reconciliation / quality fail | artifacts above |"
    echo "| P1 | High-impact provisional resources | \`review_items.json\` → \`high_impact\` |"
    echo "| P2 | Oversized or singleton-heavy shards | \`split_quality_report.json\` metrics |"
    echo "| P3 | Sample Terraform roots | \`aws/groups/<id>/\` |"
    echo "| P4 | Orphans | \`orphans_bundle.json\` |"
    echo
    echo "## Handoff to Azure / GCP"
    echo
    echo "- Prefer workflow input \`source_pr=<this PR number>\` (not a stale branch)."
    echo "- Destination PRs will sanitize some group ids (\`_\` → \`-\`); counts should still match."
    echo "- If destination conversion rates show 1.0, that is **not** proof the AWS split was perfect — only that mapped types got scaffolds."
    echo
    echo "## Artifact map"
    echo
    echo "| Path | Use |"
    echo "| --- | --- |"
    echo "| \`aws/artifacts/TODO.md\` | This checklist |"
    echo "| \`aws/artifacts/discovery-report.md\` | Discovery summary and AWS scan inventory overview |"
    echo "| \`aws/artifacts/cloud2code-scan-report.md\` | Human-readable inventory, evidence checks, observed causes, and unknowns |"
    echo "| \`aws/artifacts/cloud2code-scan-report.json\` | Machine-readable per-type scan report |"
    echo "| \`aws/artifacts/split_quality_report.json\` | Score, metrics, residual issues |"
    echo "| \`aws/artifacts/review_items.json\` | High-impact review list |"
    echo "| \`aws/artifacts/logical_group_manifest.json\` | Group → addresses |"
    echo "| \`aws/groups/<id>/\` | Per-group reverse IaC |"
    echo
    echo "## Sign-off checklist"
    echo
    echo "- [ ] Region/account correct"
    echo "- [ ] Count reconciliation OK"
    echo "- [ ] Split quality acceptable (or exceptions documented)"
    echo "- [ ] High-impact review items triaged"
    echo "- [ ] Sample aws/groups roots look sane"
    echo "- [ ] Ready to run Azure/GCP with \`source_pr\` pinned to this PR"
    echo
  } >"$out_file"
}

# Write discovery-report.md + migration-blueprint.json into an aws/artifacts dir.
prepare_aws_discovery_pr_artifacts() {
  local work_root="${1:?WORK_ROOT}"
  local artifacts_dir="${2:?ARTIFACTS_DIR}"
  mkdir -p "$artifacts_dir"
  local region account group_count orphan_count identity_path state_path scan_log
  region="$(read_note "$work_root" "aws_region" 2>/dev/null || read_note "$work_root" "cloud2code_region" 2>/dev/null || echo unknown)"
  identity_path="${work_root}/.work/aws-caller-identity.json"
  account="$(read_note "$work_root" "aws_account_id" 2>/dev/null || true)"
  if [ -z "$account" ] && [ -s "$identity_path" ] && command -v jq >/dev/null 2>&1; then
    account="$(jq -r '.Account // empty' "$identity_path" 2>/dev/null || true)"
  fi
  account="${account:-unknown}"
  group_count="$(read_note "$work_root" "logical_group_count" 2>/dev/null || echo unknown)"
  orphan_count="$(read_note "$work_root" "tfstate_decomposer_orphan_count" 2>/dev/null || echo unknown)"
  state_path="$(read_note "$work_root" "cloud2code_tfstate_path" 2>/dev/null || read_note "$work_root" "monolith_state_uri" 2>/dev/null || true)"
  if [ -z "$state_path" ]; then
    state_path="$(read_note "$work_root" "cloud2code_output_dir" 2>/dev/null || true)"
  fi
  if [ -z "$state_path" ] && [ -f "${work_root}/.work/cloud2code-inputs.json" ] && command -v jq >/dev/null 2>&1; then
    state_path="$(jq -r '.cloud2code_output_dir // empty' "${work_root}/.work/cloud2code-inputs.json" 2>/dev/null || true)"
  fi
  if [ -z "$state_path" ] && [ -d "${work_root}/cloud2code" ]; then
    state_path="${work_root}/cloud2code"
  fi
  scan_log="${work_root}/.work/cloud2code.log"
  if [ -x "${work_root}/scripts/aws_discovery_scan_report.py" ] || [ -f "${work_root}/scripts/aws_discovery_scan_report.py" ]; then
    python3 "${work_root}/scripts/aws_discovery_scan_report.py" \
      --region "$region" --identity "$identity_path" --state "$state_path" --log "$scan_log" \
      --json-out "${artifacts_dir}/cloud2code-scan-report.json" \
      --markdown-out "${artifacts_dir}/cloud2code-scan-report.md"
  else
    echo "aws_discovery_report_error=scan_report_generator_missing path=${work_root}/scripts/aws_discovery_scan_report.py" >&2
    return 1
  fi
  {
    echo "# AWS cloud discovery report"
    echo
    echo "- workflow_run_id: \`$(read_note "$work_root" "workflow_run_id" 2>/dev/null || echo unknown)\`"
    echo "- aws_region: \`${region}\`"
    echo "- aws_account_id: \`${account}\`"
    echo "- logical_group_count: \`${group_count}\`"
    echo "- monolith_resource_count: \`$(read_note "$work_root" "monolith_resource_count" 2>/dev/null || echo unknown)\`"
    echo "- count_reconciliation_ok: \`$(read_note "$work_root" "count_reconciliation_ok" 2>/dev/null || echo unknown)\`"
    echo "- split_quality_pass: \`$(read_note "$work_root" "split_quality_pass" 2>/dev/null || echo unknown)\`"
    echo "- orphan_count: \`${orphan_count}\`"
    echo
    echo "The detailed scan inventory (account, region, found types, skipped types, and reasons) is in \`cloud2code-scan-report.md\`; machine-readable data is in \`cloud2code-scan-report.json\`."
    echo
    echo "Cloud2Code raw scan log (when present) lives under \`aws/artifacts/cloud2code.log\`."
  } >"${artifacts_dir}/discovery-report.md"
  if [ -s "${artifacts_dir}/cloud2code-scan-report.md" ]; then
    {
      echo
      cat "${artifacts_dir}/cloud2code-scan-report.md"
    } >>"${artifacts_dir}/discovery-report.md"
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg source_cloud "aws" \
      --arg region "$region" \
      --arg account "$account" \
      --arg group_count "$group_count" \
      --arg orphan_count "$orphan_count" \
      --arg split_quality_pass "$(read_note "$work_root" "split_quality_pass" 2>/dev/null || echo "")" \
      --arg count_reconciliation_ok "$(read_note "$work_root" "count_reconciliation_ok" 2>/dev/null || echo "")" \
      '{
        source_cloud: $source_cloud,
        aws_region: $region,
        aws_account_id: $account,
        logical_group_count: $group_count,
        orphan_count: $orphan_count,
        split_quality_pass: $split_quality_pass,
        count_reconciliation_ok: $count_reconciliation_ok,
        purpose: "AWS-side migration blueprint / readiness profile for azure-migration-pr and gcp-migration-pr handoff"
      }' >"${artifacts_dir}/migration-blueprint.json"
  else
    printf '{"source_cloud":"aws","purpose":"AWS-side migration blueprint"}\n' >"${artifacts_dir}/migration-blueprint.json"
  fi
  write_aws_discovery_todo_md "$work_root" "$artifacts_dir"
}

# Resolve source_pr (GitHub PR number) to a head branch when provided.
# Prints the branch name to stdout. Returns 0 on success.
resolve_source_pr_head_branch() {
  local repo_full="${1:?REPO}"
  local source_pr="${2:?PR}"
  local head=""
  head="$(gh pr view "$source_pr" --repo "$repo_full" --json headRefName -q .headRefName 2>/dev/null || true)"
  if [ -z "$head" ] || [ "$head" = "null" ]; then
    return 1
  fi
  printf '%s' "$head"
}

record_git_credentials_blocker() {
  local work_root="${1:?WORK_ROOT}"
  local detail="${2:-unknown}"
  mirror_note "$work_root" "pr_blocker" "git_credentials_missing"
  mirror_note "$work_root" "iac_push_status" "failed"
  mirror_note "$work_root" "git_credentials_error" "$detail"
  echo "pr_blocker=git_credentials_missing"
  echo "iac_push_status=failed"
}

cmd_clone_iac_repo() {
  local work_root="${1:?WORK_ROOT}"
  local repo_url="${2:-}"
  local default_branch="${3:-main}"

  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$repo_url" ] && [ -n "${IAC_REPOSITORY_URL:-}" ]; then
    repo_url="$IAC_REPOSITORY_URL"
  fi
  if [ -z "$repo_url" ]; then
    mirror_note "$work_root" "repo_clone_path" "skipped_no_iac_repository_url_provided"
    echo "repo_clone_path=skipped_no_iac_repository_url_provided"
    return 1
  fi

  mirror_note "$work_root" "iac_repository_url" "$repo_url"
  mirror_note "$work_root" "default_branch" "$default_branch"
  mkdir -p "${work_root}/.work"

  local repo_dir clone_url git_token
  repo_dir="$(resolve_repo_dir "$work_root")"
  mkdir -p "$(dirname "$repo_dir")"
  clone_url="$(git_clone_url "$repo_url")"
  git_token="$(resolve_git_token)"

  if [[ "$repo_url" =~ ^https:// ]] && [ -z "$git_token" ] && [[ ! "$clone_url" =~ ^https://[^/@]+@ ]]; then
    record_git_credentials_blocker "$work_root" "GIT_TOKEN_missing_for_https_clone"
    echo "clone_error=git_credentials_missing"
    return 1
  fi

  if ! bootstrap_gh; then
    if [[ "$repo_url" =~ ^https:// ]]; then
      record_git_credentials_blocker "$work_root" "bootstrap_gh_no_token"
      echo "clone_error=git_credentials_missing"
      return 1
    fi
  fi

  if [ ! -d "$repo_dir/.git" ]; then
    rm -rf "$repo_dir"
    if ! git clone --depth 1 --branch "$default_branch" "$clone_url" "$repo_dir" \
      2>"${work_root}/.work/clone.err"; then
      if ! git clone --depth 1 "$clone_url" "$repo_dir" 2>>"${work_root}/.work/clone.err"; then
        if grep -qiE 'terminal prompt disabled|authentication failed|could not read Username|403|401|invalid credentials|permission denied' \
          "${work_root}/.work/clone.err" 2>/dev/null; then
          record_git_credentials_blocker "$work_root" "git_clone_auth_failed"
        fi
        echo "clone_error=git_clone_failed"
        return 1
      fi
    fi
  fi

  cd "$repo_dir"
  git fetch origin "$default_branch" 2>/dev/null || true
  git checkout "$default_branch" 2>/dev/null || git checkout -B "$default_branch"
  git pull --ff-only origin "$default_branch" 2>/dev/null || true

  mirror_note "$work_root" "repo_clone_path" "$repo_dir"
  echo "repo_clone_path=${repo_dir}"
  echo "iac_repository_url=${repo_url}"
}


azure_credentials_configured() {
  # Reader live-plan needs the standard ARM_* env (or ClientId aliases from vault).
  [ -n "${ARM_CLIENT_ID:-${ClientId:-${client_id:-}}}" ] \
    && [ -n "${ARM_CLIENT_SECRET:-${ClientSecret:-${client_secret:-}}}" ] \
    && [ -n "${ARM_TENANT_ID:-${TenantId:-${tenant_id:-}}}" ] \
    && [ -n "${ARM_SUBSCRIPTION_ID:-${SubscriptionId:-${subscription_id:-}}}" ]
}

gcp_credentials_configured() {
  # Live plan needs ADC JSON (or GOOGLE_APPLICATION_CREDENTIALS path) plus project.
  if [ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON:-}" ] || [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
    [ -n "${GCP_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-${CLOUDSDK_CORE_PROJECT:-}}}" ]
    return $?
  fi
  return 1
}

cmd_azure_source_fetch() {
  local work_root="${1:?WORK_ROOT}"
  local repo_url="${2:-${SOURCE_IAC_REPOSITORY_URL:-}}"
  local source_branch="${3:-${SOURCE_IAC_BRANCH:-}}"
  local default_branch="${4:-${DEFAULT_BRANCH:-main}}"
  local source_pr="${SOURCE_PR:-${SOURCE_IAC_PR:-}}"

  require_embedded_invocation || return 1

  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "source_iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$repo_url" ] && [ -n "${IAC_REPOSITORY_URL:-}" ]; then
    repo_url="$IAC_REPOSITORY_URL"
  fi
  if [ -z "$source_branch" ]; then
    source_branch="$(read_note "$work_root" "source_iac_branch" 2>/dev/null || true)"
  fi
  if [ -z "$source_pr" ]; then
    source_pr="$(read_note "$work_root" "source_pr" 2>/dev/null || true)"
  fi
  if [ -z "$source_pr" ]; then
    source_pr="$(read_note "$work_root" "source_iac_pr" 2>/dev/null || true)"
  fi
  if [ -z "$repo_url" ]; then
    mirror_note "$work_root" "blocked:azure_source_iac_fetch_failed" "missing_source_iac_repository_url"
    mirror_note "$work_root" "stage_summary:azure-source-fetch" "blocked:missing_source_iac_repository_url"
    echo "blocked:azure_source_iac_fetch_failed=missing_source_iac_repository_url"
    return 1
  fi

  mkdir -p "${work_root}/.work"
  mirror_note "$work_root" "source_iac_repository_url" "$repo_url"
  mirror_note "$work_root" "iac_repository_url" "$repo_url"
  mirror_note "$work_root" "default_branch" "$default_branch"
  mirror_note "$work_root" "source_cloud" "aws"
  mirror_note "$work_root" "destination_cloud" "azure"

  local source_dir clone_url git_token repo_full
  source_dir="${work_root}/source_repo"
  clone_url="$(git_clone_url "$repo_url")"
  git_token="$(resolve_git_token)"
  repo_full="$(repo_full_name_from_url "$repo_url")"

  if [[ "$repo_url" =~ ^https:// ]] && [ -z "$git_token" ] && [[ ! "$clone_url" =~ ^https://[^/@]+@ ]]; then
    record_git_credentials_blocker "$work_root" "GIT_TOKEN_missing_for_source_fetch"
    mirror_note "$work_root" "stage_summary:azure-source-fetch" "blocked:git_credentials_missing"
    echo "clone_error=git_credentials_missing"
    return 1
  fi

  if ! bootstrap_gh; then
    if [[ "$repo_url" =~ ^https:// ]]; then
      record_git_credentials_blocker "$work_root" "bootstrap_gh_no_token_source_fetch"
      mirror_note "$work_root" "stage_summary:azure-source-fetch" "blocked:git_credentials_missing"
      echo "clone_error=git_credentials_missing"
      return 1
    fi
  fi

  if [ -n "$source_pr" ]; then
    local resolved_branch=""
    if resolved_branch="$(resolve_source_pr_head_branch "$repo_full" "$source_pr")"; then
      source_branch="$resolved_branch"
      mirror_note "$work_root" "source_pr" "$source_pr"
      echo "source_pr=${source_pr}"
    elif [ -n "$source_branch" ]; then
      echo "source_pr_resolve_failed_fallback_branch=${source_branch}"
      mirror_note "$work_root" "source_pr_resolve_fallback" "using SOURCE_IAC_BRANCH after source_pr=${source_pr} failed"
    else
      mirror_note "$work_root" "blocked:azure_source_iac_fetch_failed" "source_pr_resolve_failed"
      mirror_note "$work_root" "stage_summary:azure-source-fetch" "blocked:source_pr_resolve_failed"
      echo "blocked:azure_source_iac_fetch_failed=source_pr_resolve_failed"
      echo "source_pr=${source_pr}"
      return 1
    fi
  fi
  if [ -z "$source_branch" ]; then
    mirror_note "$work_root" "blocked:azure_source_iac_fetch_failed" "missing_source_iac_branch"
    mirror_note "$work_root" "stage_summary:azure-source-fetch" "blocked:missing_source_iac_branch"
    echo "blocked:azure_source_iac_fetch_failed=missing_source_iac_branch"
    return 1
  fi
  mirror_note "$work_root" "source_iac_branch" "$source_branch"

  rm -rf "$source_dir"
  mkdir -p "$source_dir"
  (
    cd "$source_dir"
    git init -q
    git remote add origin "$clone_url"
    git fetch --depth 1 origin "$source_branch"
    git checkout -q -B source-fetch FETCH_HEAD
  ) 2>"${work_root}/.work/source-fetch.err" || {
    mirror_note "$work_root" "blocked:azure_source_iac_fetch_failed" "git_fetch_failed"
    mirror_note "$work_root" "stage_summary:azure-source-fetch" "blocked:git_fetch_failed"
    echo "clone_error=git_fetch_failed"
    sed -E 's#x-access-token:[^@]*@#x-access-token:***@#g' "${work_root}/.work/source-fetch.err" >&2 || true
    return 1
  }

  if [ ! -d "${source_dir}/aws/groups" ]; then
    mirror_note "$work_root" "blocked:azure_source_iac_fetch_failed" "missing_aws_groups"
    mirror_note "$work_root" "stage_summary:azure-source-fetch" "blocked:missing_aws_groups"
    echo "source_fetch_error=missing_aws_groups"
    return 1
  fi

  rm -rf "${work_root}/groups" "${work_root}/source_aws"
  cp -a "${source_dir}/aws/groups" "${work_root}/groups"
  cp -a "${source_dir}/aws" "${work_root}/source_aws"

  local artifacts_dir="${source_dir}/aws/artifacts"
  if [ -d "$artifacts_dir" ]; then
    for artifact in \
      logical_group_manifest.json \
      shard_manifest.json \
      per_group_resource_counts.json \
      group_state_paths.json \
      registry_mapping_report.json \
      orphans_bundle.json \
      sample_group_ids.json \
      batch_payloads.json \
      identifier_map.json \
      split_quality_report.json \
      split_tuning_history.json \
      review_items.json \
      layer_summary.json \
      cleanup.py \
      split_state.py \
      verify_split.py; do
      if [ -f "${artifacts_dir}/${artifact}" ]; then
        cp "${artifacts_dir}/${artifact}" "${work_root}/${artifact}"
      fi
    done
    if [ -f "${artifacts_dir}/notes.json" ]; then
      cp "${artifacts_dir}/notes.json" "${work_root}/source_notes.json"
    fi
  fi

  if [ ! -f "${work_root}/logical_group_manifest.json" ]; then
    python3 - "$work_root" <<'PY'
import json
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
groups_dir = work / "groups"
manifest = {}
for group_dir in sorted(p for p in groups_dir.iterdir() if p.is_dir()):
    resource_types = set()
    addresses = []
    for tf in group_dir.glob("*.tf"):
        text = tf.read_text(encoding="utf-8", errors="ignore")
        for rtype, name in re.findall(r'resource\s+"(aws_[^"]+)"\s+"([^"]+)"', text):
            resource_types.add(rtype)
            addresses.append(f"{rtype}.{name}")
        for rtype in re.findall(r'import\s+\{[^}]*to\s*=\s*([^.\s]+)\.', text, flags=re.S):
            if rtype.startswith("aws_"):
                resource_types.add(rtype)
    manifest[group_dir.name] = {
        "group_id": group_dir.name,
        "resource_count": len(addresses) or len(resource_types),
        "resources": sorted(addresses),
        "resource_types": sorted(resource_types),
    }
(work / "logical_group_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  fi

  local group_count
  group_count="$(find "${work_root}/groups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  mirror_note "$work_root" "azure_source_iac_fetched" "true"
  mirror_note "$work_root" "azure_source_iac_group_count" "$group_count"
  mirror_note "$work_root" "logical_group_count" "$group_count"
  mirror_note "$work_root" "source_iac_repo_path" "$source_dir"
  mirror_note "$work_root" "source_iac_groups_path" "${work_root}/groups"
  mirror_note "$work_root" "source_iac_artifacts_path" "${work_root}/source_aws/artifacts"
  mirror_note "$work_root" "stage_summary:azure-source-fetch" "ok"

  echo 'azure_source_iac_fetched: "true"'
  echo "azure_source_iac_group_count=${group_count}"
  echo "source_iac_repository_url=${repo_url}"
  echo "source_iac_branch=${source_branch}"
}

cmd_registry_scaffold() {
  local work_root="${1:?WORK_ROOT}"
  require_embedded_invocation || return 1
  DBSPLIT_QUIET_PY=1 run_decomposer_py "$work_root" scaffold-registry "$work_root"
  mirror_note "$work_root" "registry_mapping_report" "${work_root}/registry_mapping_report.json"
  mirror_note "$work_root" "orphans_bundle" "${work_root}/orphans_bundle.json"
  mirror_note "$work_root" "stage_summary:registry-and-import-codegen" "ok"
  mirror_note "$work_root" "iac_pr_fast_path" "true"
}

cmd_sync_groups_to_repo() {
  local work_root="${1:?WORK_ROOT}"
  local repo_dir
  repo_dir="$(resolve_repo_dir "$work_root")"
  if [ ! -d "$repo_dir/.git" ]; then
    echo "sync_error=no_clone"
    return 1
  fi
  if [ ! -d "${work_root}/groups" ]; then
    echo "sync_error=no_groups_dir"
    return 1
  fi
  local source_cloud destination_cloud source_dir destination_dir artifacts_dir
  source_cloud="$(read_note "$work_root" "source_cloud" 2>/dev/null || true)"
  destination_cloud="$(read_note "$work_root" "destination_cloud" 2>/dev/null || true)"
  source_cloud="${source_cloud:-aws}"
  destination_cloud="${destination_cloud:-azure}"
  source_dir="${repo_dir}/${source_cloud}"
  destination_dir="${repo_dir}/${destination_cloud}"
  artifacts_dir="${source_dir}/artifacts"

  rm -rf "${source_dir}/groups" "$artifacts_dir"
  mkdir -p "$source_dir" "$destination_dir" "$artifacts_dir"
  cp -a "${work_root}/groups" "${source_dir}/groups"
  prune_iac_sync_runtime_artifacts "${source_dir}/groups"

  for artifact in \
    logical_group_manifest.json \
    shard_manifest.json \
    per_group_resource_counts.json \
    group_state_paths.json \
    registry_mapping_report.json \
    orphans_bundle.json \
    sample_group_ids.json \
    batch_payloads.json \
    identifier_map.json \
    split_quality_report.json \
    split_tuning_history.json \
    review_items.json \
    layer_summary.json \
    cleanup.py \
    split_state.py \
    verify_split.py \
    notes.json; do
    if [ -f "${work_root}/${artifact}" ]; then
      cp "${work_root}/${artifact}" "${artifacts_dir}/${artifact}"
    fi
  done
  for script_artifact in allocate_manifest.py tfstate_monolith_decomposer.py stage-runner.sh aws_discovery_scan_report.py; do
    if [ -f "${work_root}/scripts/${script_artifact}" ]; then
      cp "${work_root}/scripts/${script_artifact}" "${artifacts_dir}/${script_artifact}"
    fi
  done
  if [ -d "${work_root}/cloud2code" ]; then
    rm -rf "${artifacts_dir}/cloud2code"
    cp -a "${work_root}/cloud2code" "${artifacts_dir}/cloud2code"
  fi
  if [ -f "${work_root}/.work/cloud2code.log" ]; then
    cp "${work_root}/.work/cloud2code.log" "${artifacts_dir}/cloud2code.log"
  fi
  if [ -f "${work_root}/.work/cloud2code-command.txt" ]; then
    cp "${work_root}/.work/cloud2code-command.txt" "${artifacts_dir}/cloud2code-command.txt"
  fi
  if [ -f "${work_root}/.work/aws-caller-identity.json" ]; then
    cp "${work_root}/.work/aws-caller-identity.json" "${artifacts_dir}/aws-caller-identity.json"
  fi
  if [ -s "${work_root}/aws/artifacts/converge-status.json" ]; then
    cp "${work_root}/aws/artifacts/converge-status.json" "${artifacts_dir}/converge-status.json"
  fi
  prepare_aws_discovery_pr_artifacts "$work_root" "$artifacts_dir"

  if [ ! -f "${source_dir}/README.md" ]; then
    cat >"${source_dir}/README.md" <<EOF
# ${source_cloud} source IaC

Generated by the StackGen \`aws-cloud-discovery\` workflow.

- \`groups/<group_id>/\` contains per-group Terraform roots and split state shards.
- \`artifacts/\` contains Cloud2Code output, manifests, split quality/tuning reports, mappings, and handoff metadata for \`azure-migration-pr\` / \`gcp-migration-pr\`.
EOF
  fi

  local group_count
  group_count="$(find "${source_dir}/groups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  mirror_note "$work_root" "groups_synced_to_repo" "$group_count"
  mirror_note "$work_root" "source_cloud" "$source_cloud"
  mirror_note "$work_root" "destination_cloud" "$destination_cloud"
  mirror_note "$work_root" "source_iac_repo_path" "${source_cloud}/groups"
  mirror_note "$work_root" "source_artifacts_repo_path" "${source_cloud}/artifacts"
  mirror_note "$work_root" "destination_iac_repo_path" "${destination_cloud}"
  echo "groups_synced_to_repo=${group_count}"
  echo "source_iac_repo_path=${source_cloud}/groups"
  echo "source_artifacts_repo_path=${source_cloud}/artifacts"
  echo "destination_iac_repo_path=${destination_cloud}"
}

prune_iac_sync_runtime_artifacts() {
  local groups_root="${1:?GROUPS_ROOT}"
  [ -d "$groups_root" ] || return 0

  find "$groups_root" -type d \( -name ".terraform" -o -name ".terragrunt-cache" \) -prune -exec rm -rf {} + 2>/dev/null || true
  find "$groups_root" -type f \( \
    -name ".terraform.lock.hcl" -o \
    -name "*.tfplan" -o \
    -name "azure.tfplan" -o \
    -name "hydrate-*.tfplan" -o \
    -name "verify-*.tfplan" -o \
    -name "*.out" -o \
    -name "fmt-*.out" -o \
    -name "init-*.out" -o \
    -name "validate-*.out" -o \
    -name "test-*.out" -o \
    -name "tflint-*.out" -o \
    -name "crash.log" -o \
    -name "crash.*.log" \
  \) -delete 2>/dev/null || true
}


# True when a per-group validate result is complete enough to skip on resume.
destination_validate_group_result_complete() {
  local f="${1:?}"
  [ -f "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '
    (.group_id | type == "string" and length > 0)
    and (.fmt | type == "string")
    and (.validate | type == "string")
    and (.test | type == "string")
    and (.lint | type == "string")
    and (.plan_status | type == "string")
    and has("plan_counts")
    and has("validation_ok")
  ' "$f" >/dev/null 2>&1
}

# In-progress validation JSON lives under .work/, never under */artifacts/.
# Interrupted validates used to leave validation-report.XXXXXX in artifacts and
# azure-pr / gcp-pr committed those leftovers via cp -a of the whole tree.
mktemp_destination_validation_report() {
  local work_root="${1:?WORK_ROOT}"
  mkdir -p "${work_root}/.work"
  mktemp "${work_root}/.work/validation-report.XXXXXX"
}

# Drop mktemp leftovers; keep only the finalized validation-report.json.
prune_destination_validation_temp_reports() {
  local artifacts_dir="${1:?ARTIFACTS_DIR}"
  [ -d "$artifacts_dir" ] || return 0
  find "$artifacts_dir" -maxdepth 1 -type f -name 'validation-report.*' ! -name 'validation-report.json' -delete 2>/dev/null || true
}

# True when the report has a non-empty groups matrix and is not an explicit stub.
destination_validation_report_is_ready() {
  local report="${1:?REPORT}"
  [ -f "$report" ] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    grep -qi 'stub for pr open' "$report" 2>/dev/null && return 1
    grep -Eq '"groups"[[:space:]]*:[[:space:]]*\[' "$report" || return 1
    grep -Eq '"groups"[[:space:]]*:[[:space:]]*\[\]' "$report" && return 1
    return 0
  fi
  if jq -e '
    (.summary.note // "" | test("stub"; "i"))
    or ((.groups // []) | length) == 0
  ' "$report" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Ensure azure/gcp PR stages ship a validation matrix. Prefer a real report from
# validate; if still missing/stub after a refresh attempt, write an explicit
# incomplete report and continue so review-candidate PRs still open with remarks
# (session 5822818: pr_blocker=validation_report_incomplete blocked sibling PRs).
ensure_destination_validation_report() {
  local work_root="${1:?WORK_ROOT}"
  local cloud="${2:?CLOUD}" # azure|gcp
  local report="${work_root}/${cloud}/artifacts/validation-report.json"
  local plan_status validation_ok

  if destination_validation_report_is_ready "$report"; then
    return 0
  fi
  case "$cloud" in
    azure) cmd_azure_iac_validate "$work_root" || true ;;
    gcp) cmd_gcp_iac_validate "$work_root" || true ;;
    *)
      echo "ensure_destination_validation_report: unknown cloud=${cloud}" >&2
      return 1
      ;;
  esac
  if destination_validation_report_is_ready "$report"; then
    return 0
  fi

  plan_status="$(read_note "$work_root" "${cloud}_plan_status" 2>/dev/null || true)"
  validation_ok="$(read_note "$work_root" "${cloud}_iac_validation_ok" 2>/dev/null || true)"
  mkdir -p "$(dirname "$report")"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg note "incomplete validation report — opening review-candidate PR with remarks" \
      --arg plan "${plan_status:-unknown}" \
      --arg vok "${validation_ok:-unknown}" \
      --arg cloud "$cloud" \
      '{
        summary: {
          note: $note,
          validation_ok: $vok,
          plan_status: $plan,
          pr_policy: "soft_gate_open_with_remarks"
        },
        groups: [{
          group_id: "_incomplete",
          fmt: "unknown",
          validate: "unknown",
          plan: $plan,
          note: ("Validate did not produce a complete matrix. Inspect " + $cloud + "/artifacts/ and TODO.md. Do not treat this PR as apply-ready.")
        }]
      }' >"$report"
  else
    cat >"$report" <<EOF
{
  "summary": {
    "note": "incomplete validation report — opening review-candidate PR with remarks",
    "validation_ok": "${validation_ok:-unknown}",
    "plan_status": "${plan_status:-unknown}",
    "pr_policy": "soft_gate_open_with_remarks"
  },
  "groups": [
    {
      "group_id": "_incomplete",
      "fmt": "unknown",
      "validate": "unknown",
      "plan": "${plan_status:-unknown}",
      "note": "Validate did not produce a complete matrix. Inspect ${cloud}/artifacts/ and TODO.md. Do not treat this PR as apply-ready."
    }
  ]
}
EOF
  fi
  mirror_note "$work_root" "validation_report_incomplete" "true"
  mirror_note "$work_root" "stage_summary:${cloud}-pr" "ok:validation_report_incomplete_opening_pr"
  echo "warning:validation_report_incomplete_opening_pr"
  echo "validation_report_path=${report}"
  return 0
}

cmd_sync_hydrated_iac_pr() {
  local work_root="${1:?WORK_ROOT}"
  local repo_url="${2:-${IAC_REPOSITORY_URL:-}}"
  local default_branch="${3:-${DEFAULT_BRANCH:-main}}"
  local workflow_run_id="${4:-${WORKFLOW_RUN_ID:-}}"

  require_embedded_invocation || return 1

  local validation_ok generated_count
  validation_ok="$(read_note "$work_root" "terraform_validation_ok" 2>/dev/null || true)"
  generated_count="$(find "${work_root}/groups" -mindepth 2 -maxdepth 2 -name generated.tf 2>/dev/null | wc -l | tr -d ' ')"
  generated_count="${generated_count:-0}"
  if [ "$generated_count" -eq 0 ]; then
    mirror_note "$work_root" "hydrated_iac_sync_status" "skipped:no_generated_tf"
    echo "hydrated_iac_sync_status=skipped:no_generated_tf"
    echo "hydrated_generated_tf_count=0"
    return 0
  fi
  echo "hydrated_generated_tf_count=${generated_count}"
  # Always push usable generated.tf even when fmt/validate/zero-diff failed.
  # Operators still need the HCL; validation stays a soft readiness signal.
  if [ "$validation_ok" != "true" ]; then
    mirror_note "$work_root" "hydrated_iac_sync_validation" "failed"
    echo "hydrated_iac_sync_validation=failed"
  else
    mirror_note "$work_root" "hydrated_iac_sync_validation" "ok"
    echo "hydrated_iac_sync_validation=ok"
  fi

  # Sample parity is a warning only — do not block pushing what hydrate produced.
  if ! assert_sample_groups_hydrated "$work_root" "${work_root}/groups"; then
    mirror_note "$work_root" "hydrated_iac_sync_parity" "warn:sample_incomplete"
    echo "hydrated_iac_sync_parity=warn:sample_incomplete"
  fi

  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$default_branch" ] || [ "$default_branch" = "main" ]; then
    default_branch="$(note_or_default "$work_root" "default_branch" "main")"
  fi
  if [ -z "$workflow_run_id" ]; then
    workflow_run_id="$(read_note "$work_root" "workflow_run_id" 2>/dev/null || true)"
  fi
  if [ -z "$workflow_run_id" ]; then
    workflow_run_id="$(date +%Y%m%d%H%M%S)"
  fi

  local branch
  branch="$(read_note "$work_root" "iac_push_branch" 2>/dev/null || true)"
  if [ -z "$branch" ]; then
    branch="$(read_note "$work_root" "working_branch" 2>/dev/null || true)"
  fi
  if [ -z "$branch" ]; then
    # Prefer discovery/<run_id> — matches iac-pr-pipeline / aws-cloud-discovery PR
    # naming. Legacy split/ fallback starved azure/gcp handoff of a source_pr.
    branch="discovery/${workflow_run_id}"
  fi

  cmd_clone_iac_repo "$work_root" "$repo_url" "$default_branch" || return 1

  local repo_dir repo_full
  repo_dir="$(resolve_repo_dir "$work_root")"
  repo_full="$(repo_full_name_from_url "$repo_url")"
  cd "$repo_dir"
  git fetch origin "$branch" >/dev/null 2>&1 || true
  git checkout "$branch" 2>/dev/null || git checkout -B "$branch" "origin/$branch" 2>/dev/null || git checkout -B "$branch"

  cmd_sync_groups_to_repo "$work_root"

  local source_cloud_synced repo_generated_count
  source_cloud_synced="$(read_note "$work_root" "source_cloud" 2>/dev/null || echo aws)"
  repo_generated_count="$(find "${repo_dir}/${source_cloud_synced}/groups" -mindepth 2 -maxdepth 2 -name generated.tf 2>/dev/null | wc -l | tr -d ' ')"
  repo_generated_count="${repo_generated_count:-0}"
  if [ "$repo_generated_count" -eq 0 ]; then
    mirror_note "$work_root" "hydrated_iac_sync_status" "failed:repo_missing_generated_tf"
    echo "hydrated_iac_sync_status=failed:repo_missing_generated_tf"
    return 1
  fi
  echo "repo_generated_tf_count=${repo_generated_count}"

  clear_stale_git_index_lock "$repo_dir"
  git add -A --force
  if git diff --cached --quiet; then
    mirror_note "$work_root" "hydrated_iac_sync_status" "ok:no_changes"
    mirror_note "$work_root" "source_iac_branch" "$branch"
    echo "hydrated_iac_sync_status=ok:no_changes"
    echo "source_iac_branch=${branch}"
    return 0
  fi

  local commit_msg
  if [ "$validation_ok" = "true" ]; then
    commit_msg="hydrate: add generated Terraform HCL (${workflow_run_id})"
  else
    commit_msg="hydrate: add generated Terraform HCL (${workflow_run_id}; validation incomplete)"
  fi
  git commit -m "$commit_msg" || {
    mirror_note "$work_root" "hydrated_iac_sync_status" "failed:commit"
    echo "hydrated_iac_sync_status=failed:commit"
    return 1
  }

  if ! git push -u origin "$branch" 2>"${work_root}/.work/hydrated-push.err"; then
    mirror_note "$work_root" "hydrated_iac_sync_status" "failed:push"
    echo "hydrated_iac_sync_status=failed:push"
    cat "${work_root}/.work/hydrated-push.err" >&2 || true
    return 1
  fi

  local pr_url
  pr_url="$(read_note "$work_root" "iac_pr_url" 2>/dev/null || read_note "$work_root" "pr_url" 2>/dev/null || true)"
  if [ -z "$pr_url" ] || [ "$pr_url" = "null" ]; then
    pr_url="$(gh pr list --repo "$repo_full" --head "$branch" --json url -q '.[0].url' 2>/dev/null || true)"
  fi

  mirror_note "$work_root" "hydrated_iac_sync_status" "ok"
  mirror_note "$work_root" "source_iac_branch" "$branch"
  mirror_note "$work_root" "iac_push_branch" "$branch"
  [ -n "$pr_url" ] && [ "$pr_url" != "null" ] && mirror_note "$work_root" "iac_pr_url" "$pr_url"
  echo "hydrated_iac_sync_status=ok"
  echo "source_iac_branch=${branch}"
  [ -n "$pr_url" ] && [ "$pr_url" != "null" ] && echo "iac_pr_url=${pr_url}"
}
resolve_tofu_bin() {
  if command -v tofu >/dev/null 2>&1; then
    command -v tofu
    return 0
  fi
  if command -v terraform >/dev/null 2>&1; then
    command -v terraform
    return 0
  fi
  return 1
}

terraform_runtime_base() {
  local work_root="${1:?WORK_ROOT}"
  local candidate
  for candidate in \
    "${DBSPLIT_TF_RUNTIME_ROOT:-}" \
    "/opt/ocp-sno-aiden/aiden-tf-runtime" \
    "/tmp/aiden-tf-runtime" \
    "${work_root}/.work/tf-runtime"; do
    [ -n "$candidate" ] || continue
    mkdir -p "$candidate" 2>/dev/null || continue
    if [ -w "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

safe_runtime_component() {
  printf '%s' "${1:?VALUE}" | tr -c 'A-Za-z0-9._-' '_'
}

configure_group_tofu_runtime() {
  local work_root="${1:?WORK_ROOT}"
  local group_id="${2:?GROUP_ID}"
  local base run_name safe_group
  base="$(terraform_runtime_base "$work_root")" || return 1
  run_name="$(safe_runtime_component "$(basename "$work_root")")"
  safe_group="$(safe_runtime_component "$group_id")"
  export TF_PLUGIN_CACHE_DIR="${base}/plugin-cache"
  export TF_DATA_DIR="${base}/data/${run_name}/${safe_group}"
  mkdir -p "$TF_PLUGIN_CACHE_DIR" "$TF_DATA_DIR"
  mirror_note "$work_root" "terraform_runtime_root" "$base" || true
  mirror_note "$work_root" "terraform_plugin_cache_dir" "$TF_PLUGIN_CACHE_DIR" || true
  echo "terraform_runtime_root=${base}"
}

cleanup_terraform_runtime_artifacts() {
  local work_root="${1:?WORK_ROOT}"
  local group_id="${2:-}"
  local dir

  if [ -n "$group_id" ] && [ -d "${work_root}/groups/${group_id}" ]; then
    rm -rf "${work_root}/groups/${group_id}/.terraform" 2>/dev/null || true
    rm -f "${work_root}/groups/${group_id}"/*.tfplan 2>/dev/null || true
  fi

  for dir in "${work_root}/groups" "${work_root}/repo/aws/groups" "${work_root}/source_repo/aws/groups"; do
    [ -d "$dir" ] || continue
    find "$dir" -type d -name ".terraform" -prune -exec rm -rf {} + 2>/dev/null || true
    find "$dir" -type f \( -name "*.tfplan" -o -name "hydrate-*.tfplan" -o -name "verify-*.tfplan" \) -delete 2>/dev/null || true
  done

  if [ -n "${TF_DATA_DIR:-}" ]; then
    rm -rf "$TF_DATA_DIR" 2>/dev/null || true
    mkdir -p "$TF_DATA_DIR" 2>/dev/null || true
  fi
}

classify_tofu_init_failure() {
  local log_file="${1:?LOG_FILE}"
  if grep -qiE 'no space left on device|disk quota exceeded|not enough space' "$log_file"; then
    printf '%s' "runner_disk_full"
    return 0
  fi
  if grep -qiE 'Failed to install provider|Error while installing|provider registry|could not query provider registry|timeout|TLS handshake' "$log_file"; then
    printf '%s' "provider_install_failed"
    return 0
  fi
  # Shared plugin cache can list a version that was never fully downloaded.
  if grep -qiE 'Failed to read plugin cache|plugin cache|checksum|there is no package for registry' "$log_file"; then
    printf '%s' "plugin_cache_failed"
    return 0
  fi
  printf '%s' "init_failed"
}

tofu_init_with_repair() {
  local work_root="${1:?WORK_ROOT}"
  local group_id="${2:?GROUP_ID}"
  local tofu_bin="${3:?TOFU}"
  local groups_dir="${work_root}/groups/${group_id}"
  local max_init_attempts="${DBSPLIT_TF_INIT_MAX_ATTEMPTS:-3}"
  local init_attempt=1
  local init_log reason excerpt status_json

  configure_group_tofu_runtime "$work_root" "$group_id" || {
    mirror_note "$work_root" "hcl_hydration_status:${group_id}" "{\"plan_no_changes\":false,\"failure_reason\":\"terraform_runtime_unavailable\",\"attempt\":1}"
    return 1
  }

  while [ "$init_attempt" -le "$max_init_attempts" ]; do
    init_log="${groups_dir}/init-${init_attempt}.out"
    # Prefer the flock-wrapped init so concurrent groups do not race the cache.
    if tofu_init_with_plugin_cache_lock "$tofu_bin" "$init_log"; then
      mirror_note "$work_root" "hcl_init_status:${group_id}" "{\"ok\":true,\"attempt\":${init_attempt},\"log_path\":\"${init_log}\",\"tf_data_dir\":\"${TF_DATA_DIR}\",\"plugin_cache_dir\":\"${TF_PLUGIN_CACHE_DIR}\"}" || true
      return 0
    fi

    reason="$(classify_tofu_init_failure "$init_log")"
    excerpt="$(tail -c 2000 "$init_log" 2>/dev/null | jq -Rs .)"
    status_json="{\"plan_no_changes\":false,\"failure_reason\":\"${reason}\",\"attempt\":${init_attempt},\"init_log_path\":\"${init_log}\",\"init_error\":${excerpt},\"tf_data_dir\":\"${TF_DATA_DIR}\",\"plugin_cache_dir\":\"${TF_PLUGIN_CACHE_DIR}\"}"
    mirror_note "$work_root" "hcl_hydration_status:${group_id}" "$status_json" || true
    mirror_note "$work_root" "hcl_init_status:${group_id}" "$status_json" || true
    echo "group_init_failed=${group_id} reason=${reason} attempt=${init_attempt} log=${init_log}"

    case "$reason" in
      runner_disk_full|provider_install_failed|plugin_cache_failed)
        cleanup_terraform_runtime_artifacts "$work_root" "$group_id"
        # Drop stale cache entries so the next init re-downloads the provider.
        if [ -n "${TF_PLUGIN_CACHE_DIR:-}" ] && [ -d "$TF_PLUGIN_CACHE_DIR" ]; then
          find "$TF_PLUGIN_CACHE_DIR" -type d -name 'registry.opentofu.org' -prune -exec rm -rf {} + 2>/dev/null || true
          find "$TF_PLUGIN_CACHE_DIR" -type d -name 'registry.terraform.io' -prune -exec rm -rf {} + 2>/dev/null || true
        fi
        configure_group_tofu_runtime "$work_root" "$group_id" || true
        # Force provider re-resolution after cache wipe.
        ( cd "$groups_dir" && "$tofu_bin" init -backend=false -input=false -upgrade -no-color >"${groups_dir}/init-upgrade-${init_attempt}.out" 2>&1 ) || true
        ;;
      *)
        ;;
    esac
    init_attempt=$((init_attempt + 1))
  done

  return 1
}

sample_group_ids_json() {
  local work_root="${1:?WORK_ROOT}"
  local manifest_path="${work_root}/logical_group_manifest.json"
  local group_count sample_size
  if [ ! -f "$manifest_path" ]; then
    echo "converge_input_error=missing_logical_group_manifest path=${manifest_path}" >&2
    return 1
  fi
  group_count="$(jq 'length' "$manifest_path" 2>/dev/null || true)"
  if ! [[ "$group_count" =~ ^[0-9]+$ ]]; then
    echo "converge_input_error=bad_manifest_group_count group_count=${group_count:-unset} path=${manifest_path}" >&2
    return 1
  fi
  # Full coverage by default. Cap only when DBSPLIT_HYDRATE_SAMPLE_SIZE is set.
  if [ -n "${DBSPLIT_HYDRATE_SAMPLE_SIZE:-}" ] && [ "${DBSPLIT_HYDRATE_SAMPLE_SIZE}" -gt 0 ] 2>/dev/null; then
    sample_size="$DBSPLIT_HYDRATE_SAMPLE_SIZE"
    if [ "$sample_size" -gt "$group_count" ]; then
      sample_size="$group_count"
    fi
    mirror_note "$work_root" "large_state_sample_mode" "true"
  else
    sample_size="$group_count"
    mirror_note "$work_root" "large_state_sample_mode" "false"
  fi
  mirror_note "$work_root" "large_state_sample_size" "$sample_size"
  mirror_note "$work_root" "hydrate_group_total" "$group_count"
  jq -c --argjson n "$sample_size" 'keys | sort | .[0:$n]' "$manifest_path" 2>/dev/null || {
    echo "converge_input_error=manifest_jq_failed path=${manifest_path}" >&2
    return 1
  }
}

cmd_prepare_parallel_artifacts() {
  local work_root="${1:?WORK_ROOT}"
  require_embedded_invocation || return 1

  # batch_payloads.json is created by prepare-parallel-artifacts itself. Treating
  # it as an ingest prerequisite made the registry PR stage fail on every fresh
  # run, before the generator had a chance to create its output.
  if [ ! -s "${work_root}/logical_group_manifest.json" ]; then
    echo "converge_input_error=missing_logical_group_manifest work_root=${work_root}" >&2
    mirror_note "$work_root" "blocked:converge_inputs_missing" "true" || true
    mirror_note "$work_root" "converge_input_error" "missing_logical_group_manifest" || true
    echo 'blocked:converge_inputs_missing: "true"'
    return 1
  fi

  DBSPLIT_QUIET_PY=1 run_decomposer_py "$work_root" prepare-parallel-artifacts "$work_root" || return 1
  mirror_note "$work_root" "stage_summary:prepare-parallel-artifacts" "ok"

  if [ ! -f "${work_root}/sample_group_ids.json" ]; then
    echo "converge_input_error=missing_sample_group_ids work_root=${work_root}" >&2
    mirror_note "$work_root" "blocked:converge_inputs_missing" "true" || true
    mirror_note "$work_root" "converge_input_error" "missing_sample_group_ids" || true
    echo 'blocked:converge_inputs_missing: "true"'
    return 1
  fi

  local sample_ids
  sample_ids="$(jq -c '.' "${work_root}/sample_group_ids.json" 2>/dev/null || true)"
  if [ -z "$sample_ids" ] || [ "$sample_ids" = "null" ]; then
    echo "converge_input_error=bad_sample_group_ids work_root=${work_root}" >&2
    mirror_note "$work_root" "blocked:converge_inputs_missing" "true" || true
    mirror_note "$work_root" "converge_input_error" "bad_sample_group_ids" || true
    echo 'blocked:converge_inputs_missing: "true"'
    return 1
  fi
  mirror_note "$work_root" "large_state_sample_group_ids" "$sample_ids"
  mirror_note "$work_root" "sample_group_ids_path" "${work_root}/sample_group_ids.json"
  mirror_note "$work_root" "batch_payloads_path" "${work_root}/batch_payloads.json"
  mirror_note "$work_root" "identifier_map_path" "${work_root}/identifier_map.json"

  local group_count sample_size
  group_count="$(jq 'length' "${work_root}/logical_group_manifest.json" 2>/dev/null || echo 0)"
  sample_size="$(jq 'length' "${work_root}/sample_group_ids.json" 2>/dev/null || echo 0)"
  [[ "$group_count" =~ ^[0-9]+$ ]] || group_count=0
  [[ "$sample_size" =~ ^[0-9]+$ ]] || sample_size=0
  if [ "$sample_size" -lt "$group_count" ]; then
    mirror_note "$work_root" "large_state_sample_mode" "true"
  else
    mirror_note "$work_root" "large_state_sample_mode" "false"
  fi
  mirror_note "$work_root" "large_state_sample_size" "$sample_size"
  mirror_note "$work_root" "hydrate_group_total" "$group_count"

  echo "sample_group_ids_path=${work_root}/sample_group_ids.json"
  echo "batch_payloads_path=${work_root}/batch_payloads.json"
  echo "identifier_map_path=${work_root}/identifier_map.json"
  echo "large_state_sample_group_ids=${sample_ids}"
  echo "hydrate_group_total=${group_count}"
  echo "hydrate_group_selected=${sample_size}"
}

fix_generated_tf_name_conflicts() {
  local gen_tf="${1:?generated.tf}"
  [ -f "$gen_tf" ] || return 0
  python3 - "$gen_tf" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# Drop provider-generated fields that commonly fail validation after
# -generate-config-out because they are computed defaults, empty optional IDs, or
# mutually exclusive arguments.
route_null_attrs = {
    "carrier_gateway_id",
    "core_network_arn",
    "destination_prefix_list_id",
    "egress_only_gateway_id",
    "gateway_id",
    "ipv6_cidr_block",
    "local_gateway_id",
    "nat_gateway_id",
    "network_interface_id",
    "odb_network_arn",
    "outpost_arn",
    "transit_gateway_id",
    "vpc_endpoint_id",
    "vpc_peering_connection_id",
}
remove_empty_attrs = {
    "customer_owned_ipv4_pool",
    "outpost_arn",
    # Format-validated optionals: the provider rejects "" outright, and the
    # empty value carries no intent, so dropping them keeps the diff at zero.
    "durability",
    "transit_encryption_mode",
    "slots",
    # generate-config-out emits empty IPv6 IPAM fields that conflict with
    # assign_generated_ipv6_cidr_block / ipv6_cidr_block.
    "ipv6_ipam_pool_id",
    "ipv6_netmask_length",
    "ipv4_ipam_pool_id",
    "ipv4_netmask_length",
}
# Computed / read-only attributes that generate-config-out still emits.
api_gateway_deployment_drop = {
    "execution_arn",
    "invoke_url",
    "created_date",
}
replication_group_managed_attrs = (
    "az_mode",
    "availability_zone",
    "engine",
    "engine_version",
    "maintenance_window",
    "node_type",
    "notification_topic_arn",
    "num_cache_nodes",
    "parameter_group_name",
    "port",
    "security_group_ids",
    "security_group_names",
    "snapshot_arns",
    "snapshot_name",
    "snapshot_retention_limit",
    "snapshot_window",
    "subnet_group_name",
)

def drop_attr_lines(block: str, attrs) -> str:
    for attr in attrs:
        block = re.sub(rf"^\s*{re.escape(attr)}\s*=.*\n", "", block, flags=re.M)
    return block

def drop_list_or_block_attr(block: str, attr: str) -> str:
    # Attribute form: attr = [ ... ] or attr = { ... } (possibly nested). Scan
    # a balanced span so multi-line values are removed whole. The previous
    # single-line fallback orphaned the value body when the opener line did
    # not end in '[' (trace 1c64c4a5: bare `{` on generated.tf line 6 →
    # "Argument or block definition required" init_failed x3).
    pattern = re.compile(
        rf"^(\s*){re.escape(attr)}\s*=\s*[\[\{{]",
        re.M,
    )
    while True:
        m = pattern.search(block)
        if not m:
            break
        opener = m.group(0).rstrip()[-1]
        i = m.end() - 1  # at '[' or '{'
        depth = 0
        j = i
        in_str = False
        escape = False
        while j < len(block):
            ch = block[j]
            if in_str:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == opener:
                depth += 1
            elif ch == ("]" if opener == "[" else "}"):
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        # Consume trailing whitespace/newline after the closing bracket.
        while j < len(block) and block[j] in " \t":
            j += 1
        if j < len(block) and block[j] == "\n":
            j += 1
        block = block[: m.start()] + block[j:]
    return block

def _extract_bracket_span(text: str, open_idx: int) -> int:
    """Return index just past the matching closing bracket for text[open_idx]."""
    open_ch = text[open_idx]
    close_ch = "]" if open_ch == "[" else "}"
    depth = 0
    j = open_idx
    in_str = False
    escape = False
    while j < len(text):
        ch = text[j]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == open_ch:
                depth += 1
            elif ch == close_ch:
                depth -= 1
                if depth == 0:
                    return j + 1
        j += 1
    return len(text)

def rewrite_route_list_as_blocks(block: str) -> str:
    """Turn route = [ { ... }, ... ] into repeated route { } blocks."""
    return rewrite_named_list_as_blocks(block, "route", route_null_attrs)


def rewrite_named_list_as_blocks(block: str, attr: str, null_attrs=None) -> str:
    """Turn attr = [ { ... }, ... ] into repeated attr { } blocks."""
    null_attrs = set(null_attrs or ())
    pattern = re.compile(rf"^(\s*){re.escape(attr)}\s*=\s*\[", re.M)
    while True:
        m = pattern.search(block)
        if not m:
            break
        indent = m.group(1)
        list_start = m.end() - 1
        list_end = _extract_bracket_span(block, list_start)
        raw = block[list_start:list_end]
        objects = []
        i = 1  # skip '['
        while i < len(raw) - 1:
            while i < len(raw) - 1 and raw[i] in " \t\n\r,":
                i += 1
            if i >= len(raw) - 1:
                break
            if raw[i] != "{":
                break
            obj_end = _extract_bracket_span(raw, i)
            objects.append(raw[i:obj_end])
            i = obj_end
        new_parts = []
        for obj in objects:
            inner = obj.strip()
            if inner.startswith("{") and inner.endswith("}"):
                inner = inner[1:-1]
            lines_out = []
            for line in inner.splitlines():
                stripped = line.strip().rstrip(",")
                if not stripped or stripped in ("{", "}"):
                    continue
                stripped = re.sub(r'^"([A-Za-z0-9_]+)"\s*=', r"\1 =", stripped)
                empty = re.match(
                    r"^([A-Za-z0-9_]+)\s*=\s*(?:\"\"|null)\s*$",
                    stripped,
                )
                if empty and empty.group(1) in null_attrs:
                    continue
                if re.search(r'=\s*""\s*$', stripped) or re.search(r"=\s*null\s*$", stripped):
                    continue
                lines_out.append(f"{indent}  {stripped}")
            if not lines_out:
                continue
            new_parts.append(
                f"{indent}{attr} {{\n" + "\n".join(lines_out) + f"\n{indent}}}"
            )
        replacement = ("\n".join(new_parts) + "\n") if new_parts else ""
        end = list_end
        while end < len(block) and block[end] in " \t":
            end += 1
        if end < len(block) and block[end] == "\n":
            end += 1
        block = block[: m.start()] + replacement + block[end:]
    return block


def rewrite_single_object_attr_as_block(block: str, attr: str) -> str:
    """Turn attr = { ... } into attr { ... } (nested block, not object assign)."""
    pattern = re.compile(rf"^(\s*){re.escape(attr)}\s*=\s*\{{", re.M)
    while True:
        m = pattern.search(block)
        if not m:
            break
        indent = m.group(1)
        obj_start = m.end() - 1
        obj_end = _extract_bracket_span(block, obj_start)
        raw = block[obj_start:obj_end]
        inner = raw[1:-1] if raw.startswith("{") and raw.endswith("}") else raw
        lines_out = []
        for line in inner.splitlines():
            stripped = line.strip().rstrip(",")
            if not stripped:
                continue
            stripped = re.sub(r'^"([A-Za-z0-9_]+)"\s*=', r"\1 =", stripped)
            if re.search(r'=\s*""\s*$', stripped) or re.search(r"=\s*null\s*$", stripped):
                continue
            lines_out.append(f"{indent}  {stripped}")
        replacement = (
            f"{indent}{attr} {{\n" + "\n".join(lines_out) + f"\n{indent}}}\n"
            if lines_out
            else ""
        )
        end = obj_end
        while end < len(block) and block[end] in " \t":
            end += 1
        if end < len(block) and block[end] == "\n":
            end += 1
        block = block[: m.start()] + replacement + block[end:]
    return block

out = []
for block in re.split(r"(?=resource\s+\"[^\"]+\"\s+\"[^\"]+\"\s+\{)", text):
    if re.search(r"\bname_prefix\s*=", block) and re.search(r"\bname\s*=", block):
        block = re.sub(r"^\s*name_prefix\s*=.*\n", "", block, flags=re.M)
    if re.search(r"\bsecondary_private_ip_addresses\s*=", block) and re.search(r"\bsecondary_private_ip_address_count\s*=", block):
        block = re.sub(r"^\s*secondary_private_ip_addresses\s*=.*\n", "", block, flags=re.M)
    if re.search(r"\bavailability_zone\s*=", block) and re.search(r"\bavailability_zone_id\s*=", block):
        block = re.sub(r"^\s*availability_zone_id\s*=.*\n", "", block, flags=re.M)
    # OIDC provider URLs are stored without a scheme but the provider requires
    # one, so validation fails on every imported EKS or GitHub Actions issuer.
    if block.startswith('resource "aws_iam_openid_connect_provider"'):
        block = re.sub(r'^(\s*url\s*=\s*)"(?!https?://)([^"]+)"', r'\1"https://\2"', block, flags=re.M)
    # An ElastiCache replication group is sized either by cluster count or by
    # node groups, never both. Config generation emits all three because they
    # are computed in state; keep the cluster count and drop the shard pair.
    if re.search(r"\bnum_cache_clusters\s*=", block):
        block = re.sub(r"^\s*num_node_groups\s*=.*\n", "", block, flags=re.M)
        block = re.sub(r"^\s*replicas_per_node_group\s*=.*\n", "", block, flags=re.M)
    # A cache cluster that belongs to a replication group inherits its engine and
    # placement from the group, so the provider rejects those attributes here even
    # though they are all populated in state.
    if block.startswith('resource "aws_elasticache_cluster"') and re.search(r"\breplication_group_id\s*=\s*\"[^\"]+\"", block):
        for attr in replication_group_managed_attrs:
            block = re.sub(rf"^\s*{re.escape(attr)}\s*=.*\n", "", block, flags=re.M)
    if block.startswith('resource "aws_api_gateway_deployment"'):
        block = drop_attr_lines(block, api_gateway_deployment_drop)
    # generate-config-out emits mixed_instances_policy as a list; AWS provider
    # expects a nested block. Drop the malformed attribute so validate can pass;
    # launch template / ASG still import from state for plan.
    if block.startswith('resource "aws_autoscaling_group"'):
        block = drop_list_or_block_attr(block, "mixed_instances_policy")
        block = drop_list_or_block_attr(block, "launch_template")
        # Prefer launch_template block when both ID and name forms conflict later.
        block = rewrite_named_list_as_blocks(block, "tag")
    # dns_options on vpc endpoints must be a block, not a list attribute.
    if 'resource "aws_vpc_endpoint"' in block[:80] or block.startswith('resource "aws_vpc_endpoint"'):
        block = drop_list_or_block_attr(block, "dns_options")
    # generate-config-out / emit-from-state emit route = [ { ... } ]; provider wants
    # repeated route { } blocks. Rewrite in place so validate and zero-diff plan both work.
    if block.startswith('resource "aws_route_table"'):
        block = rewrite_route_list_as_blocks(block)
    if block.startswith('resource "aws_ecs_task_definition"') or block.startswith(
        'resource "aws_ecs_service"'
    ):
        block = rewrite_named_list_as_blocks(block, "runtime_platform")
        block = rewrite_single_object_attr_as_block(block, "runtime_platform")
    # Root API GW resources with empty parent_id cannot validate; drop the block.
    if block.startswith('resource "aws_api_gateway_resource"'):
        if re.search(r'^\s*path_part\s*=\s*""\s*$', block, re.M) or re.search(
            r"^\s*path_part\s*=\s*\"/\"\s*$", block, re.M
        ):
            if not re.search(r'^\s*parent_id\s*=\s*\"[^\"]+\"\s*$', block, re.M):
                block = (
                    "# dropped aws_api_gateway_resource root without parent_id "
                    "(provider requires parent_id; use rest_api.root_resource_id)\n"
                )
    block = re.sub(r"^\s*enable_lni_at_device_index\s*=\s*0\s*\n", "", block, flags=re.M)
    # Zero netmask lengths are invalid enums; empty string IPAM pool IDs conflict
    # with assign_generated_* flags. Drop both forms before validate.
    for attr in (
        "ipv6_netmask_length",
        "ipv4_netmask_length",
        "ipv6_ipam_pool_id",
        "ipv4_ipam_pool_id",
    ):
        block = re.sub(rf"^\s*{re.escape(attr)}\s*=\s*(?:0|\"\")\s*\n", "", block, flags=re.M)
    if re.search(r"\bipv6_cidr_block\s*=", block) or re.search(
        r"\bassign_generated_ipv6_cidr_block\s*=", block
    ):
        block = re.sub(r"^\s*ipv6_ipam_pool_id\s*=.*\n", "", block, flags=re.M)
        block = re.sub(r"^\s*ipv6_netmask_length\s*=.*\n", "", block, flags=re.M)
    for attr in route_null_attrs:
        block = re.sub(rf"^(\s*{re.escape(attr)}\s*=\s*)\"\"\s*$", rf"\1null", block, flags=re.M)
    for attr in remove_empty_attrs:
        block = re.sub(rf"^\s*{re.escape(attr)}\s*=\s*\"\"\s*\n", "", block, flags=re.M)
    block = re.sub(r"^\s*map_customer_owned_ip_on_launch\s*=\s*false\s*\n", "", block, flags=re.M)
    out.append(block)
open(path, "w", encoding="utf-8").write("".join(out))
PY
}

plan_change_counts_json() {
  local tofu_bin="${1:?TOFU}"
  local plan_file="${2:?PLAN_FILE}"
  local json add change destroy
  json="$("$tofu_bin" show -json "$plan_file" 2>/dev/null)" || return 1
  add="$(printf '%s' "$json" | jq '[.resource_changes[]? | select(.change.actions | index("create")) | select((.change.actions | index("delete")) | not)] | length' 2>/dev/null || echo 0)"
  change="$(printf '%s' "$json" | jq '[.resource_changes[]? | select(.change.actions | index("update"))] | length' 2>/dev/null || echo 0)"
  destroy="$(printf '%s' "$json" | jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' 2>/dev/null || echo 0)"
  printf '{"add":%s,"change":%s,"destroy":%s}' "${add:-0}" "${change:-0}" "${destroy:-0}"
}

# Resolve hcl_sanity.py from the work-root script pack (preferred) or beside this runner.
resolve_hcl_sanity_py() {
  local work_root="${1:-}"
  if [ -n "$work_root" ] && [ -f "${work_root}/scripts/hcl_sanity.py" ]; then
    printf '%s\n' "${work_root}/scripts/hcl_sanity.py"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if [ -f "${here}/hcl_sanity.py" ]; then
    printf '%s\n' "${here}/hcl_sanity.py"
    return 0
  fi
  return 1
}

# Fail closed when imports.tf addresses are missing from generated resource HCL.
assert_source_group_parity() {
  local work_root="${1:?WORK_ROOT}"
  local group_dir="${2:?GROUP_DIR}"
  local sanity_py
  if ! sanity_py="$(resolve_hcl_sanity_py "$work_root")"; then
    echo "parity_fail=missing_hcl_sanity_py group=$(basename "$group_dir")" >&2
    return 1
  fi
  python3 "$sanity_py" source-parity "$group_dir"
}

# Destination groups must emit at least one resource block (empty scaffolds fail).
assert_destination_group_resources() {
  local work_root="${1:?WORK_ROOT}"
  local group_dir="${2:?GROUP_DIR}"
  local sanity_py
  if ! sanity_py="$(resolve_hcl_sanity_py "$work_root")"; then
    echo "destination_fail=missing_hcl_sanity_py group=$(basename "$group_dir")" >&2
    return 1
  fi
  python3 "$sanity_py" destination-resources "$group_dir"
}

# Shared plugin-cache lock so concurrent/overlapping inits do not race the cache.
tofu_init_with_plugin_cache_lock() {
  local tofu_bin="${1:?TOFU}"
  local out_file="${2:?OUT}"
  local lock_file="${TF_PLUGIN_CACHE_DIR:-/tmp}/.tf-plugin-cache.lock"
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 120 200 || true
      "$tofu_bin" init -backend=false -input=false -no-color
    ) 200>"$lock_file" >"$out_file" 2>&1
    return $?
  fi
  "$tofu_bin" init -backend=false -input=false -no-color >"$out_file" 2>&1
}

# Parse tofu logs into surgical fix targets and optionally drop safe attrs.
# Writes notes/hcl_fix_targets:<group_id> and a JSON report under the group dir.
emit_hcl_fix_targets() {
  local work_root="${1:?WORK_ROOT}"
  local group_id="${2:?GROUP_ID}"
  local log_file="${3:?LOG}"
  local groups_dir="${work_root}/groups/${group_id}"
  local sanity_py report_path targets_json removed=0

  [ -f "$log_file" ] || return 0
  if ! sanity_py="$(resolve_hcl_sanity_py "$work_root")"; then
    return 0
  fi
  report_path="${groups_dir}/hcl_fix_targets.json"
  if ! python3 "$sanity_py" parse-tofu-errors "$log_file" \
    --group-id "$group_id" --out "$report_path" >"${groups_dir}/hcl_fix_targets.raw.json" 2>/dev/null; then
    # parse returns 1 when no Error: blocks; still useful to clear stale notes.
    if [ ! -s "$report_path" ]; then
      return 0
    fi
  fi
  if [ -f "$report_path" ]; then
    targets_json="$(tr '\n' ' ' <"$report_path" | head -c 12000)"
    mirror_note "$work_root" "hcl_fix_targets:${group_id}" "$targets_json" || true
    # Echo compact lines the agent can act on without opening the full JSON.
    python3 - "$report_path" <<'PY' || true
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
targets = data.get("targets") or []
print(f"hcl_fix_target_count={len(targets)}")
for t in targets[:25]:
    addr = t.get("address") or "?"
    attr = t.get("attribute") or "-"
    sug = t.get("suggestion") or "-"
    err = (t.get("error") or "")[:80]
    hint = (t.get("rewrite_hint") or "")[:120]
    excerpt = (t.get("excerpt") or "")[:120]
    line = (
        f"hcl_fix_target group={data.get('group_id','')} address={addr} "
        f"attr={attr} suggestion={sug} error={err}"
    )
    if hint:
        line += f" hint={hint}"
    elif excerpt:
        line += f" excerpt={excerpt}"
    print(line)
PY
    if [ -f "${groups_dir}/generated.tf" ]; then
      removed="$(python3 "$sanity_py" apply-surgical-fixes "$groups_dir" "$report_path" 2>/dev/null | awk -F= '/removed_attrs=/{print $NF}' | tail -1)"
      removed="${removed:-0}"
      if [ "$removed" != "0" ] && [ -n "$removed" ]; then
        echo "hcl_surgical_auto_fixed=${group_id} removed_attrs=${removed}"
        fix_generated_tf_name_conflicts "${groups_dir}/generated.tf" || true
        return 0
      fi
    fi
  fi
  return 0
}

# Retry validate when plugin-cache / lock races produce flaky failures.
tofu_validate_with_retry() {
  local tofu_bin="${1:?TOFU}"
  local out_file="${2:?OUT}"
  local attempt
  for attempt in 1 2 3; do
    if "$tofu_bin" validate -no-color >"$out_file" 2>&1; then
      return 0
    fi
    if ! grep -qiE 'plugin|lock|timeout|connection|busy|checksum|inconsistent|cached' "$out_file" 2>/dev/null; then
      return 1
    fi
    sleep "$attempt"
    tofu_init_with_plugin_cache_lock "$tofu_bin" "init.retry.out" || true
  done
  return 1
}

# Truncate a tofu log for the validation JSON report (no newlines / control chars).
validation_error_snippet() {
  local path="${1:?PATH}"
  local max_chars="${2:-400}"
  if [ ! -s "$path" ]; then
    echo ""
    return 0
  fi
  tr '\n' ' ' <"$path" | tr -cd '[:print:] ' | head -c "$max_chars"
}

# Pick non-empty destination groups for live plan with basename diversity so the
# default sample is not biased to lexicographically first l1-foundation shards.
# Prints one group_id per line (up to limit). limit=0 prints nothing (caller plans all).
select_diversified_live_plan_group_ids() {
  local work_root="${1:?WORK_ROOT}"
  local cloud="${2:?CLOUD}"
  local limit="${3:?LIMIT}"
  local groups_root="${work_root}/${cloud}/groups"
  local all_file picked_file remaining_file
  local group_dir gid picked=0 pat line

  if [ "$limit" = "0" ] || [ ! -d "$groups_root" ]; then
    return 0
  fi

  all_file="$(mktemp)"
  picked_file="$(mktemp)"
  remaining_file="$(mktemp)"

  while IFS= read -r group_dir; do
    [ -n "$group_dir" ] || continue
    if assert_destination_group_resources "$work_root" "$group_dir" >/dev/null 2>&1; then
      basename "$group_dir"
    fi
  done < <(find "$groups_root" -mindepth 1 -maxdepth 1 -type d | sort) >"$all_file"
  cp "$all_file" "$remaining_file"

  # One pick per bucket first (diversity), then fill from leftovers.
  local patterns=(
    'l2-platform|platform'
    'lambda|function|cloudfunctions|gcf'
    's3|storage|bucket'
    'rds|sql|postgres|mysql|database|cosmos'
    'eks|gke|kubernetes|container|aks|ecs'
    'redis|elasticache|cache'
    'api.gateway|apigw|api-gateway|apim|rest-api'
    'l1-foundation|foundation|vpc|network'
  )

  for pat in "${patterns[@]}"; do
    [ "$picked" -ge "$limit" ] && break
    line="$(grep -E -i -- "$pat" "$remaining_file" | head -n 1 || true)"
    [ -n "$line" ] || continue
    echo "$line" >>"$picked_file"
    picked=$((picked + 1))
    grep -vxF -- "$line" "$remaining_file" >"${remaining_file}.next" || true
    mv "${remaining_file}.next" "$remaining_file"
  done

  while [ "$picked" -lt "$limit" ]; do
    line="$(head -n 1 "$remaining_file" || true)"
    [ -n "$line" ] || break
    echo "$line" >>"$picked_file"
    picked=$((picked + 1))
    grep -vxF -- "$line" "$remaining_file" >"${remaining_file}.next" || true
    mv "${remaining_file}.next" "$remaining_file"
  done

  cat "$picked_file"
  rm -f "$all_file" "$picked_file" "$remaining_file" "${remaining_file}.next" 2>/dev/null || true
}

# Sample-matrix / sync gate: every listed sample group must have import↔resource parity.
assert_sample_groups_hydrated() {
  local work_root="${1:?WORK_ROOT}"
  local groups_root="${2:-${work_root}/groups}"
  local sample_path="${work_root}/sample_group_ids.json"
  local group_id fail_count=0

  if [ ! -f "$sample_path" ]; then
    echo "parity_fail=missing_sample_group_ids path=${sample_path}" >&2
    return 1
  fi
  if [ ! -d "$groups_root" ]; then
    echo "parity_fail=missing_groups_root path=${groups_root}" >&2
    return 1
  fi

  while IFS= read -r group_id; do
    [ -n "$group_id" ] || continue
    if ! assert_source_group_parity "$work_root" "${groups_root}/${group_id}"; then
      fail_count=$((fail_count + 1))
    fi
  done < <(jq -r '.[]' "$sample_path")

  if [ "$fail_count" -gt 0 ]; then
    mirror_note "$work_root" "sample_hydrate_parity_ok" "false"
    mirror_note "$work_root" "sample_hydrate_parity_fail_count" "$fail_count"
    echo "sample_hydrate_parity_ok=false fail_count=${fail_count}"
    return 1
  fi
  mirror_note "$work_root" "sample_hydrate_parity_ok" "true"
  echo "sample_hydrate_parity_ok=true"
  return 0
}

plan_change_counts_detailed_json() {
  local tofu_bin="${1:?TOFU}"
  local plan_file="${2:?PLAN_FILE}"
  local json
  json="$("$tofu_bin" show -json "$plan_file" 2>/dev/null)" || return 1
  printf '%s' "$json" | jq -c '
    {
      create: ([.resource_changes[]? | select((.change.actions | index("create")) and ((.change.actions | index("delete")) | not))] | length),
      update: ([.resource_changes[]? | select(.change.actions | index("update"))] | length),
      delete: ([.resource_changes[]? | select((.change.actions | index("delete")) and ((.change.actions | index("create")) | not))] | length),
      replace: ([.resource_changes[]? | select((.change.actions | index("delete")) and (.change.actions | index("create")))] | length)
    }
  '
}

hydrate_one_group() {
  local work_root="${1:?WORK_ROOT}"
  local group_id="${2:?GROUP_ID}"
  local tofu_bin="${3:?TOFU}"
  local groups_dir="${work_root}/groups/${group_id}"
  local gen_tf="${groups_dir}/generated.tf"
  local max_attempts="${DBSPLIT_HYDRATE_MAX_ATTEMPTS:-3}"
  local attempt=1
  local status_json plan_out remaining_json plan_file

  if [ ! -d "$groups_dir" ]; then
    echo "group_skip=${group_id} reason=no_group_dir"
    return 1
  fi

  cd "$groups_dir"
  tofu_init_with_repair "$work_root" "$group_id" "$tofu_bin" || {
    # Surface the real init log so the agent can repair broken HCL, not guess.
    local last_init=""
    last_init="$(ls -1t "${groups_dir}"/init-*.out 2>/dev/null | head -1 || true)"
    if [ -n "$last_init" ]; then
      emit_hcl_fix_targets "$work_root" "$group_id" "$last_init" || true
      echo "group_init_error_snippet=${group_id} $(validation_error_snippet "$last_init" 500)"
    fi
    echo "group_skip=${group_id} reason=init_failed_after_repair"
    return 1
  }

  while [ "$attempt" -le "$max_attempts" ]; do
    # Prefer state-backed full attribute emit (literal IDs, secret stubs). Live
    # plan -generate-config-out is a secondary enricher when parity still fails.
    local need_generate=0
    local pre_generate=""
    if [ ! -f "$gen_tf" ]; then
      need_generate=1
    elif ! assert_source_group_parity "$work_root" "$groups_dir" >"parity-pre-${attempt}.out" 2>&1; then
      need_generate=1
    fi

    if [ "$need_generate" -eq 1 ]; then
      local sanity_py=""
      if sanity_py="$(resolve_hcl_sanity_py "$work_root")"; then
        # Primary: replace/write all import addresses from the group shard.
        python3 "$sanity_py" emit-from-state --replace "$groups_dir" \
          >"emit-primary-${attempt}.out" 2>&1 || true
      fi
      if [ ! -f "$gen_tf" ] || ! assert_source_group_parity "$work_root" "$groups_dir" >"parity-after-emit-${attempt}.out" 2>&1; then
        # Secondary: live reverse-config when AWS read still works.
        if [ -f "$gen_tf" ]; then
          pre_generate="generated.tf.pre-${attempt}"
          mv -f "$gen_tf" "$pre_generate"
        fi
        "$tofu_bin" plan -generate-config-out=generated.tf -input=false -lock=false -no-color \
          -out="hydrate-${attempt}.tfplan" >"generate-${attempt}.out" 2>&1 || true
        if [ ! -f "$gen_tf" ] && [ -n "$pre_generate" ] && [ -f "$pre_generate" ]; then
          mv -f "$pre_generate" "$gen_tf"
        fi
        # If live generate still incomplete, merge missing addresses from state.
        if [ ! -f "$gen_tf" ] || ! assert_source_group_parity "$work_root" "$groups_dir" >"parity-emit-${attempt}.out" 2>&1; then
          if [ -n "${sanity_py:-}" ] || sanity_py="$(resolve_hcl_sanity_py "$work_root")"; then
            python3 "$sanity_py" emit-from-state "$groups_dir" >"emit-${attempt}.out" 2>&1 || true
          fi
        fi
      else
        echo "emit_primary_ok=${group_id} attempt=${attempt}" >"generate-${attempt}.out"
      fi
    else
      echo "generate_skipped=${group_id} reason=existing_generated_tf_parity_ok attempt=${attempt}" \
        >"generate-${attempt}.out"
    fi
    if [ -f "$gen_tf" ]; then
      fix_generated_tf_name_conflicts "$gen_tf"
    fi

    # Agent-controlled stub vars/secrets so plan -input=false can compile.
    local sanity_stub=""
    if sanity_stub="$(resolve_hcl_sanity_py "$work_root")"; then
      python3 "$sanity_stub" write-stub-tfvars "$groups_dir" >"stub-tfvars-${attempt}.out" 2>&1 || true
    fi

    local fmt_status validate_status test_status lint_status validation_ok has_tests parity_ok plan_rc compile_ok
    local error_snippet=""
    fmt_status="false"
    validate_status="false"
    test_status="skipped:no_tests"
    lint_status="skipped:tflint_missing"
    parity_ok="false"
    validation_ok="true"
    compile_ok="false"
    plan_rc=1

    # Incomplete hydrate must fail closed: missing generated.tf or import gaps
    # previously let validate pass while plan later failed (PR #44 false greens).
    if [ ! -f "$gen_tf" ]; then
      validation_ok="false"
      validate_status="missing_generated_tf"
    elif assert_source_group_parity "$work_root" "$groups_dir" >"parity-${attempt}.out" 2>&1; then
      parity_ok="true"
    else
      validation_ok="false"
      parity_ok="false"
      validate_status="import_generated_parity_failed"
    fi

    "$tofu_bin" fmt -recursive -no-color >/dev/null 2>&1 || true
    if "$tofu_bin" fmt -recursive -check -no-color >"fmt-${attempt}.out" 2>&1; then
      fmt_status="true"
    else
      validation_ok="false"
    fi

    if [ "$validation_ok" = "true" ]; then
      if "$tofu_bin" validate -no-color >"validate-${attempt}.out" 2>&1; then
        validate_status="true"
      else
        validation_ok="false"
        validate_status="false"
        # Pack finds concrete attribute/resource errors; drop safe ones; leave
        # structural issues for the agent with an actionable target list.
        emit_hcl_fix_targets "$work_root" "$group_id" "validate-${attempt}.out" || true
        error_snippet="$(validation_error_snippet "validate-${attempt}.out" 500)"
        if [ -f "$gen_tf" ]; then
          if "$tofu_bin" validate -no-color >"validate-${attempt}-postfix.out" 2>&1; then
            validate_status="true"
            validation_ok="true"
            echo "group_validate_recovered=${group_id} attempt=${attempt}"
          else
            emit_hcl_fix_targets "$work_root" "$group_id" "validate-${attempt}-postfix.out" || true
            error_snippet="$(validation_error_snippet "validate-${attempt}-postfix.out" 500)"
          fi
        fi
      fi
    fi

    has_tests="$(find . -type f \( -name '*.tftest.hcl' -o -name '*.tftest.json' \) -print -quit 2>/dev/null || true)"
    if [ -n "$has_tests" ]; then
      if "$tofu_bin" test -no-color >"test-${attempt}.out" 2>&1; then
        test_status="true"
      else
        test_status="false"
        validation_ok="false"
      fi
    fi

    if command -v tflint >/dev/null 2>&1; then
      tflint --init >/dev/null 2>&1 || true
      if tflint --format compact >"tflint-${attempt}.out" 2>&1; then
        lint_status="true"
      else
        lint_status="false"
        validation_ok="false"
      fi
    fi

    if [ "$validation_ok" != "true" ]; then
      # Prefer generate log when validate never ran (init/parity path).
      if [ -z "$error_snippet" ] && [ -f "generate-${attempt}.out" ]; then
        emit_hcl_fix_targets "$work_root" "$group_id" "generate-${attempt}.out" || true
        error_snippet="$(validation_error_snippet "generate-${attempt}.out" 500)"
      fi
      status_json="$(jq -nc \
        --arg path "$gen_tf" \
        --argjson parity "$parity_ok" \
        --arg fmt "$fmt_status" \
        --arg validate "$validate_status" \
        --arg test "$test_status" \
        --arg lint "$lint_status" \
        --argjson compile false \
        --arg snippet "$error_snippet" \
        --argjson attempt "$attempt" \
        '{generated_tf_path:$path,plan_no_changes:false,plan_exit_code:null,import_generated_parity:$parity,remaining_actions:{add:0,change:0,destroy:0},validation:{fmt:$fmt,validate:$validate,test:$test,lint:$lint},compile_ok:$compile,error_snippet:$snippet,attempt:$attempt}')"
      mirror_note "$work_root" "hcl_hydration_status:${group_id}" "$status_json"
      if [ -n "$error_snippet" ]; then
        echo "group_validate_error=${group_id} ${error_snippet}"
      fi
      echo "group_compile_ok=${group_id} false attempt=${attempt}"
      attempt=$((attempt + 1))
      continue
    fi

    plan_file="verify-${attempt}.tfplan"
    plan_rc=0
    plan_out="$("$tofu_bin" plan -refresh=false -input=false -lock=false -no-color -out="$plan_file" 2>&1)" || plan_rc=$?
    printf '%s\n' "$plan_out" >"plan-${attempt}.out"

    # Never treat a failed plan as zero-diff. A missing import config yields no
    # "N to add" lines and used to default remaining_actions to zeros (PR #44).
    if [ "$plan_rc" -ne 0 ]; then
      remaining_json='{"add":0,"change":0,"destroy":0}'
      emit_hcl_fix_targets "$work_root" "$group_id" "plan-${attempt}.out" || true
      error_snippet="$(validation_error_snippet "plan-${attempt}.out" 500)"
      status_json="$(jq -nc \
        --arg path "$gen_tf" \
        --argjson parity "$parity_ok" \
        --arg fmt "$fmt_status" \
        --arg validate "$validate_status" \
        --arg test "$test_status" \
        --arg lint "$lint_status" \
        --argjson compile false \
        --argjson plan_rc "$plan_rc" \
        --argjson remaining "$remaining_json" \
        --arg snippet "$error_snippet" \
        --argjson attempt "$attempt" \
        '{generated_tf_path:$path,plan_no_changes:false,plan_exit_code:$plan_rc,import_generated_parity:$parity,remaining_actions:$remaining,validation:{fmt:$fmt,validate:$validate,test:$test,lint:$lint},compile_ok:$compile,error_snippet:$snippet,attempt:$attempt}')"
      mirror_note "$work_root" "hcl_hydration_status:${group_id}" "$status_json"
      echo "group_valid=${group_id} plan_status=failed attempt=${attempt}"
      echo "group_compile_ok=${group_id} false attempt=${attempt}"
      attempt=$((attempt + 1))
      continue
    fi

    compile_ok="true"
    remaining_json="$(plan_change_counts_json "$tofu_bin" "$plan_file" 2>/dev/null || echo '{"add":0,"change":0,"destroy":0}')"

    if printf '%s' "$plan_out" | grep -q 'No changes'; then
      status_json="$(jq -nc \
        --arg path "$gen_tf" \
        --argjson parity "$parity_ok" \
        --arg fmt "$fmt_status" \
        --arg validate "$validate_status" \
        --arg test "$test_status" \
        --arg lint "$lint_status" \
        --argjson compile true \
        --argjson remaining "$remaining_json" \
        --argjson attempt "$attempt" \
        '{generated_tf_path:$path,plan_no_changes:true,plan_exit_code:0,import_generated_parity:$parity,remaining_actions:$remaining,validation:{fmt:$fmt,validate:$validate,test:$test,lint:$lint},compile_ok:$compile,attempt:$attempt}')"
      mirror_note "$work_root" "hcl_hydration_status:${group_id}" "$status_json"
      echo "group_ok=${group_id} attempt=${attempt}"
      echo "group_compile_ok=${group_id} true attempt=${attempt}"
      return 0
    fi

    if [ "$remaining_json" = '{"add":0,"change":0,"destroy":0}' ] && \
      ! printf '%s' "$plan_out" | grep -qE '[0-9]+ to (add|change|destroy)'; then
      status_json="$(jq -nc \
        --arg path "$gen_tf" \
        --argjson parity "$parity_ok" \
        --arg fmt "$fmt_status" \
        --arg validate "$validate_status" \
        --arg test "$test_status" \
        --arg lint "$lint_status" \
        --argjson compile true \
        --argjson remaining "$remaining_json" \
        --argjson attempt "$attempt" \
        '{generated_tf_path:$path,plan_no_changes:true,plan_exit_code:0,import_generated_parity:$parity,remaining_actions:$remaining,validation:{fmt:$fmt,validate:$validate,test:$test,lint:$lint},compile_ok:$compile,attempt:$attempt}')"
      mirror_note "$work_root" "hcl_hydration_status:${group_id}" "$status_json"
      echo "group_ok=${group_id} attempt=${attempt}"
      echo "group_compile_ok=${group_id} true attempt=${attempt}"
      return 0
    fi

    status_json="$(jq -nc \
      --arg path "$gen_tf" \
      --argjson parity "$parity_ok" \
      --arg fmt "$fmt_status" \
      --arg validate "$validate_status" \
      --arg test "$test_status" \
      --arg lint "$lint_status" \
      --argjson compile true \
      --argjson remaining "$remaining_json" \
      --argjson attempt "$attempt" \
      '{generated_tf_path:$path,plan_no_changes:false,plan_exit_code:0,import_generated_parity:$parity,remaining_actions:$remaining,validation:{fmt:$fmt,validate:$validate,test:$test,lint:$lint},compile_ok:$compile,attempt:$attempt}')"
    mirror_note "$work_root" "hcl_hydration_status:${group_id}" "$status_json"
    echo "group_valid=${group_id} plan_status=changes_remaining remaining=${remaining_json} attempt=${attempt}"
    echo "group_compile_ok=${group_id} true attempt=${attempt}"
    return 0
  done

  if [ -z "${remaining_json:-}" ]; then
    remaining_json='{"add":0,"change":0,"destroy":0}'
  fi
  status_json="$(jq -nc \
    --arg path "$gen_tf" \
    --argjson parity "${parity_ok:-false}" \
    --arg fmt "${fmt_status:-false}" \
    --arg validate "${validate_status:-false}" \
    --arg test "${test_status:-unknown}" \
    --arg lint "${lint_status:-unknown}" \
    --argjson compile false \
    --argjson plan_rc "${plan_rc:-1}" \
    --argjson remaining "$remaining_json" \
    --argjson attempt "$max_attempts" \
    '{generated_tf_path:$path,plan_no_changes:false,plan_exit_code:$plan_rc,import_generated_parity:$parity,remaining_actions:$remaining,validation:{fmt:$fmt,validate:$validate,test:$test,lint:$lint},compile_ok:$compile,attempt:$attempt}')"
  mirror_note "$work_root" "hcl_hydration_status:${group_id}" "$status_json"
  echo "group_compile_ok=${group_id} false attempt=${max_attempts}"
  # Soft coverage: keep generated.tf even when fmt/validate still fail. Matrix
  # records terraform_validation_ok=false; sync still pushes the HCL.
  if [ -f "$gen_tf" ]; then
    echo "group_hydrated_soft=${group_id} remaining=${remaining_json} attempt=${max_attempts}"
    return 0
  fi
  echo "group_fail=${group_id} remaining=${remaining_json} attempt=${max_attempts}"
  return 1
}

# True when a prior hydrate visit already left this group fmt+validate+compile
# green with a non-empty generated.tf. Used to resume after SIGKILL/OOM.
group_hydrate_already_ok() {
  local work_root="${1:?WORK_ROOT}"
  local group_id="${2:?GROUP_ID}"
  local gen_tf="${work_root}/groups/${group_id}/generated.tf"
  local status_blob validate_flag fmt_flag compile_flag

  [ -f "$gen_tf" ] || return 1
  # Reject agent "heals" that truncate generated.tf (session 1864c3a4).
  [ -s "$gen_tf" ] || return 1
  status_blob="$(read_note "$work_root" "hcl_hydration_status:${group_id}" 2>/dev/null || true)"
  [ -n "$status_blob" ] || return 1
  validate_flag="$(printf '%s' "$status_blob" | jq -r '.validation.validate // "false"' 2>/dev/null || echo false)"
  fmt_flag="$(printf '%s' "$status_blob" | jq -r '.validation.fmt // "false"' 2>/dev/null || echo false)"
  compile_flag="$(printf '%s' "$status_blob" | jq -r '.compile_ok // false' 2>/dev/null || echo false)"
  [ "$validate_flag" = "true" ] && [ "$fmt_flag" = "true" ] && [ "$compile_flag" = "true" ]
}

# Persist matrix progress after each group so a SIGKILL mid-loop still leaves a
# resume point (cannot trap SIGKILL; checkpoint is the only autoheal).
write_hydrate_checkpoint() {
  local work_root="${1:?WORK_ROOT}"
  local last_group="${2:-}"
  local ok_count="${3:-0}"
  local fail_count="${4:-0}"
  local skipped_ok="${5:-0}"
  local processed="${6:-0}"
  local remaining="${7:-0}"
  local total="${8:-0}"
  local checkpoint="${work_root}/aws/artifacts/hydrate_checkpoint.json"

  mkdir -p "${work_root}/aws/artifacts" 2>/dev/null || true
  jq -nc \
    --arg last "$last_group" \
    --argjson ok "$ok_count" \
    --argjson fail "$fail_count" \
    --argjson skipped "$skipped_ok" \
    --argjson processed "$processed" \
    --argjson remaining "$remaining" \
    --argjson total "$total" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
    '{schema:"nile-hydrate-checkpoint/v1",last_group:$last,ok:$ok,fail:$fail,skipped_ok:$skipped,processed_this_visit:$processed,remaining:$remaining,total:$total,updated_at:$ts}' \
    >"$checkpoint" 2>/dev/null || true
  mirror_note "$work_root" "hydrate_checkpoint_path" "$checkpoint" || true
  mirror_note "$work_root" "hydrate_last_group" "$last_group" || true
}

write_converge_status_artifact() {
  local work_root="${1:?WORK_ROOT}"
  local complete="${2:?COMPLETE}"
  local validation_ok="${3:-}"
  local total="${4:-0}" ok="${5:-0}" failed="${6:-0}"
  local remaining="${7:-0}" generated="${8:-0}" compile_ok="${9:-0}"
  local blocker="${10:-}"
  local artifact="${work_root}/aws/artifacts/converge-status.json"
  mkdir -p "$(dirname "$artifact")"
  local tmp
  tmp="$(mktemp "${artifact}.XXXXXX")"
  if [ "$complete" = "true" ]; then
    jq -n \
      --arg run_id "$(read_note "$work_root" workflow_run_id 2>/dev/null || true)" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg blocker "$blocker" \
      --argjson validation_ok "$validation_ok" \
      --argjson total "$total" --argjson ok "$ok" --argjson failed "$failed" \
      --argjson remaining "$remaining" --argjson generated "$generated" \
      --argjson compile_ok "$compile_ok" \
      '{schema:"nile-converge-status/v1",workflow_run_id:$run_id,updated_at:$timestamp,complete:true,blocker:$blocker,terraform_validation_ok:$validation_ok,hydrate_groups_total:$total,hydrate_groups_ok:$ok,hydrate_groups_failed:$failed,hydrate_groups_remaining:$remaining,hydrated_generated_tf_count:$generated,compile_ok_groups:$compile_ok}' >"$tmp"
  else
    jq -n \
      --arg run_id "$(read_note "$work_root" workflow_run_id 2>/dev/null || true)" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg blocker "$blocker" \
      --argjson total "$total" --argjson ok "$ok" --argjson failed "$failed" \
      --argjson remaining "$remaining" --argjson generated "$generated" \
      --argjson compile_ok "$compile_ok" \
      '{schema:"nile-converge-status/v1",workflow_run_id:$run_id,updated_at:$timestamp,complete:false,blocker:$blocker,terraform_validation_ok:null,hydrate_groups_total:$total,hydrate_groups_ok:$ok,hydrate_groups_failed:$failed,hydrate_groups_remaining:$remaining,hydrated_generated_tf_count:$generated,compile_ok_groups:$compile_ok}' >"$tmp"
  fi
  mv "$tmp" "$artifact"
  mirror_note "$work_root" "converge_status_artifact" "$artifact" || true
  echo "converge_status_artifact=${artifact}"
}

cmd_hydrate_and_plan_matrix() {
  local work_root="${1:?WORK_ROOT}"
  require_embedded_invocation || return 1

  local tofu_bin
  if ! tofu_bin="$(resolve_tofu_bin)"; then
    mirror_note "$work_root" "blocked:remote_runner_tofu_missing" "true"
    mirror_note "$work_root" "multi_plan_zero_diff_ok" "false"
    echo 'blocked:remote_runner_tofu_missing: "true"'
    echo 'multi_plan_zero_diff_ok: "false"'
    return 1
  fi

  local sample_path="${work_root}/sample_group_ids.json"
  if [ ! -f "$sample_path" ]; then
    cmd_prepare_parallel_artifacts "$work_root" || return 1
  fi

  # Serialize visits: a retried tool call must not hydrate and git-push
  # concurrently with a previous visit that is still running (trace 1c64c4a5:
  # overlapping converge visits raced .git/index.lock in PR sync and both were
  # killed at the 30m tool timeout). Lock waits up to DBSPLIT_LOCK_TIMEOUT and
  # fails loudly when a live visit holds it.
  local visit_lock=""
  visit_lock="$(acquire_run_lock "$work_root" "converge-visit")" || {
    echo "converge_visit_error=lock_timeout" >&2
    echo 'converge_retryable: "true"'
    echo 'converge_batch_incomplete: "true"'
    echo "hydrate_incomplete_reason=visit_lock_held"
    local lock_generated_count lock_total
    lock_generated_count="$(find "${work_root}/groups" -mindepth 2 -maxdepth 2 -name generated.tf -size +0 2>/dev/null | wc -l | tr -d ' ')"
    lock_total="$(jq 'length' "$sample_path" 2>/dev/null || echo 0)"
    write_converge_status_artifact "$work_root" false "" "${lock_total:-0}" 0 0 "${lock_total:-0}" "${lock_generated_count:-0}" 0 visit_lock_held
    return 0
  }

  # Cap work per pack visit so one execute_series cannot OOM the runner
  # (signal: killed). 0 = unlimited (default) — finish all groups before Ready.
  # Set DBSPLIT_HYDRATE_MAX_GROUPS_PER_VISIT>0 only when deliberately batching;
  # shell-converge-loop GO_BACKs until hydrate_groups_remaining=0.
  local max_per_visit="${DBSPLIT_HYDRATE_MAX_GROUPS_PER_VISIT:-0}"
  # Wall-clock budget per visit (default 20m) so the visit completes inside the
  # nile-runner 30m result-wait window; remaining groups are deferred and the
  # loop resumes them next visit instead of losing the whole batch result.
  local visit_budget="${DBSPLIT_HYDRATE_VISIT_BUDGET_SECONDS:-1200}"
  local visit_deadline=$(( $(date +%s) + visit_budget ))
  local ok_count fail_count zero_count total missing_count soft_count compile_ok_count
  local skipped_ok processed_this_visit remaining deferred
  ok_count=0
  fail_count=0
  zero_count=0
  total=0
  missing_count=0
  soft_count=0
  compile_ok_count=0
  skipped_ok=0
  processed_this_visit=0
  remaining=0
  deferred=0

  while IFS= read -r group_id; do
    [ -n "$group_id" ] || continue
    total=$((total + 1))
  done < <(jq -r '.[]' "$sample_path")

  while IFS= read -r group_id; do
    [ -n "$group_id" ] || continue

    if group_hydrate_already_ok "$work_root" "$group_id"; then
      skipped_ok=$((skipped_ok + 1))
      ok_count=$((ok_count + 1))
      compile_ok_count=$((compile_ok_count + 1))
      local status_blob plan_zero
      status_blob="$(read_note "$work_root" "hcl_hydration_status:${group_id}" 2>/dev/null || true)"
      plan_zero="$(printf '%s' "$status_blob" | jq -r '.plan_no_changes // false' 2>/dev/null || echo false)"
      if [ "$plan_zero" = "true" ]; then
        zero_count=$((zero_count + 1))
      fi
      echo "group_resume_skip=${group_id} reason=already_validate_ok"
      write_hydrate_checkpoint "$work_root" "$group_id" "$ok_count" "$fail_count" "$skipped_ok" "$processed_this_visit" "$remaining" "$total"
      continue
    fi

    if [ "$max_per_visit" -gt 0 ] 2>/dev/null && [ "$processed_this_visit" -ge "$max_per_visit" ]; then
      remaining=$((remaining + 1))
      deferred=$((deferred + 1))
      echo "group_deferred=${group_id} reason=visit_batch_cap max=${max_per_visit}"
      continue
    fi

    if [ "$visit_budget" -gt 0 ] 2>/dev/null && [ "$(date +%s)" -ge "$visit_deadline" ] 2>/dev/null; then
      remaining=$((remaining + 1))
      deferred=$((deferred + 1))
      echo "group_deferred=${group_id} reason=visit_time_budget budget_seconds=${visit_budget}"
      continue
    fi

    processed_this_visit=$((processed_this_visit + 1))
    if hydrate_one_group "$work_root" "$group_id" "$tofu_bin"; then
      local status_blob validate_flag fmt_flag plan_zero compile_flag
      status_blob="$(read_note "$work_root" "hcl_hydration_status:${group_id}" 2>/dev/null || true)"
      validate_flag="$(printf '%s' "$status_blob" | jq -r '.validation.validate // "false"' 2>/dev/null || echo false)"
      fmt_flag="$(printf '%s' "$status_blob" | jq -r '.validation.fmt // "false"' 2>/dev/null || echo false)"
      plan_zero="$(printf '%s' "$status_blob" | jq -r '.plan_no_changes // false' 2>/dev/null || echo false)"
      compile_flag="$(printf '%s' "$status_blob" | jq -r '.compile_ok // false' 2>/dev/null || echo false)"
      if [ "$validate_flag" = "true" ] && [ "$fmt_flag" = "true" ] && [ "$compile_flag" = "true" ]; then
        ok_count=$((ok_count + 1))
        compile_ok_count=$((compile_ok_count + 1))
        if [ "$plan_zero" = "true" ]; then
          zero_count=$((zero_count + 1))
        fi
      else
        soft_count=$((soft_count + 1))
        fail_count=$((fail_count + 1))
      fi
    else
      missing_count=$((missing_count + 1))
      fail_count=$((fail_count + 1))
    fi
    # Each initialized group holds its own copy of the provider binaries, which
    # adds up to tens of GB across a matrix and evicts the runner for disk
    # pressure. The plugin cache keeps re-init cheap, so release them per group.
    cleanup_terraform_runtime_artifacts "$work_root" "$group_id"
    write_hydrate_checkpoint "$work_root" "$group_id" "$ok_count" "$fail_count" "$skipped_ok" "$processed_this_visit" "$remaining" "$total"
  done < <(jq -r '.[]' "$sample_path")

  # Recount remaining after the loop (deferred groups only; failed still "done").
  remaining="$deferred"

  local validation_ok="false"
  local multi_ok="false"
  local batch_incomplete="false"
  if [ "$remaining" -gt 0 ]; then
    batch_incomplete="true"
  fi

  if [ "$batch_incomplete" != "true" ]; then
    if [ "$total" -gt 0 ] && [ "$fail_count" -eq 0 ]; then
      validation_ok="true"
    fi
    if [ "$total" -gt 0 ] && [ "$zero_count" -eq "$total" ]; then
      multi_ok="true"
    fi

    # Belt-and-suspenders: even if hydrate_one_group returned 0, matrix must
    # have complete generated.tf for every selected group before sync/PR.
    if [ "$validation_ok" = "true" ]; then
      if ! assert_sample_groups_hydrated "$work_root" "${work_root}/groups"; then
        validation_ok="false"
        multi_ok="false"
        fail_count=$((fail_count + 1))
      fi
    fi
  fi

  local generated_count
  generated_count="$(find "${work_root}/groups" -mindepth 2 -maxdepth 2 -name generated.tf -size +0 2>/dev/null | wc -l | tr -d ' ')"

  write_hydrate_checkpoint "$work_root" "" "$ok_count" "$fail_count" "$skipped_ok" "$processed_this_visit" "$remaining" "$total"
  mirror_note "$work_root" "hydrated_generated_tf_count" "$generated_count"
  mirror_note "$work_root" "hydrate_groups_resumed" "$skipped_ok"
  mirror_note "$work_root" "hydrate_groups_processed_this_visit" "$processed_this_visit"
  mirror_note "$work_root" "hydrate_groups_remaining" "$remaining"
  mirror_note "$work_root" "hydrate_compile_ok_count" "$compile_ok_count"
  mirror_note "$work_root" "stage_summary:shell-converge-matrix" "valid_groups=${ok_count} invalid_groups=${fail_count} soft_hydrated_groups=${soft_count} missing_generated_tf=${missing_count} zero_change_groups=${zero_count} compile_ok_groups=${compile_ok_count} generated_tf_count=${generated_count} resumed=${skipped_ok} processed=${processed_this_visit} remaining=${remaining}"

  echo "terraform_valid_groups=${ok_count}"
  echo "terraform_invalid_groups=${fail_count}"
  echo "terraform_soft_hydrated_groups=${soft_count}"
  echo "terraform_missing_generated_tf=${missing_count}"
  echo "terraform_zero_change_groups=${zero_count}"
  echo "terraform_compile_ok_groups=${compile_ok_count}"
  echo "hydrated_generated_tf_count=${generated_count}"
  echo "hydrate_group_selected=${total}"
  echo "hydrate_groups_resumed=${skipped_ok}"
  echo "hydrate_groups_processed_this_visit=${processed_this_visit}"
  echo "hydrate_groups_remaining=${remaining}"
  echo "hydrate_max_groups_per_visit=${max_per_visit}"

  if [ "$batch_incomplete" = "true" ]; then
    # Intentionally omit terraform_validation_ok so shell-converge-loop GO_BACKs
    # and the next visit resumes. Emitting false would FINISH and stop autoheal.
    # Clear any stale conclusive sentinel from a prior visit's notes.
    mirror_note "$work_root" "terraform_validation_ok" "" || true
    mirror_note "$work_root" "converge_retryable" "true"
    mirror_note "$work_root" "converge_batch_incomplete" "true"
    mirror_note "$work_root" "multi_plan_zero_diff_ok" "false"
    echo 'converge_retryable: "true"'
    echo 'converge_batch_incomplete: "true"'
    echo 'multi_plan_zero_diff_ok: "false"'
    echo "hydrate_incomplete_reason=visit_batch_cap remaining=${remaining}"
  else
    mirror_note "$work_root" "converge_retryable" "false"
    mirror_note "$work_root" "converge_batch_incomplete" "false"
    mirror_note "$work_root" "terraform_validation_ok" "$validation_ok"
    mirror_note "$work_root" "multi_plan_zero_diff_ok" "$multi_ok"
    echo 'converge_retryable: "false"'
    echo 'converge_batch_incomplete: "false"'
    echo "terraform_validation_ok: \"${validation_ok}\""
    echo "multi_plan_zero_diff_ok: \"${multi_ok}\""
  fi

  # Durable runner-side validation record, copied into the discovery PR below.
  write_converge_status_artifact "$work_root" "$([[ "$batch_incomplete" != true ]] && echo true || echo false)" "$validation_ok" \
    "$total" "$ok_count" "$fail_count" "$remaining" "$generated_count" "$compile_ok_count" \
    "$([ "$batch_incomplete" = true ] && echo batch_incomplete || true)"

  # Aggregate surgical targets across the sample so the agent has one punch list
  # instead of re-running the same pack with no diagnosis.
  if [ "$validation_ok" != "true" ] || [ "$batch_incomplete" = "true" ]; then
    local agg="${work_root}/aws/artifacts/hcl_fix_report.json"
    mkdir -p "${work_root}/aws/artifacts" 2>/dev/null || mkdir -p "${work_root}/artifacts" 2>/dev/null || true
    python3 - "$work_root" "$sample_path" "$agg" <<'PY' || true
import json, sys
from pathlib import Path
work_root, sample_path, agg = sys.argv[1:4]
groups = json.loads(Path(sample_path).read_text(encoding="utf-8"))
all_targets = []
for gid in groups:
    p = Path(work_root) / "groups" / gid / "hcl_fix_targets.json"
    if not p.is_file():
        continue
    data = json.loads(p.read_text(encoding="utf-8"))
    all_targets.extend(data.get("targets") or [])
report = {
    "schema": "nile-hcl-fix-report/v1",
    "invalid_groups": len({t.get("group_id") for t in all_targets if t.get("group_id")}),
    "target_count": len(all_targets),
    "targets": all_targets[:200],
}
Path(agg).parent.mkdir(parents=True, exist_ok=True)
Path(agg).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(f"hcl_fix_report_path={agg}")
print(f"hcl_fix_report_targets={len(all_targets)}")
for t in all_targets[:40]:
    hint = (t.get("rewrite_hint") or "")[:100]
    excerpt = (t.get("excerpt") or "")[:100]
    extra = f" hint={hint}" if hint else (f" excerpt={excerpt}" if excerpt else "")
    print(
        "hcl_fix_target "
        f"group={t.get('group_id','')} "
        f"address={t.get('address') or '?'} "
        f"attr={t.get('attribute') or '-'} "
        f"suggestion={t.get('suggestion') or '-'} "
        f"error={(t.get('error') or '')[:80]}"
        f"{extra}"
    )
PY
    if [ -f "$agg" ]; then
      mirror_note "$work_root" "hcl_fix_report_path" "$agg" || true
    fi
    # Soft-fail: keep exit 0 so converge can still sync generated.tf to the PR.
    release_run_lock "$visit_lock"
    return 0
  fi
  release_run_lock "$visit_lock"
  return 0
}

cmd_azure_migration_blueprint() {
  local work_root="${1:?WORK_ROOT}"
  require_embedded_invocation || return 1

  mkdir -p "${work_root}/azure/artifacts"

  python3 - "$work_root" <<'PY'
import hashlib
import json
import os
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
artifacts = work / "azure" / "artifacts"
artifacts.mkdir(parents=True, exist_ok=True)
groups_dir = work / "groups"
manifest_path = work / "logical_group_manifest.json"

sys.path.insert(0, str(work / "scripts"))
import azure_mapping_catalog as amc

catalog = amc.load_catalog()

# Categories that always warrant a human look even when the catalog has a mapping.
# Deepened scaffolds (identity RBAC, LB, DNS, cache, nosql, static_ip) rely on confidence_threshold.
REVIEW_CATEGORIES = {
    "placeholder",
    "key_management",
    "analytics",
    "non_applicable",
    "cdn",
    "containers",
    "api",
}

profile = {
    "version": "2026-08-12.review-candidate.v1",
    "mode": "review_candidate",
    "source_cloud": "aws",
    "target_cloud": "azure",
    "confidence_threshold": 0.8,
    "defaults": {
        "location": "eastus",
        "resource_group_pattern": "rg-${group_id}",
        "tags": {
            "generated_by": "stackgen-aws-migrator",
            "migration_mode": "review-candidate",
            "standards": "caf-waf-opentofu",
        },
        "networking": {
            "vnet_cidr": "10.0.0.0/16",
            "subnet_cidr": "10.0.1.0/24",
            "nsg": "created when compute, Kubernetes, functions, or networking resources are present",
        },
        "identity": {
            "default": "SystemAssigned or user-assigned managed identity",
            "iam_mapping": "AWS IAM roles and policies map to managed identity plus Azure RBAC review notes",
        },
        "sku": {
            "aks_node_size": "Standard_DS2_v2",
            "vm_size": "Standard_B2s",
            "vmss_sku": "Standard_B2s",
            "storage_replication": "LRS",
            "service_bus_sku": "Standard",
            "event_hubs_sku": "Standard",
            "postgres_sku": "B_Standard_B1ms",
        },
        "module_source_preference": "local Terraform roots under azure/groups/<group_id>; upstream modules can replace these later",
    },
    "mapping_catalog": {
        "path": "scripts/mappings/aws-to-azure.json",
        "version": catalog.get("version"),
        "source_cloud": catalog.get("source_cloud", "aws"),
        "destination_cloud": catalog.get("destination_cloud", "azure"),
        "note": "Deterministic AWS->Azure resource type mapping is driven by this catalog, not ad-hoc heuristics.",
    },
}

def sanitize_group_id(value: str) -> str:
    value = re.sub(r"[^a-zA-Z0-9_-]+", "-", value or "group").strip("-_")
    return value.lower()[:64] or "group"

def load_manifest_groups():
    groups = {}
    if manifest_path.exists():
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        if isinstance(data, dict):
            iterator = data.items()
        elif isinstance(data, list):
            iterator = [(str(item.get("group_id") or item.get("id") or idx), item) for idx, item in enumerate(data) if isinstance(item, dict)]
        else:
            iterator = []
        for gid, entry in iterator:
            if not isinstance(entry, dict):
                entry = {}
            group_id = sanitize_group_id(str(entry.get("group_id") or entry.get("id") or gid))
            resources = entry.get("resources") or entry.get("addresses") or entry.get("resource_addresses") or []
            resource_types = set(entry.get("resource_types") or entry.get("types") or [])
            if isinstance(resources, dict):
                resources = list(resources.keys())
            for resource in resources:
                if isinstance(resource, dict):
                    address = str(resource.get("address") or resource.get("resource_address") or "")
                    rtype = str(resource.get("type") or resource.get("resource_type") or "")
                else:
                    address = str(resource)
                    rtype = ""
                if not rtype and "." in address:
                    rtype = address.split(".")[-2] if address.endswith("]") and len(address.split(".")) > 1 else address.split(".")[0]
                if rtype.startswith("aws_"):
                    resource_types.add(rtype)
            groups.setdefault(group_id, {"group_id": group_id, "source_resource_types": set(), "source_resource_count": 0})
            groups[group_id]["source_resource_types"].update(resource_types)
            try:
                groups[group_id]["source_resource_count"] = int(entry.get("resource_count") or len(resources) or groups[group_id]["source_resource_count"])
            except Exception:
                groups[group_id]["source_resource_count"] = len(resources)
    if groups_dir.exists():
        for path in sorted(groups_dir.iterdir()):
            if not path.is_dir():
                continue
            group_id = sanitize_group_id(path.name)
            groups.setdefault(group_id, {"group_id": group_id, "source_resource_types": set(), "source_resource_count": 0})
            tf_types = set()
            for tf in path.glob("*.tf"):
                text = tf.read_text(encoding="utf-8", errors="ignore")
                tf_types.update(re.findall(r'resource\s+"(aws_[^"]+)"\s+"', text))
                tf_types.update(re.findall(r'import\s+\{[^}]*to\s*=\s*([^.\s]+)\.', text, flags=re.S))
            groups[group_id]["source_resource_types"].update(tf_types)
            if not groups[group_id]["source_resource_count"]:
                groups[group_id]["source_resource_count"] = len(tf_types)
    return groups

def decision_from_catalog(rtype):
    resolved = amc.resolve(catalog, rtype)
    return {
        "source_type": resolved["source_type"],
        "status": resolved["status"],
        "category": resolved["category"],
        "emission": resolved.get("emission") or amc.emission_for_category(resolved.get("category")),
        "hitl_lane": resolved.get("hitl_lane") or amc.classify_hitl_lane(resolved),
        "azure_service": resolved["azure_service"],
        "default_target": resolved["default_target"],
        "target_resource_types": resolved["target_resource_types"],
        "companions": resolved["companions"],
        "attribute_mapping": resolved["attribute_mapping"],
        "confidence": round(float(resolved["confidence"]), 2),
        "review": resolved["review"],
        "match_kind": resolved["match_kind"],
    }

def classify(source_types):
    decisions = []
    matched_categories = set()
    for rtype in sorted(source_types):
        decision = decision_from_catalog(rtype)
        decisions.append(decision)
        matched_categories.add(decision["category"])
    if not decisions:
        decisions.append({
            "source_type": "unknown",
            "status": "unsupported",
            "category": "placeholder",
            "emission": "resource_group_only",
            "hitl_lane": "ambiguous",
            "azure_service": "Placeholder Terraform scaffold",
            "default_target": None,
            "target_resource_types": [],
            "companions": [],
            "attribute_mapping": {},
            "confidence": 0.40,
            "review": "No source resource types were discoverable for this group.",
            "match_kind": "none",
        })
        matched_categories.add("placeholder")
    return decisions, sorted(matched_categories)

groups = load_manifest_groups()
blueprint_groups = []
review_entries = []
for group_id, entry in sorted(groups.items()):
    source_types = sorted(t for t in entry["source_resource_types"] if str(t).startswith("aws_"))
    decisions, categories = classify(source_types)
    confidence, confidence_reason = amc.group_confidence(decisions)
    review_needed, review_reasons = amc.explain_review_needed(
        decisions,
        confidence,
        confidence_reason,
        profile["confidence_threshold"],
        REVIEW_CATEGORIES,
    )
    lane_counts = {}
    for d in decisions:
        lane = d.get("hitl_lane") or amc.classify_hitl_lane(d)
        lane_counts[lane] = lane_counts.get(lane, 0) + 1
    # Prefer actionable lanes for index bucketing.
    primary_lane = "defer"
    for candidate in ("ambiguous", "permissions", "shape", "defer"):
        if lane_counts.get(candidate):
            primary_lane = candidate
            break
    if confidence_reason == "non_applicable_only":
        primary_lane = "defer"
    stable_hash = hashlib.sha1(group_id.encode("utf-8")).hexdigest()[:12]
    group_record = {
        "group_id": group_id,
        "stable_hash": stable_hash,
        "source_resource_count": entry.get("source_resource_count", 0),
        "source_resource_types": source_types,
        "target_categories": categories,
        "mapping_decisions": decisions,
        "hitl_lane_counts": lane_counts,
        "primary_hitl_lane": primary_lane,
        "confidence": confidence,
        "confidence_reason": confidence_reason or None,
        "review_needed": review_needed,
        "review_needed_reasons": review_reasons,
        "review_needed_reason": "; ".join(review_reasons) if review_reasons else None,
        "azure_root": f"azure/groups/{group_id}",
    }
    blueprint_groups.append(group_record)
    if review_needed:
        review_entries.append(group_record)

blueprint = {
    "profile": profile,
    "group_count": len(blueprint_groups),
    "groups": blueprint_groups,
    "review_needed_count": len(review_entries),
    "hitl_lane_counts": {
        lane: sum(1 for g in blueprint_groups if g.get("primary_hitl_lane") == lane)
        for lane in ("shape", "permissions", "ambiguous", "defer")
    },
}

(artifacts / "migration-profile.json").write_text(json.dumps(profile, indent=2, sort_keys=True) + "\n", encoding="utf-8")
(artifacts / "migration-blueprint.json").write_text(json.dumps(blueprint, indent=2, sort_keys=True) + "\n", encoding="utf-8")

lines = [
    "# Azure migration review-needed items",
    "",
    "Review-candidate mode (CAF/WAF defaults). Triage by HITL lane — do not treat every flagged group the same.",
    "",
    "## How to navigate",
    "",
    "1. Read the [Summary](#summary) lane counts.",
    "2. Work **ambiguous** and **permissions** first; **shape** is optional spot-check; **defer** usually skip.",
    "3. Operator checklist: [`TODO.md`](./TODO.md).",
    "",
]
if not review_entries:
    lines.extend(["## Summary", "", "No mandatory HITL groups — shape scaffolds cleared the confidence gate. Spot-check full_scaffold roots in TODO still recommended.", ""])
else:
    def _lane(g):
        return g.get("primary_hitl_lane") or (
            "defer" if (g.get("confidence_reason") or "") == "non_applicable_only" else "ambiguous"
        )

    by_lane = {k: [] for k in ("ambiguous", "permissions", "shape", "defer")}
    for g in review_entries:
        by_lane.setdefault(_lane(g), []).append(g)
    lines.extend(
        [
            "## Summary",
            "",
            f"- Review-needed groups: **{len(review_entries)}**",
            f"- Ambiguous (product/engine/topology choice): **{len(by_lane['ambiguous'])}**",
            f"- Permissions (IAM action translation): **{len(by_lane['permissions'])}**",
            f"- Shape (below threshold / residual naming-SKU): **{len(by_lane['shape'])}**",
            f"- Defer (non_applicable-only): **{len(by_lane['defer'])}**",
            "",
            "## Index",
            "",
        ]
    )
    for lane, title in (
        ("ambiguous", "Ambiguous (do these first)"),
        ("permissions", "Permissions (IAM / RBAC)"),
        ("shape", "Shape (spot-check)"),
        ("defer", "Defer (usually skip)"),
    ):
        lines.extend([f"### {title}", ""])
        for group in by_lane.get(lane) or []:
            gid = group["group_id"]
            reason = group.get("confidence_reason") or lane
            lines.append(f"- [`{gid}`](#{gid}) — `{reason}`")
        if not by_lane.get(lane):
            lines.append("- _(none)_")
        lines.append("")
    ordered = by_lane["ambiguous"] + by_lane["permissions"] + by_lane["shape"] + by_lane["defer"]
    for group in ordered:
        lines.append(f"## {group['group_id']}")
        lines.append("")
        lines.append(f"- HITL lane: `{group.get('primary_hitl_lane')}`")
        lines.append(f"- Confidence: `{group['confidence']}`")
        if group.get("confidence_reason"):
            lines.append(f"- Confidence reason: `{group['confidence_reason']}`")
        if group.get("review_needed_reason"):
            lines.append(f"- Why review is required: {group['review_needed_reason']}")
        lines.append(f"- Source resource types: `{', '.join(group['source_resource_types']) or 'unknown'}`")
        lines.append(f"- Terraform root: `{group.get('azure_root') or ('azure/groups/' + group['group_id'])}`")
        for decision in group["mapping_decisions"]:
            lane = decision.get("hitl_lane") or amc.classify_hitl_lane(decision)
            if lane == "defer":
                continue
            if lane in ("permissions", "ambiguous") or decision["confidence"] < profile["confidence_threshold"] or decision.get("status") != "mapped" or decision["category"] in REVIEW_CATEGORIES:
                status = decision.get("status", "mapped")
                lines.append(
                    f"- `{decision['source_type']}` -> **{decision['azure_service']}** "
                    f"(`{decision['confidence']}`, {status}, lane=`{lane}`): {decision['review']}"
                )
        lines.append("")
(artifacts / "review-needed.md").write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

print(f"azure_migration_blueprint_path={artifacts / 'migration-blueprint.json'}")
print(f"azure_review_needed_path={artifacts / 'review-needed.md'}")
print(f"azure_blueprint_group_count={len(blueprint_groups)}")
PY

  local group_count
  group_count="$(jq -r '.group_count // 0' "${work_root}/azure/artifacts/migration-blueprint.json")"
  mirror_note "$work_root" "azure_migration_profile_path" "${work_root}/azure/artifacts/migration-profile.json"
  mirror_note "$work_root" "azure_migration_blueprint_path" "${work_root}/azure/artifacts/migration-blueprint.json"
  mirror_note "$work_root" "azure_review_needed_path" "${work_root}/azure/artifacts/review-needed.md"
  mirror_note "$work_root" "azure_blueprint_group_count" "$group_count"
  mirror_note "$work_root" "azure_migration_blueprint_ok" "true"
  mirror_note "$work_root" "stage_summary:azure-migration-blueprint" "ok"
  echo 'azure_migration_blueprint_ok: "true"'
  echo "azure_blueprint_group_count=${group_count}"
}

cmd_azure_iac_generate() {
  local work_root="${1:?WORK_ROOT}"
  require_embedded_invocation || return 1

  if [ ! -f "${work_root}/azure/artifacts/migration-blueprint.json" ]; then
    cmd_azure_migration_blueprint "$work_root"
  fi

  local gen_py="${work_root}/scripts/azure_iac_generate.py"
  if [ ! -f "$gen_py" ]; then
    echo "azure_iac_generate_error=missing_azure_iac_generate.py" >&2
    mirror_note "$work_root" "azure_iac_generated" "false"
    mirror_note "$work_root" "stage_summary:azure-iac-generate" "blocked:missing_generator"
    return 1
  fi
  python3 "$gen_py" "$work_root"

  local group_count
  group_count="$(jq -r '.generated_group_count // 0' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || echo 0)"
  mirror_note "$work_root" "azure_iac_group_count" "$group_count"
  mirror_note "$work_root" "azure_iac_generated" "true"
  mirror_note "$work_root" "stage_summary:azure-iac-generate" "ok"
  local conv_rate conv_ok eligible converted identity_count app_iam_rate app_iam_ok app_iam_eligible app_iam_converted
  conv_rate="$(jq -r '.infra_conversion_rate // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  conv_ok="$(jq -r '.infra_conversion_ok // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  eligible="$(jq -r '.infra_eligible_count // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  converted="$(jq -r '.infra_converted_count // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  identity_count="$(jq -r '.identity_scaffold_count // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  app_iam_rate="$(jq -r '.app_iam_conversion_rate // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  app_iam_ok="$(jq -r '.app_iam_conversion_ok // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  app_iam_eligible="$(jq -r '.app_iam_eligible_count // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  app_iam_converted="$(jq -r '.app_iam_converted_count // empty' "${work_root}/azure/artifacts/generation-summary.json" 2>/dev/null || true)"
  if [ -n "$conv_rate" ]; then
    mirror_note "$work_root" "azure_infra_conversion_rate" "$conv_rate"
  fi
  if [ -n "$conv_ok" ]; then
    mirror_note "$work_root" "azure_infra_conversion_ok" "$conv_ok"
  fi
  if [ -n "$eligible" ]; then
    mirror_note "$work_root" "azure_infra_eligible_count" "$eligible"
  fi
  if [ -n "$converted" ]; then
    mirror_note "$work_root" "azure_infra_converted_count" "$converted"
  fi
  if [ -n "$identity_count" ]; then
    mirror_note "$work_root" "azure_identity_scaffold_count" "$identity_count"
  fi
  if [ -n "$app_iam_rate" ]; then
    mirror_note "$work_root" "azure_app_iam_conversion_rate" "$app_iam_rate"
    mirror_note "$work_root" "azure_app_iam_conversion_ok" "$app_iam_ok"
    mirror_note "$work_root" "azure_app_iam_eligible_count" "$app_iam_eligible"
    mirror_note "$work_root" "azure_app_iam_converted_count" "$app_iam_converted"
  fi
  echo 'azure_iac_generated: "true"'
  echo "azure_iac_group_count=${group_count}"
  if [ -n "$conv_rate" ]; then
    echo "azure_infra_conversion_rate=${conv_rate}"
    echo "azure_infra_conversion_ok=${conv_ok}"
  fi
  if [ -n "$app_iam_rate" ]; then
    echo "azure_app_iam_conversion_rate=${app_iam_rate}"
    echo "azure_app_iam_conversion_ok=${app_iam_ok}"
  fi
}

# Parallel-with-validate stage: lint + security scanners + mechanical autofix.
# Mutates ${cloud}/groups in place so azure-pr / gcp-pr pick up the fixes.
cmd_destination_iac_harden() {
  local work_root="${1:?WORK_ROOT}"
  local cloud="${2:?CLOUD}" # azure|gcp
  require_embedded_invocation || return 1

  local groups_dir="${work_root}/${cloud}/groups"
  local artifacts_dir="${work_root}/${cloud}/artifacts"
  local report="${artifacts_dir}/harden-report.json"
  local findings_md="${artifacts_dir}/harden-findings.md"
  local parallel="${DEST_HARDEN_PARALLELISM:-4}"
  local harden_py="${work_root}/scripts/destination_iac_harden.py"
  local tofu_bin=""

  if [ ! -d "$groups_dir" ]; then
    mirror_note "$work_root" "${cloud}_iac_harden_ok" "false"
    mirror_note "$work_root" "stage_summary:${cloud}-iac-harden" "blocked:generation_missing"
    echo "${cloud}_iac_harden_ok: \"false\""
    echo "stage_summary:${cloud}-iac-harden=blocked:generation_missing"
    return 1
  fi

  mkdir -p "$artifacts_dir" "${artifacts_dir}/harden-groups"
  if [ ! -f "$harden_py" ]; then
    if [ -f "$(dirname "${BASH_SOURCE[0]}")/destination_iac_harden.py" ]; then
      harden_py="$(dirname "${BASH_SOURCE[0]}")/destination_iac_harden.py"
    else
      mirror_note "$work_root" "${cloud}_iac_harden_ok" "false"
      mirror_note "$work_root" "stage_summary:${cloud}-iac-harden" "blocked:missing_harden_script"
      echo "${cloud}_iac_harden_ok: \"false\""
      echo "stage_summary:${cloud}-iac-harden=blocked:missing_harden_script"
      return 1
    fi
  fi

  tofu_bin="$(resolve_tofu_bin 2>/dev/null || true)"

  local group_list
  group_list="$(mktemp "${artifacts_dir}/harden-group-list.XXXXXX")"
  find "$groups_dir" -mindepth 1 -maxdepth 1 -type d | sort >"$group_list"

  # Bounded parallel workers (stage itself is DAG-parallel with *-iac-validate).
  local running=0
  while IFS= read -r group_dir; do
    [ -n "$group_dir" ] || continue
    (
      group_id="$(basename "$group_dir")"
      lock="${group_dir}/.harden.lock"
      out_json="${artifacts_dir}/harden-groups/${group_id}.json"
      lint_status="skipped:tflint_missing"
      fmt_status="skipped:tofu_missing"
      scanner_status="skipped:no_scanner"
      scanner_tool="none"
      exec 9>"$lock"
      if command -v flock >/dev/null 2>&1; then
        flock 9
      fi
      python3 "$harden_py" --cloud "$cloud" --group-dir "$group_dir" --json-out "$out_json" \
        >"${artifacts_dir}/harden-groups/${group_id}.autofix.out" 2>&1 || true

      if [ -n "$tofu_bin" ] && assert_destination_group_resources "$work_root" "$group_dir" >/dev/null 2>&1; then
        if "$tofu_bin" fmt -recursive -no-color "$group_dir" >/dev/null 2>&1; then
          fmt_status="true"
        else
          fmt_status="false"
        fi
      elif [ -z "$tofu_bin" ]; then
        fmt_status="skipped:tofu_missing"
      else
        fmt_status="skipped:empty_scaffold"
      fi

      if command -v tflint >/dev/null 2>&1 && [ "$fmt_status" != "skipped:empty_scaffold" ]; then
        (
          cd "$group_dir"
          tflint --init >/dev/null 2>&1 || true
          if tflint --fix --format compact >"tflint-harden.out" 2>&1; then
            lint_status="true"
          elif tflint --format compact >"tflint-harden.out" 2>&1; then
            lint_status="true"
          else
            lint_status="false"
          fi
        )
      fi

      if command -v checkov >/dev/null 2>&1; then
        scanner_tool="checkov"
        if checkov -d "$group_dir" --framework terraform --quiet -o json \
          >"${artifacts_dir}/harden-groups/${group_id}.checkov.json" 2>"${artifacts_dir}/harden-groups/${group_id}.checkov.err"; then
          scanner_status="true"
        else
          scanner_status="findings"
        fi
      elif command -v tfsec >/dev/null 2>&1; then
        scanner_tool="tfsec"
        if tfsec "$group_dir" --format json --out "${artifacts_dir}/harden-groups/${group_id}.tfsec.json" >/dev/null 2>&1; then
          scanner_status="true"
        else
          scanner_status="findings"
        fi
      elif command -v trivy >/dev/null 2>&1; then
        scanner_tool="trivy"
        if trivy config "$group_dir" --quiet --format json \
          --output "${artifacts_dir}/harden-groups/${group_id}.trivy.json" >/dev/null 2>&1; then
          scanner_status="true"
        else
          scanner_status="findings"
        fi
      fi

      jq -n \
        --arg gid "$group_id" \
        --arg fmt "$fmt_status" \
        --arg lint "$lint_status" \
        --arg scanner "$scanner_status" \
        --arg tool "$scanner_tool" \
        '{group_id:$gid,fmt:$fmt,lint:$lint,scanner:$scanner,scanner_tool:$tool}' \
        >"${artifacts_dir}/harden-groups/${group_id}.meta.json"
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$parallel" ]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done <"$group_list"
  wait
  rm -f "$group_list"

  local total fixes findings residual fmt_fail lint_fail scanner_findings
  total="$(find "${artifacts_dir}/harden-groups" -name '*.json' ! -name '*.meta.json' ! -name '*.checkov.json' ! -name '*.tfsec.json' ! -name '*.trivy.json' | wc -l | tr -d ' ')"
  fixes=0
  findings=0
  residual=0
  fmt_fail=0
  lint_fail=0
  scanner_findings=0
  if ls "${artifacts_dir}/harden-groups"/*.json >/dev/null 2>&1; then
    fixes="$(find "${artifacts_dir}/harden-groups" -name '*.json' ! -name '*.meta.json' ! -name '*.checkov.json' ! -name '*.tfsec.json' ! -name '*.trivy.json' -print0 | xargs -0 jq -s '[.[].fixes // [] | length] | add // 0' 2>/dev/null || echo 0)"
    findings="$(find "${artifacts_dir}/harden-groups" -name '*.json' ! -name '*.meta.json' ! -name '*.checkov.json' ! -name '*.tfsec.json' ! -name '*.trivy.json' -print0 | xargs -0 jq -s '[.[].findings // [] | length] | add // 0' 2>/dev/null || echo 0)"
    residual="$(find "${artifacts_dir}/harden-groups" -name '*.json' ! -name '*.meta.json' ! -name '*.checkov.json' ! -name '*.tfsec.json' ! -name '*.trivy.json' -print0 | xargs -0 jq -s '[.[].findings // [] | map(select((.autofixed // "false") != "true")) | length] | add // 0' 2>/dev/null || echo 0)"
  fi
  if ls "${artifacts_dir}/harden-groups"/*.meta.json >/dev/null 2>&1; then
    fmt_fail="$(jq -s '[.[] | select(.fmt == "false")] | length' "${artifacts_dir}/harden-groups"/*.meta.json 2>/dev/null || echo 0)"
    lint_fail="$(jq -s '[.[] | select(.lint == "false")] | length' "${artifacts_dir}/harden-groups"/*.meta.json 2>/dev/null || echo 0)"
    scanner_findings="$(jq -s '[.[] | select(.scanner == "findings")] | length' "${artifacts_dir}/harden-groups"/*.meta.json 2>/dev/null || echo 0)"
  fi

  jq -n \
    --arg cloud "$cloud" \
    --argjson total "${total:-0}" \
    --argjson fixes "${fixes:-0}" \
    --argjson findings "${findings:-0}" \
    --argjson residual "${residual:-0}" \
    --argjson fmt_fail "${fmt_fail:-0}" \
    --argjson lint_fail "${lint_fail:-0}" \
    --argjson scanner_findings "${scanner_findings:-0}" \
    --arg parallel "$parallel" \
    '{
      cloud: $cloud,
      group_count: $total,
      autofix_count: $fixes,
      finding_count: $findings,
      residual_count: $residual,
      fmt_fail_count: $fmt_fail,
      lint_fail_count: $lint_fail,
      scanner_finding_groups: $scanner_findings,
      parallelism: $parallel,
      mode: "parallel_with_validate"
    }' >"$report"

  {
    echo "# ${cloud} IaC harden findings"
    echo
    echo "Mechanical lint/security pass (runs **in parallel** with \`${cloud}-iac-validate\`)."
    echo "Autofixes are applied under \`${cloud}/groups/\` and land in the same PR."
    echo
    echo "| Metric | Value |"
    echo "| --- | --- |"
    echo "| Groups scanned | \`${total}\` |"
    echo "| Autofixes applied | \`${fixes}\` |"
    echo "| Residual findings | \`${residual}\` |"
    echo "| fmt failures | \`${fmt_fail}\` |"
    echo "| tflint failures | \`${lint_fail}\` |"
    echo "| Scanner finding groups | \`${scanner_findings}\` |"
    echo
    echo "Per-group detail: \`${cloud}/artifacts/harden-groups/\`."
    echo "Machine report: [\`harden-report.json\`](./harden-report.json)."
    echo
    echo "## Autofixes applied (sample)"
    echo
    find "${artifacts_dir}/harden-groups" -name '*.json' \
      ! -name '*.meta.json' ! -name '*.checkov.json' ! -name '*.tfsec.json' ! -name '*.trivy.json' -print0 2>/dev/null \
      | xargs -0 jq -r '
          .findings[]? | select((.autofixed // "false") == "true")
          | "- `\(.code)`: \(.message)"
        ' 2>/dev/null | head -40 || true
    echo
    echo "## Residual findings (not autofixed; sample)"
    echo
    residual_sample="$(
      find "${artifacts_dir}/harden-groups" -name '*.json' \
        ! -name '*.meta.json' ! -name '*.checkov.json' ! -name '*.tfsec.json' ! -name '*.trivy.json' -print0 2>/dev/null \
        | xargs -0 jq -r '
            .findings[]? | select((.autofixed // "false") != "true")
            | "- `\(.severity // "info")` `\(.code)`: \(.message)"
          ' 2>/dev/null | head -40 || true
    )"
    if [ -n "$residual_sample" ]; then
      printf '%s\n' "$residual_sample"
    else
      echo "- _(none in sample)_"
    fi
    echo
  } >"$findings_md"

  if [ "$cloud" = "azure" ] || [ "$cloud" = "gcp" ]; then
    write_destination_todo_md "$work_root" "$cloud" 2>/dev/null || true
  fi

  mirror_note "$work_root" "${cloud}_iac_harden_ok" "true"
  mirror_note "$work_root" "${cloud}_iac_harden_report" "$report"
  mirror_note "$work_root" "${cloud}_iac_harden_findings" "$findings_md"
  mirror_note "$work_root" "${cloud}_iac_harden_autofix_count" "$fixes"
  mirror_note "$work_root" "${cloud}_iac_harden_finding_count" "$findings"
  mirror_note "$work_root" "${cloud}_iac_harden_residual_count" "$residual"
  mirror_note "$work_root" "stage_summary:${cloud}-iac-harden" "ok"
  echo "${cloud}_iac_harden_ok: \"true\""
  echo "${cloud}_iac_harden_report=${report}"
  echo "${cloud}_iac_harden_findings=${findings_md}"
  echo "${cloud}_iac_harden_autofix_count=${fixes}"
  echo "${cloud}_iac_harden_finding_count=${findings}"
  echo "${cloud}_iac_harden_residual_count=${residual}"
  echo "stage_summary:${cloud}-iac-harden=ok"
}

cmd_azure_iac_harden() {
  cmd_destination_iac_harden "${1:?WORK_ROOT}" "azure"
}

cmd_gcp_iac_harden() {
  cmd_destination_iac_harden "${1:?WORK_ROOT}" "gcp"
}

# Living-governance harness: refresh docs, inventory, run agent-authored validator.
# Does not encode Nile Priority-1 rules — the validator is authored from this-run docs.
cmd_destination_iac_governance_conform() {
  local work_root="${1:?WORK_ROOT}"
  local cloud="${2:?CLOUD}" # azure|gcp
  require_embedded_invocation || return 1

  local groups_dir="${work_root}/${cloud}/groups"
  local artifacts_dir="${work_root}/${cloud}/artifacts"
  local harness="${work_root}/scripts/governance_conform.py"
  local opa_harness="${work_root}/scripts/governance_opa_check.py"
  local ok_key="${cloud}_iac_governance_ok"
  local stage_id="${cloud}-iac-governance-conform"

  if [ ! -d "$groups_dir" ]; then
    mirror_note "$work_root" "$ok_key" "false"
    mirror_note "$work_root" "stage_summary:${stage_id}" "blocked:generation_missing"
    echo "${ok_key}: \"false\""
    echo "stage_summary:${stage_id}=blocked:generation_missing"
    return 1
  fi

  mkdir -p "$artifacts_dir"
  local script_dir
  script_dir="$(dirname "${BASH_SOURCE[0]}")"
  if [ ! -f "$harness" ]; then
    if [ -f "${script_dir}/governance_conform.py" ]; then
      mkdir -p "${work_root}/scripts"
      cp "${script_dir}/governance_conform.py" "$harness"
    else
      mirror_note "$work_root" "$ok_key" "false"
      mirror_note "$work_root" "stage_summary:${stage_id}" "blocked:missing_governance_harness"
      echo "${ok_key}: \"false\""
      echo "stage_summary:${stage_id}=blocked:missing_governance_harness"
      return 1
    fi
  fi
  if [ ! -f "$opa_harness" ]; then
    if [ -f "${script_dir}/governance_opa_check.py" ]; then
      mkdir -p "${work_root}/scripts"
      cp "${script_dir}/governance_opa_check.py" "$opa_harness"
    else
      mirror_note "$work_root" "$ok_key" "false"
      mirror_note "$work_root" "stage_summary:${stage_id}" "blocked:governance_opa_unavailable"
      echo "${ok_key}: \"false\""
      echo "stage_summary:${stage_id}=blocked:governance_opa_unavailable"
      return 1
    fi
  fi
  local rc=0
  python3 "$harness" --work-root "$work_root" --cloud "$cloud" --all \
    >"${artifacts_dir}/governance-conform.out" 2>"${artifacts_dir}/governance-conform.err" || rc=$?

  local report="${artifacts_dir}/governance-conformance-report.json"
  local opa_rc=0 opa_ok="true" opa_blocked="" opa_report="${artifacts_dir}/governance-opa-report.json"
  if [ -f "$opa_harness" ]; then
    python3 "$opa_harness" --work-root "$work_root" --cloud "$cloud" \
      >"${artifacts_dir}/governance-opa-check.out" 2>"${artifacts_dir}/governance-opa-check.err" || opa_rc=$?
    if [ -f "$opa_report" ] && command -v jq >/dev/null 2>&1; then
      opa_ok="$(jq -r 'if .opa_ok == true then "true" else "false" end' "$opa_report" 2>/dev/null || echo false)"
      opa_blocked="$(jq -r '.blocked // empty' "$opa_report" 2>/dev/null || true)"
    fi
    # Never apply HCL fixes in Python. Rego emits remediation direction and
    # the migration agent decides, edits the correct source/HCL layer, and reruns.
    local opa_findings="${artifacts_dir}/governance-opa-findings.json"
    local current_findings_fingerprint="" previous_findings_fingerprint=""
    local findings_note_key="${cloud}_iac_opa_findings_sha256"
    if [ -f "$opa_findings" ]; then
      current_findings_fingerprint="$(sha256sum "$opa_findings" 2>/dev/null | awk '{print $1}')"
      previous_findings_fingerprint="$(read_note "$work_root" "$findings_note_key" 2>/dev/null || true)"
      mirror_note "$work_root" "$findings_note_key" "$current_findings_fingerprint"
      if [ "$opa_ok" != "true" ] && [ -n "$previous_findings_fingerprint" ] \
        && [ "$current_findings_fingerprint" = "$previous_findings_fingerprint" ]; then
        printf '{"schema":"nile-opa-no-progress/v1","cloud":"%s","findings_sha256":"%s","reason":"same_opa_findings_across_agent_visits"}\n' \
          "$cloud" "$current_findings_fingerprint" >"${artifacts_dir}/governance-opa-no-progress.json"
        opa_blocked="governance_no_progress"
        echo "governance_opa_status=nonconformant:no_progress_same_findings_across_visits"
      fi
    fi
    if [ "$opa_rc" -eq 2 ]; then
      mirror_note "$work_root" "$ok_key" "false"
      mirror_note "$work_root" "${cloud}_iac_governance_report" "$report"
      mirror_note "$work_root" "${cloud}_iac_opa_report" "$opa_report"
      mirror_note "$work_root" "${cloud}_iac_opa_findings" "${artifacts_dir}/governance-opa-findings.json"
      mirror_note "$work_root" "stage_summary:${stage_id}" "blocked:governance_opa_unavailable"
      echo "${ok_key}: \"false\""
      echo "stage_summary:${stage_id}=blocked:governance_opa_unavailable"
      return 1
    fi
  fi

  if [ "$opa_blocked" = "governance_no_progress" ]; then
    mirror_note "$work_root" "$ok_key" "false"
    mirror_note "$work_root" "${cloud}_iac_governance_report" "$report"
    mirror_note "$work_root" "${cloud}_iac_opa_report" "$opa_report"
    mirror_note "$work_root" "${cloud}_iac_opa_findings" "${artifacts_dir}/governance-opa-findings.json"
    mirror_note "$work_root" "stage_summary:${stage_id}" "blocked:governance_no_progress"
    echo "${ok_key}: \"false\""
    echo "stage_summary:${stage_id}=blocked:governance_no_progress"
    return 0
  fi

  local sha="" source_sha="" ok="false" blocked="" iteration="0" report_resources="0" inventory_resources="0"
  if [ -f "$report" ] && command -v jq >/dev/null 2>&1; then
    sha="$(jq -r '.governance_commit_sha // empty' "$report" 2>/dev/null || true)"
    ok="$(jq -r 'if .conformance_ok == true then "true" else "false" end' "$report" 2>/dev/null || echo false)"
    blocked="$(jq -r '.blocked // empty' "$report" 2>/dev/null || true)"
    iteration="$(jq -r '.iteration // 0' "$report" 2>/dev/null || echo 0)"
    report_resources="$(jq -r '.resource_count // 0' "$report" 2>/dev/null || echo 0)"
  fi
  local source_manifest="${artifacts_dir}/governance-source.json" resource_inventory="${artifacts_dir}/resource-inventory.json"
  if [ -f "$source_manifest" ] && command -v jq >/dev/null 2>&1; then
    source_sha="$(jq -r '.commit_sha // empty' "$source_manifest" 2>/dev/null || true)"
  fi
  if [ -f "$resource_inventory" ] && command -v jq >/dev/null 2>&1; then
    inventory_resources="$(jq -r '.resource_count // (.resources | length) // 0' "$resource_inventory" 2>/dev/null || echo 0)"
  fi
  if [ "$blocked" != "governance_docs_unavailable" ] && [ "$rc" -ne 2 ] \
    && { [ -z "$sha" ] || [ -z "$source_sha" ] || [ "$sha" != "$source_sha" ] \
      || ! [[ "$report_resources" =~ ^[0-9]+$ ]] || ! [[ "$inventory_resources" =~ ^[0-9]+$ ]] \
      || [ "$report_resources" -eq 0 ] || [ "$inventory_resources" -eq 0 ] \
      || [ "$report_resources" -lt "$inventory_resources" ]; }; then
    ok="false"
    blocked="governance_evidence_incomplete"
    printf '{"schema":"nile-governance-evidence-check/v1","cloud":"%s","report_sha":"%s","source_sha":"%s","report_resource_count":%s,"inventory_resource_count":%s,"blocked":"%s"}\n' \
      "$cloud" "$sha" "$source_sha" "$report_resources" "$inventory_resources" "$blocked" \
      >"${artifacts_dir}/governance-evidence-check.json"
    echo "governance_evidence_check=blocked:incomplete_or_mismatched_sha_or_resource_coverage"
  fi

  if [ "$cloud" = "azure" ] || [ "$cloud" = "gcp" ]; then
    write_destination_todo_md "$work_root" "$cloud" 2>/dev/null || true
  fi

  if [ "$blocked" = "governance_evidence_incomplete" ]; then
    mirror_note "$work_root" "$ok_key" "false"
    mirror_note "$work_root" "${cloud}_iac_governance_report" "$report"
    mirror_note "$work_root" "${cloud}_governance_commit_sha" "$sha"
    mirror_note "$work_root" "stage_summary:${stage_id}" "blocked:governance_evidence_incomplete"
    echo "${ok_key}: \"false\""
    echo "stage_summary:${stage_id}=blocked:governance_evidence_incomplete"
    return 0
  fi

  if [ "$blocked" = "governance_docs_unavailable" ] || [ "$rc" -eq 2 ]; then
    mirror_note "$work_root" "$ok_key" "false"
    mirror_note "$work_root" "${cloud}_iac_governance_report" "$report"
    mirror_note "$work_root" "${cloud}_governance_commit_sha" "$sha"
    mirror_note "$work_root" "stage_summary:${stage_id}" "blocked:governance_docs_unavailable"
    echo "${ok_key}: \"false\""
    echo "stage_summary:${stage_id}=blocked:governance_docs_unavailable"
    return 1
  fi

  if [ "$opa_ok" != "true" ]; then
    ok="false"
  fi

  mirror_note "$work_root" "$ok_key" "$ok"
  mirror_note "$work_root" "${cloud}_iac_governance_report" "$report"
  mirror_note "$work_root" "${cloud}_iac_governance_findings" "${artifacts_dir}/governance-findings.json"
  mirror_note "$work_root" "${cloud}_iac_opa_report" "$opa_report"
  mirror_note "$work_root" "${cloud}_iac_opa_findings" "${artifacts_dir}/governance-opa-findings.json"
  mirror_note "$work_root" "${cloud}_iac_opa_fix_hints" "${artifacts_dir}/governance-opa-fix-hints.md"
  mirror_note "$work_root" "${cloud}_governance_commit_sha" "$sha"
  mirror_note "$work_root" "${cloud}_iac_governance_iteration" "$iteration"
  if [ -n "$opa_blocked" ]; then
    mirror_note "$work_root" "${cloud}_iac_opa_blocked" "$opa_blocked"
  fi
  if [ "$ok" = "true" ]; then
    mirror_note "$work_root" "stage_summary:${stage_id}" "ok"
    echo "${ok_key}: \"true\""
    echo "stage_summary:${stage_id}=ok"
    echo "${cloud}_governance_commit_sha=${sha}"
    return 0
  fi

  mirror_note "$work_root" "stage_summary:${stage_id}" "nonconformant:governance_residual"
  echo "${ok_key}: \"false\""
  echo "stage_summary:${stage_id}=nonconformant:governance_residual"
  echo "${cloud}_governance_commit_sha=${sha}"
  return 0
}

cmd_azure_iac_governance_conform() {
  cmd_destination_iac_governance_conform "${1:?WORK_ROOT}" "azure"
}

cmd_gcp_iac_governance_conform() {
  cmd_destination_iac_governance_conform "${1:?WORK_ROOT}" "gcp"
}

# Soft gate: agents should remediate OPA/validator residuals in the governance
# loop first. If residuals remain after max iterations, still open the PR and
# document them in TODO.md + PR body (session d7f9f34c blocked with no PR).
require_destination_governance_ok() {
  local work_root="${1:?WORK_ROOT}"
  local cloud="${2:?CLOUD}"
  local ok
  ok="$(read_note "$work_root" "${cloud}_iac_governance_ok" 2>/dev/null || true)"
  if [ "$ok" = "true" ]; then
    mirror_note "$work_root" "governance_residual" "false"
    return 0
  fi
  mirror_note "$work_root" "governance_residual" "true"
  echo "governance_residual=true"
  echo "warning:governance_nonconformant_opening_pr_with_todos"
  return 0
}

# Emit Nile governance + OPA residual instructions (stdout). Used by TODO.md and
# destination PR bodies so operators always get fix steps even when ok=false.
emit_governance_residual_md() {
  local work_root="${1:?WORK_ROOT}"
  local cloud="${2:?CLOUD}"
  local gov_report="${work_root}/${cloud}/artifacts/governance-conformance-report.json"
  local opa_report="${work_root}/${cloud}/artifacts/governance-opa-report.json"
  local opa_findings="${work_root}/${cloud}/artifacts/governance-opa-findings.json"
  local opa_hints="${work_root}/${cloud}/artifacts/governance-opa-fix-hints.md"
  local exceptions="${work_root}/${cloud}/artifacts/governance-exceptions.md"
  local assumptions="${work_root}/${cloud}/artifacts/governance-assumptions.md"
  local opa_guidance="${work_root}/${cloud}/artifacts/governance-opa-guidance.json"
  local gov_ok opa_ok deny_count blocking_count

  gov_ok="$(read_note "$work_root" "${cloud}_iac_governance_ok" 2>/dev/null || true)"
  gov_ok="${gov_ok:-unknown}"
  opa_ok="$(jq -r '.opa_ok // "unknown"' "$opa_report" 2>/dev/null || echo unknown)"
  if [ "$opa_ok" = "unknown" ] && [ -f "$opa_findings" ]; then
    deny_count="$(jq -r '.deny_count // 0' "$opa_findings" 2>/dev/null || echo 0)"
    if [ "$deny_count" = "0" ]; then
      opa_ok="true"
    else
      opa_ok="false"
    fi
  else
    deny_count="$(jq -r '.deny_count // 0' "${opa_findings:-$opa_report}" 2>/dev/null || echo 0)"
  fi
  blocking_count="$(jq -r '.blocking_count // 0' "$gov_report" 2>/dev/null || echo 0)"

  echo "## Nile governance / OPA residuals"
  echo
  echo "| Item | Value |"
  echo "| --- | --- |"
  echo "| \`${cloud}_iac_governance_ok\` | \`${gov_ok}\` |"
  echo "| opa_ok | \`${opa_ok}\` |"
  echo "| OPA deny_count | \`${deny_count}\` |"
  echo "| Validator blocking_count | \`${blocking_count}\` |"
  if [ -f "$gov_report" ]; then
    echo "| Governance SHA | \`$(jq -r '.governance_commit_sha // empty' "$gov_report" 2>/dev/null || echo unknown)\` |"
  fi
  echo
  if [ "$gov_ok" = "true" ]; then
    echo "Governance gate cleared for this run. Spot-check artifacts below before apply."
    echo
  else
    echo "> **Residual governance/OPA findings remain.** The migration agent must reason from the Rego-authored direction and remediate before this PR is considered complete. Treat the items below as merge blockers until cleared or explicitly accepted."
    echo
    echo "### TODO — clear residuals"
    echo
    echo "1. Read [\`governance-opa-guidance.json\`](./governance-opa-guidance.json) and [\`governance-opa-fix-hints.md\`](./governance-opa-fix-hints.md); trace source evidence → provider schema → plan path → Rego direction, then make the appropriate HCL/generator/policy change and verify it."
    echo "2. Record any migration placeholders in [\`governance-assumptions.md\`](./governance-assumptions.md)."
    echo "3. Clear validator blockers in [\`governance-exceptions.md\`](./governance-exceptions.md)."
    echo "4. Re-run \`${cloud}-iac-governance-conform\` until \`${cloud}_iac_governance_ok=true\`."
    echo "5. Do **not** apply cloud resources while \`opa_ok\` / \`conformance_ok\` are false unless an owner accepts each residual."
    echo
  fi
  if [ -f "$assumptions" ]; then
    echo "### Migration assumptions"
    echo
    sed -n '1,60p' "$assumptions"
    echo
    echo "- Full list: [\`governance-assumptions.md\`](./governance-assumptions.md)"
    echo
  fi
  if [ -f "$opa_guidance" ]; then
    echo "- Rego-authored guidance: [\`governance-opa-guidance.json\`](./governance-opa-guidance.json)"
    echo
  fi
  if [ -f "$opa_findings" ] && command -v jq >/dev/null 2>&1; then
    echo "### Top OPA denies (sample)"
    echo
    echo '```'
    jq -r '
      (.findings // [])
      | .[0:25][]
      | if type == "string" then .
        elif .msg then .msg
        elif .message then .message
        elif .reason then .reason
        else tostring end
    ' "$opa_findings" 2>/dev/null | head -40 || true
    echo '```'
    echo
    echo "- Full rollup: [\`governance-opa-findings.json\`](./governance-opa-findings.json)"
    echo
  fi
  if [ -f "$opa_hints" ]; then
    echo "### OPA fix hints (excerpt)"
    echo
    sed -n '1,80p' "$opa_hints"
    echo
    echo "- Full hints: [\`governance-opa-fix-hints.md\`](./governance-opa-fix-hints.md)"
    echo
  fi
  if [ -f "$exceptions" ]; then
    echo "- Validator exceptions: [\`governance-exceptions.md\`](./governance-exceptions.md)"
    echo
  fi
  if [ -f "$gov_report" ]; then
    echo "- Conformance report: [\`governance-conformance-report.json\`](./governance-conformance-report.json)"
    echo
  fi
}

cmd_destination_iac_validate() {
  local work_root="${1:?WORK_ROOT}"
  local cloud="${2:?CLOUD}" # azure|gcp
  require_embedded_invocation || return 1

  if [ "$cloud" != "azure" ] && [ "$cloud" != "gcp" ]; then
    echo "destination_validate_error=unsupported_cloud cloud=${cloud}" >&2
    return 1
  fi

  # Materialize ADC for the google provider when vault only supplies JSON.
  if [ "$cloud" = "gcp" ]; then
    if [ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON:-}" ] && [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
      mkdir -p "${work_root}/.work"
      printf '%s' "$GOOGLE_APPLICATION_CREDENTIALS_JSON" >"${work_root}/.work/gcp-sa.json"
      export GOOGLE_APPLICATION_CREDENTIALS="${work_root}/.work/gcp-sa.json"
    fi
    if [ -n "${GCP_PROJECT_ID:-}" ]; then
      export GOOGLE_CLOUD_PROJECT="$GCP_PROJECT_ID"
      export CLOUDSDK_CORE_PROJECT="$GCP_PROJECT_ID"
    fi
  fi

  if [ ! -d "${work_root}/${cloud}/groups" ]; then
    if [ "$cloud" = "azure" ]; then
      cmd_azure_iac_generate "$work_root"
    else
      cmd_gcp_iac_generate "$work_root"
    fi
  fi

  local tofu_bin
  if ! tofu_bin="$(resolve_tofu_bin)"; then
    mirror_note "$work_root" "blocked:remote_runner_tofu_missing" "true"
    mirror_note "$work_root" "${cloud}_iac_validation_ok" "false"
    echo 'blocked:remote_runner_tofu_missing: "true"'
    echo "${cloud}_iac_validation_ok: \"false\""
    return 1
  fi

  local groups_dir="${work_root}/${cloud}/groups"
  local artifacts_dir="${work_root}/${cloud}/artifacts"
  local report="${artifacts_dir}/validation-report.json"
  local groups_out="${artifacts_dir}/validate-groups"
  local parallel="${DEST_VALIDATE_PARALLELISM:-4}"
  local run_tflint="${DEST_VALIDATE_RUN_TFLINT:-0}"
  local plan_tfplan="${cloud}.tfplan"
  local resume_skipped=0

  mkdir -p "$artifacts_dir" "$groups_out"
  echo "dest_validate_parallelism=${parallel}"

  local plan_mode plan_status_overall require_live_plan
  if [ "$cloud" = "azure" ]; then
    require_live_plan="${REQUIRE_AZURE_LIVE_PLAN:-0}"
    if azure_credentials_configured; then
      plan_mode="enabled"
      plan_status_overall="success"
    else
      plan_mode="skipped"
      plan_status_overall="skipped:missing_credentials"
      if [ "$require_live_plan" = "1" ] || [ "$require_live_plan" = "true" ]; then
        mirror_note "$work_root" "azure_iac_validation_ok" "false"
        mirror_note "$work_root" "azure_plan_status" "skipped:missing_credentials"
        mirror_note "$work_root" "stage_summary:azure-iac-validate" "blocked:missing_azure_credentials"
        echo 'azure_plan_status=skipped:missing_credentials'
        echo 'azure_iac_validation_ok: "false"'
        echo 'stage_summary:azure-iac-validate=blocked:missing_azure_credentials'
        echo 'blocked:missing_azure_credentials: "true"'
        return 1
      fi
    fi
  else
    require_live_plan="${REQUIRE_GCP_LIVE_PLAN:-0}"
    if gcp_credentials_configured; then
      plan_mode="enabled"
      plan_status_overall="success"
    else
      plan_mode="skipped"
      plan_status_overall="skipped:missing_credentials"
      if [ "$require_live_plan" = "1" ] || [ "$require_live_plan" = "true" ]; then
        mirror_note "$work_root" "gcp_iac_validation_ok" "false"
        mirror_note "$work_root" "gcp_plan_status" "skipped:missing_credentials"
        mirror_note "$work_root" "stage_summary:gcp-iac-validate" "blocked:missing_gcp_credentials"
        echo 'gcp_plan_status=skipped:missing_credentials'
        echo 'gcp_iac_validation_ok: "false"'
        echo 'stage_summary:gcp-iac-validate=blocked:missing_gcp_credentials'
        echo 'blocked:missing_gcp_credentials: "true"'
        return 1
      fi
    fi
  fi

  # Hundreds of groups each init the same provider. Without a shared cache every
  # group downloads and stores its own copy, which is both slow and large enough
  # to exhaust the runner's disk.
  local runtime_base
  if runtime_base="$(terraform_runtime_base "$work_root")"; then
    export TF_PLUGIN_CACHE_DIR="${runtime_base}/plugin-cache"
    mkdir -p "$TF_PLUGIN_CACHE_DIR"
  fi

  local live_plan_limit validate_group_limit live_plan_all_flag
  if [ "$cloud" = "azure" ]; then
    live_plan_limit="${AZURE_LIVE_PLAN_MAX_GROUPS:-0}"
    validate_group_limit="${AZURE_VALIDATE_MAX_GROUPS:-0}"
    live_plan_all_flag="${AZURE_LIVE_PLAN_ALL:-0}"
  else
    live_plan_limit="${GCP_LIVE_PLAN_MAX_GROUPS:-0}"
    validate_group_limit="${GCP_VALIDATE_MAX_GROUPS:-0}"
    live_plan_all_flag="${GCP_LIVE_PLAN_ALL:-0}"
  fi
  # Default: when live plan is required, cap plans so Guild tool timeouts stay realistic.
  # Static fmt/validate still covers every group unless *_VALIDATE_MAX_GROUPS is set.
  # Set *_LIVE_PLAN_ALL=1 (or a huge limit) to plan every group.
  if [ "$plan_mode" = "enabled" ] && [ "$live_plan_all_flag" != "1" ] && [ "$live_plan_all_flag" != "true" ]; then
    if [ "$cloud" = "azure" ] && [ -z "${AZURE_LIVE_PLAN_MAX_GROUPS:-}" ]; then
      live_plan_limit=8
    elif [ "$cloud" = "gcp" ] && [ -z "${GCP_LIVE_PLAN_MAX_GROUPS:-}" ]; then
      live_plan_limit=8
    fi
  fi
  # Static fmt/validate covers every group by default. Only live plan is sampled
  # so Guild tool windows stay realistic.

  local live_plan_ids_file=""
  if [ "$plan_mode" = "enabled" ] && [ "$live_plan_limit" != "0" ]; then
    live_plan_ids_file="$(mktemp "${artifacts_dir}/live-plan-ids.XXXXXX")"
    select_diversified_live_plan_group_ids "$work_root" "$cloud" "$live_plan_limit" >"$live_plan_ids_file"
    echo "${cloud}_iac_validate_live_plan_sample=$(tr '
' ',' <"$live_plan_ids_file" | sed 's/,$//')"
  fi

  local group_list
  group_list="$(mktemp "${artifacts_dir}/validate-group-list.XXXXXX")"
  find "$groups_dir" -mindepth 1 -maxdepth 1 -type d | sort >"$group_list"
  if [ "$validate_group_limit" != "0" ]; then
    local truncated
    truncated="$(mktemp "${artifacts_dir}/validate-group-list-trunc.XXXXXX")"
    head -n "$validate_group_limit" "$group_list" >"$truncated"
    mv "$truncated" "$group_list"
    echo "${cloud}_iac_validate_progress truncated_at=$(wc -l <"$group_list" | tr -d ' ') validate_group_limit=${validate_group_limit}"
  fi

  # Bounded parallel workers (same pattern as destination harden). Resume skips
  # groups that already have a complete validate-groups/<id>.json from a prior
  # attempt killed by Guild context deadline.
  local running=0 group_dir group_id out_json
  while IFS= read -r group_dir; do
    [ -n "$group_dir" ] || continue
    group_id="$(basename "$group_dir")"
    out_json="${groups_out}/${group_id}.json"
    if destination_validate_group_result_complete "$out_json"; then
      resume_skipped=$((resume_skipped + 1))
      continue
    fi
    (
      # Do not let one group failure abort the stage (parent has set -e).
      set +e
      fmt_status="false"
      validate_status="false"
      test_status="skipped:no_tests"
      if [ "$run_tflint" = "1" ] || [ "$run_tflint" = "true" ]; then
        lint_status="skipped:tflint_missing"
      else
        lint_status="skipped:deferred_to_harden"
      fi
      if [ "$plan_mode" = "enabled" ]; then
        plan_status="skipped:not_planned"
      else
        plan_status="skipped:missing_credentials"
      fi
      plan_counts='{"create":0,"update":0,"delete":0,"replace":0}'
      validation_ok="true"
      did_plan="false"
      validate_error=""

      cd "$group_dir" || exit 0
      # Empty review stubs are expected; skip without failing the stage.
      if ! assert_destination_group_resources "$work_root" "$group_dir" >"resources.out" 2>&1; then
        validate_status="skipped:empty_scaffold"
        fmt_status="skipped:empty_scaffold"
        plan_status="skipped:empty_scaffold"
        validation_ok="true"
      elif ! tofu_init_with_plugin_cache_lock "$tofu_bin" "init.out"; then
        validate_status="init_failed"
        validation_ok="false"
        validate_error="$(validation_error_snippet init.out)"
        plan_status="skipped:static_validation_failed"
      else
        # Heal known provider limits + stub missing tfvars before validate.
        if sanity_py="$(resolve_hcl_sanity_py "$work_root" 2>/dev/null)"; then
          python3 "$sanity_py" fix-provider-limits "$group_dir" >"provider-limits.out" 2>&1 || true
          python3 "$sanity_py" write-stub-tfvars "$group_dir" >"stub-tfvars.out" 2>&1 || true
        fi
        "$tofu_bin" fmt -recursive -no-color >/dev/null 2>&1 || true
        if "$tofu_bin" fmt -recursive -check -no-color >"fmt.out" 2>&1; then
          fmt_status="true"
        else
          validation_ok="false"
          validate_error="$(validation_error_snippet fmt.out)"
        fi
        if tofu_validate_with_retry "$tofu_bin" "validate.out"; then
          validate_status="true"
        else
          # Pack autofix: provider limits + surgical attr drops/adds on this group's *.tf, then re-validate.
          if sanity_py="$(resolve_hcl_sanity_py "$work_root" 2>/dev/null)"; then
            python3 "$sanity_py" fix-provider-limits "$group_dir" >>"provider-limits.out" 2>&1 || true
            python3 "$sanity_py" write-stub-tfvars "$group_dir" >>"stub-tfvars.out" 2>&1 || true
            python3 "$sanity_py" parse-tofu-errors "validate.out" \
              --group-id "$group_id" --out "hcl_fix_targets.json" \
              >"hcl_fix_targets.raw.json" 2>/dev/null || true
            if [ -f "hcl_fix_targets.json" ]; then
              python3 "$sanity_py" apply-surgical-fixes "$group_dir" "hcl_fix_targets.json" \
                >>"surgical-fixes.out" 2>&1 || true
            fi
          fi
          "$tofu_bin" fmt -recursive -no-color >/dev/null 2>&1 || true
          if tofu_validate_with_retry "$tofu_bin" "validate-retry.out"; then
            validate_status="true"
            validation_ok="true"
            echo "group_validate_recovered=${group_id}"
          else
            validation_ok="false"
            validate_error="$(validation_error_snippet validate-retry.out)"
          fi
        fi
        has_tests="$(find . -type f \( -name '*.tftest.hcl' -o -name '*.tftest.json' \) -print -quit 2>/dev/null || true)"
        if [ -n "$has_tests" ]; then
          if "$tofu_bin" test -no-color >"test.out" 2>&1; then
            test_status="true"
          else
            test_status="false"
            validation_ok="false"
          fi
        fi
        if [ "$run_tflint" = "1" ] || [ "$run_tflint" = "true" ]; then
          if command -v tflint >/dev/null 2>&1; then
            if tflint --init >/dev/null 2>&1; then
              if tflint --format compact >"tflint.out" 2>&1; then
                lint_status="true"
              else
                lint_status="false"
                validation_ok="false"
              fi
            else
              lint_status="skipped:tflint_init_failed"
            fi
          fi
        fi
        should_plan_inner="false"
        if [ "$validation_ok" = "true" ] && [ "$plan_mode" = "enabled" ]; then
          if [ "$live_plan_limit" = "0" ]; then
            should_plan_inner="true"
          elif [ -n "$live_plan_ids_file" ] && grep -qxF -- "$group_id" "$live_plan_ids_file"; then
            should_plan_inner="true"
          else
            plan_status="skipped:live_plan_sample_limit"
          fi
        elif [ "$validation_ok" != "true" ] && [ "$plan_mode" = "enabled" ]; then
          plan_status="skipped:static_validation_failed"
        fi
        if [ "$should_plan_inner" = "true" ]; then
          did_plan="true"
          if "$tofu_bin" plan -refresh=false -input=false -lock=false -no-color -out="$plan_tfplan" >"plan.out" 2>&1; then
            plan_counts="$(plan_change_counts_detailed_json "$tofu_bin" "$plan_tfplan" 2>/dev/null || echo '{"create":0,"update":0,"delete":0,"replace":0}')"
            creates="$(printf '%s' "$plan_counts" | jq -r '.create // 0')"
            deletes="$(printf '%s' "$plan_counts" | jq -r '.delete // 0')"
            replaces="$(printf '%s' "$plan_counts" | jq -r '.replace // 0')"
            if [ "$deletes" -eq 0 ] && [ "$replaces" -eq 0 ] && [ "$creates" -gt 0 ]; then
              plan_status="success:expected_creates"
            elif [ "$deletes" -gt 0 ] || [ "$replaces" -gt 0 ]; then
              plan_status="failed:unexpected_delete_or_replace"
            else
              plan_status="failed:no_expected_creates"
            fi
          else
            plan_status="failed:plan_error"
          fi
        fi
      fi

      jq -n \
        --arg gid "$group_id" \
        --arg fmt "$fmt_status" \
        --arg validate "$validate_status" \
        --arg test "$test_status" \
        --arg lint "$lint_status" \
        --arg plan "$plan_status" \
        --arg verr "$validate_error" \
        --arg vok "$validation_ok" \
        --arg dplan "$did_plan" \
        --argjson counts "$plan_counts" \
        '{
          group_id: $gid,
          fmt: $fmt,
          validate: $validate,
          test: $test,
          lint: $lint,
          plan_status: $plan,
          plan_counts: $counts,
          validate_error: $verr,
          validation_ok: $vok,
          did_plan: $dplan
        }' >"${out_json}.tmp" && mv "${out_json}.tmp" "$out_json"

      # Release the initialized provider tree now that this group is reported.
      rm -rf "${group_dir}/.terraform" "${group_dir}/${plan_tfplan}" 2>/dev/null || true

      done_n=0
      planned_n=0
      static_fail_n=0
      plan_fail_n=0
      if ls "${groups_out}"/*.json >/dev/null 2>&1; then
        done_n="$(find "$groups_out" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
        planned_n="$(jq -s '[.[] | select(.did_plan == "true")] | length' "${groups_out}"/*.json 2>/dev/null || echo 0)"
        static_fail_n="$(jq -s '[.[] | select(.validation_ok != "true")] | length' "${groups_out}"/*.json 2>/dev/null || echo 0)"
        plan_fail_n="$(jq -s '[.[] | select((.plan_status // "") | startswith("failed:"))] | length' "${groups_out}"/*.json 2>/dev/null || echo 0)"
      fi
      # Heartbeat so long runs do not look idle to Guild/runner watchdogs.
      if [ $((done_n % 10)) -eq 0 ] || [ "$did_plan" = "true" ]; then
        echo "${cloud}_iac_validate_progress group=${group_id} done=${done_n} planned=${planned_n} static_fail=${static_fail_n} plan_fail=${plan_fail_n} plan_status=${plan_status}"
      fi
      exit 0
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$parallel" ]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done <"$group_list"
  wait
  rm -f "$group_list"
  rm -f "$live_plan_ids_file" 2>/dev/null || true
  echo "validate_resume_skipped=${resume_skipped}"

  local total=0 static_fail=0 plan_fail=0 planned=0
  local tmp_report
  tmp_report="$(mktemp_destination_validation_report "$work_root")"
  if ls "${groups_out}"/*.json >/dev/null 2>&1; then
    jq -s '{
      groups: [
        .[] | {
          group_id: .group_id,
          fmt: .fmt,
          validate: .validate,
          test: .test,
          lint: .lint,
          plan_status: .plan_status,
          plan_counts: .plan_counts,
          validate_error: (.validate_error // "")
        }
      ] | sort_by(.group_id)
    }' "${groups_out}"/*.json >"$tmp_report"
    total="$(jq -s 'length' "${groups_out}"/*.json 2>/dev/null || echo 0)"
    static_fail="$(jq -s '[.[] | select(.validation_ok != "true")] | length' "${groups_out}"/*.json 2>/dev/null || echo 0)"
    planned="$(jq -s '[.[] | select(.did_plan == "true")] | length' "${groups_out}"/*.json 2>/dev/null || echo 0)"
    plan_fail="$(jq -s '[.[] | select((.plan_status // "") | startswith("failed:"))] | length' "${groups_out}"/*.json 2>/dev/null || echo 0)"
  else
    printf '{"groups":[]}
' >"$tmp_report"
  fi

  local overall_ok="false" cloud_plan_status
  cloud_plan_status="$plan_status_overall"
  if [ "$plan_mode" = "enabled" ]; then
    if [ "$planned" -eq 0 ]; then
      cloud_plan_status="failed:no_groups_planned"
      plan_fail=$((plan_fail + 1))
    elif [ "$plan_fail" -eq 0 ]; then
      if [ "$live_plan_limit" != "0" ] && [ "$planned" -lt "$total" ]; then
        cloud_plan_status="success:sample:${planned}/${total}"
      else
        cloud_plan_status="success"
      fi
    else
      cloud_plan_status="failed"
    fi
  fi
  if [ "$total" -gt 0 ] && [ "$static_fail" -eq 0 ] && [ "$plan_fail" -eq 0 ]; then
    overall_ok="true"
  fi

  local plan_key="${cloud}_plan_status"
  jq --arg ok "$overall_ok" \
    --arg plan "$cloud_plan_status" \
    --arg plan_key "$plan_key" \
    --argjson total "$total" \
    --argjson static_fail "$static_fail" \
    --argjson plan_fail "$plan_fail" \
    '. + {
      validation_ok: ($ok == "true"),
      group_count: $total,
      static_fail_count: $static_fail,
      plan_fail_count: $plan_fail
    } + {($plan_key): $plan}' "$tmp_report" >"$report"
  rm -f "$tmp_report"

  mirror_note "$work_root" "${cloud}_iac_validation_report" "$report"
  mirror_note "$work_root" "${cloud}_iac_validation_ok" "$overall_ok"
  mirror_note "$work_root" "${cloud}_plan_status" "$cloud_plan_status"
  mirror_note "$work_root" "${cloud}_plan_groups_planned" "$planned"
  mirror_note "$work_root" "${cloud}_plan_sample_limit" "$live_plan_limit"
  local create_total update_total delete_total replace_total
  create_total="$(jq '[.groups[]?.plan_counts.create // 0] | add // 0' "$report" 2>/dev/null || echo 0)"
  update_total="$(jq '[.groups[]?.plan_counts.update // 0] | add // 0' "$report" 2>/dev/null || echo 0)"
  delete_total="$(jq '[.groups[]?.plan_counts.delete // 0] | add // 0' "$report" 2>/dev/null || echo 0)"
  replace_total="$(jq '[.groups[]?.plan_counts.replace // 0] | add // 0' "$report" 2>/dev/null || echo 0)"
  mirror_note "$work_root" "${cloud}_plan_create_count" "$create_total"
  mirror_note "$work_root" "${cloud}_plan_update_count" "$update_total"
  mirror_note "$work_root" "${cloud}_plan_delete_count" "$delete_total"
  mirror_note "$work_root" "${cloud}_plan_replace_count" "$replace_total"
  if [ "$overall_ok" = "true" ]; then
    mirror_note "$work_root" "stage_summary:${cloud}-iac-validate" "ok"
    echo "stage_summary:${cloud}-iac-validate=ok"
  else
    mirror_note "$work_root" "stage_summary:${cloud}-iac-validate" "blocked:validation_failed"
    echo "stage_summary:${cloud}-iac-validate=blocked:validation_failed"
  fi
  echo "${cloud}_iac_validation_report=${report}"
  echo "${cloud}_plan_status=${cloud_plan_status}"
  echo "${cloud}_plan_groups_planned=${planned}"
  echo "${cloud}_plan_create_count=${create_total}"
  echo "${cloud}_plan_update_count=${update_total}"
  echo "${cloud}_plan_delete_count=${delete_total}"
  echo "${cloud}_plan_replace_count=${replace_total}"
  echo "${cloud}_iac_validation_ok: \"${overall_ok}\""
}

cmd_azure_iac_validate() {
  cmd_destination_iac_validate "$1" azure
}

build_azure_pr_title() {
  local workflow_run_id="${1:?WORKFLOW_RUN_ID}"
  printf 'chore(terraform): add Azure migration IaC for %s' "$workflow_run_id"
}

write_azure_pr_body() {
  local work_root="${1:?WORK_ROOT}"
  local workflow_run_id="${2:?WORKFLOW_RUN_ID}"
  local repo_full="${3:?REPO}"
  local default_branch="${4:-main}"
  local out_file="${5:?OUT}"

  local group_count validation_ok plan_status review_count blueprint_path validation_report
  group_count="$(read_note "$work_root" "azure_iac_group_count" 2>/dev/null || echo unknown)"
  validation_ok="$(read_note "$work_root" "azure_iac_validation_ok" 2>/dev/null || echo unknown)"
  plan_status="$(read_note "$work_root" "azure_plan_status" 2>/dev/null || echo unknown)"
  blueprint_path="$(read_note "$work_root" "azure_migration_blueprint_path" 2>/dev/null || echo "${work_root}/azure/artifacts/migration-blueprint.json")"
  validation_report="$(read_note "$work_root" "azure_iac_validation_report" 2>/dev/null || echo "${work_root}/azure/artifacts/validation-report.json")"
  local planned_groups sample_limit static_groups
  planned_groups="$(read_note "$work_root" "azure_plan_groups_planned" 2>/dev/null || echo unknown)"
  sample_limit="$(read_note "$work_root" "azure_plan_sample_limit" 2>/dev/null || echo unknown)"
  static_groups="$(jq -r '.group_count // "unknown"' "$validation_report" 2>/dev/null || echo unknown)"
  review_count="unknown"
  if [ -f "$blueprint_path" ]; then
    review_count="$(jq -r '.review_needed_count // "unknown"' "$blueprint_path" 2>/dev/null || echo unknown)"
  fi

  local gen_summary conv_rate conv_ok eligible converted identity_count
  local app_iam_rate app_iam_ok app_iam_eligible app_iam_converted
  gen_summary="${work_root}/azure/artifacts/generation-summary.json"
  conv_rate="$(read_note "$work_root" "azure_infra_conversion_rate" 2>/dev/null || true)"
  conv_ok="$(read_note "$work_root" "azure_infra_conversion_ok" 2>/dev/null || true)"
  eligible="$(read_note "$work_root" "azure_infra_eligible_count" 2>/dev/null || true)"
  converted="$(read_note "$work_root" "azure_infra_converted_count" 2>/dev/null || true)"
  identity_count="$(read_note "$work_root" "azure_identity_scaffold_count" 2>/dev/null || true)"
  app_iam_rate="$(read_note "$work_root" "azure_app_iam_conversion_rate" 2>/dev/null || true)"
  app_iam_ok="$(read_note "$work_root" "azure_app_iam_conversion_ok" 2>/dev/null || true)"
  app_iam_eligible="$(read_note "$work_root" "azure_app_iam_eligible_count" 2>/dev/null || true)"
  app_iam_converted="$(read_note "$work_root" "azure_app_iam_converted_count" 2>/dev/null || true)"
  if [ -f "$gen_summary" ]; then
    conv_rate="$(jq -r '.infra_conversion_rate // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    conv_ok="$(jq -r '.infra_conversion_ok // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    eligible="$(jq -r '.infra_eligible_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    converted="$(jq -r '.infra_converted_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    identity_count="$(jq -r '.identity_scaffold_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    app_iam_rate="$(jq -r '.app_iam_conversion_rate // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    app_iam_ok="$(jq -r '.app_iam_conversion_ok // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    app_iam_eligible="$(jq -r '.app_iam_eligible_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    app_iam_converted="$(jq -r '.app_iam_converted_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
  fi
  conv_rate="${conv_rate:-unknown}"
  conv_ok="${conv_ok:-unknown}"
  eligible="${eligible:-unknown}"
  converted="${converted:-unknown}"
  identity_count="${identity_count:-unknown}"
  app_iam_rate="${app_iam_rate:-unknown}"
  app_iam_ok="${app_iam_ok:-unknown}"
  app_iam_eligible="${app_iam_eligible:-unknown}"
  app_iam_converted="${app_iam_converted:-unknown}"

  local review_excerpt unsupported_excerpt harden_excerpt harden_report harden_autofix harden_findings harden_fmt harden_lint
  review_excerpt=""
  if [ -f "${work_root}/azure/artifacts/review-needed.md" ]; then
    review_excerpt="$(sed -n '1,120p' "${work_root}/azure/artifacts/review-needed.md")"
  fi
  unsupported_excerpt=""
  if [ -f "$blueprint_path" ]; then
    unsupported_excerpt="$(jq -r '[.groups[]?.mapping_decisions[]? | select(.status=="unsupported" or .emission=="resource_group_only" or .category=="placeholder") | .source_type] | unique | .[]' "$blueprint_path" 2>/dev/null | head -40 | while read -r st; do echo "- \`$st\`: catalog unsupported/placeholder — see review-needed.md"; done || true)"
  fi
  harden_report="${work_root}/azure/artifacts/harden-report.json"
  harden_autofix="unknown"
  harden_findings="unknown"
  harden_fmt="unknown"
  harden_lint="unknown"
  if [ -f "$harden_report" ]; then
    harden_autofix="$(jq -r '.autofix_count // 0' "$harden_report" 2>/dev/null || echo 0)"
    harden_findings="$(jq -r '.residual_count // .finding_count // 0' "$harden_report" 2>/dev/null || echo 0)"
    harden_fmt="$(jq -r '.fmt_fail_count // 0' "$harden_report" 2>/dev/null || echo 0)"
    harden_lint="$(jq -r '.lint_fail_count // 0' "$harden_report" 2>/dev/null || echo 0)"
  fi
  harden_excerpt=""
  if [ -f "${work_root}/azure/artifacts/harden-findings.md" ]; then
    harden_excerpt="$(sed -n '1,80p' "${work_root}/azure/artifacts/harden-findings.md")"
  fi

  mkdir -p "$(dirname "$out_file")"
  {
    echo "## Summary"
    echo
    echo "Adds **review-candidate** Azure Terraform under \`azure/\` (CAF naming, WAF security defaults, honest emission labels) for AWS reverse-IaC groups."
    echo "Ambiguous mappings do not block the PR; operators must treat non-\`full_scaffold\` emissions as incomplete. Details: \`azure/artifacts/review-needed.md\`."
    echo
    echo "## Run status"
    echo
    echo "| Item | Value |"
    echo "| --- | --- |"
    echo "| Repository | \`${repo_full}\` |"
    echo "| Base branch | \`${default_branch}\` |"
    echo "| workflow_run_id | \`${workflow_run_id}\` |"
    echo "| Generated Azure groups | \`${group_count}\` |"
    echo "| Static validated groups | \`${static_groups}\` |"
    echo "| Live plan sample | \`${planned_groups}\` of \`${static_groups}\` (limit \`${sample_limit}\`) |"
    echo "| Azure validation | \`${validation_ok}\` |"
    echo "| Azure plan status | \`${plan_status}\` |"
    echo "| Harden autofixes | \`${harden_autofix}\` |"
    echo "| Harden residual findings | \`${harden_findings}\` |"
    echo "| Harden fmt / tflint fails | \`${harden_fmt}\` / \`${harden_lint}\` |"
    echo "| Review-needed groups | \`${review_count}\` |"
    echo "| Infra conversion rate | \`${conv_rate}\` (eligible \`${eligible}\`, converted \`${converted}\`, ok=\`${conv_ok}\`, target ≥ 0.80) |"
    echo "| App IAM conversion rate | \`${app_iam_rate}\` (eligible \`${app_iam_eligible}\`, converted \`${app_iam_converted}\`, ok=\`${app_iam_ok}\`, target ≥ 0.80) |"
    echo "| Identity / app-IAM instances | \`${identity_count}\` (excluded from infra conversion; tracked in app IAM rate) |"
    echo
    echo "## Operator contract"
    echo
    echo "- This PR is **review-candidate** IaC (CAF naming + WAF security defaults). It is **not** apply-ready landing-zone/AVM."
    echo "- Catalog \`status=mapped\` means a target type exists; check \`emission\` (\`managed_identity_rbac_scaffold\` = UAI + custom role + assignment, not full action translation)."
    echo "- **Infra conversion** counts non-identity mapped AWS instances that received a matching \`azurerm_*\` scaffold (target ≥ 80%)."
    echo "- **App IAM conversion** (acquisition path) counts workload \`aws_iam_role\` / policy / inline policy instances that received UAI + \`azurerm_role_definition\` scaffolds. AWS actions are preserved as comments for specialist translation. Attachments stay \`non_applicable\` glue."
    echo "- Static validation should cover all generated groups; live plan may be a **sample** — trust the sample columns above, not a bare \`success\` alone."
    echo
    echo "## Validation contract"
    echo
    echo "- Static validation runs \`tofu fmt\`, \`tofu validate\`, optional \`tofu test\`, and optional \`tflint\` on validated groups."
    echo "- Parallel \`azure-iac-harden\` applies mechanical security/lint autofixes into the same PR; see \`azure/artifacts/harden-findings.md\`."
    echo "- \`azure-iac-governance-conform\` refreshes living Nile docs, derives a per-resource tree, and re-verifies Priority-1 + OPA. Agents must follow Rego-authored directions in \`governance-opa-guidance.json\`, reason about source values/provider schema, edit the appropriate layer, and re-run verification. If residuals remain after max iterations, this PR still opens with TODOs — clear them before apply. Pin SHA from \`azure/artifacts/governance-source.json\`. Validation evidence is not human approval."
    echo "- Live Azure plan runs only when Azure credentials are present on the runner (sampled when \`AZURE_LIVE_PLAN_MAX_GROUPS\` is set)."
    echo "- Live plan status is recorded as \`azure_plan_status\`. When credentials are required, missing ARM_* fails validate; this PR never applies Azure resources."
    echo "- When a live plan runs, sampled success requires expected creates and no deletes or replacements."
    echo
    emit_governance_residual_md "$work_root" "azure"
    if [ -f "${work_root}/azure/artifacts/governance-assumptions.md" ]; then
      echo "## Migration assumptions"
      echo
      sed -n '1,80p' "${work_root}/azure/artifacts/governance-assumptions.md"
      echo
    fi
    echo "## Lint / security harden"
    echo
    if [ -n "$harden_excerpt" ]; then
      printf '%s\n' "$harden_excerpt"
    else
      echo "No harden report yet — \`azure-iac-harden\` may still be running or was skipped."
    fi
    echo
    echo "## Mapping decisions"
    echo
    echo "- Default profile: \`azure/artifacts/migration-profile.json\`"
    echo "- Migration blueprint: \`azure/artifacts/migration-blueprint.json\`"
    echo "- Validation report: \`azure/artifacts/validation-report.json\`"
    echo "- Harden report: \`azure/artifacts/harden-report.json\`"
    echo "- Governance source SHA: \`azure/artifacts/governance-source.json\`"
    echo "- Governance conformance: \`azure/artifacts/governance-conformance-report.json\`"
    echo "- Generation summary (incl. conversion): \`azure/artifacts/generation-summary.json\`"
    echo
    if [ -n "$unsupported_excerpt" ]; then
      echo "## Unsupported or placeholder mappings"
      echo
      printf '%s\n' "$unsupported_excerpt"
      echo
    fi
    echo "## Review needed"
    echo
    if [ -n "$review_excerpt" ]; then
      printf '%s\n' "$review_excerpt"
    else
      echo "No review-needed artifact was generated."
    fi
    echo
    echo "## Provenance"
    echo
    echo "- script_pack: \`${SCRIPT_PACK_VERSION}\`"
    echo "- generated_by: StackGen aws-migrator (\`azure-pr\`)"
  } >"$out_file"
}

cmd_azure_pr() {
  local work_root="${1:?WORK_ROOT}"
  local repo_url="${2:-${IAC_REPOSITORY_URL:-}}"
  local default_branch="${3:-${DEFAULT_BRANCH:-main}}"
  local workflow_run_id="${4:-${WORKFLOW_RUN_ID:-}}"

  require_embedded_invocation || return 1

  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$default_branch" ] || [ "$default_branch" = "main" ]; then
    default_branch="$(note_or_default "$work_root" "default_branch" "main")"
  fi
  if [ -z "$workflow_run_id" ]; then
    workflow_run_id="$(read_note "$work_root" "workflow_run_id" 2>/dev/null || date +%Y%m%d%H%M%S)"
  fi
  workflow_run_id="$(printf '%s' "$workflow_run_id" | tr -c 'A-Za-z0-9._-' '-')"

  if [ ! -d "${work_root}/azure/groups" ]; then
    cmd_azure_iac_generate "$work_root"
  fi
  require_destination_governance_ok "$work_root" "azure" || return 1
  ensure_destination_validation_report "$work_root" "azure" || return 1
  prune_destination_validation_temp_reports "${work_root}/azure/artifacts"

  cmd_clone_iac_repo "$work_root" "$repo_url" "$default_branch" || {
    mirror_note "$work_root" "stage_summary:azure-pr" "blocked:clone_failed"
    return 1
  }

  if ! bootstrap_gh; then
    mirror_note "$work_root" "pr_blocker" "git_credentials_missing"
    mirror_note "$work_root" "stage_summary:azure-pr" "blocked:git_credentials_missing"
    echo "pr_blocker=git_credentials_missing"
    return 1
  fi

  local repo_dir repo_full branch pr_title pr_body_file
  repo_dir="$(resolve_repo_dir "$work_root")"
  repo_full="$(repo_full_name_from_url "$repo_url")"
  branch="$(allocate_unique_pr_branch "$repo_full" "azure" "$workflow_run_id")"
  pr_body_file="${work_root}/azure/artifacts/azure-pr-body.md"
  pr_title="$(build_azure_pr_title "$workflow_run_id")"

  cd "$repo_dir"
  if ! git switch -c "$branch"; then
    mirror_note "$work_root" "pr_blocker" "branch_create_failed"
    mirror_note "$work_root" "stage_summary:azure-pr" "blocked:branch_create_failed"
    echo "pr_blocker=branch_create_failed"
    return 1
  fi
  rm -rf azure
  mkdir -p azure
  cp -a "${work_root}/azure/." azure/
  prune_iac_sync_runtime_artifacts azure/groups
  prune_destination_validation_temp_reports azure/artifacts
  write_destination_todo_md "$work_root" "azure"
  cp "${work_root}/azure/artifacts/TODO.md" "azure/artifacts/TODO.md"
  write_azure_pr_body "$work_root" "$workflow_run_id" "$repo_full" "$default_branch" "$pr_body_file"
  cp "$pr_body_file" "azure/artifacts/azure-pr-body.md"

  local commits=0 rc=0
  git_commit_paths_if_changed \
    "azure: migration blueprint for ${workflow_run_id}" \
    azure/artifacts/migration-blueprint.json \
    azure/artifacts/migration-profile.json \
    azure/artifacts/mapping-research.md || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "stage_summary:azure-pr" "blocked:blueprint_commit_failed"
    return 1
  fi
  rc=0
  git_commit_paths_if_changed \
    "azure: terraform groups for ${workflow_run_id}" \
    azure/groups || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "stage_summary:azure-pr" "blocked:terraform_commit_failed"
    return 1
  fi
  rc=0
  git_commit_paths_if_changed \
    "azure: human TODO checklist for ${workflow_run_id}" \
    azure/artifacts/TODO.md \
    azure/artifacts/review-needed.md \
    azure/artifacts/governance-assumptions.md || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "stage_summary:azure-pr" "blocked:todo_commit_failed"
    return 1
  fi
  rc=0
  git_commit_paths_if_changed \
    "azure: migration plan and validation for ${workflow_run_id}" \
    azure/artifacts/validation-report.json \
    azure/artifacts/generation-summary.json \
    azure/artifacts/azure-pr-body.md \
    azure/artifacts || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "stage_summary:azure-pr" "blocked:plan_commit_failed"
    return 1
  fi

  if [ "$commits" -lt 1 ]; then
    mirror_note "$work_root" "stage_summary:azure-pr" "blocked:nothing_to_commit"
    echo "pr_error=nothing_to_commit"
    return 1
  fi

  local pr_url=""
  if ! pr_url="$(git_push_and_open_pr "$repo_full" "$default_branch" "$branch" "$pr_title" "$pr_body_file" "${work_root}/azure/artifacts")"; then
    if [ -f "${work_root}/azure/artifacts/push.err" ]; then
      mirror_note "$work_root" "pr_blocker" "push_failed"
      mirror_note "$work_root" "stage_summary:azure-pr" "blocked:push_failed"
      echo "pr_blocker=push_failed"
    else
      mirror_note "$work_root" "pr_blocker" "pr_create_failed"
      mirror_note "$work_root" "stage_summary:azure-pr" "blocked:pr_create_failed"
      echo "pr_blocker=pr_create_failed"
    fi
    return 1
  fi

  mirror_note "$work_root" "azure_working_branch" "$branch"
  mirror_note "$work_root" "working_branch" "$branch"
  mirror_note "$work_root" "azure_pr_url" "$pr_url"
  mirror_note "$work_root" "pr_url" "$pr_url"
  mirror_note "$work_root" "azure_pr_commit_count" "$commits"
  mirror_note "$work_root" "iac_push_status" "ok"
  mirror_note "$work_root" "stage_summary:azure-pr" "ok"
  echo "working_branch=${branch}"
  echo "azure_pr_url=${pr_url}"
  echo "pr_url=${pr_url}"
  echo "azure_pr_commit_count=${commits}"
}


# normalize_gcp_source_groups copies alternate agent layouts into canonical $WORK_ROOT/groups/.
# Without this, blueprint sees zero groups when fetch used source-iac/ instead of the runner script.
normalize_gcp_source_groups() {
  local work_root="${1:?WORK_ROOT}"
  local groups_dir="${work_root}/groups"
  local count candidate

  count="$(find "${groups_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${count:-0}" -gt 0 ]; then
    return 0
  fi

  for candidate in \
    "${work_root}/source_repo/aws/groups" \
    "${work_root}/source-iac/aws/groups" \
    "${work_root}/source_aws/groups"; do
    if [ ! -d "$candidate" ]; then
      continue
    fi
    count="$(find "$candidate" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${count:-0}" -eq 0 ]; then
      continue
    fi
    rm -rf "$groups_dir"
    cp -a "$candidate" "$groups_dir"
    echo "gcp_source_groups_normalized_from=${candidate}"
    return 0
  done

  return 1
}

cmd_gcp_source_fetch() {
  local work_root="${1:?WORK_ROOT}"
  local repo_url="${2:-${SOURCE_IAC_REPOSITORY_URL:-}}"
  local source_branch="${3:-${SOURCE_IAC_BRANCH:-}}"
  local default_branch="${4:-${DEFAULT_BRANCH:-main}}"
  local source_pr="${SOURCE_PR:-${SOURCE_IAC_PR:-}}"

  require_embedded_invocation || return 1

  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "source_iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$repo_url" ] && [ -n "${IAC_REPOSITORY_URL:-}" ]; then
    repo_url="$IAC_REPOSITORY_URL"
  fi
  if [ -z "$source_branch" ]; then
    source_branch="$(read_note "$work_root" "source_iac_branch" 2>/dev/null || true)"
  fi
  if [ -z "$source_pr" ]; then
    source_pr="$(read_note "$work_root" "source_pr" 2>/dev/null || true)"
  fi
  if [ -z "$source_pr" ]; then
    source_pr="$(read_note "$work_root" "source_iac_pr" 2>/dev/null || true)"
  fi
  if [ -z "$repo_url" ]; then
    mirror_note "$work_root" "blocked:gcp_source_iac_fetch_failed" "missing_source_iac_repository_url"
    mirror_note "$work_root" "stage_summary:gcp-source-fetch" "blocked:missing_source_iac_repository_url"
    echo "blocked:gcp_source_iac_fetch_failed=missing_source_iac_repository_url"
    return 1
  fi

  mkdir -p "${work_root}/.work"
  mirror_note "$work_root" "source_iac_repository_url" "$repo_url"
  mirror_note "$work_root" "iac_repository_url" "$repo_url"
  mirror_note "$work_root" "default_branch" "$default_branch"
  mirror_note "$work_root" "source_cloud" "aws"
  mirror_note "$work_root" "destination_cloud" "gcp"

  local source_dir clone_url git_token repo_full
  source_dir="${work_root}/source_repo"
  clone_url="$(git_clone_url "$repo_url")"
  git_token="$(resolve_git_token)"
  repo_full="$(repo_full_name_from_url "$repo_url")"

  if [[ "$repo_url" =~ ^https:// ]] && [ -z "$git_token" ] && [[ ! "$clone_url" =~ ^https://[^/@]+@ ]]; then
    record_git_credentials_blocker "$work_root" "GIT_TOKEN_missing_for_source_fetch"
    mirror_note "$work_root" "stage_summary:gcp-source-fetch" "blocked:git_credentials_missing"
    echo "clone_error=git_credentials_missing"
    return 1
  fi

  if ! bootstrap_gh; then
    if [[ "$repo_url" =~ ^https:// ]]; then
      record_git_credentials_blocker "$work_root" "bootstrap_gh_no_token_source_fetch"
      mirror_note "$work_root" "stage_summary:gcp-source-fetch" "blocked:git_credentials_missing"
      echo "clone_error=git_credentials_missing"
      return 1
    fi
  fi

  if [ -n "$source_pr" ]; then
    local resolved_branch=""
    if resolved_branch="$(resolve_source_pr_head_branch "$repo_full" "$source_pr")"; then
      source_branch="$resolved_branch"
      mirror_note "$work_root" "source_pr" "$source_pr"
      echo "source_pr=${source_pr}"
    elif [ -n "$source_branch" ]; then
      echo "source_pr_resolve_failed_fallback_branch=${source_branch}"
      mirror_note "$work_root" "source_pr_resolve_fallback" "using SOURCE_IAC_BRANCH after source_pr=${source_pr} failed"
    else
      mirror_note "$work_root" "blocked:gcp_source_iac_fetch_failed" "source_pr_resolve_failed"
      mirror_note "$work_root" "stage_summary:gcp-source-fetch" "blocked:source_pr_resolve_failed"
      echo "blocked:gcp_source_iac_fetch_failed=source_pr_resolve_failed"
      echo "source_pr=${source_pr}"
      return 1
    fi
  fi
  if [ -z "$source_branch" ]; then
    mirror_note "$work_root" "blocked:gcp_source_iac_fetch_failed" "missing_source_iac_branch"
    mirror_note "$work_root" "stage_summary:gcp-source-fetch" "blocked:missing_source_iac_branch"
    echo "blocked:gcp_source_iac_fetch_failed=missing_source_iac_branch"
    return 1
  fi
  mirror_note "$work_root" "source_iac_branch" "$source_branch"

  rm -rf "$source_dir"
  mkdir -p "$source_dir"
  (
    cd "$source_dir"
    git init -q
    git remote add origin "$clone_url"
    git fetch --depth 1 origin "$source_branch"
    git checkout -q -B source-fetch FETCH_HEAD
  ) 2>"${work_root}/.work/source-fetch.err" || {
    mirror_note "$work_root" "blocked:gcp_source_iac_fetch_failed" "git_fetch_failed"
    mirror_note "$work_root" "stage_summary:gcp-source-fetch" "blocked:git_fetch_failed"
    echo "clone_error=git_fetch_failed"
    sed -E 's#x-access-token:[^@]*@#x-access-token:***@#g' "${work_root}/.work/source-fetch.err" >&2 || true
    return 1
  }

  if [ ! -d "${source_dir}/aws/groups" ]; then
    mirror_note "$work_root" "blocked:gcp_source_iac_fetch_failed" "missing_aws_groups"
    mirror_note "$work_root" "stage_summary:gcp-source-fetch" "blocked:missing_aws_groups"
    echo "source_fetch_error=missing_aws_groups"
    return 1
  fi

  rm -rf "${work_root}/groups" "${work_root}/source_aws"
  cp -a "${source_dir}/aws/groups" "${work_root}/groups"
  cp -a "${source_dir}/aws" "${work_root}/source_aws"

  local artifacts_dir="${source_dir}/aws/artifacts"
  if [ -d "$artifacts_dir" ]; then
    for artifact in \
      logical_group_manifest.json \
      shard_manifest.json \
      per_group_resource_counts.json \
      group_state_paths.json \
      registry_mapping_report.json \
      orphans_bundle.json \
      sample_group_ids.json \
      batch_payloads.json \
      identifier_map.json \
      split_quality_report.json \
      split_tuning_history.json \
      review_items.json \
      layer_summary.json \
      cleanup.py \
      split_state.py \
      verify_split.py; do
      if [ -f "${artifacts_dir}/${artifact}" ]; then
        cp "${artifacts_dir}/${artifact}" "${work_root}/${artifact}"
      fi
    done
    if [ -f "${artifacts_dir}/notes.json" ]; then
      cp "${artifacts_dir}/notes.json" "${work_root}/source_notes.json"
    fi
  fi

  if [ ! -f "${work_root}/logical_group_manifest.json" ]; then
    python3 - "$work_root" <<'PY'
import json
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
groups_dir = work / "groups"
manifest = {}
for group_dir in sorted(p for p in groups_dir.iterdir() if p.is_dir()):
    resource_types = set()
    addresses = []
    for tf in group_dir.glob("*.tf"):
        text = tf.read_text(encoding="utf-8", errors="ignore")
        for rtype, name in re.findall(r'resource\s+"(aws_[^"]+)"\s+"([^"]+)"', text):
            resource_types.add(rtype)
            addresses.append(f"{rtype}.{name}")
        for rtype in re.findall(r'import\s+\{[^}]*to\s*=\s*([^.\s]+)\.', text, flags=re.S):
            if rtype.startswith("aws_"):
                resource_types.add(rtype)
    manifest[group_dir.name] = {
        "group_id": group_dir.name,
        "resource_count": len(addresses) or len(resource_types),
        "resources": sorted(addresses),
        "resource_types": sorted(resource_types),
    }
(work / "logical_group_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  fi

  local group_count
  group_count="$(find "${work_root}/groups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [ ! -d "${work_root}/groups" ] || [ "${group_count:-0}" -eq 0 ]; then
    mirror_note "$work_root" "blocked:gcp_source_iac_fetch_failed" "empty_groups_layout"
    mirror_note "$work_root" "stage_summary:gcp-source-fetch" "blocked:empty_groups_layout"
    echo "source_fetch_error=empty_groups_layout group_count=${group_count}"
    return 1
  fi
  mirror_note "$work_root" "gcp_source_iac_fetched" "true"
  mirror_note "$work_root" "gcp_source_iac_group_count" "$group_count"
  mirror_note "$work_root" "logical_group_count" "$group_count"
  mirror_note "$work_root" "source_iac_repo_path" "$source_dir"
  mirror_note "$work_root" "source_iac_groups_path" "${work_root}/groups"
  mirror_note "$work_root" "source_iac_artifacts_path" "${work_root}/source_aws/artifacts"
  mirror_note "$work_root" "stage_summary:gcp-source-fetch" "ok"

  echo 'gcp_source_iac_fetched: "true"'
  echo "gcp_source_iac_group_count=${group_count}"
  echo "source_iac_repository_url=${repo_url}"
  echo "source_iac_branch=${source_branch}"
}

cmd_gcp_migration_blueprint() {
  local work_root="${1:?WORK_ROOT}"
  require_embedded_invocation || return 1

  normalize_gcp_source_groups "$work_root" || true

  mkdir -p "${work_root}/gcp/artifacts"

  python3 - "$work_root" <<'PY'
import hashlib
import json
import os
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
artifacts = work / "gcp" / "artifacts"
artifacts.mkdir(parents=True, exist_ok=True)
groups_dir = work / "groups"
manifest_path = work / "logical_group_manifest.json"

sys.path.insert(0, str(work / "scripts"))
import gcp_mapping_catalog as gmc

catalog = gmc.load_catalog()

# Categories that always warrant a human look even when the catalog has a mapping.
# Deepened scaffolds (identity RBAC, LB, DNS, cache, nosql, static_ip) rely on confidence_threshold.
REVIEW_CATEGORIES = {
    "placeholder",
    "key_management",
    "analytics",
    "non_applicable",
    "cdn",
    "containers",
    "api",
}

profile = {
    "version": "2026-08-12.review-candidate.v1",
    "mode": "review_candidate",
    "source_cloud": "aws",
    "target_cloud": "gcp",
    "confidence_threshold": 0.8,
    "defaults": {
        "project_id": os.environ.get("GCP_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT") or "REPLACE-GCP-PROJECT",
        "region": os.environ.get("GCP_REGION") or "us-central1",
        "location": os.environ.get("GCP_REGION") or "us-central1",
        "resource_group_pattern": "project-${group_id}",
        "tags": {
            "generated_by": "stackgen-aws-migrator",
            "migration_mode": "review-candidate",
            "standards": "gcp-opentofu",
        },
        "labels": {
            "generated_by": "stackgen-aws-migrator",
            "migration_mode": "review-candidate",
        },
        "networking": {
            "subnet_cidr": "10.0.1.0/24",
        },
        "identity": {
            "default": "google_service_account",
            "iam_mapping": "AWS IAM roles map to service accounts plus GCP IAM bindings (operator-owned)",
        },
        "sku": {
            "gke_node_size": "e2-medium",
            "vm_machine_type": "e2-medium",
            "mig_machine_type": "e2-medium",
            "cloudsql_tier": "db-f1-micro",
        },
        "module_source_preference": "local Terraform roots under gcp/groups/<group_id>; upstream modules can replace these later",
    },
    "mapping_catalog": {
        "path": "scripts/mappings/aws-to-gcp.json",
        "version": catalog.get("version"),
        "source_cloud": catalog.get("source_cloud", "aws"),
        "destination_cloud": catalog.get("destination_cloud", "gcp"),
        "note": "Deterministic AWS->GCP resource type mapping is driven by this catalog, not ad-hoc heuristics.",
    },
}

def sanitize_group_id(value: str) -> str:
    value = re.sub(r"[^a-zA-Z0-9_-]+", "-", value or "group").strip("-_")
    return value.lower()[:64] or "group"

def load_manifest_groups():
    groups = {}
    if manifest_path.exists():
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        if isinstance(data, dict):
            iterator = data.items()
        elif isinstance(data, list):
            iterator = [(str(item.get("group_id") or item.get("id") or idx), item) for idx, item in enumerate(data) if isinstance(item, dict)]
        else:
            iterator = []
        for gid, entry in iterator:
            if not isinstance(entry, dict):
                entry = {}
            # Manifest keys are shard identity; normalizing here collapses source groups.
            group_id = str(entry.get("group_id") or entry.get("id") or gid)
            resources = entry.get("resources") or entry.get("addresses") or entry.get("resource_addresses") or []
            resource_types = set(entry.get("resource_types") or entry.get("types") or [])
            if isinstance(resources, dict):
                resources = list(resources.keys())
            for resource in resources:
                if isinstance(resource, dict):
                    address = str(resource.get("address") or resource.get("resource_address") or "")
                    rtype = str(resource.get("type") or resource.get("resource_type") or "")
                else:
                    address = str(resource)
                    rtype = ""
                if not rtype and "." in address:
                    rtype = address.split(".")[-2] if address.endswith("]") and len(address.split(".")) > 1 else address.split(".")[0]
                if rtype.startswith("aws_"):
                    resource_types.add(rtype)
            groups.setdefault(group_id, {"group_id": group_id, "source_resource_types": set(), "source_resource_count": 0})
            groups[group_id]["source_resource_types"].update(resource_types)
            try:
                groups[group_id]["source_resource_count"] = int(entry.get("resource_count") or len(resources) or groups[group_id]["source_resource_count"])
            except Exception:
                groups[group_id]["source_resource_count"] = len(resources)
    if groups_dir.exists():
        for path in sorted(groups_dir.iterdir()):
            if not path.is_dir():
                continue
            group_id = sanitize_group_id(path.name)
            groups.setdefault(group_id, {"group_id": group_id, "source_resource_types": set(), "source_resource_count": 0})
            tf_types = set()
            for tf in path.glob("*.tf"):
                text = tf.read_text(encoding="utf-8", errors="ignore")
                tf_types.update(re.findall(r'resource\s+"(aws_[^"]+)"\s+"', text))
                tf_types.update(re.findall(r'import\s+\{[^}]*to\s*=\s*([^.\s]+)\.', text, flags=re.S))
            groups[group_id]["source_resource_types"].update(tf_types)
            if not groups[group_id]["source_resource_count"]:
                groups[group_id]["source_resource_count"] = len(tf_types)
    return groups

def decision_from_catalog(rtype):
    resolved = gmc.resolve(catalog, rtype)
    return {
        "source_type": resolved["source_type"],
        "status": resolved["status"],
        "category": resolved["category"],
        "emission": resolved.get("emission") or gmc.emission_for_category(resolved.get("category")),
        "hitl_lane": resolved.get("hitl_lane") or gmc.classify_hitl_lane(resolved),
        "gcp_service": resolved["gcp_service"],
        "default_target": resolved["default_target"],
        "target_resource_types": resolved["target_resource_types"],
        "companions": resolved["companions"],
        "attribute_mapping": resolved["attribute_mapping"],
        "confidence": round(float(resolved["confidence"]), 2),
        "review": resolved["review"],
        "match_kind": resolved["match_kind"],
    }

def classify(source_types):
    decisions = []
    matched_categories = set()
    for rtype in sorted(source_types):
        decision = decision_from_catalog(rtype)
        decisions.append(decision)
        matched_categories.add(decision["category"])
    if not decisions:
        decisions.append({
            "source_type": "unknown",
            "status": "unsupported",
            "category": "placeholder",
            "emission": "resource_group_only",
            "hitl_lane": "ambiguous",
            "gcp_service": "Placeholder Terraform scaffold",
            "default_target": None,
            "target_resource_types": [],
            "companions": [],
            "attribute_mapping": {},
            "confidence": 0.40,
            "review": "No source resource types were discoverable for this group.",
            "match_kind": "none",
        })
        matched_categories.add("placeholder")
    return decisions, sorted(matched_categories)

groups = load_manifest_groups()
blueprint_groups = []
review_entries = []
for group_id, entry in sorted(groups.items()):
    source_types = sorted(t for t in entry["source_resource_types"] if str(t).startswith("aws_"))
    decisions, categories = classify(source_types)
    confidence, confidence_reason = gmc.group_confidence(decisions)
    review_needed, review_reasons = gmc.explain_review_needed(
        decisions,
        confidence,
        confidence_reason,
        profile["confidence_threshold"],
        REVIEW_CATEGORIES,
    )
    lane_counts = {}
    for d in decisions:
        lane = d.get("hitl_lane") or gmc.classify_hitl_lane(d)
        lane_counts[lane] = lane_counts.get(lane, 0) + 1
    primary_lane = "defer"
    for candidate in ("ambiguous", "permissions", "shape", "defer"):
        if lane_counts.get(candidate):
            primary_lane = candidate
            break
    if confidence_reason == "non_applicable_only":
        primary_lane = "defer"
    stable_hash = hashlib.sha1(group_id.encode("utf-8")).hexdigest()[:12]
    group_record = {
        "group_id": group_id,
        "stable_hash": stable_hash,
        "source_resource_count": entry.get("source_resource_count", 0),
        "source_resource_types": source_types,
        "target_categories": categories,
        "mapping_decisions": decisions,
        "hitl_lane_counts": lane_counts,
        "primary_hitl_lane": primary_lane,
        "confidence": confidence,
        "confidence_reason": confidence_reason or None,
        "review_needed": review_needed,
        "review_needed_reasons": review_reasons,
        "review_needed_reason": "; ".join(review_reasons) if review_reasons else None,
        "gcp_root": f"gcp/groups/{group_id}",
    }
    blueprint_groups.append(group_record)
    if review_needed:
        review_entries.append(group_record)

blueprint = {
    "profile": profile,
    "group_count": len(blueprint_groups),
    "groups": blueprint_groups,
    "review_needed_count": len(review_entries),
    "hitl_lane_counts": {
        lane: sum(1 for g in blueprint_groups if g.get("primary_hitl_lane") == lane)
        for lane in ("shape", "permissions", "ambiguous", "defer")
    },
}

(artifacts / "migration-profile.json").write_text(json.dumps(profile, indent=2, sort_keys=True) + "\n", encoding="utf-8")
(artifacts / "migration-blueprint.json").write_text(json.dumps(blueprint, indent=2, sort_keys=True) + "\n", encoding="utf-8")

lines = [
    "# GCP migration review-needed items",
    "",
    "Review-candidate mode (GCP security defaults). Triage by HITL lane — do not treat every flagged group the same.",
    "",
    "## How to navigate",
    "",
    "1. Read the [Summary](#summary) lane counts.",
    "2. Work **ambiguous** and **permissions** first; **shape** is optional spot-check; **defer** usually skip.",
    "3. Operator checklist: [`TODO.md`](./TODO.md).",
    "",
]
if not review_entries:
    lines.extend(["## Summary", "", "No mandatory HITL groups — shape scaffolds cleared the confidence gate. Spot-check full_scaffold roots in TODO still recommended.", ""])
else:
    def _lane(g):
        return g.get("primary_hitl_lane") or (
            "defer" if (g.get("confidence_reason") or "") == "non_applicable_only" else "ambiguous"
        )

    by_lane = {k: [] for k in ("ambiguous", "permissions", "shape", "defer")}
    for g in review_entries:
        by_lane.setdefault(_lane(g), []).append(g)
    lines.extend(
        [
            "## Summary",
            "",
            f"- Review-needed groups: **{len(review_entries)}**",
            f"- Ambiguous (product/engine/topology choice): **{len(by_lane['ambiguous'])}**",
            f"- Permissions (IAM action translation): **{len(by_lane['permissions'])}**",
            f"- Shape (below threshold / residual naming-SKU): **{len(by_lane['shape'])}**",
            f"- Defer (non_applicable-only): **{len(by_lane['defer'])}**",
            "",
            "## Index",
            "",
        ]
    )
    for lane, title in (
        ("ambiguous", "Ambiguous (do these first)"),
        ("permissions", "Permissions (IAM / RBAC)"),
        ("shape", "Shape (spot-check)"),
        ("defer", "Defer (usually skip)"),
    ):
        lines.extend([f"### {title}", ""])
        for group in by_lane.get(lane) or []:
            gid = group["group_id"]
            reason = group.get("confidence_reason") or lane
            lines.append(f"- [`{gid}`](#{gid}) — `{reason}`")
        if not by_lane.get(lane):
            lines.append("- _(none)_")
        lines.append("")
    ordered = by_lane["ambiguous"] + by_lane["permissions"] + by_lane["shape"] + by_lane["defer"]
    for group in ordered:
        lines.append(f"## {group['group_id']}")
        lines.append("")
        lines.append(f"- HITL lane: `{group.get('primary_hitl_lane')}`")
        lines.append(f"- Confidence: `{group['confidence']}`")
        if group.get("confidence_reason"):
            lines.append(f"- Confidence reason: `{group['confidence_reason']}`")
        if group.get("review_needed_reason"):
            lines.append(f"- Why review is required: {group['review_needed_reason']}")
        lines.append(f"- Source resource types: `{', '.join(group['source_resource_types']) or 'unknown'}`")
        lines.append(f"- Terraform root: `{group.get('gcp_root') or ('gcp/groups/' + group['group_id'])}`")
        for decision in group["mapping_decisions"]:
            lane = decision.get("hitl_lane") or gmc.classify_hitl_lane(decision)
            if lane == "defer":
                continue
            svc = decision.get("gcp_service") or decision.get("default_target") or "review"
            if lane in ("permissions", "ambiguous") or decision["confidence"] < profile["confidence_threshold"] or decision.get("status") != "mapped" or decision["category"] in REVIEW_CATEGORIES:
                status = decision.get("status", "mapped")
                lines.append(
                    f"- `{decision['source_type']}` -> **{svc}** "
                    f"(`{decision['confidence']}`, {status}, lane=`{lane}`): {decision['review']}"
                )
        lines.append("")
(artifacts / "review-needed.md").write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

print(f"gcp_migration_blueprint_path={artifacts / 'migration-blueprint.json'}")
print(f"gcp_review_needed_path={artifacts / 'review-needed.md'}")
print(f"gcp_blueprint_group_count={len(blueprint_groups)}")
PY

  local group_count
  group_count="$(jq -r '.group_count // 0' "${work_root}/gcp/artifacts/migration-blueprint.json")"
  if [ "${group_count:-0}" -eq 0 ]; then
    mirror_note "$work_root" "gcp_migration_blueprint_ok" "false"
    mirror_note "$work_root" "stage_summary:gcp-migration-blueprint" "blocked:empty_blueprint"
    echo "gcp_blueprint_error=empty_blueprint group_count=0"
    return 1
  fi
  mirror_note "$work_root" "gcp_migration_profile_path" "${work_root}/gcp/artifacts/migration-profile.json"
  mirror_note "$work_root" "gcp_migration_blueprint_path" "${work_root}/gcp/artifacts/migration-blueprint.json"
  mirror_note "$work_root" "gcp_review_needed_path" "${work_root}/gcp/artifacts/review-needed.md"
  mirror_note "$work_root" "gcp_blueprint_group_count" "$group_count"
  mirror_note "$work_root" "gcp_migration_blueprint_ok" "true"
  mirror_note "$work_root" "stage_summary:gcp-migration-blueprint" "ok"
  echo 'gcp_migration_blueprint_ok: "true"'
  echo "gcp_blueprint_group_count=${group_count}"
}

cmd_gcp_iac_generate() {
  local work_root="${1:?WORK_ROOT}"
  require_embedded_invocation || return 1

  if [ ! -f "${work_root}/gcp/artifacts/migration-blueprint.json" ]; then
    cmd_gcp_migration_blueprint "$work_root"
  fi

  local gen_py="${work_root}/scripts/gcp_iac_generate.py"
  if [ ! -f "$gen_py" ]; then
    echo "gcp_iac_generate_error=missing_gcp_iac_generate.py" >&2
    mirror_note "$work_root" "gcp_iac_generated" "false"
    mirror_note "$work_root" "stage_summary:gcp-iac-generate" "blocked:missing_generator"
    return 1
  fi
  python3 "$gen_py" "$work_root"

  local group_count
  group_count="$(jq -r '.generated_group_count // 0' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || echo 0)"
  if [ "${group_count:-0}" -eq 0 ]; then
    mirror_note "$work_root" "gcp_iac_group_count" "0"
    mirror_note "$work_root" "gcp_iac_generated" "false"
    mirror_note "$work_root" "stage_summary:gcp-iac-generate" "blocked:empty_generation"
    echo "gcp_iac_generate_error=empty_generation"
    return 1
  fi
  mirror_note "$work_root" "gcp_iac_group_count" "$group_count"
  mirror_note "$work_root" "gcp_iac_generated" "true"
  mirror_note "$work_root" "stage_summary:gcp-iac-generate" "ok"
  local conv_rate conv_ok eligible converted identity_count app_iam_rate app_iam_ok app_iam_eligible app_iam_converted
  conv_rate="$(jq -r '.infra_conversion_rate // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  conv_ok="$(jq -r '.infra_conversion_ok // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  eligible="$(jq -r '.infra_eligible_count // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  converted="$(jq -r '.infra_converted_count // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  identity_count="$(jq -r '.identity_scaffold_count // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  app_iam_rate="$(jq -r '.app_iam_conversion_rate // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  app_iam_ok="$(jq -r '.app_iam_conversion_ok // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  app_iam_eligible="$(jq -r '.app_iam_eligible_count // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  app_iam_converted="$(jq -r '.app_iam_converted_count // empty' "${work_root}/gcp/artifacts/generation-summary.json" 2>/dev/null || true)"
  if [ -n "$conv_rate" ]; then
    mirror_note "$work_root" "gcp_infra_conversion_rate" "$conv_rate"
  fi
  if [ -n "$conv_ok" ]; then
    mirror_note "$work_root" "gcp_infra_conversion_ok" "$conv_ok"
  fi
  if [ -n "$eligible" ]; then
    mirror_note "$work_root" "gcp_infra_eligible_count" "$eligible"
  fi
  if [ -n "$converted" ]; then
    mirror_note "$work_root" "gcp_infra_converted_count" "$converted"
  fi
  if [ -n "$identity_count" ]; then
    mirror_note "$work_root" "gcp_identity_scaffold_count" "$identity_count"
  fi
  if [ -n "$app_iam_rate" ]; then
    mirror_note "$work_root" "gcp_app_iam_conversion_rate" "$app_iam_rate"
    mirror_note "$work_root" "gcp_app_iam_conversion_ok" "$app_iam_ok"
    mirror_note "$work_root" "gcp_app_iam_eligible_count" "$app_iam_eligible"
    mirror_note "$work_root" "gcp_app_iam_converted_count" "$app_iam_converted"
  fi
  echo 'gcp_iac_generated: "true"'
  echo "gcp_iac_group_count=${group_count}"
  if [ -n "$conv_rate" ]; then
    echo "gcp_infra_conversion_rate=${conv_rate}"
    echo "gcp_infra_conversion_ok=${conv_ok}"
  fi
  if [ -n "$app_iam_rate" ]; then
    echo "gcp_app_iam_conversion_rate=${app_iam_rate}"
    echo "gcp_app_iam_conversion_ok=${app_iam_ok}"
  fi
}

cmd_gcp_iac_validate() {
  cmd_destination_iac_validate "$1" gcp
}

build_gcp_pr_title() {
  local workflow_run_id="${1:?WORKFLOW_RUN_ID}"
  printf 'chore(terraform): add GCP migration IaC for %s' "$workflow_run_id"
}

write_gcp_pr_body() {
  local work_root="${1:?WORK_ROOT}"
  local workflow_run_id="${2:?WORKFLOW_RUN_ID}"
  local repo_full="${3:?REPO}"
  local default_branch="${4:-main}"
  local out_file="${5:?OUT}"

  local group_count validation_ok plan_status review_count blueprint_path validation_report
  group_count="$(read_note "$work_root" "gcp_iac_group_count" 2>/dev/null || echo unknown)"
  validation_ok="$(read_note "$work_root" "gcp_iac_validation_ok" 2>/dev/null || echo unknown)"
  plan_status="$(read_note "$work_root" "gcp_plan_status" 2>/dev/null || echo unknown)"
  blueprint_path="$(read_note "$work_root" "gcp_migration_blueprint_path" 2>/dev/null || echo "${work_root}/gcp/artifacts/migration-blueprint.json")"
  validation_report="$(read_note "$work_root" "gcp_iac_validation_report" 2>/dev/null || echo "${work_root}/gcp/artifacts/validation-report.json")"
  local planned_groups sample_limit static_groups
  planned_groups="$(read_note "$work_root" "gcp_plan_groups_planned" 2>/dev/null || echo unknown)"
  sample_limit="$(read_note "$work_root" "gcp_plan_sample_limit" 2>/dev/null || echo unknown)"
  static_groups="$(jq -r '.group_count // "unknown"' "$validation_report" 2>/dev/null || echo unknown)"
  review_count="unknown"
  if [ -f "$blueprint_path" ]; then
    review_count="$(jq -r '.review_needed_count // "unknown"' "$blueprint_path" 2>/dev/null || echo unknown)"
  fi
  local conv_rate conv_ok eligible converted identity_count gen_summary
  local app_iam_rate app_iam_ok app_iam_eligible app_iam_converted
  gen_summary="${work_root}/gcp/artifacts/generation-summary.json"
  conv_rate="$(read_note "$work_root" "gcp_infra_conversion_rate" 2>/dev/null || true)"
  conv_ok="$(read_note "$work_root" "gcp_infra_conversion_ok" 2>/dev/null || true)"
  eligible="$(read_note "$work_root" "gcp_infra_eligible_count" 2>/dev/null || true)"
  converted="$(read_note "$work_root" "gcp_infra_converted_count" 2>/dev/null || true)"
  identity_count="$(read_note "$work_root" "gcp_identity_scaffold_count" 2>/dev/null || true)"
  app_iam_rate="$(read_note "$work_root" "gcp_app_iam_conversion_rate" 2>/dev/null || true)"
  app_iam_ok="$(read_note "$work_root" "gcp_app_iam_conversion_ok" 2>/dev/null || true)"
  app_iam_eligible="$(read_note "$work_root" "gcp_app_iam_eligible_count" 2>/dev/null || true)"
  app_iam_converted="$(read_note "$work_root" "gcp_app_iam_converted_count" 2>/dev/null || true)"
  if [ -z "$conv_rate" ] && [ -f "$gen_summary" ]; then
    conv_rate="$(jq -r '.infra_conversion_rate // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    conv_ok="$(jq -r '.infra_conversion_ok // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    eligible="$(jq -r '.infra_eligible_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    converted="$(jq -r '.infra_converted_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    identity_count="$(jq -r '.identity_scaffold_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    app_iam_rate="$(jq -r '.app_iam_conversion_rate // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    app_iam_ok="$(jq -r '.app_iam_conversion_ok // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    app_iam_eligible="$(jq -r '.app_iam_eligible_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
    app_iam_converted="$(jq -r '.app_iam_converted_count // "unknown"' "$gen_summary" 2>/dev/null || echo unknown)"
  fi
  conv_rate="${conv_rate:-unknown}"
  conv_ok="${conv_ok:-unknown}"
  eligible="${eligible:-unknown}"
  converted="${converted:-unknown}"
  identity_count="${identity_count:-unknown}"
  app_iam_rate="${app_iam_rate:-unknown}"
  app_iam_ok="${app_iam_ok:-unknown}"
  app_iam_eligible="${app_iam_eligible:-unknown}"
  app_iam_converted="${app_iam_converted:-unknown}"

  local review_excerpt unsupported_excerpt harden_excerpt harden_report harden_autofix harden_findings harden_fmt harden_lint
  review_excerpt=""
  if [ -f "${work_root}/gcp/artifacts/review-needed.md" ]; then
    review_excerpt="$(sed -n '1,120p' "${work_root}/gcp/artifacts/review-needed.md")"
  fi
  unsupported_excerpt=""
  if [ -f "$blueprint_path" ]; then
    unsupported_excerpt="$(jq -r '[.groups[]?.mapping_decisions[]? | select(.status=="unsupported" or .emission=="resource_group_only" or .category=="placeholder") | .source_type] | unique | .[]' "$blueprint_path" 2>/dev/null | head -40 | while read -r st; do echo "- \`$st\`: catalog unsupported/placeholder — see review-needed.md"; done || true)"
  fi
  harden_report="${work_root}/gcp/artifacts/harden-report.json"
  harden_autofix="unknown"
  harden_findings="unknown"
  harden_fmt="unknown"
  harden_lint="unknown"
  if [ -f "$harden_report" ]; then
    harden_autofix="$(jq -r '.autofix_count // 0' "$harden_report" 2>/dev/null || echo 0)"
    harden_findings="$(jq -r '.residual_count // .finding_count // 0' "$harden_report" 2>/dev/null || echo 0)"
    harden_fmt="$(jq -r '.fmt_fail_count // 0' "$harden_report" 2>/dev/null || echo 0)"
    harden_lint="$(jq -r '.lint_fail_count // 0' "$harden_report" 2>/dev/null || echo 0)"
  fi
  harden_excerpt=""
  if [ -f "${work_root}/gcp/artifacts/harden-findings.md" ]; then
    harden_excerpt="$(sed -n '1,80p' "${work_root}/gcp/artifacts/harden-findings.md")"
  fi

  local validation_incomplete=""
  validation_incomplete="$(read_note "$work_root" "validation_report_incomplete" 2>/dev/null || true)"
  if [ -z "$validation_incomplete" ] && [ -f "$validation_report" ]; then
    if jq -e '(.summary.pr_policy // "") == "soft_gate_open_with_remarks" or (.groups[0].group_id // "") == "_incomplete"' "$validation_report" >/dev/null 2>&1; then
      validation_incomplete="true"
    fi
  fi

  mkdir -p "$(dirname "$out_file")"
  {
    echo "## Summary"
    echo
    echo "Adds **review-candidate** GCP Terraform under \`gcp/\` (GCP naming and private-by-default defaults, honest emission labels) for AWS reverse-IaC groups."
    echo "Ambiguous mappings do not block the PR; operators must treat non-\`full_scaffold\` emissions as incomplete. Details: \`gcp/artifacts/review-needed.md\`."
    if [ "$validation_incomplete" = "true" ] || [ "$validation_ok" != "true" ]; then
      echo
      echo "> **Not apply-ready.** Validation matrix is incomplete or failed (\`validation_ok=${validation_ok}\`, \`plan_status=${plan_status}\`). Opened so reviewers can inspect scaffolds, governance residuals, and TODO.md. Fix validate/plan before merge/apply."
    fi
    echo
    echo "## Run status"
    echo
    echo "| Item | Value |"
    echo "| --- | --- |"
    echo "| Repository | \`${repo_full}\` |"
    echo "| Base branch | \`${default_branch}\` |"
    echo "| workflow_run_id | \`${workflow_run_id}\` |"
    echo "| Generated GCP groups | \`${group_count}\` |"
    echo "| Static validated groups | \`${static_groups}\` |"
    echo "| Live plan sample | \`${planned_groups}\` of \`${static_groups}\` (limit \`${sample_limit}\`) |"
    echo "| GCP validation | \`${validation_ok}\` |"
    echo "| GCP plan status | \`${plan_status}\` |"
    local wiring_summary="${work_root}/gcp/artifacts/generation-summary.json"
    if [ -f "$wiring_summary" ]; then
      local log_source_count log_target_count log_routing_status log_retention_assumptions
      log_source_count="$(jq '[.groups[]?.source_resource_counts.aws_cloudwatch_log_group // 0] | add // 0' "$wiring_summary" 2>/dev/null || echo unknown)"
      log_target_count="$(jq '[.groups[]?.generated_resource_counts.google_logging_project_bucket_config // 0] | add // 0' "$wiring_summary" 2>/dev/null || echo unknown)"
      log_routing_status="$(jq -r '[.groups[]?.logging_routing_status // empty] | unique | join(", ")' "$wiring_summary" 2>/dev/null || echo unknown)"
      log_retention_assumptions="$(jq '[.groups[]?.logging_retention_assumption_count // 0] | add // 0' "$wiring_summary" 2>/dev/null || echo unknown)"
      echo "| CloudWatch log groups → GCP log buckets | \`${log_source_count} → ${log_target_count}\` |"
      echo "| CloudWatch routing status | \`${log_routing_status:-not_applicable}\` |"
      echo "| CloudWatch retention assumptions | \`${log_retention_assumptions}\` |"
    fi
    echo "| Validation report complete | \`$([ "$validation_incomplete" = "true" ] && echo false || echo true)\` |"
    echo "| Harden autofixes | \`${harden_autofix}\` |"
    echo "| Harden residual findings | \`${harden_findings}\` |"
    echo "| Harden fmt / tflint fails | \`${harden_fmt}\` / \`${harden_lint}\` |"
    echo "| Review-needed groups | \`${review_count}\` |"
    echo "| Infra conversion rate | \`${conv_rate}\` (eligible \`${eligible}\`, converted \`${converted}\`, ok=\`${conv_ok}\`, target ≥ 0.80) |"
    echo "| App IAM conversion rate | \`${app_iam_rate}\` (eligible \`${app_iam_eligible}\`, converted \`${app_iam_converted}\`, ok=\`${app_iam_ok}\`, target ≥ 0.80) |"
    echo "| Identity / app-IAM instances | \`${identity_count}\` (excluded from infra conversion; tracked in app IAM rate) |"
    echo
    echo "## Operator contract"
    echo
    echo "- This PR is **review-candidate** IaC (GCP naming + private-by-default defaults). It is **not** apply-ready landing-zone/AVM."
    echo "- Catalog \`status=mapped\` means a target type exists; check \`emission\` (\`managed_identity_rbac_scaffold\` = SA + custom role + binding, not full action translation)."
    echo "- **Infra conversion** counts non-identity mapped AWS instances that received a matching \`google_*\` scaffold (target ≥ 80%)."
    echo "- **App IAM conversion** (acquisition path) counts workload \`aws_iam_role\` / policy / inline policy instances that received SA + \`google_project_iam_custom_role\` scaffolds. AWS actions are preserved as comments for specialist translation. Attachments stay \`non_applicable\` glue."
    echo "- Static validation should cover all generated groups; live plan may be a **sample** — trust the sample columns above, not a bare \`success\` alone."
    echo
    echo "## Validation contract"
    echo
    echo "- Static validation runs \`tofu fmt\`, \`tofu validate\`, optional \`tofu test\`, and optional \`tflint\` on validated groups."
    echo "- Parallel \`gcp-iac-harden\` applies mechanical security/lint autofixes into the same PR; see \`gcp/artifacts/harden-findings.md\`."
    echo "- \`gcp-iac-governance-conform\` refreshes living Nile docs, derives a per-resource tree, and re-verifies Priority-1 + OPA. Agents must follow Rego-authored directions in \`governance-opa-guidance.json\`, reason about source values/provider schema, edit the appropriate layer, and re-run verification. If residuals remain after max iterations, this PR still opens with TODOs — clear them before apply. Pin SHA from \`gcp/artifacts/governance-source.json\`. Validation evidence is not human approval."
    echo "- Live GCP plan runs only when GCP credentials are present on the runner (sampled when \`GCP_LIVE_PLAN_MAX_GROUPS\` is set)."
    echo "- Live plan status is recorded as \`gcp_plan_status\`. When credentials are required, missing GOOGLE_*/GCP_* fails validate; this PR never applies GCP resources."
    echo "- When a live plan runs, sampled success requires expected creates and no deletes or replacements."
    echo
    emit_governance_residual_md "$work_root" "gcp"
    if [ -f "${work_root}/gcp/artifacts/governance-assumptions.md" ]; then
      echo "## Migration assumptions"
      echo
      sed -n '1,80p' "${work_root}/gcp/artifacts/governance-assumptions.md"
      echo
    fi
    echo "## Lint / security harden"
    echo
    if [ -n "$harden_excerpt" ]; then
      printf '%s\n' "$harden_excerpt"
    else
      echo "No harden report yet — \`gcp-iac-harden\` may still be running or was skipped."
    fi
    echo
    echo "## Mapping decisions"
    echo
    echo "- Mapping research (Registry/provider evidence, candidate targets, and unresolved decisions): \`gcp/artifacts/mapping-research.md\` when gaps required research."
    echo "- Default profile: \`gcp/artifacts/migration-profile.json\`"
    echo "- Migration blueprint: \`gcp/artifacts/migration-blueprint.json\`"
    echo "- Generation summary (incl. conversion): \`gcp/artifacts/generation-summary.json\`"
    echo "- Validation report: \`gcp/artifacts/validation-report.json\`"
    echo "- Harden report: \`gcp/artifacts/harden-report.json\`"
    echo "- Governance source SHA: \`gcp/artifacts/governance-source.json\`"
    echo "- Governance conformance: \`gcp/artifacts/governance-conformance-report.json\`"
    echo
    if [ -n "$unsupported_excerpt" ]; then
      echo "## Unsupported or placeholder mappings"
      echo
      printf '%s\n' "$unsupported_excerpt"
      echo
    fi
    echo "## Review needed"
    echo
    if [ -n "$review_excerpt" ]; then
      printf '%s\n' "$review_excerpt"
    else
      echo "No review-needed artifact was generated."
    fi
    echo
    echo "## Provenance"
    echo
    echo "- script_pack: \`${SCRIPT_PACK_VERSION}\`"
    echo "- generated_by: StackGen aws-migrator (\`gcp-pr\`)"
  } >"$out_file"
}

cmd_gcp_pr() {
  local work_root="${1:?WORK_ROOT}"
  local repo_url="${2:-${IAC_REPOSITORY_URL:-}}"
  local default_branch="${3:-${DEFAULT_BRANCH:-main}}"
  local workflow_run_id="${4:-${WORKFLOW_RUN_ID:-}}"

  require_embedded_invocation || return 1

  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$default_branch" ] || [ "$default_branch" = "main" ]; then
    default_branch="$(note_or_default "$work_root" "default_branch" "main")"
  fi
  if [ -z "$workflow_run_id" ]; then
    workflow_run_id="$(read_note "$work_root" "workflow_run_id" 2>/dev/null || date +%Y%m%d%H%M%S)"
  fi
  workflow_run_id="$(printf '%s' "$workflow_run_id" | tr -c 'A-Za-z0-9._-' '-')"

  if [ ! -d "${work_root}/gcp/groups" ]; then
    cmd_gcp_iac_generate "$work_root"
  fi
  require_destination_governance_ok "$work_root" "gcp" || return 1
  ensure_destination_validation_report "$work_root" "gcp" || return 1
  prune_destination_validation_temp_reports "${work_root}/gcp/artifacts"

  cmd_clone_iac_repo "$work_root" "$repo_url" "$default_branch" || {
    mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:clone_failed"
    return 1
  }

  if ! bootstrap_gh; then
    mirror_note "$work_root" "pr_blocker" "git_credentials_missing"
    mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:git_credentials_missing"
    echo "pr_blocker=git_credentials_missing"
    return 1
  fi

  local repo_dir repo_full branch pr_title pr_body_file
  repo_dir="$(resolve_repo_dir "$work_root")"
  repo_full="$(repo_full_name_from_url "$repo_url")"
  branch="$(allocate_unique_pr_branch "$repo_full" "gcp" "$workflow_run_id")"
  pr_body_file="${work_root}/gcp/artifacts/gcp-pr-body.md"
  pr_title="$(build_gcp_pr_title "$workflow_run_id")"

  cd "$repo_dir"
  if ! git switch -c "$branch"; then
    mirror_note "$work_root" "pr_blocker" "branch_create_failed"
    mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:branch_create_failed"
    echo "pr_blocker=branch_create_failed"
    return 1
  fi
  rm -rf gcp
  mkdir -p gcp
  cp -a "${work_root}/gcp/." gcp/
  prune_iac_sync_runtime_artifacts gcp/groups
  prune_destination_validation_temp_reports gcp/artifacts
  write_destination_todo_md "$work_root" "gcp"
  cp "${work_root}/gcp/artifacts/TODO.md" "gcp/artifacts/TODO.md"
  write_gcp_pr_body "$work_root" "$workflow_run_id" "$repo_full" "$default_branch" "$pr_body_file"
  cp "$pr_body_file" "gcp/artifacts/gcp-pr-body.md"

  local commits=0 rc=0
  git_commit_paths_if_changed \
    "gcp: migration blueprint for ${workflow_run_id}" \
    gcp/artifacts/migration-blueprint.json \
    gcp/artifacts/migration-profile.json \
    gcp/artifacts/mapping-research.md || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:blueprint_commit_failed"
    return 1
  fi
  rc=0
  git_commit_paths_if_changed \
    "gcp: terraform groups for ${workflow_run_id}" \
    gcp/groups || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:terraform_commit_failed"
    return 1
  fi
  rc=0
  git_commit_paths_if_changed \
    "gcp: human TODO checklist for ${workflow_run_id}" \
    gcp/artifacts/TODO.md \
    gcp/artifacts/review-needed.md \
    gcp/artifacts/governance-assumptions.md || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:todo_commit_failed"
    return 1
  fi
  rc=0
  git_commit_paths_if_changed \
    "gcp: migration plan and validation for ${workflow_run_id}" \
    gcp/artifacts/validation-report.json \
    gcp/artifacts/generation-summary.json \
    gcp/artifacts/gcp-pr-body.md \
    gcp/artifacts || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:plan_commit_failed"
    return 1
  fi

  if [ "$commits" -lt 1 ]; then
    mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:nothing_to_commit"
    echo "pr_error=nothing_to_commit"
    return 1
  fi

  local pr_url=""
  if ! pr_url="$(git_push_and_open_pr "$repo_full" "$default_branch" "$branch" "$pr_title" "$pr_body_file" "${work_root}/gcp/artifacts")"; then
    if [ -f "${work_root}/gcp/artifacts/push.err" ]; then
      mirror_note "$work_root" "pr_blocker" "push_failed"
      mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:push_failed"
      echo "pr_blocker=push_failed"
    else
      mirror_note "$work_root" "pr_blocker" "pr_create_failed"
      mirror_note "$work_root" "stage_summary:gcp-pr" "blocked:pr_create_failed"
      echo "pr_blocker=pr_create_failed"
    fi
    return 1
  fi

  mirror_note "$work_root" "gcp_working_branch" "$branch"
  mirror_note "$work_root" "working_branch" "$branch"
  mirror_note "$work_root" "gcp_pr_url" "$pr_url"
  mirror_note "$work_root" "pr_url" "$pr_url"
  mirror_note "$work_root" "gcp_pr_commit_count" "$commits"
  mirror_note "$work_root" "iac_push_status" "ok"
  mirror_note "$work_root" "stage_summary:gcp-pr" "ok"
  echo "working_branch=${branch}"
  echo "gcp_pr_url=${pr_url}"
  echo "pr_url=${pr_url}"
  echo "gcp_pr_commit_count=${commits}"
}


build_iac_pr_title() {
  local work_root="${1:?WORK_ROOT}"
  local repo_full="${2:?REPO}"
  local custom
  custom="$(read_note "$work_root" "iac_pr_title" 2>/dev/null || true)"
  if [ -n "$custom" ]; then
    printf '%s' "$custom"
    return 0
  fi
  local repo_name group_count monolith_count
  repo_name="${repo_full##*/}"
  group_count="$(read_note "$work_root" "logical_group_count" 2>/dev/null || echo unknown)"
  monolith_count="$(read_note "$work_root" "monolith_resource_count" 2>/dev/null || echo unknown)"
  printf 'chore(terraform): split %s monolith state into %s groups (%s resources)' \
    "$repo_name" "$group_count" "$monolith_count"
}

write_iac_pr_body() {
  local work_root="${1:?WORK_ROOT}"
  local workflow_run_id="${2:?WORKFLOW_RUN_ID}"
  local repo_full="${3:?REPO}"
  local default_branch="${4:-main}"
  local out_file="${5:?OUT}"

  local custom_body
  custom_body="$(read_note "$work_root" "iac_pr_body_path" 2>/dev/null || true)"
  if [ -n "$custom_body" ] && [ -f "$custom_body" ]; then
    cp "$custom_body" "$out_file"
    return 0
  fi

  local group_count monolith_count aggregate_count reconcile_ok grouping_strategy max_cap groups_synced monolith_uri split_score split_pass tuning_iterations
  group_count="$(read_note "$work_root" "logical_group_count" 2>/dev/null || echo unknown)"
  monolith_count="$(read_note "$work_root" "monolith_resource_count" 2>/dev/null || echo unknown)"
  aggregate_count="$(read_note "$work_root" "aggregate_group_resource_count" 2>/dev/null || echo unknown)"
  reconcile_ok="$(read_note "$work_root" "count_reconciliation_ok" 2>/dev/null || echo unknown)"
  grouping_strategy="$(read_note "$work_root" "grouping_strategy" 2>/dev/null || echo unknown)"
  max_cap="$(read_note "$work_root" "max_resources_per_appstack" 2>/dev/null || echo unknown)"
  groups_synced="$(read_note "$work_root" "groups_synced_to_repo" 2>/dev/null || echo unknown)"
  monolith_uri="$(read_note "$work_root" "monolith_state_uri" 2>/dev/null || echo unknown)"
  split_score="$(read_note "$work_root" "split_quality_score" 2>/dev/null || echo unknown)"
  split_pass="$(read_note "$work_root" "split_quality_pass" 2>/dev/null || echo unknown)"
  tuning_iterations="$(read_note "$work_root" "split_tuning_iterations" 2>/dev/null || echo unknown)"

  local sample_groups=""
  if [ -f "${work_root}/sample_group_ids.json" ]; then
    sample_groups="$(jq -r '.[:8][]' "${work_root}/sample_group_ids.json" 2>/dev/null | paste -sd, - || true)"
  fi

  mkdir -p "$(dirname "$out_file")"
  {
    echo "## Summary"
    echo
    echo "Automated **terraform state shard split** from the StackGen \`aws-cloud-discovery\` workflow."
    echo "This PR adds source-cloud IaC under \`aws/groups/<group_id>/\` and workflow artifacts under \`aws/artifacts/\`."
    echo "The Azure generation stage later syncs destination-cloud IaC under \`azure/\` and opens an Azure PR."
    echo
    echo "## Split metrics"
    echo
    echo "| Metric | Value |"
    echo "| --- | --- |"
    echo "| Repository | \`${repo_full}\` |"
    echo "| Base branch | \`${default_branch}\` |"
    echo "| Logical groups | \`${group_count}\` |"
    echo "| Monolith resources | \`${monolith_count}\` |"
    echo "| Aggregate group resources | \`${aggregate_count}\` |"
    echo "| Count reconciliation | \`${reconcile_ok}\` |"
    echo "| Grouping strategy | \`${grouping_strategy}\` |"
    echo "| Max resources per group | \`${max_cap}\` |"
    echo "| Split quality score | \`${split_score}\` |"
    echo "| Split quality pass | \`${split_pass}\` |"
    echo "| Tuning iterations | \`${tuning_iterations}\` |"
    echo "| Groups synced in this PR | \`${groups_synced}\` |"
    if [ -n "$monolith_uri" ] && [ "$monolith_uri" != "unknown" ]; then
      echo "| Source monolith URI | \`${monolith_uri}\` |"
    fi
    echo
    if [ -n "$sample_groups" ]; then
      echo "## Sample group IDs (hydrate/plan matrix)"
      echo
      echo "\`${sample_groups}\`"
      echo
    fi
    echo "## Review checklist"
    echo
    echo "- [ ] \`aws/groups/\` tree matches expected group count"
    echo "- [ ] \`aws/artifacts/split_quality_report.json\` and \`aws/artifacts/split_tuning_history.json\` explain the selected segregation"
    echo "- [ ] Per-group state files present under each \`aws/groups/<id>/\`"
    echo "- [ ] Source Cloud2Code output, manifests, and handoff artifacts are present under \`aws/artifacts/\`"
    echo "- [ ] Azure follow-up PR includes \`azure/groups/<group_id>/\` and \`azure/artifacts/\`"
    echo "- [ ] Import/registry scaffold files look correct for your repo layout"
    echo "- [ ] Follow-up: run \`shell-converge-matrix\` / zero-diff plans on sample groups before merge"
    echo
    echo "## Provenance"
    echo
    echo "- workflow_run_id: \`${workflow_run_id}\`"
    echo "- script_pack: \`${SCRIPT_PACK_VERSION}\`"
    echo "- generated_by: StackGen aws-migrator (\`iac-pr-pipeline\`)"
  } >"$out_file"
}

cmd_commit_pr() {
  local work_root="${1:?WORK_ROOT}"
  local repo_url="${2:-}"
  local default_branch="${3:-main}"
  local workflow_run_id="${4:-}"

  if [ -z "$repo_url" ]; then
    repo_url="$(read_note "$work_root" "iac_repository_url" 2>/dev/null || true)"
  fi
  if [ -z "$default_branch" ] || [ "$default_branch" = "main" ]; then
    default_branch="$(note_or_default "$work_root" "default_branch" "main")"
  fi
  if [ -z "$workflow_run_id" ]; then
    workflow_run_id="${WORKFLOW_RUN_ID:-$(read_note "$work_root" "workflow_run_id" 2>/dev/null || true)}"
  fi
  if [ -z "$workflow_run_id" ]; then
    workflow_run_id="$(date +%Y%m%d%H%M%S)"
  fi

  if ! bootstrap_gh; then
    mirror_note "$work_root" "pr_blocker" "git_credentials_missing"
    echo "pr_blocker=git_credentials_missing"
    return 1
  fi

  local repo_dir repo_full branch pr_title pr_body_file
  repo_dir="$(resolve_repo_dir "$work_root")"
  if [ ! -d "$repo_dir/.git" ]; then
    mirror_note "$work_root" "pr_blocker" "no_clone"
    echo "pr_error=no_clone"
    return 1
  fi

  repo_full="$(repo_full_name_from_url "$repo_url")"
  branch="$(allocate_unique_pr_branch "$repo_full" "discovery" "$workflow_run_id")"

  cd "$repo_dir"
  clear_stale_git_index_lock "$repo_dir"
  if ! git switch -c "$branch"; then
    mirror_note "$work_root" "pr_blocker" "branch_create_failed"
    echo "pr_blocker=branch_create_failed"
    return 1
  fi

  prepare_aws_discovery_pr_artifacts "$work_root" "${repo_dir}/aws/artifacts"

  pr_title="$(build_iac_pr_title "$work_root" "$repo_full")"
  pr_body_file="${work_root}/.work/pr-body.md"
  write_iac_pr_body "$work_root" "$workflow_run_id" "$repo_full" "$default_branch" "$pr_body_file"

  local commits=0 rc=0
  # 1) discovery report
  git_commit_paths_if_changed \
    "aws: cloud discovery report for ${workflow_run_id}" \
    aws/artifacts/discovery-report.md \
    aws/artifacts/cloud2code-scan-report.md \
    aws/artifacts/cloud2code-scan-report.json \
    aws/artifacts/cloud2code \
    aws/artifacts/cloud2code.log \
    aws/artifacts/cloud2code-command.txt \
    aws/artifacts/aws-caller-identity.json || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "pr_blocker" "discovery_report_commit_failed"
    return 1
  fi
  # 2) tfstate (artifact indexes + any *.tfstate under aws/groups — not HCL)
  rc=0
  local -a tfstate_paths=(
    aws/artifacts/group_state_paths.json
    aws/artifacts/per_group_resource_counts.json
    aws/artifacts/shard_manifest.json
  )
  local tfstate_file
  while IFS= read -r tfstate_file; do
    [ -n "$tfstate_file" ] || continue
    tfstate_paths+=("$tfstate_file")
  done < <(find aws/groups -type f \( -name '*.tfstate' -o -name '*.tfstate.backup' \) 2>/dev/null || true)
  while IFS= read -r tfstate_file; do
    [ -n "$tfstate_file" ] || continue
    tfstate_paths+=("$tfstate_file")
  done < <(find aws/artifacts/cloud2code -type f -name '*.tfstate' 2>/dev/null || true)
  git_commit_paths_if_changed \
    "aws: tfstate monolith and split shards for ${workflow_run_id}" \
    "${tfstate_paths[@]}" || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "pr_blocker" "tfstate_commit_failed"
    return 1
  fi
  # Evidence: monolith + shard state must be tracked in the PR (gitignore-proof).
  local committed_tfstate_count=0 monolith_tfstate_tracked=false
  committed_tfstate_count="$(git ls-files -- 'aws/groups/**/*.tfstate' 'aws/artifacts/cloud2code/**/*.tfstate' 2>/dev/null | wc -l | tr -d ' ')"
  if git ls-files --error-unmatch 'aws/artifacts/cloud2code/aws-*/terraform.tfstate' >/dev/null 2>&1 \
    || git ls-files -- 'aws/artifacts/cloud2code/**/*.tfstate' 2>/dev/null | grep -q .; then
    monolith_tfstate_tracked=true
  fi
  echo "tfstate_committed=true"
  echo "tfstate_tracked_count=${committed_tfstate_count}"
  echo "monolith_tfstate_tracked=${monolith_tfstate_tracked}"
  mirror_note "$work_root" "tfstate_tracked_count" "$committed_tfstate_count"
  mirror_note "$work_root" "monolith_tfstate_tracked" "$monolith_tfstate_tracked"
  # 3) migration blueprint
  rc=0
  git_commit_paths_if_changed \
    "aws: migration blueprint for ${workflow_run_id}" \
    aws/artifacts/migration-blueprint.json || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "pr_blocker" "blueprint_commit_failed"
    return 1
  fi
  # 4) module split report
  rc=0
  git_commit_paths_if_changed \
    "aws: module split report for ${workflow_run_id}" \
    aws/artifacts/logical_group_manifest.json \
    aws/artifacts/split_quality_report.json \
    aws/artifacts/split_tuning_history.json \
    aws/artifacts/registry_mapping_report.json \
    aws/artifacts/orphans_bundle.json \
    aws/artifacts/review_items.json \
    aws/artifacts/layer_summary.json \
    aws/artifacts/sample_group_ids.json \
    aws/artifacts/batch_payloads.json \
    aws/artifacts/identifier_map.json \
    aws/artifacts/notes.json \
    aws/artifacts/converge-status.json || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "pr_blocker" "split_report_commit_failed"
    return 1
  fi
  # 5) terraform code
  rc=0
  git_commit_paths_if_changed \
    "aws: terraform group roots for ${workflow_run_id}" \
    aws/groups \
    aws/README.md || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "pr_blocker" "terraform_commit_failed"
    return 1
  fi
  # 6) TODO list
  rc=0
  git_commit_paths_if_changed \
    "aws: human TODO checklist for ${workflow_run_id}" \
    aws/artifacts/TODO.md || rc=$?
  if [ "$rc" -eq 0 ]; then commits=$((commits + 1)); elif [ "$rc" -ne 2 ]; then
    mirror_note "$work_root" "pr_blocker" "todo_commit_failed"
    return 1
  fi

  if [ "$commits" -lt 1 ]; then
    echo "pr_error=nothing_to_commit"
    return 1
  fi

  local pr_url=""
  if ! pr_url="$(git_push_and_open_pr "$repo_full" "$default_branch" "$branch" "$pr_title" "$pr_body_file" "${work_root}/.work")"; then
    if [ -f "${work_root}/.work/push.err" ]; then
      mirror_note "$work_root" "pr_blocker" "push_failed"
      echo "pr_blocker=push_failed"
    else
      mirror_note "$work_root" "pr_blocker" "pr_create_failed"
      echo "pr_blocker=pr_create_failed"
    fi
    return 1
  fi

  mirror_note "$work_root" "working_branch" "$branch"
  mirror_note "$work_root" "pr_url" "$pr_url"
  mirror_note "$work_root" "iac_pr_url" "$pr_url"
  mirror_note "$work_root" "iac_push_status" "ok"
  mirror_note "$work_root" "iac_push_branch" "$branch"
  mirror_note "$work_root" "aws_discovery_pr_commit_count" "$commits"
  echo "working_branch=${branch}"
  echo "pr_url=${pr_url}"
  echo "iac_pr_url=${pr_url}"
  echo "aws_discovery_pr_commit_count=${commits}"
}

adopt_decomposition_handoff() {
  local work_root="${1:?WORK_ROOT}"
  if [ -f "${work_root}/logical_group_manifest.json" ] && [ -d "${work_root}/groups" ]; then
    return 0
  fi

  local manifest_path source_root
  manifest_path="$(read_note "$work_root" "logical_group_manifest_path" 2>/dev/null || true)"
  if [ -f "$manifest_path" ] && [ -d "$(dirname "$manifest_path")/groups" ]; then
    source_root="$(cd "$(dirname "$manifest_path")" && pwd)"
  else
    manifest_path="${work_root}/decomposition/logical_group_manifest.json"
    source_root="${work_root}/decomposition"
  fi
  if [ ! -f "$manifest_path" ] || [ ! -d "${source_root}/groups" ]; then
    return 0
  fi
  source_root="$(cd "$source_root" && pwd)"
  if [ "$source_root" = "$work_root" ]; then
    return 0
  fi

  local artifact
  for artifact in \
    logical_group_manifest.json \
    shard_manifest.json \
    per_group_resource_counts.json \
    group_state_paths.json \
    reconcile_result.json \
    split_quality_report.json \
    split_tuning_history.json \
    review_items.json \
    layer_summary.json; do
    if [ -f "${source_root}/${artifact}" ] && [ ! -e "${work_root}/${artifact}" ]; then
      cp -a "${source_root}/${artifact}" "${work_root}/${artifact}"
    fi
  done
  if [ -d "${source_root}/groups" ] && [ ! -e "${work_root}/groups" ]; then
    cp -a "${source_root}/groups" "${work_root}/groups"
  fi

  if [ -f "${work_root}/reconcile_result.json" ]; then
    mirror_note "$work_root" "count_reconciliation_ok" \
      "$(jq -r '.count_reconciliation_ok // false' "${work_root}/reconcile_result.json")"
    mirror_note "$work_root" "monolith_resource_count" \
      "$(jq -r '.monolith_resource_count // 0' "${work_root}/reconcile_result.json")"
    mirror_note "$work_root" "aggregate_group_resource_count" \
      "$(jq -r '.aggregate_group_resource_count // 0' "${work_root}/reconcile_result.json")"
  fi
  mirror_note "$work_root" "logical_group_manifest_path" "${work_root}/logical_group_manifest.json"
  mirror_note "$work_root" "group_state_paths" "${work_root}/group_state_paths.json"
  mirror_note "$work_root" "decomposition_handoff_adopted_from" "$source_root"
  echo "decomposition_handoff_adopted_from=${source_root}"
}

cmd_iac_pr_pipeline() {
  local work_root="${1:?WORK_ROOT}"
  local repo_url="${2:-${IAC_REPOSITORY_URL:-}}"
  local default_branch="${3:-${DEFAULT_BRANCH:-main}}"
  local workflow_run_id="${4:-${WORKFLOW_RUN_ID:-}}"

  require_embedded_invocation || return 1
  # Compatibility for a worker that wrote a valid split under
  # $WORK_ROOT/decomposition instead of using the canonical ingest bootstrap.
  adopt_decomposition_handoff "$work_root"

  local reconcile_ok
  reconcile_ok="$(read_note "$work_root" "count_reconciliation_ok" 2>/dev/null || true)"
  # Session 8478c357 split into $WORK_ROOT/decomposition/<group>/terraform.tfstate
  # with no manifest and no reconcile result, which the adopter above cannot
  # salvage. Redo the canonical split from the scanned state rather than ending
  # the run: the scan is the expensive part and it already succeeded.
  if [ "$reconcile_ok" != "true" ]; then
    echo "iac_pr_recovery=rerunning_canonical_split"
    if cmd_ingest_and_split "$work_root"; then
      reconcile_ok="$(read_note "$work_root" "count_reconciliation_ok" 2>/dev/null || true)"
    fi
  fi
  if [ "$reconcile_ok" != "true" ]; then
    echo "iac_pr_error=count_reconciliation_not_ok"
    return 1
  fi

  if [ -n "$workflow_run_id" ]; then
    mirror_note "$work_root" "workflow_run_id" "$workflow_run_id"
  fi

  cmd_registry_scaffold "$work_root"
  cmd_prepare_parallel_artifacts "$work_root"
  cmd_clone_iac_repo "$work_root" "$repo_url" "$default_branch"
  cmd_sync_groups_to_repo "$work_root"
  cmd_commit_pr "$work_root" "$repo_url" "$default_branch" "$workflow_run_id"
  echo "iac_pr_fast_path=true"
  jq -r '"pr_url=\(.pr_url // "")", "iac_pr_url=\(.iac_pr_url // "")", "groups_synced_to_repo=\(.groups_synced_to_repo // "0")"' \
    "${work_root}/notes.json"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    preflight) cmd_preflight "$@" ;;
    download-state) cmd_download_state "$@" ;;
    discover-anchors) cmd_discover_anchors "$@" ;;
    allocate-manifest) cmd_allocate_manifest "$@" ;;
    extract-group-states) cmd_extract_group_states "$@" ;;
    split-manifest) cmd_split_manifest "$@" ;;
    ingest-and-split) cmd_ingest_and_split "$@" ;;
    emit-ingest-handoff) emit_ingest_handoff_summary "${1:?WORK_ROOT}" ;;
    count-reconcile) cmd_count_reconcile "$@" ;;
    verify-script-pack)
      local work_root="${1:?WORK_ROOT}"
      emit_script_pack_verify "$work_root"
      ;;
    cleanup-old-runs) cmd_cleanup_old_runs "${1:-${WORK_ROOT:-}}" "${2:-${HOME:-/home/runner}}" "${3:-$DBSPLIT_RUN_TTL_HOURS}" ;;
    mark-run-complete) mark_run_complete "${1:?WORK_ROOT}" ;;
    clone-iac-repo) cmd_clone_iac_repo "$@" ;;
    azure-source-fetch) cmd_azure_source_fetch "$@" ;;
    registry-scaffold) cmd_registry_scaffold "$@" ;;
    sync-groups-to-repo) cmd_sync_groups_to_repo "$@" ;;
    commit-pr) cmd_commit_pr "$@" ;;
    iac-pr-pipeline) cmd_iac_pr_pipeline "$@" ;;
    prepare-parallel-artifacts) cmd_prepare_parallel_artifacts "$@" ;;
    hydrate-and-plan-matrix) cmd_hydrate_and_plan_matrix "$@" ;;
    sync-hydrated-iac-pr) cmd_sync_hydrated_iac_pr "$@" ;;
    azure-migration-blueprint) cmd_azure_migration_blueprint "$@" ;;
    azure-iac-generate) cmd_azure_iac_generate "$@" ;;
    azure-iac-harden) cmd_azure_iac_harden "$@" ;;
    azure-iac-governance-conform) cmd_azure_iac_governance_conform "$@" ;;
    azure-iac-validate) cmd_azure_iac_validate "$@" ;;
    azure-pr) cmd_azure_pr "$@" ;;
    gcp-source-fetch) cmd_gcp_source_fetch "$@" ;;
    gcp-migration-blueprint) cmd_gcp_migration_blueprint "$@" ;;
    gcp-iac-generate) cmd_gcp_iac_generate "$@" ;;
    gcp-iac-harden) cmd_gcp_iac_harden "$@" ;;
    gcp-iac-governance-conform) cmd_gcp_iac_governance_conform "$@" ;;
    gcp-iac-validate) cmd_gcp_iac_validate "$@" ;;
    gcp-pr) cmd_gcp_pr "$@" ;;
    *)
      echo "usage: …|azure-iac-generate|azure-iac-harden|azure-iac-governance-conform|azure-iac-validate|azure-pr|gcp-source-fetch|gcp-migration-blueprint|gcp-iac-generate|gcp-iac-harden|gcp-iac-governance-conform|gcp-iac-validate|gcp-pr WORK_ROOT ..." >&2
      exit 2
      ;;
  esac
}

main "$@"
