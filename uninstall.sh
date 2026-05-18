#!/bin/bash
#
# Junie CLI Uninstaller
#

set -euo pipefail

JUNIE_BIN="$HOME/.local/bin/junie"
JUNIE_DATA="$HOME/.local/share/junie"
FORCE=0
DRY_RUN=0

log() { echo "[Junie] $*"; }
warn() { echo "[Junie] WARNING: $*" >&2; }
log_error() { echo "[Junie] ERROR: $*" >&2; }

usage() {
        cat <<'EOF'
Usage: bash junie-uninstall.sh [--force] [--dry-run]

Options:
  --force    Skip confirmation prompt
  --dry-run  Show what would be removed without changing anything
  --help     Show this help
EOF
}

run() {
        if [[ "$DRY_RUN" -eq 1 ]]; then
                printf '[dry-run] '
                printf '%q ' "$@"
                printf '\n'
        else
                "$@"
        fi
}

safe_path() {
        local path="$1"
        case "$path" in
        "$HOME/.local/bin/"* | "$HOME/.local/share/junie" | "$HOME/.local/share/junie/"*)
                return 0
                ;;
        *)
                return 1
                ;;
        esac
}

remove_file_if_exists() {
        local path="$1"
        if [[ ! -e "$path" && ! -L "$path" ]]; then
                return 0
        fi
        if ! safe_path "$path"; then
                log_error "Refusing to remove unsafe path: $path"
                exit 1        fi
        log "Removing $path"
        run rm -f "$path"
}

remove_dir_if_exists() {
        local path="$1"
        if [[ ! -d "$path" ]]; then
                return 0
        fi
        if ! safe_path "$path"; then
                log_error "Refusing to remove unsafe path: $path"
                exit 1
        fi
        log "Removing $path"
        run rm -rf "$path"
}

remove_dir_if_empty() {
        local path="$1"
        if [[ ! -d "$path" ]]; then
                return 0
        fi
        if ! safe_path "$path"; then
                log_error "Refusing to inspect unsafe path: $path"
                exit 1
        fi
        if [[ -z "$(ls -A "$path" 2>/dev/null)" ]]; then
                log "Removing empty directory $path"
                run rmdir "$path"
        fi
}

remove_line_from_file() {
        local file="$1"
        local exact_line="$2"

                                                                                                                 if [[ ! -f "$file" ]]; then
                return 0
        fi
        if ! grep -Fxq "$exact_line" "$file"; then
                return 0
        fi
        warn "Removing PATH entry from $file"
        if [[ "$DRY_RUN" -eq 1 ]]; then
                printf '[dry-run] remove exact line from %q: %s\n' "$file" "$exact_line"
                return 0                                                                                                                      fi

        local tmp                                                                                                                             tmp=$(mktemp)
        grep -Fxv "$exact_line" "$file" >"$tmp" || true
        mv "$tmp" "$file"
}

detect_profiles() {
        local os shell_name
        os=$(uname -s)
        shell_name=$(basename "${SHELL:-}" 2>/dev/null || echo "")

                                                                            case "$shell_name" in
        zsh)
                printf '%s\n' "$HOME/.zshrc" "$HOME/.zprofile"
                ;;
        bash)
                if [[ "$os" == "Darwin" ]]; then
                        printf '%s\n' "$HOME/.bash_profile" "$HOME/.profile"
                else
                        printf '%s\n' "$HOME/.bashrc" "$HOME/.profile"
                fi
                ;;
        fish)
                printf '%s\n' "$HOME/.config/fish/config.fish"
                ;;
        *)
                printf '%s\n' "$HOME/.profile"
                ;;
        esac
}

confirm() {
        if [[ "$FORCE" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
                return 0
        fi

        echo "This will remove Junie files and PATH entries added by the installer."
        echo "It may affect other tools if you use ~/.local/bin for anything else."
        printf "Continue? [y/N] "
        read -r reply
        case "$reply" in
        y | Y | yes | YES) ;;                                                                                                                 *)
                log "Aborted"
                exit 0
                ;;
        esac
}

main() {
        while [[ $# -gt 0 ]]; do
                case "$1" in
                --force)
                        FORCE=1
                        ;;
                --dry-run)
                        DRY_RUN=1
                        ;;
                --help)
                        usage
                        exit 0
                        ;;
                *)
                        log_error "Unknown option: $1"
                        usage
                        exit 1
                        ;;
                esac
                shift
        done

        confirm

        remove_file_if_exists "$JUNIE_BIN"
        remove_file_if_exists "$JUNIE_DATA/current"
        remove_dir_if_exists "$JUNIE_DATA/versions"
        remove_dir_if_exists "$JUNIE_DATA/updates"
        remove_dir_if_empty "$JUNIE_DATA"
        while IFS= read -r profile; do
                remove_line_from_file "$profile" 'export PATH="$HOME/.local/bin:$PATH"'
                remove_line_from_file "$profile" 'fish_add_path "$HOME/.local/bin"'
        done < <(detect_profiles)

        log "Junie uninstall complete"
}

main "$@"
