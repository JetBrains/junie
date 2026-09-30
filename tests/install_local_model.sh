#!/usr/bin/env bash
#
# Regression test: the `--local-model` flag must be accepted, unknown flags must
# be rejected, and the local model setup must run only when the flag is given.
#
# Usage:
#   bash tests/install_local_model.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

INSTALLERS=(
  "install.sh"
  "install-eap.sh"
  "install-nightly.sh"
  "install-experimental.sh"
)

# The local model is macOS-only, so the PowerShell installers must not offer it.
INSTALLERS_WITHOUT_LOCAL_MODEL=(
  "install.ps1"
  "install-eap.ps1"
  "install-nightly.ps1"
  "install-experimental.ps1"
)

LOCAL_MODEL_URL="https://raw.githubusercontent.com/jetbrains-junie/junie/main/local/install.sh"

PASS=0
FAIL=0

pass() {
  echo "PASS [$1] $2"
  PASS=$((PASS + 1))
}

fail() {
  echo "FAIL [$1] $2" >&2
  FAIL=$((FAIL + 1))
}

# Run the installer in a subshell with the given args, capturing output+status.
# Argument parsing happens before any network access, so this never downloads.
run_installer() {
  bash "$1" "${@:2}" 2>&1
}

# Extract a shell construct from the installer so it can be exercised with stubs.
extract() {
  sed -n "/$2/,/$3/p" "$1"
}

for name in "${INSTALLERS[@]}"; do
  installer="$REPO_ROOT/$name"
  if [[ ! -f "$installer" ]]; then
    fail "$name" "installer not found at $installer"
    continue
  fi

  # --help exits cleanly and documents the flag.
  output="$(run_installer "$installer" --help)"
  status=$?
  if [[ "$status" -eq 0 && "$output" == *"--local-model"* ]]; then
    pass "$name" "--help documents --local-model"
  else
    fail "$name" "--help: expected status 0 and --local-model in usage, got status $status: $output"
  fi

  # An unknown flag is rejected instead of silently ignored.
  output="$(run_installer "$installer" --local-models)"
  status=$?
  if [[ "$status" -eq 1 && "$output" == *"Unknown option: --local-models"* ]]; then
    pass "$name" "unknown flag rejected"
  else
    fail "$name" "unknown flag: expected status 1 and an error, got status $status: $output"
  fi

  # The installer fetches the local model installer kept in this repo.
  installer_url="$(sed -n 's/^LOCAL_MODEL_URL="\(.*\)"$/\1/p' "$installer")"
  if [[ "$installer_url" == "$LOCAL_MODEL_URL" ]]; then
    pass "$name" "points at the in-repo local installer"
  else
    fail "$name" "LOCAL_MODEL_URL: expected $LOCAL_MODEL_URL, got ${installer_url:-<unset>}"
  fi

  function_src="$(extract "$installer" '^install_local_model() {$' '^}$')"
  if [[ -z "$function_src" ]]; then
    fail "$name" "install_local_model function not found"
    continue
  fi

  observed="$(
    LOCAL_MODEL_URL="$installer_url"
    log() { :; }
    log_error() { :; }
    curl() { printf 'url=%s\n' "${*: -1}"; }
    bash() { cat; }
    eval "$function_src"
    install_local_model
  )"
  if [[ "$observed" == *"url=$LOCAL_MODEL_URL"* ]]; then
    pass "$name" "install_local_model runs the local model installer"
  else
    fail "$name" "install_local_model: expected a fetch of $LOCAL_MODEL_URL, got: $observed"
  fi

  # A failing local model setup must still tell the user that Junie is installed,
  # and hand them the command to retry the local model on its own.
  observed="$(
    LOCAL_MODEL_URL="$installer_url"
    log() { printf '%s\n' "$*"; }
    log_error() { printf '%s\n' "$*"; }
    curl() { :; }
    bash() { cat > /dev/null; return 1; }
    eval "$function_src"
    install_local_model
  )"
  status=$?
  if [[ "$status" -eq 1
        && "$observed" == *"Junie itself is installed and ready to use"*
        && "$observed" == *"curl -fsSL $LOCAL_MODEL_URL"* ]]; then
    pass "$name" "failed local model setup reports Junie as installed, with a retry hint"
  else
    fail "$name" "failed local model setup: expected status 1, the Junie-is-installed line and a retry hint, got status $status: $observed"
  fi

  # The tail dispatch runs the setup only when the flag was given.
  dispatch_src="$(extract "$installer" '^if \[\[ -n "\$LOCAL_MODEL" \]\]; then$' '^fi$')"
  if [[ -z "$dispatch_src" ]]; then
    fail "$name" "local model dispatch not found"
    continue
  fi

  observed="$(
    install_local_model() { echo "called"; }
    LOCAL_MODEL=1
    eval "$dispatch_src"
    LOCAL_MODEL=""
    eval "$dispatch_src"
  )"
  if [[ "$observed" == "called" ]]; then
    pass "$name" "local model setup runs only with --local-model"
  else
    fail "$name" "dispatch: expected exactly one call, got: ${observed:-<none>}"
  fi
done

for name in "${INSTALLERS_WITHOUT_LOCAL_MODEL[@]}"; do
  installer="$REPO_ROOT/$name"
  if [[ ! -f "$installer" ]]; then
    fail "$name" "installer not found at $installer"
    continue
  fi

  if traces="$(grep -niE 'local.model|local/install\.sh' "$installer")"; then
    fail "$name" "must not reference the local model setup: $traces"
  else
    pass "$name" "no local model setup"
  fi
done

# The URL the installers fetch must resolve to a script that exists in the repo.
local_script="${LOCAL_MODEL_URL##*/main/}"
if [[ -x "$REPO_ROOT/$local_script" ]]; then
  pass "$local_script" "present and executable"
else
  fail "$local_script" "installers fetch it, but it is missing or not executable"
fi

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
