#!/bin/bash

set -e

# ============================================================
# CONFIGURATION
# ============================================================

export AWS_REGION="ap-south-1"

export APP_CLUSTER_NAME="application-eks"

export APP_VPC_CIDR="10.10.0.0/16"

export AZ1="ap-south-1a"
export AZ2="ap-south-1b"

# ============================================================
# APPLICATION SUBNET CIDRS
# ============================================================

export APP_PUBLIC_1_CIDR="10.10.1.0/24"
export APP_PUBLIC_2_CIDR="10.10.2.0/24"

export APP_PRIVATE_1_CIDR="10.10.11.0/24"
export APP_PRIVATE_2_CIDR="10.10.12.0/24"

#Create VPC
#============

export APP_VPC_ID=$(aws ec2 create-vpc \
  --region "$AWS_REGION" \
  --cidr-block "$APP_VPC_CIDR" \
  --query 'Vpc.VpcId' \
  --output text)

echo $APP_VPC_ID

aws ec2 create-tags \
  --region "$AWS_REGION" \
  --resources "$APP_VPC_ID" \
  --tags \
  Key=Name,Value=application-vpc

aws ec2 modify-vpc-attribute \
  --vpc-id "$APP_VPC_ID" \
  --enable-dns-support '{"Value":true}'

aws ec2 modify-vpc-attribute \
  --vpc-id "$APP_VPC_ID" \
  --enable-dns-hostnames '{"Value":true}'



#Internet Gateway
#================

export APP_IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$AWS_REGION" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$APP_IGW_ID" \
  --vpc-id "$APP_VPC_ID"

aws ec2 create-tags \
  --resources "$APP_IGW_ID" \
  --tags Key=Name,Value=application-igw



#Public Subnets
#==============

export APP_PUBLIC_1_ID=$(aws ec2 create-subnet \
  --vpc-id "$APP_VPC_ID" \
  --cidr-block "$APP_PUBLIC_1_CIDR" \
  --availability-zone "$AZ1" \
  --query 'Subnet.SubnetId' \
  --output text)

export APP_PUBLIC_2_ID=$(aws ec2 create-subnet \
  --vpc-id "$APP_VPC_ID" \
  --cidr-block "$APP_PUBLIC_2_CIDR" \
  --availability-zone "$AZ2" \
  --query 'Subnet.SubnetId' \
  --output text)

aws ec2 modify-subnet-attribute \
  --subnet-id "$APP_PUBLIC_1_ID" \
  --map-public-ip-on-launch

aws ec2 modify-subnet-attribute \
  --subnet-id "$APP_PUBLIC_2_ID" \
  --map-public-ip-on-launch



#Private Subnets
#===============

export APP_PRIVATE_1_ID=$(aws ec2 create-subnet \
  --vpc-id "$APP_VPC_ID" \
  --cidr-block "$APP_PRIVATE_1_CIDR" \
  --availability-zone "$AZ1" \
  --query 'Subnet.SubnetId' \
  --output text)

export APP_PRIVATE_2_ID=$(aws ec2 create-subnet \
  --vpc-id "$APP_VPC_ID" \
  --cidr-block "$APP_PRIVATE_2_CIDR" \
  --availability-zone "$AZ2" \
  --query 'Subnet.SubnetId' \
  --output text)


#EKS Required Tags
#=================

aws ec2 create-tags \
  --resources \
  "$APP_PUBLIC_1_ID" \
  "$APP_PUBLIC_2_ID" \
  --tags \
  Key=kubernetes.io/role/elb,Value=1 \
  Key=kubernetes.io/cluster/$APP_CLUSTER_NAME,Value=shared

aws ec2 create-tags \
  --resources \
  "$APP_PRIVATE_1_ID" \
  "$APP_PRIVATE_2_ID" \
  --tags \
  Key=kubernetes.io/role/internal-elb,Value=1 \
  Key=kubernetes.io/cluster/$APP_CLUSTER_NAME,Value=shared


#Public Route Table
#==================

export APP_PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$APP_VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id "$APP_PUBLIC_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$APP_IGW_ID"

aws ec2 associate-route-table \
  --route-table-id "$APP_PUBLIC_RT_ID" \
  --subnet-id "$APP_PUBLIC_1_ID"

aws ec2 associate-route-table \
  --route-table-id "$APP_PUBLIC_RT_ID" \
  --subnet-id "$APP_PUBLIC_2_ID"


#NAT Gateway
#============

export APP_NAT_EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --query AllocationId \
  --output text)

export APP_NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$APP_PUBLIC_1_ID" \
  --allocation-id "$APP_NAT_EIP_ALLOC_ID" \
  --query 'NatGateway.NatGatewayId' \
  --output text)

aws ec2 wait nat-gateway-available \
  --nat-gateway-ids "$APP_NAT_GW_ID"


#Private Route Table
#===================

export APP_PRIVATE_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$APP_VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id "$APP_PRIVATE_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$APP_NAT_GW_ID"

aws ec2 associate-route-table \
  --route-table-id "$APP_PRIVATE_RT_ID" \
  --subnet-id "$APP_PRIVATE_1_ID"

aws ec2 associate-route-table \
  --route-table-id "$APP_PRIVATE_RT_ID" \
  --subnet-id "$APP_PRIVATE_2_ID"




echo "============================================================"
echo "NETWORK SETUP COMPLETED SUCCESSFULLY"
echo "============================================================"
echo ""
echo "AWS REGION:"
echo "$AWS_REGION"
echo ""
echo "------------------------------------------------------------"
echo "APPLICATION VPC"
echo "------------------------------------------------------------"
echo "VPC:"
echo "$APP_VPC_ID"
echo "CIDR:"
echo "$APP_VPC_CIDR"
echo ""
echo "Public Subnet 1:"
echo "$APP_PUBLIC_1_ID"
echo "Public Subnet 2:"
echo "$APP_PUBLIC_2_ID"
echo ""
echo "Private Subnet 1:"
echo "$APP_PRIVATE_1_ID"
echo "Private Subnet 2:"
echo "$APP_PRIVATE_2_ID"
echo ""
echo "NAT Gateway:"
echo "$APP_NAT_GW_ID"
