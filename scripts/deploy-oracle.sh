#!/usr/bin/env bash
# Build this fork's CE Docker image (linux/amd64) and deploy to the Oracle VM.
#
# Usage (from repo root, on your Mac):
#   ./scripts/deploy-oracle.sh
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
"${SSH[@]}" bash -s << EOF
set -euo pipefail
gunzip -c /tmp/nocodb-fork-ce.tar.gz | sudo docker load
rm -f /tmp/nocodb-fork-ce.tar.gz
sudo docker rm -f nocodb 2>/dev/null || true
sudo docker run -d \\
  --name nocodb \\
  --restart unless-stopped \\
  -p 127.0.0.1:8080:8080 \\
  -v /opt/nocodb/data:/usr/app/data \\
  -e NC_PUBLIC_URL=${PUBLIC_URL} \\
  -e NC_GUI_DIST_PATH=/usr/src/app/node_modules/nc-lib-gui/lib/dist \\
  ${IMAGE_TAG}
# Keep only the fork image to save RAM on the micro instance
sudo docker image prune -f >/dev/null || true
for i in \$(seq 1 45); do
  code=\$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8080/api/v1/health || echo fail)
  echo "health \$i \$code"
  if [ "\$code" = "200" ]; then
    curl -sS http://127.0.0.1:8080/api/v1/health; echo
    curl -sS -m 10 -H "Accept: text/html" -o /dev/null -w "ui:%{http_code} %{content_type}\\n" http://127.0.0.1:8080/
    sudo docker ps --format "table {{.Names}}\\t{{.Image}}\\t{{.Status}}"
    exit 0
  fi
  if sudo docker logs nocodb 2>&1 | tail -n 25 | grep -q "migration directory is corrupt"; then
    echo "MIGRATION ERROR:"
    sudo docker logs nocodb 2>&1 | tail -n 40
    exit 2
  fi
  sleep 4
done
echo FAIL
sudo docker logs nocodb 2>&1 | tail -n 50
exit 1
EOF

echo "==> Done. Open ${PUBLIC_URL}"
