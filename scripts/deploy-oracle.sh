#!/usr/bin/env bash
# Build this fork's CE Docker image (linux/amd64) and deploy to the Oracle VM.
#
# Usage (from repo root, on your Mac):
#   ./scripts/deploy-oracle.sh
#
# CI equivalent: .github/workflows/deploy-oracle.yml (push to develop/main)
#
# Optional env:
#   ORACLE_HOST   default: 146.235.233.206
#   SSH_KEY       default: ~/.ssh/oci-nocodb
#   IMAGE_TAG     default: nocodb-fork:ce
#   PUBLIC_URL    default: https://db.misha.live

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORACLE_HOST="${ORACLE_HOST:-146.235.233.206}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/oci-nocodb}"
IMAGE_TAG="${IMAGE_TAG:-nocodb-fork:ce}"
PUBLIC_URL="${PUBLIC_URL:-https://db.misha.live}"
TAR="/tmp/nocodb-fork-ce.tar.gz"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "ubuntu@${ORACLE_HOST}")
SCP=(scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)

echo "==> Node / pnpm"
# shellcheck disable=SC1091
source "$HOME/.nvm/nvm.sh" 2>/dev/null || true
nvm use 22 >/dev/null 2>&1 || true
node -v
pnpm -v

echo "==> Build backend bundle"
cd "$ROOT/packages/nocodb"
pnpm run docker:build
test -f docker/main.js

echo "==> Docker build (${IMAGE_TAG}, linux/amd64)"
docker buildx build --platform linux/amd64 -f Dockerfile.ce -t "$IMAGE_TAG" --load .

echo "==> Save image"
docker save "$IMAGE_TAG" | gzip > "$TAR"
ls -lh "$TAR"

echo "==> Upload to ${ORACLE_HOST}"
"${SCP[@]}" "$TAR" "ubuntu@${ORACLE_HOST}:/tmp/nocodb-fork-ce.tar.gz"

echo "==> Swap container on VM"
PUBLIC_URL="$PUBLIC_URL" IMAGE_TAG="$IMAGE_TAG" "${SSH[@]}" 'bash -s' < "$ROOT/scripts/oracle-swap.sh"

echo "==> Done. Open ${PUBLIC_URL}"
