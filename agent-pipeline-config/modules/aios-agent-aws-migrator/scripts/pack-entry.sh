#!/usr/bin/env bash
# Tiny release-asset entrypoint. Stage notes curl|bash this instead of pasting the
# multi-KB fetch bootstrap (agents invent checks like script_pack_dir_missing).
set -euo pipefail

PACK_VER="${PACK_VER:-__SCRIPT_PACK_VERSION__}"
PACK_REPO="${PACK_REPO:-Walmart-StackGen/Nile-Factory}"
PRELOAD_DIR="${PRELOAD_DIR:-/opt/aws-migrator/script-pack/${PACK_VER}}"
PACK_URL="${PACK_URL:-https://github.com/${PACK_REPO}/releases/download/pack-${PACK_VER}/script-pack-${PACK_VER}.tar.gz}"

usage() {
  echo "usage: pack-entry.sh preflight <workflow_run_id>" >&2
  echo "       pack-entry.sh scan <workflow_run_id> <aws_region> [exclude_csv]" >&2
  echo "       pack-entry.sh ingest <workflow_run_id>" >&2
  echo "       pack-entry.sh iac-pr <workflow_run_id>" >&2
  echo "       pack-entry.sh converge <workflow_run_id>" >&2
  echo "       pack-entry.sh destination <stage> <workflow_run_id>" >&2
  exit 2
}

install_git_cred_helper() {
  local tok cred_dir
  tok="${GIT_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-${token:-}}}}"
  [ -n "$tok" ] || return 0
  export GIT_TOKEN="$tok" GH_TOKEN="${GH_TOKEN:-$tok}" GITHUB_TOKEN="${GITHUB_TOKEN:-$tok}" GIT_TERMINAL_PROMPT=0
  cred_dir="${HOME:-/home/runner}/.aws-migrator/bin"
  mkdir -p "$cred_dir"
  # Publish atomically: concurrent runner sessions share HOME, so readers must
  # never observe a partial helper script. Do not mutate ~/.gitconfig here.
  local helper_tmp
  helper_tmp="$(mktemp "${cred_dir}/.git-credential-stackgen.XXXXXX")"
  cat >"${helper_tmp}" <<'GCEOF'
#!/bin/sh
case "$1" in
get)
  tok="${GIT_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-${token:-}}}}"
  [ -n "$tok" ] || exit 0
  printf "username=x-access-token\npassword=%s\n" "$tok"
  ;;
esac
GCEOF
  chmod 0755 "${helper_tmp}"
  mv -f "${helper_tmp}" "${cred_dir}/git-credential-stackgen"
  # GIT_CONFIG_COUNT scopes this setting to this process tree (git + gh's git
  # subprocesses), avoiding the runner-wide .gitconfig lock shared by workflows.
  local config_count="${GIT_CONFIG_COUNT:-0}"
  case "$config_count" in ''|*[!0-9]*) config_count=0 ;; esac
  export "GIT_CONFIG_KEY_${config_count}=credential.helper"
  export "GIT_CONFIG_VALUE_${config_count}=${cred_dir}/git-credential-stackgen"
  export GIT_CONFIG_COUNT="$((config_count + 1))"
}

ensure_pack() {
  local tok tmp
  tok="${GIT_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-${token:-}}}}"
  if [ -n "$tok" ]; then
    export GIT_TOKEN="$tok" GH_TOKEN="${GH_TOKEN:-$tok}" GITHUB_TOKEN="${GITHUB_TOKEN:-$tok}"
  fi

  if [ -f "${PRELOAD_DIR}/runner-capability-preflight.sh" ] \
    && [ -f "${PRELOAD_DIR}/cloud2code-aws-scan.sh" ] \
    && [ -f "${PRELOAD_DIR}/ingest-bootstrap.sh" ] \
    && [ -f "${PRELOAD_DIR}/iac-pr-bootstrap.sh" ] \
    && [ -f "${PRELOAD_DIR}/converge-bootstrap.sh" ] \
    && [ -f "${PRELOAD_DIR}/run-destination-stage.sh" ]; then
    echo "script_pack_already_present path=${PRELOAD_DIR} version=${PACK_VER}"
    return 0
  fi

  if [ -z "$tok" ]; then
    echo "script_pack_error=fetch_missing_token path=${PRELOAD_DIR} version=${PACK_VER}" >&2
    exit 1
  fi
  tmp="$(mktemp -d)"
  if command -v gh >/dev/null 2>&1; then
    gh release download "pack-${PACK_VER}" -R "${PACK_REPO}" -p "script-pack-${PACK_VER}.tar.gz" -D "${tmp}"
  else
    curl -fsSL -H "Authorization: Bearer ${tok}" -H "Accept: application/octet-stream" \
      "${PACK_URL}" -o "${tmp}/script-pack-${PACK_VER}.tar.gz"
  fi
  mkdir -p "${PRELOAD_DIR}"
  tar -xzf "${tmp}/script-pack-${PACK_VER}.tar.gz" -C "${PRELOAD_DIR}"
  chmod +x "${PRELOAD_DIR}"/*.sh 2>/dev/null || true
  rm -rf "${tmp}"
  if [ ! -f "${PRELOAD_DIR}/runner-capability-preflight.sh" ] \
    || [ ! -f "${PRELOAD_DIR}/cloud2code-aws-scan.sh" ] \
    || [ ! -f "${PRELOAD_DIR}/ingest-bootstrap.sh" ] \
    || [ ! -f "${PRELOAD_DIR}/iac-pr-bootstrap.sh" ] \
    || [ ! -f "${PRELOAD_DIR}/converge-bootstrap.sh" ] \
    || [ ! -f "${PRELOAD_DIR}/run-destination-stage.sh" ]; then
    echo "script_pack_error=fetch_incomplete path=${PRELOAD_DIR} version=${PACK_VER}" >&2
    ls -la "${PRELOAD_DIR}" >&2 || true
    exit 1
  fi
  echo "script_pack_fetch=ok path=${PRELOAD_DIR} version=${PACK_VER}"
}

cmd="${1:-}"
shift || true

ensure_pack
install_git_cred_helper

case "$cmd" in
  preflight)
    exec bash "${PRELOAD_DIR}/runner-capability-preflight.sh" "${1:-}"
    ;;
  scan)
    export CLOUD2CODE_INCLUDE="${CLOUD2CODE_INCLUDE:-}"
    # The scan one-liner passes requested excludes as argv 3. Ignoring it made
    # "Exclude aws_glue_catalog_table" a no-op and the default catalog exclude
    # ran instead.
    _scan_exclude="${3:-}"
    case "${_scan_exclude}" in
      ''|CLOUD2CODE_EXCLUDE_PLACEHOLDER) ;;
      *)
        if [ -z "${CLOUD2CODE_EXCLUDE:-}" ]; then
          export CLOUD2CODE_EXCLUDE="${_scan_exclude}"
        fi
        ;;
    esac
    export CLOUD2CODE_EXCLUDE="${CLOUD2CODE_EXCLUDE:-}"
    export CLOUD2CODE_TAGS="${CLOUD2CODE_TAGS:-}"
    export CLOUD2CODE_ALLOW_PARTIAL="${CLOUD2CODE_ALLOW_PARTIAL:-}"
    # Stage paste sets timeout_seconds=3600. Wait for the detached import inside
    # that call so the scan loop sees scan_ok or a real blocker, not "running".
    if [ -z "${CLOUD2CODE_SCAN_CALL_BUDGET_SECONDS:-}" ]; then
      export CLOUD2CODE_SCAN_CALL_BUDGET_SECONDS=3500
    fi
    export WORKFLOW_RUN_ID="${1:-${WORKFLOW_RUN_ID:-}}"
    export AWS_REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
    export AWS_DEFAULT_REGION="${AWS_REGION}"
    if [ -f "${PRELOAD_DIR}/cloud2code-scan-detach.sh" ]; then
      exec bash "${PRELOAD_DIR}/cloud2code-scan-detach.sh" "${WORKFLOW_RUN_ID}" "${AWS_REGION}"
    fi
    exec bash "${PRELOAD_DIR}/cloud2code-aws-scan.sh" "${WORKFLOW_RUN_ID}" "${AWS_REGION}"
    ;;
  ingest)
    export WORKFLOW_RUN_ID="${1:-${WORKFLOW_RUN_ID:-}}"
    export DBSPLIT_EMBEDDED=1
    exec bash "${PRELOAD_DIR}/ingest-bootstrap.sh"
    ;;
  iac-pr)
    export WORKFLOW_RUN_ID="${1:-${WORKFLOW_RUN_ID:-}}"
    export DBSPLIT_EMBEDDED=1
    exec bash "${PRELOAD_DIR}/iac-pr-bootstrap.sh"
    ;;
  converge)
    export WORKFLOW_RUN_ID="${1:-${WORKFLOW_RUN_ID:-}}"
    export DBSPLIT_EMBEDDED=1
    exec bash "${PRELOAD_DIR}/converge-bootstrap.sh"
    ;;
  destination)
    # Azure/GCP destination stages. Env (SOURCE_PR, SOURCE_IAC_BRANCH, …) is set by
    # the execute_series one-liner before pack-entry runs. Self-heals when the ACA
    # image still has an older /opt pack (session 55e77bfd: only 20260911.8 present).
    stage="${1:-}"
    wf="${2:-${WORKFLOW_RUN_ID:-}}"
    if [ -z "$stage" ] || [ -z "$wf" ]; then
      usage
    fi
    export WORKFLOW_RUN_ID="$wf"
    export DBSPLIT_EMBEDDED="${DBSPLIT_EMBEDDED:-1}"
    exec bash "${PRELOAD_DIR}/run-destination-stage.sh" "$stage" "$wf"
    ;;
  *)
    usage
    ;;
esac
