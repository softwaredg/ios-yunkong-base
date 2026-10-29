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

if grep -q '<!--' "$ROOT/App/App.entitlements"; then
  echo "error: App.entitlements has XML comments" >&2
  exit 1
fi
# Copy to ASCII temp first — plutil/ldid reading 手机基座源码/... produced empty <dict/> (181 bytes).
ENT_XML="$STAGE/App.entitlements.xml"
cp "$ROOT/App/App.entitlements" "$ENT_XML"
if command -v plutil >/dev/null 2>&1; then
  plutil -convert xml1 "$ENT_XML"
fi
echo "entitlements file for sign: $ENT_XML"
wc -c "$ENT_XML"
cat "$ENT_XML"
grep -E 'global-capture|no-sandbox' "$ENT_XML" || {
  echo "error: ENT_XML missing required keys" >&2
  exit 1
}
BIN="$APP_IN_STAGE/${APP_NAME}"
# Prefer codesign adhoc — reliable on GHA macOS; brew ldid 2.1.5 was embedding <dict/>.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --entitlements "$ENT_XML" --generate-entitlement-der "$BIN"
  echo "codesign adhoc done"
else
  echo "error: codesign not found" >&2
  exit 1
fi
# Verify via codesign display (ldid -e may still be empty on codesign-signed bins).
ENT_DUMP="$(codesign -d --entitlements :- "$BIN" 2>/dev/null || true)"
echo "codesign entitlements dump:"
echo "$ENT_DUMP"
if ! printf '%s' "$ENT_DUMP" | grep -q 'global-capture'; then
  echo "error: signed binary missing QuartzCore.global-capture" >&2
  exit 1
fi
if ! printf '%s' "$ENT_DUMP" | grep -q 'no-sandbox'; then
  echo "error: signed binary missing no-sandbox" >&2
  exit 1
fi
echo "entitlements ok"
if [[ -d "$APP_IN_STAGE/PlugIns/Broadcast.appex" ]]; then
  rm -rf "$APP_IN_STAGE/PlugIns/Broadcast.appex/_CodeSignature" || true
  EXT_BIN="$APP_IN_STAGE/PlugIns/Broadcast.appex/Broadcast"
  EXT_ENT="$STAGE/Extension.entitlements.xml"
  if command -v plutil >/dev/null 2>&1; then
    plutil -convert xml1 -o "$EXT_ENT" "$ROOT/Extension/Extension.entitlements"
  else
    cp "$ROOT/Extension/Extension.entitlements" "$EXT_ENT"
  fi
  codesign --force --sign - --entitlements "$EXT_ENT" --generate-entitlement-der "$EXT_BIN"
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
