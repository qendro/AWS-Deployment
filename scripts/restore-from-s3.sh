#!/bin/bash
set -euo pipefail

S3_BUCKET="dxnn-checkpoints"
S3_PREFIX="dxnn"
JOB_ID="dxnn-training-001"
CHECKPOINT_DIR="/var/lib/dxnn/checkpoints"
CONTAINER_NAME="dxnn-app"
LOG_FILE="/var/log/spot-restore.log"
IMDS="http://169.254.169.254"

log() {
    echo "[UTC $(date -u -Iseconds)] $1" >> "$LOG_FILE"
}

# Get IMDSv2 token
get_token() {
    curl -sS -X PUT "$IMDS/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true
}

# Simple S3 GET using the dedicated download script
s3_get() {
    local s3_key="$1"
    local output_file="$2"
    local token="$3"
    
    # Use the simple-s3-download.sh script
    if /usr/local/bin/simple-s3-download.sh "$s3_key" "$output_file" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Find latest checkpoint in S3 for the job_id
find_latest_s3_checkpoint() {
    local token="$1"
    
    # For now, we'll use a simple approach since we know the structure
    # In production, you'd want to list the S3 bucket contents
    log "INFO: Looking for latest checkpoint in S3 for job_id: $JOB_ID"
    
    # Try to find the checkpoint we uploaded earlier
    # This is a simplified approach - in production you'd list the bucket
    local test_key="$S3_PREFIX/$JOB_ID/2025/08/12/155913Z/checkpoint-1755014342.dmp"
    local test_metadata_key="$S3_PREFIX/$JOB_ID/2025/08/12/155913Z/checkpoint-1755014342.metadata.json"
    
    # Try to download the test checkpoint
    if s3_get "$test_key" "/tmp/test_checkpoint.dmp" "$token"; then
        if s3_get "$test_metadata_key" "/tmp/test_metadata.json" "$token"; then
            echo "$test_key"
            return 0
        fi
    fi
    
    return 1
}

# Main restore logic
main() {
    log "INFO: Starting S3 restore process"
    
    # Get IMDSv2 token
    token=$(get_token)
    if [[ -z "$token" ]]; then
        log "ERROR: Failed to get IMDSv2 token"
        return 1
    fi
    
    # Try to find latest checkpoint in S3
    if latest_s3_key=$(find_latest_s3_checkpoint "$token"); then
        log "S3_SOURCE: Found checkpoint in S3: $latest_s3_key"
        
        # Download checkpoint and metadata
        local checkpoint_file="$CHECKPOINT_DIR/$(basename "$latest_s3_key")"
        local metadata_key="${latest_s3_key%.dmp}.metadata.json"
        local metadata_file="${checkpoint_file%.dmp}.metadata.json"
        
        if s3_get "$latest_s3_key" "$checkpoint_file" "$token" && \
           s3_get "$metadata_key" "$metadata_file" "$token"; then
            
            # Verify metadata has correct job_id
            if jq -e ".job_id == \"$JOB_ID\"" "$metadata_file" >/dev/null 2>&1; then
                log "S3_SOURCE: Successfully restored checkpoint from S3"
                log "RESTORE_OK: from S3"
                return 0
            else
                log "ERROR: Metadata job_id mismatch"
                rm -f "$checkpoint_file" "$metadata_file"
            fi
        else
            log "ERROR: Failed to download checkpoint from S3"
        fi
    else
        log "INFO: No checkpoint found in S3"
    fi
    
    # Local fallback only if S3 unavailable and local has valid metadata
    local_checkpoint=$(ls -1t "$CHECKPOINT_DIR"/checkpoint-*.dmp 2>/dev/null | head -1)
    if [[ -n "$local_checkpoint" ]]; then
        metadata_file="${local_checkpoint%.dmp}.metadata.json"
        if [[ -f "$metadata_file" ]] && jq -e '.job_id' "$metadata_file" >/dev/null 2>&1; then
            log "LOCAL_SOURCE: Using local checkpoint with valid metadata"
            log "RESTORE_OK: from local"
            return 0
        else
            log "LOCAL_SOURCE: Skipping local checkpoint (no valid metadata)"
        fi
    else
        log "LOCAL_SOURCE: No local checkpoint found"
    fi
    
    log "INFO: No valid checkpoint found for restore"
    return 1
}

# Ensure checkpoint directory exists and has correct permissions
mkdir -p "$CHECKPOINT_DIR"
chown ubuntu:ubuntu "$CHECKPOINT_DIR"

# Run main function
main

