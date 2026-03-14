#!/bin/bash
set -e

# Copy AMI to another region
# Usage: ./copy-ami-to-region.sh SOURCE_AMI SOURCE_REGION TARGET_REGION

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 SOURCE_AMI SOURCE_REGION TARGET_REGION"
    echo ""
    echo "Example:"
    echo "  $0 ami-0d3a88de604a5cc04 us-east-1 eu-west-1"
    exit 1
fi

SOURCE_AMI="$1"
SOURCE_REGION="$2"
TARGET_REGION="$3"

log_info "Copying AMI from $SOURCE_REGION to $TARGET_REGION"
log_info "Source AMI: $SOURCE_AMI"

# Get source AMI name
SOURCE_NAME=$(aws ec2 describe-images \
    --region "$SOURCE_REGION" \
    --image-ids "$SOURCE_AMI" \
    --query 'Images[0].Name' \
    --output text)

if [[ -z "$SOURCE_NAME" || "$SOURCE_NAME" == "None" ]]; then
    log_error "Could not find source AMI: $SOURCE_AMI in $SOURCE_REGION"
    exit 1
fi

log_info "Source AMI name: $SOURCE_NAME"

# Generate new name with timestamp
NEW_NAME="${SOURCE_NAME}-copy-$(date +%Y%m%d-%H%M%S)"

# Copy AMI
log_info "Starting AMI copy (this may take 10-15 minutes)..."
NEW_AMI_ID=$(aws ec2 copy-image \
    --source-region "$SOURCE_REGION" \
    --source-image-id "$SOURCE_AMI" \
    --region "$TARGET_REGION" \
    --name "$NEW_NAME" \
    --description "Copy of $SOURCE_AMI from $SOURCE_REGION" \
    --query 'ImageId' \
    --output text)

log_success "AMI copy initiated: $NEW_AMI_ID"
log_info "Waiting for AMI to become available in $TARGET_REGION..."

# Wait for AMI to be available
aws ec2 wait image-available \
    --region "$TARGET_REGION" \
    --image-ids "$NEW_AMI_ID"

log_success "AMI copy completed!"
echo ""
echo "  Region: $TARGET_REGION"
echo "  AMI ID: $NEW_AMI_ID"
echo "  Name: $NEW_NAME"
echo ""
log_info "Update your config file with: ami_id: \"$NEW_AMI_ID\""
echo ""
