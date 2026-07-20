#!/bin/bash
#
# Regression test: installers must select the greatest numeric version for the
# current platform, regardless of JSONL entry order.
#
# Usage:
#   bash tests/install_latest_version.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

INSTALLERS=(
  "install.sh"
  "install-eap.sh"
  "install-nightly.sh"
  "install-experimental.sh"
)

JSONL='{"version":"2383.9","platform":"macos-aarch64","downloadUrl":"https://example.test/2383.9.zip","sha256":"sha-2383.9"}
{"version":"9999.1","platform":"linux-amd64","downloadUrl":"https://example.test/wrong-platform.zip","sha256":"wrong-platform"}
{"version":"2383.10","platform":"macos-aarch64","downloadUrl":"https://example.test/2383.10.zip","sha256":"sha-2383.10"}
{"version":"2383.2","platform":"macos-aarch64","downloadUrl":"https://example.test/2383.2.zip","sha256":"sha-2383.2"}'

PASS=0
FAIL=0

for name in "${INSTALLERS[@]}"; do
  installer="$REPO_ROOT/$name"
  if [[ ! -f "$installer" ]]; then
    echo "FAIL [$name]: installer not found at $installer" >&2
    FAIL=$((FAIL + 1))
    continue
  fi

  function_src="$(sed -n '/^fetch_latest_version() {$/,/^}$/p' "$installer")"
  if [[ -z "$function_src" ]]; then
    echo "FAIL [$name]: fetch_latest_version function not found" >&2
    FAIL=$((FAIL + 1))
    continue
  fi

  unset VERSION DOWNLOAD_URL SHA256
  export PLATFORM="macos-aarch64"
  export UPDATE_INFO_URL="https://example.test/update-info.jsonl"
  log() { :; }
  log_error() { printf '%s\n' "$*" >&2; }
  curl() { printf '%s\n' "$JSONL"; }
  eval "$function_src"

  if fetch_latest_version &&
     [[ "$VERSION" == "2383.10" ]] &&
     [[ "$DOWNLOAD_URL" == "https://example.test/2383.10.zip" ]] &&
     [[ "$SHA256" == "sha-2383.10" ]]; then
    echo "PASS [$name]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$name]: expected numeric latest 2383.10, got ${VERSION:-<empty>}" >&2
    FAIL=$((FAIL + 1))
  fi
done

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]