#!/bin/bash
set -euo pipefail

# Simple S3 download using AWS Signature v4 and curl only
# No AWS CLI required

# Configuration
S3_BUCKET="dxnn-checkpoints"
S3_REGION="us-east-1"
IMDS="http://169.254.169.254"

# Helper functions
hex() {
    printf '%s' "$1" | od -A n -t x1 | tr -d ' \n'
}

sha256() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# Get IMDSv2 token
get_token() {
    curl -sS -X PUT "$IMDS/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true
}

# Get AWS credentials from IMDSv2
get_credentials() {
    local token="$1"
    local role_name
    local credentials
    
    # Get role name
    role_name=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
        "$IMDS/latest/meta-data/iam/security-credentials/")
    
    if [[ -z "$role_name" ]]; then
        echo "ERROR: No IAM role found" >&2
        return 1
    fi
    
    # Get credentials
    credentials=$(curl -s -H "X-aws-ec2-metadata-token: $token" \
        "$IMDS/latest/meta-data/iam/security-credentials/$role_name")
    
    if [[ -z "$credentials" ]]; then
        echo "ERROR: Failed to get credentials for role: $role_name" >&2
        return 1
    fi
    
    # Extract credentials using jq
    ACCESS_KEY_ID=$(echo "$credentials" | jq -r '.AccessKeyId')
    SECRET_ACCESS_KEY=$(echo "$credentials" | jq -r '.SecretAccessKey')
    SESSION_TOKEN=$(echo "$credentials" | jq -r '.Token')
    
    if [[ "$ACCESS_KEY_ID" == "null" ]] || [[ "$SECRET_ACCESS_KEY" == "null" ]]; then
        echo "ERROR: Invalid credentials response" >&2
        return 1
    fi
    
    echo "INFO: Got credentials for role: $role_name" >&2
}

# Simple S3 GET with AWS Signature v4
s3_get() {
    local s3_key="$1"
    local output_file="$2"
    local token="$3"
    
    # Get credentials
    if ! get_credentials "$token"; then
        return 1
    fi
    
    local http_method="GET"
    local service="s3"
    local host="$S3_BUCKET.s3.amazonaws.com"
    local endpoint="https://$host"
    
    # Timestamps
    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    local date_stamp
    date_stamp=$(date -u +%Y%m%d)
    
    # Empty payload for GET
    local payload_hash
    payload_hash=$(sha256 "")
    
    # Canonical request
    local canonical_uri="/$s3_key"
    local canonical_querystring=""
    local canonical_headers="host:$host"$'\n'"x-amz-content-sha256:$payload_hash"$'\n'"x-amz-date:$timestamp"
    if [[ -n "$SESSION_TOKEN" ]]; then
        canonical_headers="$canonical_headers"$'\n'"x-amz-security-token:$SESSION_TOKEN"
    fi
    canonical_headers="$canonical_headers"$'\n'
    
    local signed_headers="host;x-amz-content-sha256;x-amz-date"
    if [[ -n "$SESSION_TOKEN" ]]; then
        signed_headers="$signed_headers;x-amz-security-token"
    fi
    
    local canonical_request="$http_method"$'\n'"$canonical_uri"$'\n'"$canonical_querystring"$'\n'"$canonical_headers"$'\n'"$signed_headers"$'\n'"$payload_hash"
    
    # String to sign
    local algorithm="AWS4-HMAC-SHA256"
    local credential_scope="$date_stamp/$S3_REGION/$service/aws4_request"
    local string_to_sign="$algorithm"$'\n'"$timestamp"$'\n'"$credential_scope"$'\n'"$(sha256 "$canonical_request")"
    
    # Sign the string
    local k_date
    k_date=$(printf '%s' "$date_stamp" | openssl dgst -sha256 -hmac "AWS4$SECRET_ACCESS_KEY" -binary)
    local k_region
    k_region=$(printf '%s' "$S3_REGION" | openssl dgst -sha256 -hmac "$k_date" -binary)
    local k_service
    k_service=$(printf '%s' "$service" | openssl dgst -sha256 -hmac "$k_region" -binary)
    local k_signing
    k_signing=$(printf '%s' "aws4_request" | openssl dgst -sha256 -hmac "$k_service" -binary)
    local signature
    signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -hmac "$k_signing" | cut -d' ' -f2)
    
    # Authorization header
    local authorization_header="$algorithm Credential=$ACCESS_KEY_ID/$credential_scope, SignedHeaders=$signed_headers, Signature=$signature"
    
    # Make the request
    local response
    response=$(curl -s -w "%{http_code}" -X GET \
        -H "x-amz-content-sha256: $payload_hash" \
        -H "Host: $host" \
        -H "x-amz-date: $timestamp" \
        -H "Authorization: $authorization_header" \
        ${SESSION_TOKEN:+-H "x-amz-security-token: $SESSION_TOKEN"} \
        -o "$output_file" \
        "$endpoint$canonical_uri")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        echo "SUCCESS: Downloaded s3://$S3_BUCKET/$s3_key to $output_file"
        return 0
    else
        echo "ERROR: Download failed with HTTP $http_code" >&2
        rm -f "$output_file"
        return 1
    fi
}

# Main function
main() {
    if [[ $# -ne 2 ]]; then
        echo "Usage: $0 <s3_key> <local_file>"
        echo "Example: $0 dxnn/job-001/checkpoint.dmp /var/lib/dxnn/checkpoints/checkpoint.dmp"
        exit 1
    fi
    
    local s3_key="$1"
    local output_file="$2"
    
    # Get IMDSv2 token
    echo "Getting IMDSv2 token..." >&2
    token=$(get_token)
    if [[ -z "$token" ]]; then
        echo "ERROR: Failed to get IMDSv2 token" >&2
        exit 1
    fi
    
    # Download from S3
    echo "Downloading from S3..." >&2
    if s3_get "$s3_key" "$output_file" "$token"; then
        echo "Download completed successfully"
        exit 0
    else
        echo "Download failed"
        exit 1
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi