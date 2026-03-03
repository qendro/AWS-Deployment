#!/bin/bash
set -e

# Setup IAM Policy for DXNN Deployment

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${BLUE}DXNN IAM Policy Setup${NC}"
echo "====================="
echo ""

# Check AWS CLI
if ! command -v aws >/dev/null 2>&1; then
    log_error "AWS CLI not found"
    exit 1
fi

# Get current user
log_info "Getting current AWS identity..."
IDENTITY=$(aws sts get-caller-identity --output json)
USER_ARN=$(echo "$IDENTITY" | jq -r '.Arn')
ACCOUNT_ID=$(echo "$IDENTITY" | jq -r '.Account')
USER_NAME=$(echo "$USER_ARN" | awk -F'/' '{print $NF}')

log_info "Current user: $USER_NAME"
log_info "Account ID: $ACCOUNT_ID"
echo ""

# Create policy JSON
POLICY_FILE="/tmp/dxnn-deployment-policy.json"
cat > "$POLICY_FILE" << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2InstanceManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:StopInstances",
        "ec2:StartInstances",
        "ec2:RebootInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeSpotInstanceRequests",
        "ec2:RequestSpotInstances",
        "ec2:CancelSpotInstanceRequests",
        "ec2:ModifyInstanceAttribute"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AMIManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateImage",
        "ec2:DeregisterImage",
        "ec2:DescribeImages",
        "ec2:ModifyImageAttribute",
        "ec2:CopyImage",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:DescribeTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SnapshotManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
        "ec2:DescribeSnapshots",
        "ec2:ModifySnapshotAttribute",
        "ec2:CopySnapshot"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KeyPairManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:DescribeKeyPairs",
        "ec2:ImportKeyPair"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecurityGroupManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeSecurityGroups",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3BucketManagement",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:ListBucket",
        "s3:ListAllMyBuckets",
        "s3:GetBucketLocation",
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucketVersions"
      ],
      "Resource": [
        "arn:aws:s3:::dxnn-checkpoints",
        "arn:aws:s3:::dxnn-checkpoints/*"
      ]
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole",
        "iam:GetRole",
        "iam:ListInstanceProfiles"
      ],
      "Resource": [
        "arn:aws:iam::*:role/DXNN-Spot-Profile",
        "arn:aws:iam::*:instance-profile/DXNN-Spot-Profile"
      ]
    },
    {
      "Sid": "PricingAndAvailability",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeRegions"
      ],
      "Resource": "*"
    }
  ]
}
EOF

log_info "Policy file created: $POLICY_FILE"
echo ""

# Check if policy already exists
POLICY_NAME="DXNN-Deployment-Policy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    log_warning "Policy already exists: $POLICY_NAME"
    read -p "Update existing policy? (yes/no): " update_policy
    
    if [[ "$update_policy" == "yes" ]]; then
        log_info "Creating new policy version..."
        aws iam create-policy-version \
            --policy-arn "$POLICY_ARN" \
            --policy-document "file://$POLICY_FILE" \
            --set-as-default
        log_success "Policy updated"
    fi
else
    log_info "Creating IAM policy: $POLICY_NAME"
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "file://$POLICY_FILE" \
        --description "Permissions for DXNN deployment, AMI creation, and spot instance management"
    log_success "Policy created: $POLICY_ARN"
fi

echo ""

# Check if policy is attached to user
log_info "Checking if policy is attached to user..."
if aws iam list-attached-user-policies --user-name "$USER_NAME" | grep -q "$POLICY_NAME"; then
    log_success "Policy already attached to user: $USER_NAME"
else
    log_info "Attaching policy to user: $USER_NAME"
    aws iam attach-user-policy \
        --user-name "$USER_NAME" \
        --policy-arn "$POLICY_ARN"
    log_success "Policy attached to user"
fi

echo ""
log_success "IAM policy setup complete!"
echo ""
log_info "Policy ARN: $POLICY_ARN"
log_info "Attached to: $USER_NAME"
echo ""
log_warning "Note: IAM changes may take 1-2 minutes to propagate"
echo ""

# Cleanup
rm -f "$POLICY_FILE"

# Verification
log_info "Verifying permissions..."
echo ""

if aws ec2 describe-images --owners self --max-items 1 >/dev/null 2>&1; then
    log_success "✓ Can describe images"
else
    log_error "✗ Cannot describe images"
fi

if aws ec2 describe-instances --max-items 1 >/dev/null 2>&1; then
    log_success "✓ Can describe instances"
else
    log_error "✗ Cannot describe instances"
fi

echo ""
log_info "You can now run: ./docker-ami.sh --create"
