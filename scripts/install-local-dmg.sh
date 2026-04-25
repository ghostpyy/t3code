#!/usr/bin/env bash

set -euo pipefail

if [[ "${OSTYPE:-}" != darwin* ]]; then
  printf '[fail] scripts/install-local-dmg.sh currently supports macOS only.\n' >&2
  exit 1
fi

RELEASE_REPO="${T3CODE_RELEASE_REPO:-pingdotgg/t3code}"
INSTALL_DIR="${T3CODE_INSTALL_DIR:-/Applications}"
DOWNLOAD_DIR="${T3CODE_DOWNLOAD_DIR:-$HOME/Downloads/t3code-installer}"
REPO_ROOT="${T3CODE_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOCAL_BUILD_OUTPUT_DIR=""
ARCH_OVERRIDE=""
ASSET_OVERRIDE=""
TAG_OVERRIDE=""
DMG_PATH=""
INSTALL_LATEST=0
BUILD_CURRENT=0
SKIP_LOCAL_BUILD=0
KEEP_DMG=0
LAUNCH_AFTER_INSTALL=1
YES=0
DOWNLOADED_DMG=0
MOUNT_POINT=""
TEMP_DIR=""
RELEASE_JSON=""

say() {
  printf '\033[1;36m[install]\033[0m %s\n' "$*"
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
Usage:
  scripts/install-local-dmg.sh /path/to/T3-Code.dmg [--yes]
  scripts/install-local-dmg.sh --build-current [--yes]
  scripts/install-local-dmg.sh --latest-release [--tag <release-tag>] [--yes]

Installs a T3 Code macOS build from a local DMG, builds and installs the
current checkout, or downloads and installs the latest published GitHub
release DMG.

Options:
  --build-current      Build a DMG from the current repo checkout and install it.
  --skip-build         With --build-current, reuse an existing local build output dir.
  --build-output-dir   With --build-current, output directory for the generated artifacts.
  --latest-release     Download and install the latest published release.
  --latest             Alias for --latest-release.
  --tag TAG            Install a specific GitHub release tag instead of the latest.
  --repo OWNER/REPO    GitHub repo to install from. Default: $RELEASE_REPO
  --arch arm64|x64     Override DMG architecture selection for build/release install.
  --asset NAME         Explicit DMG asset name to download for --latest-release.
  --download-dir DIR   Download directory for --latest-release. Default: $DOWNLOAD_DIR
  --keep-dmg           Keep the downloaded DMG after install.
  --no-launch          Do not launch the app after install.
  --yes                Skip confirmation before overwriting an existing app.
  --help               Show this help text.

Environment overrides:
  T3CODE_RELEASE_REPO
  T3CODE_INSTALL_DIR
  T3CODE_DOWNLOAD_DIR
  T3CODE_REPO_ROOT
EOF
}

cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  if [[ "$DOWNLOADED_DMG" -eq 1 && "$KEEP_DMG" -ne 1 && -n "$DMG_PATH" && -f "$DMG_PATH" ]]; then
    rm -f -- "$DMG_PATH" || true
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR" || true
  fi
}

trap cleanup EXIT

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

fetch_release_json() {
  local tag="$1"
  if ! command_exists gh; then
    die "GitHub CLI ('gh') is required for --latest installs."
  fi

  if [[ -n "$tag" ]]; then
    gh release view "$tag" --repo "$RELEASE_REPO" --json tagName,name,publishedAt,assets
  else
    gh release view --repo "$RELEASE_REPO" --json tagName,name,publishedAt,assets
  fi
}

build_current_dmg() {
  local arch_suffix="$1"
  if ! command_exists bun; then
    die "Bun is required to build the current checkout."
  fi

  local build_output_dir="$LOCAL_BUILD_OUTPUT_DIR"
  if [[ -z "$build_output_dir" ]]; then
    TEMP_DIR="$(mktemp -d -t t3code-local-build.XXXXXX)"
    build_output_dir="$TEMP_DIR/release"
  fi

  mkdir -p "$build_output_dir"

  say "Building current checkout at $REPO_ROOT (arch=$arch_suffix)"
  (
    cd "$REPO_ROOT"
    if [[ "$SKIP_LOCAL_BUILD" -eq 1 ]]; then
      node scripts/build-desktop-artifact.ts --platform mac --target dmg --arch "$arch_suffix" --output-dir "$build_output_dir" --skip-build
    else
      node scripts/build-desktop-artifact.ts --platform mac --target dmg --arch "$arch_suffix" --output-dir "$build_output_dir"
    fi
  )

  DMG_PATH="$(
    find "$build_output_dir" -maxdepth 1 -type f -name "T3-Code-*.dmg" -print \
      | LC_ALL=C sort \
      | tail -n 1
  )"
  [[ -n "$DMG_PATH" && -f "$DMG_PATH" ]] || die "No DMG artifact was produced in $build_output_dir"
}

resolve_arch_suffix() {
  local arch="${ARCH_OVERRIDE:-$(uname -m)}"
  case "$arch" in
    arm64|aarch64)
      printf 'arm64'
      ;;
    x86_64|amd64|x64)
      printf 'x64'
      ;;
    *)
      die "Unsupported architecture: $arch"
      ;;
  esac
}

python_read_release_field() {
  local mode="$1"
  local suffix="$2"
  RELEASE_JSON="$RELEASE_JSON" python3 - "$mode" "$suffix" <<'PY'
import json
import os
import sys

mode = sys.argv[1]
suffix = sys.argv[2]
payload = json.loads(os.environ["RELEASE_JSON"])
assets = payload.get("assets", [])

match = None
for asset in assets:
    name = asset.get("name", "")
    if name.endswith(f"-{suffix}.dmg"):
        match = asset
        break

if mode == "tag":
    print(payload.get("tagName", ""))
elif mode == "asset-name":
    print("" if match is None else match.get("name", ""))
elif mode == "asset-digest":
    print("" if match is None else match.get("digest", ""))
elif mode == "published-at":
    print(payload.get("publishedAt", ""))
else:
    raise SystemExit(f"unknown mode: {mode}")
PY
}

verify_sha256_if_present() {
  local path="$1"
  local digest="$2"
  [[ "$digest" == sha256:* ]] || return 0
  local expected="${digest#sha256:}"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "Checksum mismatch for $(basename "$path")"
}

mount_dmg() {
  local dmg="$1"
  MOUNT_POINT="$(
    hdiutil attach "$dmg" -nobrowse -readonly -plist | python3 -c '
import plistlib
import sys

payload = plistlib.loads(sys.stdin.buffer.read())
for entity in payload.get("system-entities", []):
    mount_point = entity.get("mount-point")
    if mount_point:
        print(mount_point)
        break
'
  )"
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || die "Unable to mount $dmg"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest)
      INSTALL_LATEST=1
      ;;
    --latest-release)
      INSTALL_LATEST=1
      ;;
    --build-current)
      BUILD_CURRENT=1
      ;;
    --skip-build)
      SKIP_LOCAL_BUILD=1
      ;;
    --build-output-dir)
      [[ $# -ge 2 ]] || die "--build-output-dir requires a value"
      LOCAL_BUILD_OUTPUT_DIR="$2"
      shift
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      TAG_OVERRIDE="$2"
      shift
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      RELEASE_REPO="$2"
      shift
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      ARCH_OVERRIDE="$2"
      shift
      ;;
    --asset)
      [[ $# -ge 2 ]] || die "--asset requires a value"
      ASSET_OVERRIDE="$2"
      shift
      ;;
    --download-dir)
      [[ $# -ge 2 ]] || die "--download-dir requires a value"
      DOWNLOAD_DIR="$2"
      shift
      ;;
    --keep-dmg)
      KEEP_DMG=1
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL=0
      ;;
    --yes)
      YES=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      die "Unknown argument: $1"
      ;;
    *)
      [[ -z "$DMG_PATH" ]] || die "Only one DMG path may be provided"
      DMG_PATH="$1"
      ;;
  esac
  shift
done

mode_count=$(( INSTALL_LATEST + BUILD_CURRENT ))
if [[ "$mode_count" -gt 1 ]]; then
  die "Choose only one install source: local DMG, --build-current, or --latest-release"
fi

if [[ "$BUILD_CURRENT" -eq 0 && "$INSTALL_LATEST" -eq 0 && -z "$DMG_PATH" ]]; then
  die "Provide a local DMG path or use --build-current / --latest-release"
fi

local_arch_suffix="$(resolve_arch_suffix)"

if [[ "$BUILD_CURRENT" -eq 1 ]]; then
  build_current_dmg "$local_arch_suffix"
elif [[ "$INSTALL_LATEST" -eq 1 ]]; then
  RELEASE_JSON="$(fetch_release_json "$TAG_OVERRIDE")"
  resolved_tag="$(python_read_release_field tag "$local_arch_suffix")"
  resolved_date="$(python_read_release_field published-at "$local_arch_suffix")"
  asset_name="${ASSET_OVERRIDE:-$(python_read_release_field asset-name "$local_arch_suffix")}"
  digest="$(python_read_release_field asset-digest "$local_arch_suffix")"
  [[ -n "$asset_name" ]] || die "No DMG asset found for architecture $local_arch_suffix in $RELEASE_REPO"

  mkdir -p "$DOWNLOAD_DIR"
  DMG_PATH="$DOWNLOAD_DIR/$asset_name"
  say "Downloading $asset_name from $RELEASE_REPO (${resolved_tag}, published $resolved_date)"
  gh release download "$resolved_tag" --repo "$RELEASE_REPO" --pattern "$asset_name" --dir "$DOWNLOAD_DIR" --clobber
  DOWNLOADED_DMG=1
  verify_sha256_if_present "$DMG_PATH" "$digest"
else
  [[ -f "$DMG_PATH" ]] || die "DMG not found: $DMG_PATH"
fi

mount_dmg "$DMG_PATH"
SRC_APP="$(find "$MOUNT_POINT" -maxdepth 2 -type d -name '*.app' -print | head -n 1)"
[[ -n "$SRC_APP" ]] || die "No .app bundle found in $DMG_PATH"

DEST_APP="$INSTALL_DIR/$(basename "$SRC_APP")"
if [[ -d "$DEST_APP" && "$YES" -ne 1 ]]; then
  printf 'Replace existing app at %s? [y/N] ' "$DEST_APP"
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

if [[ -d "$DEST_APP" ]]; then
  say "Removing existing app at $DEST_APP"
  rm -rf -- "$DEST_APP"
fi

say "Installing $(basename "$SRC_APP") to $INSTALL_DIR"
ditto "$SRC_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_APP" >/dev/null 2>&1 || true

INSTALLED_VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST_APP/Contents/Info.plist" 2>/dev/null || true
)"
say "Installed $DEST_APP${INSTALLED_VERSION:+ (version $INSTALLED_VERSION)}"

if [[ "$LAUNCH_AFTER_INSTALL" -eq 1 ]]; then
  say "Launching $(basename "$DEST_APP")"
  open -n "$DEST_APP"
fi
