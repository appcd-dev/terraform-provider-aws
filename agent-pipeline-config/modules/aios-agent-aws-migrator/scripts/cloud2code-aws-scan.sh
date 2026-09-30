#!/usr/bin/env bash
set -euo pipefail

# Args: $1 = workflow_run_id; $2 = aws_region (optional but recommended)
# Agents sometimes paste the literal '{{workflow_run_id}}' token when Guild does
# not expand it inside execute_series (session b2177674). Prefer a real id from
# argv, then WORKFLOW_RUN_ID, and refuse brace placeholders so the work root is
# never '/home/runner/.{{workflow_run_id}}'.
WF_ID_ARG="${1:-}"
AWS_REGION_ARG="${2:-}"

RUNNER_WORK_HOME="${RUNNER_WORK_HOME:-/home/runner}"
SCRIPT_PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflow-run-id.sh
. "${SCRIPT_PACK_DIR}/workflow-run-id.sh"

export HOME="$RUNNER_WORK_HOME"

if ! WF_ID="$(resolve_workflow_run_id "$WF_ID_ARG")"; then
  echo 'blocked:cloud2code_workflow_run_id_unresolved: "true"'
  echo "cloud2code_workflow_run_id_arg=${WF_ID_ARG:-<empty>}"
  echo "hint=replace {{workflow_run_id}} with the real id from the stagerunner [Workflow execution] header (e.g. wf-aws-cloud-discovery-…), or export WORKFLOW_RUN_ID before the scan"
  exit 1
fi
export WORKFLOW_RUN_ID="$WF_ID"

ABS_WORK_ROOT="${RUNNER_WORK_HOME}/.${WF_ID}"
WORK_ROOT="$ABS_WORK_ROOT"
INPUT_JSON="$WORK_ROOT/.work/cloud2code-inputs.json"
NOTES_JSON="$WORK_ROOT/notes.json"

mkdir -p "$WORK_ROOT/.work" "$WORK_ROOT/cloud2code" "$WORK_ROOT/state"
chmod 700 "$WORK_ROOT" 2>/dev/null || true
[ -f "$NOTES_JSON" ] || echo '{}' >"$NOTES_JSON"
echo "cloud2code_workflow_run_id=$WF_ID"
echo "cloud2code_work_root=$WORK_ROOT"

# Merge the region in, never rewrite the file: cloud2code_include / _exclude /
# _tags may already be there and a full rewrite silently widens the scan.
if [ -n "$AWS_REGION_ARG" ]; then
  if command -v jq >/dev/null 2>&1; then
    _merged="$(mktemp "${INPUT_JSON}.XXXXXX")"
    if [ -s "$INPUT_JSON" ] && jq --arg r "$AWS_REGION_ARG" '. + {aws_region: $r}' "$INPUT_JSON" >"$_merged" 2>/dev/null; then
      mv "$_merged" "$INPUT_JSON"
    else
      rm -f "$_merged"
      jq -n --arg r "$AWS_REGION_ARG" '{aws_region: $r}' >"$INPUT_JSON"
    fi
  else
    printf '{"aws_region":"%s"}\n' "$AWS_REGION_ARG" >"$INPUT_JSON"
  fi
fi

mirror_note() {
  local key="${1:?KEY}"
  local value="${2:-}"
  local tmp
  tmp="$(mktemp "${NOTES_JSON}.XXXXXX")"
  jq --arg k "$key" --arg v "$value" '. + {($k): $v}' "$NOTES_JSON" >"$tmp" \
    && mv "$tmp" "$NOTES_JSON"
}

read_input() {
  local key="${1:?KEY}"
  [ -f "$INPUT_JSON" ] || return 0
  jq -r --arg k "$key" '.[$k] // empty' "$INPUT_JSON" 2>/dev/null || true
}

read_note() {
  local key="${1:?KEY}"
  jq -r --arg k "$key" '.[$k] // empty' "$NOTES_JSON" 2>/dev/null || true
}

coalesce_value() {
  local key="${1:?KEY}"
  local env_key="${2:-}"
  local value=""
  value="$(read_input "$key")"
  if [ -z "$value" ]; then
    value="$(read_note "$key")"
  fi
  if [ -z "$value" ] && [ -n "$env_key" ]; then
    value="$(printenv "$env_key" 2>/dev/null || true)"
  fi
  printf '%s' "$value"
}

AWS_REGION="$(coalesce_value aws_region AWS_REGION)"
# Tolerate LLM-mangled env aliases (session 32e2ad9f used aws_region= without argv).
if [ -z "$AWS_REGION" ]; then
  AWS_REGION="${aws_region:-${AWS_DEFAULT_REGION:-}}"
fi
CLOUD2CODE_INCLUDE="$(coalesce_value cloud2code_include CLOUD2CODE_INCLUDE)"
CLOUD2CODE_EXCLUDE="$(coalesce_value cloud2code_exclude CLOUD2CODE_EXCLUDE)"
# Default exclude: catalog non_applicable types that never map to Azure/GCP as
# standalone resources (identity humans, Athena, EC2 key pairs, folded attrs).
# Operators may override via cloud2code_exclude / CLOUD2CODE_EXCLUDE.
# An explicit include is already a whitelist, so the default exclude only adds
# a chance of cloud2code rejecting the pair.
if [ -z "$CLOUD2CODE_EXCLUDE" ] && [ -z "$CLOUD2CODE_INCLUDE" ]; then
  CLOUD2CODE_EXCLUDE="aws_athena_workgroup,aws_cloudfront_origin_access_identity,aws_db_parameter_group,aws_iam_access_key,aws_iam_account_alias,aws_iam_account_password_policy,aws_iam_group,aws_iam_group_membership,aws_iam_group_policy,aws_iam_group_policy_attachment,aws_iam_openid_connect_provider,aws_iam_saml_provider,aws_iam_server_certificate,aws_iam_user,aws_iam_user_group_membership,aws_iam_user_policy,aws_iam_user_policy_attachment,aws_iam_user_ssh_key,aws_key_pair,aws_route53_resolver_rule_association"
fi
# Drop exclude types cloud2code does not recognize — unsupported --exclude values
# abort the entire import (cloud2code 0.5.x: "type X on Exclude filter: not supported").
if [ -n "$CLOUD2CODE_EXCLUDE" ] && command -v cloud2code >/dev/null 2>&1; then
  _sup_file="$(mktemp)"
  if cloud2code get-supported-resources -c aws >"${_sup_file}" 2>/dev/null; then
    CLOUD2CODE_EXCLUDE="$(
      printf '%s' "$CLOUD2CODE_EXCLUDE" | tr ',' '\n' | while IFS= read -r _t; do
        _t="$(printf '%s' "${_t}" | tr -d '[:space:]')"
        [ -z "${_t}" ] && continue
        if grep -Eq "^ - ${_t}\$" "${_sup_file}"; then
          printf '%s\n' "${_t}"
        else
          echo "cloud2code_exclude_skipped_unsupported=${_t}" >&2
        fi
      done | paste -sd, -
    )"
  fi
  rm -f "${_sup_file}"
fi
CLOUD2CODE_TAGS="$(coalesce_value cloud2code_tags CLOUD2CODE_TAGS)"
CLOUD2CODE_ALLOW_PARTIAL="$(coalesce_value cloud2code_allow_partial CLOUD2CODE_ALLOW_PARTIAL)"
CLOUD2CODE_MIN_COVERAGE_PERCENT="$(coalesce_value cloud2code_min_coverage_percent CLOUD2CODE_MIN_COVERAGE_PERCENT)"
CLOUD2CODE_MIN_COVERAGE_PERCENT="${CLOUD2CODE_MIN_COVERAGE_PERCENT:-90}"
if ! [[ "$CLOUD2CODE_MIN_COVERAGE_PERCENT" =~ ^[0-9]+$ ]] || [ "$CLOUD2CODE_MIN_COVERAGE_PERCENT" -lt 1 ] || [ "$CLOUD2CODE_MIN_COVERAGE_PERCENT" -gt 100 ]; then
  echo "blocked:cloud2code_min_coverage_percent_invalid value=${CLOUD2CODE_MIN_COVERAGE_PERCENT}"
  exit 1
fi
# Discovery should preserve accessible resources when individual reads are
# denied. Cloud2Code marks these inventories partial; downstream stages must
# retain that caveat rather than treating skipped reads as complete coverage.
# An explicit false remains available for operators who require a complete scan.
case "$CLOUD2CODE_ALLOW_PARTIAL" in
  "" ) CLOUD2CODE_ALLOW_PARTIAL=true ;;
  false|0|no) CLOUD2CODE_ALLOW_PARTIAL=false ;;
  true|1|yes) CLOUD2CODE_ALLOW_PARTIAL=true ;;
  *) echo "blocked:cloud2code_allow_partial_invalid value=${CLOUD2CODE_ALLOW_PARTIAL}"; exit 1 ;;
esac
CLOUD2CODE_OUTPUT_DIR="$(coalesce_value cloud2code_output_dir CLOUD2CODE_OUTPUT_DIR)"
CLOUD2CODE_DISCOVERY_NAME="$(coalesce_value cloud2code_discovery_name CLOUD2CODE_DISCOVERY_NAME)"
IAC_REPOSITORY_URL="$(coalesce_value iac_repository_url IAC_REPOSITORY_URL)"
if [ -z "$IAC_REPOSITORY_URL" ]; then
  IAC_REPOSITORY_URL="$(coalesce_value iac_repo_url IAC_REPO_URL)"
fi
if [ -z "$IAC_REPOSITORY_URL" ]; then
  IAC_REPOSITORY_URL="https://github.com/Walmart-StackGen/Nile-Factory.git"
fi
DEFAULT_BRANCH="$(coalesce_value default_branch DEFAULT_BRANCH)"
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="main"
fi
GROUPING_STRATEGY="$(coalesce_value grouping_strategy GROUPING_STRATEGY)"
MAX_RESOURCES_PER_APPSTACK="$(coalesce_value max_resources_per_appstack MAX_RESOURCES_PER_APPSTACK)"
TFSTATE_DECOMPOSER_ENV_SCOPE="$(coalesce_value tfstate_decomposer_env_scope TFSTATE_DECOMPOSER_ENV_SCOPE)"
TFSTATE_DECOMPOSER_ENV_TAG_KEYS="$(coalesce_value tfstate_decomposer_env_tag_keys TFSTATE_DECOMPOSER_ENV_TAG_KEYS)"
TFSTATE_DECOMPOSER_LAYER3_TAG_KEYS="$(coalesce_value tfstate_decomposer_layer3_tag_keys TFSTATE_DECOMPOSER_LAYER3_TAG_KEYS)"
TFSTATE_DECOMPOSER_SKIP_UNKNOWN_TYPE_REVIEW="$(coalesce_value tfstate_decomposer_skip_unknown_type_review TFSTATE_DECOMPOSER_SKIP_UNKNOWN_TYPE_REVIEW)"
TFSTATE_DECOMPOSER_OVERRIDES_JSON="$(coalesce_value tfstate_decomposer_overrides_json TFSTATE_DECOMPOSER_OVERRIDES_JSON)"
TFSTATE_DECOMPOSER_OVERRIDES_PATH="$(coalesce_value tfstate_decomposer_overrides_path TFSTATE_DECOMPOSER_OVERRIDES_PATH)"
TFSTATE_DECOMPOSER_LAYER_TAXONOMY_JSON="$(coalesce_value tfstate_decomposer_layer_taxonomy_json TFSTATE_DECOMPOSER_LAYER_TAXONOMY_JSON)"
TFSTATE_DECOMPOSER_MAX_TUNING_ITERATIONS="$(coalesce_value tfstate_decomposer_max_tuning_iterations TFSTATE_DECOMPOSER_MAX_TUNING_ITERATIONS)"

CLOUD2CODE_AUTO_IMPORT="false"

if [ -z "$AWS_REGION" ]; then
  mirror_note "blocked:missing_aws_region" "true"
  mirror_note "stage_summary:cloud2code-scan-aws" "blocked:missing_aws_region"
  echo 'blocked:missing_aws_region: "true"'
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  mirror_note "blocked:remote_runner_jq_missing" "true"
  mirror_note "stage_summary:cloud2code-scan-aws" "blocked:jq_missing"
  echo 'blocked:remote_runner_jq_missing: "true"'
  exit 1
fi

# Install lives in runner-capability-preflight; scan verifies and can re-ensure.
if [ -f "$SCRIPT_PACK_DIR/ensure_cloud2code.sh" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_PACK_DIR/ensure_cloud2code.sh"
  if ! ensure_cloud2code; then
    mirror_note "blocked:remote_runner_cloud2code_version_unavailable" "true"
    echo 'blocked:remote_runner_cloud2code_version_unavailable: "true"'
    exit 1
  fi
fi

if ! command -v cloud2code >/dev/null 2>&1; then
  mirror_note "blocked:remote_runner_cloud2code_missing" "true"
  mirror_note "stage_summary:cloud2code-scan-aws" "blocked:cloud2code_missing"
  echo 'blocked:remote_runner_cloud2code_missing: "true"'
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  mirror_note "blocked:remote_runner_awscli_missing" "true"
  mirror_note "stage_summary:cloud2code-scan-aws" "blocked:awscli_missing"
  echo 'blocked:remote_runner_awscli_missing: "true"'
  exit 1
fi

if [ -z "$CLOUD2CODE_OUTPUT_DIR" ]; then
  CLOUD2CODE_OUTPUT_DIR="$WORK_ROOT/cloud2code/aws-$AWS_REGION"
fi
mkdir -p "$CLOUD2CODE_OUTPUT_DIR"

aws sts get-caller-identity >"$WORK_ROOT/.work/aws-caller-identity.json" 2>"$WORK_ROOT/.work/aws-sts.err" \
  && {
    mirror_note "aws_caller_identity_path" "$WORK_ROOT/.work/aws-caller-identity.json"
    _account_id="$(jq -r '.Account // empty' "$WORK_ROOT/.work/aws-caller-identity.json" 2>/dev/null || true)"
    [ -n "$_account_id" ] && mirror_note "aws_account_id" "$_account_id"
    echo "aws_caller_identity=$(tr -d '\n' <"$WORK_ROOT/.work/aws-caller-identity.json")"
  } \
  || {
    mirror_note "aws_caller_identity_probe" "skipped_or_denied"
    echo "aws_caller_identity_probe=skipped_or_denied"
    if [ -s "$WORK_ROOT/.work/aws-sts.err" ]; then
      echo "aws_sts_err=$(tr '\n' ' ' <"$WORK_ROOT/.work/aws-sts.err")"
    fi
  }

# Build and run the import. Each attempt uses a clean output directory so a
# failed/partial tfstate cannot leak into a later successful attempt.
run_cloud2code_import() {
  rm -f "$CLOUD2CODE_OUTPUT_DIR/terraform.tfstate"
  export CLOUD2CODE_OUTPUT_DIR
  local -a cmd=(cloud2code --log-type=json import aws --region "$AWS_REGION" --output-dir "$CLOUD2CODE_OUTPUT_DIR" "--auto-import=$CLOUD2CODE_AUTO_IMPORT")
  if [ -n "$CLOUD2CODE_DISCOVERY_NAME" ]; then
    cmd+=(--name "$CLOUD2CODE_DISCOVERY_NAME")
  fi
  if [ -n "$CLOUD2CODE_TAGS" ]; then
    cmd+=(--tags "$CLOUD2CODE_TAGS")
  fi
  if [ -n "$CLOUD2CODE_INCLUDE" ]; then
    cmd+=(--include "$CLOUD2CODE_INCLUDE")
  fi
  if [ -n "$CLOUD2CODE_EXCLUDE" ]; then
    cmd+=(--exclude "$CLOUD2CODE_EXCLUDE")
  fi
  if [ "$CLOUD2CODE_ALLOW_PARTIAL" = true ]; then
    cmd+=(--allow-partial)
  fi
  # Keep structured permission_skipped events in the log consumed by the PR
  # report, even if a runner-wide CLOUD2CODE_LOG_TYPE override is configured.
  printf '%q ' "${cmd[@]}" >"$WORK_ROOT/.work/cloud2code-command.txt"
  echo >>"$WORK_ROOT/.work/cloud2code-command.txt"
  "${cmd[@]}" >"$WORK_ROOT/.work/cloud2code.log" 2>&1
}

scan_has_nonretryable_read_failures() {
  grep -Eqi 'could not import from aws: scan incomplete' "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null &&
    grep -Eq 'scan integrity: listed=[0-9]+ imported=[0-9]+ import_state_skipped=[0-9]+ read_skipped=[0-9]+ read_failed=[1-9][0-9]* throttled_types=0([[:space:]]|$)' "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null &&
    ! grep -qiE 'ThrottlingException|Throttling: Rate exceeded|RequestLimitExceeded|provider API rate limited|scan aborted due to API rate limiting' "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null
}

extract_read_failed_types() {
  # cloud2code: "type aws_alb listed=33 imported=0 ... read_failed=33"
  grep -Eo 'type aws_[a-z0-9_]+ listed=[0-9]+ imported=0[^[:space:]]* read_failed=[1-9][0-9]*' \
    "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null \
    | sed -E 's/^type (aws_[a-z0-9_]+) .*/\1/' \
    | sort -u \
    | paste -sd, -
}

CMD_OK=0
# Do not carry partial status from an earlier stage retry in the same workflow.
mirror_note "cloud2code_throttle_skipped" ""
THROTTLE_SKIPPED=""
run_cloud2code_import && CMD_OK=1 || CMD_OK=0
if [ "$CMD_OK" -ne 1 ]; then
  # Cloud2Code can exit nonzero after writing a valid partial state for read
  # failures. Only accept that artifact when its explicit counters satisfy the
  # configured coverage floor; never infer partial success from a log alone.
  if scan_has_nonretryable_read_failures; then
    echo "cloud2code_nonzero_with_read_failures=true"
  else
    # Retry throttling once; other nonzero exits remain fatal. Repeated
    # throttling is never treated as success or hidden by excluding a type.
    _throttle_type="$(grep -Eo 'scan aborted due to API rate limiting: error while reading the resources of type: [a-z0-9_]+' "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null | grep -Eo 'aws_[a-z0-9_]+' | tail -1 || true)"
    if [ -z "$_throttle_type" ]; then
      _throttle_type="$(grep -iE 'ThrottlingException|Throttling: Rate exceeded|RequestLimitExceeded' "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null | grep -Eo 'aws_[a-z0-9_]+' | tail -1 || true)"
    fi
    if [ -n "$_throttle_type" ]; then
      echo "cloud2code_throttle_detected=${_throttle_type}"
      mirror_note "cloud2code_throttle_detected" "${_throttle_type}"
      _backoff="${CLOUD2CODE_THROTTLE_BACKOFF_SECONDS:-60}"
      echo "cloud2code_throttle_backoff=${_backoff}s"
      sleep "$_backoff"
      run_cloud2code_import && CMD_OK=1 || CMD_OK=0
      if [ "$CMD_OK" -ne 1 ] && grep -qiE 'ThrottlingException|Throttling: Rate exceeded|RequestLimitExceeded|provider API rate limited' "$WORK_ROOT/.work/cloud2code.log"; then
        _retry_throttle_type="$(grep -Eo 'scan aborted due to API rate limiting: error while reading the resources of type: [a-z0-9_]+' "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null | grep -Eo 'aws_[a-z0-9_]+' | tail -1 || true)"
        [ -n "$_retry_throttle_type" ] && _throttle_type="$_retry_throttle_type"
        THROTTLE_SKIPPED="${THROTTLE_SKIPPED:+${THROTTLE_SKIPPED},}${_throttle_type}"
        mirror_note "cloud2code_throttle_skipped" "$THROTTLE_SKIPPED"
        echo "cloud2code_throttle_softskip=${_throttle_type}"
        if [ "$CLOUD2CODE_ALLOW_PARTIAL" = true ]; then
          if [ -n "$CLOUD2CODE_EXCLUDE" ]; then
            CLOUD2CODE_EXCLUDE="${CLOUD2CODE_EXCLUDE},${_throttle_type}"
          else
            CLOUD2CODE_EXCLUDE="${_throttle_type}"
          fi
          CLOUD2CODE_EXCLUDE="$(printf '%s' "$CLOUD2CODE_EXCLUDE" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)"
          echo "cloud2code_exclude_after_throttle=${CLOUD2CODE_EXCLUDE}"
          mirror_note "cloud2code_exclude" "$CLOUD2CODE_EXCLUDE"
          run_cloud2code_import && CMD_OK=1 || CMD_OK=0
        fi
      fi
    fi
  fi
fi

mirror_note "cloud2code_command_path" "$WORK_ROOT/.work/cloud2code-command.txt"
mirror_note "aws_region" "$AWS_REGION"
mirror_note "cloud2code_auto_import" "$CLOUD2CODE_AUTO_IMPORT"
mirror_note "cloud2code_output_dir" "$CLOUD2CODE_OUTPUT_DIR"
mirror_note "cloud2code_min_coverage_percent" "$CLOUD2CODE_MIN_COVERAGE_PERCENT"
mirror_note "cloud2code_partial_failure_accepted" "false"
mirror_note "cloud2code_partial_coverage_percent" ""
if [ -n "$CLOUD2CODE_INCLUDE" ]; then mirror_note "cloud2code_include" "$CLOUD2CODE_INCLUDE"; fi
if [ -n "$CLOUD2CODE_EXCLUDE" ]; then mirror_note "cloud2code_exclude" "$CLOUD2CODE_EXCLUDE"; fi
if [ -n "$CLOUD2CODE_TAGS" ]; then mirror_note "cloud2code_tags" "$CLOUD2CODE_TAGS"; fi
if [ -n "$IAC_REPOSITORY_URL" ]; then mirror_note "iac_repository_url" "$IAC_REPOSITORY_URL"; fi
if [ -n "$DEFAULT_BRANCH" ]; then mirror_note "default_branch" "$DEFAULT_BRANCH"; fi
if [ -n "$GROUPING_STRATEGY" ]; then mirror_note "grouping_strategy" "$GROUPING_STRATEGY"; fi
if [ -n "$MAX_RESOURCES_PER_APPSTACK" ]; then mirror_note "max_resources_per_appstack" "$MAX_RESOURCES_PER_APPSTACK"; fi
if [ -n "$TFSTATE_DECOMPOSER_ENV_SCOPE" ]; then mirror_note "tfstate_decomposer_env_scope" "$TFSTATE_DECOMPOSER_ENV_SCOPE"; fi
if [ -n "$TFSTATE_DECOMPOSER_ENV_TAG_KEYS" ]; then mirror_note "tfstate_decomposer_env_tag_keys" "$TFSTATE_DECOMPOSER_ENV_TAG_KEYS"; fi
if [ -n "$TFSTATE_DECOMPOSER_LAYER3_TAG_KEYS" ]; then mirror_note "tfstate_decomposer_layer3_tag_keys" "$TFSTATE_DECOMPOSER_LAYER3_TAG_KEYS"; fi
if [ -n "$TFSTATE_DECOMPOSER_SKIP_UNKNOWN_TYPE_REVIEW" ]; then mirror_note "tfstate_decomposer_skip_unknown_type_review" "$TFSTATE_DECOMPOSER_SKIP_UNKNOWN_TYPE_REVIEW"; fi
if [ -n "$TFSTATE_DECOMPOSER_OVERRIDES_JSON" ]; then mirror_note "tfstate_decomposer_overrides_json" "$TFSTATE_DECOMPOSER_OVERRIDES_JSON"; fi
if [ -n "$TFSTATE_DECOMPOSER_OVERRIDES_PATH" ]; then mirror_note "tfstate_decomposer_overrides_path" "$TFSTATE_DECOMPOSER_OVERRIDES_PATH"; fi
if [ -n "$TFSTATE_DECOMPOSER_LAYER_TAXONOMY_JSON" ]; then mirror_note "tfstate_decomposer_layer_taxonomy_json" "$TFSTATE_DECOMPOSER_LAYER_TAXONOMY_JSON"; fi
if [ -n "$TFSTATE_DECOMPOSER_MAX_TUNING_ITERATIONS" ]; then mirror_note "tfstate_decomposer_max_tuning_iterations" "$TFSTATE_DECOMPOSER_MAX_TUNING_ITERATIONS"; fi

PARTIAL_FAILURE_ACCEPTED=false
if [ "$CMD_OK" -ne 1 ] && [ "$CLOUD2CODE_ALLOW_PARTIAL" = true ] && scan_has_nonretryable_read_failures; then
  _integrity="$(grep -Eo 'scan integrity: listed=[0-9]+ imported=[0-9]+ import_state_skipped=[0-9]+ read_skipped=[0-9]+ read_failed=[0-9]+ throttled_types=[0-9]+' "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null | tail -1 || true)"
  if [ -n "$_integrity" ]; then
    read -r _listed _imported _state_skipped _read_skipped _read_failed _throttled <<<"$(printf '%s\n' "$_integrity" | sed -E 's/^scan integrity: listed=([0-9]+) imported=([0-9]+) import_state_skipped=([0-9]+) read_skipped=([0-9]+) read_failed=([0-9]+) throttled_types=([0-9]+)$/\1 \2 \3 \4 \5 \6/')"
    STATE_PATH="$(find "$CLOUD2CODE_OUTPUT_DIR" -maxdepth 5 -type f \( -name 'terraform.tfstate' -o -name '*.tfstate' \) | sort | head -1)"
    if [ "$_listed" -gt 0 ] && [ "$((_imported * 100 / _listed))" -ge "$CLOUD2CODE_MIN_COVERAGE_PERCENT" ] \
      && [ "$_throttled" -eq 0 ] && [ -n "$STATE_PATH" ] && [ -s "$STATE_PATH" ] \
      && jq -e '.resources' "$STATE_PATH" >/dev/null 2>&1; then
      _state_count="$(jq '[.resources[]? | select(.mode=="managed") | .instances[]?] | length' "$STATE_PATH" 2>/dev/null || echo 0)"
      if [ "$_state_count" -eq "$_imported" ] && [ "$_state_count" -gt 0 ]; then
        CMD_OK=1
        PARTIAL_FAILURE_ACCEPTED=true
        echo "cloud2code_partial_failure_accepted=true coverage_percent=$((_imported * 100 / _listed)) minimum_percent=$CLOUD2CODE_MIN_COVERAGE_PERCENT"
        mirror_note "cloud2code_partial_failure_accepted" "true"
        mirror_note "cloud2code_partial_coverage_percent" "$((_imported * 100 / _listed))"
      fi
    fi
  fi
fi

if [ "$CMD_OK" -ne 1 ]; then
  _failed_types="$(extract_read_failed_types || true)"
  [ -n "$_failed_types" ] && echo "cloud2code_read_failed_types=${_failed_types}"
  mirror_note "blocked:cloud2code_scan_failed" "true"
  mirror_note "cloud2code_log_path" "$WORK_ROOT/.work/cloud2code.log"
  mirror_note "stage_summary:cloud2code-scan-aws" "blocked:cloud2code_import_failed"
  echo 'blocked:cloud2code_scan_failed: "true"'
  echo "cloud2code_log_path=$WORK_ROOT/.work/cloud2code.log"
  if grep -qiE 'ThrottlingException|Throttling: Rate exceeded|RequestLimitExceeded|provider API rate limited' "$WORK_ROOT/.work/cloud2code.log"; then
    echo "cloud2code_scan_retryable: \"true\""
  else
    echo "cloud2code_scan_retryable: \"false\""
  fi
  echo "cloud2code_log_tail_begin"
  tail -n 120 "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null || true
  echo "cloud2code_log_tail_end"
  exit 1
fi

STATE_PATH="$(find "$CLOUD2CODE_OUTPUT_DIR" -maxdepth 5 -type f \( -name 'terraform.tfstate' -o -name '*.tfstate' \) | sort | head -1)"
if [ -z "$STATE_PATH" ] || [ ! -s "$STATE_PATH" ]; then
  mirror_note "blocked:cloud2code_tfstate_missing" "true"
  mirror_note "cloud2code_log_path" "$WORK_ROOT/.work/cloud2code.log"
  mirror_note "stage_summary:cloud2code-scan-aws" "blocked:tfstate_missing"
  echo 'blocked:cloud2code_tfstate_missing: "true"'
  exit 1
fi

if ! jq -e '.resources' "$STATE_PATH" >/dev/null 2>&1; then
  mirror_note "blocked:cloud2code_tfstate_invalid" "true"
  mirror_note "cloud2code_tfstate_path" "$STATE_PATH"
  mirror_note "stage_summary:cloud2code-scan-aws" "blocked:tfstate_invalid"
  echo 'blocked:cloud2code_tfstate_invalid: "true"'
  exit 1
fi

MANAGED_COUNT="$(jq '[.resources[]? | select(.mode=="managed") | .instances[]?] | length' "$STATE_PATH" 2>/dev/null || echo 0)"
RESOURCE_TYPE_COUNT="$(jq '[.resources[]? | select(.mode=="managed") | .type] | unique | length' "$STATE_PATH" 2>/dev/null || echo 0)"
if [ "$MANAGED_COUNT" -le 0 ]; then
  mirror_note "blocked:cloud2code_state_empty" "true"
  mirror_note "cloud2code_tfstate_path" "$STATE_PATH"
  echo 'blocked:cloud2code_state_empty: "true"'
  exit 1
fi

THROTTLE_SKIPPED="$(read_note "cloud2code_throttle_skipped")"
# Cloud2Code reports read permissions and other omissions in this integrity
# line. Keep them visible in the workflow result and distinguish a usable
# partial state from a complete inventory.
SCAN_INTEGRITY="$(grep -Eo 'scan integrity: listed=[0-9]+ imported=[0-9]+ import_state_skipped=[0-9]+ read_skipped=[0-9]+ read_failed=[0-9]+ throttled_types=[0-9]+' "$WORK_ROOT/.work/cloud2code.log" 2>/dev/null | tail -1 || true)"
SCAN_PARTIAL=false
if [ -n "$SCAN_INTEGRITY" ]; then
  read -r _listed _imported _state_skipped _read_skipped _read_failed _throttled <<<"$(printf '%s\n' "$SCAN_INTEGRITY" | sed -E 's/^scan integrity: listed=([0-9]+) imported=([0-9]+) import_state_skipped=([0-9]+) read_skipped=([0-9]+) read_failed=([0-9]+) throttled_types=([0-9]+)$/\1 \2 \3 \4 \5 \6/')"
  if [ "$_listed" -gt "$_imported" ] || [ "$_state_skipped" -gt 0 ] || [ "$_read_skipped" -gt 0 ] || [ "$_read_failed" -gt 0 ] || [ "$_throttled" -gt 0 ]; then
    SCAN_PARTIAL=true
  fi
fi
if [ -n "$THROTTLE_SKIPPED" ]; then SCAN_PARTIAL=true; fi
if [ -n "$THROTTLE_SKIPPED" ] || { [ "$CLOUD2CODE_ALLOW_PARTIAL" != true ] && [ "$SCAN_PARTIAL" = true ] && [ "$PARTIAL_FAILURE_ACCEPTED" != true ]; }; then
  mirror_note "blocked:cloud2code_partial_scan" "true"
  mirror_note "cloud2code_partial_resource_types" "$THROTTLE_SKIPPED"
  echo 'blocked:cloud2code_partial_scan: "true"'
  [ -n "$SCAN_INTEGRITY" ] && echo "$SCAN_INTEGRITY"
  echo "cloud2code_partial_resource_types=${THROTTLE_SKIPPED}"
  echo "cloud2code_tfstate_path=$STATE_PATH"
  echo "monolith_resource_count=$MANAGED_COUNT"
  exit 1
fi

if [ "$SCAN_PARTIAL" = true ]; then
  mirror_note "cloud2code_partial_scan" "true"
  mirror_note "cloud2code_scan_integrity" "$SCAN_INTEGRITY"
  echo 'cloud2code_partial_scan: "true"'
  if [ "$PARTIAL_FAILURE_ACCEPTED" = true ]; then
    echo "cloud2code_partial_failure_accepted: \"true\""
    echo "cloud2code_partial_coverage_percent=$((_imported * 100 / _listed))"
    echo "cloud2code_min_coverage_percent=$CLOUD2CODE_MIN_COVERAGE_PERCENT"
    mirror_note "cloud2code_partial_failure_accepted" "true"
    mirror_note "cloud2code_partial_coverage_percent" "$((_imported * 100 / _listed))"
  fi
  if [ -n "$SCAN_INTEGRITY" ]; then echo "$SCAN_INTEGRITY"; fi
  if [ -n "$THROTTLE_SKIPPED" ]; then echo "cloud2code_throttle_skipped=${THROTTLE_SKIPPED}"; fi
else
  mirror_note "cloud2code_partial_scan" "false"
fi

mirror_note "cloud2code_scan_ok" "true"
mirror_note "cloud2code_tfstate_path" "$STATE_PATH"
mirror_note "cloud2code_log_path" "$WORK_ROOT/.work/cloud2code.log"
mirror_note "monolith_state_uri" "$STATE_PATH"
mirror_note "tfstate_file" "$STATE_PATH"
mirror_note "monolith_resource_count" "$MANAGED_COUNT"
mirror_note "cloud2code_resource_type_count" "$RESOURCE_TYPE_COUNT"
mirror_note "stage_summary:cloud2code-scan-aws" "ok"

echo 'cloud2code_scan_ok: "true"'
if [ -n "$THROTTLE_SKIPPED" ]; then
  echo "cloud2code_partial_scan: true"
  echo "cloud2code_throttle_skipped=${THROTTLE_SKIPPED}"
fi
echo "aws_region=$AWS_REGION"
echo "cloud2code_tfstate_path=$STATE_PATH"
echo "monolith_state_uri=$STATE_PATH"
echo "monolith_resource_count=$MANAGED_COUNT"
echo "cloud2code_resource_type_count=$RESOURCE_TYPE_COUNT"
