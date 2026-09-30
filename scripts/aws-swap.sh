#!/usr/bin/env bash
# Install or replace ONLY the nocodb-ce container.
# Never removes containers named nocodb or any other name.
# Never prunes images (that could delete other projects' unused tags).
#
# Expects (optional): /tmp/nocodb-ce.tar.gz
# Env:
#   PUBLIC_URL      public URL (required for links)
#   IMAGE_TAG       default nocodb-ce:develop
#   CONTAINER_NAME  default nocodb-ce
#   HOST_PORT       default 18080 (host loopback)
#   DATA_DIR        default /opt/nocodb-ce/data

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-nocodb-ce}"
IMAGE_TAG="${IMAGE_TAG:-nocodb-ce:develop}"
DATA_DIR="${DATA_DIR:-/opt/nocodb-ce/data}"
HOST_PORT="${HOST_PORT:-18080}"
ENV_FILE="${ENV_FILE:-/opt/nocodb-ce/env}"
TAR="${TAR:-/tmp/nocodb-ce.tar.gz}"
PUBLIC_URL="${PUBLIC_URL:-}"

if [ "$CONTAINER_NAME" = "nocodb" ]; then
  echo "Refusing container name 'nocodb' (would collide with other stacks)" >&2
  exit 1
fi
case "$CONTAINER_NAME" in
  nocodb-ce|nocodb-ce-*) ;;
  *)
    echo "Refusing container name '$CONTAINER_NAME' (must be nocodb-ce*)" >&2
    exit 1
    ;;
esac
if [ "$DATA_DIR" = "/opt/nocodb/data" ] || [ "$DATA_DIR" = "/usr/app/data" ]; then
  echo "Refusing DATA_DIR=$DATA_DIR (reserved / shared path)" >&2
  exit 1
fi

echo "==> Load image (if tarball present)"
if [ -f "$TAR" ]; then
  gunzip -c "$TAR" | sudo docker load
  rm -f "$TAR"
fi

echo "==> Data dir $DATA_DIR"
sudo mkdir -p "$DATA_DIR" "$(dirname "$ENV_FILE")"
sudo chown -R ubuntu:ubuntu "$(dirname "$DATA_DIR")" 2>/dev/null || true

if [ ! -f "$ENV_FILE" ]; then
  echo "==> generate $ENV_FILE"
  JWT="$(openssl rand -hex 32)"
  printf 'NC_AUTH_JWT_SECRET=%s\n' "$JWT" | sudo tee "$ENV_FILE" >/dev/null
  sudo chmod 600 "$ENV_FILE"
fi

if [ -z "$PUBLIC_URL" ]; then
  META_IP="$(curl -sS --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  PUBLIC_URL="http://${META_IP:-127.0.0.1}"
fi

echo "==> Replace only ${CONTAINER_NAME}"
if sudo docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  sudo docker rm -f "$CONTAINER_NAME"
fi

sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  -p "127.0.0.1:${HOST_PORT}:8080" \
  -v "${DATA_DIR}:/usr/app/data" \
  -e "NC_PUBLIC_URL=${PUBLIC_URL}" \
  -e NC_GUI_DIST_PATH=/usr/src/app/node_modules/nc-lib-gui/lib/dist \
  "$IMAGE_TAG"

echo "==> Wait for health on 127.0.0.1:${HOST_PORT}"
for i in $(seq 1 45); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${HOST_PORT}/api/v1/health" || echo fail)"
  echo "health $i $code"
  if [ "$code" = "200" ]; then
    curl -sS "http://127.0.0.1:${HOST_PORT}/api/v1/health"; echo
    sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    echo "==> other containers (untouched):"
    sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    exit 0
  fi
  if sudo docker logs "$CONTAINER_NAME" 2>&1 | tail -n 25 | grep -q "migration directory is corrupt"; then
    echo "MIGRATION ERROR:"
    sudo docker logs "$CONTAINER_NAME" 2>&1 | tail -n 40
    exit 2
  fi
  sleep 4
done

echo FAIL
sudo docker logs "$CONTAINER_NAME" 2>&1 | tail -n 50
exit 1
