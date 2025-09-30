#!/bin/bash
# Finalizer script for DXNN spot instance (consolidated, formerly finalize_run_simple.sh)
# ...existing code from finalize_run_simple.sh...

set -euo pipefail

# Optional environment overrides
if [[ -f /etc/dxnn-env ]]; then
    # shellcheck disable=SC1091
    source /etc/dxnn-env
fi

# Configuration
AWS_CLI_BIN="${AWS_CLI_BIN:-aws}"
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

# Artifacts to capture from the DXNN workspace
ARTIFACT_DIRS=("Mnesia.nonode@nohost" "logs")
ARTIFACT_FILES=("config.erl")
AUTO_TERMINATE_DEFAULT="${AUTO_TERMINATE_DEFAULT:-true}"

# Optional region handling for AWS CLI
AWS_REGION_HINT="${AWS_REGION:-${AWS_DEFAULT_REGION:-${S3_REGION:-}}}"
AWS_S3_ARGS=(--no-progress)
if [[ -n "$AWS_REGION_HINT" ]]; then
    AWS_S3_ARGS+=(--region "$AWS_REGION_HINT")
fi
AWS_CLI_INSTALL_DIR="${AWS_CLI_INSTALL_DIR:-/usr/local/aws-cli}"
AWS_CLI_BIN_DIR="${AWS_CLI_BIN_DIR:-/usr/local/bin}"

# Ensure AWS CLI is present before doing any work
run_privileged() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        log "ERROR" "Privileged command requires root or sudo: $*"
        return 1
    fi
}

wait_for_aws_cli() {
    local attempts=0
    local max_attempts=${AWS_CLI_WAIT_ATTEMPTS:-12}
    local sleep_seconds=${AWS_CLI_WAIT_SECONDS:-5}

    while (( attempts < max_attempts )); do
        if command -v "$AWS_CLI_BIN" >/dev/null 2>&1; then
            return 0
        fi

        attempts=$((attempts + 1))
        log "INFO" "Waiting for AWS CLI to become available (attempt $attempts/$max_attempts)"
        sleep "$sleep_seconds"
        hash -r
    done

    return 1
}

install_aws_cli_bundle() {
    local arch url tmp_dir zip_path
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
            ;;
        aarch64|arm64)
            url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
            ;;
        *)
            log "WARN" "Unsupported architecture for AWS CLI bundle: $arch"
            return 1
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        log "ERROR" "curl is required to download the AWS CLI bundle"
        return 1
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        log "INFO" "Installing unzip dependency for AWS CLI bundle"
        if command -v apt-get >/dev/null 2>&1; then
            run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y unzip >> "$LOG_FILE" 2>&1 || return 1
        elif command -v yum >/dev/null 2>&1; then
            run_privileged yum install -y unzip >> "$LOG_FILE" 2>&1 || return 1
        else
            log "ERROR" "No supported package manager found to install unzip"
            return 1
        fi
    fi

    tmp_dir=$(mktemp -d)
    if [[ -z "$tmp_dir" || ! -d "$tmp_dir" ]]; then
        log "ERROR" "Failed to create temporary directory for AWS CLI install"
        return 1
    fi

    zip_path="$tmp_dir/awscliv2.zip"
    if ! curl -Ls "$url" -o "$zip_path" >> "$LOG_FILE" 2>&1; then
        log "ERROR" "Failed to download AWS CLI bundle from $url"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! unzip -q "$zip_path" -d "$tmp_dir" >> "$LOG_FILE" 2>&1; then
        log "ERROR" "Failed to extract AWS CLI bundle"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! run_privileged "$tmp_dir/aws/install" --bin-dir "$AWS_CLI_BIN_DIR" --install-dir "$AWS_CLI_INSTALL_DIR" --update >> "$LOG_FILE" 2>&1; then
        log "ERROR" "AWS CLI bundle installer failed"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
    hash -r
    log "INFO" "AWS CLI bundle installed successfully"
    return 0
}

require_aws_cli() {
    if wait_for_aws_cli; then
        return 0
    fi

    log "WARN" "AWS CLI not found - attempting automatic installation"
    local installed=false

    if command -v apt-get >/dev/null 2>&1; then
        if run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$LOG_FILE" 2>&1 && \
           run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y awscli >> "$LOG_FILE" 2>&1; then
            hash -r
            installed=true
        else
            log "INFO" "apt-get install awscli failed or package unavailable; falling back"
        fi
    elif command -v yum >/dev/null 2>&1; then
        if run_privileged yum install -y awscli >> "$LOG_FILE" 2>&1; then
            hash -r
            installed=true
        else
            log "INFO" "yum install awscli failed; falling back"
        fi
    fi

    if [[ $installed == false ]]; then
        install_aws_cli_bundle && installed=true
    fi

    if wait_for_aws_cli; then
        if [[ $installed == true ]]; then
            log "INFO" "AWS CLI installed successfully"
        fi
        return 0
    fi

    log "ERROR" "AWS CLI not found. Install awscli or set AWS_CLI_BIN"
    exit 1
}

aws_s3_cp() {
    "$AWS_CLI_BIN" s3 cp "$@" "${AWS_S3_ARGS[@]}"
}

resolve_auto_terminate() {
    local value="${AUTO_TERMINATE:-}";
    if [[ -z "$value" ]]; then
        value="$AUTO_TERMINATE_DEFAULT"
    fi

    value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')

    case "$value" in
        true|1|yes|on)
            echo "true"
            ;;
        false|0|no|off)
            echo "false"
            ;;
        *)
            if [[ "${SAFE_MODE:-}" == "true" ]]; then
                echo "false"
            else
                echo "true"
            fi
            ;;
    esac
}

# Retry configuration
MAX_RETRIES=7
RETRY_DELAYS=(1 2 4 8 16 32 64)

# Logging function with UTC timestamps
log() {
    local level="$1"
    shift
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $level: $*" | tee -a "$LOG_FILE"
}

enumerate_artifacts() {
    local base_dir="$1"
    local rel path

    for rel in "${ARTIFACT_DIRS[@]}"; do
        path="$base_dir/$rel"
        if [[ -d "$path" ]]; then
            while IFS= read -r -d '' file; do
                printf '%s\0' "$file"
            done < <(find "$path" -type f -print0)
        else
            log "INFO" "Artifact directory missing, skipping: $rel"
        fi
    done

    for rel in "${ARTIFACT_FILES[@]}"; do
        path="$base_dir/$rel"
        if [[ -f "$path" ]]; then
            printf '%s\0' "$path"
        else
            log "INFO" "Artifact file missing, skipping: $rel"
        fi
    done
}

# Check if required environment variables are set
check_config() {
    if [[ -z "$S3_BUCKET" || -z "$JOB_ID" || -z "$RUN_ID" ]]; then
        log "ERROR" "Missing required configuration: S3_BUCKET=$S3_BUCKET JOB_ID=$JOB_ID RUN_ID=$RUN_ID"
        exit 1
    fi

    require_aws_cli
}

# Check if S3 sentinel already exists using AWS CLI
check_s3_sentinel() {
    local s3_key="$S3_PREFIX/$JOB_ID/$RUN_ID/_SUCCESS"
    local temp_file="/tmp/_SUCCESS_check"

    if aws_s3_cp "s3://$S3_BUCKET/$s3_key" "$temp_file" >/dev/null 2>&1; then
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

        if aws_s3_cp "$source_file" "s3://$S3_BUCKET/$s3_key" >/dev/null 2>&1; then
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

# Upload selected artifacts to S3
upload_selected_artifacts() {
    local source_dir="$1"
    local s3_prefix="$2"
    local failed_files=()
    local uploaded_count=0

    log "INFO" "Uploading selected artifacts from $source_dir -> s3://$S3_BUCKET/$s3_prefix"

    : > "$MANIFEST_FILE"

    while IFS= read -r -d '' file; do
        local relative_path="${file#$source_dir/}"
        if [[ "$relative_path" == "$file" ]]; then
            relative_path="$(basename "$file")"
        fi
        relative_path="${relative_path##/}"
        [[ -z "$relative_path" ]] && continue

        local s3_key="$s3_prefix/$relative_path"
        if upload_file_to_s3 "$file" "$s3_key"; then
            local file_mode
            file_mode=$(stat -c '%a' "$file" 2>/dev/null || echo '0644')
            printf '%s\t%s\n' "$file_mode" "$relative_path" >> "$MANIFEST_FILE"
            uploaded_count=$((uploaded_count + 1))
        else
            failed_files+=("$relative_path")
        fi
    done < <(enumerate_artifacts "$source_dir")

    if [[ ${#failed_files[@]} -ne 0 ]]; then
        log "ERROR" "Failed to upload ${#failed_files[@]} artifacts: ${failed_files[*]}"
        rm -f "$MANIFEST_FILE"
        return 1
    fi

    if [[ $uploaded_count -eq 0 ]]; then
        log "WARN" "No artifacts matched the selection; skipping artifact upload"
        return 0
    fi

    log "INFO" "Uploaded $uploaded_count artifact files"
    return 0
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
        log "INFO" "MANIFEST_EMPTY - No files recorded; skipping manifest upload"
        return 0
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
    if upload_selected_artifacts "$dxnn_dir" "$s3_prefix"; then
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

    local finalize_status="success"
    if finalize; then
        rm -f "$MANIFEST_FILE"
        log "INFO" "FINALIZE_COMPLETE - Artifacts processed (status: $COMPLETION_STATUS)"
    else
        rm -f "$MANIFEST_FILE"
        finalize_status="failure"
        log "ERROR" "FINALIZE_FAILED - Encountered errors during finalization"
    fi

    local auto_terminate
    auto_terminate=$(resolve_auto_terminate)

    log "INFO" "AUTO_TERMINATE_DEFAULT=$AUTO_TERMINATE_DEFAULT AUTO_TERMINATE_ENV=${AUTO_TERMINATE:-} SAFE_MODE=${SAFE_MODE:-} RESOLVED_AUTO_TERMINATE=$auto_terminate"

    if [[ "${SAFE_MODE:-}" == "true" ]]; then
        auto_terminate="false"
        log "INFO" "SAFE_MODE enabled - skipping poweroff"
    fi

    if [[ "$auto_terminate" != "true" ]]; then
        log "INFO" "AUTO_TERMINATE disabled - instance will remain running"
        if [[ "$finalize_status" == "failure" ]]; then
            return 1
        fi
        return 0
    fi

    log "INFO" "AUTO_TERMINATE enabled - powering off instance"
    if ! run_privileged poweroff; then
        log "ERROR" "Poweroff command failed; attempting shutdown fallback"
        run_privileged shutdown -h now || log "ERROR" "Shutdown fallback also failed"
    fi
}

# Execute main function
main "$@"
