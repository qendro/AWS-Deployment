#!/bin/bash
# Validation script for AWS-Deployment

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}[CHECK]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# Check AWS CLI
check_aws_cli() {
    log_info "Checking AWS CLI..."
    if command -v aws >/dev/null 2>&1; then
        aws_version=$(aws --version 2>&1 | cut -d' ' -f1)
        log_pass "AWS CLI found: $aws_version"
        return 0
    else
        log_fail "AWS CLI not found"
        return 1
    fi
}

# Check AWS credentials
check_aws_credentials() {
    log_info "Checking AWS credentials..."
    if aws sts get-caller-identity >/dev/null 2>&1; then
        account_id=$(aws sts get-caller-identity --query Account --output text)
        log_pass "AWS credentials valid (Account: $account_id)"
        return 0
    else
        log_fail "AWS credentials not configured or invalid"
        return 1
    fi
}

# Check required tools
check_tools() {
    local tools=("curl" "ssh" "git")
    local all_good=true
    
    for tool in "${tools[@]}"; do
        log_info "Checking $tool..."
        if command -v "$tool" >/dev/null 2>&1; then
            log_pass "$tool found"
        else
            log_fail "$tool not found"
            all_good=false
        fi
    done
    
    return $([[ "$all_good" == "true" ]] && echo 0 || echo 1)
}

# Check yq (optional but recommended)
check_yq() {
    log_info "Checking yq (YAML processor)..."
    if command -v yq >/dev/null 2>&1; then
        yq_version=$(yq --version 2>&1)
        log_pass "yq found: $yq_version"
        return 0
    else
        log_fail "yq not found (optional - config file features will be limited)"
        return 1
    fi
}

# Main validation
main() {
    echo "AWS-Deployment Validation"
    echo "=========================="
    echo
    
    local all_checks=0
    
    check_aws_cli || ((all_checks++))
    check_aws_credentials || ((all_checks++))
    check_tools || ((all_checks++))
    check_yq  # Optional, don't count as failure
    
    echo
    if [[ $all_checks -eq 0 ]]; then
        log_pass "All required checks passed! ✅"
        echo "You're ready to deploy AWS instances."
    else
        log_fail "$all_checks check(s) failed ❌"
        echo "Please fix the issues above before deploying."
        exit 1
    fi
}

main "$@"
