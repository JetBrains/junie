#!/bin/bash
# DO NOT EDIT — generated from templates/install.sh.template by templates/generate.sh
#
# Junie CLI Installer
# Usage: curl -fsSL https://junie.jetbrains.com/install.sh | bash
#
# To install a specific version:
#   curl -fsSL https://junie.jetbrains.com/install.sh | JUNIE_VERSION=656.1 bash
#

set -euo pipefail

CHANNEL="experimental"
UPDATE_INFO_URL="https://raw.githubusercontent.com/jetbrains-junie/junie/main/update-info-experimental.jsonl"
INSTALL_TAG="<install_tag>"
GITHUB_RELEASES="https://github.com/jetbrains-junie/junie/releases"
JUNIE_BIN="$HOME/.local/bin"
JUNIE_DATA="$HOME/.local/share/junie"

# One-shot mode (set by the shim for `junie --<channel>`): install/refresh this
# channel's latest build but do NOT touch the existing shim, the `current`
# symlink, or PATH -- the default channel must stay intact. When set, the
# installed version is reported back via $JUNIE_ONESHOT_VERSION_FILE.
ONESHOT="${JUNIE_ONESHOT:-}"

log() { echo "[Junie] $*"; }
log_error() { echo "[Junie] ERROR: $*" >&2; }

# Ensure the required archive extractor is available before we start downloading
# anything. We fail early with an actionable, OS-aware install hint so users on
# minimal images (containers, fresh VPS, etc.) aren't stuck staring at a cryptic
# `command not found` halfway through the install.
#
# On macOS we require `ditto` (Apple's archive tool, part of the base install)
# so notarized/code-signed .app bundles are reconstructed exactly. Info-ZIP
# `unzip` mangles symlinks/permissions/xattrs and breaks the signature seal,
# which on Apple Silicon yields "is damaged and cannot be opened." On Linux we
# require `unzip`.
require_extractor() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v ditto > /dev/null 2>&1; then
      return 0
    fi
    log_error "'ditto' is required to install Junie on macOS, but it was not found in PATH."
    log_error "'ditto' ships with macOS at /usr/bin/ditto; ensure /usr/bin is on your PATH and re-run this installer."
    exit 1
  fi
  if command -v unzip > /dev/null 2>&1; then
    return 0
  fi
  log_error "'unzip' is required to install Junie, but it was not found in PATH."
  if command -v apt-get > /dev/null 2>&1; then
    log_error "Install it with: sudo apt-get update && sudo apt-get install -y unzip"
  elif command -v dnf > /dev/null 2>&1; then
    log_error "Install it with: sudo dnf install -y unzip"
  elif command -v yum > /dev/null 2>&1; then
    log_error "Install it with: sudo yum install -y unzip"
  elif command -v apk > /dev/null 2>&1; then
    log_error "Install it with: sudo apk add unzip"
  elif command -v pacman > /dev/null 2>&1; then
    log_error "Install it with: sudo pacman -S --noconfirm unzip"
  elif command -v zypper > /dev/null 2>&1; then
    log_error "Install it with: sudo zypper install -y unzip"
  else
    log_error "Install the 'unzip' package using your system package manager, then re-run this installer."
  fi
  exit 1
}
require_extractor

# Calculate SHA-256 checksum
sha256sum_file() {
  local file="$1"
  if command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$file" | cut -d' ' -f1
  elif command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$file" | cut -d' ' -f1
  else
    log "Warning: No SHA-256 tool available, skipping checksum verification"
    echo ""
  fi
}

# Whether a version directory already contains a valid, executable binary.
# Used in one-shot mode to skip a redundant re-download of an already-installed
# latest build. (Inline equivalent of the shim's get_binary_path_in check.)
oneshot_target_ready() {
  local dir="$1" bin=""
  if [[ -d "$dir/Applications/junie.app" ]]; then
    bin="$dir/Applications/junie.app/Contents/MacOS/junie"
  elif [[ -f "$dir/junie/bin/junie" ]]; then
    bin="$dir/junie/bin/junie"
  elif [[ -f "$dir/junie" ]]; then
    bin="$dir/junie"
  fi
  [[ -n "$bin" && -x "$bin" ]]
}

# Fetch latest version info from update-info JSONL
fetch_latest_version() {
  log "Fetching latest version info..."
  local jsonl
  jsonl=$(curl -fsSL "$UPDATE_INFO_URL")

  # Find the entry with the greatest numeric version for our platform.
  local entry
  entry=$(echo "$jsonl" | grep "\"platform\":\"$PLATFORM\"" |
    sed 's/.*"version":"\([^"]*\)".*/\1\	&/' |
    LC_ALL=C sort -t. -k1,1n -k2,2n | tail -1 | cut -f2-)

  if [[ -z "$entry" ]]; then
    log_error "No release found for platform: $PLATFORM"
    exit 1
  fi

  # Parse fields from JSON
  VERSION=$(echo "$entry" | grep -o '"version":"[^"]*"' | sed 's/"version":"\([^"]*\)"/\1/')
  DOWNLOAD_URL=$(echo "$entry" | grep -o '"downloadUrl":"[^"]*"' | sed 's/"downloadUrl":"\([^"]*\)"/\1/')
  SHA256=$(echo "$entry" | grep -o '"sha256":"[^"]*"' | sed 's/"sha256":"\([^"]*\)"/\1/')

  if [[ -z "$VERSION" || -z "$DOWNLOAD_URL" ]]; then
    log_error "Failed to parse version info"
    exit 1
  fi
}

# Look up the SHA-256 checksum for a specific version+platform from the
# update-info JSONL so that explicit JUNIE_VERSION requests can still be
# integrity-checked. Echoes the checksum if found, or an empty string otherwise.
# Best-effort: network/parse failures or a version that isn't listed simply
# result in an empty checksum (the caller decides how to proceed).
fetch_version_sha256() {
  local want_version="$1"
  local jsonl entry
  jsonl=$(curl -fsSL "$UPDATE_INFO_URL" 2> /dev/null) || return 0

  # Match the entry for the exact version (trailing quote anchors the match so
  # "1.1" does not match "1.12") and our platform.
  entry=$(echo "$jsonl" | grep "\"version\":\"$want_version\"" | grep "\"platform\":\"$PLATFORM\"" | tail -1)
  [[ -z "$entry" ]] && return 0

  echo "$entry" | grep -o '"sha256":"[^"]*"' | sed 's/"sha256":"\([^"]*\)"/\1/'
}

# Detect platform
OS=$(uname -s)
ARCH=$(uname -m)

case "$OS" in
  Linux)  OS_NAME="linux" ;;
  Darwin) OS_NAME="macos" ;;
  *)      log_error "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64)   ARCH_NAME="amd64" ;;
  aarch64|arm64)  ARCH_NAME="aarch64" ;;
  *)              log_error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

PLATFORM="${OS_NAME}-${ARCH_NAME}"

# Determine version: use JUNIE_VERSION env var if set, otherwise fetch latest
if [[ -n "${JUNIE_VERSION:-}" ]]; then
  VERSION="$JUNIE_VERSION"
  DOWNLOAD_URL="$GITHUB_RELEASES/download/${VERSION}/junie-${CHANNEL}-${VERSION}-${PLATFORM}.zip"
  log "Using specified version: $VERSION"
  # Even for an explicitly requested version, try to look up its published
  # checksum so the download is still integrity-checked. If the version isn't
  # listed in update-info we proceed without a checksum (best-effort).
  SHA256=$(fetch_version_sha256 "$VERSION")
  if [[ -n "$SHA256" ]]; then
    log "Found published checksum for version $VERSION"
  else
    log "Warning: No checksum found for version $VERSION; proceeding without integrity verification"
  fi
else
  fetch_latest_version
fi

log "Installing Junie $VERSION for $PLATFORM..."

# Create directories
mkdir -p "$JUNIE_BIN"
mkdir -p "$JUNIE_DATA/versions"
mkdir -p "$JUNIE_DATA/updates"

if [[ -n "$INSTALL_TAG" && "$INSTALL_TAG" != "<install_tag>" ]]; then
  mkdir -p "$JUNIE_DATA/misc"
  printf '%s' "$INSTALL_TAG" > "$JUNIE_DATA/misc/install_tag"
fi

# Install shim (skipped in one-shot mode so the existing shim stays intact)
if [[ -z "$ONESHOT" ]]; then
cat > "$JUNIE_BIN/junie" << 'SHIM_EOF'
#!/bin/bash
#
# JUNIE_MANAGED_SHIM
#
# Junie CLI Shim
#
# This script is the entry point for Junie CLI. It handles:
# 1. Applying pending updates before launching
# 2. Version selection via JUNIE_VERSION env or --use-version flag
# 3. Executing the appropriate version binary
#
# Installation locations:
#   Shim:     ~/.local/bin/junie
#   Data:     ~/.local/share/junie/
#   Versions: ~/.local/share/junie/versions/<version>/junie
#   Updates:  ~/.local/share/junie/updates/

set -euo pipefail

# === Configuration ===
JUNIE_DATA="${JUNIE_DATA:-$HOME/.local/share/junie}"
VERSIONS_DIR="$JUNIE_DATA/versions"
UPDATES_DIR="$JUNIE_DATA/updates"
CURRENT_LINK="$JUNIE_DATA/current"
PENDING_UPDATE="$UPDATES_DIR/pending-update.json"

# Base URL serving the channel installers (override for testing).
INSTALL_BASE_URL="${JUNIE_INSTALL_BASE_URL:-https://junie.jetbrains.com}"
# Known update channels. Injected from templates/channels.tsv by generate.sh,
# so this list (and the flag matching derived from it) has a single source.
KNOWN_CHANNELS="release eap nightly experimental"

# Persistent upgrade log. Lives under ~/.junie/logs (separate from the data dir,
# so wiping ~/.local/share/junie during reinstall does not lose update history).
# Always APPEND -- never truncate.
UPGRADE_LOG_DIR="${JUNIE_LOG_DIR:-$HOME/.junie/logs}"
UPGRADE_LOG="$UPGRADE_LOG_DIR/upgrade.log"

# === Utility Functions ===

# Log message to stderr
log() {
  echo "[Junie] $*" >&2
}

# Append a timestamped line to the upgrade log. Best-effort: failure to write
# (e.g. read-only HOME) must never break the update flow itself, so all errors
# are swallowed. Always opens the file in append mode (>>).
log_upgrade() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "-")
  { mkdir -p "$UPGRADE_LOG_DIR" 2>/dev/null && printf '%s [pid=%s] %s\n' "$ts" "$$" "$*" >> "$UPGRADE_LOG"; } 2>/dev/null || true
}

# Convenience: echo to stderr AND append to upgrade.log.
log_both() {
  log "$*"
  log_upgrade "$*"
}

# Check if a command exists
has_command() {
  command -v "$1" > /dev/null 2>&1
}

# Parse JSON field (basic, works without jq)
# Usage: parse_json "field" < file.json
parse_json_field() {
  local field="$1"
  # Extract value for "field": "value" or "field": number
  grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true
}

# Parse JSON field with jq if available, fallback to grep
get_json_field() {
  local file="$1"
  local field="$2"

  if has_command jq; then
    jq -r ".$field // empty" "$file" 2>/dev/null || true
  else
    parse_json_field "$field" < "$file"
  fi
}

# Calculate SHA-256 checksum
sha256sum_file() {
  local file="$1"
  if has_command shasum; then
    shasum -a 256 "$file" | cut -d' ' -f1
  elif has_command sha256sum; then
    sha256sum "$file" | cut -d' ' -f1
  else
    log "Warning: No SHA-256 tool available, skipping checksum verification"
    echo ""
  fi
}

# Get binary path for an arbitrary version directory.
# Handles different package structures (macOS app bundle, Linux, direct binary).
get_binary_path_in() {
  local version_dir="$1"

  # macOS: look for .app bundle
  if [[ -d "$version_dir/Applications/junie.app" ]]; then
    echo "$version_dir/Applications/junie.app/Contents/MacOS/junie"
  # Linux: look for junie/bin/junie
  elif [[ -f "$version_dir/junie/bin/junie" ]]; then
    echo "$version_dir/junie/bin/junie"
  # Fallback: direct junie binary
  elif [[ -f "$version_dir/junie" ]]; then
    echo "$version_dir/junie"
  else
    echo ""
  fi
}

# Get binary path for a given version (by name).
get_binary_path() {
  local version="$1"
  get_binary_path_in "$VERSIONS_DIR/$version"
}

# Pick the zip extractor for the current OS. On macOS we must use `ditto`
# (Apple's archive tool) so notarized/code-signed .app bundles are
# reconstructed exactly -- symlinks, permissions, and extended attributes
# intact. Info-ZIP `unzip` mangles those and breaks the signature seal, which
# on Apple Silicon yields "is damaged and cannot be opened." On Linux we keep
# `unzip`.
zip_extractor() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ditto"
  else
    echo "unzip"
  fi
}

# Detect the archive type of $1 by extension or magic bytes.
# Echoes the zip extractor ("unzip" or "ditto"), "tar", or "" if unknown.
detect_archive_type() {
  local file="$1"
  case "$file" in
    *.zip|*.ZIP) zip_extractor; return 0 ;;
    *.tar.gz|*.tgz|*.TAR.GZ|*.TGZ) echo "tar"; return 0 ;;
  esac
  local magic
  magic=$(head -c 4 "$file" 2>/dev/null | od -An -tx1 | tr -d ' \n' 2>/dev/null || echo "")
  case "$magic" in
    504b0304*|504b0506*|504b0708*) zip_extractor ;;
    1f8b*)                          echo "tar"   ;;
    *)                              echo ""      ;;
  esac
}

# === Defensive Sanitization ===
#
# JUNIE-2957 defense: drop update artifacts that are empty or unparseable
# BEFORE we (or the binary's own update path) act on them.
#
# A legitimate in-flight update writes the manifest fully and only then renames
# it into place, so an existing `pending-update.json` or
# `pending-update.json.processing` that is zero bytes, or that lacks the
# required `version` / `zipPath` fields, can only be junk -- a leftover from a
# prior crash, a partial write, or content planted by mistake. We must not feed
# that to either `apply_pending_update` below or to the launched binary, which
# may otherwise try to "resolve" paths derived from CWD/EJ_RUNNER_PWD.
#
# Best-effort: any rm failure is swallowed; the regular `apply_pending_update`
# path will then handle the file conservatively or skip it.
sanitize_pending_updates() {
  [[ -d "$UPDATES_DIR" ]] || return 0
  local f v z
  for f in "$PENDING_UPDATE" "$UPDATES_DIR/pending-update.json.processing"; do
    [[ -f "$f" ]] || continue
    if [[ ! -s "$f" ]]; then
      log_both "Removing zero-byte update artifact: $f"
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    v=$(get_json_field "$f" "version")
    z=$(get_json_field "$f" "zipPath")
    if [[ -z "$v" || -z "$z" ]]; then
      log_both "Removing unparseable update artifact (missing version/zipPath): $f"
      rm -f "$f" 2>/dev/null || true
    fi
  done
}

# === Apply Pending Update ===
#
# Atomic extraction strategy:
#   1. Verify manifest and checksum.
#   2. Extract into a staging directory inside $VERSIONS_DIR (same FS, so `mv` is a rename).
#   3. Validate the resolved binary in the staging tree is executable.
#   4. Swap the staging dir into $VERSIONS_DIR/$version (replacing any previous tree
#      wholesale -- important for macOS .app code-signing consistency).
#   5. Flip the `current` symlink.
#   6. Only then delete the zip + pending manifest.
#
# Failure modes:
#   - Poisoned manifest (missing fields, missing zip, checksum mismatch):
#       drop manifest + zip, return non-zero.
#   - Retryable failure (extraction error, validation failure, missing extractor):
#       preserve manifest + zip so the next launch retries, return non-zero.
# In all failure cases $VERSIONS_DIR/$version is left untouched from before the attempt.
apply_pending_update() {
  if [[ ! -f "$PENDING_UPDATE" ]]; then
    return 0
  fi

  log_both "Applying pending update (manifest=$PENDING_UPDATE)"

  # Parse manifest
  local version zip_path sha256
  version=$(get_json_field "$PENDING_UPDATE" "version")
  zip_path=$(get_json_field "$PENDING_UPDATE" "zipPath")
  sha256=$(get_json_field "$PENDING_UPDATE" "sha256")
  log_upgrade "manifest parsed: version='$version' zipPath='$zip_path' sha256='${sha256:-<none>}'"

  if [[ -z "$version" || -z "$zip_path" ]]; then
    log_both "Invalid pending update manifest, skipping"
    rm -f "$PENDING_UPDATE"
    return 1
  fi

  if [[ ! -f "$zip_path" ]]; then
    log_both "Update file not found: $zip_path"
    rm -f "$PENDING_UPDATE"
    return 1
  fi

  local zip_size=""
  zip_size=$(wc -c < "$zip_path" 2>/dev/null | tr -d ' ' || echo "?")
  log_upgrade "archive present: path='$zip_path' size_bytes=$zip_size"

  # Verify checksum if available
  if [[ -n "$sha256" ]]; then
    log_upgrade "checksum: starting SHA-256 validation (expected=$sha256)"
    local actual_sha256
    actual_sha256=$(sha256sum_file "$zip_path")
    log_upgrade "checksum: computed actual='${actual_sha256:-<unavailable>}'"

    if [[ -z "$actual_sha256" ]]; then
      log_upgrade "checksum: skipped (no SHA-256 tool available)"
    elif ! echo "$actual_sha256" | grep -qi "^${sha256}$"; then
      # Case-insensitive comparison (compatible with bash 3.x on macOS)
      log_both "Checksum mismatch, skipping update"
      log_both "Expected: $sha256"
      log_both "Got: $actual_sha256"
      log_upgrade "checksum: FAIL -- dropping manifest and archive"
      rm -f "$PENDING_UPDATE" "$zip_path"
      return 1
    else
      log_upgrade "checksum: OK"
    fi
  else
    log_upgrade "checksum: skipped (manifest has no sha256)"
  fi

  # Pick the right extractor by archive type. No silent wrong-tool fallback
  # (don't run tar on a zip).
  local extractor
  extractor=$(detect_archive_type "$zip_path")
  log_upgrade "extractor: detected='${extractor:-<unknown>}' for '$zip_path'"
  if [[ -z "$extractor" ]]; then
    log_both "Error: Unknown archive type for $zip_path; preserving update for retry"
    return 1
  fi
  if ! has_command "$extractor"; then
    log_both "Error: Required extraction tool '$extractor' not found; install it and retry"
    return 1
  fi

  # Staging path lives inside $VERSIONS_DIR so the final `mv` is a same-filesystem rename.
  local staging="$VERSIONS_DIR/.$version.tmp.$$"
  local old_dir="$VERSIONS_DIR/.$version.old.$$"

  # Catch signals during extraction so Ctrl-C / SIGTERM doesn't leave a partial
  # staging dir behind. (EXIT trap is not reliable for *function* returns, so we
  # also do explicit cleanup before every error return below.)
  # shellcheck disable=SC2064
  trap "rm -rf \"$staging\" \"$old_dir\"; trap - INT TERM; exit 130" INT TERM

  rm -rf "$staging"
  if ! mkdir -p "$staging"; then
    log_both "Error: Failed to create staging directory $staging"
    trap - INT TERM
    return 1
  fi
  log_upgrade "staging: created '$staging'"

  log_both "Extracting to $staging..."
  log_upgrade "extract: starting tool='$extractor' src='$zip_path' dst='$staging'"

  if [[ "$extractor" == "unzip" ]]; then
    if ! unzip -q "$zip_path" -d "$staging"; then
      log_both "Error: Failed to extract $zip_path; preserving update for retry"
      log_upgrade "extract: FAIL (unzip exit non-zero)"
      rm -rf "$staging"
      trap - INT TERM
      return 1
    fi
  elif [[ "$extractor" == "ditto" ]]; then
    # macOS: use ditto so the signed .app bundle is reconstructed exactly.
    # No unzip fallback -- on failure we preserve the update for retry to
    # avoid installing a structurally broken (and thus "damaged") bundle.
    if ! ditto -x -k "$zip_path" "$staging"; then
      log_both "Error: Failed to extract $zip_path; preserving update for retry"
      log_upgrade "extract: FAIL (ditto exit non-zero)"
      rm -rf "$staging"
      trap - INT TERM
      return 1
    fi
  else
    if ! tar -xzf "$zip_path" -C "$staging"; then
      log_both "Error: Failed to extract $zip_path; preserving update for retry"
      log_upgrade "extract: FAIL (tar exit non-zero)"
      rm -rf "$staging"
      trap - INT TERM
      return 1
    fi
  fi
  log_upgrade "extract: OK"

  # Resolve the binary against the staging dir and ensure it is executable.
  local staged_binary
  staged_binary=$(get_binary_path_in "$staging")
  if [[ -z "$staged_binary" ]]; then
    log_both "Error: No junie binary found in extracted payload; preserving update for retry"
    rm -rf "$staging"
    trap - INT TERM
    return 1
  fi
  log_upgrade "binary: resolved '$staged_binary'"
  chmod +x "$staged_binary" 2>/dev/null || true
  if [[ ! -x "$staged_binary" ]]; then
    log_both "Error: Extracted binary is not executable: $staged_binary"
    rm -rf "$staging"
    trap - INT TERM
    return 1
  fi

  # Remove quarantine on macOS (best-effort)
  xattr -dr com.apple.quarantine "$staging" 2>/dev/null || true

  # Atomic swap: move existing version aside, then rename staging into place.
  # We replace the whole tree so macOS .app bundles stay code-sign-consistent.
  log_upgrade "atomic-move: target='$VERSIONS_DIR/$version'"
  if [[ -e "$VERSIONS_DIR/$version" ]]; then
    rm -rf "$old_dir"
    log_upgrade "atomic-move: moving existing tree aside -> '$old_dir'"
    if ! mv "$VERSIONS_DIR/$version" "$old_dir"; then
      log_both "Error: Failed to move existing version aside"
      log_upgrade "atomic-move: FAIL (mv existing -> old_dir)"
      rm -rf "$staging"
      trap - INT TERM
      return 1
    fi
  fi

  if ! mv "$staging" "$VERSIONS_DIR/$version"; then
    log_both "Error: Failed to install new version into $VERSIONS_DIR/$version"
    log_upgrade "atomic-move: FAIL (mv staging -> target); attempting rollback"
    # Try to restore previous version if we moved it aside
    if [[ -e "$old_dir" && ! -e "$VERSIONS_DIR/$version" ]]; then
      mv "$old_dir" "$VERSIONS_DIR/$version" 2>/dev/null \
        && log_upgrade "atomic-move: rollback OK" \
        || log_upgrade "atomic-move: rollback FAILED"
    fi
    rm -rf "$staging" "$old_dir"
    trap - INT TERM
    return 1
  fi
  log_upgrade "atomic-move: rename OK ('$staging' -> '$VERSIONS_DIR/$version')"

  # Best-effort cleanup of the previous tree
  rm -rf "$old_dir" 2>/dev/null || true

  # Flip the current symlink atomically.
  ln -sfn "$VERSIONS_DIR/$version" "$CURRENT_LINK"
  log_upgrade "symlink: 'current' -> '$VERSIONS_DIR/$version'"

  # Drop pending artifacts only after a fully successful swap.
  rm -f "$zip_path" "$PENDING_UPDATE"
  log_upgrade "cleanup: removed zip='$zip_path' and manifest='$PENDING_UPDATE'"

  trap - INT TERM

  log_both "Updated to version $version"
  return 0
}

# === Resolve Version ===
resolve_version() {
  local version=""

  # Priority 1: --use-version flag
  for arg in "$@"; do
    case "$arg" in
      --use-version=*)
        version="${arg#--use-version=}"
        break
        ;;
    esac
  done

  # Priority 2: JUNIE_VERSION environment variable
  if [[ -z "$version" && -n "${JUNIE_VERSION:-}" ]]; then
    version="$JUNIE_VERSION"
  fi

  # Priority 3: current symlink
  if [[ -z "$version" ]]; then
    if [[ -L "$CURRENT_LINK" ]]; then
      version=$(basename "$(readlink "$CURRENT_LINK")")
    elif [[ -d "$CURRENT_LINK" ]]; then
      # current might be a directory in some setups
      version=$(basename "$CURRENT_LINK")
    fi
  fi

  if [[ -z "$version" ]]; then
    log "Error: No version found. Please reinstall Junie."
    log "Run: curl -fsSL https://junie.jetbrains.com/install.sh | bash"
    exit 1
  fi

  # Verify version exists
  if [[ ! -d "$VERSIONS_DIR/$version" ]]; then
    log "Error: Version $version not found in $VERSIONS_DIR"
    log "Available versions:"
    ls -1 "$VERSIONS_DIR" 2>/dev/null || log "  (none)"
    exit 1
  fi

  echo "$version"
}

# === Filter Shim-Specific Arguments ===
# Global array to store filtered args (needed because bash can't return arrays)
FILTERED_ARGS=()

filter_args() {
  FILTERED_ARGS=()
  for arg in "$@"; do
    local skip="" c
    case "$arg" in
      --use-version=*|--channel=*) skip=1 ;;                # Skip shim-specific flags
      --*)
        # Skip bareword channel flags (--eap, --nightly, ...), data-driven.
        for c in $KNOWN_CHANNELS; do
          if [[ "$arg" == "--$c" ]]; then
            skip=1
            break
          fi
        done
        ;;
    esac
    [[ -n "$skip" ]] && continue
    FILTERED_ARGS+=("$arg")
  done
}

# === Handle Shim Commands ===
handle_shim_commands() {
  case "${1:-}" in
    --shim-version)
      echo "junie-shim 1.0.0"
      exit 0
      ;;
    --list-versions)
      echo "Installed versions:"
      if [[ -d "$VERSIONS_DIR" ]]; then
        local current_version=""
        if [[ -L "$CURRENT_LINK" ]]; then
          current_version=$(basename "$(readlink "$CURRENT_LINK")")
        fi
        for v in "$VERSIONS_DIR"/*/; do
          local vname
          vname=$(basename "$v")
          # Skip transient staging dirs (.<v>.tmp.<pid>, .<v>.old.<pid>) defensively.
          case "$vname" in .*) continue ;; esac
          if [[ "$vname" == "$current_version" ]]; then
            echo "  $vname (current)"
          else
            echo "  $vname"
          fi
        done
      else
        echo "  (none)"
      fi
      exit 0
      ;;
    --switch-version=*)
      local new_version="${1#--switch-version=}"
      if [[ ! -d "$VERSIONS_DIR/$new_version" ]]; then
        log "Error: Version $new_version not found"
        exit 1
      fi
      ln -sfn "$VERSIONS_DIR/$new_version" "$CURRENT_LINK"
      log "Switched to version $new_version"
      exit 0
      ;;
  esac
}

# === Channel Switching (one-shot) ===
#
# `junie --eap` (also --nightly / --release / --experimental, or --channel=<name>)
# fetches and launches the latest build of another channel *for this run only*.
# It shells out to that channel's published installer in one-shot mode
# (JUNIE_ONESHOT=1), which installs the build under $VERSIONS_DIR WITHOUT
# touching the shim, the `current` symlink, or PATH. We then exec that build
# directly. The persisted default channel is left completely intact, so a plain
# `junie` afterwards still launches (and self-updates) the default channel.

REQUESTED_CHANNEL=""
CHANNEL_VERSION=""

# Scan args for a channel flag, setting REQUESTED_CHANNEL (last one wins).
# Both forms are derived from KNOWN_CHANNELS: bareword `--<channel>` and the
# explicit `--channel=<name>`.
detect_channel_flag() {
  REQUESTED_CHANNEL=""
  local arg c
  for arg in "$@"; do
    case "$arg" in
      --channel=*)
        REQUESTED_CHANNEL="${arg#--channel=}"
        ;;
      --*)
        for c in $KNOWN_CHANNELS; do
          if [[ "$arg" == "--$c" ]]; then
            REQUESTED_CHANNEL="$c"
            break
          fi
        done
        ;;
    esac
  done
  # Always succeed: the loop's last command is a `[[ ]]` test that returns 1 for
  # any non-channel arg (e.g. `--help`). Since this function is called as a bare
  # command under `set -e`, that stray exit status would abort the whole shim.
  return 0
}

is_known_channel() {
  local c="$1" k
  for k in $KNOWN_CHANNELS; do
    [[ "$c" == "$k" ]] && return 0
  done
  return 1
}

installer_url_for_channel() {
  local c="$1"
  if [[ "$c" == "release" ]]; then
    echo "$INSTALL_BASE_URL/install.sh"
  else
    echo "$INSTALL_BASE_URL/install-$c.sh"
  fi
}

# Install (if needed) a build of channel $1 and set CHANNEL_VERSION to the
# installed version. If $2 (a build number) is given it is pinned via the
# installer's JUNIE_VERSION; otherwise the channel's latest build is used.
# Returns non-zero on any failure, in which case the caller aborts without
# touching the default channel.
install_channel_oneshot() {
  local channel="$1" build="${2:-}"
  if ! is_known_channel "$channel"; then
    log "Error: Unknown channel '$channel' (known: $KNOWN_CHANNELS)"
    return 1
  fi
  if ! has_command curl; then
    log "Error: 'curl' is required to switch channels"
    return 1
  fi

  local url version_file
  url="$(installer_url_for_channel "$channel")"
  version_file="$(mktemp)"

  if [[ -n "$build" ]]; then
    log "Fetching '$channel' build $build..."
  else
    log "Fetching latest '$channel' build..."
  fi
  # JUNIE_VERSION="" lets the installer pick the channel's latest build.
  if ! curl -fsSL "$url" \
        | JUNIE_ONESHOT=1 JUNIE_ONESHOT_VERSION_FILE="$version_file" JUNIE_VERSION="$build" bash; then
    log "Error: Failed to install '$channel' build"
    rm -f "$version_file"
    return 1
  fi

  CHANNEL_VERSION="$(cat "$version_file" 2>/dev/null || true)"
  rm -f "$version_file"

  if [[ -z "$CHANNEL_VERSION" ]]; then
    log "Error: Channel installer did not report a version"
    return 1
  fi
  if [[ ! -d "$VERSIONS_DIR/$CHANNEL_VERSION" ]]; then
    log "Error: Channel build $CHANNEL_VERSION not found after install"
    return 1
  fi
  return 0
}

# Launch another channel's build for this run only, then exit. An optional
# `--use-version=<build>` pins a specific build of the channel; otherwise the
# channel's latest build is used.
run_channel_oneshot() {
  local requested_build="" arg
  for arg in "$@"; do
    case "$arg" in
      --use-version=*) requested_build="${arg#--use-version=}" ;;
    esac
  done

  if ! install_channel_oneshot "$REQUESTED_CHANNEL" "$requested_build"; then
    exit 1
  fi

  local binary
  binary=$(get_binary_path "$CHANNEL_VERSION")
  if [[ -z "$binary" || ! -x "$binary" ]]; then
    log "Error: Binary not found or not executable for $REQUESTED_CHANNEL version $CHANNEL_VERSION"
    exit 1
  fi

  export EJ_RUNNER_PWD="${EJ_RUNNER_PWD:-$(pwd)}"
  export JUNIE_DATA="$JUNIE_DATA"

  # Disable the binary's auto-update for one-shot channel runs. This build is
  # launched only for the current invocation, so it must never check for,
  # download, or stage an update -- doing so would race with and clobber the
  # user's persisted default channel. The binary honors JUNIE_SKIP_UPDATE_CHECK
  # (see SystemOptionsGroup / AutoUpdateService).
  export JUNIE_SKIP_UPDATE_CHECK=1

  filter_args "$@"
  exec "$binary" ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}
}

# === Main ===
main() {
  # Handle shim-specific commands
  handle_shim_commands "$@"

  # Channel one-shot (`junie --eap` etc.): launch another channel's latest build
  # for this run only, leaving the default channel and its pending updates alone.
  detect_channel_flag "$@"
  if [[ -n "$REQUESTED_CHANNEL" ]]; then
    run_channel_oneshot "$@"
  fi

  # Defense-in-depth (JUNIE-2957): drop empty / unparseable update artifacts
  # before either we or the launched binary react to them.
  sanitize_pending_updates

  # Apply pending update if present. On failure we deliberately do NOT abort:
  # the previous version is still on disk (via the `current` symlink) and should run.
  if ! apply_pending_update; then
    log "Update not applied; continuing with current version"
  fi

  # Resolve which version to run
  local version
  version=$(resolve_version "$@")

  # Get binary path (handles macOS app bundle, Linux, direct binary)
  local binary
  binary=$(get_binary_path "$version")

  if [[ -z "$binary" || ! -x "$binary" ]]; then
    log "Error: Binary not found or not executable for version $version"
    log "Looked in: $VERSIONS_DIR/$version"
    exit 1
  fi

  # Set required environment variable for Junie
  export EJ_RUNNER_PWD="${EJ_RUNNER_PWD:-$(pwd)}"

  # Set JUNIE_DATA for the app to know where data is stored
  export JUNIE_DATA="$JUNIE_DATA"

  # Resolve and export this shim's own absolute path so the binary can refresh
  # it in place during auto-update (see ShimUpdater on the binary side).
  local self="$0"
  case "$self" in
    /*) ;;
    *) self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")" ;;
  esac
  export JUNIE_SHIM_PATH="$self"

  # Filter out shim-specific args and execute
  filter_args "$@"
  exec "$binary" ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}
}

main "$@"
SHIM_EOF
chmod +x "$JUNIE_BIN/junie"
fi

# Download and install binary
# Always re-download and overwrite the target version directory, regardless of
# whether it already exists. This avoids reusing a previously cached broken or
# partial install for the same version.
TARGET_DIR="$JUNIE_DATA/versions/$VERSION"

# In one-shot mode we still re-resolved "latest" above; only the download itself
# is skipped when that exact version is already installed and valid.
if [[ -n "$ONESHOT" ]] && oneshot_target_ready "$TARGET_DIR"; then
  log "Version $VERSION already installed; skipping download"
else
  TMP_ZIP=$(mktemp)

  log "Downloading $DOWNLOAD_URL"
  curl -fSL --progress-bar -o "$TMP_ZIP" "$DOWNLOAD_URL"

  # Verify checksum
  if [[ -n "$SHA256" ]]; then
    actual_sha256=$(sha256sum_file "$TMP_ZIP")
    if [[ -n "$actual_sha256" ]]; then
      if ! echo "$actual_sha256" | grep -qi "^${SHA256}$"; then
        log_error "Checksum verification failed!"
        log_error "Expected: $SHA256"
        log_error "Got: $actual_sha256"
        rm -f "$TMP_ZIP"
        exit 1
      fi
      log "Checksum verified"
    fi
  fi

  # Extract to a staging dir on the same filesystem as $TARGET_DIR, validate the
  # resolved binary, then atomically rename into place. This mirrors the shim's
  # robust extraction so an interrupted install never leaves a half-extracted tree.
  STAGING="$JUNIE_DATA/versions/.$VERSION.tmp.$$"
  trap 'rm -rf "$STAGING"' EXIT INT TERM
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  # On macOS use ditto so the signed .app bundle is reconstructed exactly;
  # on Linux use unzip. (See require_extractor above for the rationale.)
  if [[ "$OS_NAME" == "macos" ]]; then
    ditto -x -k "$TMP_ZIP" "$STAGING"
  else
    unzip -q "$TMP_ZIP" -d "$STAGING"
  fi
  rm -f "$TMP_ZIP"

  # Validate the extracted binary (inline equivalent of get_binary_path_in).
  if [[ -d "$STAGING/Applications/junie.app" ]]; then
    STAGED_BIN="$STAGING/Applications/junie.app/Contents/MacOS/junie"
  elif [[ -f "$STAGING/junie/bin/junie" ]]; then
    STAGED_BIN="$STAGING/junie/bin/junie"
  elif [[ -f "$STAGING/junie" ]]; then
    STAGED_BIN="$STAGING/junie"
  else
    STAGED_BIN=""
  fi
  if [[ -z "$STAGED_BIN" ]]; then
    log_error "No junie binary found in downloaded payload"
    exit 1
  fi
  chmod +x "$STAGED_BIN" 2>/dev/null || true
  if [[ ! -x "$STAGED_BIN" ]]; then
    log_error "Extracted binary is not executable: $STAGED_BIN"
    exit 1
  fi

  # macOS Gatekeeper handling. We sign AND notarize, so the bundle normally
  # passes Gatekeeper with quarantine intact and nothing needs to be stripped.
  # As a defensive fallback we verify acceptance during install and only strip
  # quarantine if Gatekeeper would actually reject this copy (e.g. a browser
  # re-download that got re-quarantined). Gating the strip behind a *failed*
  # assessment preserves Gatekeeper's protection in the normal case while still
  # producing a working install in the edge case.
  if [[ "$OS_NAME" == "macos" && -d "$STAGING/Applications/junie.app" ]]; then
    APP="$STAGING/Applications/junie.app"
    # Is the signature structurally valid? (Informational only; never abort.)
    if ! /usr/bin/codesign --verify --deep --strict "$APP" > /dev/null 2>&1; then
      log "Warning: code signature could not be verified for $APP"
    fi
    # Would Gatekeeper let it execute? This also checks notarization, so it
    # reflects the real first-launch user experience.
    if /usr/sbin/spctl --assess --type execute "$APP" > /dev/null 2>&1; then
      log "Gatekeeper assessment passed"
    else
      log "Gatekeeper assessment failed; stripping quarantine as a fallback"
      # Call Apple's xattr by absolute path so a foreign `xattr` earlier on PATH
      # cannot shadow it (that binary may lack -r; see JUNIE-2906), and fully
      # silence it (Apple's xattr prints its usage text to stdout, so 2>/dev/null
      # alone would still leak noise). `|| true` keeps `set -e` from aborting.
      [[ -x /usr/bin/xattr ]] && /usr/bin/xattr -dr com.apple.quarantine "$APP" > /dev/null 2>&1 || true
    fi
  fi

  # Remove any existing (possibly broken) version directory, then atomically
  # rename the validated staging tree into the final version directory.
  rm -rf "$TARGET_DIR"
  mv "$STAGING" "$TARGET_DIR"
  trap - EXIT INT TERM
fi

# Set current version (the persisted default). Skipped in one-shot mode so a
# `junie --<channel>` run does not change which channel plain `junie` launches.
if [[ -z "$ONESHOT" ]]; then
  ln -sfn "$TARGET_DIR" "$JUNIE_DATA/current"
fi

log "Installed successfully!"

# Returns 0 if PATH was already set or profile was updated.
# Returns 1 if profile could not be updated (caller shows manual instructions).
add_to_path() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) return 0 ;;
  esac

  local shell_name export_line profile_files profile_dir
  shell_name=$(basename "${SHELL:-}" 2>/dev/null || echo "")
  export_line='export PATH="$HOME/.local/bin:$PATH"'

  case "$shell_name" in
    zsh)
      # .zshrc is preferred; .zprofile is the fallback (also sourced by login shells)
      profile_files="$HOME/.zshrc $HOME/.zprofile"
      ;;
    bash)
      # macOS terminals open login shells (.bash_profile); Linux terminals open non-login shells (.bashrc)
      if [[ "$OS_NAME" == "macos" ]]; then
        profile_files="$HOME/.bash_profile $HOME/.profile"
      else
        profile_files="$HOME/.bashrc $HOME/.profile"
      fi
      ;;
    fish)
      profile_files="$HOME/.config/fish/config.fish"
      export_line='fish_add_path "$HOME/.local/bin"'
      ;;
    *)
      profile_files="$HOME/.profile"
      ;;
  esac

  local file
  for file in $profile_files; do
    if [[ -f "$file" ]] && grep -q '\.local/bin' "$file" 2>/dev/null; then
      return 0
    fi
  done

  for file in $profile_files; do
    profile_dir=$(dirname "$file")
    if [[ ! -d "$profile_dir" ]]; then
      mkdir -p "$profile_dir" 2>/dev/null || continue
    fi
    if { printf '\n%s\n' "$export_line" >> "$file"; } 2>/dev/null; then
      log "Added $JUNIE_BIN to PATH in $file"
      return 0
    fi
  done

  return 1
}

if [[ -n "$ONESHOT" ]]; then
  # Report the installed version back to the caller (the shim) and skip any PATH
  # changes -- one-shot installs must not modify the user's environment.
  if [[ -n "${JUNIE_ONESHOT_VERSION_FILE:-}" ]]; then
    printf '%s' "$VERSION" > "$JUNIE_ONESHOT_VERSION_FILE" 2>/dev/null || true
  fi
elif add_to_path; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*)
      echo ""
      echo "Run: junie --help"
      ;;
    *)
      echo ""
      echo "To get started, run:"
      echo '  export PATH="$HOME/.local/bin:$PATH"'
      echo ""
      echo "Then run: junie --help"
      ;;
  esac
else
  echo ""
  echo "Manually add to your PATH:"
  echo '  export PATH="$HOME/.local/bin:$PATH"'
  echo ""
  echo "Then run: junie --help"
fi
