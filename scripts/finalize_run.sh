#!/bin/bash

# AWS Spot Instance Finalizer Script
# Handles both completion and interruption scenarios with idempotency
# Uses lock-based protection and S3 sentinel checking

set -euo pipefail

# Configuration
LOCK_FILE="/var/lock/dxnn.finalize.lock"
LOG_FILE="/var/log/dxnn-run.log"
COMPLETION_STATUS="${COMPLETION_STATUS:-unknown}"
EXIT_CODE="${EXIT_CODE:-1}"

# S3 Configuration (from environment or config)
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-dxnn}"
JOB_ID="${JOB_ID:-}"
RUN_ID="${RUN_ID:-}"

# Retry configuration
MAX_RETRIES=7
RETRY_DELAYS=(1 2 4 8 16 32 64)

# Logging function with UTC timestamps
log() {
    local level="$1"
    shift
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $level: $*" | tee -a "$LOG_FILE"
}

# Check if required environment variables are set
check_config() {
    if [[ -z "$S3_BUCKET" || -z "$JOB_ID" || -z "$RUN_ID" ]]; then
        log "ERROR" "Missing required configuration: S3_BUCKET=$S3_BUCKET JOB_ID=$JOB_ID RUN_ID=$RUN_ID"
        exit 1
    fi
}

# Check if S3 sentinel already exists
check_s3_sentinel() {
    local s3_path="s3://$S3_BUCKET/$S3_PREFIX/$JOB_ID/$RUN_ID/_SUCCESS"
    
    if aws s3 ls "$s3_path" >/dev/null 2>&1; then
        log "INFO" "S3 sentinel already exists at $s3_path - finalization already completed"
        return 0
    fi
    return 1
}

# Upload files to S3 with exponential backoff
upload_to_s3() {
    local source_dir="$1"
    local s3_path="s3://$S3_BUCKET/$S3_PREFIX/$JOB_ID/$RUN_ID/"
    
    for attempt in $(seq 0 $((MAX_RETRIES - 1))); do
        log "INFO" "S3 upload attempt $((attempt + 1))/$MAX_RETRIES to $s3_path"
        
        if aws s3 sync "$source_dir" "$s3_path" --exclude "_SUCCESS" --exclude "_FAILED_UPLOAD"; then
            log "INFO" "S3 upload successful"
            return 0
        fi
        
        if [[ $attempt -lt $((MAX_RETRIES - 1)) ]]; then
            local delay=${RETRY_DELAYS[$attempt]}
            log "WARN" "S3 upload failed, retrying in ${delay}s..."
            sleep "$delay"
        fi
    done
    
    log "ERROR" "S3 upload failed after $MAX_RETRIES attempts"
    return 1
}

# Create and upload S3 sentinel with metadata
create_s3_sentinel() {
    local status="$1"
    local sentinel_file="/tmp/_SUCCESS"
    local s3_path="s3://$S3_BUCKET/$S3_PREFIX/$JOB_ID/$RUN_ID/_SUCCESS"
    
    # Create sentinel with metadata
    cat > "$sentinel_file" << EOF
{
    "run_id": "$RUN_ID",
    "finalized_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "status": "$status",
    "completion_status": "$COMPLETION_STATUS",
    "exit_code": $EXIT_CODE,
    "reason": "$(if [[ "$COMPLETION_STATUS" == "normal" ]]; then echo "training_completed"; else echo "spot_interruption"; fi)"
}
EOF
    
    # Upload sentinel
    if aws s3 cp "$sentinel_file" "$s3_path"; then
        log "INFO" "S3 sentinel created successfully at $s3_path"
        rm -f "$sentinel_file"
        return 0
    else
        log "ERROR" "Failed to create S3 sentinel"
        rm -f "$sentinel_file"
        return 1
    fi
}

# Create failure sentinel
create_failure_sentinel() {
    local sentinel_file="/tmp/_FAILED_UPLOAD"
    local s3_path="s3://$S3_BUCKET/$S3_PREFIX/$JOB_ID/$RUN_ID/_FAILED_UPLOAD"
    
    cat > "$sentinel_file" << EOF
{
    "run_id": "$RUN_ID",
    "failed_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "completion_status": "$COMPLETION_STATUS",
    "exit_code": $EXIT_CODE,
    "error": "s3_upload_failed"
}
EOF
    
    aws s3 cp "$sentinel_file" "$s3_path" || true
    rm -f "$sentinel_file"
}

# Main finalization logic
finalize() {
    log "INFO" "FINALIZE_START - Status: $COMPLETION_STATUS, Exit Code: $EXIT_CODE"
    
    # Check configuration
    check_config
    
    # Check if already finalized
    if check_s3_sentinel; then
        log "INFO" "FINALIZE_ALREADY_COMPLETED - Exiting"
        return 0
    fi
    
    # Find DXNN directory and artifacts
    local dxnn_dir="/opt/dxnn"
    if [[ ! -d "$dxnn_dir" ]]; then
        dxnn_dir="/home/ubuntu/DXNN_test_v2"
    fi
    
    if [[ ! -d "$dxnn_dir" ]]; then
        log "ERROR" "DXNN directory not found"
        return 1
    fi
    
    # Upload artifacts
    if upload_to_s3 "$dxnn_dir"; then
        # Upload logs
        if [[ -f "$LOG_FILE" ]]; then
            aws s3 cp "$LOG_FILE" "s3://$S3_BUCKET/$S3_PREFIX/$JOB_ID/$RUN_ID/dxnn-run.log" || true
        fi
        
        # Create success sentinel
        if create_s3_sentinel "success"; then
            log "INFO" "FINALIZE_SUCCESS - All artifacts uploaded"
            return 0
        else
            log "ERROR" "FINALIZE_FAILED - Sentinel creation failed"
            return 1
        fi
    else
        log "ERROR" "UPLOAD_FAIL - Creating failure sentinel"
        create_failure_sentinel
        log "ERROR" "FINALIZE_FAILED - Upload failed"
        return 1
    fi
}

# Main execution with lock protection
main() {
    # Acquire exclusive lock
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "INFO" "Another finalization process is running - exiting"
        exit 0
    fi
    
    # Run finalization
    if finalize; then
        log "INFO" "TERMINATING - Powering off instance"
        poweroff
    else
        log "ERROR" "FINALIZE_FAILED - Powering off instance anyway"
        poweroff
    fi
}

# Execute main function
main "$@"