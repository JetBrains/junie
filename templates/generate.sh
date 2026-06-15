#!/usr/bin/env bash
#
# generate.sh — regenerate the installer scripts in the repo root from the
# templates in this directory.
#
# Usage:
#   ./templates/generate.sh           # write install*.sh and install*.ps1
#   ./templates/generate.sh --check   # do not write; diff and exit non-zero
#                                       if any output would differ
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHANNELS_FILE="$SCRIPT_DIR/channels.tsv"
TPL_SH="$SCRIPT_DIR/install.sh.template"
TPL_PS1="$SCRIPT_DIR/install.ps1.template"
SHIM_SH="$SCRIPT_DIR/junie.shim.sh"
SHIM_BAT="$SCRIPT_DIR/junie.shim.bat"

MODE="write"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --check) MODE="check" ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "generate.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
fi

# Sanity checks.
for f in "$CHANNELS_FILE" "$TPL_SH" "$TPL_PS1" "$SHIM_SH" "$SHIM_BAT"; do
  if [[ ! -f "$f" ]]; then
    echo "generate.sh: required input missing: $f" >&2
    exit 1
  fi
done

# render <template> <shim_file> <template_basename> <channel> <url> -> stdout
render() {
  local template="$1" shim_file="$2" template_name="$3" channel="$4" url="$5" channels="$6"
  CHANNEL="$channel" URL="$url" SHIM_FILE="$shim_file" \
  TEMPLATE_NAME="$template_name" CHANNELS="$channels" \
  awk '
    # Return 1 if channel "ch" is in the comma-separated list "lst".
    function in_channel_list(ch, lst,    n, arr, i) {
      n = split(lst, arr, ",")
      for (i = 1; i <= n; i++) {
        gsub(/[ \t]/, "", arr[i])
        if (arr[i] == ch) return 1
      }
      return 0
    }
    BEGIN {
      channel       = ENVIRON["CHANNEL"]
      url           = ENVIRON["URL"]
      shim_file     = ENVIRON["SHIM_FILE"]
      template_name = ENVIRON["TEMPLATE_NAME"]
      channels      = ENVIRON["CHANNELS"]
      include       = 1
    }
    NR == 1 {
      print
      print "# DO NOT EDIT — generated from templates/" template_name " by templates/generate.sh"
      next
    }
    # Channel-conditional blocks (single source for all channels, but selective
    # output): {{#channels:a,b}} ... {{/channels}} includes the body only for
    # the listed channels; {{^channels:a,b}} ... {{/channels}} includes it only
    # for the others. Blocks must not be nested. The directive lines themselves
    # are never emitted.
    /^[ \t]*\{\{#channels:.*\}\}[ \t]*$/ {
      list = $0
      sub(/^[ \t]*\{\{#channels:/, "", list)
      sub(/\}\}[ \t]*$/, "", list)
      include = in_channel_list(channel, list)
      next
    }
    /^[ \t]*\{\{\^channels:.*\}\}[ \t]*$/ {
      list = $0
      sub(/^[ \t]*\{\{\^channels:/, "", list)
      sub(/\}\}[ \t]*$/, "", list)
      include = in_channel_list(channel, list) ? 0 : 1
      next
    }
    /^[ \t]*\{\{\/channels\}\}[ \t]*$/ {
      include = 1
      next
    }
    include == 0 { next }
    $0 == "{{SHIM}}" {
      # The shim is inlined verbatim except for {{CHANNELS}}, which lets the
      # shim derive its channel list from channels.tsv (single source of truth).
      while ((getline line < shim_file) > 0) {
        gsub(/\{\{CHANNELS\}\}/, channels, line)
        print line
      }
      close(shim_file)
      next
    }
    {
      gsub(/\{\{CHANNEL\}\}/, channel)
      gsub(/\{\{UPDATE_INFO_URL\}\}/, url)
      gsub(/\{\{CHANNELS\}\}/, channels)
      print
    }
  ' "$template"
}

# output_basename <shell> <channel> -> filename
output_basename() {
  local shell="$1" channel="$2"
  if [[ "$channel" == "release" ]]; then
    echo "install.$shell"
  else
    echo "install-$channel.$shell"
  fi
}

# Parse channels.tsv into two parallel arrays.
channel_names=()
channel_urls=()
while IFS=$'\t' read -r name url _rest; do
  # Strip a possible trailing CR (defensive).
  name="${name%$'\r'}"
  url="${url%$'\r'}"
  # Skip blanks and comments.
  [[ -z "${name:-}" ]] && continue
  [[ "${name:0:1}" == "#" ]] && continue
  if [[ -z "${url:-}" ]]; then
    echo "generate.sh: malformed channels.tsv row (missing URL): $name" >&2
    exit 1
  fi
  channel_names+=("$name")
  channel_urls+=("$url")
done < "$CHANNELS_FILE"

if [[ ${#channel_names[@]} -eq 0 ]]; then
  echo "generate.sh: no channels parsed from $CHANNELS_FILE" >&2
  exit 1
fi

# Space-separated channel list injected into the shims as {{CHANNELS}} so the
# channel set has a single source of truth (channels.tsv).
channels_list="${channel_names[*]}"

# Workspace for rendered output (always used; in --check mode this is the
# comparison source, in write mode files are mv'd into place).
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

any_diff=0

for i in "${!channel_names[@]}"; do
  channel="${channel_names[$i]}"
  url="${channel_urls[$i]}"

  for spec in "sh|$TPL_SH|$SHIM_SH|install.sh.template" \
              "ps1|$TPL_PS1|$SHIM_BAT|install.ps1.template"; do
    IFS='|' read -r shell template shim template_name <<<"$spec"
    out_name="$(output_basename "$shell" "$channel")"
    out_path="$WORK_DIR/$out_name"

    render "$template" "$shim" "$template_name" "$channel" "$url" "$channels_list" > "$out_path"

    # Detect any unresolved placeholders.
    if LC_ALL=C grep -nE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$out_path" >/dev/null; then
      echo "generate.sh: unresolved placeholder(s) in $out_name:" >&2
      LC_ALL=C grep -nE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$out_path" >&2 || true
      exit 1
    fi

    final_path="$REPO_ROOT/$out_name"

    if [[ "$MODE" == "check" ]]; then
      if [[ ! -f "$final_path" ]]; then
        echo "generate.sh: missing $out_name in repo root" >&2
        any_diff=1
        continue
      fi
      if ! diff -u "$final_path" "$out_path" >/dev/null; then
        echo "==> $out_name differs:"
        diff -u "$final_path" "$out_path" || true
        any_diff=1
      fi
    else
      mv "$out_path" "$final_path"
      echo "wrote $out_name"
    fi
  done
done

if [[ "$MODE" == "check" ]]; then
  if [[ "$any_diff" -ne 0 ]]; then
    echo "generate.sh: working tree is out of date — run ./templates/generate.sh" >&2
    exit 1
  fi
  echo "generate.sh: all installer scripts are up to date."
fi
