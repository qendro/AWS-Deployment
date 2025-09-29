#!/bin/bash
set -euo pipefail

# Restore DXNN artifacts from S3 using simple-s3-download.sh

S3_BUCKET="dxnn-checkpoints"
S3_PREFIX="dxnn"
JOB_ID="dxnn-training-001"
RUN_ID=""
DXNN_DIR="/home/ubuntu/dxnn-trader"
RESTORE_LOG="/var/log/dxnn-restore.log"
DOWNLOAD_BIN="/usr/local/bin/simple-s3-download.sh"

# Allow optional runtime overrides
if [[ -n "${RESTORE_S3_BUCKET:-}" ]]; then
    S3_BUCKET="$RESTORE_S3_BUCKET"
fi
if [[ -n "${RESTORE_S3_PREFIX:-}" ]]; then
    S3_PREFIX="$RESTORE_S3_PREFIX"
fi
if [[ -n "${RESTORE_JOB_ID:-}" ]]; then
    JOB_ID="$RESTORE_JOB_ID"
fi
if [[ -n "${RESTORE_RUN_ID:-}" ]]; then
    RUN_ID="$RESTORE_RUN_ID"
fi
if [[ -n "${RESTORE_DXNN_DIR:-}" ]]; then
    DXNN_DIR="$RESTORE_DXNN_DIR"
fi

export S3_BUCKET S3_PREFIX JOB_ID RUN_ID DXNN_DIR

log() {
    local level="$1"
    shift
    printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" | tee -a "$RESTORE_LOG"
}

require_downloader() {
    if [[ ! -x "$DOWNLOAD_BIN" ]]; then
        log "WARN" "Downloader not found at $DOWNLOAD_BIN - skipping restore"
        return 1
    fi
    return 0
}

resolve_run_id() {
    if [[ -n "$RUN_ID" ]]; then
        log "INFO" "Using provided RUN_ID=$RUN_ID"
        return 0
    fi

    local pointer_key="$S3_PREFIX/$JOB_ID/_LATEST_RUN"
    local pointer_tmp
    pointer_tmp=$(mktemp)

    if "$DOWNLOAD_BIN" "$pointer_key" "$pointer_tmp" >/dev/null 2>&1; then
        if command -v jq >/dev/null 2>&1; then
            RUN_ID=$(jq -r '.run_id // empty' "$pointer_tmp")
        else
            RUN_ID=$(sed -n 's/.*"run_id"[[:space:]]*:[[:space:]]*"\([^\"]*\)".*/\1/p' "$pointer_tmp" | head -n1)
        fi
        rm -f "$pointer_tmp"

        if [[ -z "$RUN_ID" ]]; then
            log "WARN" "Latest pointer file present but missing run_id"
            return 1
        fi
        log "INFO" "Resolved RUN_ID=$RUN_ID from latest pointer"
        return 0
    fi

    rm -f "$pointer_tmp"
    log "INFO" "No latest run pointer found - skipping restore"
    return 1
}

restore_manifest() {
    local manifest_key="$S3_PREFIX/$JOB_ID/$RUN_ID/_MANIFEST"
    local manifest_tmp
    manifest_tmp=$(mktemp)

    if ! "$DOWNLOAD_BIN" "$manifest_key" "$manifest_tmp" >/dev/null 2>&1; then
        log "INFO" "Manifest not found at s3://$S3_BUCKET/$manifest_key - skipping restore"
        rm -f "$manifest_tmp"
        return 1
    fi

    while IFS=$'\t' read -r file_mode relative_path || [[ -n "${file_mode:-}" ]]; do
        if [[ -z "${relative_path:-}" ]]; then
            relative_path="$file_mode"
            file_mode="0644"
        fi
        [[ -z "${relative_path:-}" ]] && continue
        local target_path="$DXNN_DIR/$relative_path"
        local target_dir
        target_dir=$(dirname "$target_path")
        mkdir -p "$target_dir"

        local object_key="$S3_PREFIX/$JOB_ID/$RUN_ID/$relative_path"
        if "$DOWNLOAD_BIN" "$object_key" "$target_path" >/dev/null 2>&1; then
            log "INFO" "Restored $relative_path"
            if [[ -n "${file_mode:-}" && "$file_mode" =~ ^[0-7]{3,4}$ ]]; then
                chmod "$file_mode" "$target_path" 2>/dev/null || true
            fi
        else
            log "ERROR" "Failed to download $relative_path"
            rm -f "$manifest_tmp"
            return 2
        fi
    done < "$manifest_tmp"

    rm -f "$manifest_tmp"
    return 0
}

main() {
    log "INFO" "Starting S3 restore to $DXNN_DIR"
    if ! require_downloader; then
        log "INFO" "Restore skipped because downloader is unavailable"
        exit 0
    fi

    if ! resolve_run_id; then
        log "INFO" "Restore skipped - no previous run id"
        exit 0
    fi

    if restore_manifest; then
        status=0
    else
        status=$?
    fi
    case "$status" in
        0)
            log "INFO" "Restore completed for RUN_ID=$RUN_ID"
            ;;
        1)
            log "INFO" "Restore skipped - manifest missing"
            ;;
        2)
            log "ERROR" "Restore failed to download one or more files"
            exit 1
            ;;
        *)
            log "ERROR" "Restore encountered an unexpected status ($status)"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
