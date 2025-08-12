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
    local role_name
    role_name=$(curl -s "$IMDS/latest/meta-data/iam/security-credentials/")
    if [[ -z "$role_name" ]]; then
        log "ERROR: No IAM role found"
        return 1
    fi
    
    local credentials
    credentials=$(curl -s "$IMDS/latest/meta-data/iam/security-credentials/$role_name")
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

# Generate AWS Signature v4 for S3 PUT
s3_put_with_sigv4() {
    local file_path="$1"
    local s3_key="$2"
    
    # Get credentials
    if ! get_aws_credentials; then
        return 1
    fi
    
    local http_method="PUT"
    local service="s3"
    local region="us-east-1"  # Hardcoded for now
    local host="$S3_BUCKET.s3.amazonaws.com"
    local endpoint="https://$host"
    
    # File info
    local content_type="application/octet-stream"
    local content_length
    content_length=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    
    # Timestamps
    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    local date_stamp
    date_stamp=$(date -u +%Y%m%d)
    
    # Canonical request
    local canonical_uri="/$s3_key"
    local canonical_querystring=""
    local canonical_headers="content-length:$content_length"$'\n'"content-type:$content_type"$'\n'"host:$host"$'\n'"x-amz-date:$timestamp"
    if [[ -n "$SESSION_TOKEN" ]]; then
        canonical_headers="$canonical_headers"$'\n'"x-amz-security-token:$SESSION_TOKEN"
    fi
    canonical_headers="$canonical_headers"$'\n'
    
    local signed_headers="content-length;content-type;host;x-amz-date"
    if [[ -n "$SESSION_TOKEN" ]]; then
        signed_headers="$signed_headers;x-amz-security-token"
    fi
    
    local payload_hash
    payload_hash=$(sha256 "$(cat "$file_path")")
    
    local canonical_request="$http_method"$'\n'"$canonical_uri"$'\n'"$canonical_querystring"$'\n'"$canonical_headers"$'\n'"$signed_headers"$'\n'"$payload_hash"
    
    # String to sign
    local algorithm="AWS4-HMAC-SHA256"
    local credential_scope="$date_stamp/$region/$service/aws4_request"
    local string_to_sign="$algorithm"$'\n'"$timestamp"$'\n'"$credential_scope"$'\n'"$(sha256 "$canonical_request")"
    
    # Sign the string
    local k_date
    k_date=$(printf '%s' "$date_stamp" | openssl dgst -sha256 -hmac "AWS4$SECRET_ACCESS_KEY" -binary)
    local k_region
    k_region=$(printf '%s' "$region" | openssl dgst -sha256 -hmac "$k_date" -binary)
    local k_service
    k_service=$(printf '%s' "$service" | openssl dgst -sha256 -hmac "$k_region" -binary)
    local k_signing
    k_signing=$(printf '%s' "aws4_request" | openssl dgst -sha256 -hmac "$k_service" -binary)
    local signature
    signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -hmac "$k_signing" | cut -d' ' -f2)
    
    # Authorization header
    local authorization_header="$algorithm Credential=$ACCESS_KEY_ID/$credential_scope, SignedHeaders=$signed_headers, Signature=$signature"
    
    # Make the request
    local curl_headers=(
        "Content-Type: $content_type"
        "Content-Length: $content_length"
        "Host: $host"
        "X-Amz-Date: $timestamp"
        "Authorization: $authorization_header"
    )
    
    if [[ -n "$SESSION_TOKEN" ]]; then
        curl_headers+=("X-Amz-Security-Token: $SESSION_TOKEN")
    fi
    
    # Build curl command
    local curl_cmd="curl -s -w '%{http_code}' -X PUT"
    for header in "${curl_headers[@]}"; do
        curl_cmd="$curl_cmd -H '$header'"
    done
    curl_cmd="$curl_cmd --data-binary @$file_path '$endpoint$canonical_uri'"
    
    # Execute upload
    local response
    response=$(eval "$curl_cmd")
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        log "UPLOAD_OK: $s3_key"
        return 0
    else
        log "UPLOAD_FAIL: HTTP $http_code for $s3_key"
        return 1
    fi
}

# S3 upload with exact retry pattern (AWS Signature v4)
upload_checkpoint() {
    local checkpoint_file="$1"
    local s3_key="$2"
    
    for attempt in {1..3}; do
        if s3_put_with_sigv4 "$checkpoint_file" "$s3_key"; then
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
