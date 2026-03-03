#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HELPER="${SCRIPT_DIR}/dxnn-config.sh"
if [[ -f "$CONFIG_HELPER" ]]; then
    # shellcheck disable=SC1090
    # shellcheck source=scripts/dxnn-config.sh
    source "$CONFIG_HELPER"
else
    echo "DXNN configuration helper not found: $CONFIG_HELPER" >&2
    exit 1
fi

# Optional environment overrides
if [[ -f /etc/dxnn-env ]]; then
    # shellcheck disable=SC1091
    source /etc/dxnn-env
fi

load_dxnn_config

dxnn_assign_default CHECKPOINT_DEADLINE "${DXNN_CFG_CHECKPOINT_DEADLINE:-60}" "60"
dxnn_assign_default POLL_INTERVAL "${DXNN_CFG_POLL_INTERVAL:-4}" "4"
dxnn_assign_default S3_BUCKET "${DXNN_CFG_S3_BUCKET:-dxnn-checkpoints}" "dxnn-checkpoints"
dxnn_assign_default S3_PREFIX "${DXNN_CFG_S3_PREFIX:-dxnn}" "dxnn"
dxnn_assign_default JOB_ID "${DXNN_CFG_JOB_ID:-dxnn-training-001}" "dxnn-training-001"
dxnn_assign_default CONTAINER_NAME "${DXNN_CFG_CONTAINER_NAME:-dxnn-app}" "dxnn-app"
dxnn_assign_default ERLANG_NODE "${DXNN_CFG_ERLANG_NODE:-dxnn@127.0.0.1}" "dxnn@127.0.0.1"
dxnn_assign_default ERLANG_COOKIE_FILE "${DXNN_CFG_ERLANG_COOKIE_FILE:-/var/lib/dxnn/.erlang.cookie}" "/var/lib/dxnn/.erlang.cookie"
dxnn_assign_default AUTO_TERMINATE_DEFAULT "${DXNN_CFG_AUTO_TERMINATE:-false}" "false"
dxnn_assign_default AUTO_TERMINATE "${DXNN_CFG_AUTO_TERMINATE:-false}" "false"
dxnn_assign_default USE_REBALANCE "${DXNN_CFG_USE_REBALANCE:-false}" "false"

dxnn_finalize_int CHECKPOINT_DEADLINE "${DXNN_CFG_CHECKPOINT_DEADLINE:-60}"
dxnn_finalize_int POLL_INTERVAL "${DXNN_CFG_POLL_INTERVAL:-4}"
dxnn_finalize_bool AUTO_TERMINATE_DEFAULT "${DXNN_CFG_AUTO_TERMINATE:-false}"
dxnn_finalize_bool AUTO_TERMINATE "${DXNN_CFG_AUTO_TERMINATE:-false}"
dxnn_finalize_bool USE_REBALANCE "${DXNN_CFG_USE_REBALANCE:-false}"

CHECKPOINT_DIR="/var/lib/dxnn/checkpoints"
LOG_FILE="/var/log/spot-watch.log"
LOCK_FILE="/run/dxnn_spot_triggered"

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
    export AUTO_TERMINATE="${AUTO_TERMINATE:-$AUTO_TERMINATE_DEFAULT}"
    export AUTO_TERMINATE_DEFAULT
    
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
