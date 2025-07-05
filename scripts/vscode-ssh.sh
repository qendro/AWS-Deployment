#!/bin/bash
# VSCode SSH configuration generator

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../output"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Generate VSCode SSH config
generate_vscode_config() {
    local deployment_file="$1"
    
    if [[ ! -f "$deployment_file" ]]; then
        echo "Deployment file not found: $deployment_file"
        return 1
    fi
    
    # Extract info from deployment JSON
    local instance_id public_ip ssh_key_file
    instance_id=$(jq -r '.instance_id' "$deployment_file")
    public_ip=$(jq -r '.public_ip' "$deployment_file")
    ssh_key_file=$(jq -r '.ssh_key_file' "$deployment_file")
    app_type=$(jq -r '.app_type' "$deployment_file")
    
    # Generate SSH config entry
    local ssh_config_entry
    ssh_config_entry="Host aws-${app_type}-${instance_id}
    HostName ${public_ip}
    User ec2-user
    IdentityFile ${ssh_key_file}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
"
    
    echo "$ssh_config_entry"
    
    # Save to file
    local config_file="$OUTPUT_DIR/ssh-config-${instance_id}.txt"
    echo "$ssh_config_entry" > "$config_file"
    
    log_success "SSH config saved to: $config_file"
    log_info "To use with VSCode:"
    log_info "1. Copy the config entry to your ~/.ssh/config file"
    log_info "2. In VSCode, press F1 and run 'Remote-SSH: Connect to Host'"
    log_info "3. Select: aws-${app_type}-${instance_id}"
}

# Process all deployment files
main() {
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        echo "Output directory not found: $OUTPUT_DIR"
        exit 1
    fi
    
    local deployment_files
    deployment_files=$(find "$OUTPUT_DIR" -name "deployment-*.json" 2>/dev/null || true)
    
    if [[ -z "$deployment_files" ]]; then
        echo "No deployment files found in $OUTPUT_DIR"
        exit 1
    fi
    
    log_info "Generating VSCode SSH configurations..."
    
    while IFS= read -r file; do
        log_info "Processing: $(basename "$file")"
        generate_vscode_config "$file"
    done <<< "$deployment_files"
    
    # Generate combined config
    local combined_config="$OUTPUT_DIR/ssh-config-all.txt"
    log_info "Creating combined SSH config: $combined_config"
    
    echo "# AWS-Deployment SSH Configuration" > "$combined_config"
    echo "# Add this to your ~/.ssh/config file" >> "$combined_config"
    echo "" >> "$combined_config"
    
    while IFS= read -r file; do
        generate_vscode_config "$file" >> "$combined_config"
        echo "" >> "$combined_config"
    done <<< "$deployment_files"
    
    log_success "Combined SSH config created!"
    log_info "File: $combined_config"
}

main "$@"
