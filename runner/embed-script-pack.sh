#!/usr/bin/env bash
# Copy the aws-migrator script pack into the runner HOME and render ingest-bootstrap.sh.
set -euo pipefail

MODULE="agent-pipeline-config/modules/aios-agent-aws-migrator"
VERSION="$(sed -n 's/^SCRIPT_PACK_VERSION="\([^"]*\)"/\1/p' "$MODULE/scripts/stage-runner.sh" | head -n1)"
test -n "$VERSION"
DEST="/home/runner/.aws-migrator/script-pack/${VERSION}"

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
cp "$MODULE/scripts/runner-capability-preflight.sh" "$DEST/"
cp "$MODULE/scripts/cloud2code-aws-scan.sh" "$DEST/"
cp "$MODULE/mappings/aws-to-azure.json" "$DEST/mappings/"
cp "$MODULE/mappings/aws-to-gcp.json" "$DEST/mappings/"
chmod +x "$DEST/stage-runner.sh" "$DEST/run-destination-stage.sh" \
  "$DEST/runner-capability-preflight.sh" "$DEST/cloud2code-aws-scan.sh"

python3 /tmp/render_ingest_bootstrap.py "$DEST"
chown -R runner:runner /home/runner/.aws-migrator
echo "script pack at $DEST"
ls -la "$DEST"
