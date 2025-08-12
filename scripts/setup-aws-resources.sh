#!/bin/bash
set -euo pipefail

echo "Setting up AWS resources for DXNN Spot instances..."

# Create S3 bucket
echo "Creating S3 bucket: dxnn-checkpoints"
aws s3 mb s3://dxnn-checkpoints --region us-east-1 || echo "Bucket may already exist"

# Create IAM policy
echo "Creating IAM policy: DXNN-Spot-Policy"
aws iam create-policy \
    --policy-name DXNN-Spot-Policy \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "s3:PutObject",
                    "s3:GetObject",
                    "s3:ListBucket"
                ],
                "Resource": [
                    "arn:aws:s3:::dxnn-checkpoints",
                    "arn:aws:s3:::dxnn-checkpoints/dxnn/*"
                ]
            }
        ]
    }' || echo "Policy may already exist"

# Create IAM role
echo "Creating IAM role: DXNN-Spot-Role"
aws iam create-role \
    --role-name DXNN-Spot-Role \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "ec2.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }' || echo "Role may already exist"

# Attach policy to role
echo "Attaching policy to role..."
aws iam attach-role-policy \
    --role-name DXNN-Spot-Role \
    --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/DXNN-Spot-Policy || echo "Policy may already be attached"

# Create instance profile
echo "Creating instance profile: DXNN-Spot-Profile"
aws iam create-instance-profile \
    --instance-profile-name DXNN-Spot-Profile || echo "Instance profile may already exist"

# Add role to instance profile
echo "Adding role to instance profile..."
aws iam add-role-to-instance-profile \
    --instance-profile-name DXNN-Spot-Profile \
    --role-name DXNN-Spot-Role || echo "Role may already be in profile"

echo "AWS resources setup complete!"
echo ""
echo "To use with EC2 instances, specify the instance profile:"
echo "  --iam-instance-profile Name=DXNN-Spot-Profile"
