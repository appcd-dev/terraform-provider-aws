#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/ensure_cloud2code.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TEST_ROOT/archive" "$TEST_ROOT/bin" "$TEST_ROOT/install"
cat >"$TEST_ROOT/archive/cloud2code" <<'EOF'
#!/usr/bin/env sh
echo "0.5.5"
EOF
chmod +x "$TEST_ROOT/archive/cloud2code"
tar -C "$TEST_ROOT/archive" -czf "$TEST_ROOT/cloud2code.tar.gz" cloud2code

cat >"$TEST_ROOT/bin/uname" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  -s) echo Linux ;;
  -m) echo aarch64 ;;
  *) exit 1 ;;
esac
EOF
cat >"$TEST_ROOT/bin/curl" <<EOF
#!/usr/bin/env sh
output=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "-o" ]; then
    shift
    output="\$1"
  fi
  shift
done
cp "$TEST_ROOT/cloud2code.tar.gz" "\$output"
EOF
chmod +x "$TEST_ROOT/bin/uname" "$TEST_ROOT/bin/curl"

PATH="$TEST_ROOT/bin:/usr/bin:/bin"
export PATH
export CLOUD2CODE_INSTALL_DIR="$TEST_ROOT/install"
export CLOUD2CODE_RELEASE_BASE_URL="https://releases.example.test/binaries/cloud2code"

# shellcheck source=ensure_cloud2code.sh
source "$INSTALLER"
ensure_cloud2code

[ "$(command -v cloud2code)" = "$TEST_ROOT/install/cloud2code" ] \
  || fail "installed cloud2code was not added to PATH"
[ "$(cloud2code version)" = "0.5.5" ] \
  || fail "installed cloud2code is not executable"

rm -f "$TEST_ROOT/bin/curl"
ensure_cloud2code

echo "PASS: cloud2code is downloaded only when missing and installed on PATH"
