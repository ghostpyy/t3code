#!/usr/bin/env bash

set -euo pipefail

RELEASE_REPO="${T3CODE_RELEASE_REPO:-pingdotgg/t3code}"
UPSTREAM_URL="${T3CODE_UPSTREAM_URL:-https://github.com/${RELEASE_REPO}.git}"
UPSTREAM_BRANCH="${T3CODE_UPSTREAM_BRANCH:-main}"
UPSTREAM_DIR="${T3CODE_UPSTREAM_DIR:-$HOME/Library/Caches/t3code/upstream-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNC_ONLY=0
YES=0
NO_LAUNCH=0

say() {
  printf '\033[1;36m[upstream]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  scripts/install-upstream-source.sh [--yes]
  scripts/install-upstream-source.sh --sync-only

Fetches a clean upstream checkout into a dedicated cache directory, updates it
to the latest branch tip, installs dependencies, and optionally builds +
installs the app from that checkout.

Options:
  --branch NAME   Upstream branch to track. Default: $UPSTREAM_BRANCH
  --dir DIR       Cache directory for the synced checkout. Default: $UPSTREAM_DIR
  --repo SLUG     GitHub repo slug. Default: $RELEASE_REPO
  --sync-only     Only update the cached checkout and install dependencies.
  --no-launch     Do not launch the app after installing it.
  --yes           Skip installer overwrite confirmation.
  --help          Show this help text.

Environment overrides:
  T3CODE_RELEASE_REPO
  T3CODE_UPSTREAM_URL
  T3CODE_UPSTREAM_BRANCH
  T3CODE_UPSTREAM_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      [[ $# -ge 2 ]] || die "--branch requires a value"
      UPSTREAM_BRANCH="$2"
      shift
      ;;
    --dir)
      [[ $# -ge 2 ]] || die "--dir requires a value"
      UPSTREAM_DIR="$2"
      shift
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      RELEASE_REPO="$2"
      UPSTREAM_URL="https://github.com/${RELEASE_REPO}.git"
      shift
      ;;
    --sync-only)
      SYNC_ONLY=1
      ;;
    --no-launch)
      NO_LAUNCH=1
      ;;
    --yes)
      YES=1
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

command -v git >/dev/null 2>&1 || die "Git is required."
command -v bun >/dev/null 2>&1 || die "Bun is required."

mkdir -p "$(dirname "$UPSTREAM_DIR")"

if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
  say "Cloning ${RELEASE_REPO} into $UPSTREAM_DIR"
  git clone --branch "$UPSTREAM_BRANCH" --single-branch "$UPSTREAM_URL" "$UPSTREAM_DIR"
fi

say "Fetching ${RELEASE_REPO} (${UPSTREAM_BRANCH})"
git -C "$UPSTREAM_DIR" remote set-url origin "$UPSTREAM_URL"
git -C "$UPSTREAM_DIR" fetch origin --prune
git -C "$UPSTREAM_DIR" checkout -B "$UPSTREAM_BRANCH" "origin/$UPSTREAM_BRANCH"
git -C "$UPSTREAM_DIR" reset --hard "origin/$UPSTREAM_BRANCH"
git -C "$UPSTREAM_DIR" clean -fd

say "Installing dependencies in cached upstream checkout"
(cd "$UPSTREAM_DIR" && bun install)

commit="$(git -C "$UPSTREAM_DIR" rev-parse --short HEAD)"
date="$(git -C "$UPSTREAM_DIR" log -1 --format=%cs)"
say "Synced upstream checkout to ${commit} (${date})"

if [[ "$SYNC_ONLY" -eq 1 ]]; then
  exit 0
fi

install_args=(--build-current)
if [[ "$YES" -eq 1 ]]; then
  install_args+=(--yes)
fi
if [[ "$NO_LAUNCH" -eq 1 ]]; then
  install_args+=(--no-launch)
fi

T3CODE_REPO_ROOT="$UPSTREAM_DIR" bash "$REPO_ROOT/scripts/install-local-dmg.sh" "${install_args[@]}"
