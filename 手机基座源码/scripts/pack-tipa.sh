#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
OUT_DIR="${1:-$REPO/手机基座}"
VERSION="${VERSION:-0.1.0}"
APP_NAME="IOSYunKongBase"
DERIVED="${DERIVED_DATA:-$ROOT/build}"
PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"
APP="$PRODUCTS/${APP_NAME}.app"

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

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

TIPA="$OUT_DIR/IOS云控基座-TVH4-IOHID-${VERSION}.tipa"
(
  cd "$STAGE"
  rm -f "$TIPA"
  zip -qry "$TIPA" Payload
)
echo "wrote $TIPA"
ls -la "$TIPA"
