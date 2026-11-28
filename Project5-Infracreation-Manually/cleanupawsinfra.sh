#!/bin/bash

set -e

###########################################################
# CONFIGURATION
###########################################################


CLUSTER_NAME="application-eks"


AWS_REGION="ap-south-1"

VPC_ID="vpc-0969a26bb723d81da"

APP_PUBLIC_1_ID="subnet-0de65316501e62485"
APP_PUBLIC_2_ID="subnet-010f6d04c180d12f9"

APP_PRIVATE_1_ID="subnet-0ad279431ad397ebb"
APP_PRIVATE_2_ID="subnet-027928723346d4bcd"

APP_NAT_GW_ID="nat-00b303e1d644cacdd"


###########################################################
# DELETE EKS CLUSTER
###########################################################

echo "=================================================="
echo "DELETING EKS CLUSTER"
echo "=================================================="

if aws eks describe-cluster \
  --region $AWS_REGION \
  --name $CLUSTER_NAME >/dev/null 2>&1
then

  eksctl delete cluster \
    --name $CLUSTER_NAME \
    --region $AWS_REGION

else
  echo "Cluster already deleted."
fi

echo ""
echo "Waiting for EKS ENIs to disappear..."
echo ""

sleep 60

###########################################################
# DISCOVER RESOURCES
###########################################################

echo "=================================================="
echo "DISCOVERING VPC RESOURCES"
echo "=================================================="

PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
  --region $AWS_REGION \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].SubnetId' \
  --output text)

IGW_ID=$(aws ec2 describe-internet-gateways \
  --region $AWS_REGION \
  --filters Name=attachment.vpc-id,Values=$VPC_ID \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)

NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --region $AWS_REGION \
  --filter Name=vpc-id,Values=$VPC_ID \
  --query 'NatGateways[?State!=`deleted`].NatGatewayId' \
  --output text)

EIP_ALLOC_ID=$(aws ec2 describe-addresses \
  --region $AWS_REGION \
  --query 'Addresses[].AllocationId' \
  --output text)

###########################################################
# DELETE NAT GATEWAY
###########################################################

if [[ ! -z "$NAT_GW_ID" && "$NAT_GW_ID" != "None" ]]; then

  echo ""
  echo "=================================================="
  echo "DELETING NAT GATEWAY"
  echo "=================================================="

  aws ec2 delete-nat-gateway \
    --region $AWS_REGION \
    --nat-gateway-id $NAT_GW_ID

  echo "Waiting for NAT Gateway deletion..."

  while true
  do

    STATE=$(aws ec2 describe-nat-gateways \
      --region $AWS_REGION \
      --nat-gateway-ids $NAT_GW_ID \
      --query 'NatGateways[0].State' \
      --output text 2>/dev/null || echo "deleted")

    echo "Current State: $STATE"

    if [[ "$STATE" == "deleted" ]]; then
      break
    fi

    sleep 30

  done

fi

###########################################################
# RELEASE EIP
###########################################################

if [[ ! -z "$EIP_ALLOC_ID" && "$EIP_ALLOC_ID" != "None" ]]; then

  echo ""
  echo "=================================================="
  echo "RELEASING ELASTIC IP"
  echo "=================================================="

  for eip in $EIP_ALLOC_ID
  do
      aws ec2 release-address \
        --region $AWS_REGION \
        --allocation-id $eip || true
  done

fi

###########################################################
# DELETE ROUTE TABLES
###########################################################

echo ""
echo "=================================================="
echo "DELETING ROUTE TABLES"
echo "=================================================="

CUSTOM_RTS=$(aws ec2 describe-route-tables \
  --region $AWS_REGION \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'RouteTables[?Associations[?Main==`false`]].RouteTableId' \
  --output text)

for rt in $CUSTOM_RTS
do

  echo "Deleting Route Table: $rt"

  ASSOCS=$(aws ec2 describe-route-tables \
    --region $AWS_REGION \
    --route-table-ids $rt \
    --query 'RouteTables[0].Associations[].RouteTableAssociationId' \
    --output text)

  for assoc in $ASSOCS
  do
      [[ "$assoc" != "None" ]] && \
      aws ec2 disassociate-route-table \
      --region $AWS_REGION \
      --association-id $assoc || true
  done

  aws ec2 delete-route-table \
    --region $AWS_REGION \
    --route-table-id $rt || true

done

###########################################################
# DELETE SUBNETS
###########################################################

echo ""
echo "=================================================="
echo "DELETING SUBNETS"
echo "=================================================="

for subnet in $PUBLIC_SUBNETS
do

  echo "Deleting subnet: $subnet"

  aws ec2 delete-subnet \
    --region $AWS_REGION \
    --subnet-id $subnet || true

done

###########################################################
# DELETE INTERNET GATEWAY
###########################################################

if [[ ! -z "$IGW_ID" && "$IGW_ID" != "None" ]]; then

  echo ""
  echo "=================================================="
  echo "DELETING INTERNET GATEWAY"
  echo "=================================================="

  aws ec2 detach-internet-gateway \
    --region $AWS_REGION \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID || true

  aws ec2 delete-internet-gateway \
    --region $AWS_REGION \
    --internet-gateway-id $IGW_ID || true

fi

###########################################################
# DELETE VPC
###########################################################

echo ""
echo "=================================================="
echo "DELETING VPC"
echo "=================================================="

aws ec2 delete-vpc \
  --region $AWS_REGION \
  --vpc-id $VPC_ID

echo ""
echo "=================================================="
echo "CLEANUP COMPLETED"
echo "=================================================="
