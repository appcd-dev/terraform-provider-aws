#!/usr/bin/env bash
# Download pinned CLIs into /usr/local/bin. Run as root during image build.
set -euo pipefail

ARCH="${TARGETARCH:?TARGETARCH required (amd64 or arm64)}"
. /tmp/versions.env

case "$ARCH" in
  amd64)
    TOFU_SHA="$TOFU_SHA256_AMD64"
    RUNNER_SHA="$AIDEN_RUNNER_SHA256_AMD64"
    C2C_SHA="$CLOUD2CODE_SHA256_AMD64"
    OPA_SHA="$OPA_SHA256_AMD64"
    TFLINT_SHA="$TFLINT_SHA256_AMD64"
    GH_SHA="$GH_SHA256_AMD64"
    AWS_ARCH="x86_64"
    AWS_SHA="$AWSCLI_SHA256_X86_64"
    ;;
  arm64)
    TOFU_SHA="$TOFU_SHA256_ARM64"
    RUNNER_SHA="$AIDEN_RUNNER_SHA256_ARM64"
    C2C_SHA="$CLOUD2CODE_SHA256_ARM64"
    OPA_SHA="$OPA_SHA256_ARM64"
    TFLINT_SHA="$TFLINT_SHA256_ARM64"
    GH_SHA="$GH_SHA256_ARM64"
    AWS_ARCH="aarch64"
    AWS_SHA="$AWSCLI_SHA256_AARCH64"
    ;;
  *)
    echo "unsupported TARGETARCH=$ARCH" >&2
    exit 1
    ;;
esac

fetch() {
  local url="$1" dest="$2" sha="$3"
  curl -fsSL -o "$dest" "$url"
  echo "${sha}  ${dest}" | sha256sum -c -
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch "https://releases.stackgen.com/binaries/aiden-runner/v${AIDEN_RUNNER_VERSION}/aiden-runner_${AIDEN_RUNNER_VERSION}_linux_${ARCH}.tar.gz" \
  "$tmp/aiden-runner.tar.gz" "$RUNNER_SHA"
tar -xzf "$tmp/aiden-runner.tar.gz" -C "$tmp" aiden-runner
install -m 0755 "$tmp/aiden-runner" /usr/local/bin/aiden-runner

fetch "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${ARCH}.zip" \
  "$tmp/tofu.zip" "$TOFU_SHA"
unzip -q -o "$tmp/tofu.zip" tofu -d "$tmp"
install -m 0755 "$tmp/tofu" /usr/local/bin/tofu

fetch "https://releases.stackgen.com/binaries/cloud2code/v${CLOUD2CODE_VERSION}/cloud2code_${CLOUD2CODE_VERSION}_linux_${ARCH}.tar.gz" \
  "$tmp/cloud2code.tar.gz" "$C2C_SHA"
tar -xzf "$tmp/cloud2code.tar.gz" -C "$tmp" cloud2code
install -m 0755 "$tmp/cloud2code" /usr/local/bin/cloud2code

fetch "https://github.com/open-policy-agent/opa/releases/download/v${OPA_VERSION}/opa_linux_${ARCH}_static" \
  "$tmp/opa" "$OPA_SHA"
install -m 0755 "$tmp/opa" /usr/local/bin/opa

fetch "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${ARCH}.zip" \
  "$tmp/tflint.zip" "$TFLINT_SHA"
unzip -q -o "$tmp/tflint.zip" tflint -d "$tmp"
install -m 0755 "$tmp/tflint" /usr/local/bin/tflint

fetch "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
  "$tmp/gh.tar.gz" "$GH_SHA"
tar -xzf "$tmp/gh.tar.gz" -C "$tmp" --strip-components=2 "gh_${GH_VERSION}_linux_${ARCH}/bin/gh"
install -m 0755 "$tmp/gh" /usr/local/bin/gh

fetch "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip" \
  "$tmp/awscliv2.zip" "$AWS_SHA"
unzip -q -o "$tmp/awscliv2.zip" -d "$tmp"
"$tmp/aws/install" -i /usr/local/aws-cli -b /usr/local/bin
