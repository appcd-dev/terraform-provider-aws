#!/usr/bin/env bash
# Point an existing aiden-runner Helm release at the Nile-Factory GHCR image.
#
# The image bakes the aws-migrator script pack (including run-destination-stage.sh)
# and CLIs: tofu, cloud2code, aws, gh, opa, tflint, python3, jq, git.
#
# Usage:
#   upgrade-nile-factory-runner-helm.sh <deployment-dir> <helm-release> [namespace] [image-pull-secret]
#
# Example (tramlaw on developer-eks):
#   kubectl config use-context arn:aws:eks:...:cluster/developer-eks
#   agent-pipeline-config/scripts/upgrade-nile-factory-runner-helm.sh \
#     agent-pipeline-config/deployments/greenfield tramlaw-runner aiden-runner ghcr-pkg
set -euo pipefail

DEPLOYMENT_DIR="${1:?usage: upgrade-nile-factory-runner-helm.sh <deployment-dir> <helm-release> [namespace] [image-pull-secret]}"
RELEASE="${2:?helm release name required}"
NAMESPACE="${3:-aiden-runner}"
PULL_SECRET="${4:-}"

TF_BIN="${TF_BIN:-tofu}"
cd "$DEPLOYMENT_DIR"

IMAGE="$("$TF_BIN" output -raw remote_runner_image)"
HELM_SETS="$("$TF_BIN" output -raw remote_runner_helm_image_sets)"

echo "Upgrading Helm release ${RELEASE} in ${NAMESPACE} to image ${IMAGE}"

extra_args=()
if [ -n "$PULL_SECRET" ]; then
  extra_args+=(--set "imagePullSecrets[0].name=${PULL_SECRET}")
fi

# shellcheck disable=SC2086
helm upgrade "$RELEASE" appcd-public-releases/aiden-runner \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set "image.repository=$(echo "$IMAGE" | cut -d: -f1)" \
  --set "image.tag=$(echo "$IMAGE" | cut -d: -f2)" \
  --set 'runner.allowedClis=tofu\,terraform\,jq\,git\,aws\,gh\,python3\,tar\,curl\,wget\,opa\,tflint\,cloud2code' \
  "${extra_args[@]}"

echo "Waiting for rollout..."
kubectl rollout status "deployment/${RELEASE}-aiden-runner" -n "$NAMESPACE" --timeout=180s

POD="$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
echo "Smoke on pod ${POD}:"
kubectl exec -n "$NAMESPACE" "$POD" -- sh -lc 'opa version; test -x /home/runner/.aws-migrator/script-pack/*/run-destination-stage.sh && echo run-destination-stage:ok'
