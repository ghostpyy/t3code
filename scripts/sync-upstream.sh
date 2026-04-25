#!/usr/bin/env bash
set -euo pipefail

# Sync this fork with pingdotgg/t3code while keeping every fork commit
# intact (sim-bridge, sim-pane, ax-stamp, chat UI polish, …).
#
# Strategy: MERGE, not rebase.
#   * Fork commits keep their original SHAs forever.
#   * origin/main is append-only — no force-push, external refs stay valid.
#   * Conflicts are resolved once per merge and pinned in the merge commit.
#
# Flow:
#   1. Stash any work-in-progress.
#   2. Fetch upstream.
#   3. git merge --no-ff upstream/main (conflict => bail with instructions).
#   4. Restore WIP.
#   5. Reinstall deps (--ignore-scripts to dodge the effect-language-service
#      post-install patch race).
#   6. typecheck + lint.
#
# Usage: bash scripts/sync-upstream.sh [--dry-run]

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

require_remote() {
  if ! git remote get-url "$1" >/dev/null 2>&1; then
    echo "remote '$1' missing. add it: git remote add $1 $2" >&2
    exit 1
  fi
}

require_remote upstream "https://github.com/pingdotgg/t3code.git"
require_remote origin   "https://github.com/ghostpyy/t3code.git"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "must be on main (currently on $CURRENT_BRANCH)" >&2
  exit 1
fi

WIP_STASH=""
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "stashing WIP..."
  if (( DRY_RUN == 0 )); then
    git stash push -u -m "sync-upstream WIP $(date +%s)"
    WIP_STASH=1
  fi
fi

echo "fetching upstream..."
(( DRY_RUN == 1 )) || git fetch upstream main

UPSTREAM_HEAD="$(git rev-parse upstream/main 2>/dev/null || echo "")"
LOCAL_HEAD="$(git rev-parse HEAD)"
echo "local main : $LOCAL_HEAD"
echo "upstream   : $UPSTREAM_HEAD"

if [[ -z "$UPSTREAM_HEAD" ]]; then
  echo "upstream/main not found, did fetch fail?" >&2
  exit 1
fi

BASE="$(git merge-base HEAD upstream/main)"
if [[ "$BASE" == "$UPSTREAM_HEAD" ]]; then
  echo "already up to date with upstream/main"
else
  BEHIND="$(git rev-list --count "$BASE..$UPSTREAM_HEAD")"
  echo "merging $BEHIND commit(s) from upstream/main..."
  if (( DRY_RUN == 0 )); then
    if ! git merge --no-ff --no-edit \
        -m "chore: merge upstream/main ($BEHIND commit(s))" \
        upstream/main; then
      echo
      echo "merge stopped on conflicts."
      echo "resolve them, then:"
      echo "  git add -A"
      echo "  git commit --no-edit"
      echo "  git push origin main"
      if [[ -n "$WIP_STASH" ]]; then
        echo
        echo "your WIP is stashed; restore with: git stash pop"
      fi
      exit 1
    fi
  fi
fi

if [[ -n "$WIP_STASH" ]]; then
  echo "restoring WIP..."
  git stash pop || echo "stash pop reported conflicts; resolve manually"
fi

echo "reinstalling deps (ignore-scripts to avoid effect-language-service patch glitch)..."
(( DRY_RUN == 1 )) || bun install --ignore-scripts

echo "typechecking..."
(( DRY_RUN == 1 )) || bun typecheck

echo "linting..."
(( DRY_RUN == 1 )) || bun lint

echo
echo "sync complete. push when ready: git push origin main"
