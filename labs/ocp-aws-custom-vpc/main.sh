#!/bin/bash
set -x

# Variables
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DIRNAME="$(basename $DIR)"
REPO_DIR="$(dirname $DIR)"
BIN_DIR="$REPO_DIR/.bin"

export CLUSTER_NAME=${CLUSTER_NAME:-"$DIRNAME"}
export CLUSTER_DIR="$DIR/.cluster"
export STACK_NAME=${STACK_NAME:-"$DIRNAME"}
export SSH_KEY=${SSH_KEY:-$(cat $HOME/.ssh/id_rsa.pub)}
export PULL_SECRET=${PULL_SECRET:-$(cat $HOME/.openshift/pull-secret-latest.json)}
export AWS_REGION=${AWS_REGION:-"$(aws configure get region)"}

TEMPLATE_FILE="main.cfn.yaml"

# Deploy the CloudFormation stack
aws cloudformation deploy \
  --template-file $TEMPLATE_FILE \
  --stack-name $STACK_NAME \
  --capabilities CAPABILITY_NAMED_IAM

# Output the stack details
aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs"

# Retrieve the private subnet IDs
export PRIVATE_SUBNET_1_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet1Id'].OutputValue" \
  --output text)


export PRIVATE_SUBNET_2_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet2Id'].OutputValue" \
  --output text)

export PRIVATE_SUBNET_3_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet3Id'].OutputValue" \
  --output text)

echo "Private Subnet 1 ID: $PRIVATE_SUBNET_1_ID"
echo "Private Subnet 2 ID: $PRIVATE_SUBNET_2_ID"
echo "Private Subnet 3 ID: $PRIVATE_SUBNET_3_ID"


# Retrieve the private subnet IDs
export PUBLIC_SUBNET_1_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet1Id'].OutputValue" \
  --output text)


export PUBLIC_SUBNET_2_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet2Id'].OutputValue" \
  --output text)

export PUBLIC_SUBNET_3_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet3Id'].OutputValue" \
  --output text)

echo "Public Subnet 1 ID: $PUBLIC_SUBNET_1_ID"
echo "Public Subnet 2 ID: $PUBLIC_SUBNET_2_ID"
echo "Public Subnet 3 ID: $PUBLIC_SUBNET_3_ID"


mkdir -p $CLUSTER_DIR

envsubst < $DIR/install-config.env.yaml > $CLUSTER_DIR/install-config.yaml
cp $CLUSTER_DIR/install-config.yaml $CLUSTER_DIR/install-config.backup.yaml

$BIN_DIR/openshift-install create cluster --dir="$CLUSTER_DIR"

echo "$BIN_DIR/openshift-install destroy cluster --dir=\"$CLUSTER_DIR\"" > $CLUSTER_DIR/destroy_cluster.sh

echo "lab-aws-custom-vpc execution completed."
