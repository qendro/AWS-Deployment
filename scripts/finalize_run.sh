#!/bin/bash
# Finalizer script for DXNN spot instance (consolidated, formerly finalize_run_simple.sh)
# ...existing code from finalize_run_simple.sh...

set -euo pipefail

# Configuration
LOCK_FILE="/var/lock/dxnn.finalize.lock"
LOG_FILE="/var/log/dxnn-run.log"
COMPLETION_STATUS="${COMPLETION_STATUS:-unknown}"
EXIT_CODE="${EXIT_CODE:-1}"
MANIFEST_FILE="/tmp/dxnn_manifest.txt"

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

# Check if S3 sentinel already exists using simple-s3-download.sh
check_s3_sentinel() {
    local s3_key="$S3_PREFIX/$JOB_ID/$RUN_ID/_SUCCESS"
    local temp_file="/tmp/_SUCCESS_check"
    
    if /usr/local/bin/simple-s3-download.sh "$s3_key" "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        log "INFO" "S3 sentinel already exists at s3://$S3_BUCKET/$s3_key - finalization already completed"
        return 0
    fi
    rm -f "$temp_file" 2>/dev/null || true
    return 1
}

# Upload single file to S3 with exponential backoff
upload_file_to_s3() {
    local source_file="$1"
    local s3_key="$2"
    
    for attempt in $(seq 0 $((MAX_RETRIES - 1))); do
        log "INFO" "S3 upload attempt $((attempt + 1))/$MAX_RETRIES: $s3_key"
        
        if /usr/local/bin/simple-s3-upload.sh "$source_file" "$s3_key"; then
            log "INFO" "S3 upload successful: $s3_key"
            return 0
        fi
        
        if [[ $attempt -lt $((MAX_RETRIES - 1)) ]]; then
            local delay=${RETRY_DELAYS[$attempt]}
            log "WARN" "S3 upload failed, retrying in ${delay}s..."
            sleep "$delay"
        fi
    done
    
    log "ERROR" "S3 upload failed after $MAX_RETRIES attempts: $s3_key"
    return 1
}

# Upload directory contents to S3 recursively
upload_directory_to_s3() {
    local source_dir="$1"
    local s3_prefix="$2"
    local failed_files=()

    log "INFO" "Starting directory upload: $source_dir -> s3://$S3_BUCKET/$s3_prefix"

    # Reset manifest file
    : > "$MANIFEST_FILE"

    # Find all files in directory (excluding _SUCCESS and _FAILED_UPLOAD)
    while IFS= read -r -d '' file; do
        local relative_path="${file#$source_dir/}"
        local s3_key="$s3_prefix/$relative_path"
        
        # Skip sentinel files
        if [[ "$relative_path" == "_SUCCESS" || "$relative_path" == "_FAILED_UPLOAD" ]]; then
            continue
        fi
        
        if upload_file_to_s3 "$file" "$s3_key"; then
            local file_mode
            file_mode=$(stat -c '%a' "$file" 2>/dev/null || echo '0644')
            printf '%s\t%s\n' "$file_mode" "$relative_path" >> "$MANIFEST_FILE"
        else
            failed_files+=("$relative_path")
        fi
    done < <(find "$source_dir" -type f -print0)

    if [[ ${#failed_files[@]} -eq 0 ]]; then
        log "INFO" "All files uploaded successfully"
        return 0
    else
        log "ERROR" "Failed to upload ${#failed_files[@]} files: ${failed_files[*]}"
        rm -f "$MANIFEST_FILE"
        return 1
    fi
}

# Create and upload S3 sentinel with metadata
create_s3_sentinel() {
    local status="$1"
    local sentinel_file="/tmp/_SUCCESS"
    local s3_key="$S3_PREFIX/$JOB_ID/$RUN_ID/_SUCCESS"
    
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
    if upload_file_to_s3 "$sentinel_file" "$s3_key"; then
        log "INFO" "S3 sentinel created successfully at s3://$S3_BUCKET/$s3_key"
        rm -f "$sentinel_file"
        return 0
    else
        log "ERROR" "Failed to create S3 sentinel"
        rm -f "$sentinel_file"
        return 1
    fi
}

# Update pointer to latest successful run
update_latest_pointer() {
    local pointer_file="/tmp/_LATEST_RUN"
    local s3_key="$S3_PREFIX/$JOB_ID/_LATEST_RUN"

    cat > "$pointer_file" << EOF
{
    "run_id": "$RUN_ID",
    "updated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

    if upload_file_to_s3 "$pointer_file" "$s3_key"; then
        log "INFO" "LATEST_PTR_UPDATED - Updated pointer to $RUN_ID"
    else
        log "WARN" "LATEST_PTR_FAILED - Could not update latest run pointer"
    fi

    rm -f "$pointer_file"
}

# Upload manifest describing artifacts
upload_manifest() {
    local s3_manifest_key="$S3_PREFIX/$JOB_ID/$RUN_ID/_MANIFEST"

    if [[ ! -s "$MANIFEST_FILE" ]]; then
        log "WARN" "MANIFEST_EMPTY - No files recorded in manifest"
        return 1
    fi

    if upload_file_to_s3 "$MANIFEST_FILE" "$s3_manifest_key"; then
        log "INFO" "MANIFEST_UPLOADED - Stored at s3://$S3_BUCKET/$s3_manifest_key"
        return 0
    fi

    log "ERROR" "MANIFEST_UPLOAD_FAILED"
    return 1
}

# Create failure sentinel
create_failure_sentinel() {
    local sentinel_file="/tmp/_FAILED_UPLOAD"
    local s3_key="$S3_PREFIX/$JOB_ID/$RUN_ID/_FAILED_UPLOAD"
    
    cat > "$sentinel_file" << EOF
{
    "run_id": "$RUN_ID",
    "failed_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "completion_status": "$COMPLETION_STATUS",
    "exit_code": $EXIT_CODE,
    "error": "s3_upload_failed"
}
EOF
    
    upload_file_to_s3 "$sentinel_file" "$s3_key" || true
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
    local dxnn_dir="/home/ubuntu/dxnn-trader"
    if [[ ! -d "$dxnn_dir" ]]; then
        dxnn_dir="/opt/dxnn"
    fi
    
    if [[ ! -d "$dxnn_dir" ]]; then
        log "ERROR" "DXNN directory not found. Checked: /home/ubuntu/dxnn-trader and /opt/dxnn"
        log "INFO" "Available directories in /home/ubuntu: $(ls -la /home/ubuntu/ 2>/dev/null || echo 'Permission denied')"
        return 1
    fi
    
    log "INFO" "Using DXNN directory: $dxnn_dir"
    
    # Upload artifacts
    local s3_prefix="$S3_PREFIX/$JOB_ID/$RUN_ID"
    if upload_directory_to_s3 "$dxnn_dir" "$s3_prefix"; then
        # Upload logs
        if [[ -f "$LOG_FILE" ]]; then
            upload_file_to_s3 "$LOG_FILE" "$s3_prefix/dxnn-run.log" || true
        fi

        # Upload manifest (includes files copied from directory upload)
        if ! upload_manifest; then
            log "ERROR" "FINALIZE_FAILED - Manifest upload failed"
            create_failure_sentinel
            return 1
        fi
        
        # Create success sentinel
        if create_s3_sentinel "success"; then
            update_latest_pointer
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
        rm -f "$MANIFEST_FILE"
        log "INFO" "TERMINATING - Powering off instance"
        if [[ "${SAFE_MODE:-}" == "true" ]]; then
            log "INFO" "SAFE_MODE enabled - would poweroff here"
        else
            poweroff
        fi
    else
        rm -f "$MANIFEST_FILE"
        log "ERROR" "FINALIZE_FAILED - Powering off instance anyway"
        if [[ "${SAFE_MODE:-}" == "true" ]]; then
            log "INFO" "SAFE_MODE enabled - would poweroff here"
        else
            poweroff
        fi
    fi
}

# Execute main function
main "$@"
