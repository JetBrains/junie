#!/bin/bash
#
# Regression test: the local model installer must recognise an AMD or Intel card
# from the Linux graphics device tree and pick the engine package published for
# the detected GPU vendor, so adding such a package never changes what NVIDIA
# machines download.
#
# Usage:
#   bash tests/local_gpu_hardware.sh

set -uo pipefail

REPO_ROOT="$(dirname "$(cd "$(dirname "$0")" && pwd)")"
INSTALLER="$REPO_ROOT/local/install.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() {
  if [ "$2" = "$3" ]; then
    echo "PASS $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL $1: expected [$3], got [$2]" >&2
    FAIL=$((FAIL + 1))
  fi
}

# One fake card: vendor id, dedicated VRAM in bytes, PCI device id.
add_card() {
  mkdir -p "$WORK/drm/$1/device"
  echo "$2" > "$WORK/drm/$1/device/vendor"
  echo "$3" > "$WORK/drm/$1/device/mem_info_vram_total"
  echo "$4" > "$WORK/drm/$1/device/device"
}

# One fake Intel card: the size of its memory window in bytes, PCI device id.
# The xe driver has no VRAM file; the installer reads the size of "resource2".
add_intel_card() {
  mkdir -p "$WORK/drm/$1/device"
  echo 0x8086 > "$WORK/drm/$1/device/vendor"
  echo "$3" > "$WORK/drm/$1/device/device"
  dd if=/dev/zero of="$WORK/drm/$1/device/resource2" bs=1 count=0 seek="$2" 2>/dev/null
}

cat > "$WORK/feed.jsonl" <<'FEED'
{"version":"1.0","platform":"linux-amd64","hardware":"NVIDIA GPU","downloadUrl":"https://example.com/nvidia-1.0.tar.gz","sha256":"aa"}
{"version":"1.1","platform":"linux-amd64","hardware":"NVIDIA GPU","downloadUrl":"https://example.com/nvidia-1.1.tar.gz","sha256":"bb"}
{"version":"1.1","platform":"linux-amd64","hardware":"AMD GPU","downloadUrl":"https://example.com/amd-1.1.tar.gz","sha256":"cc"}
{"version":"1.1","platform":"linux-amd64","hardware":"Intel GPU","downloadUrl":"https://example.com/intel-1.1.tar.gz","sha256":"dd"}
FEED

# Run the installer's own detection and engine selection with stubbed tools.
# $1 says what nvidia-smi does: "nvidia" names a card, "broken" fails the way a
# driver left without its card does, anything else means the tool is missing.
# The result is "<hardware>|<engine URL>".
select_engine() {
  mkdir -p "$WORK/bin"
  rm -f "$WORK/bin/nvidia-smi"
  if [ "$1" = "nvidia" ]; then
    printf '#!/bin/sh\necho "NVIDIA GeForce RTX 3090"\n' > "$WORK/bin/nvidia-smi"
  elif [ "$1" = "broken" ]; then
    printf '#!/bin/sh\necho "NVIDIA-SMI has failed"\nexit 9\n' > "$WORK/bin/nvidia-smi"
  fi
  [ -f "$WORK/bin/nvidia-smi" ] && chmod +x "$WORK/bin/nvidia-smi"
  printf '#!/bin/sh\ncat "%s"\n' "$WORK/feed.jsonl" > "$WORK/bin/curl"
  chmod +x "$WORK/bin/curl"
  {
    echo 'OS_TYPE=linux; PLATFORM=linux-amd64; CHANNEL=main; RED=; RESET='
    echo "JUNIE_LOCAL_DRM_ROOT='$WORK/drm'; ENGINE_UPDATE_URL=unused"
    sed -n '/^get_json_field() {/,/^}/p' "$INSTALLER"
    sed -n '/^DRM_ROOT=/,/^# Inference engine release/p' "$INSTALLER"
    echo 'fetch_engine_config; printf "%s|%s" "$(detect_gpu_hardware)" "$ENGINE_URL"'
  } > "$WORK/probe.sh"
  PATH="$WORK/bin:/usr/bin:/bin" sh "$WORK/probe.sh" 2>&1
}

# An integrated Radeon with 2 GiB and a discrete Radeon RX 7900 XTX.
add_card card0 0x1002 2147483648 0x13c0
add_card card1 0x1002 25753026560 0x744c
mkdir -p "$WORK/drm/card1-DP-1"

check "AMD card gets the AMD package" "$(select_engine none)" "AMD GPU|https://example.com/amd-1.1.tar.gz"
check "NVIDIA card keeps the NVIDIA package" "$(select_engine nvidia)" "NVIDIA GPU|https://example.com/nvidia-1.1.tar.gz"
check "a failing nvidia-smi does not hide the AMD card" "$(select_engine broken)" "AMD GPU|https://example.com/amd-1.1.tar.gz"

# An Arc Pro B65 beside the integrated Radeon of the processor.
rm -rf "$WORK/drm"
add_card card0 0x1002 2147483648 0x13c0
add_intel_card card1 34359738368 0xe222
check "Intel card beside AMD integrated graphics gets the Intel package" "$(select_engine none)" "Intel GPU|https://example.com/intel-1.1.tar.gz"

# Integrated graphics alone: an Intel one with a 256 MiB window, an AMD one with 2 GiB.
rm -rf "$WORK/drm"
add_intel_card card0 268435456 0x7d55
add_card card1 0x1002 2147483648 0x13c0
check "integrated graphics fall back to the NVIDIA package" "$(select_engine none)" "NVIDIA GPU|https://example.com/nvidia-1.1.tar.gz"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
