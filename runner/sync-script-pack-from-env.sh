#!/usr/bin/env bash
# Materialize the aws-migrator script pack from mothership-synced env vars.
# aiden-runner injects flat vault metadata keys (SCRIPT_PACK_*) into execute_command
# children; this script downloads the tarball when version or sha gates drift.
set -euo pipefail

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

pack_sha_ok() {
  local dir="$1"
  local actual decomposer_actual runner_actual catalog_py_actual catalog_json_actual
  local gcp_catalog_py_actual gcp_catalog_json_actual

  actual="$(sha256_file "$dir/allocate_manifest.py")"
  decomposer_actual="$(sha256_file "$dir/tfstate_monolith_decomposer.py")"
  runner_actual="$(sha256_file "$dir/stage-runner.sh")"
  catalog_py_actual="$(sha256_file "$dir/azure_mapping_catalog.py")"
  catalog_json_actual="$(sha256_file "$dir/mappings/aws-to-azure.json")"
  gcp_catalog_py_actual="$(sha256_file "$dir/gcp_mapping_catalog.py")"
  gcp_catalog_json_actual="$(sha256_file "$dir/mappings/aws-to-gcp.json")"

  [ "$actual" = "${SCRIPT_PACK_ALLOCATE_SHA256:-}" ] \
    && [ "$decomposer_actual" = "${SCRIPT_PACK_DECOMPOSER_SHA256:-}" ] \
    && [ "$runner_actual" = "${SCRIPT_PACK_RUNNER_SHA256:-}" ] \
    && [ "$catalog_py_actual" = "${SCRIPT_PACK_CATALOG_PY_SHA256:-}" ] \
    && [ "$catalog_json_actual" = "${SCRIPT_PACK_CATALOG_JSON_SHA256:-}" ] \
    && [ "$gcp_catalog_py_actual" = "${SCRIPT_PACK_GCP_CATALOG_PY_SHA256:-}" ] \
    && [ "$gcp_catalog_json_actual" = "${SCRIPT_PACK_GCP_CATALOG_JSON_SHA256:-}" ]
}

VERSION="${SCRIPT_PACK_VERSION:-}"
PRELOAD_DIR="${SCRIPT_PACK_PRELOAD_DIR:-}"
URL="${SCRIPT_PACK_TARBALL_URL:-}"

if [ -z "$VERSION" ] || [ -z "$PRELOAD_DIR" ] || [ -z "$URL" ]; then
  exit 0
fi

if [ -d "$PRELOAD_DIR" ] \
  && [ -f "$PRELOAD_DIR/stage-runner.sh" ] \
  && [ -f "$PRELOAD_DIR/ingest-bootstrap.sh" ] \
  && [ -f "$PRELOAD_DIR/run-destination-stage.sh" ] \
  && pack_sha_ok "$PRELOAD_DIR"; then
  echo "script_pack_sync=skipped version=${VERSION} dir=${PRELOAD_DIR}"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "script_pack_sync_error=fetch_tool_missing" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
archive="${tmpdir}/script-pack.tar.gz"
trap 'rm -rf "$tmpdir"' EXIT

auth_header=()
token="${SCRIPT_PACK_GITHUB_TOKEN:-${GIT_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}}"
if [ -n "$token" ] && [[ "$URL" == https://github.com/* || "$URL" == https://api.github.com/* ]]; then
  auth_header=(-H "Authorization: Bearer ${token}")
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${auth_header[@]}" "$URL" -o "$archive"
else
  wget -q "${auth_header[@]/#/-header=}" -O "$archive" "$URL"
fi

if [ -n "${SCRIPT_PACK_TARBALL_SHA256:-}" ]; then
  actual_tar="$(sha256_file "$archive")"
  if [ "$actual_tar" != "$SCRIPT_PACK_TARBALL_SHA256" ]; then
    echo "script_pack_sync_error=tarball_sha256_mismatch expected=${SCRIPT_PACK_TARBALL_SHA256} actual=${actual_tar}" >&2
    exit 1
  fi
fi

rm -rf "$PRELOAD_DIR"
mkdir -p "$PRELOAD_DIR"
tar -xzf "$archive" -C "$PRELOAD_DIR"
chmod +x "$PRELOAD_DIR/stage-runner.sh" "$PRELOAD_DIR/run-destination-stage.sh" 2>/dev/null || true

if ! pack_sha_ok "$PRELOAD_DIR"; then
  echo "script_pack_sync_error=extract_sha256_mismatch dir=${PRELOAD_DIR}" >&2
  exit 1
fi

echo "script_pack_sync=ok version=${VERSION} dir=${PRELOAD_DIR} url=${URL}"
