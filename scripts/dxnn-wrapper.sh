#!/bin/bash

# DXNN Minimal Wrapper Script
# Runs DXNN inside tmux so existing control scripts continue to work
# Calls finalizer with proper exit code and completion status

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


# Optional environment overrides (legacy)
if [[ -f /etc/dxnn-env ]]; then
        # shellcheck disable=SC1091
        source /etc/dxnn-env
fi

load_dxnn_config

dxnn_assign_default S3_BUCKET "${DXNN_CFG_S3_BUCKET:-dxnn-checkpoints}" "dxnn-checkpoints"
dxnn_assign_default S3_PREFIX "${DXNN_CFG_S3_PREFIX:-dxnn}" "dxnn"
dxnn_assign_default RESTORE_FROM_S3 "${DXNN_CFG_RESTORE_FROM_S3:-false}" "false"
dxnn_assign_default AUTO_TERMINATE "${DXNN_CFG_AUTO_TERMINATE:-false}" "false"
dxnn_assign_default AUTO_TERMINATE_DEFAULT "${DXNN_CFG_AUTO_TERMINATE:-false}" "false"

dxnn_finalize_bool RESTORE_FROM_S3 "${DXNN_CFG_RESTORE_FROM_S3:-false}"
dxnn_finalize_bool AUTO_TERMINATE "${DXNN_CFG_AUTO_TERMINATE:-false}"
dxnn_finalize_bool AUTO_TERMINATE_DEFAULT "${DXNN_CFG_AUTO_TERMINATE:-false}"

AUTO_TERMINATE="${AUTO_TERMINATE:-$DXNN_CFG_AUTO_TERMINATE}"
AUTO_TERMINATE_DEFAULT="$AUTO_TERMINATE"

export S3_BUCKET S3_PREFIX RESTORE_FROM_S3 AUTO_TERMINATE AUTO_TERMINATE_DEFAULT

# Configuration
LOG_FILE="/var/log/dxnn-run.log"
DXNN_DIR="/home/ubuntu/dxnn-trader"
FINALIZER_SCRIPT="/usr/local/bin/finalize_run.sh"
TMUX_SESSION="trader"
SESSION_EXIT_CODE_FILE="/tmp/dxnn_exit_code"
TMUX_RUNNER_SCRIPT="/tmp/dxnn_tmux_runner.sh"

export RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%SZ)}"
export POPULATION_ID="${POPULATION_ID:-unknown}"

# Logging function with UTC timestamps
log() {
    local level="$1"
    shift
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $level: $*" | tee -a "$LOG_FILE"
}

# Signal handler for TERM/INT - forward to tmux session
cleanup() {
    log "INFO" "WRAPPER_SIGNAL_RECEIVED - Forwarding to tmux session"
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux send-keys -t "$TMUX_SESSION" C-c 2>/dev/null || true
        sleep 2
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    fi
}

# Set up signal traps
trap cleanup TERM INT

create_tmux_runner() {
    cat > "$TMUX_RUNNER_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail

log_runner() {
    printf '[%s] INFO: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$LOG_FILE"
}

# Extract population_id from Erlang output if available
extract_population_id() {
    if [[ -f "$LOG_FILE" ]]; then
        # Look for population_id in logs (format: population_id=<<"2025-02-11T15-30-45Z_a3f9_run1">>)
        local pop_id=$(grep -oP 'population_id=<<"\K[^"]+' "$LOG_FILE" 2>/dev/null | tail -1)
        if [[ -n "$pop_id" ]]; then
            echo "$pop_id"
            return 0
        fi
    fi
    echo "unknown"
}

log_runner "TMUX_SESSION_START - Starting DXNN training"
cd "$DXNN_DIR"

# Get Erlang cookie for distributed access
ERLANG_COOKIE=""
if [[ -f "/var/lib/dxnn/.erlang.cookie" ]]; then
    ERLANG_COOKIE=$(cat /var/lib/dxnn/.erlang.cookie)
fi

# Get hostname for node name
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

# Start with distributed Erlang enabled for remote shell access
# Use -name for fully qualified names, -setcookie for authentication
if [[ -n "$ERLANG_COOKIE" ]]; then
    log_runner "Starting with distributed Erlang: dxnn@$HOSTNAME"
    erl -name "dxnn@$HOSTNAME" \
        -setcookie "$ERLANG_COOKIE" \
        -noshell \
        -eval "launcher:start()"
else
    log_runner "Starting without distributed Erlang (no cookie found)"
    erl -noshell -eval "launcher:start()"
fi

exit_code=$?
log_runner "TMUX_SESSION_END - DXNN exited with code $exit_code"
echo "$exit_code" > "$SESSION_EXIT_CODE_FILE"
exit "$exit_code"
EOF
    chmod +x "$TMUX_RUNNER_SCRIPT"
}

# Main wrapper function
run_dxnn() {
    log "INFO" "WRAPPER_START - Starting DXNN training"

    if ! command -v tmux >/dev/null 2>&1; then
        log "ERROR" "tmux not found - cannot continue"
        return 1
    fi

    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    rm -f "$SESSION_EXIT_CODE_FILE"

    create_tmux_runner

    export LOG_FILE DXNN_DIR SESSION_EXIT_CODE_FILE

    log "INFO" "DXNN_START - Launching tmux session $TMUX_SESSION"
    if ! tmux new-session -d -s "$TMUX_SESSION" "$TMUX_RUNNER_SCRIPT"; then
        log "ERROR" "Failed to start tmux session"
        rm -f "$TMUX_RUNNER_SCRIPT"
        return 1
    fi

    log "INFO" "DXNN_WAITING - Monitoring tmux session completion..."
    while tmux has-session -t "$TMUX_SESSION" 2>/dev/null; do
        sleep 5
    done

    local exit_code=1
    if [[ -f "$SESSION_EXIT_CODE_FILE" ]]; then
        exit_code=$(cat "$SESSION_EXIT_CODE_FILE" 2>/dev/null || echo 1)
    else
        log "WARN" "DXNN_EXIT_CODE_MISSING - Defaulting to 1"
    fi

    # Extract population_id from logs after run completes
    POPULATION_ID=$(extract_population_id)
    export POPULATION_ID
    
    # Extract lineage_id from population_id
    if [[ "$POPULATION_ID" != "unknown" ]]; then
        LINEAGE_ID=$(echo "$POPULATION_ID" | awk -F'_' '{print $2}')
        export LINEAGE_ID
        log "INFO" "DXNN_POPULATION_EXTRACTED - population_id=$POPULATION_ID lineage_id=$LINEAGE_ID"
    fi

    rm -f "$SESSION_EXIT_CODE_FILE" "$TMUX_RUNNER_SCRIPT"
    log "INFO" "DXNN_PROCESS_END - Session completed with code: $exit_code"
    return $exit_code
}

# Determine completion status and call finalizer
finalize() {
    local exit_code="$1"
    local completion_status
    
    # Determine completion reason based on exit code
    if [[ $exit_code -eq 0 ]]; then
        completion_status="normal"
        log "INFO" "COMPLETION_NORMAL - Training completed successfully, initiating S3 upload"
    else
        completion_status="interrupted"
        log "INFO" "COMPLETION_INTERRUPTED - Training interrupted (exit code: $exit_code), initiating S3 upload"
    fi
    
    # Set environment variables for finalizer
    export COMPLETION_STATUS="$completion_status"
    export EXIT_CODE="$exit_code"
    
    log "INFO" "FINALIZER_CALL - Calling finalize_run.sh with status: $completion_status, exit: $exit_code"
    log "INFO" "S3_UPLOAD_START - Beginning upload to s3://$S3_BUCKET/$S3_PREFIX/$LINEAGE_ID/$POPULATION_ID/"
    
    # Call finalizer script
    if [[ -x "$FINALIZER_SCRIPT" ]]; then
        log "INFO" "FINALIZER_EXEC - Executing $FINALIZER_SCRIPT"
        "$FINALIZER_SCRIPT"
        log "INFO" "FINALIZER_COMPLETE - Upload and finalization completed successfully"
    else
        log "ERROR" "FINALIZER_NOT_FOUND - $FINALIZER_SCRIPT not executable"
        exit 1
    fi
}

# Main execution
main() {
    log "INFO" "WRAPPER_INIT - Starting DXNN wrapper with Run ID: $RUN_ID"
    log "INFO" "WRAPPER_CONFIG - S3 destination: s3://$S3_BUCKET/$S3_PREFIX/<lineage_id>/<population_id>/"
    
    # Run DXNN and capture exit code
    local exit_code=0
    log "INFO" "WRAPPER_EXEC - Launching DXNN process..."
    
    if run_dxnn; then
        exit_code=0
        log "INFO" "WRAPPER_SUCCESS - DXNN process completed successfully"
    else
        exit_code=$?
        log "WARN" "WRAPPER_ERROR - DXNN process failed with exit code: $exit_code"
    fi
    
    log "INFO" "WRAPPER_FINALIZE - DXNN execution finished, starting finalization process"
    
    # Call finalizer with outcome
    finalize "$exit_code"
    
    log "INFO" "WRAPPER_END - All operations completed"
}

# Execute main function
main "$@"
