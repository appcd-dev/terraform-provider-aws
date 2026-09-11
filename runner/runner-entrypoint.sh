#!/usr/bin/env bash
# Restore the baked script pack into HOME before starting aiden-runner.
#
# Deployments mount a persistent volume over /home/runner so workflow scratch
# trees survive a container restart. That mount hides anything the image baked
# under HOME, so preflight reports blocked:remote_runner_script_pack_missing on
# the first start against an empty volume. The pack ships in /opt instead and is
# copied in here, on every start, for whatever versions the image carries.
set -euo pipefail

PACK_SRC_ROOT="/opt/aws-migrator/script-pack"
PACK_DEST_ROOT="${HOME}/.aws-migrator/script-pack"

if [ -d "$PACK_SRC_ROOT" ]; then
  mkdir -p "$PACK_DEST_ROOT"
  for src in "$PACK_SRC_ROOT"/*/; do
    [ -d "$src" ] || continue
    version="$(basename "$src")"
    dest="${PACK_DEST_ROOT}/${version}"
    if [ -x "${dest}/stage-runner.sh" ] && [ -x "${dest}/ingest-bootstrap.sh" ]; then
      continue
    fi
    # A partial copy is worse than none: the pack is sha256-gated, so replace it
    # whole rather than patching whatever the volume already holds.
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -R "$src". "$dest/"
    chmod -R u+rwX "$dest"
    echo "runner-entrypoint: restored script pack ${version} into ${dest}"
  done
fi

exec /usr/local/bin/aiden-runner "$@"
