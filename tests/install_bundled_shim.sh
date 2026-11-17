#!/usr/bin/env bash
#
# Regression test: Unix installers must install the package's own
# versions/<v>/shim/junie.sh byte-for-byte, and fall back to the embedded
# shim only for packages without a bundled one. The installed shim must be
# executable either way.
#
# Usage:
#   bash tests/install_bundled_shim.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

INSTALLERS=(
  "install.sh"
  "install-eap.sh"
  "install-nightly.sh"
  "install-experimental.sh"
)

PASS=0
FAIL=0

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

for name in "${INSTALLERS[@]}"; do
  installer="$REPO_ROOT/$name"

  # The embedded shim contains its own top-level `}` lines, so the function
  # ends at the first `}` after the heredoc terminator.
  function_src="$(awk '
    /^install_shim\(\) \{$/ { found = 1 }
    found { print }
    found && /^SHIM_EOF$/ { heredoc_done = 1 }
    found && heredoc_done && /^}$/ { exit }
  ' "$installer")"
  if [[ -z "$function_src" ]]; then
    echo "FAIL [$name]: install_shim function not found" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  unset -f install_shim
  eval "$function_src"

  case_dir="$WORK_ROOT/${name%.sh}"
  version_dir="$case_dir/versions/1.1"
  shim_path="$case_dir/bin/junie"
  mkdir -p "$version_dir/shim" "$(dirname "$shim_path")"
  printf 'stale shim\n' > "$shim_path"

  printf '#!/usr/bin/env bash\n# JUNIE_MANAGED_SHIM\n# bundled %s\n' "$name" > "$version_dir/shim/junie.sh"
  install_shim "$version_dir" "$shim_path"
  if ! cmp -s "$version_dir/shim/junie.sh" "$shim_path"; then
    echo "FAIL [$name]: bundled shim was not installed byte-for-byte" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  if [[ ! -x "$shim_path" ]]; then
    echo "FAIL [$name]: bundled shim is not executable after install" >&2
    FAIL=$((FAIL + 1))
    continue
  fi

  rm -f "$version_dir/shim/junie.sh"
  printf 'stale shim\n' > "$shim_path"
  chmod -x "$shim_path"
  install_shim "$version_dir" "$shim_path"
  if ! grep -q 'JUNIE_MANAGED_SHIM' "$shim_path" || grep -q "bundled $name" "$shim_path"; then
    echo "FAIL [$name]: fallback did not install the embedded managed shim" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  if [[ ! -x "$shim_path" ]]; then
    echo "FAIL [$name]: fallback shim is not executable after install" >&2
    FAIL=$((FAIL + 1))
    continue
  fi

  echo "PASS [$name]"
  PASS=$((PASS + 1))
done

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
