#!/usr/bin/env bash
# Build this fork's CE Docker image (linux/amd64) and deploy to the isolated AWS VM.
#
# Usage (from repo root):
#   ./scripts/deploy-aws.sh              # inventory summary + provision if needed + deploy
#   ./scripts/deploy-aws.sh inventory    # read-only
#   ./scripts/deploy-aws.sh provision    # isolated VPC/VM only
#   ./scripts/deploy-aws.sh deploy       # build image and swap nocodb-ce container
#
# Optional env:
#   AWS_HOST / SSH_KEY / PUBLIC_URL / AWS_REGION
#   STATE_FILE  default ~/.nocodb-ce-aws.env
#   IMAGE_TAG   default nocodb-ce:develop

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="${STATE_FILE:-$HOME/.nocodb-ce-aws.env}"
IMAGE_TAG="${IMAGE_TAG:-nocodb-ce:develop}"
TAR="/tmp/nocodb-ce.tar.gz"
CMD="${1:-all}"

# shellcheck disable=SC1091
source "$HOME/.nvm/nvm.sh" 2>/dev/null || true
nvm use 22 >/dev/null 2>&1 || true

load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

require_host() {
  load_state
  AWS_HOST="${AWS_HOST:-}"
  SSH_KEY="${SSH_KEY:-$HOME/.ssh/nocodb-ce}"
  SSH_USER="${SSH_USER:-ubuntu}"
  PUBLIC_URL="${PUBLIC_URL:-}"
  if [ -z "$AWS_HOST" ]; then
    echo "AWS_HOST is not set. Run: $0 provision" >&2
    exit 1
  fi
  SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${SSH_USER}@${AWS_HOST}")
  SCP=(scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
}

verify_others_untouched() {
  echo "==> Confirm existing Cloud66 instances still running/stopped as before"
  aws ec2 describe-instances --region "${AWS_REGION:-us-east-1}" \
    --filters Name=instance-state-name,Values=running,stopped \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,PublicIpAddress]' \
    --output table
}

inventory() {
  "$ROOT/scripts/aws-inventory.sh"
}

provision() {
  "$ROOT/scripts/aws-provision-ec2.sh"
  load_state
}

deploy() {
  require_host
  echo "==> Node / pnpm"
  node -v
  pnpm -v

  echo "==> Build backend bundle"
  cd "$ROOT/packages/nocodb"
  pnpm run docker:build
  test -f docker/main.js

  echo "==> Docker build (${IMAGE_TAG}, linux/amd64)"
  docker buildx build --platform linux/amd64 -f Dockerfile.ce -t "$IMAGE_TAG" --load .

  echo "==> Save image"
  docker save "$IMAGE_TAG" | gzip >"$TAR"
  ls -lh "$TAR"

  echo "==> Upload to ${AWS_HOST}"
  "${SCP[@]}" "$TAR" "${SSH_USER}@${AWS_HOST}:/tmp/nocodb-ce.tar.gz"

  echo "==> Swap ONLY nocodb-ce on AWS"
  PUBLIC_URL="${PUBLIC_URL:-http://${AWS_HOST}}" \
    IMAGE_TAG="$IMAGE_TAG" \
    "${SSH[@]}" "PUBLIC_URL='${PUBLIC_URL:-http://${AWS_HOST}}' IMAGE_TAG='${IMAGE_TAG}' bash -s" \
    <"$ROOT/scripts/aws-swap.sh"

  echo "==> Public health ${PUBLIC_URL:-http://${AWS_HOST}}/api/v1/health"
  curl -sS --max-time 15 "${PUBLIC_URL:-http://${AWS_HOST}}/api/v1/health" || true
  echo
  echo "==> Done. Open ${PUBLIC_URL:-http://${AWS_HOST}}"
  verify_others_untouched
}

case "$CMD" in
  inventory) inventory ;;
  provision) provision ;;
  deploy) deploy ;;
  all)
    inventory
    provision
    deploy
    ;;
  *)
    echo "Usage: $0 [all|inventory|provision|deploy]" >&2
    exit 2
    ;;
esac
