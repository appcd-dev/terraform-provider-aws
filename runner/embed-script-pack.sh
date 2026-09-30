#!/usr/bin/env bash
# Copy the aws-migrator script pack into the image and render ingest-bootstrap.sh.
# The pack lives under /opt, outside the runner HOME, because deployments mount a
# persistent volume over /home/runner and that would hide a pack baked there.
# runner-entrypoint.sh copies it into HOME at startup.
set -euo pipefail

MODULE="agent-pipeline-config/modules/aios-agent-aws-migrator"
VERSION="$(sed -n 's/^SCRIPT_PACK_VERSION="\([^"]*\)"/\1/p' "$MODULE/scripts/stage-runner.sh" | head -n1)"
test -n "$VERSION"
DEST="/opt/aws-migrator/script-pack/${VERSION}"
# Stages run the pack straight out of /opt. Nothing depends on a copy under
# HOME, which the ACA Azure Files share can mask.
RUNTIME_DEST="$DEST"

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
cp "$MODULE/mappings/aws-to-azure.json" "$DEST/mappings/"
cp "$MODULE/mappings/aws-to-gcp.json" "$DEST/mappings/"
chmod +x "$DEST/stage-runner.sh" "$DEST/run-destination-stage.sh" \
  "$DEST/runner-capability-preflight.sh" "$DEST/cloud2code-aws-scan.sh"

# Agents keep renaming the scan script and the command dies with exit 127
# before any scan runs: pack.sh (session 8478c357), cloud2code-scan (90cf9291),
# cloud2code-scan-aws (1c98a1b9). One listed the directory, saw the real names,
# and still did not retry with one. So accept the whole plausible name space and
# run the real script.
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

python3 /tmp/render_ingest_bootstrap.py "$DEST" "$RUNTIME_DEST"
chmod -R a+rX /opt/aws-migrator
# Let the runner user refresh the pack in place when script-pack vault sync is on.
chown -R 1000:1000 /opt/aws-migrator
echo "script pack at $DEST (runtime $RUNTIME_DEST)"
ls -la "$DEST"
