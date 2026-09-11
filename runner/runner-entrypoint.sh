#!/usr/bin/env bash
# Restore the baked script pack into HOME before starting aiden-runner.
#
# Deployments mount a persistent volume over /home/runner so workflow scratch
# trees survive a container restart. That mount hides anything the image baked
# under HOME, so preflight reports blocked:remote_runner_script_pack_missing on
# the first start against an empty volume. The pack ships in /opt instead and is
# copied in here, on every start, for whatever versions the image carries.
set -uo pipefail

PACK_SRC_ROOT="/opt/aws-migrator/script-pack"
PACK_DEST_ROOT="${HOME}/.aws-migrator/script-pack"

# Never abort on a restore failure. A runner that starts and reports
# blocked:remote_runner_script_pack_missing is diagnosable; one that exits here
# crash-loops, and Azure Container Apps keeps serving the previous revision,
# which looks like the deployment silently did nothing.
restore_pack() {
  [ -d "$PACK_SRC_ROOT" ] || return 0
  mkdir -p "$PACK_DEST_ROOT" || return 1

  local src version dest
  for src in "$PACK_SRC_ROOT"/*/; do
    [ -d "$src" ] || continue
    version="$(basename "$src")"
    dest="${PACK_DEST_ROOT}/${version}"
    if [ -r "${dest}/stage-runner.sh" ] && [ -r "${dest}/ingest-bootstrap.sh" ]; then
      continue
    fi
    # A partial copy is worse than none: the pack is sha256-gated, so replace it
    # whole rather than patching whatever the volume already holds.
    rm -rf "$dest"
    mkdir -p "$dest" || return 1
    cp -R "$src". "$dest/" || return 1
    # Azure Files takes its modes from the mount options and rejects chmod with
    # EPERM, so this is best effort. It matters only on a local volume.
    chmod -R u+rwX "$dest" 2>/dev/null || true
    echo "runner-entrypoint: restored script pack ${version} into ${dest}"
  done
}

if ! restore_pack; then
  echo "runner-entrypoint: WARNING could not restore the script pack into ${PACK_DEST_ROOT}; preflight will report it missing" >&2
fi

exec /usr/local/bin/aiden-runner "$@"
