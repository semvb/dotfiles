#!/usr/bin/env bash
#
# deploy.sh — symlink dotfiles from this repo into $HOME, driven by MANIFEST.
#
# Usage:
#   ./deploy.sh                 link everything listed in MANIFEST
#   ./deploy.sh -n              dry run: show what would happen, change nothing
#   ./deploy.sh add <path>      move an existing file/dir into the repo,
#                               add it to MANIFEST and link it back
#
# MANIFEST format (one entry per line, # starts a comment):
#   .zshrc                      repo/.zshrc       -> ~/.zshrc
#   nvim -> .config/nvim        repo/nvim         -> ~/.config/nvim
#
# Existing files at a destination are never deleted: they are moved into
# ~/.dotfiles_backup/<timestamp>/ before the symlink is created.

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$DOTFILES/MANIFEST"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0

info()  { printf '\033[32m[OK]\033[0m    %s\n' "$*"; }
skip()  { printf '\033[90m[SKIP]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m  %s\n' "$*"; }
err()   { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
run()   { if (( DRY_RUN )); then printf '        would run: %s\n' "$*"; else "$@"; fi; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# link <path in repo> <path relative to $HOME>
link() {
    local src="$DOTFILES/$1" dest="$HOME/$2"

    if [[ ! -e "$src" ]]; then
        err "$1 is listed in MANIFEST but does not exist in the repo"
        return
    fi

    # Already pointing at the right place: nothing to do.
    if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
        skip "$dest already linked"
        return
    fi

    # Something else is in the way: back it up instead of deleting it.
    if [[ -e "$dest" || -L "$dest" ]]; then
        local backup="$BACKUP_DIR/$2"
        warn "$dest exists, moving it to $backup"
        run mkdir -p "$(dirname "$backup")"
        run mv "$dest" "$backup"
    fi

    run mkdir -p "$(dirname "$dest")"
    run ln -s "$src" "$dest"
    info "$dest -> $src"
}

deploy() {
    [[ -f "$MANIFEST" ]] || { err "no MANIFEST found at $MANIFEST"; exit 1; }

    local line src dest
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "${line%%#*}")"          # strip comments + whitespace
        [[ -z "$line" ]] && continue

        if [[ "$line" == *"->"* ]]; then
            src="$(trim "${line%%->*}")"
            dest="$(trim "${line#*->}")"
        else
            src="$line"
            dest="$line"
        fi
        dest="${dest#\~/}"                    # allow "~/.config/x" as well

        link "$src" "$dest"
    done < "$MANIFEST"
}

# add <existing path under $HOME>
add() {
    local target="${1:?usage: ./deploy.sh add <path>}"
    target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"

    [[ -e "$target" ]]   || { err "$target does not exist"; exit 1; }
    [[ -L "$target" ]]   && { err "$target is already a symlink"; exit 1; }
    [[ "$target" == "$HOME/"* ]] || { err "$target is not inside \$HOME"; exit 1; }

    local rel="${target#"$HOME/"}"           # e.g. .config/nvim
    local name="$rel"
    # Keep the repo tidy: ~/.config/foo is stored as repo/config/foo
    [[ "$rel" == .config/* ]] && name="config/${rel#.config/}"

    [[ -e "$DOTFILES/$name" ]] && { err "$name already exists in the repo"; exit 1; }

    run mkdir -p "$(dirname "$DOTFILES/$name")"
    run mv "$target" "$DOTFILES/$name"
    if [[ "$name" == "$rel" ]]; then
        run sh -c "printf '%s\n' '$rel' >> '$MANIFEST'"
    else
        run sh -c "printf '%s\n' '$name -> $rel' >> '$MANIFEST'"
    fi
    link "$name" "$rel"
    info "added $rel to the repo — don't forget to commit it"
}

main() {
    if [[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]]; then
        DRY_RUN=1; shift
        echo "Dry run — nothing will be changed."
    fi

    case "${1:-}" in
        add)        shift; add "$@" ;;
        ""|deploy)  deploy ;;
        -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
        *)          err "unknown command: $1"; exit 1 ;;
    esac
}

main "$@"
