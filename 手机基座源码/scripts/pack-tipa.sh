#!/bin/bash
# Pack unsigned .app → tipa. Version patch auto-increments (+1) unless
# VERSION is set with BUMP=0. Removes older 云控 tipa packages in OUT_DIR.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
OUT_DIR="${1:-$REPO/手机基座}"
VERSION_FILE="$ROOT/VERSION"
APP_NAME="IOSYunKongBase"
DERIVED="${DERIVED_DATA:-$ROOT/build}"
PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"
APP="$PRODUCTS/${APP_NAME}.app"
PREFIX="IOS云控基座-TVH4-IOHID"

bump_patch() {
  local cur="$1"
  local major minor patch
  IFS=. read -r major minor patch <<<"$cur"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  patch=$((patch + 1))
  echo "${major}.${minor}.${patch}"
}

# Resolve version: BUMP=0 + VERSION → use as-is; else bump VERSION file (default 0.2.1).
if [[ -n "${VERSION:-}" && "${BUMP:-1}" == "0" ]]; then
  NEW_VERSION="$VERSION"
else
  CUR="$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null || true)"
  [[ -z "$CUR" ]] && CUR="0.2.1"
  if [[ -n "${VERSION:-}" ]]; then
    NEW_VERSION="$VERSION"
  else
    NEW_VERSION="$(bump_patch "$CUR")"
  fi
fi
echo "$NEW_VERSION" >"$VERSION_FILE"
VERSION="$NEW_VERSION"
# Keep Xcode marketing version in sync when project.yml is present.
if [[ -f "$ROOT/project.yml" ]]; then
  sed -i.bak -E "s/(MARKETING_VERSION: )\"[0-9.]+\"/\1\"${VERSION}\"/" "$ROOT/project.yml" || true
  rm -f "$ROOT/project.yml.bak"
fi

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
  echo "error: missing app bundle: $APP" >&2
  exit 1
fi

mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"

APP_IN_STAGE="$STAGE/Payload/${APP_NAME}.app"
rm -rf "$APP_IN_STAGE/_CodeSignature" || true
rm -f "$APP_IN_STAGE/embedded.mobileprovision" || true

if command -v ldid >/dev/null 2>&1; then
  ldid -S"$ROOT/App/App.entitlements" "$APP_IN_STAGE/${APP_NAME}"
  if [[ -d "$APP_IN_STAGE/PlugIns/Broadcast.appex" ]]; then
    rm -rf "$APP_IN_STAGE/PlugIns/Broadcast.appex/_CodeSignature" || true
    ldid -S"$ROOT/Extension/Extension.entitlements" "$APP_IN_STAGE/PlugIns/Broadcast.appex/Broadcast"
  fi
else
  echo "warning: ldid not found; tipa may not install on TrollStore" >&2
fi

TIPA="$OUT_DIR/${PREFIX}-${VERSION}.tipa"
(
  cd "$STAGE"
  rm -f "$TIPA"
  zip -qry "$TIPA" Payload
)

# Drop previous 云控 tipa builds + download staging dirs; keep the new file.
shopt -s nullglob
for f in "$OUT_DIR"/${PREFIX}-*.tipa "$OUT_DIR"/IOS云控基座.tipa; do
  [[ -e "$f" ]] || continue
  if [[ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" != "$(cd "$(dirname "$TIPA")" && pwd)/$(basename "$TIPA")" ]]; then
    echo "remove old $(basename "$f")"
    rm -f "$f"
  fi
done
for d in "$OUT_DIR"/tipa-*; do
  [[ -d "$d" ]] || continue
  echo "remove staging $(basename "$d")"
  rm -rf "$d"
done
shopt -u nullglob

# Expose for CI (GITHUB_OUTPUT / callers).
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=${VERSION}" >>"$GITHUB_OUTPUT"
  echo "tipa=${TIPA}" >>"$GITHUB_OUTPUT"
fi
echo "VERSION=${VERSION}"
echo "wrote $TIPA"
ls -la "$TIPA"
