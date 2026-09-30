#!/usr/bin/env bash
# Preload the tfstate decomposition script pack onto a Kubernetes-hosted
# aiden-runner.
#
# Every pack file is sha256-gated by the agent module, so the runner must hold
# byte-identical copies at the exact `script_pack_version` the module expects.
# Without this script the preload is a manual multi-step `kubectl cp`, and the
# rendered `ingest-bootstrap.sh` (generated from module locals, not committed)
# has to be reconstructed by hand on every version bump.
#
# Usage:
#   agent-pipeline-config/scripts/preload-script-pack.sh <deployment-dir> [pod] [namespace]
#
# Defaults resolve the runner pod by the aiden-runner label in the namespace.
set -euo pipefail

DEPLOYMENT_DIR="${1:?usage: preload-script-pack.sh <deployment-dir> [pod] [namespace]}"
POD="${2:-}"
NAMESPACE="${3:-aiden-runner}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_SRC="${REPO_ROOT}/agent-pipeline-config/modules/aios-agent-aws-migrator"
PACK_SRC="${MODULE_SRC}/scripts"
CATALOG_SRC="${MODULE_SRC}/mappings/aws-to-azure.json"
GCP_CATALOG_SRC="${MODULE_SRC}/mappings/aws-to-gcp.json"

TF_BIN="${TF_BIN:-tofu}"

cd "$DEPLOYMENT_DIR"
VERSION="$("$TF_BIN" output -raw script_pack_version)"
PRELOAD_DIR="$("$TF_BIN" output -raw script_pack_preload_dir)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/mappings"
cp "$PACK_SRC/allocate_manifest.py" "$STAGE/allocate_manifest.py"
cp "$PACK_SRC/tfstate_monolith_decomposer.py" "$STAGE/tfstate_monolith_decomposer.py"
cp "$PACK_SRC/stage-runner.sh" "$STAGE/stage-runner.sh"
cp "$PACK_SRC/aws_discovery_scan_report.py" "$STAGE/aws_discovery_scan_report.py"
cp "$PACK_SRC/azure_mapping_catalog.py" "$STAGE/azure_mapping_catalog.py"
cp "$PACK_SRC/azure_iac_generate.py" "$STAGE/azure_iac_generate.py"
cp "$PACK_SRC/gcp_mapping_catalog.py" "$STAGE/gcp_mapping_catalog.py"
cp "$PACK_SRC/gcp_iac_generate.py" "$STAGE/gcp_iac_generate.py"
cp "$PACK_SRC/app_iam.py" "$STAGE/app_iam.py"
cp "$PACK_SRC/hcl_sanity.py" "$STAGE/hcl_sanity.py"
cp "$PACK_SRC/destination_iac_harden.py" "$STAGE/destination_iac_harden.py"
cp "$PACK_SRC/governance_conform.py" "$STAGE/governance_conform.py"
cp "$PACK_SRC/governance_opa_check.py" "$STAGE/governance_opa_check.py"
cp "$PACK_SRC/run-destination-stage.sh" "$STAGE/run-destination-stage.sh"
cp "$CATALOG_SRC" "$STAGE/mappings/aws-to-azure.json"
cp "$GCP_CATALOG_SRC" "$STAGE/mappings/aws-to-gcp.json"
"$TF_BIN" output -raw ingest_bootstrap_script >"$STAGE/ingest-bootstrap.sh"
chmod +x "$STAGE/stage-runner.sh" "$STAGE/ingest-bootstrap.sh" "$STAGE/run-destination-stage.sh"

if [ -z "$POD" ]; then
  # Prefer a Running pod — Failed/Completed pods still match the label and break kubectl exec.
  POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=aiden-runner --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
fi
if [ -z "$POD" ]; then
  echo "error: no Running aiden-runner pod in namespace ${NAMESPACE}" >&2
  exit 1
fi

# Stage into PRELOAD_DIR.tmp then atomically rename so concurrent workflow stages
# never observe a half-deleted pack (preload_catalog_missing during rm -rf + kubectl cp).
STAGING_DIR="${PRELOAD_DIR}.tmp.$$"
echo "preloading script pack version=${VERSION} pod=${POD} ns=${NAMESPACE} dir=${PRELOAD_DIR} staging=${STAGING_DIR}"
kubectl exec -n "$NAMESPACE" "$POD" -- sh -lc "rm -rf '${STAGING_DIR}' '${PRELOAD_DIR}.old' && mkdir -p '${STAGING_DIR}/mappings'"
for f in allocate_manifest.py tfstate_monolith_decomposer.py stage-runner.sh aws_discovery_scan_report.py azure_mapping_catalog.py azure_iac_generate.py gcp_mapping_catalog.py gcp_iac_generate.py app_iam.py hcl_sanity.py destination_iac_harden.py governance_conform.py governance_opa_check.py ingest-bootstrap.sh run-destination-stage.sh; do
  kubectl cp "$STAGE/$f" "${NAMESPACE}/${POD}:${STAGING_DIR}/$f"
done
kubectl cp "$STAGE/mappings/aws-to-azure.json" "${NAMESPACE}/${POD}:${STAGING_DIR}/mappings/aws-to-azure.json"
kubectl cp "$STAGE/mappings/aws-to-gcp.json" "${NAMESPACE}/${POD}:${STAGING_DIR}/mappings/aws-to-gcp.json"
kubectl exec -n "$NAMESPACE" "$POD" -- sh -lc "
  set -e
  chmod +x '${STAGING_DIR}/stage-runner.sh' '${STAGING_DIR}/ingest-bootstrap.sh' '${STAGING_DIR}/run-destination-stage.sh'
  for f in allocate_manifest.py tfstate_monolith_decomposer.py stage-runner.sh aws_discovery_scan_report.py azure_mapping_catalog.py azure_iac_generate.py gcp_mapping_catalog.py gcp_iac_generate.py app_iam.py hcl_sanity.py destination_iac_harden.py governance_conform.py governance_opa_check.py ingest-bootstrap.sh run-destination-stage.sh mappings/aws-to-azure.json mappings/aws-to-gcp.json; do
    test -f '${STAGING_DIR}/'\$f || { echo \"error: staging missing \$f\" >&2; exit 1; }
  done
  if [ -d '${PRELOAD_DIR}' ]; then
    rm -rf '${PRELOAD_DIR}.old'
    mv '${PRELOAD_DIR}' '${PRELOAD_DIR}.old'
  fi
  mv '${STAGING_DIR}' '${PRELOAD_DIR}'
  rm -rf '${PRELOAD_DIR}.old'
"

echo "--- runner sha256 ---"
kubectl exec -n "$NAMESPACE" "$POD" -- sh -lc "cd '${PRELOAD_DIR}' && sha256sum allocate_manifest.py tfstate_monolith_decomposer.py stage-runner.sh aws_discovery_scan_report.py azure_mapping_catalog.py azure_iac_generate.py gcp_mapping_catalog.py gcp_iac_generate.py app_iam.py hcl_sanity.py destination_iac_harden.py governance_conform.py governance_opa_check.py run-destination-stage.sh mappings/aws-to-azure.json mappings/aws-to-gcp.json"
echo "--- local sha256 ---"
(cd "$STAGE" && shasum -a 256 allocate_manifest.py tfstate_monolith_decomposer.py stage-runner.sh aws_discovery_scan_report.py azure_mapping_catalog.py azure_iac_generate.py gcp_mapping_catalog.py gcp_iac_generate.py app_iam.py hcl_sanity.py destination_iac_harden.py governance_conform.py governance_opa_check.py run-destination-stage.sh mappings/aws-to-azure.json mappings/aws-to-gcp.json)
