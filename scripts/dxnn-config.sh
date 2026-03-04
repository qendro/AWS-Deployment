#!/bin/bash

# Shared configuration helpers for DXNN scripts.
# Provides centralized loading of YAML configuration values and sane defaults.

# Normalize boolean-like values to "true"/"false" with a fallback when input is invalid.
dxnn_normalize_bool() {
    local raw="${1:-}"
    local fallback="${2:-false}"
    case "${raw,,}" in
        true|1|yes|y|on)
            echo "true"
            ;;
        false|0|no|n|off)
            echo "false"
            ;;
        *)
            echo "$fallback"
            ;;
    esac
}

# Return numeric value when positive integer, otherwise fallback.
dxnn_sanitize_positive_int() {
    local raw="${1:-}"
    local fallback="${2:-0}"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "$raw"
    else
        echo "$fallback"
    fi
}

# Assign default to variable only when it is unset or empty.
dxnn_assign_default() {
    local var_name="$1"
    local config_value="$2"
    local fallback="$3"
    local current="${!var_name:-}"

    if [[ -z "$current" ]]; then
        local effective="$config_value"
        [[ -z "$effective" ]] && effective="$fallback"
        printf -v "$var_name" '%s' "$effective"
        export "$var_name"
    fi
}

# Ensure variable holds normalized boolean value.
dxnn_finalize_bool() {
    local var_name="$1"
    local fallback="$2"
    local normalized
    normalized=$(dxnn_normalize_bool "${!var_name:-}" "$fallback")
    printf -v "$var_name" '%s' "$normalized"
    export "$var_name"
}

# Ensure variable holds a positive integer (or fallback when invalid).
dxnn_finalize_int() {
    local var_name="$1"
    local fallback="$2"
    local sanitized
    sanitized=$(dxnn_sanitize_positive_int "${!var_name:-}" "$fallback")
    printf -v "$var_name" '%s' "$sanitized"
    export "$var_name"
}

load_dxnn_config() {
    # Memoize without breaking explicit overrides via argument.
    local requested_config="${1:-}";
    if [[ -n "$requested_config" ]]; then
        DXNN_CONFIG_FILE="$requested_config"
        DXNN_CONFIG_INITIALIZED="false"
    fi

    if [[ "${DXNN_CONFIG_INITIALIZED:-false}" == "true" ]]; then
        return 0
    fi

    local config_file="${DXNN_CONFIG_FILE:-}"
    if [[ -z "$config_file" ]]; then
        local candidates=(
            "/aws-deployment/config/dxnn-spot-prod.yml"
            "/config/dxnn-spot-prod.yml"
            "/home/ubuntu/config/dxnn-spot-prod.yml"
            "${HOME:-/home/ubuntu}/config/dxnn-spot-prod.yml"
        )
        for candidate in "${candidates[@]}"; do
            if [[ -f "$candidate" ]]; then
                config_file="$candidate"
                break
            fi
        done
    fi

    local have_config="false"
    if command -v yq >/dev/null 2>&1 && [[ -n "$config_file" && -f "$config_file" ]]; then
        have_config="true"
    else
        config_file=""
    fi

    # Baseline defaults
    local cfg_auto_terminate="false"
    local cfg_restore_from_s3="false"
    local cfg_s3_bucket="dxnn-checkpoints"
    local cfg_s3_prefix="dxnn"
    local cfg_container_name="dxnn-app"
    local cfg_erlang_node="dxnn@127.0.0.1"
    local cfg_erlang_cookie="/var/lib/dxnn/.erlang.cookie"
    local cfg_checkpoint_deadline="60"
    local cfg_poll_interval="4"
    local cfg_use_rebalance="false"

    if [[ "$have_config" == "true" ]]; then
        local value

        value=$(yq -r '.spot_handling.auto_terminate // ""' "$config_file" 2>/dev/null || echo "")
        cfg_auto_terminate=$(dxnn_normalize_bool "$value" "$cfg_auto_terminate")

        value=$(yq -r '.spot_handling.restore_from_s3_on_boot // ""' "$config_file" 2>/dev/null || echo "")
        cfg_restore_from_s3=$(dxnn_normalize_bool "$value" "$cfg_restore_from_s3")

        value=$(yq -r '.spot_handling.s3_bucket // ""' "$config_file" 2>/dev/null || echo "")
        [[ "$value" != "null" && -n "$value" ]] && cfg_s3_bucket="$value"

        value=$(yq -r '.spot_handling.s3_prefix // ""' "$config_file" 2>/dev/null || echo "")
        [[ "$value" != "null" && -n "$value" ]] && cfg_s3_prefix="$value"

        value=$(yq -r '.spot_handling.container_name // ""' "$config_file" 2>/dev/null || echo "")
        [[ "$value" != "null" && -n "$value" ]] && cfg_container_name="$value"

        value=$(yq -r '.spot_handling.erlang_node // ""' "$config_file" 2>/dev/null || echo "")
        [[ "$value" != "null" && -n "$value" ]] && cfg_erlang_node="$value"

        value=$(yq -r '.spot_handling.erlang_cookie_file // ""' "$config_file" 2>/dev/null || echo "")
        [[ "$value" != "null" && -n "$value" ]] && cfg_erlang_cookie="$value"

        value=$(yq -r '.spot_handling.checkpoint_deadline_seconds // ""' "$config_file" 2>/dev/null || echo "")
        cfg_checkpoint_deadline=$(dxnn_sanitize_positive_int "$value" "$cfg_checkpoint_deadline")

        value=$(yq -r '.spot_handling.poll_interval_seconds // ""' "$config_file" 2>/dev/null || echo "")
        cfg_poll_interval=$(dxnn_sanitize_positive_int "$value" "$cfg_poll_interval")

        value=$(yq -r '.spot_handling.use_rebalance_recommendation // ""' "$config_file" 2>/dev/null || echo "")
        cfg_use_rebalance=$(dxnn_normalize_bool "$value" "$cfg_use_rebalance")
    fi

    export DXNN_CFG_CONFIG_FILE="$config_file"
    export DXNN_CFG_AUTO_TERMINATE="$cfg_auto_terminate"
    export DXNN_CFG_RESTORE_FROM_S3="$cfg_restore_from_s3"
    export DXNN_CFG_S3_BUCKET="$cfg_s3_bucket"
    export DXNN_CFG_S3_PREFIX="$cfg_s3_prefix"
    export DXNN_CFG_CONTAINER_NAME="$cfg_container_name"
    export DXNN_CFG_ERLANG_NODE="$cfg_erlang_node"
    export DXNN_CFG_ERLANG_COOKIE_FILE="$cfg_erlang_cookie"
    export DXNN_CFG_CHECKPOINT_DEADLINE="$cfg_checkpoint_deadline"
    export DXNN_CFG_POLL_INTERVAL="$cfg_poll_interval"
    export DXNN_CFG_USE_REBALANCE="$cfg_use_rebalance"

    if [[ -n "$config_file" ]]; then
        export DXNN_CONFIG_FILE="$config_file"
    fi
    export DXNN_CONFIG_INITIALIZED="true"
}
