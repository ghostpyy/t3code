#!/usr/bin/env bash

set -euo pipefail

if [[ "${OSTYPE:-}" != darwin* ]]; then
  printf '[fail] scripts/deep-clean.sh currently supports macOS only.\n' >&2
  exit 1
fi

APP_NAME="${T3CODE_APP_NAME:-T3 Code (Alpha).app}"
APP_PATH="${T3CODE_APP_PATH:-/Applications/${APP_NAME}}"
BUNDLE_ID="${T3CODE_BUNDLE_ID:-com.t3tools.t3code}"
DOWNLOAD_CACHE_DIR="${T3CODE_DOWNLOAD_CACHE_DIR:-$HOME/Downloads/t3code-installer}"
DRY_RUN=0
YES=0

say() {
  printf '\033[1;36m[clean]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: scripts/deep-clean.sh [--yes] [--dry-run]

Removes the installed T3 Code macOS app, its user data, caches, update residue,
temporary files, and the default installer download cache.

Options:
  --yes       Skip the confirmation prompt.
  --dry-run   Print what would be removed without changing anything.
  --help      Show this help text.

Environment overrides:
  T3CODE_APP_NAME
  T3CODE_APP_PATH
  T3CODE_BUNDLE_ID
  T3CODE_DOWNLOAD_CACHE_DIR
EOF
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi

  "$@"
}

remove_path() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  say "Removing $path"
  run rm -rf -- "$path"
}

cleanup_temp_matches() {
  local root="$1"
  [[ -d "$root" ]] || return 0

  while IFS= read -r -d '' match; do
    remove_path "$match"
  done < <(
    find "$root" -maxdepth 2 \
      \( -name 't3code*' -o -name 'T3-Code*' -o -name 'SimBridge*' \) \
      -print0 2>/dev/null
  )
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      YES=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "$YES" -ne 1 && "$DRY_RUN" -ne 1 ]]; then
  printf 'Delete the installed app, caches, temp files, and installer cache for T3 Code? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      say "Cancelled."
      exit 0
      ;;
  esac
fi

say "Stopping running T3 Code processes..."
for pattern in "T3 Code" "SimBridge" "$BUNDLE_ID" "ShipIt"; do
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    run pkill -9 -f "$pattern" || true
  fi
done
sleep 1

if [[ -d "$APP_PATH" ]]; then
  say "Unregistering $APP_PATH from LaunchServices"
  run /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP_PATH" || true
fi

shopt -s nullglob

paths=(
  "$APP_PATH"
  "$DOWNLOAD_CACHE_DIR"
  "$HOME/Library/Application Support/$BUNDLE_ID"
  "$HOME/Library/Application Support/t3code"
  "$HOME/Library/Application Support/T3 Code"
  "$HOME/Library/Application Support/T3 Code (Alpha)"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/Caches/$BUNDLE_ID.ShipIt"
  "$HOME/Library/Caches/${BUNDLE_ID}.ShipIt"
  "$HOME/Library/Caches/T3 Code"
  "$HOME/Library/Caches/T3 Code (Alpha)"
  "$HOME/Library/Cookies/$BUNDLE_ID.binarycookies"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/${BUNDLE_ID}.binarycookies"
  "$HOME/Library/Logs/$BUNDLE_ID"
  "$HOME/Library/Logs/T3 Code"
  "$HOME/Library/Logs/T3 Code (Alpha)"
  "$HOME/Library/Logs/t3code"
  "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
  "$HOME/Library/Preferences/${BUNDLE_ID}.helper.plist"
  "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
  "$HOME/Library/WebKit/$BUNDLE_ID"
)

for byhost in "$HOME/Library/Preferences/ByHost/${BUNDLE_ID}."*; do
  paths+=("$byhost")
done

for path in "${paths[@]}"; do
  remove_path "$path"
done

cleanup_temp_matches "/tmp"
cleanup_temp_matches "${TMPDIR:-/tmp}"

say "Deep clean complete."
