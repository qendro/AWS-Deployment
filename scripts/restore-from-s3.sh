#!/bin/bash
set -euo pipefail

S3_BUCKET="dxnn-checkpoints"
S3_PREFIX="dxnn"
JOB_ID="dxnn-training-001"
CHECKPOINT_DIR="/var/lib/dxnn/checkpoints"
CONTAINER_NAME="dxnn-app"
LOG_FILE="/var/log/spot-restore.log"

log() {
    echo "[UTC $(date -u -Iseconds)] $1" >> "$LOG_FILE"
}

# For now, just check local checkpoints since S3 restore requires AWS CLI
# In production, this would use direct S3 HTTP calls with AWS Signature v4
log "INFO: S3 restore not implemented yet (requires AWS Signature v4)"

# Local fallback only if local has valid metadata
local_checkpoint=$(ls -1t "$CHECKPOINT_DIR"/checkpoint-*.dmp 2>/dev/null | head -1)
if [[ -n "$local_checkpoint" ]]; then
    metadata_file="${local_checkpoint%.dmp}.metadata.json"
    if [[ -f "$metadata_file" ]] && jq -e '.job_id' "$metadata_file" >/dev/null 2>&1; then
        log "LOCAL_SOURCE: Using local checkpoint with valid metadata"
        # For now, just copy to the right location for DXNN to find
        cp "$local_checkpoint" "$CHECKPOINT_DIR/"
        log "RESTORE_OK: from local"
    else
        log "LOCAL_SOURCE: Skipping local checkpoint (no valid metadata)"
    fi
else
    log "LOCAL_SOURCE: No local checkpoint found"
fi

