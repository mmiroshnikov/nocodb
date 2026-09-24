#!/usr/bin/env bash
# Swap NocoDB container on the Oracle VM after an image tarball was uploaded.
# Expects: /tmp/nocodb-fork-ce.tar.gz
# Optional env: PUBLIC_URL (default https://db.misha.live), IMAGE_TAG (default nocodb-fork:ce)

set -euo pipefail

PUBLIC_URL="${PUBLIC_URL:-https://db.misha.live}"
IMAGE_TAG="${IMAGE_TAG:-nocodb-fork:ce}"

echo "==> Load image"
gunzip -c /tmp/nocodb-fork-ce.tar.gz | sudo docker load
rm -f /tmp/nocodb-fork-ce.tar.gz

echo "==> Restart container"
sudo docker rm -f nocodb 2>/dev/null || true
sudo docker run -d \
  --name nocodb \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v /opt/nocodb/data:/usr/app/data \
  -e NC_PUBLIC_URL="${PUBLIC_URL}" \
  -e NC_GUI_DIST_PATH=/usr/src/app/node_modules/nc-lib-gui/lib/dist \
  "${IMAGE_TAG}"

sudo docker image prune -f >/dev/null || true

echo "==> Wait for health"
for i in $(seq 1 45); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:8080/api/v1/health || echo fail)
  echo "health $i $code"
  if [ "$code" = "200" ]; then
    curl -sS http://127.0.0.1:8080/api/v1/health; echo
    curl -sS -m 10 -H "Accept: text/html" -o /dev/null -w "ui:%{http_code} %{content_type}\n" http://127.0.0.1:8080/
    sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
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
