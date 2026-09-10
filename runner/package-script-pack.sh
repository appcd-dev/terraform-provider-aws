#!/usr/bin/env bash
# Build a flat script-pack tarball for mothership vault sync (SCRIPT_PACK_TARBALL_URL).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="${ROOT}/agent-pipeline-config/modules/aios-agent-aws-migrator"
VERSION="$(sed -n 's/^SCRIPT_PACK_VERSION="\([^"]*\)"/\1/p' "$MODULE/scripts/stage-runner.sh" | head -n1)"
test -n "$VERSION"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

DEST="${STAGING}/pack"
mkdir -p "$DEST/mappings"

cp "$MODULE/scripts/allocate_manifest.py" "$DEST/"
cp "$MODULE/scripts/tfstate_monolith_decomposer.py" "$DEST/"
cp "$MODULE/scripts/stage-runner.sh" "$DEST/"
cp "$MODULE/scripts/azure_mapping_catalog.py" "$DEST/"
cp "$MODULE/scripts/azure_iac_generate.py" "$DEST/"
cp "$MODULE/scripts/gcp_mapping_catalog.py" "$DEST/"
cp "$MODULE/scripts/gcp_iac_generate.py" "$DEST/"
cp "$MODULE/scripts/app_iam.py" "$DEST/"
cp "$MODULE/scripts/hcl_sanity.py" "$DEST/"
cp "$MODULE/scripts/destination_iac_harden.py" "$DEST/"
cp "$MODULE/scripts/governance_conform.py" "$DEST/"
cp "$MODULE/scripts/governance_opa_check.py" "$DEST/"
cp "$MODULE/scripts/run-destination-stage.sh" "$DEST/"
cp "$MODULE/scripts/ensure_cloud2code.sh" "$DEST/"
cp "$MODULE/mappings/aws-to-azure.json" "$DEST/mappings/"
cp "$MODULE/mappings/aws-to-gcp.json" "$DEST/mappings/"
chmod +x "$DEST/stage-runner.sh" "$DEST/run-destination-stage.sh"

(cd "$ROOT" && python3 "$ROOT/runner/render_ingest_bootstrap.py" "$DEST")

OUT="${1:-${ROOT}/runner/dist/script-pack-${VERSION}.tar.gz}"
mkdir -p "$(dirname "$OUT")"
tar -czf "$OUT" -C "$DEST" .
echo "wrote ${OUT} version=${VERSION} bytes=$(wc -c <"$OUT" | tr -d ' ')"
