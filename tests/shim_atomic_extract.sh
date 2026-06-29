#!/bin/bash
#
# Self-test for the atomic-extraction shim embedded in install.sh.
#
# Usage:
#   bash tests/shim_atomic_extract.sh
#
# The script:
#   1. Extracts the shim source from install.sh between the SHIM_EOF heredoc markers.
#   2. Strips the trailing `main "$@"` line so sourcing doesn't run main().
#   3. Sources the shim under a synthetic $JUNIE_DATA (mktemp dir) and exercises
#      apply_pending_update against fake update payloads.
#   4. Asserts post-conditions on filesystem state and exit code.
#
# Each scenario runs in its own clean $JUNIE_DATA and either passes silently or
# prints an error and exits 1 at the first failed assertion.
#
# Requires: bash, unzip, zip, shasum or sha256sum.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="$REPO_ROOT/install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
  echo "FAIL: cannot find $INSTALL_SH" >&2
  exit 1
fi

for tool in unzip zip; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "SKIP: required tool '$tool' not installed; skipping shim tests" >&2
    exit 0
  fi
done

# === Extract shim source ===
SHIM_SRC="$(mktemp)"
awk '/^cat > "\$JUNIE_BIN\/junie" << '\''SHIM_EOF'\''$/{flag=1; next} /^SHIM_EOF$/{flag=0} flag' \
  "$INSTALL_SH" > "$SHIM_SRC"
# Remove the trailing `main "$@"` so sourcing the shim does not execute it.
sed -i.bak '/^main "\$@"$/d' "$SHIM_SRC" 2>/dev/null || sed -i '' '/^main "\$@"$/d' "$SHIM_SRC"
rm -f "$SHIM_SRC.bak"

# === Test harness ===
PASS=0
FAIL=0
CURRENT_TEST=""

setup_env() {
  CURRENT_TEST="$1"
  export JUNIE_DATA
  JUNIE_DATA="$(mktemp -d)"
  mkdir -p "$JUNIE_DATA/versions" "$JUNIE_DATA/updates"
  # Re-source the shim into the current shell each test so functions/vars are fresh.
  # shellcheck disable=SC1090
  source "$SHIM_SRC"
  # The shim sets `set -euo pipefail`. For tests we explicitly invoke functions
  # that are *expected* to fail (and we capture their exit code), so disable -e
  # in the test harness.
  set +e
  # Also drop any EXIT/INT/TERM traps inherited from previous runs of the
  # function we're about to test.
  trap - EXIT INT TERM
}

teardown_env() {
  rm -rf "$JUNIE_DATA"
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

# Build a zip with a working junie/bin/junie binary plus optional extra files.
# Usage: make_linux_zip <out_zip> [extra_relpath ...]
make_linux_zip() {
  local out="$1"; shift
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/junie/bin"
  printf '#!/bin/sh\necho junie %s\n' "$(basename "$out")" > "$d/junie/bin/junie"
  chmod +x "$d/junie/bin/junie"
  local extra
  for extra in "$@"; do
    mkdir -p "$d/$(dirname "$extra")"
    echo "payload-$extra" > "$d/$extra"
  done
  ( cd "$d" && zip -qr "$out" . )
  rm -rf "$d"
}

# Build a zip with the macOS .app layout.
make_app_zip() {
  local out="$1"
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/Applications/junie.app/Contents/MacOS"
  printf '#!/bin/sh\necho junie\n' > "$d/Applications/junie.app/Contents/MacOS/junie"
  chmod +x "$d/Applications/junie.app/Contents/MacOS/junie"
  ( cd "$d" && zip -qr "$out" . )
  rm -rf "$d"
}

# Build a zip that contains no recognisable junie binary.
make_empty_zip() {
  local out="$1"
  local d
  d="$(mktemp -d)"
  echo "garbage" > "$d/README.txt"
  ( cd "$d" && zip -qr "$out" . )
  rm -rf "$d"
}

write_manifest() {
  local version="$1" zip_path="$2"
  cat > "$JUNIE_DATA/updates/pending-update.json" <<EOF
{"version":"$version","zipPath":"$zip_path"}
EOF
}

# Stub `uname` so the shim's `zip_extractor` resolves zips to `ditto` (Darwin
# path). Only `uname -s` is overridden; any other invocation defers to the real
# binary. Pair with `stub_ditto_*` and remove with `unstub_macos`.
stub_macos_uname() {
  uname() {
    if [[ "${1:-}" == "-s" ]]; then echo "Darwin"; return 0; fi
    command uname "$@"
  }
}

# Stub `uname` so zip extraction follows the Linux `unzip` path, even when the
# test is running on macOS.
stub_linux_uname() {
  uname() {
    if [[ "${1:-}" == "-s" ]]; then echo "Linux"; return 0; fi
    command uname "$@"
  }
}

# Stub `ditto -x -k SRC DST` to extract via unzip (which CI has), emulating a
# working macOS ditto. Any other ditto invocation is a no-op success.
stub_ditto_ok() {
  ditto() {
    if [[ "${1:-}" == "-x" && "${2:-}" == "-k" ]]; then
      unzip -q "$3" -d "$4"
      return $?
    fi
    return 0
  }
}

# Stub `ditto` so extraction always fails, emulating a broken/incompatible
# ditto on macOS (exercises the new ditto branch's fail-and-preserve path).
stub_ditto_fail() {
  ditto() { return 1; }
}

unstub_macos() {
  unset -f uname ditto 2>/dev/null || true
}

# Seed a pre-existing version dir, used as "the previous working version".
seed_version() {
  local v="$1"; shift
  mkdir -p "$JUNIE_DATA/versions/$v/junie/bin"
  printf '#!/bin/sh\necho old %s\n' "$v" > "$JUNIE_DATA/versions/$v/junie/bin/junie"
  chmod +x "$JUNIE_DATA/versions/$v/junie/bin/junie"
  local extra
  for extra in "$@"; do
    mkdir -p "$JUNIE_DATA/versions/$v/$(dirname "$extra")"
    echo "stale" > "$JUNIE_DATA/versions/$v/$extra"
  done
  ln -sfn "$JUNIE_DATA/versions/$v" "$JUNIE_DATA/current"
}

# === Scenarios ===

# 1. Happy-path zip update: 1.0 -> 1.1
test_happy_path() {
  setup_env "happy_path"
  seed_version "1.0"
  local zip="$JUNIE_DATA/updates/u.zip"
  make_linux_zip "$zip"
  write_manifest "1.1" "$zip"

  apply_pending_update
  local rc=$?

  assert "[[ $rc -eq 0 ]]" "apply_pending_update should succeed" || { teardown_env; return; }
  assert "[[ -x \"$JUNIE_DATA/versions/1.1/junie/bin/junie\" ]]" "new version binary must exist + be executable" || { teardown_env; return; }
  assert "[[ -x \"$JUNIE_DATA/versions/1.0/junie/bin/junie\" ]]" "previous version must remain intact" || { teardown_env; return; }
  assert '[[ "$(readlink "$JUNIE_DATA/current")" == "$JUNIE_DATA/versions/1.1" ]]' "current must point at 1.1" || { teardown_env; return; }
  assert "[[ ! -f \"$JUNIE_DATA/updates/pending-update.json\" ]]" "manifest must be deleted after success" || { teardown_env; return; }
  assert "[[ ! -f \"$zip\" ]]" "zip must be deleted after success" || { teardown_env; return; }
  assert "! ls -A \"$JUNIE_DATA/versions\"/.*.tmp.* > /dev/null 2>&1" "no staging dirs left behind" || { teardown_env; return; }
  ok
  teardown_env
}

# 2. Same-version reinstall must NOT leave stale files behind
test_same_version_reinstall() {
  setup_env "same_version_reinstall"
  seed_version "1.0" "junie/bin/stale.txt"
  local zip="$JUNIE_DATA/updates/u.zip"
  make_linux_zip "$zip"
  write_manifest "1.0" "$zip"

  apply_pending_update
  local rc=$?

  assert "[[ $rc -eq 0 ]]" "apply_pending_update should succeed" || { teardown_env; return; }
  assert "[[ ! -f \"$JUNIE_DATA/versions/1.0/junie/bin/stale.txt\" ]]" "stale file from old tree must be gone (wholesale replacement)" || { teardown_env; return; }
  assert "[[ -x \"$JUNIE_DATA/versions/1.0/junie/bin/junie\" ]]" "new binary must be in place" || { teardown_env; return; }
  ok
  teardown_env
}

# 3. macOS .app layout: replace bundle wholesale
test_app_bundle_layout() {
  setup_env "app_bundle_layout"
  mkdir -p "$JUNIE_DATA/versions/2.0/Applications/junie.app/Contents/MacOS"
  mkdir -p "$JUNIE_DATA/versions/2.0/Applications/junie.app/Contents/Resources"
  printf '#!/bin/sh\necho old\n' > "$JUNIE_DATA/versions/2.0/Applications/junie.app/Contents/MacOS/junie"
  chmod +x "$JUNIE_DATA/versions/2.0/Applications/junie.app/Contents/MacOS/junie"
  echo "stale-signed-resource" > "$JUNIE_DATA/versions/2.0/Applications/junie.app/Contents/Resources/old.plist"
  ln -sfn "$JUNIE_DATA/versions/2.0" "$JUNIE_DATA/current"

  local zip="$JUNIE_DATA/updates/u.zip"
  make_app_zip "$zip"
  write_manifest "2.0" "$zip"

  apply_pending_update
  local rc=$?

  assert "[[ $rc -eq 0 ]]" "apply_pending_update should succeed" || { teardown_env; return; }
  assert "[[ -x \"$JUNIE_DATA/versions/2.0/Applications/junie.app/Contents/MacOS/junie\" ]]" "new app binary must exist" || { teardown_env; return; }
  assert "[[ ! -f \"$JUNIE_DATA/versions/2.0/Applications/junie.app/Contents/Resources/old.plist\" ]]" "stale signed resource must be removed" || { teardown_env; return; }
  ok
  teardown_env
}

# 4. Corrupt zip -> previous version intact, manifest + zip preserved
test_corrupt_zip_preserves_artifacts() {
  setup_env "corrupt_zip"
  seed_version "1.0"
  local zip="$JUNIE_DATA/updates/u.zip"
  printf 'not-a-real-zip' > "$zip"
  write_manifest "1.1" "$zip"

  apply_pending_update
  local rc=$?

  assert "[[ $rc -ne 0 ]]" "apply_pending_update must fail on corrupt zip" || { teardown_env; return; }
  assert "[[ ! -d \"$JUNIE_DATA/versions/1.1\" ]]" "no partial 1.1 dir must be created" || { teardown_env; return; }
  assert "[[ -x \"$JUNIE_DATA/versions/1.0/junie/bin/junie\" ]]" "previous version must remain intact" || { teardown_env; return; }
  assert '[[ "$(readlink "$JUNIE_DATA/current")" == "$JUNIE_DATA/versions/1.0" ]]' "current must still point at 1.0" || { teardown_env; return; }
  assert "[[ -f \"$JUNIE_DATA/updates/pending-update.json\" ]]" "manifest must be preserved for retry" || { teardown_env; return; }
  assert "[[ -f \"$zip\" ]]" "zip must be preserved for retry" || { teardown_env; return; }
  assert "! ls -A \"$JUNIE_DATA/versions\"/.*.tmp.* > /dev/null 2>&1" "no staging dirs left behind" || { teardown_env; return; }
  ok
  teardown_env
}

# 5. Missing unzip on a zip payload -> no silent tar fallback, artifacts preserved
test_missing_unzip_tool() {
  setup_env "missing_unzip"
  stub_linux_uname
  seed_version "1.0"
  local zip="$JUNIE_DATA/updates/u.zip"
  make_linux_zip "$zip"
  write_manifest "1.1" "$zip"

  # Stub has_command to claim unzip is missing.
  has_command() {
    if [[ "$1" == "unzip" ]]; then return 1; fi
    command -v "$1" > /dev/null 2>&1
  }

  apply_pending_update
  local rc=$?

  unset -f has_command
  unset -f uname 2>/dev/null || true

  assert "[[ $rc -ne 0 ]]" "apply_pending_update must fail when unzip missing on zip payload" || { teardown_env; return; }
  assert "[[ ! -d \"$JUNIE_DATA/versions/1.1\" ]]" "no new version dir on failure" || { teardown_env; return; }
  assert "[[ -f \"$JUNIE_DATA/updates/pending-update.json\" ]]" "manifest must be preserved for retry" || { teardown_env; return; }
  assert "[[ -f \"$zip\" ]]" "zip must be preserved for retry" || { teardown_env; return; }
  ok
  teardown_env
}

# 6. Validation failure (zip contains no junie binary) -> artifacts preserved
test_validation_failure_no_binary() {
  setup_env "validation_failure"
  seed_version "1.0"
  local zip="$JUNIE_DATA/updates/u.zip"
  make_empty_zip "$zip"
  write_manifest "1.1" "$zip"

  apply_pending_update
  local rc=$?

  assert "[[ $rc -ne 0 ]]" "apply_pending_update must fail when no binary found" || { teardown_env; return; }
  assert "[[ ! -d \"$JUNIE_DATA/versions/1.1\" ]]" "no new version dir on validation failure" || { teardown_env; return; }
  assert "[[ -f \"$JUNIE_DATA/updates/pending-update.json\" ]]" "manifest must be preserved for retry" || { teardown_env; return; }
  assert "[[ -f \"$zip\" ]]" "zip must be preserved for retry" || { teardown_env; return; }
  assert "! ls -A \"$JUNIE_DATA/versions\"/.*.tmp.* > /dev/null 2>&1" "trap must remove staging dir on failure" || { teardown_env; return; }
  ok
  teardown_env
}

# 7. Poisoned manifest (missing fields) -> manifest deleted (existing behavior)
test_poisoned_manifest() {
  setup_env "poisoned_manifest"
  seed_version "1.0"
  echo '{"foo":"bar"}' > "$JUNIE_DATA/updates/pending-update.json"

  apply_pending_update
  local rc=$?

  assert "[[ $rc -ne 0 ]]" "apply_pending_update must fail on invalid manifest" || { teardown_env; return; }
  assert "[[ ! -f \"$JUNIE_DATA/updates/pending-update.json\" ]]" "manifest must be deleted on poisoned manifest" || { teardown_env; return; }
  assert "[[ -x \"$JUNIE_DATA/versions/1.0/junie/bin/junie\" ]]" "previous version must remain intact" || { teardown_env; return; }
  ok
  teardown_env
}

# 9. macOS happy path: zip resolves to `ditto`, bundle swapped, current flipped.
test_macos_ditto_happy_path() {
  setup_env "macos_ditto_happy_path"
  stub_macos_uname
  stub_ditto_ok
  seed_version "1.0"
  local zip="$JUNIE_DATA/updates/u.zip"
  make_app_zip "$zip"
  write_manifest "1.1" "$zip"

  # Sanity: on the stubbed-Darwin path a zip must resolve to the ditto extractor.
  assert '[[ "$(detect_archive_type "$zip")" == "ditto" ]]' "zip must resolve to ditto on macOS" || { unstub_macos; teardown_env; return; }

  apply_pending_update
  local rc=$?

  assert "[[ $rc -eq 0 ]]" "apply_pending_update should succeed via ditto" || { unstub_macos; teardown_env; return; }
  assert "[[ -x \"$JUNIE_DATA/versions/1.1/Applications/junie.app/Contents/MacOS/junie\" ]]" "new app binary must exist after ditto extract" || { unstub_macos; teardown_env; return; }
  assert '[[ "$(readlink "$JUNIE_DATA/current")" == "$JUNIE_DATA/versions/1.1" ]]' "current must point at 1.1" || { unstub_macos; teardown_env; return; }
  assert "[[ ! -f \"$JUNIE_DATA/updates/pending-update.json\" ]]" "manifest must be deleted after success" || { unstub_macos; teardown_env; return; }
  assert "[[ ! -f \"$zip\" ]]" "zip must be deleted after success" || { unstub_macos; teardown_env; return; }
  assert "! ls -A \"$JUNIE_DATA/versions\"/.*.tmp.* > /dev/null 2>&1" "no staging dirs left behind" || { unstub_macos; teardown_env; return; }
  ok
  unstub_macos
  teardown_env
}

# 10. macOS ditto failure -> no unzip fallback, artifacts preserved for retry.
test_macos_ditto_failure_preserves_artifacts() {
  setup_env "macos_ditto_failure"
  stub_macos_uname
  stub_ditto_fail
  seed_version "1.0"
  local zip="$JUNIE_DATA/updates/u.zip"
  make_app_zip "$zip"
  write_manifest "1.1" "$zip"

  apply_pending_update
  local rc=$?

  assert "[[ $rc -ne 0 ]]" "apply_pending_update must fail when ditto fails" || { unstub_macos; teardown_env; return; }
  assert "[[ ! -d \"$JUNIE_DATA/versions/1.1\" ]]" "no partial 1.1 dir must be created" || { unstub_macos; teardown_env; return; }
  assert "[[ -x \"$JUNIE_DATA/versions/1.0/junie/bin/junie\" ]]" "previous version must remain intact" || { unstub_macos; teardown_env; return; }
  assert '[[ "$(readlink "$JUNIE_DATA/current")" == "$JUNIE_DATA/versions/1.0" ]]' "current must still point at 1.0" || { unstub_macos; teardown_env; return; }
  assert "[[ -f \"$JUNIE_DATA/updates/pending-update.json\" ]]" "manifest must be preserved for retry" || { unstub_macos; teardown_env; return; }
  assert "[[ -f \"$zip\" ]]" "zip must be preserved for retry" || { unstub_macos; teardown_env; return; }
  assert "! ls -A \"$JUNIE_DATA/versions\"/.*.tmp.* > /dev/null 2>&1" "no staging dirs left behind" || { unstub_macos; teardown_env; return; }
  ok
  unstub_macos
  teardown_env
}

# 8. No pending update -> no-op success
test_no_pending_update() {
  setup_env "no_pending_update"
  seed_version "1.0"

  apply_pending_update
  local rc=$?

  assert "[[ $rc -eq 0 ]]" "apply_pending_update must succeed when no manifest present" || { teardown_env; return; }
  ok
  teardown_env
}

# === Run ===
test_happy_path
test_same_version_reinstall
test_app_bundle_layout
test_corrupt_zip_preserves_artifacts
test_missing_unzip_tool
test_validation_failure_no_binary
test_poisoned_manifest
test_macos_ditto_happy_path
test_macos_ditto_failure_preserves_artifacts
test_no_pending_update

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

rm -f "$SHIM_SRC"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
