#!/bin/sh
set -e

# ============================================================
# Prerequisites
# ============================================================

# Ensure the required commands are available before we start downloading
# anything. We fail early with an actionable message so users on minimal
# systems aren't stuck staring at a cryptic `command not found` halfway
# through the install.
# Detect the OS early so we can pick the right toolchain for every step.
if uname -s | grep -qi "darwin"; then
  OS_TYPE="macos"
else
  OS_TYPE="linux"
fi

require_commands() {
  missing=""
  common="curl tar unzip head tput"
  if [ "$OS_TYPE" = "macos" ]; then
    required="$common shasum pgrep xxd sysctl sw_vers"
  else
    required="$common sha256sum"
  fi
  for cmd in $required; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done
  if [ -n "$missing" ]; then
    echo "ERROR: Required commands not found:$missing"
    echo ""
    if [ "$OS_TYPE" = "macos" ]; then
      echo "These are part of macOS base system or Xcode Command Line Tools."
      echo "Install Xcode CLI tools with:"
      echo "  xcode-select --install"
    else
      echo "Install them with your distribution's package manager, e.g.:"
      echo "  apt-get update && apt-get install -y coreutils"
      echo "or"
      echo "  dnf install -y coreutils"
    fi
    echo "then re-run this installer."
    exit 1
  fi
}
require_commands

# ============================================================
# Command-line arguments
# ============================================================

PROTOCOL_VERSION=1

MACHINE_OUTPUT=false
CHECK_ONLY=false
LIST_MODELS=false
MODEL="Qwen3.6-27B-MLX-4bit"
CHANNEL="main"

usage() {
  echo "Usage: install.sh [options]"
  echo ""
  echo "Options:"
  echo "  --model <name>     Model to install: Qwen3.6-27B-MLX-4bit (default) or Qwen3.8-27B-MLX-4bit"
  echo "  --channel <name>   Update channel: main (default) or eap"
  echo "  --check-only       Report system information, then exit"
  echo "  --models           List all available models for this architecture, then exit"
  echo "  --json             Emit machine-readable events on stdout, human output on stderr"
  echo "  --help, -h         Show this help"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) MACHINE_OUTPUT=true ;;
    --check-only) CHECK_ONLY=true ;;
    --models) LIST_MODELS=true ;;
    --model)
      shift
      if [ $# -eq 0 ]; then
        echo "ERROR: --model requires a value"; usage; exit 1
      fi
      MODEL="$1"
      ;;
    --model=*) MODEL="${1#--model=}" ;;
    --channel)
      shift
      if [ $# -eq 0 ]; then
        echo "ERROR: --channel requires a value"; usage; exit 1
      fi
      CHANNEL="$1"
      ;;
    --channel=*) CHANNEL="${1#--channel=}" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

if [ "$MACHINE_OUTPUT" = true ]; then
  # stdout carries only machine events; human-oriented output goes to stderr
  exec 3>&1 1>&2
fi

# ============================================================
# Configuration
# ============================================================

BASE_DIR="$HOME/.local/share/junie-local"
# Junie configuration directory; the caller (Junie CLI) overrides it when it
# runs with a non-default home so the model config lands where that instance
# looks for it.
JUNIE_HOME="${JUNIE_HOME:-$HOME/.junie}"
MODELS_DIR="$BASE_DIR/models"
DOWNLOAD_DIR="$BASE_DIR/incomplete_downloads"

# ============================================================
# Platform detection
# ============================================================

# Detect the target platform (e.g. macos-aarch64 or linux-amd64).
# OS_TYPE was already set at the top of the script; UNAME_OS is kept for
# display and for the legacy checks that still use it.
UNAME_OS=$(uname -s)
UNAME_ARCH=$(uname -m)
case "$UNAME_OS" in
  Darwin) OS_NAME="macos" ;;
  *)      OS_NAME="linux" ;;
esac
case "$UNAME_ARCH" in
  arm64|aarch64) ARCH_NAME="aarch64" ;;
  x86_64|amd64)  ARCH_NAME="amd64" ;;
  *)             ARCH_NAME="$UNAME_ARCH" ;;
esac
PLATFORM="${OS_NAME}-${ARCH_NAME}"

# ============================================================
# Model configuration: fetched from update-info-models-<channel>.jsonl
# ============================================================

# Base URL for the update-info files (engine and model metadata). Override via
# environment variable to point at a custom location during testing/deployment.
UPDATE_FILES_BASE_URL="${JUNIE_LOCAL_UPDATE_FILES_BASE_URL:-https://raw.githubusercontent.com/jetbrains-junie/junie/main/local}"

# Model update metadata is published per channel as JSONL (one object per line)
# with platform, model id (filename in models/ folder), displayName, etc.
MODELS_UPDATE_URL="${UPDATE_FILES_BASE_URL}/update-info-models-${CHANNEL}.jsonl"

# Global: the fetched model JSON (qwen3.6.json etc), kept for archive lookups.
models_json=""

# Extract a string field from JSON on stdin. Handles both compact
# ("key":"value") and pretty-printed ("key": "value") formats. Prints the
# first occurrence; empty if the field is not found.
get_json_field() {
  local field="$1"
  grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\"/\\1/"
}

# List all models available for the current platform from the channel's
# update-info-models JSONL. In human mode prints one "id (displayName)" per
# line; with --json emits a single "models" event with the full list.
list_available_models() {
  models_jsonl=$(curl -fsSL "$MODELS_UPDATE_URL" 2>/dev/null) || {
    echo "ERROR: Could not fetch models list from $MODELS_UPDATE_URL"
    emit_error "Could not fetch models list from $MODELS_UPDATE_URL"
    exit 1
  }
  if [ "$MACHINE_OUTPUT" = true ]; then
    # Build a JSON array of {"id":"...","displayName":"..."} objects.
    models_array="["
    first=true
    while IFS= read -r entry; do
      case "$entry" in
        *"\"platform\":\"${PLATFORM}\""*) ;;
        *) continue ;;
      esac
      id=$(printf '%s' "$entry" | get_json_field id)
      name=$(printf '%s' "$entry" | get_json_field displayName)
      if [ "$first" = true ]; then
        first=false
      else
        models_array="$models_array,"
      fi
      models_array="$models_array{\"id\":\"$(json_escape "$id")\",\"displayName\":\"$(json_escape "$name")\"}"
    done <<EOF
$(printf '%s\n' "$models_jsonl")
EOF
    models_array="$models_array]"
    emit_event "\"event\":\"models\",\"platform\":\"$(json_escape "$PLATFORM")\",\"channel\":\"$(json_escape "$CHANNEL")\",\"models\":$models_array"
  else
    while IFS= read -r entry; do
      case "$entry" in
        *"\"platform\":\"${PLATFORM}\""*) ;;
        *) continue ;;
      esac
      id=$(printf '%s' "$entry" | get_json_field id)
      name=$(printf '%s' "$entry" | get_json_field displayName)
      echo "$name ($id)"
    done <<EOF
$(printf '%s\n' "$models_jsonl")
EOF
  fi
}

# Extract a field from an archive entry by index. Each archive object has
# exactly one of each field, so we extract all values of that field in order
# and pick the Nth one.
get_archive_field() {
  local archive_index="$1"
  local field="$2"
  printf '%s' "$models_json" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*[^,}]*" | sed "s/\"${field}\"[[:space:]]*:[[:space:]]*//; s/[\" ]//g" | sed -n "$((archive_index + 1))p"
}

fetch_models_config() {
  # Fetch the JSONL metadata.
  models_jsonl=$(curl -fsSL "$MODELS_UPDATE_URL" 2>/dev/null) || {
    echo "ERROR: Could not fetch models config from $MODELS_UPDATE_URL"
    exit 1
  }

  # Find the entry matching our platform and the requested model.
  model_entry=$(printf '%s\n' "$models_jsonl" | grep "\"platform\":\"${PLATFORM}\"" | grep "\"id\":\"${MODEL}\"" | tail -1)
  if [ -z "$model_entry" ]; then
    supported=$(printf '%s\n' "$models_jsonl" | grep "\"platform\":\"${PLATFORM}\"" | while IFS= read -r e; do printf '%s' "$e" | get_json_field id; done | tr '\n' ',' | sed 's/,$//')
    echo "ERROR: Unknown model: $MODEL for platform $PLATFORM (supported: $supported)"
    exit 1
  fi

  # Extract the model id (filename in the models/ folder).
  MODEL_FILE_ID=$(printf '%s' "$model_entry" | get_json_field id)

  # Fetch the model JSON file.
  MODEL_CONFIG_URL="${UPDATE_FILES_BASE_URL}/models/${MODEL_FILE_ID}.json"
  models_json=$(curl -fsSL "$MODEL_CONFIG_URL" 2>/dev/null) || {
    echo "ERROR: Could not fetch model config from $MODEL_CONFIG_URL"
    exit 1
  }

  # Save the model JSON locally so the engine can use it. Skip when only
  # listing models — no install is happening.
  if [ "$LIST_MODELS" != true ]; then
    MODEL_CONFIG_FILE="$BASE_DIR/models/${MODEL_FILE_ID}.json"
    echo "  Saving model config to $MODEL_CONFIG_FILE..."
    echo "$models_json" > "$MODEL_CONFIG_FILE"
  fi

  # Extract the Junie model id (used for config file naming and defaults).
  JUNIE_MODEL_ID=$(printf '%s' "$models_json" | get_json_field id)

  # Count the archives to install.
  ARCHIVE_COUNT=$(printf '%s' "$models_json" | grep -o '"modelId"' | wc -l | tr -d ' ')
}

fetch_models_config

# ============================================================
# Engine configuration: fetched from update-info-engine-<channel>.jsonl
# ============================================================

# Engine update metadata is published per channel as JSONL (one object per
# line). Fetch the file for the requested channel and pick the entry that
# matches our platform.
ENGINE_UPDATE_URL="${UPDATE_FILES_BASE_URL}/update-info-engine-${CHANNEL}.jsonl"

fetch_engine_config() {
  engine_jsonl=$(curl -fsSL "$ENGINE_UPDATE_URL" 2>/dev/null) || {
    echo "ERROR: Could not fetch engine config from $ENGINE_UPDATE_URL"
    exit 1
  }
  engine_entry=$(printf '%s\n' "$engine_jsonl" | grep "\"platform\":\"${PLATFORM}\"" | tail -1)
  if [ -z "$engine_entry" ]; then
    echo "ERROR: No engine entry found for platform $PLATFORM in channel $CHANNEL"
    exit 1
  fi

  ENGINE_VERSION=$(printf '%s' "$engine_entry" | get_json_field version)
  ENGINE_URL=$(printf '%s' "$engine_entry" | get_json_field downloadUrl)
  ENGINE_SHA256=$(printf '%s' "$engine_entry" | get_json_field sha256)
}

fetch_engine_config

# Archive name is the last path segment of the download URL.
ENGINE_ARCHIVE=$(printf '%s' "$ENGINE_URL" | sed 's|.*/||')

# Inference engine release. Versions are unpacked side by side under versions/
# and the current symlink points at the one to run.
ENGINE_LABEL="inference engine"
VERSIONS_DIR="$BASE_DIR/versions"
ENGINE_DIR="$VERSIONS_DIR/$ENGINE_VERSION"
CURRENT_LINK="$BASE_DIR/current"
ENGINE_CTL="$CURRENT_LINK/serverctl.sh"

# The port the engine serves on (the Junie model config below points at it) and
# the RAM allowance it may spend on weights and KV cache. The engine reads the
# rest of its settings from $BASE_DIR/server-config.json, which it writes itself
# on first start. Nothing here consumes the RAM allowance yet — it is only
# displayed and reported in the "config" event.
ENGINE_PORT=19239
ENGINE_RAM_GB=35


# ============================================================
# Functions
# ============================================================

# ============================================================
# Machine-readable events (--json): one JSON object per line on stdout
#   {"event":"hello","protocol":1}
#   {"event":"check","name":"os|cpu|ram","status":"ok|warn|fail","value":"...","requirement":"..."}
#   {"event":"config","port":N,"ram_gb":N,"engine_version":"...","model":"...","checks_passed":true|false}
#   {"event":"step_start","id":"engine|models|configure|start","title":"..."}
#   {"event":"progress","action":"downloading|extracting","file":"...","bytes":N,"total":N,"label":"..."}
#   {"event":"activity","action":"verifying|extracting","file":"...","label":"..."}
#   {"event":"step_done","id":"engine|models|configure|start"}
#   {"event":"warning","message":"..."}
#   {"event":"error","message":"..."}
#   {"event":"done","model_id":"...","port":N,"model_path":"...","label":"..."}
# Consumers must check the protocol version in "hello" and ignore
# unknown event types and fields.
# ============================================================

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit_event() {
  if [ "$MACHINE_OUTPUT" = true ]; then
    printf '{%s}\n' "$1" >&3
  fi
}

emit_check() {
  emit_event "\"event\":\"check\",\"name\":\"$1\",\"status\":\"$2\",\"value\":\"$(json_escape "$3")\",\"requirement\":\"$(json_escape "$4")\""
}

emit_step_start() {
  emit_event "\"event\":\"step_start\",\"id\":\"$1\",\"title\":\"$(json_escape "$2")\""
}

emit_step_done() {
  emit_event "\"event\":\"step_done\",\"id\":\"$1\""
}

emit_progress() {
  emit_event "\"event\":\"progress\",\"action\":\"${5:-downloading}\",\"file\":\"$(json_escape "$1")\",\"bytes\":${2:-0},\"total\":${3:-0},\"label\":\"$(json_escape "$4")\""
}

emit_activity() {
  emit_event "\"event\":\"activity\",\"action\":\"$1\",\"file\":\"$(json_escape "$2")\",\"label\":\"$(json_escape "$3")\""
}

emit_warning() {
  emit_event "\"event\":\"warning\",\"message\":\"$(json_escape "$1")\""
}

emit_error() {
  emit_event "\"event\":\"error\",\"message\":\"$(json_escape "$1")\""
}

# Map an ok/warn flag pair to a check status
check_status() {
  if [ "$1" != true ]; then
    echo "fail"
  elif [ "$2" = true ]; then
    echo "warn"
  else
    echo "ok"
  fi
}

emit_event "\"event\":\"hello\",\"protocol\":$PROTOCOL_VERSION"

# ============================================================
# OS-specific utility functions
# ============================================================

# Calculate SHA-256 checksum of a file. Uses shasum on macOS and sha256sum on
# Linux, since the two tools have different flags and output formats.
get_checksum() {
  local file="$1"
  if [ "$OS_TYPE" = "macos" ]; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    sha256sum "$file" | awk '{print $1}'
  fi
}

# Generate a random hex token. xxd is not available on all Linux systems,
# so fall back to od, which is part of POSIX coreutils.
generate_token() {
  if command -v xxd > /dev/null 2>&1; then
    head -c 12 /dev/urandom | xxd -p
  else
    head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Check whether the engine daemon is currently running. macOS has pgrep with
# a clean -f flag; on Linux we use ps + grep and filter out the grep itself.
# We match on "serverctl" and the base dir rather than a hardcoded binary name,
# so the check works regardless of the platform-specific engine binary.
is_engine_running() {
  if [ "$OS_TYPE" = "macos" ]; then
    pgrep -f "$ENGINE_CTL" > /dev/null 2>&1 || pgrep -f "junie.*vlm" > /dev/null 2>&1
  else
    ps aux | grep -E "serverctl|junie.*vlm" | grep -v grep | grep -q .
  fi
}

# Helper: wait for user to press any key, then exit. Only a standalone run on a
# terminal has someone to wait for: piped into a shell (`curl ... | sh`) stdin is
# this script's own source, so the read returns at once and the prompt is noise.
wait_and_exit() {
  show_cursor
  if [ "$MACHINE_OUTPUT" != true ] && [ -t 0 ]; then
    echo ""
    echo "Press any key to exit..."
    # If read fails, still exit with the intended code (not read's status)
    read -r -n 1 || true
  fi
  exit "$1"
}


# --- junie-ui:begin ---
# Presentation layer: the Junie logo, section headings, checked values, and
# downloads/extractions with a progress bar. Everything degrades to plain lines
# when stdout is not a terminal, CI=true, JUNIE_NO_ANIM=1, or --json is in
# effect, so piped, logged and machine-consumed runs stay readable.
#
# The block stands on its own so preview.sh can source it straight out of this
# file. The event emitters live above it; when the block is sourced by itself
# they are absent, so a stub keeps the download and extraction loops working.
MACHINE_OUTPUT="${MACHINE_OUTPUT:-false}"
if ! command -v emit_progress > /dev/null 2>&1; then
  emit_progress() { :; }
  emit_error() { :; }
fi

ESC=$(printf '\033')
CSI="${ESC}["
RESET="${CSI}0m"
BOLD="${CSI}1m"
HIDE_CURSOR="${CSI}?25l"
SHOW_CURSOR="${CSI}?25h"
CLEAR_RIGHT="${CSI}0K"

# Brand colors, same values the Junie CLI uses for its logo and progress.
JUNIE_GREEN="${CSI}38;2;72;224;84m"
JUNIE_GREEN_DIM="${CSI}38;2;36;110;42m"
GRAY="${CSI}38;2;150;150;150m"
GRAY_DIM="${CSI}38;2;92;92;92m"
RED="${CSI}38;2;255;107;107m"
YELLOW="${CSI}38;2;255;199;89m"
GREEN="$JUNIE_GREEN"
NC="$RESET"

# Cursor moves and a redrawn progress line need a real terminal.
INTERACTIVE=true
if [ ! -t 1 ] || [ "${CI:-}" = "true" ] || [ "${JUNIE_NO_ANIM:-}" = "1" ] \
   || [ "$MACHINE_OUTPUT" = true ]; then
  INTERACTIVE=false
fi

# Escape sequences only mean anything on a terminal. A piped or captured run
# gets plain text, and with --json the human stream is a log for whoever
# launched us, so it stays clean too and progress travels as events instead.
if [ ! -t 1 ] || [ "$MACHINE_OUTPUT" = true ]; then
  RESET=''
  BOLD=''
  HIDE_CURSOR=''
  SHOW_CURSOR=''
  CLEAR_RIGHT=''
  JUNIE_GREEN=''
  JUNIE_GREEN_DIM=''
  GRAY=''
  GRAY_DIM=''
  RED=''
  YELLOW=''
  GREEN=''
  NC=''
fi

TERM_COLS=$(tput cols 2>/dev/null || echo 80)

show_cursor() {
  if [ "$INTERACTIVE" = true ]; then
    printf '%s' "$SHOW_CURSOR"
  fi
  return 0
}

# The Junie J and wordmark, character-for-character the same art as the CLI.
LOGO_ART='       ///////       |       ///////       |       ///////       |///////      /////// |///////      /////// |///////     //////// |       ///////////   |       /////////     |       //////        '
WORDMARK_ART='      ///                           ///              |      ///                           ///              |      ///  ///     ///  /////////         ///////    |      ///  ///     ///  //////////  ///  //////////  |      ///  ///     ///  ///     /// /// ///     //// |      ///  ///     ///  ///     /// /// //////////// |      ///  ///    ////  ///     /// /// ///          | ////////  //////////   ///     /// ///  /////////// | //////     ////////    ///     /// ///   ////////   '

# Prints the logo. The wordmark is dropped on narrow terminals, matching the
# CLI's 80-column cutoff. With --json the caller draws its own interface, so the
# art would only clutter the log it collects.
junie_logo() {
  if [ "$MACHINE_OUTPUT" = true ]; then
    return 0
  fi
  logo_wordmark="$WORDMARK_ART"
  if [ "$TERM_COLS" -lt 80 ]; then
    logo_wordmark=""
  fi
  printf '\n'
  awk -v logo="$LOGO_ART" -v mark="$logo_wordmark" \
      -v green="$JUNIE_GREEN" -v reset="$RESET" -v bold="$BOLD" '
    BEGIN {
      rows = split(logo, logoline, "|")
      if (mark != "") split(mark, markline, "|")
      for (y = 1; y <= rows; y++) {
        out = "  " green bold logoline[y] reset
        if (mark != "") out = out "  " bold markline[y] reset
        print out
      }
    }'
  printf '\n'
  return 0
}

# A section heading with an underline as wide as its title.
section() {
  printf '\n  %s%s%s%s\n' "$JUNIE_GREEN" "$BOLD" "$1" "$RESET"
  awk -v n="${#1}" -v c="$GRAY_DIM" -v r="$RESET" \
    'BEGIN { s = ""; for (i = 0; i < n; i++) s = s "─"; print "  " c s r }'
  printf '\n'
  return 0
}

# Helper: print a value in green if ok, yellow if warning, red if not ok
print_value() {
  label="$1"
  value="$2"
  ok="$3"
  warn="$4"
  requirement="$5"
  if [ "$ok" = true ] && [ "$warn" = false ]; then
    printf "  %s%-20s%s ${GREEN}%s${NC}\n" "$GRAY" "$label" "$RESET" "$value"
  elif [ "$warn" = true ]; then
    printf "  %s%-20s%s ${YELLOW}%s${NC}  %s(%s)%s\n" "$GRAY" "$label" "$RESET" "$value" "$GRAY_DIM" "$requirement" "$RESET"
  else
    printf "  %s%-20s%s ${RED}%s${NC}  %s(requirement: %s)%s\n" "$GRAY" "$label" "$RESET" "$value" "$GRAY_DIM" "$requirement" "$RESET"
  fi
}

# Bytes as a human-readable size, e.g. 6.1 GB.
human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824
    else if (b >= 1048576) printf "%.1f MB", b / 1048576
    else if (b >= 1024) printf "%.0f KB", b / 1024
    else printf "%d B", b
  }'
}

BAR_WIDTH=32
PROGRESS_DREW=false
PROGRESS_LOGGED=-1

# Draws the progress bar: one line, redrawn in place with a carriage return.
# It must never wrap -- a wrapped line puts the cursor on a row the carriage
# return cannot reach, and every frame would then leave its own leftovers on
# screen -- so the label, the ETA and the speed are dropped, in that order, until
# the line fits the terminal, and the bar itself shrinks if that is still not
# enough. Off a terminal the numbers are logged once per 10% instead, and with
# --json nothing is drawn at all because the progress events carry it.
# Usage: progress_render <have-bytes> <total-bytes|0> <bytes-per-second> <label>
progress_render() {
  if [ "$MACHINE_OUTPUT" = true ]; then
    return 0
  fi
  if [ "$INTERACTIVE" != true ]; then
    if [ "$2" -gt 0 ]; then
      progress_step=$(( $1 * 10 / $2 ))
      if [ "$progress_step" -gt "$PROGRESS_LOGGED" ]; then
        PROGRESS_LOGGED=$progress_step
        printf '  %d%% (%s of %s)\n' "$(( progress_step * 10 ))" "$(human_bytes "$1")" "$(human_bytes "$2")"
      fi
    fi
    return 0
  fi
  PROGRESS_DREW=true

  awk -v have="$1" -v total="$2" -v bps="$3" -v label="$4" \
      -v width="$BAR_WIDTH" -v cols="$TERM_COLS" -v clr="$CLEAR_RIGHT" \
      -v green="$JUNIE_GREEN" -v dim="$JUNIE_GREEN_DIM" -v gray="$GRAY" \
      -v graydim="$GRAY_DIM" -v reset="$RESET" '
    function human(b) {
      if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824)
      if (b >= 1048576) return sprintf("%.1f MB", b / 1048576)
      if (b >= 1024) return sprintf("%.0f KB", b / 1024)
      return sprintf("%d B", b)
    }
    BEGIN {
      ratio = total > 0 ? have / total : 0
      if (ratio > 1) ratio = 1

      # Every field is padded to a width that does not depend on the current
      # value, so the numbers do not shift as they grow and the fitting decision
      # below lands the same way on every frame. Deciding from the raw values
      # would make the ETA blink in and out whenever a size gained a digit.
      size_w = length(human(total))
      if (size_w < 9) size_w = 9
      pct_s = total > 0 ? sprintf("%3d%%", int(ratio * 100)) : ""
      size_s = total > 0 ? sprintf("%*s of %s", size_w, human(have), human(total)) \
                         : sprintf("%*s", size_w, human(have))
      speed_s = bps > 0 ? sprintf("%9s/s", human(bps)) : sprintf("%11s", "")
      if (bps > 0 && total > have) {
        eta_secs = int((total - have) / bps)
        eta_s = sprintf("eta %3d:%02d", eta_secs / 60, eta_secs % 60)
      } else {
        eta_s = sprintf("%9s", "")
      }

      # Two leading spaces, the bar, two spaces, then as many fields as fit on
      # the line. The label is dropped first, then the ETA, then the speed, and
      # the bar shrinks if even that is not enough.
      stats = pct_s (pct_s == "" ? "" : "  ") size_s
      show_speed = 1
      show_eta = total > 0
      while (1) {
        tail = show_speed ? "  " speed_s : ""
        if (show_eta) tail = tail "  " eta_s
        if (2 + width + 2 + length(stats tail) + (label != "" ? 2 + length(label) : 0) <= cols - 1) break
        if (label != "") { label = ""; continue }
        if (show_eta) { show_eta = 0; continue }
        if (show_speed) { show_speed = 0; continue }
        break
      }
      stats = stats tail
      room = cols - 1 - (2 + 2 + length(stats))
      if (room < width) width = room > 8 ? room : 8

      filled = int(ratio * width + 0.5)
      bar = ""; for (i = 0; i < filled; i++) bar = bar "█"
      rest = ""; for (i = filled; i < width; i++) rest = rest "░"

      printf "\r  %s%s%s%s  %s%s%s%s%s", green, bar, dim, rest, gray, stats, \
             (label != "" ? graydim "  " label : ""), reset, clr
      fflush()
    }'
  return 0
}

# Closes the progress line and gives the cursor back.
progress_end() {
  if [ "$PROGRESS_DREW" = true ] && [ "$INTERACTIVE" = true ]; then
    printf '\n'
  fi
  PROGRESS_DREW=false
  PROGRESS_LOGGED=-1
  show_cursor
  return 0
}

# Size of a local file in bytes, 0 when it does not exist yet.
file_size() {
  if [ ! -f "$1" ]; then
    echo 0
    return 0
  fi
  wc -c < "$1" | tr -d ' '
}

# Asks the server for the size of a file and whether it accepts ranged GETs,
# which is what makes an interrupted download resumable. Sets REMOTE_SIZE (empty
# when unknown) and REMOTE_RANGES.
probe_remote() {
  REMOTE_SIZE=""
  REMOTE_RANGES=false

  probe_headers=$(curl -sIL --max-time 30 "$1" 2>/dev/null | tr -d '\r') || probe_headers=""
  # Redirects mean several header blocks. Only the last one describes the file,
  # and only if it succeeded: an error page has a Content-Length too.
  # The size is only accepted as a plain number: everything downstream does
  # arithmetic on it, and `set -e` would kill the installer over a header a proxy
  # decided to reword.
  REMOTE_SIZE=$(printf '%s\n' "$probe_headers" | awk '
    /^[Hh][Tt][Tt][Pp]\// { status = $2; next }
    tolower($1) == "content-length:" { len = $2 }
    END { if (status ~ /^2/ && len ~ /^[0-9]+$/) print len }')
  if printf '%s\n' "$probe_headers" | awk '
    /^[Hh][Tt][Tt][Pp]\// { status = $2; ranges = 0; next }
    tolower($1) == "accept-ranges:" { ranges = (tolower($2) == "bytes") }
    END { exit(status ~ /^2/ && ranges ? 0 : 1) }'; then
    REMOTE_RANGES=true
  fi

  # Some CDNs answer HEAD without a size; a one-byte ranged GET settles both
  # questions at once, because only a 206 carries Content-Range.
  if [ -z "$REMOTE_SIZE" ]; then
    probe_headers=$(curl -sL --max-time 30 -r 0-0 -D - -o /dev/null "$1" 2>/dev/null | tr -d '\r') || probe_headers=""
    REMOTE_SIZE=$(printf '%s\n' "$probe_headers" | awk '
      /^[Hh][Tt][Tt][Pp]\// { status = $2; next }
      tolower($1) == "content-range:" { split($2, a, "/"); if (a[2] != "") total = a[2] }
      END { if (status == "206" && total ~ /^[0-9]+$/) print total }')
    if [ -n "$REMOTE_SIZE" ]; then
      REMOTE_RANGES=true
    fi
  fi
  return 0
}

CURL_PID=""
CURL_ERR_FILE=""

# Downloads <url> into <file> with a progress bar, continuing an interrupted
# transfer instead of starting over: curl runs with -C -, the partial file is
# kept on Ctrl-C and on network errors, and the next attempt picks up at its
# current size. A file that already has the remote size is left alone, so a
# re-run after a completed download costs one HEAD request. Progress is reported
# both ways -- as a redrawn bar for a person and as protocol events -- so the
# same function serves a standalone run and a --json consumer.
# Usage: download_with_progress <url> <file> [label]
download_with_progress() {
  dl_url="$1"
  dl_out="$2"
  dl_label="${3:-}"
  dl_name=$(basename "$dl_out")

  probe_remote "$dl_url"
  dl_total="${REMOTE_SIZE:-0}"
  dl_have=$(file_size "$dl_out")

  if [ "$dl_total" -gt 0 ] && [ "$dl_have" -eq "$dl_total" ]; then
    printf '  %sAlready downloaded%s (%s)\n' "$JUNIE_GREEN" "$RESET" "$(human_bytes "$dl_total")"
    emit_progress "$dl_name" "$dl_have" "$dl_total" "$dl_label"
    return 0
  fi
  if [ "$dl_total" -gt 0 ] && [ "$dl_have" -gt "$dl_total" ]; then
    printf '  %sLocal file is bigger than the remote one — starting over.%s\n' "$YELLOW" "$RESET"
    rm -f "$dl_out"
    dl_have=0
  fi
  if [ "$dl_have" -gt 0 ] && [ "$REMOTE_RANGES" != true ]; then
    printf '  %sServer will not resume this file — downloading it again.%s\n' "$YELLOW" "$RESET"
    rm -f "$dl_out"
    dl_have=0
  fi
  if [ "$dl_have" -gt 0 ]; then
    printf '  %sResuming at %s%s\n' "$GRAY" "$(human_bytes "$dl_have")" "$RESET"
  fi

  # Re-measure the terminal: it may have been resized since the last step, and
  # the bar sizes itself to fit.
  TERM_COLS=$(tput cols 2>/dev/null || echo 80)
  if [ "$INTERACTIVE" = true ]; then
    printf '%s' "$HIDE_CURSOR"
  fi

  # curl keeps stderr for the failure message: it would otherwise land in the
  # middle of the bar. The path is global so the interrupt trap can remove it.
  CURL_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/junie-curl.XXXXXX")
  dl_err="$CURL_ERR_FILE"
  curl --fail --silent --show-error --location -C - -o "$dl_out" "$dl_url" 2>"$dl_err" &
  CURL_PID=$!

  dl_prev_bytes=$dl_have
  dl_prev_time=$(date +%s)
  dl_bps=0
  while kill -0 "$CURL_PID" 2>/dev/null; do
    dl_now_bytes=$(file_size "$dl_out")
    dl_now_time=$(date +%s)
    if [ "$dl_now_time" -gt "$dl_prev_time" ]; then
      dl_bps=$(( (dl_now_bytes - dl_prev_bytes) / (dl_now_time - dl_prev_time) ))
      dl_prev_bytes=$dl_now_bytes
      dl_prev_time=$dl_now_time
      # One event per second; the bar below is redrawn far more often than that.
      emit_progress "$dl_name" "$dl_now_bytes" "$dl_total" "$dl_label"
    fi
    progress_render "$dl_now_bytes" "$dl_total" "$dl_bps" "$dl_label"
    sleep 0.2
  done

  dl_rc=0
  wait "$CURL_PID" || dl_rc=$?
  CURL_PID=""
  # One last frame so the bar lands on the final size — but only on success: a
  # failed download should not leave a bar behind at all.
  if [ "$dl_rc" -eq 0 ]; then
    dl_final=$(file_size "$dl_out")
    progress_render "$dl_final" "$dl_total" "$dl_bps" "$dl_label"
    emit_progress "$dl_name" "$dl_final" "$dl_total" "$dl_label"
  fi
  progress_end

  # Exit 33/36 mean the server refused our resume offset. With no known size we
  # cannot tell a finished file from a broken one, so let the checksum decide.
  if [ "$dl_rc" -eq 33 ] || [ "$dl_rc" -eq 36 ]; then
    if [ "$dl_total" -eq 0 ]; then
      printf '  %sServer rejected the resume offset; verifying what we have.%s\n' "$YELLOW" "$RESET"
      rm -f "$dl_err"
      CURL_ERR_FILE=""
      return 0
    fi
  fi
  if [ "$dl_rc" -ne 0 ]; then
    if [ -s "$dl_err" ]; then
      printf '  %s%s%s\n' "$RED" "$(head -n 2 "$dl_err" | tr -d '\r')" "$RESET"
    fi
    rm -f "$dl_err"
    CURL_ERR_FILE=""
    return "$dl_rc"
  fi
  rm -f "$dl_err"
  CURL_ERR_FILE=""
  return 0
}

# Function to download a file with retry logic and exponential backoff.
# Every attempt resumes from the bytes already on disk, so a dropped connection
# costs the retry, not the download. An attempt that made progress resets the
# backoff, because a flaky link that keeps moving forward is worth staying on.
# Usage: download_with_retry <url> <output_file> [max_retries] [label]
download_with_retry() {
  url="$1"
  output_file="$2"
  max_retries="${3:-3}"
  label="${4:-}"
  attempt=1
  delay=2

  while [ "$attempt" -le "$max_retries" ]; do
    if [ "$attempt" -gt 1 ]; then
      printf '  %sAttempt %d of %d%s\n' "$GRAY_DIM" "$attempt" "$max_retries" "$RESET"
    fi
    before=$(file_size "$output_file")
    if download_with_progress "$url" "$output_file" "$label"; then
      return 0
    fi
    after=$(file_size "$output_file")

    if [ "$attempt" -lt "$max_retries" ]; then
      if [ "$after" -gt "$before" ]; then
        delay=2
      fi
      if [ "$after" -gt 0 ]; then
        printf '  %sDownload stopped at %s. Resuming in %ds...%s\n' \
          "$YELLOW" "$(human_bytes "$after")" "$delay" "$RESET"
      else
        printf '  %sDownload failed. Retrying in %ds...%s\n' "$YELLOW" "$delay" "$RESET"
      fi
      sleep "$delay"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done

  printf '  %sERROR: Download failed after %d attempts.%s\n' "$RED" "$max_retries" "$RESET"
  if [ "$(file_size "$output_file")" -gt 0 ]; then
    printf '  %sThe partial file is kept — re-run this script to resume.%s\n' "$GRAY" "$RESET"
  fi
  emit_error "Download failed after $max_retries attempts"
  return 1
}

UNZIP_PID=""

# Unzips <archive> into <dest> with a progress bar driven by the size of
# <watch-dir>, the directory the archive creates, and with the same progress
# events a --json consumer gets for downloads. Falls back to a plain quiet unzip
# when the uncompressed size is unavailable.
# Usage: extract_with_progress <archive> <dest> <watch-dir> [label]
extract_with_progress() {
  ex_zip="$1"
  ex_dest="$2"
  ex_watch="$3"
  ex_label="${4:-}"
  ex_name=$(basename "$ex_zip")

  ex_total=$(unzip -Zt "$ex_zip" 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "bytes") { print $(i - 1); exit } }')
  if [ -z "$ex_total" ]; then
    unzip -q -o "$ex_zip" -d "$ex_dest"
    return 0
  fi

  TERM_COLS=$(tput cols 2>/dev/null || echo 80)
  if [ "$INTERACTIVE" = true ]; then
    printf '%s' "$HIDE_CURSOR"
  fi
  unzip -q -o "$ex_zip" -d "$ex_dest" &
  UNZIP_PID=$!
  ex_prev_bytes=0
  ex_prev_time=$(date +%s)
  ex_bps=0
  while kill -0 "$UNZIP_PID" 2>/dev/null; do
    # The destination directory does not exist until unzip creates it, so `du`
    # can fail — `awk END` still prints a number, keeping the arithmetic valid.
    ex_now_bytes=$(du -sk "$ex_watch" 2>/dev/null | awk 'END { print $1 * 1024 }')
    ex_now_bytes=${ex_now_bytes:-0}
    ex_now_time=$(date +%s)
    if [ "$ex_now_time" -gt "$ex_prev_time" ]; then
      ex_bps=$(( (ex_now_bytes - ex_prev_bytes) / (ex_now_time - ex_prev_time) ))
      ex_prev_bytes=$ex_now_bytes
      ex_prev_time=$ex_now_time
      emit_progress "$ex_name" "$ex_now_bytes" "$ex_total" "$ex_label" "extracting"
    fi
    progress_render "$ex_now_bytes" "$ex_total" "$ex_bps" "$ex_label"
    sleep 0.5
  done

  ex_rc=0
  wait "$UNZIP_PID" || ex_rc=$?
  UNZIP_PID=""
  if [ "$ex_rc" -eq 0 ]; then
    progress_render "$ex_total" "$ex_total" "$ex_bps" "$ex_label"
    emit_progress "$ex_name" "$ex_total" "$ex_total" "$ex_label" "extracting"
  fi
  progress_end
  return "$ex_rc"
}

# Types a line out character by character. The line is peeled one character at a
# time with parameter expansion rather than indexed with a substring, which is a
# bash extension.
type_line() {
  if [ "$INTERACTIVE" != true ]; then
    printf '  %s\n' "$1"
    return 0
  fi
  printf '  %s' "${2:-$GRAY}"
  type_rest="$1"
  while [ -n "$type_rest" ]; do
    type_tail="${type_rest#?}"
    printf '%s' "${type_rest%"$type_tail"}"
    type_rest="$type_tail"
    sleep 0.012
  done
  printf '%s\n' "$RESET"
  return 0
}
# --- junie-ui:end ---

# Cleanup function — kills child processes on interrupt
cleanup() {
  exit_code="$1"

  # Avoid executing this trap recursively.
  trap - INT TERM

  # Close the progress bar and give the cursor back before printing anything.
  progress_end
  if [ -n "$CURL_ERR_FILE" ]; then
    rm -f "$CURL_ERR_FILE"
  fi

  echo ""
  if [ -d "$DOWNLOAD_DIR" ]; then
    printf '  %sInterrupted — partial downloads preserved in %s%s\n' "$YELLOW" "$DOWNLOAD_DIR" "$RESET"
    printf '  %sRe-run this script to resume from where it stopped.%s\n' "$GRAY" "$RESET"
    emit_error "Interrupted — partial downloads preserved, re-run to resume"
  else
    printf '  %sInterrupted.%s\n' "$YELLOW" "$RESET"
    emit_error "Interrupted"
  fi

  # curl and unzip are killed, not their partial output: the bytes already on
  # disk are what the next run resumes from.
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true

  wait_and_exit "$exit_code"
}

# Check if an engine version has been fully unpacked. As with the models, a
# completion marker is written after unpacking — a version directory without it
# is a leftover from an interrupted run.
engine_completion_marker() {
  echo "$VERSIONS_DIR/.$ENGINE_VERSION.installed"
}

engine_installed() {
  [ -f "$ENGINE_DIR/serverctl.sh" ] && [ -f "$(engine_completion_marker)" ]
}

# Function to download and unpack the inference engine, then point current at it
install_engine() {
  if engine_installed; then
    printf '  %sEngine v%s is already unpacked. Skipping download.%s\n' "$GRAY" "$ENGINE_VERSION" "$RESET"
  else
    echo "  Downloading $ENGINE_ARCHIVE..."
    download_with_retry "$ENGINE_URL" "$DOWNLOAD_DIR/$ENGINE_ARCHIVE" 3 "$ENGINE_LABEL"
    printf '  %sChecking SHA256...%s\n' "$GRAY" "$RESET"

    emit_activity "verifying" "$ENGINE_ARCHIVE" "$ENGINE_LABEL"
    actual_sha256=$(get_checksum "$DOWNLOAD_DIR/$ENGINE_ARCHIVE")
    if [ "$actual_sha256" != "$ENGINE_SHA256" ]; then
      printf '  %sERROR: SHA256 mismatch for %s%s\n' "$RED" "$ENGINE_ARCHIVE" "$RESET"
      echo "    Expected: $ENGINE_SHA256"
      echo "    Actual:   $actual_sha256"
      # A resumed download that ends up corrupt would keep failing this check
      # forever, so drop the file and let the next run fetch it again.
      rm -f "$DOWNLOAD_DIR/$ENGINE_ARCHIVE"
      printf '  %sThe damaged file was removed — re-run this script to download it again.%s\n' "$GRAY" "$RESET"
      emit_error "SHA256 mismatch for $ENGINE_ARCHIVE"
      wait_and_exit 1
    fi
    printf '  %sSHA256 verified%s %s%s%s\n' "$JUNIE_GREEN" "$RESET" "$GRAY_DIM" "$actual_sha256" "$RESET"

    echo "  Unpacking to $ENGINE_DIR..."
    emit_activity "extracting" "$ENGINE_ARCHIVE" "$ENGINE_LABEL"
    # Remove leftovers from a previously interrupted unpack
    rm -rf "$ENGINE_DIR"
    mkdir -p "$ENGINE_DIR"
    # The archive holds a single junie-mlx-vlm/ directory; strip it so the
    # binary lands directly in the version directory
    tar -xzf "$DOWNLOAD_DIR/$ENGINE_ARCHIVE" -C "$ENGINE_DIR" --strip-components=1
    touch "$(engine_completion_marker)"
    rm -f "$DOWNLOAD_DIR/$ENGINE_ARCHIVE"
    echo "  Unpack complete."
  fi

  # A real directory at current would make ln fail — refuse rather than delete it
  if [ -d "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
    echo "  ERROR: $CURRENT_LINK is a directory, not a symlink."
    echo "  Move it out of the way and re-run."
    emit_error "$CURRENT_LINK is a directory, not a symlink"
    wait_and_exit 1
  fi

  echo "  Pointing $CURRENT_LINK at $ENGINE_DIR..."
  ln -sfn "$ENGINE_DIR" "$CURRENT_LINK"
  echo ""
}

# Ensure server-config.json exists with the api_key and port fields. The engine
# handles all config updates after initial creation — we only create it here if
# it doesn't already exist.
handle_server_config() {
  SERVER_CONFIG="$BASE_DIR/server-config.json"

  # If the config already exists, leave it alone — the engine manages it.
  if [ -f "$SERVER_CONFIG" ]; then
    echo "  Reusing existing server-config.json."
    return 0
  fi

  # First run: generate a token and create the config file.
  local token
  token="sk-$(generate_token)"
  echo "  Auth token generated."
  echo "  Writing server-config.json with api_key and port..."
  cat > "$SERVER_CONFIG" <<EOF
{
  "api_key": "$token",
  "port": $ENGINE_PORT
}
EOF
  echo "  server-config.json created with bearer auth and port."
}

# Function to start the engine daemon using serverctl.sh. The daemon serves the
# public API and supervises the inference worker itself.
start_engine() {
  # Ensure server-config.json exists (created on first run, reused afterwards).
  handle_server_config

  # Read the auth token from the config file.
  local auth_token
  auth_token=$(get_json_field api_key < "$BASE_DIR/server-config.json")

  if [ ! -f "$ENGINE_CTL" ]; then
    echo "  ERROR: serverctl.sh not found at $ENGINE_CTL"
    echo "  Cannot start the engine without it."
    emit_error "serverctl.sh not found at $ENGINE_CTL"
    return 1
  fi

  # Stop an engine from an earlier run so it releases the port
  if is_engine_running; then
    echo "  Stopping the running engine..."
    "$ENGINE_CTL" stop >/dev/null 2>&1 || true
    waited=0
    while [ "$waited" -lt 10 ] && is_engine_running; do
      sleep 1
      waited=$((waited + 1))
    done
  fi

  # Start via serverctl.sh (the subshell keeps the daemon out of this script's
  # job table so the interrupt handler cannot take it down with the installer).
  # 3>&- keeps the spawned daemon from inheriting the machine-output event
  # stream: a consumer reading our stdout would otherwise never see
  # end-of-stream because the daemon holds the pipe open forever.
  echo "  Starting the engine..."
  ( "$ENGINE_CTL" start > /dev/null 2>&1 3>&- )

  # Wait for the engine to become ready by polling /status until phase is "ready".
  waited=0
  while [ "$waited" -lt 30 ]; do
    phase=$(curl -s -m 5 -H "Authorization: Bearer $auth_token" "http://localhost:$ENGINE_PORT/status" 2>/dev/null \
      | get_json_field phase || true)
    if [ "$phase" = "ready" ]; then
      echo "  Engine is ready on port $ENGINE_PORT."
      return 0
    fi
    if [ "$phase" = "error" ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "  WARNING: the engine is not answering on port $ENGINE_PORT yet."
  echo "  Check the engine logs in $BASE_DIR"
  emit_warning "engine did not start listening on port $ENGINE_PORT — see logs in $BASE_DIR"
  return 1
}

# Function to download and verify a model archive
download_and_verify() {
  download_url="$1"
  archive="$2"
  expected_sha256="$3"
  archive_label="$4"

  echo "  Downloading $archive..."
  download_with_retry "$download_url" "$DOWNLOAD_DIR/$archive" 3 "$archive_label"
  printf '  %sChecking SHA256...%s\n' "$GRAY" "$RESET"

  emit_activity "verifying" "$archive" "$archive_label"
  actual=$(get_checksum "$DOWNLOAD_DIR/$archive")
  if [ "$actual" != "$expected_sha256" ]; then
    printf '  %sERROR: SHA256 mismatch for %s%s\n' "$RED" "$archive" "$RESET"
    echo "    Expected: $expected_sha256"
    echo "    Actual:   $actual"
    # Keeping a corrupt archive would make every later run resume into the same
    # mismatch, so it is dropped and re-downloaded from scratch next time.
    rm -f "$DOWNLOAD_DIR/$archive"
    printf '  %sThe damaged archive was removed — re-run this script to download it again.%s\n' "$GRAY" "$RESET"
    emit_error "SHA256 mismatch for $archive"
    wait_and_exit 1
  fi
  printf '  %sSHA256 verified%s %s%s%s\n' "$JUNIE_GREEN" "$RESET" "$GRAY_DIM" "$actual" "$RESET"
}

# Check if a model has been fully unzipped to the models directory.
# Each archive unpacks into $MODELS_DIR/<model_id>. A completion marker file is
# written after extraction — a model directory without it is a leftover from an
# interrupted extraction.
model_completion_marker() {
  echo "$MODELS_DIR/.$1.installed"
}

model_installed() {
  model_id="$1"
  [ -d "$MODELS_DIR/$model_id" ] && [ -f "$(model_completion_marker "$model_id")" ]
}

# Download and install each model only if not already present.
# Takes the archive index within the model JSON's archives array.
install_model_if_needed() {
  archive_index="$1"

  zip_file=$(get_archive_field "$archive_index" name)
  download_url=$(get_archive_field "$archive_index" downloadUrl)
  sha256_sum=$(get_archive_field "$archive_index" sha256)
  model_id=$(get_archive_field "$archive_index" modelId)
  model_label=$(get_archive_field "$archive_index" label)

  if model_installed "$model_id"; then
    printf '  %sModel %s is already installed. Skipping.%s\n\n' "$GRAY" "$model_id" "$RESET"
    return 0
  fi

  printf '  %sModel %s is not installed. Proceeding...%s\n\n' "$GRAY" "$model_label" "$RESET"
  download_and_verify "$download_url" "$zip_file" "$sha256_sum" "$model_label"
  echo "  Extracting $zip_file..."
  emit_activity "extracting" "$zip_file" "$model_label"
  # Remove leftovers from a previously interrupted extraction — the path is
  # spelled out instead of using $MODELS_DIR so the rm -rf target is explicit
  rm -rf "$BASE_DIR/models/$model_id"
  extract_with_progress "$DOWNLOAD_DIR/$zip_file" "$MODELS_DIR" "$MODELS_DIR/$model_id" "$model_label"
  touch "$(model_completion_marker "$model_id")"
  printf '  %sExtraction complete.%s\n\n' "$JUNIE_GREEN" "$RESET"
}

if [ "$LIST_MODELS" = true ]; then
  if [ "$MACHINE_OUTPUT" != true ]; then
    echo "Available models for $PLATFORM ($CHANNEL channel):"
  fi
  list_available_models
  exit 0
fi

# ============================================================
# System validation
# ============================================================

# ============================================================
# Collect system information
# ============================================================

# OS detection — collect all platform-specific system info in one place.
UNAME_OUT=$(uname -s)
if [ "$OS_TYPE" = "macos" ]; then
  OS_FULL_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  OS_VERSION=$(echo "$OS_FULL_VERSION" | cut -d '.' -f 1)
  CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
  MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
else
  OS_FULL_VERSION=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | tr -d '"=' | cut -d' ' -f1)
  if [ -z "$OS_FULL_VERSION" ]; then
    OS_FULL_VERSION=$(uname -r)
  fi
  OS_VERSION=$(echo "$OS_FULL_VERSION" | cut -d '.' -f 1)
  if command -v lscpu > /dev/null 2>&1; then
    CPU_MODEL=$(lscpu 2>/dev/null | grep 'Model name' | cut -d: -f2 | sed 's/^[ ]*//' || echo "unknown")
  else
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ ]*//' || echo "unknown")
  fi
  MEM_BYTES=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2 * 1024}' || echo "0")
fi
MEM_GB=$((MEM_BYTES / 1073741824))

# ============================================================
# System info summary: evaluate & display
# ============================================================
junie_logo
type_line "Local model installer" "$GRAY"
section "System information"

ALL_OK=true

# OS check
# macOS: require 26+
# Linux: require kernel 5.15+ (for CUDA and modern GPU drivers)
OS_OK=true
OS_REQUIREMENT=""
if [ "$OS_TYPE" = "macos" ]; then
  if [ "$UNAME_OUT" != "Darwin" ]; then
    OS_OK=false
    ALL_OK=false
  elif [ "$OS_VERSION" -lt 26 ]; then
    OS_OK=false
    ALL_OK=false
  fi
  OS_DISPLAY="macOS $OS_FULL_VERSION"
  OS_REQUIREMENT="macOS 26 or higher"
else
  KERNEL_VERSION=$(uname -r | cut -d '.' -f 1-2)
  KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d '.' -f 1)
  KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d '.' -f 2)
  if [ "$KERNEL_MAJOR" -lt 5 ] || { [ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -lt 15 ]; }; then
    OS_OK=false
    ALL_OK=false
  fi
  OS_DISPLAY="Linux $OS_FULL_VERSION (kernel $(uname -r))"
  OS_REQUIREMENT="Linux kernel 5.15 or higher"
fi
print_value "OS:" "$OS_DISPLAY" "$OS_OK" false "$OS_REQUIREMENT"
emit_check "os" "$(check_status "$OS_OK" false)" "$OS_DISPLAY" "$OS_REQUIREMENT"

# Accelerator check
# macOS: require Apple M5 or newer (MLX)
# Linux: require NVIDIA GPU with 24 GB VRAM and CUDA 12+ (CUDA)
CPU_OK=true
ACCEL_DISPLAY="$CPU_MODEL"
ACCEL_REQUIREMENT=""
GPU_NAME=""
GPU_VRAM_GB=0
CUDA_OK=true
CUDA_DISPLAY=""
CUDA_REQUIREMENT=""

if [ "$OS_TYPE" = "macos" ]; then
  # The generation is read out of the brand string ("Apple M5 Pro" -> 5) and
  # compared numerically, so every chip released after the M5 clears the check
  # without this having to be extended for each new generation.
  CPU_GENERATION=$(printf '%s' "$CPU_MODEL" | sed -n 's/.*Apple M\([0-9][0-9]*\).*/\1/p')
  if [ -z "$CPU_GENERATION" ] || [ "$CPU_GENERATION" -lt 5 ]; then
    CPU_OK=false
    ALL_OK=false
  fi
  ACCEL_REQUIREMENT="Apple M5 or newer"
else
  # NVIDIA GPU check via nvidia-smi (not required in require_commands, so it
  # may be absent — handle that gracefully here with a clear message)
  if ! command -v nvidia-smi > /dev/null 2>&1; then
    CPU_OK=false
    ALL_OK=false
    CUDA_OK=false
    ACCEL_DISPLAY="nvidia-smi not found"
    ACCEL_REQUIREMENT="NVIDIA GPU with 24 GB VRAM and CUDA 12+"
    CUDA_DISPLAY="CUDA not detected"
    CUDA_REQUIREMENT="CUDA 12+"
  else
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -z "$GPU_INFO" ]; then
      CPU_OK=false
      ALL_OK=false
      ACCEL_DISPLAY="No NVIDIA GPU detected"
      ACCEL_REQUIREMENT="NVIDIA GPU with 24 GB VRAM and CUDA 12+"
    else
      GPU_NAME=$(echo "$GPU_INFO" | cut -d',' -f1 | sed 's/^[ ]*//')
      GPU_VRAM_MB=$(echo "$GPU_INFO" | cut -d',' -f2 | sed 's/^[ ]*//')
      GPU_VRAM_GB=$((GPU_VRAM_MB / 1024))
      DRIVER_VERSION=$(echo "$GPU_INFO" | cut -d',' -f3 | sed 's/^[ ]*//')
      ACCEL_DISPLAY="$GPU_NAME ($GPU_VRAM_GB GB VRAM, driver $DRIVER_VERSION)"
      ACCEL_REQUIREMENT="NVIDIA GPU with 24 GB VRAM and CUDA 12+"
      
      if [ "$GPU_VRAM_GB" -lt 24 ]; then
        CPU_OK=false
        ALL_OK=false
      fi
    fi

    # CUDA version check — nvidia-smi reports the highest supported CUDA version
    # in its output header, e.g. "CUDA Version: 12.2"
    CUDA_MAJOR=$(nvidia-smi 2>/dev/null | grep 'CUDA Version' | awk '{print $NF}' | cut -d '.' -f 1)
    if [ -z "$CUDA_MAJOR" ]; then
      CUDA_OK=false
      ALL_OK=false
      CUDA_DISPLAY="CUDA version not detected"
      CUDA_REQUIREMENT="CUDA 12+"
    elif [ "$CUDA_MAJOR" -lt 12 ]; then
      CUDA_OK=false
      ALL_OK=false
      CUDA_DISPLAY="CUDA $CUDA_MAJOR.x"
      CUDA_REQUIREMENT="CUDA 12+"
    else
      CUDA_DISPLAY="CUDA $CUDA_MAJOR.x"
      CUDA_REQUIREMENT="CUDA 12+"
    fi
  fi
fi

print_value "CPU:" "$CPU_MODEL" true false ""
emit_check "cpu" "ok" "$CPU_MODEL" ""
print_value "GPU:" "$ACCEL_DISPLAY" "$CPU_OK" false "$ACCEL_REQUIREMENT"
emit_check "gpu" "$(check_status "$CPU_OK" false)" "$ACCEL_DISPLAY" "$ACCEL_REQUIREMENT"
if [ "$OS_TYPE" = "linux" ]; then
  print_value "CUDA:" "$CUDA_DISPLAY" "$CUDA_OK" false "$CUDA_REQUIREMENT"
  emit_check "cuda" "$(check_status "$CUDA_OK" false)" "$CUDA_DISPLAY" "$CUDA_REQUIREMENT"
fi

# RAM check (hard: >= 40 GB, recommended: >= 60 GB)
RAM_OK=true
RAM_WARN=false
if [ "$MEM_GB" -lt 40 ]; then
  RAM_OK=false
  ALL_OK=false
elif [ "$MEM_GB" -lt 60 ]; then
  RAM_WARN=true
fi
print_value "RAM:" "${MEM_GB} GB" "$RAM_OK" "$RAM_WARN" "minimum 40 GB, 60 GB recommended"
emit_check "ram" "$(check_status "$RAM_OK" "$RAM_WARN")" "${MEM_GB} GB" "minimum 40 GB, 60 GB recommended"

# The install configuration is not shown; it still travels as an event so a
# machine consumer sees the port, the RAM allowance and the engine version.
emit_event "\"event\":\"config\",\"port\":$ENGINE_PORT,\"ram_gb\":$ENGINE_RAM_GB,\"engine_version\":\"$(json_escape "$ENGINE_VERSION")\",\"model\":\"$(json_escape "$MODEL")\",\"checks_passed\":$ALL_OK"

if [ "$CHECK_ONLY" = true ]; then
  if [ "$ALL_OK" = true ]; then
    exit 0
  else
    exit 1
  fi
fi

# ============================================================
# Abort unless all hard requirements are met
# ============================================================
if [ "$ALL_OK" = false ]; then
  echo ""
  printf '  %sSome system requirements are not met. Installation cannot proceed.%s\n' "$RED" "$RESET"
  emit_error "Some system requirements are not met. Installation cannot proceed."
  wait_and_exit 1
fi

# ============================================================
# Main installation flow
# ============================================================

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# Create directories
printf '  %sCreating directories...%s\n' "$GRAY" "$RESET"
mkdir -p "$MODELS_DIR"
mkdir -p "$VERSIONS_DIR"
mkdir -p "$DOWNLOAD_DIR"

# ============================================================
# Step 1: Install the inference engine
# ============================================================
section "Installing the inference engine"
emit_step_start "engine" "Installing the inference engine"
install_engine
emit_step_done "engine"

# ============================================================
# Step 2: Download and install models
# ============================================================
section "Installing models"
emit_step_start "models" "Installing models"

# Download and install each archive listed in the model JSON.
for i in $(seq 0 $((ARCHIVE_COUNT - 1))); do
  install_model_if_needed "$i"
done

# Cleanup model downloads
printf '  %sRemoving downloaded archives...%s\n' "$GRAY" "$RESET"
rm -rf "$DOWNLOAD_DIR"
emit_step_done "models"

# ============================================================
# Step 3: Configure Junie
# ============================================================
section "Configuring Junie"
emit_step_start "configure" "Configuring Junie"
# Setting the default model is handled by the engine on its first run.
emit_step_done "configure"

# ============================================================
# Step 4: Start the inference engine
# ============================================================
section "Starting the inference engine"
emit_step_start "start" "Starting the inference engine"
start_engine || true
emit_step_done "start"

if [ "$KEEP_CONFIG" = true ]; then
  echo ""
  printf '  %sNote: --keep-config is set, the previous server-config.json was preserved.%s\n' "$GRAY_DIM" "$RESET"
fi

section "Installation complete"
type_line "Local model installed." "$JUNIE_GREEN$BOLD"
echo ""
print_value "Engine:" "$ENGINE_DIR" true false ""
print_value "Current version:" "$CURRENT_LINK -> $ENGINE_DIR" true false ""
print_value "Models:" "$MODELS_DIR" true false ""
print_value "Logs:" "$BASE_DIR" true false ""
print_value "Junie model config:" "$JUNIE_HOME/models/${JUNIE_MODEL_ID}.json" true false ""
print_value "Default model:" "$JUNIE_MODEL_ID" true false ""
echo ""
printf '  %sThe engine serves http://localhost:%s — the first request has to wait%s\n' "$GRAY" "$ENGINE_PORT" "$RESET"
printf '  %sfor the model to load.%s\n' "$GRAY" "$RESET"
printf '  %sControl the engine with: %s {start|stop|status|wait}%s\n' "$GRAY" "$ENGINE_CTL" "$RESET"
MAIN_MODEL_ID=$(get_archive_field 0 modelId)
MAIN_LABEL=$(get_archive_field 0 label)
emit_event "\"event\":\"done\",\"model_id\":\"$JUNIE_MODEL_ID\",\"port\":$ENGINE_PORT,\"model_path\":\"$(json_escape "$MODELS_DIR/$MAIN_MODEL_ID")\",\"label\":\"$(json_escape "$MAIN_LABEL")\""
wait_and_exit 0
