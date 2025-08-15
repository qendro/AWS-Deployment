#!/bin/bash

# DXNN Minimal Wrapper Script
# Runs DXNN directly (no tmux) and handles completion/interruption
# Calls finalizer with proper exit code and completion status

set -euo pipefail

# Configuration
LOG_FILE="/var/log/dxnn-run.log"
DXNN_DIR="/home/ubuntu/dxnn-trader"
FINALIZER_SCRIPT="/usr/local/bin/finalize_run.sh"

# Environment variables for finalizer
export S3_BUCKET="${S3_BUCKET:-dxnn-checkpoints}"
export S3_PREFIX="${S3_PREFIX:-dxnn}"
export JOB_ID="${JOB_ID:-dxnn-training-001}"
export RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%SZ)}"

# Logging function with UTC timestamps
log() {
    local level="$1"
    shift
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $level: $*" | tee -a "$LOG_FILE"
}

# Signal handler for TERM/INT - forward to DXNN child
cleanup() {
    log "INFO" "WRAPPER_SIGNAL_RECEIVED - Forwarding to DXNN process"
    if [[ -n "${DXNN_PID:-}" ]] && kill -0 "$DXNN_PID" 2>/dev/null; then
        kill -TERM "$DXNN_PID" 2>/dev/null || true
        wait "$DXNN_PID" 2>/dev/null || true
    fi
}

# Set up signal traps
trap cleanup TERM INT

# Main wrapper function
run_dxnn() {
    log "INFO" "WRAPPER_START - Starting DXNN training"
    
    # Change to DXNN directory
    cd "$DXNN_DIR"
    
    # Start DXNN directly with exec (no tmux)
    # This replaces the complex tmux startup from config
    log "INFO" "DXNN_START - Launching Erlang process"
    
    # Run DXNN in background to capture PID
    erl -noshell -eval "
        mnesia:create_schema([node()]),
        mnesia:start(),
        make:all(),
        fx:init(),
        fx:start(),
        timer:sleep(5000),
        polis:create(),
        polis:start(),
        polis:sync(),
        benchmarker:maybe_restore(),
        benchmarker:start(sliding_window_5)
    " &
    
    DXNN_PID=$!
    log "INFO" "DXNN_RUNNING - PID: $DXNN_PID"
    
    # Wait for DXNN process to exit and capture exit code
    local exit_code=0
    if wait "$DXNN_PID"; then
        exit_code=0
        log "INFO" "DXNN_COMPLETED - Exit code: $exit_code"
    else
        exit_code=$?
        log "WARN" "DXNN_EXITED - Exit code: $exit_code"
    fi
    
    return $exit_code
}

# Determine completion status and call finalizer
finalize() {
    local exit_code="$1"
    local completion_status
    
    # Determine completion reason based on exit code
    if [[ $exit_code -eq 0 ]]; then
        completion_status="normal"
        log "INFO" "COMPLETION_NORMAL - Training completed successfully"
    else
        completion_status="interrupted"
        log "INFO" "COMPLETION_INTERRUPTED - Training interrupted (exit code: $exit_code)"
    fi
    
    # Set environment variables for finalizer
    export COMPLETION_STATUS="$completion_status"
    export EXIT_CODE="$exit_code"
    
    log "INFO" "FINALIZER_CALL - Status: $completion_status, Exit: $exit_code"
    
    # Call finalizer script
    if [[ -x "$FINALIZER_SCRIPT" ]]; then
        "$FINALIZER_SCRIPT"
    else
        log "ERROR" "FINALIZER_NOT_FOUND - $FINALIZER_SCRIPT not executable"
        exit 1
    fi
}

# Main execution
main() {
    log "INFO" "WRAPPER_INIT - Run ID: $RUN_ID"
    
    # Run DXNN and capture exit code
    local exit_code=0
    if run_dxnn; then
        exit_code=0
    else
        exit_code=$?
    fi
    
    # Call finalizer with outcome
    finalize "$exit_code"
}

# Execute main function
main "$@"