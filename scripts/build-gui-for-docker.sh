#!/usr/bin/env bash
# Static-build nc-gui and copy it into packages/nocodb/docker/nc-gui
# so Dockerfile.ce can overlay it onto nc-lib-gui.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/packages/nc-gui"

export NODE_OPTIONS="${NODE_OPTIONS:---max_old_space_size=6144}"

echo "==> Generate nc-gui"
pnpm run generate

SRC=""
if [ -f dist/index.html ]; then
  SRC=dist
elif [ -f .output/public/index.html ]; then
  SRC=.output/public
else
  echo "nc-gui generate produced no index.html" >&2
  ls -la dist .output/public 2>/dev/null || true
  exit 1
fi

DEST="$ROOT/packages/nocodb/docker/nc-gui"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC"/. "$DEST/"
test -f "$DEST/index.html"
echo "==> GUI copied from packages/nc-gui/${SRC} -> docker/nc-gui"
