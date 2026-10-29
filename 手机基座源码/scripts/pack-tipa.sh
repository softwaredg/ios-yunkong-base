#!/bin/bash
# Pack unsigned .app → tipa. Uses 手机基座源码/VERSION (already bumped by bump-version.sh).
# Stamps CFBundleShortVersionString into Info.plist so UI matches the tipa filename.
# Removes older 云控 tipa packages in OUT_DIR.
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

VERSION="$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  echo "error: missing $VERSION_FILE — run scripts/bump-version.sh first" >&2
  exit 1
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

# Force marketing version inside the tipa (guards against build/pack ordering bugs).
PLIST="$APP_IN_STAGE/Info.plist"
if [[ -f "$PLIST" ]]; then
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${VERSION}" "$PLIST" || true
  elif command -v plutil >/dev/null 2>&1; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
    plutil -replace CFBundleVersion -string "$VERSION" "$PLIST" || true
  fi
  echo "stamped Info.plist CFBundleShortVersionString=${VERSION}"
fi

if ! command -v ldid >/dev/null 2>&1; then
  echo "error: ldid required — tipa without private entitlements falls to 前台快照" >&2
  exit 1
fi
# ldid 2.x silently embeds <dict/> if the entitlements plist has XML comments.
if grep -q '<!--' "$ROOT/App/App.entitlements"; then
  echo "error: App.entitlements has XML comments — ldid will embed empty entitlements" >&2
  exit 1
fi
ldid -S"$ROOT/App/App.entitlements" "$APP_IN_STAGE/${APP_NAME}"
# Fail closed: empty signature blob means CARender/IOHID stay dead on device.
if ! grep -a -q 'global-capture' "$APP_IN_STAGE/${APP_NAME}"; then
  echo "error: ldid did not embed QuartzCore.global-capture into ${APP_NAME}" >&2
  exit 1
fi
if ! grep -a -q 'no-sandbox' "$APP_IN_STAGE/${APP_NAME}"; then
  echo "error: ldid did not embed no-sandbox into ${APP_NAME}" >&2
  exit 1
fi
echo "ldid entitlements ok (global-capture + no-sandbox present)"
if [[ -d "$APP_IN_STAGE/PlugIns/Broadcast.appex" ]]; then
  rm -rf "$APP_IN_STAGE/PlugIns/Broadcast.appex/_CodeSignature" || true
  ldid -S"$ROOT/Extension/Extension.entitlements" "$APP_IN_STAGE/PlugIns/Broadcast.appex/Broadcast"
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

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=${VERSION}" >>"$GITHUB_OUTPUT"
  echo "tipa=${TIPA}" >>"$GITHUB_OUTPUT"
fi
echo "VERSION=${VERSION}"
echo "wrote $TIPA"
ls -la "$TIPA"
