#!/bin/bash

# Check AMI and Snapshot Status
# Usage: ./check-ami-status.sh AMI_ID

AMI_ID="${1:-ami-0d3a88de604a5cc04}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

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

echo ""
log_info "Checking AMI: $AMI_ID in region: $REGION"
echo ""

# Check AMI exists and get details
ami_info=$(aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query 'Images[0].[State,Name,CreationDate,BlockDeviceMappings[0].Ebs.SnapshotId]' \
    --output text 2>/dev/null)

if [[ -z "$ami_info" ]]; then
    log_error "AMI not found: $AMI_ID"
    exit 1
fi

ami_state=$(echo "$ami_info" | cut -f1)
ami_name=$(echo "$ami_info" | cut -f2)
ami_created=$(echo "$ami_info" | cut -f3)
snapshot_id=$(echo "$ami_info" | cut -f4)

echo "AMI Details:"
echo "  ID: $AMI_ID"
echo "  Name: $ami_name"
echo "  State: $ami_state"
echo "  Created: $ami_created"
echo ""

if [[ "$ami_state" != "available" ]]; then
    log_error "AMI is not available (state: $ami_state)"
    exit 1
fi

log_success "AMI is available"
echo ""

# Check snapshot status
if [[ -n "$snapshot_id" && "$snapshot_id" != "None" ]]; then
    log_info "Checking snapshot: $snapshot_id"

    snapshot_info=$(aws ec2 describe-snapshots \
        --region "$REGION" \
        --snapshot-ids "$snapshot_id" \
        --query 'Snapshots[0].[State,Progress,StartTime]' \
        --output text 2>/dev/null)

    if [[ -z "$snapshot_info" ]]; then
        log_error "Snapshot not found: $snapshot_id"
        exit 1
    fi

    snapshot_state=$(echo "$snapshot_info" | cut -f1)
    snapshot_progress=$(echo "$snapshot_info" | cut -f2)
    snapshot_started=$(echo "$snapshot_info" | cut -f3)

    echo "Snapshot Details:"
    echo "  ID: $snapshot_id"
    echo "  State: $snapshot_state"
    echo "  Progress: $snapshot_progress"
    echo "  Started: $snapshot_started"
    echo ""

    if [[ "$snapshot_state" == "completed" ]]; then
        log_success "Snapshot is ready - AMI can be used for launching instances"
        exit 0
    elif [[ "$snapshot_state" == "pending" ]]; then
        log_warning "Snapshot is still pending ($snapshot_progress)"
        log_warning "Cannot launch instances until snapshot completes"
        echo ""
        log_info "Waiting for snapshot to complete..."
        if ! aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$snapshot_id"; then
            log_error "Snapshot did not complete: $snapshot_id"
            exit 1
        fi
        log_success "Snapshot is now ready!"
        exit 0
    else
        log_error "Snapshot is in unexpected state: $snapshot_state"
        exit 1
    fi
else
    log_warning "No snapshot found for this AMI"
fi

echo ""
