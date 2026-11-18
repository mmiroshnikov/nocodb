#!/usr/bin/env bash
# Create or reuse the isolated nocodb-ce EC2 stack.
# Does NOT modify existing VPCs, security groups, instances, RDS, or EIPs.
#
# Usage:
#   ./scripts/aws-provision-ec2.sh
#
# Optional env:
#   AWS_REGION   default us-east-1
#   SSH_CIDR     default: detected public IP /32
#   INSTANCE_TYPE default t3.small
#   STATE_FILE   default $HOME/.nocodb-ce-aws.env

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_DEFAULT_REGION="$REGION"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
STATE_FILE="${STATE_FILE:-$HOME/.nocodb-ce-aws.env}"
KEY_NAME="${KEY_NAME:-nocodb-ce}"
KEY_PATH="${SSH_KEY:-$HOME/.ssh/nocodb-ce}"
PROJECT="nocodb-ce"
CIDR_VPC="10.77.0.0/16"
CIDR_SUBNET="10.77.1.0/24"

MY_IP="$(curl -sS --max-time 8 https://checkip.amazonaws.com | tr -d '[:space:]')"
SSH_CIDR="${SSH_CIDR:-${MY_IP}/32}"

echo "==> region=$REGION type=$INSTANCE_TYPE ssh_cidr=$SSH_CIDR"

tag() {
  local resource="$1"
  shift
  aws ec2 create-tags --region "$REGION" --resources "$resource" --tags \
    "Key=Project,Value=$PROJECT" \
    "Key=Keep,Value=isolated" \
    "Key=ManagedBy,Value=cursor" \
    "$@"
}

find_ours() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" \
      "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[0].InstanceId' --output text
}

write_state() {
  local id="$1" ip="$2"
  cat >"$STATE_FILE" <<EOF
AWS_REGION=$REGION
AWS_HOST=$ip
AWS_INSTANCE_ID=$id
SSH_KEY=$KEY_PATH
SSH_USER=ubuntu
PUBLIC_URL=http://$ip
PROJECT=$PROJECT
EOF
  chmod 600 "$STATE_FILE"
  echo "==> wrote $STATE_FILE"
  echo "    AWS_HOST=$ip"
  echo "    AWS_INSTANCE_ID=$id"
}

EXISTING="$(find_ours)"
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$EXISTING" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  echo "==> reuse existing $EXISTING ($IP)"
  write_state "$EXISTING" "$IP"
  exit 0
fi

echo "==> no running nocodb-ce instance; creating isolated VPC + VM"

# --- key pair (never overwrite an AWS key we cannot download again) ---
mkdir -p "$HOME/.ssh"
KEY_EXISTS="$(aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)"
if [ -z "$KEY_EXISTS" ] || [ "$KEY_EXISTS" = "None" ]; then
  echo "==> create key pair $KEY_NAME"
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text >"$KEY_PATH"
  chmod 600 "$KEY_PATH"
else
  if [ ! -f "$KEY_PATH" ]; then
    KEY_NAME="${KEY_NAME}-$(date +%Y%m%d%H%M%S)"
    echo "==> AWS key exists but local pem missing; creating $KEY_NAME"
    aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
      --query 'KeyMaterial' --output text >"$KEY_PATH"
    chmod 600 "$KEY_PATH"
  else
    echo "==> reuse key pair $KEY_NAME + $KEY_PATH"
  fi
fi

# --- VPC ---
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=cidr-block,Values=$CIDR_VPC" \
  --query 'Vpcs[0].VpcId' --output text)"
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  VPC_ID="$(aws ec2 create-vpc --region "$REGION" --cidr-block "$CIDR_VPC" \
    --query 'Vpc.VpcId' --output text)"
  aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support
  aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames
  tag "$VPC_ID" "Key=Name,Value=nocodb-ce-vpc"
  echo "==> vpc $VPC_ID"
else
  echo "==> reuse vpc $VPC_ID"
fi

# --- Internet gateway ---
IGW_ID="$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)"
if [ -z "$IGW_ID" ] || [ "$IGW_ID" = "None" ]; then
  IGW_ID="$(aws ec2 create-internet-gateway --region "$REGION" \
    --query 'InternetGateway.InternetGatewayId' --output text)"
  tag "$IGW_ID" "Key=Name,Value=nocodb-ce-igw"
  aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  echo "==> igw $IGW_ID"
else
  echo "==> reuse igw $IGW_ID"
fi

# --- Subnet ---
SUBNET_ID="$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[0].SubnetId' --output text)"
if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "None" ]; then
  AZ="$(aws ec2 describe-availability-zones --region "$REGION" \
    --query 'AvailabilityZones[?State==`available`].ZoneName | [0]' --output text)"
  SUBNET_ID="$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
    --cidr-block "$CIDR_SUBNET" --availability-zone "$AZ" \
    --query 'Subnet.SubnetId' --output text)"
  aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
  tag "$SUBNET_ID" "Key=Name,Value=nocodb-ce-public"
  echo "==> subnet $SUBNET_ID ($AZ)"
else
  echo "==> reuse subnet $SUBNET_ID"
fi

# --- Route table ---
RT_ID="$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[0].RouteTableId' --output text)"
if [ -z "$RT_ID" ] || [ "$RT_ID" = "None" ]; then
  RT_ID="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
    --query 'RouteTable.RouteTableId' --output text)"
  tag "$RT_ID" "Key=Name,Value=nocodb-ce-public-rt"
  aws ec2 create-route --region "$REGION" --route-table-id "$RT_ID" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table --region "$REGION" --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID" >/dev/null
  echo "==> route table $RT_ID"
else
  echo "==> reuse route table $RT_ID"
fi

# --- Security group (new group only; never edit Cloud66 SGs) ---
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  SG_ID="$(aws ec2 create-security-group --region "$REGION" \
    --group-name nocodb-ce-sg --description "Isolated NocoDB CE (do not reuse)" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
  tag "$SG_ID" "Key=Name,Value=nocodb-ce-sg"
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$SSH_CIDR,Description=admin-ssh}]" \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=http}]" \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=https}]" >/dev/null
  echo "==> sg $SG_ID"
else
  echo "==> reuse sg $SG_ID"
fi

# --- AMI ---
AMI="$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text)"
echo "==> ami $AMI"

USER_DATA="$(cat <<'CLOUD'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io nginx openssl
systemctl enable --now docker
usermod -aG docker ubuntu
mkdir -p /opt/nocodb-ce/data
chown -R ubuntu:ubuntu /opt/nocodb-ce
cat >/etc/nginx/sites-available/nocodb-ce <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:18080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/nocodb-ce /etc/nginx/sites-enabled/nocodb-ce
systemctl enable --now nginx
nginx -t && systemctl reload nginx
CLOUD
)"

IID="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true,"Encrypted":true}}]' \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=nocodb-ce},{Key=Project,Value=$PROJECT},{Key=Keep,Value=isolated},{Key=ManagedBy,Value=cursor}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=nocodb-ce-root},{Key=Project,Value=$PROJECT},{Key=Keep,Value=isolated}]" \
  --query 'Instances[0].InstanceId' --output text)"

echo "==> launched $IID — waiting until running"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
write_state "$IID" "$IP"

echo "==> wait for SSH + docker on $IP (cloud-init)"
for i in $(seq 1 50); do
  if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
      -o BatchMode=yes "ubuntu@${IP}" 'sudo docker info >/dev/null 2>&1 && test -f /etc/nginx/sites-enabled/nocodb-ce'; then
    echo "==> host ready"
    exit 0
  fi
  echo "    wait $i/50"
  sleep 8
done

echo "WARN: instance is up at $IP but docker/nginx not ready yet; retry deploy later" >&2
exit 0
