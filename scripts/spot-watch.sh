#!/bin/bash
set -euo pipefail

# Configuration (templated from config)
CHECKPOINT_DEADLINE=60  # From IMDS detection
POLL_INTERVAL=2
S3_BUCKET="dxnn-checkpoints"
S3_PREFIX="dxnn"
JOB_ID="dxnn-training-001"
CONTAINER_NAME="dxnn-app"
ERLANG_NODE="dxnn@127.0.0.1"
ERLANG_COOKIE_FILE="/var/lib/dxnn/.erlang.cookie"
CHECKPOINT_DIR="/var/lib/dxnn/checkpoints"
LOG_FILE="/var/log/spot-watch.log"
LOCK_FILE="/run/dxnn_spot_triggered"
USE_REBALANCE=false

# IMDSv2
IMDS="http://169.254.169.254"
TOKEN_TTL=21600  # 6 hours

# Logging function with UTC timestamps
log() {
    echo "[UTC $(date -u -Iseconds)] $1" >> "$LOG_FILE"
}

# Single-shot protection with PID check
if [[ -f "$LOCK_FILE" ]]; then
    stored_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$stored_pid" ]] && kill -0 "$stored_pid" 2>/dev/null; then
        log "Already triggered by PID $stored_pid, exiting"
        exit 0
    else
        log "Removing stale lock file from PID $stored_pid"
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file with current PID
echo "$$" > "$LOCK_FILE"

# IMDSv2 token with TTL and refresh
get_token() {
    local token=""
    for i in {1..3}; do
        token=$(curl -sS -X PUT "$IMDS/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: $TOKEN_TTL" 2>/dev/null || true)
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
        sleep $((i * 2))
    done
    return 1
}

# Check for interruption signals with token refresh
check_interruption() {
    local token="$1"
    local response
    response=$(curl -sS -H "X-aws-ec2-metadata-token: $token" \
        "$IMDS/latest/meta-data/spot/instance-action" -f -w "%{http_code}" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        log "Token expired, refreshing..."
        return 2  # Signal to refresh token
    elif [[ "$http_code" == "200" ]]; then
        return 0  # Interruption detected
    else
        return 1  # No interruption
    fi
}

# Check for rebalance (optional, default OFF)
check_rebalance() {
    local token="$1"
    if [[ "$USE_REBALANCE" == "true" ]]; then
        local response
        response=$(curl -sS -H "X-aws-ec2-metadata-token: $token" \
            "$IMDS/latest/meta-data/events/recommendations/rebalance" -f -w "%{http_code}" 2>/dev/null || echo "000")
        
        local http_code="${response: -3}"
        if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
            return 2  # Signal to refresh token
        elif [[ "$http_code" == "200" ]]; then
            return 0  # Rebalance detected
        fi
    fi
    return 1  # No rebalance
}

# AWS Signature v4 helper functions
hex() {
    printf '%s' "$1" | od -A n -t x1 | tr -d ' \n'
}

sha256() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# Get AWS credentials from instance metadata
get_aws_credentials() {
    local token="$1"
    if [[ -z "$token" ]]; then
        log "ERROR: IMDSv2 token required"
        return 1
    fi
    
    local role_name
    role_name=$(curl -s -H "X-aws-ec2-metadata-token: $token" "$IMDS/latest/meta-data/iam/security-credentials/")
    if [[ -z "$role_name" ]]; then
        log "ERROR: No IAM role found"
        return 1
    fi
    
    local credentials
    credentials=$(curl -s -H "X-aws-ec2-metadata-token: $token" "$IMDS/latest/meta-data/iam/security-credentials/$role_name")
    if [[ -z "$credentials" ]]; then
        log "ERROR: Failed to get credentials for role: $role_name"
        return 1
    fi
    
    # Extract credentials using jq (should be available)
    ACCESS_KEY_ID=$(echo "$credentials" | jq -r '.AccessKeyId')
    SECRET_ACCESS_KEY=$(echo "$credentials" | jq -r '.SecretAccessKey')
    SESSION_TOKEN=$(echo "$credentials" | jq -r '.Token')
    
    if [[ "$ACCESS_KEY_ID" == "null" ]] || [[ "$SECRET_ACCESS_KEY" == "null" ]]; then
        log "ERROR: Invalid credentials response"
        return 1
    fi
    
    log "INFO: Got credentials for role: $role_name"
}

# Simple S3 upload wrapper using simple-s3-upload.sh
s3_put_with_sigv4() {
    local file_path="$1"
    local s3_key="$2"
    local token="$3"
    
    # Use the simple S3 upload script
    if /usr/local/bin/simple-s3-upload.sh "$file_path" "$s3_key"; then
        log "UPLOAD_OK: $s3_key"
        return 0
    else
        log "UPLOAD_FAIL: $s3_key"
        return 1
    fi
}
# S3 upload with exact retry pattern (AWS Signature v4)
upload_checkpoint() {
    local checkpoint_file="$1"
    local s3_key="$2"
    local token="$3"
    
    for attempt in {1..3}; do
        if s3_put_with_sigv4 "$checkpoint_file" "$s3_key" "$token"; then
            return 0
        fi
        log "UPLOAD_FAIL: attempt $attempt for $s3_key"
        if [[ $attempt -lt 3 ]]; then
            sleep $((2 ** (attempt - 1)))  # 1s, 2s, 4s backoff
        fi
    done
    
    log "UPLOAD_FAIL: all attempts failed for $s3_key"
    return 1
}

# Main polling loop
main() {
    log "STATE: STARTED"
    
    while true; do
        token=$(get_token || true)
        sleep "$POLL_INTERVAL"
        
        # Check for interruption (primary signal)
        if check_interruption "$token"; then
            log "STATE: DETECTED"
            break
        elif [[ $? -eq 2 ]]; then
            continue  # Token refresh needed
        fi
        
        # Check for rebalance (optional, default OFF)
        if check_rebalance "$token"; then
            log "STATE: DETECTED (rebalance)"
            break
        elif [[ $? -eq 2 ]]; then
            continue  # Token refresh needed
        fi
    done
    
    # Start checkpoint with deadline from detection
    log "STATE: CHECKPOINT_START"
    checkpoint_start_time=$(date +%s)
    
    # Call DXNN checkpoint via control script
    if timeout "$CHECKPOINT_DEADLINE" \
        /usr/local/bin/dxnn_ctl checkpoint; then
        log "STATE: CHECKPOINT_OK"
    else
        exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log "STATE: CHECKPOINT_TIMEOUT"
        else
            log "STATE: CHECKPOINT_ERROR (exit code: $exit_code)"
        fi
    fi
    
    # Call finalizer with interruption status
    log "STATE: FINALIZE_INTERRUPTION"
    
    # Set environment variables for finalizer
    export COMPLETION_STATUS="interrupted"
    export EXIT_CODE="1"
    export S3_BUCKET="$S3_BUCKET"
    export S3_PREFIX="$S3_PREFIX"
    export JOB_ID="$JOB_ID"
    export RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%SZ)}"
    
    # Call finalizer script (handles upload and termination)
    if [[ -x "/usr/local/bin/finalize_run.sh" ]]; then
        /usr/local/bin/finalize_run.sh
    else
        log "ERROR: Finalizer script not found, falling back to shutdown"
        shutdown -h now
    fi
}

# Cleanup on exit
trap 'rm -f "$LOCK_FILE"' EXIT
main "$@"
