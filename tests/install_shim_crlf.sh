#!/usr/bin/env bash
#
# Regression test for JUNIE-3256: the Windows shim (`junie.bat`) must be written
# with CRLF line endings. cmd.exe `goto`/`call` label seeking is unreliable on
# LF-only files (e.g. the forward jump to :after_channel_oneshot), which caused
# "The system cannot find the batch label specified - after_channel_oneshot" on
# launch.
#
# The shim template in this repo is maintained with LF, so each generated
# install*.ps1 MUST normalize $SHIM_CONTENT to CRLF immediately before writing
# it to disk. This test asserts that, for every Windows installer, the CRLF
# normalization appears and precedes the WriteAllText that creates the shim.
#
# Usage:
#   bash tests/install_shim_crlf.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PS1_INSTALLERS=(
  "install.ps1"
  "install-eap.ps1"
  "install-nightly.ps1"
  "install-experimental.ps1"
)

PASS=0
FAIL=0

for name in "${PS1_INSTALLERS[@]}"; do
  f="$REPO_ROOT/$name"
  if [[ ! -f "$f" ]]; then
    echo "FAIL [$name]: installer not found at $f" >&2
    FAIL=$((FAIL + 1))
    continue
  fi

  # Line that normalizes the shim content to CRLF.
  norm_line="$(grep -n 'SHIM_CONTENT = \$SHIM_CONTENT -replace' "$f" | head -1 | cut -d: -f1)"
  # Line that writes the shim to disk.
  write_line="$(grep -n 'WriteAllText(\$SHIM_PATH' "$f" | head -1 | cut -d: -f1)"

  if [[ -z "$norm_line" ]]; then
    echo "FAIL [$name]: missing CRLF normalization of \$SHIM_CONTENT before writing the shim" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  if [[ -z "$write_line" ]]; then
    echo "FAIL [$name]: could not find shim WriteAllText(\$SHIM_PATH ...) call" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  if [[ "$norm_line" -ge "$write_line" ]]; then
    echo "FAIL [$name]: CRLF normalization (line $norm_line) must precede shim write (line $write_line)" >&2
    FAIL=$((FAIL + 1))
    continue
  fi

  echo "PASS [$name]"
  PASS=$((PASS + 1))
done

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
