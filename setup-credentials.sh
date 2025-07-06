#!/bin/bash

# AWS Credentials Setup Script (Bash)
# This script helps you set up AWS credentials for the deployment system

info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

echo -e "\033[1;34mAWS Credentials Setup\033[0m"
echo "====================="
echo ""

# Check if .env already exists
if [ -f ".env" ]; then
    warn "Found existing .env file"
    read -rp "Do you want to overwrite it? (y/N): " overwrite
    if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
        info "Keeping existing .env file"
        exit 0
    fi
fi

info "Creating .env file for AWS credentials..."
echo ""
read -rp "Enter your AWS Access Key ID: " accessKey
read -rsp "Enter your AWS Secret Access Key: " secretKey
echo ""
read -rp "Enter your default AWS region [us-east-1]: " region
region=${region:-us-east-1}

cat > .env <<EOF
# AWS Credentials for AWS-Deployment
# Generated on $(date)

AWS_ACCESS_KEY_ID=$accessKey
AWS_SECRET_ACCESS_KEY=$secretKey
AWS_DEFAULT_REGION=$region
EOF

success ".env file created successfully!"
info "Your credentials are stored in .env"

echo ""
info "Testing AWS credentials..."
if identity=$(aws sts get-caller-identity --output json 2>/dev/null); then
    success "AWS credentials are working!"
    echo "$identity" | jq -r '"Connected as: \(.Arn)\nAccount: \(.Account)"'
else
    warn "Could not verify credentials with AWS"
    info "This might be due to network issues or invalid credentials"
fi

echo ""
success "Setup completed!"
info "You can now run deployments with:"
info "  ./docker-deploy.sh"
info "  ./docker-deploy.sh -c config/dxnn.yml"
