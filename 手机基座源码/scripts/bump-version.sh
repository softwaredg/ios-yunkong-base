#!/bin/bash
# Bump tipa VERSION (patch +1) and sync project.yml MARKETING_VERSION.
# Must run BEFORE xcodegen / xcodebuild so the .app Info.plist matches the tipa name.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"

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
if [[ -f "$ROOT/project.yml" ]]; then
  # portable in-place sed (macOS + GNU)
  sed -i.bak -E "s/(MARKETING_VERSION: )\"[0-9.]+\"/\1\"${NEW_VERSION}\"/" "$ROOT/project.yml"
  rm -f "$ROOT/project.yml.bak"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=${NEW_VERSION}" >>"$GITHUB_OUTPUT"
fi
echo "VERSION=${NEW_VERSION}"
