# ensure_cloud2code makes the pinned Cloud2Code CLI available to runner scripts.
# It installs into the runner user's home directory so root access is unnecessary.
# Re-downloads when the on-PATH binary is missing or not the pinned version.
ensure_cloud2code() {
  local version="${CLOUD2CODE_VERSION:-0.5.6}"
  local release_base="${CLOUD2CODE_RELEASE_BASE_URL:-https://releases.stackgen.com/binaries/cloud2code}"
  local target_os target_arch machine archive_url install_dir tmp_dir current

  if command -v cloud2code >/dev/null 2>&1; then
    current="$(cloud2code version 2>/dev/null | head -n 1 | tr -d '[:space:]' | sed 's/^v//')"
    case "$current" in
      "$version"|*"$version"*)
        return 0
        ;;
    esac
    echo "cloud2code_upgrade=from:${current:-unknown}:to:$version" >&2
  fi

  target_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64)
      target_arch="amd64"
      ;;
    aarch64 | arm64)
      target_arch="arm64"
      ;;
    *)
      echo "cloud2code_error=unsupported_arch architecture=$machine" >&2
      return 1
      ;;
  esac

  case "$target_os" in
    linux | darwin) ;;
    *)
      echo "cloud2code_error=unsupported_os os=$target_os" >&2
      return 1
      ;;
  esac

  if ! command -v tar >/dev/null 2>&1; then
    echo "cloud2code_error=tar_missing" >&2
    return 1
  fi

  install_dir="${CLOUD2CODE_INSTALL_DIR:-}"
  if [ -z "$install_dir" ]; then
    # Prefer writable aws-migrator bin; $HOME/.local/bin is often root-owned on ACA
    # (session 6dac05f9 Permission denied).
    if mkdir -p "$HOME/.aws-migrator/bin" 2>/dev/null && [ -w "$HOME/.aws-migrator/bin" ]; then
      install_dir="$HOME/.aws-migrator/bin"
    else
      install_dir="$HOME/.local/bin"
    fi
  fi
  archive_url="${release_base}/v${version}/cloud2code_${version}_${target_os}_${target_arch}.tar.gz"
  tmp_dir="$(mktemp -d)"

  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL -o "$tmp_dir/cloud2code.tar.gz" "$archive_url"; then
      rm -rf "$tmp_dir"
      echo "cloud2code_error=download_failed url=$archive_url" >&2
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -q -O "$tmp_dir/cloud2code.tar.gz" "$archive_url"; then
      rm -rf "$tmp_dir"
      echo "cloud2code_error=download_failed url=$archive_url" >&2
      return 1
    fi
  else
    rm -rf "$tmp_dir"
    echo "cloud2code_error=downloader_missing required=curl_or_wget" >&2
    return 1
  fi

  if ! tar -xzf "$tmp_dir/cloud2code.tar.gz" -C "$tmp_dir" cloud2code \
    || [ ! -f "$tmp_dir/cloud2code" ]; then
    rm -rf "$tmp_dir"
    echo "cloud2code_error=archive_invalid url=$archive_url" >&2
    return 1
  fi

  mkdir -p "$install_dir"
  cp "$tmp_dir/cloud2code" "$install_dir/cloud2code"
  chmod 0755 "$install_dir/cloud2code"
  rm -rf "$tmp_dir"

  export PATH="$install_dir:$PATH"
  if ! command -v cloud2code >/dev/null 2>&1; then
    echo "cloud2code_error=install_failed path=$install_dir/cloud2code" >&2
    return 1
  fi

  echo "cloud2code_source=downloaded version=$version path=$install_dir/cloud2code"
}
