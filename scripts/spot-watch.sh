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

# S3 upload with exact retry pattern (placeholder for AWS Signature v4)
upload_checkpoint() {
    local checkpoint_file="$1"
    local s3_key="$2"
    
    # For now, just log the upload attempt
    # In production, this would use AWS Signature v4 with curl
    log "INFO: Would upload $checkpoint_file to s3://$S3_BUCKET/$s3_key"
    log "INFO: Using IAM instance profile for authentication"
    
    # Simulate successful upload for testing
    log "UPLOAD_OK: $s3_key (simulated)"
    return 0
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
    
    # Find latest checkpoint
    latest_checkpoint=$(ls -1t "$CHECKPOINT_DIR"/checkpoint-*.dmp 2>/dev/null | head -1)
    
    if [[ -n "$latest_checkpoint" ]]; then
        # Create metadata with required fields
        instance_id=$(curl -s "$IMDS/latest/meta-data/instance-id")
        timestamp=$(date -u -Iseconds)Z
        metadata_file="${latest_checkpoint%.dmp}.metadata.json"
        
        cat > "$metadata_file" << EOF
{
    "job_id": "$JOB_ID",
    "instance_id": "$instance_id",
    "action": "interruption",
    "utc": "$timestamp",
    "version": "1.0"
}
EOF
        
        # Upload to S3 with deterministic keying (UTC with trailing Z)
        s3_key="$S3_PREFIX/$JOB_ID/$(date -u +%Y/%m/%d/%H%M%SZ)/$(basename "$latest_checkpoint")"
        metadata_key="$S3_PREFIX/$JOB_ID/$(date -u +%Y/%m/%d/%H%M%SZ)/$(basename "$metadata_file")"
        
        upload_checkpoint "$latest_checkpoint" "$s3_key" || true
        upload_checkpoint "$metadata_file" "$metadata_key" || true
    else
        log "No checkpoint file found"
    fi
    
    # Graceful shutdown
    log "STATE: SHUTDOWN"
    shutdown -h now
}

# Cleanup on exit
trap 'rm -f "$LOCK_FILE"' EXIT
main "$@"
