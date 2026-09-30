#!/usr/bin/env bash
# Exercise the runner image with the same conditions as the ACA Azure Files mount.
set -euo pipefail

IMAGE="${1:-nile-factory-runner:test}"
ROOT="$(mktemp -d)"
FAKE_BIN="${ROOT}/bin"
HOME_VOLUME="nile-runner-home-test-${RANDOM}-$$"
trap 'docker volume rm -f "$HOME_VOLUME" >/dev/null 2>&1 || true; rm -rf "$ROOT"' EXIT

mkdir -p "$FAKE_BIN"
docker volume create "$HOME_VOLUME" >/dev/null
docker run --rm \
  --user root \
  --mount "type=volume,src=${HOME_VOLUME},dst=/home/runner,volume-nocopy" \
  --entrypoint /bin/chown \
  "$IMAGE" 1000:1000 /home/runner

# Azure Files derives modes from mount_options and rejects chmod with EPERM.
cat >"${FAKE_BIN}/chmod" <<'EOF'
#!/bin/sh
exit 1
EOF
/bin/chmod 0755 "${FAKE_BIN}/chmod"

output="$(
  docker run --rm \
    --mount "type=volume,src=${HOME_VOLUME},dst=/home/runner,volume-nocopy" \
    --mount "type=bind,src=${FAKE_BIN},dst=/test-bin,readonly" \
    --env "PATH=/test-bin:/home/runner/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$IMAGE" version 2>&1
)"
printf '%s\n' "$output"

grep -q "runner-entrypoint: restored script pack" <<<"$output"
grep -q "Version: 0.2.22" <<<"$output"

docker run --rm \
  --mount "type=volume,src=${HOME_VOLUME},dst=/home/runner,volume-nocopy" \
  --entrypoint /bin/bash \
  "$IMAGE" -euc '
    # Stages read the pack from /opt. It must be complete and readable as the
    # runner user while the share covers HOME, which is what preflight checks.
    pack="$(echo /opt/aws-migrator/script-pack/*)"
    test -r "$pack/stage-runner.sh"
    test -r "$pack/aws_discovery_scan_report.py"
    test -r "$pack/ingest-bootstrap.sh"
    test -r "$pack/runner-capability-preflight.sh"
    test -r "$pack/run-destination-stage.sh"
    grep -q "$pack" "$pack/ingest-bootstrap.sh"
    grep -q "SCRIPT_PACK_VERSION=" "$pack/stage-runner.sh"
    for alias_name in cloud2code-scan cloud2code-scan.sh cloud2code-aws-scan pack.sh; do
      test -r "$pack/$alias_name"
      grep -q "cloud2code-aws-scan.sh" "$pack/$alias_name"
    done
    home_pack="$(echo "$HOME"/.aws-migrator/script-pack/*)"
    test -r "$home_pack/stage-runner.sh"
  '

second_output="$(
  docker run --rm \
    --mount "type=volume,src=${HOME_VOLUME},dst=/home/runner,volume-nocopy" \
    "$IMAGE" version 2>&1
)"
if grep -q "runner-entrypoint: restored script pack" <<<"$second_output"; then
  echo "second start unexpectedly recopied the script pack" >&2
  exit 1
fi

echo "persistent HOME smoke test passed"
