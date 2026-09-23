#!/usr/bin/env bash
# One-line Guild execute_series entrypoints (same pattern as ingest-bootstrap.sh).
# Avoids LLM pasting BEGIN-marker names as the command
# (session d6e915ee: /bin/sh: GCP_SOURCE_FETCH_EXECUTE_SERIES: not found).
set -euo pipefail

export HOME="${HOME:-/home/runner}"
STAGE="${1:?stage}"
WORKFLOW_RUN_ID="${2:?workflow_run_id}"
WORK_ROOT="${HOME}/.${WORKFLOW_RUN_ID}"
PACK_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORK_ROOT/scripts/mappings" "$WORK_ROOT/.work" "$WORK_ROOT/gcp/artifacts" "$WORK_ROOT/azure/artifacts"
for f in allocate_manifest.py tfstate_monolith_decomposer.py stage-runner.sh \
  azure_mapping_catalog.py azure_iac_generate.py gcp_mapping_catalog.py gcp_iac_generate.py \
  app_iam.py hcl_sanity.py destination_iac_harden.py governance_conform.py governance_opa_check.py; do
  cp -f "${PACK_DIR}/${f}" "${WORK_ROOT}/scripts/${f}"
done
if ! compgen -G "${PACK_DIR}/mappings/"*.json >/dev/null; then
  echo "script_pack_error=missing_mappings dir=${PACK_DIR}/mappings" >&2
  exit 1
fi
cp -f "${PACK_DIR}/mappings/"*.json "${WORK_ROOT}/scripts/mappings/"

export DBSPLIT_EMBEDDED=1
export WORKFLOW_RUN_ID
export IAC_REPOSITORY_URL="${IAC_REPOSITORY_URL:-https://github.com/Walmart-StackGen/Nile-Factory.git}"
export NILE_RULES_REPO="${NILE_RULES_REPO:-$IAC_REPOSITORY_URL}"
# Prefer Nile-Factory main for rules/ Rego packs (PR branches with rules/ are optional overrides).
export NILE_RULES_REF="${NILE_RULES_REF:-main}"
export NILE_GOVERNANCE_REPO="${NILE_GOVERNANCE_REPO:-https://github.com/Walmart-StackGen/Governance-and-Policy.git}"
export NILE_GOVERNANCE_REF="${NILE_GOVERNANCE_REF:-main}"
export SOURCE_IAC_REPOSITORY_URL="${SOURCE_IAC_REPOSITORY_URL:-$IAC_REPOSITORY_URL}"
export DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
export REQUIRE_GCP_LIVE_PLAN="${REQUIRE_GCP_LIVE_PLAN:-1}"
export GCP_LIVE_PLAN_MAX_GROUPS="${GCP_LIVE_PLAN_MAX_GROUPS:-8}"
export REQUIRE_AZURE_LIVE_PLAN="${REQUIRE_AZURE_LIVE_PLAN:-1}"
export AZURE_LIVE_PLAN_MAX_GROUPS="${AZURE_LIVE_PLAN_MAX_GROUPS:-8}"

# Normalize SOURCE_PR from env (one-liner may set SOURCE_PR='34' or a full PR URL).
normalize_source_pr() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  if [ -z "$raw" ] || [ "$raw" = "''" ] || [ "$raw" = '""' ]; then
    printf ''
    return 0
  fi
  if printf '%s' "$raw" | grep -Eq '^[0-9]+$'; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "$raw" | sed -nE 's|.*/pull/([0-9]+).*|\1|p; t; s|.*[#/]([0-9]+)$|\1|p'
}

SOURCE_PR="$(normalize_source_pr "${SOURCE_PR:-}")"
export SOURCE_PR

# Prefer handoff JSON / notes for source_pr and branch overrides.
if [ -f "${WORK_ROOT}/.work/source-handoff-inputs.json" ]; then
  if [ -z "${SOURCE_PR:-}" ]; then
    SOURCE_PR="$(normalize_source_pr "$(jq -r '.source_pr // .source_iac_pr // empty' "${WORK_ROOT}/.work/source-handoff-inputs.json")")"
    export SOURCE_PR
  fi
  if [ -z "${SOURCE_IAC_BRANCH:-}" ]; then
    SOURCE_IAC_BRANCH="$(jq -r '.source_iac_branch // empty' "${WORK_ROOT}/.work/source-handoff-inputs.json")"
    export SOURCE_IAC_BRANCH
  fi
  SOURCE_IAC_REPOSITORY_URL="$(jq -r --arg d "${SOURCE_IAC_REPOSITORY_URL}" '.source_iac_repository_url // .iac_repository_url // $d' "${WORK_ROOT}/.work/source-handoff-inputs.json")"
  export SOURCE_IAC_REPOSITORY_URL
fi
if [ -f "${WORK_ROOT}/notes.json" ]; then
  if [ -z "${SOURCE_PR:-}" ]; then
    SOURCE_PR="$(normalize_source_pr "$(jq -r '.source_pr // .source_iac_pr // empty' "${WORK_ROOT}/notes.json")")"
    export SOURCE_PR
  fi
  if [ -z "${SOURCE_IAC_BRANCH:-}" ]; then
    SOURCE_IAC_BRANCH="$(jq -r '.source_iac_branch // .iac_push_branch // .working_branch // empty' "${WORK_ROOT}/notes.json")"
    export SOURCE_IAC_BRANCH
  fi
  SOURCE_IAC_REPOSITORY_URL="$(jq -r --arg d "${SOURCE_IAC_REPOSITORY_URL}" '.source_iac_repository_url // .iac_repository_url // $d' "${WORK_ROOT}/notes.json")"
  IAC_REPOSITORY_URL="$(jq -r --arg d "${IAC_REPOSITORY_URL}" '.iac_repository_url // $d' "${WORK_ROOT}/notes.json")"
  export SOURCE_IAC_REPOSITORY_URL IAC_REPOSITORY_URL
fi

# Persist handoff into notes before stage-runner so PR resolution does not depend on a prior note() tool call.
if [ -n "${SOURCE_PR:-}" ]; then
  mkdir -p "${WORK_ROOT}/.work"
  if [ -f "${WORK_ROOT}/notes.json" ]; then
    jq --arg p "$SOURCE_PR" '. + {source_pr: $p, source_iac_pr: $p}' "${WORK_ROOT}/notes.json" >"${WORK_ROOT}/notes.json.tmp" \
      && mv "${WORK_ROOT}/notes.json.tmp" "${WORK_ROOT}/notes.json"
  else
    jq -n --arg p "$SOURCE_PR" '{source_pr: $p, source_iac_pr: $p}' >"${WORK_ROOT}/notes.json"
  fi
fi

run_logged_stage() {
  local stage="$1"
  shift
  local log_dir="$WORK_ROOT/.work/logs"
  local log="$log_dir/${stage}.log"
  local rc=0
  mkdir -p "$log_dir"
  bash -s "$stage" "$@" < "${WORK_ROOT}/scripts/stage-runner.sh" >"$log" 2>&1 || rc=$?
  echo "stage_transcript=$log lines=$(wc -l <"$log" | tr -d ' ')"
  echo "--- stage_evidence ---"
  if [ -f "$WORK_ROOT/notes.json" ]; then
    jq -r 'to_entries[]
      | select(.key | test("^(stage_summary:|pr_url$|iac_pr_url$|azure_pr_url$|gcp_pr_url$|working_branch$|azure_working_branch$|gcp_working_branch$|pr_blocker$|iac_push_status$|azure_iac_|azure_source_|azure_migration_|azure_plan_|azure_governance_|gcp_iac_|gcp_source_|gcp_migration_|gcp_plan_|gcp_governance_|source_)"))
      | "\(.key)=\(.value)"' "$WORK_ROOT/notes.json" 2>/dev/null || true
  fi
  echo "stage_exit_code=$rc"
  echo "--- stage_transcript_tail ---"
  grep -Ev '^ create mode |^ delete mode |^ rewrite ' "$log" 2>/dev/null | tail -n 40 | cut -c1-500 || tail -n 40 "$log" | cut -c1-500
  return "$rc"
}

case "$STAGE" in
  gcp-source-fetch)
    run_logged_stage gcp-source-fetch "$WORK_ROOT" "$SOURCE_IAC_REPOSITORY_URL" "${SOURCE_IAC_BRANCH:-}" "$DEFAULT_BRANCH"
    ;;
  gcp-migration-blueprint)
    run_logged_stage gcp-migration-blueprint "$WORK_ROOT"
    ;;
  gcp-iac-generate)
    run_logged_stage gcp-iac-generate "$WORK_ROOT"
    ;;
  gcp-iac-harden)
    run_logged_stage gcp-iac-harden "$WORK_ROOT"
    ;;
  gcp-iac-governance-conform)
    run_logged_stage gcp-iac-governance-conform "$WORK_ROOT"
    ;;
  gcp-iac-validate)
    run_logged_stage gcp-iac-validate "$WORK_ROOT"
    ;;
  gcp-pr)
    run_logged_stage gcp-pr "$WORK_ROOT" "$IAC_REPOSITORY_URL" "$DEFAULT_BRANCH" "$WORKFLOW_RUN_ID"
    ;;
  azure-source-fetch)
    run_logged_stage azure-source-fetch "$WORK_ROOT" "$SOURCE_IAC_REPOSITORY_URL" "${SOURCE_IAC_BRANCH:-}" "$DEFAULT_BRANCH"
    ;;
  azure-migration-blueprint)
    run_logged_stage azure-migration-blueprint "$WORK_ROOT"
    ;;
  azure-iac-generate)
    run_logged_stage azure-iac-generate "$WORK_ROOT"
    ;;
  azure-iac-harden)
    run_logged_stage azure-iac-harden "$WORK_ROOT"
    ;;
  azure-iac-governance-conform)
    run_logged_stage azure-iac-governance-conform "$WORK_ROOT"
    ;;
  azure-iac-validate)
    run_logged_stage azure-iac-validate "$WORK_ROOT"
    ;;
  azure-pr)
    run_logged_stage azure-pr "$WORK_ROOT" "$IAC_REPOSITORY_URL" "$DEFAULT_BRANCH" "$WORKFLOW_RUN_ID"
    ;;
  *)
    echo "unknown stage=$STAGE" >&2
    exit 2
    ;;
esac
