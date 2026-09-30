#!/usr/bin/env bash
# Build a flat script-pack tarball for mothership vault sync and ACA fetch bootstrap.
# Must match runner/embed-script-pack.sh contents (preflight + scan + aliases).
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
cp "$MODULE/scripts/aws_discovery_scan_report.py" "$DEST/"
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
cp "$MODULE/scripts/runner-capability-preflight.sh" "$DEST/"
cp "$MODULE/scripts/cloud2code-aws-scan.sh" "$DEST/"
cp "$MODULE/scripts/cloud2code-scan-detach.sh" "$DEST/"
cp "$MODULE/scripts/workflow-run-id.sh" "$DEST/"
cp "$MODULE/scripts/pack-entry.sh" "$DEST/pack-entry.sh"
sed -i.bak "s/__SCRIPT_PACK_VERSION__/${VERSION}/g" "$DEST/pack-entry.sh"
rm -f "$DEST/pack-entry.sh.bak"
cp "$MODULE/mappings/aws-to-azure.json" "$DEST/mappings/"
cp "$MODULE/mappings/aws-to-gcp.json" "$DEST/mappings/"
chmod +x "$DEST/stage-runner.sh" "$DEST/run-destination-stage.sh" \
  "$DEST/runner-capability-preflight.sh" "$DEST/cloud2code-aws-scan.sh" \
  "$DEST/cloud2code-scan-detach.sh" "$DEST/pack-entry.sh"

for alias_name in \
  cloud2code-scan cloud2code-scan.sh \
  cloud2code-aws-scan \
  cloud2code-scan-aws cloud2code-scan-aws.sh \
  cloud2code-aws cloud2code-aws.sh \
  cloud2code cloud2code.sh \
  aws-scan aws-scan.sh \
  scan-aws scan-aws.sh \
  scan scan.sh \
  run-scan run-scan.sh \
  cloud2code_aws_scan.sh cloud2code_scan_aws.sh \
  pack.sh; do
  [ -e "$DEST/$alias_name" ] && continue
  cat >"$DEST/$alias_name" <<'ALIAS'
#!/usr/bin/env bash
# Alias for cloud2code-aws-scan.sh. Kept so a renamed script still scans.
set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cloud2code-aws-scan.sh" "$@"
ALIAS
  chmod +x "$DEST/$alias_name"
done

(cd "$ROOT" && python3 "$ROOT/runner/render_ingest_bootstrap.py" "$DEST" \
  "/opt/aws-migrator/script-pack/${VERSION}")

OUT="${1:-${ROOT}/runner/dist/script-pack-${VERSION}.tar.gz}"
mkdir -p "$(dirname "$OUT")"
tar -czf "$OUT" -C "$DEST" .
ENTRY_OUT="$(dirname "$OUT")/pack-entry.sh"
cp "$DEST/pack-entry.sh" "$ENTRY_OUT"
echo "wrote ${OUT} version=${VERSION} bytes=$(wc -c <"$OUT" | tr -d ' ')"
echo "wrote ${ENTRY_OUT} bytes=$(wc -c <"$ENTRY_OUT" | tr -d ' ')"
test -f "$DEST/runner-capability-preflight.sh"
test -f "$DEST/cloud2code-aws-scan.sh"
test -f "$DEST/ingest-bootstrap.sh"
test -f "$DEST/iac-pr-bootstrap.sh"
test -f "$DEST/converge-bootstrap.sh"
test -f "$DEST/pack-entry.sh"
grep -q "${VERSION}" "$DEST/pack-entry.sh"
