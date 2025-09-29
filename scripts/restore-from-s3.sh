#!/bin/bash
set -euo pipefail

# Restore DXNN artifacts from S3 using the AWS CLI

AWS_CLI_BIN="${AWS_CLI_BIN:-aws}"
S3_BUCKET="dxnn-checkpoints"
S3_PREFIX="dxnn"
JOB_ID="dxnn-training-001"
RUN_ID=""
DXNN_DIR="/home/ubuntu/dxnn-trader"
RESTORE_LOG="/var/log/dxnn-restore.log"

AWS_REGION_HINT="${AWS_REGION:-${AWS_DEFAULT_REGION:-${RESTORE_S3_REGION:-${S3_REGION:-}}}}"
AWS_S3_ARGS=(--no-progress)
if [[ -n "$AWS_REGION_HINT" ]]; then
    AWS_S3_ARGS+=(--region "$AWS_REGION_HINT")
fi
AWS_CLI_INSTALL_DIR="${AWS_CLI_INSTALL_DIR:-/usr/local/aws-cli}"
AWS_CLI_BIN_DIR="${AWS_CLI_BIN_DIR:-/usr/local/bin}"

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

aws_s3_cp() {
    "$AWS_CLI_BIN" s3 cp "$@" "${AWS_S3_ARGS[@]}"
}

log() {
    local level="$1"
    shift
    printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" | tee -a "$RESTORE_LOG"
}

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
            run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y unzip >> "$RESTORE_LOG" 2>&1 || return 1
        elif command -v yum >/dev/null 2>&1; then
            run_privileged yum install -y unzip >> "$RESTORE_LOG" 2>&1 || return 1
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
    if ! curl -Ls "$url" -o "$zip_path" >> "$RESTORE_LOG" 2>&1; then
        log "ERROR" "Failed to download AWS CLI bundle from $url"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! unzip -q "$zip_path" -d "$tmp_dir" >> "$RESTORE_LOG" 2>&1; then
        log "ERROR" "Failed to extract AWS CLI bundle"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! run_privileged "$tmp_dir/aws/install" --bin-dir "$AWS_CLI_BIN_DIR" --install-dir "$AWS_CLI_INSTALL_DIR" --update >> "$RESTORE_LOG" 2>&1; then
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

    log "WARN" "AWS CLI not found at runtime - attempting automatic installation"
    local installed=false

    if command -v apt-get >/dev/null 2>&1; then
        if run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$RESTORE_LOG" 2>&1 && \
           run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y awscli >> "$RESTORE_LOG" 2>&1; then
            hash -r
            installed=true
        else
            log "INFO" "apt-get install awscli failed or package unavailable; falling back"
        fi
    elif command -v yum >/dev/null 2>&1; then
        if run_privileged yum install -y awscli >> "$RESTORE_LOG" 2>&1; then
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

    log "WARN" "AWS CLI still missing - skipping restore"
    return 1
}

resolve_run_id() {
    if [[ -n "$RUN_ID" ]]; then
        log "INFO" "Using provided RUN_ID=$RUN_ID"
        return 0
    fi

    local pointer_key="$S3_PREFIX/$JOB_ID/_LATEST_RUN"
    local pointer_tmp
    pointer_tmp=$(mktemp)

    if aws_s3_cp "s3://$S3_BUCKET/$pointer_key" "$pointer_tmp" >/dev/null 2>&1; then
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

    if ! aws_s3_cp "s3://$S3_BUCKET/$manifest_key" "$manifest_tmp" >/dev/null 2>&1; then
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
        if aws_s3_cp "s3://$S3_BUCKET/$object_key" "$target_path" >/dev/null 2>&1; then
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
    if ! require_aws_cli; then
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
