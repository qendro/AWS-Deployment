#!/bin/bash
set -euo pipefail

# Simple S3 download using AWS Signature v4 and curl only
# Mirrors simple-s3-upload.sh but performs GET requests

S3_BUCKET="${S3_BUCKET:-dxnn-checkpoints}"
S3_REGION="${S3_REGION:-us-east-1}"
IMDS="http://169.254.169.254"

hex() {
    printf '%s' "$1" | od -A n -t x1 | tr -d ' \n'
}

sha256() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

get_token() {
    curl -sS -X PUT "$IMDS/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true
}

get_credentials() {
    local token="$1"
    local role_name
    local credentials

    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required but not installed" >&2
        return 1
    fi

    role_name=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
        "$IMDS/latest/meta-data/iam/security-credentials/")

    if [[ -z "$role_name" ]]; then
        echo "ERROR: No IAM role found" >&2
        return 1
    fi

    credentials=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
        "$IMDS/latest/meta-data/iam/security-credentials/$role_name")

    if [[ -z "$credentials" ]]; then
        echo "ERROR: Failed to get credentials for role: $role_name" >&2
        return 1
    fi

    ACCESS_KEY_ID=$(echo "$credentials" | jq -r '.AccessKeyId')
    SECRET_ACCESS_KEY=$(echo "$credentials" | jq -r '.SecretAccessKey')
    SESSION_TOKEN=$(echo "$credentials" | jq -r '.Token')

    if [[ "$ACCESS_KEY_ID" == "null" || "$SECRET_ACCESS_KEY" == "null" ]]; then
        echo "ERROR: Invalid credentials response" >&2
        return 1
    fi

    echo "INFO: Got credentials for role: $role_name" >&2
}

s3_get() {
    local s3_key="$1"
    local destination="$2"
    local token="$3"

    if ! get_credentials "$token"; then
        return 1
    fi

    local http_method="GET"
    local service="s3"
    local host="$S3_BUCKET.s3.amazonaws.com"
    local endpoint="https://$host"
    local canonical_uri="/$s3_key"
    local canonical_querystring=""

    local payload_hash
    payload_hash=$(printf '' | sha256sum | cut -d' ' -f1)

    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    local date_stamp
    date_stamp=$(date -u +%Y%m%d)

    local canonical_headers="host:$host"$'\n'
    canonical_headers+="x-amz-content-sha256:$payload_hash"$'\n'
    canonical_headers+="x-amz-date:$timestamp"$'\n'

    local signed_headers="host;x-amz-content-sha256;x-amz-date"

    if [[ -n "${SESSION_TOKEN:-}" && "$SESSION_TOKEN" != "null" ]]; then
        canonical_headers+="x-amz-security-token:$SESSION_TOKEN"$'\n'
        signed_headers+=";x-amz-security-token"
    fi

    local canonical_request="$http_method"$'\n'"$canonical_uri"$'\n'"$canonical_querystring"$'\n'"$canonical_headers"$'\n'"$signed_headers"$'\n'"$payload_hash"

    local algorithm="AWS4-HMAC-SHA256"
    local credential_scope="$date_stamp/$S3_REGION/$service/aws4_request"
    local string_to_sign="$algorithm"$'\n'"$timestamp"$'\n'"$credential_scope"$'\n'"$(sha256 "$canonical_request")"

    local temp_dir="/tmp/s3_sign_$$"
    mkdir -p "$temp_dir"

    printf '%s' "$date_stamp" | openssl dgst -sha256 -mac HMAC -macopt "key:AWS4$SECRET_ACCESS_KEY" -binary > "$temp_dir/k_date"
    printf '%s' "$S3_REGION" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(xxd -p -c 256 < "$temp_dir/k_date")" -binary > "$temp_dir/k_region"
    printf '%s' "$service" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(xxd -p -c 256 < "$temp_dir/k_region")" -binary > "$temp_dir/k_service"
    printf '%s' "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(xxd -p -c 256 < "$temp_dir/k_service")" -binary > "$temp_dir/k_signing"
    local signature
    signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(xxd -p -c 256 < "$temp_dir/k_signing")" | cut -d' ' -f2)

    rm -rf "$temp_dir"

    local authorization_header="$algorithm Credential=$ACCESS_KEY_ID/$credential_scope, SignedHeaders=$signed_headers, Signature=$signature"

    local temp_file
    temp_file=$(mktemp)
    local http_code
    http_code=$(curl -s -o "$temp_file" -w '%{http_code}' -X GET \
        -H "x-amz-content-sha256: $payload_hash" \
        -H "Host: $host" \
        -H "x-amz-date: $timestamp" \
        -H "Authorization: $authorization_header" \
        ${SESSION_TOKEN:+-H "x-amz-security-token: $SESSION_TOKEN"} \
        "$endpoint$canonical_uri")

    if [[ "$http_code" == "200" ]]; then
        mkdir -p "$(dirname "$destination")"
        mv "$temp_file" "$destination"
        echo "SUCCESS: Downloaded s3://$S3_BUCKET/$s3_key" >&2
        return 0
    else
        local response_body
        response_body=$(cat "$temp_file")
        rm -f "$temp_file"
        echo "ERROR: Download failed with HTTP $http_code: $response_body" >&2
        return 1
    fi
}

usage() {
    echo "Usage: $0 <s3_key> <local_path>" >&2
    echo "Example: $0 dxnn/job-001/checkpoint.dmp /tmp/checkpoint.dmp" >&2
}

main() {
    if [[ $# -ne 2 ]]; then
        usage
        exit 1
    fi

    local s3_key="$1"
    local destination="$2"

    local token
    token=$(get_token)
    if [[ -z "$token" ]]; then
        echo "ERROR: Failed to get IMDSv2 token" >&2
        exit 1
    fi

    if s3_get "$s3_key" "$destination" "$token"; then
        exit 0
    else
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
