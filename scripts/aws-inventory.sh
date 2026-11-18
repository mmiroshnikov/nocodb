#!/usr/bin/env bash
# Read-only map of AWS compute/data that we must not touch.
# Usage: ./scripts/aws-inventory.sh
# Optional: AWS_REGION (default us-east-1), AWS_INVENTORY_REGIONS="us-east-1 us-east-2 us-west-2"

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
REGIONS="${AWS_INVENTORY_REGIONS:-us-east-1 us-east-2 us-west-2}"

echo "======== IDENTITY ========"
aws sts get-caller-identity

echo
echo "======== IAM ROLES (ecs / beanstalk / nocodb) ========"
aws iam list-roles \
  --query 'Roles[?contains(RoleName, `ecs`) || contains(RoleName, `ECS`) || contains(RoleName, `Beanstalk`) || contains(RoleName, `beanstalk`) || contains(RoleName, `nocodb`) || contains(RoleName, `Noco`)].{Name:RoleName,Arn:Arn}' \
  --output table || echo "(iam:ListRoles denied or empty)"

for r in $REGIONS; do
  echo
  echo "======== REGION $r ========"
  echo "-- EC2 --"
  aws ec2 describe-instances --region "$r" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,PublicIp:PublicIpAddress,Name:Tags[?Key==`Name`]|[0].Value,Project:Tags[?Key==`Project`]|[0].Value,Key:KeyName}' \
    --output table

  echo "-- RDS --"
  aws rds describe-db-instances --region "$r" \
    --query 'DBInstances[].{Id:DBInstanceIdentifier,Engine:Engine,Class:DBInstanceClass,Status:DBInstanceStatus}' \
    --output table 2>/dev/null || true

  echo "-- ECS clusters --"
  aws ecs list-clusters --region "$r" --output text 2>/dev/null || true

  echo "-- ELBv2 --"
  aws elbv2 describe-load-balancers --region "$r" \
    --query 'LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,Type:Type}' \
    --output table 2>/dev/null || true

  echo "-- ECR --"
  aws ecr describe-repositories --region "$r" \
    --query 'repositories[].repositoryName' --output text 2>/dev/null || true

  echo "-- EIP --"
  aws ec2 describe-addresses --region "$r" \
    --query 'Addresses[].{Ip:PublicIp,Inst:InstanceId}' --output table 2>/dev/null || true
done

echo
echo "======== NOCODB-CE (ours) ========"
aws ec2 describe-instances --region "$AWS_DEFAULT_REGION" \
  --filters Name=tag:Project,Values=nocodb-ce \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,PublicIp:PublicIpAddress,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
