#!/bin/bash
#
# Junie CLI Installer
# Usage: curl -fsSL https://junie.jetbrains.com/install.sh | bash
#
# To install a specific version:
#   curl -fsSL https://junie.jetbrains.com/install.sh | JUNIE_VERSION=656.1 bash
#

set -euo pipefail

CHANNEL="eap"
UPDATE_INFO_URL="https://raw.githubusercontent.com/jetbrains-junie/junie/main/update-info.jsonl"
GITHUB_RELEASES="https://github.com/jetbrains-junie/junie/releases"
JUNIE_BIN="$HOME/.local/bin"
JUNIE_DATA="$HOME/.local/share/junie"

log() { echo "[Junie] $*"; }
log_error() { echo "[Junie] ERROR: $*" >&2; }

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

# Fetch latest version info from update-info JSONL
fetch_latest_version() {
  log "Fetching latest version info..."
  local jsonl
  jsonl=$(curl -fsSL "$UPDATE_INFO_URL")

  # Find the latest entry for our platform (last matching line)
  local entry
  entry=$(echo "$jsonl" | grep "\"platform\":\"$PLATFORM\"" | tail -1)

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
  SHA256=""  # No checksum verification for specific version requests
  log "Using specified version: $VERSION"
else
  fetch_latest_version
fi

log "Installing Junie $VERSION for $PLATFORM..."

# Create directories
mkdir -p "$JUNIE_BIN"
mkdir -p "$JUNIE_DATA/versions"
mkdir -p "$JUNIE_DATA/updates"

# Install shim
cat > "$JUNIE_BIN/junie" << 'SHIM_EOF'
#!/bin/bash
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

# === Utility Functions ===

# Log message to stderr
log() {
  echo "[Junie] $*" >&2
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

# Get binary path for a given version
# Handles different package structures (macOS app bundle, Linux, direct binary)
get_binary_path() {
  local version="$1"
  local version_dir="$VERSIONS_DIR/$version"

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

# === Apply Pending Update ===
apply_pending_update() {
  if [[ ! -f "$PENDING_UPDATE" ]]; then
    return 0
  fi

  log "Applying pending update..."

  # Parse manifest
  local version zip_path sha256
  version=$(get_json_field "$PENDING_UPDATE" "version")
  zip_path=$(get_json_field "$PENDING_UPDATE" "zipPath")
  sha256=$(get_json_field "$PENDING_UPDATE" "sha256")

  if [[ -z "$version" || -z "$zip_path" ]]; then
    log "Invalid pending update manifest, skipping"
    rm -f "$PENDING_UPDATE"
    return 1
  fi

  if [[ ! -f "$zip_path" ]]; then
    log "Update file not found: $zip_path"
    rm -f "$PENDING_UPDATE"
    return 1
  fi

  # Verify checksum if available
  if [[ -n "$sha256" ]]; then
    local actual_sha256
    actual_sha256=$(sha256sum_file "$zip_path")

    # Case-insensitive comparison (compatible with bash 3.x on macOS)
    if [[ -n "$actual_sha256" ]] && ! echo "$actual_sha256" | grep -qi "^${sha256}$"; then
      log "Checksum mismatch, skipping update"
      log "Expected: $sha256"
      log "Got: $actual_sha256"
      rm -f "$PENDING_UPDATE" "$zip_path"
      return 1
    fi
  fi

  # Extract to versions directory
  local target_dir="$VERSIONS_DIR/$version"
  mkdir -p "$target_dir"

  log "Extracting to $target_dir..."

  if has_command unzip; then
    unzip -q -o "$zip_path" -d "$target_dir"
  elif has_command tar; then
    # Fallback for .tar.gz files
    tar -xzf "$zip_path" -C "$target_dir"
  else
    log "Error: No extraction tool available (unzip or tar)"
    return 1
  fi

  # Make binary executable
  chmod +x "$target_dir/junie" 2>/dev/null || true

  # Remove quarantine on macOS
  xattr -dr com.apple.quarantine "$target_dir" 2>/dev/null || true

  # Update current symlink atomically
  ln -sfn "$target_dir" "$CURRENT_LINK"

  # Cleanup
  rm -f "$zip_path" "$PENDING_UPDATE"

  log "Updated to version $version"
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
    case "$arg" in
      --use-version=*) ;; # Skip shim-specific flag
      *) FILTERED_ARGS+=("$arg") ;;
    esac
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
          local vname=$(basename "$v")
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

# === Main ===
main() {
  # Handle shim-specific commands
  handle_shim_commands "$@"

  # Apply pending update if exists
  apply_pending_update || true

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

  # Filter out shim-specific args and execute
  filter_args "$@"
  exec "$binary" ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}
}

main "$@"
SHIM_EOF
chmod +x "$JUNIE_BIN/junie"

# Download and install binary
TARGET_DIR="$JUNIE_DATA/versions/$VERSION"
if [[ ! -d "$TARGET_DIR" ]]; then
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

  mkdir -p "$TARGET_DIR"
  unzip -q -o "$TMP_ZIP" -d "$TARGET_DIR"
  rm -f "$TMP_ZIP"

  [[ "$OS_NAME" == "macos" ]] && xattr -dr com.apple.quarantine "$TARGET_DIR" 2>/dev/null || true
fi

# Set current version
ln -sfn "$TARGET_DIR" "$JUNIE_DATA/current"

log "Installed successfully!"
echo ""
echo "Add to your PATH if not already:"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "Then run: junie --help"
