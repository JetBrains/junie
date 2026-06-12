#!/bin/bash
#
# Self-test for the one-shot channel-switching logic in the shim embedded in
# install.sh (`junie --eap` and friends).
#
# Usage:
#   bash tests/shim_channel_switch.sh
#
# The script:
#   1. Extracts the shim source from install.sh between the SHIM_EOF markers.
#   2. Strips the trailing `main "$@"` so sourcing does not run main().
#   3. Sources the shim and exercises the channel helpers + install_channel_oneshot
#      against a stubbed installer (curl is replaced with a function that emits a
#      fake one-shot installer script).
#   4. Asserts the requested build is installed AND the default `current` pointer
#      is left untouched (the whole point of one-shot mode).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_ROOT/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
  echo "FAIL: cannot find $INSTALL_SH" >&2
  exit 1
fi

# Channel helpers read JUNIE_INSTALL_BASE_URL at source time; pin it for the
# installer_url_for_channel assertions below.
export JUNIE_INSTALL_BASE_URL="https://example.test"

# === Extract shim source ===
SHIM_SRC="$(mktemp)"
awk '/^cat > "\$JUNIE_BIN\/junie" << '\''SHIM_EOF'\''$/{flag=1; next} /^SHIM_EOF$/{flag=0} flag' \
  "$INSTALL_SH" > "$SHIM_SRC"
sed -i.bak '/^main "\$@"$/d' "$SHIM_SRC" 2>/dev/null || sed -i '' '/^main "\$@"$/d' "$SHIM_SRC"
rm -f "$SHIM_SRC.bak"

PASS=0
FAIL=0
CURRENT_TEST=""

setup_env() {
  CURRENT_TEST="$1"
  export JUNIE_DATA
  JUNIE_DATA="$(mktemp -d)"
  mkdir -p "$JUNIE_DATA/versions" "$JUNIE_DATA/updates"
  # shellcheck disable=SC1090
  source "$SHIM_SRC"
  set +e
  trap - EXIT INT TERM
}

teardown_env() {
  rm -rf "$JUNIE_DATA"
  unset -f curl 2>/dev/null || true
  unset JUNIE_DATA VERSIONS_DIR UPDATES_DIR CURRENT_LINK PENDING_UPDATE
}

assert() {
  local cond="$1" msg="$2"
  if eval "$cond"; then
    :
  else
    echo "FAIL [$CURRENT_TEST]: $msg (cond: $cond)" >&2
    FAIL=$((FAIL + 1))
    return 1
  fi
}

ok() {
  echo "PASS [$CURRENT_TEST]"
  PASS=$((PASS + 1))
}

seed_default_version() {
  local v="$1"
  mkdir -p "$JUNIE_DATA/versions/$v/junie/bin"
  printf '#!/bin/sh\necho default %s\n' "$v" > "$JUNIE_DATA/versions/$v/junie/bin/junie"
  chmod +x "$JUNIE_DATA/versions/$v/junie/bin/junie"
  ln -sfn "$JUNIE_DATA/versions/$v" "$JUNIE_DATA/current"
}

# Replace curl with a function that emits a fake one-shot installer. The emitted
# script honours JUNIE_ONESHOT_VERSION_FILE (set by the shim) and installs a
# build under $JUNIE_DATA/versions. The installed version is JUNIE_VERSION when
# the shim pins one (--use-version), else $FAKE_INSTALL_VERSION (the "latest").
stub_curl_installer() {
  export FAKE_INSTALL_VERSION="$1"
  curl() {
    cat <<'INSTALLER'
INSTALL_VER="${JUNIE_VERSION:-$FAKE_INSTALL_VERSION}"
mkdir -p "$JUNIE_DATA/versions/$INSTALL_VER/junie/bin"
printf '#!/bin/sh\necho fake %s\n' "$INSTALL_VER" > "$JUNIE_DATA/versions/$INSTALL_VER/junie/bin/junie"
chmod +x "$JUNIE_DATA/versions/$INSTALL_VER/junie/bin/junie"
printf '%s' "$INSTALL_VER" > "$JUNIE_ONESHOT_VERSION_FILE"
INSTALLER
  }
}

# === Scenarios ===

# 1. detect_channel_flag recognises every flag form (last one wins).
test_detect_channel_flag() {
  setup_env "detect_channel_flag"

  detect_channel_flag --help
  assert "[[ -z \"\$REQUESTED_CHANNEL\" ]]" "no channel flag -> empty" || { teardown_env; return; }

  # Regression: a non-channel arg must NOT leave a non-zero exit status. The
  # function is called as a bare command under `set -e` in main(); if its last
  # command is a failing `[[ ]]` test the whole shim aborts silently (no output,
  # exit 1) — e.g. `junie --help` or any normal launch.
  detect_channel_flag --help; local rc=$?
  assert "[[ $rc -eq 0 ]]" "non-channel arg must return success (set -e safety)" || { teardown_env; return; }

  detect_channel_flag --eap
  assert "[[ \"\$REQUESTED_CHANNEL\" == eap ]]" "--eap -> eap" || { teardown_env; return; }

  detect_channel_flag --channel=experimental run
  assert "[[ \"\$REQUESTED_CHANNEL\" == experimental ]]" "--channel=experimental -> experimental" || { teardown_env; return; }

  detect_channel_flag --eap --nightly
  assert "[[ \"\$REQUESTED_CHANNEL\" == nightly ]]" "last flag wins" || { teardown_env; return; }
  ok
  teardown_env
}

# 2. is_known_channel + installer_url_for_channel.
test_channel_url_resolution() {
  setup_env "channel_url_resolution"

  assert "is_known_channel eap" "eap is known" || { teardown_env; return; }
  assert "! is_known_channel bogus" "bogus is not known" || { teardown_env; return; }

  assert '[[ "$(installer_url_for_channel release)" == "https://example.test/install.sh" ]]' "release -> install.sh" || { teardown_env; return; }
  assert '[[ "$(installer_url_for_channel eap)" == "https://example.test/install-eap.sh" ]]' "eap -> install-eap.sh" || { teardown_env; return; }
  ok
  teardown_env
}

# 3. filter_args strips channel flags before they reach the binary.
test_filter_args_strips_channel_flags() {
  setup_env "filter_args"

  filter_args --eap run --channel=nightly --use-version=1.0 foo
  local joined="${FILTERED_ARGS[*]}"
  assert "[[ \"\$joined\" == \"run foo\" ]]" "channel + version flags stripped, rest preserved" || { teardown_env; return; }
  ok
  teardown_env
}

# 4. install_channel_oneshot installs the build and leaves `current` untouched.
test_oneshot_install_preserves_default() {
  setup_env "oneshot_install_preserves_default"
  seed_default_version "1.0"
  stub_curl_installer "9.9"

  install_channel_oneshot "eap"
  local rc=$?

  assert "[[ $rc -eq 0 ]]" "install_channel_oneshot should succeed" || { teardown_env; return; }
  assert "[[ \"\$CHANNEL_VERSION\" == 9.9 ]]" "CHANNEL_VERSION must be the installed version" || { teardown_env; return; }
  assert "[[ -x \"\$JUNIE_DATA/versions/9.9/junie/bin/junie\" ]]" "requested build must be installed" || { teardown_env; return; }
  assert '[[ "$(readlink "$JUNIE_DATA/current")" == "$JUNIE_DATA/versions/1.0" ]]' "current must still point at the default 1.0" || { teardown_env; return; }
  ok
  teardown_env
}

# 5. Pinned build via --use-version installs that exact build, not "latest".
test_oneshot_pinned_build() {
  setup_env "oneshot_pinned_build"
  seed_default_version "1.0"
  stub_curl_installer "9.9"   # "latest" would be 9.9; we pin 7.7

  install_channel_oneshot "eap" "7.7"
  local rc=$?

  assert "[[ $rc -eq 0 ]]" "install_channel_oneshot should succeed for a pinned build" || { teardown_env; return; }
  assert "[[ \"\$CHANNEL_VERSION\" == 7.7 ]]" "CHANNEL_VERSION must be the pinned build" || { teardown_env; return; }
  assert "[[ -x \"\$JUNIE_DATA/versions/7.7/junie/bin/junie\" ]]" "pinned build must be installed" || { teardown_env; return; }
  assert "[[ ! -d \"\$JUNIE_DATA/versions/9.9\" ]]" "latest build must NOT be installed when pinned" || { teardown_env; return; }
  assert '[[ "$(readlink "$JUNIE_DATA/current")" == "$JUNIE_DATA/versions/1.0" ]]' "current must still point at the default 1.0" || { teardown_env; return; }
  ok
  teardown_env
}

# 6. Unknown channel is rejected before any network call.
test_oneshot_rejects_unknown_channel() {
  setup_env "oneshot_rejects_unknown_channel"
  seed_default_version "1.0"

  install_channel_oneshot "bogus" 2>/dev/null
  local rc=$?

  assert "[[ $rc -ne 0 ]]" "unknown channel must fail" || { teardown_env; return; }
  ok
  teardown_env
}

# === Run ===
test_detect_channel_flag
test_channel_url_resolution
test_filter_args_strips_channel_flags
test_oneshot_install_preserves_default
test_oneshot_pinned_build
test_oneshot_rejects_unknown_channel

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

rm -f "$SHIM_SRC"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
