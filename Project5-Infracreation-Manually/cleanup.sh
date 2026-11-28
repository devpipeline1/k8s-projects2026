#!/bin/bash

set -e

AWS_REGION="ap-south-1"

APP_VPC_ID="vpc-0969a26bb723d81da"

APP_PUBLIC_1_ID="subnet-0de65316501e62485"
APP_PUBLIC_2_ID="subnet-010f6d04c180d12f9"

APP_PRIVATE_1_ID="subnet-0ad279431ad397ebb"
APP_PRIVATE_2_ID="subnet-027928723346d4bcd"

APP_NAT_GW_ID="nat-00b303e1d644cacdd"

echo "===================================================="
echo "Deleting NAT Gateway"
echo "===================================================="

aws ec2 delete-nat-gateway \
  --region $AWS_REGION \
  --nat-gateway-id $APP_NAT_GW_ID

echo ""
echo "Waiting for NAT Gateway deletion..."
echo ""

while true; do
  STATE=$(aws ec2 describe-nat-gateways \
    --region $AWS_REGION \
    --nat-gateway-ids $APP_NAT_GW_ID \
    --query 'NatGateways[0].State' \
    --output text 2>/dev/null || echo "deleted")

  echo "Current State: $STATE"

  if [[ "$STATE" == "deleted" ]]; then
      break
  fi

  sleep 30
done

echo ""
echo "NAT Gateway deleted."
echo ""

echo "===================================================="
echo "Getting Route Tables"
echo "===================================================="

PUBLIC_RT=$(aws ec2 describe-route-tables \
  --region $AWS_REGION \
  --filters Name=vpc-id,Values=$APP_VPC_ID \
  --query 'RouteTables[?Associations[?Main==`false`]].RouteTableId' \
  --output text)

for rt in $PUBLIC_RT
do
  echo "Deleting Route Table: $rt"

  ASSOCS=$(aws ec2 describe-route-tables \
    --region $AWS_REGION \
    --route-table-ids $rt \
    --query 'RouteTables[0].Associations[].RouteTableAssociationId' \
    --output text)

  for assoc in $ASSOCS
  do
    if [[ "$assoc" != "None" ]]; then
      aws ec2 disassociate-route-table \
        --region $AWS_REGION \
        --association-id $assoc || true
    fi
  done

  aws ec2 delete-route-table \
    --region $AWS_REGION \
    --route-table-id $rt || true
done

echo ""
echo "===================================================="
echo "Deleting Subnets"
echo "===================================================="

aws ec2 delete-subnet \
  --region $AWS_REGION \
  --subnet-id $APP_PRIVATE_1_ID

aws ec2 delete-subnet \
  --region $AWS_REGION \
  --subnet-id $APP_PRIVATE_2_ID

aws ec2 delete-subnet \
  --region $AWS_REGION \
  --subnet-id $APP_PUBLIC_1_ID

aws ec2 delete-subnet \
  --region $AWS_REGION \
  --subnet-id $APP_PUBLIC_2_ID

echo "Subnets deleted."

echo ""
echo "===================================================="
echo "Finding Internet Gateway"
echo "===================================================="

IGW_ID=$(aws ec2 describe-internet-gateways \
  --region $AWS_REGION \
  --filters Name=attachment.vpc-id,Values=$APP_VPC_ID \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)

echo "Internet Gateway: $IGW_ID"

aws ec2 detach-internet-gateway \
  --region $AWS_REGION \
  --internet-gateway-id $IGW_ID \
  --vpc-id $APP_VPC_ID

aws ec2 delete-internet-gateway \
  --region $AWS_REGION \
  --internet-gateway-id $IGW_ID

echo "Internet Gateway deleted."

echo ""
echo "===================================================="
echo "Releasing Elastic IP"
echo "===================================================="

EIP_ALLOC=$(aws ec2 describe-addresses \
  --region $AWS_REGION \
  --query "Addresses[?AssociationId==null].AllocationId" \
  --output text)

if [[ ! -z "$EIP_ALLOC" ]]; then
  aws ec2 release-address \
    --region $AWS_REGION \
    --allocation-id $EIP_ALLOC
fi

echo ""
echo "===================================================="
echo "Deleting VPC"
echo "===================================================="

aws ec2 delete-vpc \
  --region $AWS_REGION \
  --vpc-id $APP_VPC_ID

echo ""
echo "===================================================="
echo "CLEANUP COMPLETED"
echo "===================================================="

