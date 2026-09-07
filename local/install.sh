#!/bin/sh
set -e

# ============================================================
# Command-line arguments
# ============================================================

PROTOCOL_VERSION=1

MACHINE_OUTPUT=false
CHECK_ONLY=false
KEEP_CONFIG=false
MODEL="qwen3_6"
CHANNEL="main"

usage() {
  echo "Usage: install.sh [options]"
  echo ""
  echo "Options:"
  echo "  --model <name>     Model to install: qwen3_6 (default) or qwen3_8"
  echo "  --channel <name>   Update channel: main (default) or eap"
  echo "  --check-only       Report system information, then exit"
  echo "  --json             Emit machine-readable events on stdout, human output on stderr"
  echo "  --keep-config      Preserve the existing server-config.json instead of removing it"
  echo "  --help, -h         Show this help"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) MACHINE_OUTPUT=true ;;
    --check-only) CHECK_ONLY=true ;;
    --keep-config) KEEP_CONFIG=true ;;
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

BASE_URL="https://download.jetbrains.com/resources/junie-local"
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

# Detect the target platform (e.g. macos-aarch64).
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
# Model configuration: fetched from update-info-models-<channel>.json
# ============================================================

# Base URL for the update-info files (engine and model metadata). Override via
# environment variable to point at a custom location during testing/deployment.
UPDATE_FILES_BASE_URL="${JUNIE_LOCAL_UPDATE_FILES_BASE_URL:-https://raw.githubusercontent.com/jetbrains-junie/junie/main/local}"

# Model update metadata is published per channel as a JSON file with two top
# level sections:
#   models  -- model descriptors keyed by model id (must not contain dots)
#   archives -- archive descriptors keyed by <model_id>[_mtp]_<platform>.
# The platform section inside a model lists the archiveIds to install.
MODELS_UPDATE_URL="${UPDATE_FILES_BASE_URL}/update-info-models-${CHANNEL}.json"

# Global: the fetched JSON, kept for archive lookups later in the script.
models_json=""

# Extract a flat field from a top-level archive entry.
get_archive_field() {
  local archive_id="$1"
  local field="$2"
  printf '%s' "$models_json" | plutil -extract "archives.${archive_id}.${field}" raw -o - -- - 2>/dev/null
}

fetch_models_config() {
  models_json=$(curl -fsSL "$MODELS_UPDATE_URL" 2>/dev/null) || {
    echo "ERROR: Could not fetch models config from $MODELS_UPDATE_URL"
    exit 1
  }

  # Validate the requested model exists.
  model_section=$(printf '%s' "$models_json" | plutil -extract "models.$MODEL" json -o - -- - 2>/dev/null || true)
  if [ -z "$model_section" ]; then
    supported=$(printf '%s' "$models_json" | plutil -extract models raw -o - -- - | tr '\n' ',' | sed 's/,$//')
    echo "ERROR: Unknown model: $MODEL (supported: $supported)"
    exit 1
  fi

  # Validate the requested platform exists for this model.
  platform_section=$(printf '%s' "$model_section" | plutil -extract "platforms.$PLATFORM" json -o - -- - 2>/dev/null || true)
  if [ -z "$platform_section" ]; then
    supported=$(printf '%s' "$model_section" | plutil -extract platforms raw -o - -- - | tr '\n' ',' | sed 's/,$//')
    echo "ERROR: No model entry for platform $PLATFORM (supported: $supported)"
    exit 1
  fi

  # Extract the model fields.
  JUNIE_MODEL_ID=$(printf '%s' "$model_section" | plutil -extract junieModelId raw -o - -- -)
  JUNIE_MODEL_DISPLAY_NAME=$(printf '%s' "$model_section" | plutil -extract displayName raw -o - -- -)

  # Extract the list of archive ids to install (space separated).
  ARCHIVE_IDS=$(printf '%s' "$platform_section" | plutil -extract archiveIds json -o - -- - \
    | sed 's/\[//; s/\]//; s/"//g; s/,/ /g')
}

fetch_models_config

# Name the engine serves the main model under. It matches the directory the
# first archive unpacks into under $MODELS_DIR.
MAIN_ARCHIVE_ID=$(echo "$ARCHIVE_IDS" | awk '{print $1}')
ENGINE_MODEL_NAME=$(get_archive_field "$MAIN_ARCHIVE_ID" modelId)

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
}

fetch_engine_config

ENGINE_VERSION=$(printf '%s' "$engine_entry" | grep -o '"version":"[^"]*"' | sed 's/"version":"\([^"]*\)"/\1/')
ENGINE_URL=$(printf '%s' "$engine_entry" | grep -o '"downloadUrl":"[^"]*"' | sed 's/"downloadUrl":"\([^"]*\)"/\1/')
ENGINE_SHA256=$(printf '%s' "$engine_entry" | grep -o '"sha256":"[^"]*"' | sed 's/"sha256":"\([^"]*\)"/\1/')
# Archive name is the last path segment of the download URL.
ENGINE_ARCHIVE=$(printf '%s' "$ENGINE_URL" | sed 's|.*/||')

# Inference engine release. Versions are unpacked side by side under versions/
# and the current symlink points at the one to run.
ENGINE_LABEL="inference engine"
VERSIONS_DIR="$BASE_DIR/versions"
ENGINE_DIR="$VERSIONS_DIR/$ENGINE_VERSION"
CURRENT_LINK="$BASE_DIR/current"
ENGINE_BIN="$CURRENT_LINK/junie-mlx-vlm"
ENGINE_CTL="$CURRENT_LINK/serverctl.sh"
ENGINE_DAEMON_LOG="$BASE_DIR/junie-mlx-vlm-daemon.log"

# The port the engine serves on (the Junie model config below points at it) and
# the RAM allowance it may spend on weights and KV cache. The engine reads the
# rest of its settings from $BASE_DIR/server-config.json, which it writes itself
# on first start. Nothing here consumes the RAM allowance yet — it is only
# displayed and reported in the "config" event.
ENGINE_PORT=19239
ENGINE_RAM_GB=35

# Bearer auth token for local engine-to-Junie communication. Generated on first
# install and stored in server-config.json (api_key field). On re-runs the
# installer reads the existing token from server-config.json to keep it stable.
AUTH_TOKEN=""

# Junie model configuration. The id and display name come from the selected
# model above, so each variant gets its own config file in $JUNIE_HOME/models.
JUNIE_CUSTOM_MODEL_ID="custom:$JUNIE_MODEL_ID"
JUNIE_MODEL_PROVIDER_NAME="Local"
# seems to be optimal context length
JUNIE_MAX_CONTEXT_LENGTH=150000

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

# ============================================================
# Collect system information
# ============================================================

# OS detection
UNAME_OUT=$(uname -s)
OS_FULL_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
OS_VERSION=$(echo "$OS_FULL_VERSION" | cut -d '.' -f 1)

# CPU model
CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")

# Total memory in GB
MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
MEM_GB=$((MEM_BYTES / 1073741824))

# ============================================================
# System info summary: evaluate & display
# ============================================================
junie_logo
type_line "Local model installer" "$GRAY"
section "System information"

ALL_OK=true

# OS check (hard requirement: macOS 26+)
OS_OK=true
if [ "$UNAME_OUT" != "Darwin" ]; then
  OS_OK=false
  ALL_OK=false
elif [ "$OS_VERSION" -lt 26 ]; then
  OS_OK=false
  ALL_OK=false
fi
if [ "$UNAME_OUT" = "Darwin" ]; then
  OS_DISPLAY="macOS $OS_FULL_VERSION"
else
  OS_DISPLAY="$UNAME_OUT $OS_FULL_VERSION"
fi
print_value "OS:" "$OS_DISPLAY" "$OS_OK" false "macOS 26 or higher"
emit_check "os" "$(check_status "$OS_OK" false)" "$OS_DISPLAY" "macOS 26 or higher"

# CPU check (hard requirement: Apple M5 or newer)
#
# The generation is read out of the brand string ("Apple M5 Pro" -> 5) and
# compared numerically, so every chip released after the M5 clears the check
# without this having to be extended for each new generation. Everything below an
# M5 is turned away, as is an Intel Mac, whose brand string carries no
# "Apple M<n>" at all.
CPU_GENERATION=$(printf '%s' "$CPU_MODEL" | sed -n 's/.*Apple M\([0-9][0-9]*\).*/\1/p')
CPU_OK=true
if [ -z "$CPU_GENERATION" ] || [ "$CPU_GENERATION" -lt 5 ]; then
  CPU_OK=false
  ALL_OK=false
fi
print_value "CPU:" "$CPU_MODEL" "$CPU_OK" false "M5 or newer"
emit_check "cpu" "$(check_status "$CPU_OK" false)" "$CPU_MODEL" "M5 or newer"

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

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# Create directories
printf '  %sCreating directories...%s\n' "$GRAY" "$RESET"
mkdir -p "$MODELS_DIR"
mkdir -p "$VERSIONS_DIR"
mkdir -p "$DOWNLOAD_DIR"

# Check if an engine version has been fully unpacked. As with the models, a
# completion marker is written after unpacking — a version directory without it
# is a leftover from an interrupted run.
engine_completion_marker() {
  echo "$VERSIONS_DIR/.$ENGINE_VERSION.installed"
}

engine_installed() {
  [ -x "$ENGINE_DIR/junie-mlx-vlm" ] && [ -f "$ENGINE_DIR/serverctl.sh" ] && [ -f "$(engine_completion_marker)" ]
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
    actual_sha256=$(shasum -a 256 "$DOWNLOAD_DIR/$ENGINE_ARCHIVE" | awk '{print $1}')
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

# Generate a random bearer token: "sk-" plus 12 random bytes in hex.
generate_auth_token() {
  AUTH_TOKEN=$(printf 'sk-%s' "$(head -c 12 /dev/urandom | xxd -p)")
  echo "  Auth token generated."
}

# Read the bearer token from an existing server-config.json using plutil.
read_auth_token_from_server_config() {
  SERVER_CONFIG="$BASE_DIR/server-config.json"
  if [ -f "$SERVER_CONFIG" ]; then
    AUTH_TOKEN=$(plutil -extract api_key raw "$SERVER_CONFIG" 2>/dev/null || true)
  fi
}

# Write server-config.json with the api_key field set to the generated bearer
# token. The engine will read this on startup and enforce auth on all endpoints.
# With --keep-config the previous file is left in place.
handle_server_config() {
  SERVER_CONFIG="$BASE_DIR/server-config.json"

  # On re-run, try to read the existing token from server-config.json before
  # removing it, so we can reuse it in the fresh config.
  if [ -z "$AUTH_TOKEN" ] && [ -f "$SERVER_CONFIG" ]; then
    read_auth_token_from_server_config
  fi

  if [ -f "$SERVER_CONFIG" ]; then
    if [ "$KEEP_CONFIG" = true ]; then
      echo "  Keeping existing server-config.json (--keep-config)."
    else
      echo "  Removing existing server-config.json (use --keep-config to preserve)."
      rm -f "$SERVER_CONFIG"
    fi
  fi

  if [ -z "$AUTH_TOKEN" ]; then
    generate_auth_token
  fi

  if [ "$KEEP_CONFIG" != true ]; then
    echo "  Writing server-config.json with api_key..."
    cat > "$SERVER_CONFIG" <<EOF
{
  "api_key": "$AUTH_TOKEN"
}
EOF
    echo "  server-config.json created with bearer auth."
  fi
}

# Function to start the engine daemon using serverctl.sh. The daemon serves the
# public API and supervises the inference worker itself.
start_engine() {
  # Remove the config file by default so the engine writes a fresh one on first start.
  handle_server_config

  if [ ! -x "$ENGINE_BIN" ]; then
    echo "  WARNING: engine binary not found at $ENGINE_BIN"
    echo "  Skipping engine startup."
    emit_warning "engine binary not found at $ENGINE_BIN — start it manually"
    return 1
  fi

  if [ ! -f "$ENGINE_CTL" ]; then
    echo "  WARNING: serverctl.sh not found at $ENGINE_CTL — falling back to direct start"
    emit_warning "serverctl.sh missing — using direct binary start"
  fi

  # Stop an engine from an earlier run so it releases the port
  if pgrep -f junie-mlx-vlm > /dev/null 2>&1; then
    echo "  Stopping the running engine..."
    if [ -f "$ENGINE_CTL" ]; then
      "$ENGINE_CTL" stop >/dev/null 2>&1 || true
    else
      pkill -f junie-mlx-vlm || true
    fi
    waited=0
    while [ "$waited" -lt 10 ] && pgrep -f junie-mlx-vlm > /dev/null 2>&1; do
      sleep 1
      waited=$((waited + 1))
    done
  fi

  # Start via serverctl.sh (the subshell keeps the daemon out of this script's
  # job table so the interrupt handler cannot take it down with the installer).
  # 3>&- keeps the spawned daemon from inheriting the machine-output event
  # stream: a consumer reading our stdout would otherwise never see
  # end-of-stream because the daemon holds the pipe open forever.
  echo "  Starting the engine (log: $ENGINE_DAEMON_LOG)..."
  if [ -f "$ENGINE_CTL" ]; then
    ( "$ENGINE_CTL" start > /dev/null 2>&1 3>&- )
  else
    ( nohup "$ENGINE_BIN" daemon < /dev/null >> "$ENGINE_DAEMON_LOG" 2>&1 3>&- & )
  fi

  # Wait for the engine to become ready. serverctl.sh wait polls /status until
  # phase is "ready"; fall back to a simple port check if it is unavailable.
  if [ -f "$ENGINE_CTL" ]; then
    waited=0
    while [ "$waited" -lt 30 ]; do
      phase=$(curl -s -m 5 -H "Authorization: Bearer $AUTH_TOKEN" "http://localhost:$ENGINE_PORT/status" 2>/dev/null \
        | plutil -extract phase raw -o - -- - 2>/dev/null || true)
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
  else
    waited=0
    while [ "$waited" -lt 26 ]; do
      if nc -z localhost "$ENGINE_PORT" 2>/dev/null; then
        echo "  Engine is listening on port $ENGINE_PORT."
        return 0
      fi
      sleep 1
      waited=$((waited + 1))
    done
  fi

  echo "  WARNING: the engine is not answering on port $ENGINE_PORT yet."
  echo "  Check the log at $ENGINE_DAEMON_LOG"
  emit_warning "engine did not start listening on port $ENGINE_PORT — see $ENGINE_DAEMON_LOG"
  return 1
}

# Function to create Junie model config file with bearer auth
create_junie_model_config() {
  JUNIE_MODELS_DIR="$JUNIE_HOME/models"
  JUNIE_CONFIG_FILE="$JUNIE_MODELS_DIR/${JUNIE_MODEL_ID}.json"

  # Create the models directory if it doesn't exist
  if [ ! -d "$JUNIE_MODELS_DIR" ]; then
    mkdir -p "$JUNIE_MODELS_DIR"
  fi

  # Ensure the auth token is available; if handle_server_config already ran,
  # AUTH_TOKEN is already set. Otherwise read from server-config.json or generate.
  if [ -z "$AUTH_TOKEN" ]; then
    read_auth_token_from_server_config
  fi
  if [ -z "$AUTH_TOKEN" ]; then
    generate_auth_token
  fi

  # Write the Junie model config with the bearer token as apiKey.
  echo "  Creating Junie model config at $JUNIE_CONFIG_FILE..."
  cat > "$JUNIE_CONFIG_FILE" <<EOF
{
  "displayName": "$JUNIE_MODEL_DISPLAY_NAME",
  "providerName": "$JUNIE_MODEL_PROVIDER_NAME",
  "id": "$ENGINE_MODEL_NAME",
  "baseUrl": "http://localhost:$ENGINE_PORT/v1/chat/completions",
  "apiType": "OpenAICompletion",
  "apiKey": "$AUTH_TOKEN",
  "temperature": 0.6,
  "maxContextLength": $JUNIE_MAX_CONTEXT_LENGTH,
  "extraBody": {
    "enable_thinking": false
  }
}
EOF
  echo "  Junie model config created with bearer auth."
  return 0
}

# Function to set the local model as the default in Junie settings
set_default_junie_model() {
  JUNIE_SETTINGS="$JUNIE_HOME/settings.json"

  if [ ! -f "$JUNIE_SETTINGS" ]; then
    echo "  WARNING: Junie settings not found at $JUNIE_SETTINGS"
    echo "  Skipping default model configuration."
    emit_warning "Junie settings not found — the local model was not set as default"
    return 1
  fi

  echo "  Setting local model as default in Junie..."
  plutil -replace "modelForLaunch" -string "$JUNIE_CUSTOM_MODEL_ID" "$JUNIE_SETTINGS"
  echo "  Default model set to $JUNIE_MODEL_ID."
  return 0
}

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

# Function to download and verify a model archive
download_and_verify() {
  archive="$1"
  expected_sha256="$2"
  archive_label="$3"

  echo "  Downloading $archive..."
  download_with_retry "$BASE_URL/$archive" "$DOWNLOAD_DIR/$archive" 3 "$archive_label"
  printf '  %sChecking SHA256...%s\n' "$GRAY" "$RESET"

  emit_activity "verifying" "$archive" "$archive_label"
  actual=$(shasum -a 256 "$DOWNLOAD_DIR/$archive" | awk '{print $1}')
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

# Download and install each model only if not already present
install_model_if_needed() {
  zip_file="$1"
  sha256_sum="$2"
  model_id="$3"
  model_label="$4"

  if model_installed "$model_id"; then
    printf '  %sModel %s is already installed. Skipping.%s\n\n' "$GRAY" "$model_id" "$RESET"
    return 0
  fi

  printf '  %sModel %s is not installed. Proceeding...%s\n\n' "$GRAY" "$model_id" "$RESET"
  download_and_verify "$zip_file" "$sha256_sum" "$model_label"
  echo "  Extracting $zip_file..."
  emit_activity "extracting" "$zip_file" "$model_label"
  # Remove leftovers from a previously interrupted extraction — the path is
  # spelled out instead of using $MODELS_DIR so the rm -rf target is explicit
  rm -rf "$BASE_DIR/models/$model_id"
  extract_with_progress "$DOWNLOAD_DIR/$zip_file" "$MODELS_DIR" "$MODELS_DIR/$model_id" "$model_label"
  touch "$(model_completion_marker "$model_id")"
  printf '  %sExtraction complete.%s\n\n' "$JUNIE_GREEN" "$RESET"
}

# Download and install each archive listed for this model + platform.
for archive_id in $ARCHIVE_IDS; do
  install_model_if_needed "$archive_id"
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
# These degrade gracefully with warnings; without `|| true` a return 1
# would abort the script under `set -e`.
create_junie_model_config || true
set_default_junie_model || true
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
print_value "Engine log:" "$ENGINE_DAEMON_LOG" true false ""
print_value "Junie model config:" "$JUNIE_HOME/models/${JUNIE_MODEL_ID}.json" true false ""
print_value "Default model:" "$JUNIE_MODEL_ID" true false ""
echo ""
printf '  %sThe engine serves http://localhost:%s — the first request has to wait%s\n' "$GRAY" "$ENGINE_PORT" "$RESET"
printf '  %sfor the model to load.%s\n' "$GRAY" "$RESET"
printf '  %sControl the engine with: %s {start|stop|status|wait}%s\n' "$GRAY" "$ENGINE_CTL" "$RESET"
MAIN_MODEL_ID=$(get_archive_field "$MAIN_ARCHIVE_ID" modelId)
MAIN_LABEL=$(get_archive_field "$MAIN_ARCHIVE_ID" label)
emit_event "\"event\":\"done\",\"model_id\":\"$JUNIE_MODEL_ID\",\"port\":$ENGINE_PORT,\"model_path\":\"$(json_escape "$MODELS_DIR/$MAIN_MODEL_ID")\",\"label\":\"$(json_escape "$MAIN_LABEL")\""
wait_and_exit 0
