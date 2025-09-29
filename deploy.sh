#!/bin/bash
set -e

# Export AWS credentials from environment (needed inside container)
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}


# AWS EC2 Deployment Script
# Supports config-driven deployments for any application type

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# Default values
DEFAULT_INSTANCE_TYPE="t2.micro"
DEFAULT_REGION="us-east-1"
DEFAULT_APP_TYPE="generic"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Help function
show_help() {
    cat << EOF
AWS DXNN Spot Instance Deployment

USAGE:
    $0 [OPTIONS] [CONFIG_FILE]

OPTIONS:
    -h, --help              Show this help message
    -c, --config FILE       Configuration file to use
    --cleanup               Clean up all AWS resources

EXAMPLES:
    $0 -c config/dxnn-spot-prod.yml    # Deploy production
    $0 -c config/dxnn-spot.yml         # Deploy development
    $0 --cleanup                       # Clean up resources

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --cleanup)
                cleanup_resources
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # Positional argument - treat as config file
                CONFIG_FILE="$1"
                shift
                ;;
        esac
    done
}


# Create necessary directories
create_directories() {
    mkdir -p "$OUTPUT_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$TEMPLATES_DIR"
}

# Generate SSH key pair
generate_ssh_key() {
    local key_name="$1"
    local key_file="$OUTPUT_DIR/${key_name}-key.pem"
    
    if [[ -f "$key_file" ]]; then
        log_info "SSH key already exists: $key_file"
        return 0
    fi
    
    log_info "Generating SSH key pair: $key_name"
    aws ec2 create-key-pair \
        --key-name "$key_name" \
        --query 'KeyMaterial' \
        --output text > "$key_file"
    
    chmod 600 "$key_file"
    log_success "SSH key created: $key_file"
}

# Create security group
create_security_group() {
    local group_name="$1"
    local description="AWS-Deployment security group"
    
    # Check if security group exists
    if aws ec2 describe-security-groups --group-names "$group_name" >/dev/null 2>&1; then
        log_info "Security group already exists: $group_name"
        return 0
    fi
    
    log_info "Creating security group: $group_name"
    aws ec2 create-security-group \
        --group-name "$group_name" \
        --description "$description"
    
    # Add SSH access
    aws ec2 authorize-security-group-ingress \
        --group-name "$group_name" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 >/dev/null
    
    log_success "Security group created: $group_name"
}

# Get latest Amazon Linux 2 AMI
get_latest_ami() {
    aws ec2 describe-images \
        --owners amazon \
        --filters \
            "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
            "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text
}

log_launch_details() {
    local instance_id="$1"
    local public_ip="$2"
    local instance_type="$3"
    local key_path="$4"
    local ssh_user="$5"
    local app_type="$6"
    local market_type="$7"
    local spot_max_price="$8"
    
    # Get current timestamp
    local utc_ts=$(date -u +%FT%TZ)
    
    # Get or generate RUN_ID
    local run_id="${RUN_ID:-$(date -u +%Y%m%d-%H%M%SZ)}"
    
    # Get JOB_ID (empty if not set)
    local job_id="${JOB_ID:-}"
    
    # Get git info
    local git_repo=$(git config --get remote.origin.url 2>/dev/null || echo "unknown")
    local git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    
    # Create log file if it doesn't exist
    local log_file="./run-log.md"
    if [[ ! -f "$log_file" ]]; then
        cat > "$log_file" << 'EOF'
# DXNN Launch Log

EOF
    fi
    
    # Create temporary file for atomic write
    local temp_file=$(mktemp)
    
    # Copy existing content and append new entries
    cp "$log_file" "$temp_file"
    
    # Add separator line
    echo "" >> "$temp_file"
    echo "═══════════════════════════════════════════════════════════════════" >> "$temp_file"
    echo "$utc_ts | run-id=$run_id" >> "$temp_file"
    echo "═══════════════════════════════════════════════════════════════════" >> "$temp_file"
    echo "" >> "$temp_file"
    
    # Add SSH command
    echo "ssh -i $key_path $ssh_user@$public_ip" >> "$temp_file"
    
    # Add instance details
    echo "Instance: $instance_id | $instance_type" >> "$temp_file"
    
    # Add market info
    if [[ "$market_type" == "spot" ]]; then
        echo "Market: spot | Max Price: \$$spot_max_price" >> "$temp_file"
    else
        echo "Market: on-demand" >> "$temp_file"
    fi
    
    # Add job and app info
    if [[ -n "$job_id" ]]; then
        echo "Job: $job_id" >> "$temp_file"
    fi
    echo "App: $app_type" >> "$temp_file"
    
    # Add git info
    echo "Repo: $git_repo | $git_branch" >> "$temp_file"
    
    # Atomic move
    mv "$temp_file" "$log_file"
    
    log_info "Launch logged to $log_file"
}

# Wait for SSH to be available
wait_for_ssh() {
    local public_ip="$1"
    local ssh_key_path="$2"
    local max_attempts=30
    
    log_info "Waiting for SSH access..."
    log_info "SSH command: ssh -i $ssh_key_path $SSH_USER@$public_ip"
    for i in $(seq 1 $max_attempts); do
        if ssh -i "$ssh_key_path" -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@$public_ip" "echo 'SSH ready'" >/dev/null 2>&1; then
            log_success "SSH connection established"
            return 0
        fi
        log_info "SSH attempt $i/$max_attempts..."
        sleep 10
    done
    log_error "SSH connection failed after $max_attempts attempts"
    return 1
}

# Upload scripts to instance via SCP
upload_scripts() {
    local public_ip="$1"
    local ssh_key_path="$2"
    
    # Wait for SSH to be ready
    wait_for_ssh "$public_ip" "$ssh_key_path" || return 1
    
    log_info "Uploading scripts to instance..."
    
    # Upload all scripts
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null scripts/*.sh "$SSH_USER@$public_ip:/tmp/" || {
        log_error "Failed to upload scripts"
        return 1
    }
    
    # Upload service files if they exist
    [[ -f scripts/*.service ]] && scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null scripts/*.service "$SSH_USER@$public_ip:/tmp/" 2>/dev/null
    
    # Install and configure scripts
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@$public_ip" << EOF
        # Install scripts
        sudo cp /tmp/*.sh /usr/local/bin/ 2>/dev/null || true
        sudo chmod +x /usr/local/bin/*.sh

        # Configure spot handling if enabled
        if [[ "$SPOT_ENABLED" == "true" ]]; then
            # Configure spot-watch.sh with deployment-specific values
            sudo sed -i "s/CHECKPOINT_DEADLINE=60/CHECKPOINT_DEADLINE=$CHECKPOINT_DEADLINE/g" /usr/local/bin/spot-watch.sh
            sudo sed -i "s/POLL_INTERVAL=2/POLL_INTERVAL=$POLL_INTERVAL/g" /usr/local/bin/spot-watch.sh
            sudo sed -i "s|S3_BUCKET=\"dxnn-checkpoints\"|S3_BUCKET=\"$S3_BUCKET\"|g" /usr/local/bin/spot-watch.sh
            sudo sed -i "s|S3_PREFIX=\"dxnn\"|S3_PREFIX=\"$S3_PREFIX\"|g" /usr/local/bin/spot-watch.sh
            sudo sed -i "s|JOB_ID=\"dxnn-training-001\"|JOB_ID=\"$JOB_ID\"|g" /usr/local/bin/spot-watch.sh
            sudo sed -i "s|CONTAINER_NAME=\"dxnn-app\"|CONTAINER_NAME=\"$CONTAINER_NAME\"|g" /usr/local/bin/spot-watch.sh
            sudo sed -i "s|ERLANG_NODE=\"dxnn@127.0.0.1\"|ERLANG_NODE=\"$ERLANG_NODE\"|g" /usr/local/bin/spot-watch.sh
            sudo sed -i "s|ERLANG_COOKIE_FILE=\"/var/lib/dxnn/.erlang.cookie\"|ERLANG_COOKIE_FILE=\"$ERLANG_COOKIE_FILE\"|g" /usr/local/bin/spot-watch.sh
            sudo sed -i "s/USE_REBALANCE=false/USE_REBALANCE=$USE_REBALANCE/g" /usr/local/bin/spot-watch.sh

            # Install service files
            sudo cp /tmp/*.service /etc/systemd/system/ 2>/dev/null || true
            sudo systemctl daemon-reload
            sudo systemctl enable spot-watch 2>/dev/null || true
            sudo systemctl start spot-watch 2>/dev/null || true
        fi

        # Create SCRIPTS_READY trigger file for user-data autostart
        touch /home/ubuntu/SCRIPTS_READY

        # Cleanup temp files
        rm -f /tmp/*.sh /tmp/*.service
EOF
    
    log_success "Scripts uploaded and configured"
}

# Launch EC2 instance
launch_instance() {
    local instance_type="${INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}"
    local region="${REGION:-$DEFAULT_REGION}"
    local app_type="${APP_TYPE:-$DEFAULT_APP_TYPE}"
    
    # Generate unique names
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local key_name="aws-deployment-key-$timestamp"
    local sg_name="aws-deployment-sg-$timestamp"
    local instance_name="aws-deployment-$app_type-$timestamp"
    
    log_info "Deploying $app_type application on $instance_type in $region"
    
    # Create SSH key and security group
    generate_ssh_key "$key_name"
    create_security_group "$sg_name"
    
    # Get AMI ID
    local ami_id="$AMI_ID"
    [[ -z "$ami_id" ]] && { log_error "Failed to get AMI ID"; exit 1; }
    
    log_info "Using AMI: $ami_id"
    
    # Prepare user data script
    local user_data_file="$OUTPUT_DIR/user-data-$timestamp.sh"
    generate_user_data "$app_type" > "$user_data_file"
    
    # Launch instance
    log_info "Launching EC2 instance..."
    local instance_id
    
    # Build run-instances command with optional availability zone
    local run_cmd="aws ec2 run-instances \
        --image-id \"$ami_id\" \
        --count 1 \
        --instance-type \"$instance_type\" \
        --key-name \"$key_name\" \
        --security-groups \"$sg_name\" \
        --user-data \"file://$user_data_file\" \
        --tag-specifications \"ResourceType=instance,Tags=[{Key=Name,Value=$instance_name},{Key=AppType,Value=$app_type},{Key=CreatedBy,Value=AWS-Deployment}]\""
    
    # Add IAM instance profile if specified
    if [[ -n "$IAM_INSTANCE_PROFILE" && "$IAM_INSTANCE_PROFILE" != "null" ]]; then
        run_cmd="$run_cmd --iam-instance-profile Name=\"$IAM_INSTANCE_PROFILE\""
        log_info "Using IAM instance profile: $IAM_INSTANCE_PROFILE"
    fi
    
    # Add spot instance support if enabled
    if [[ "$MARKET_TYPE" == "spot" ]]; then
        run_cmd="$run_cmd --instance-market-options MarketType=spot,SpotOptions={MaxPrice=$SPOT_MAX_PRICE}"
        log_info "Launching SPOT instance with max price: $SPOT_MAX_PRICE"
    fi
    
    # Add availability zone if specified in config
    if [[ -n "$AVAILABILITY_ZONE" && "$AVAILABILITY_ZONE" != "null" ]]; then
        log_info "Using availability zone: $AVAILABILITY_ZONE"
        run_cmd="$run_cmd --placement AvailabilityZone=\"$AVAILABILITY_ZONE\""
    fi
    
    # Add instance-initiated shutdown behavior for spot instances
    SHUTDOWN_BEHAVIOR=$(yq e '.aws.instance_initiated_shutdown_behavior' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$SHUTDOWN_BEHAVIOR" && "$SHUTDOWN_BEHAVIOR" != "null" ]]; then
        run_cmd="$run_cmd --instance-initiated-shutdown-behavior \"$SHUTDOWN_BEHAVIOR\""
        log_info "Instance shutdown behavior: $SHUTDOWN_BEHAVIOR"
    fi
    
    run_cmd="$run_cmd --query 'Instances[0].InstanceId' --output text"
    
    instance_id=$(eval $run_cmd)
    
    [[ -z "$instance_id" ]] && { log_error "Failed to launch instance"; exit 1; }
    
    log_success "Instance launched: $instance_id"
    
    # Wait for instance to be running
    log_info "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$instance_id"
    
    # Get public IP
    local public_ip
    public_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    # Upload and configure scripts via SCP
    upload_scripts "$public_ip" "$OUTPUT_DIR/${key_name}-key.pem"
    
    # Save deployment info
    local info_file="$OUTPUT_DIR/deployment-$timestamp.json"
    # Use relative path for SSH key in info and log output
    local ssh_key_path_relative="./output/${key_name}-key.pem"
    cat > "$info_file" << EOF
{
    "timestamp": "$timestamp",
    "instance_id": "$instance_id",
    "instance_type": "$instance_type",
    "region": "$region",
    "app_type": "$app_type",
    "public_ip": "$public_ip",
    "key_name": "$key_name",
    "security_group": "$sg_name",
    "ssh_key_file": "$ssh_key_path_relative",
    "ssh_command": "ssh -i $ssh_key_path_relative $SSH_USER@$public_ip"
}
EOF
    
    # Log launch details
    log_launch_details "$instance_id" "$public_ip" "$instance_type" "$ssh_key_path_relative" "$SSH_USER" "$app_type" "$MARKET_TYPE" "$SPOT_MAX_PRICE"
    
    log_success "Deployment complete!"
    log_info "Instance ID: $instance_id"
    log_info "Public IP: $public_ip"
    log_info "SSH Command: ssh -i $ssh_key_path_relative $SSH_USER@$public_ip"
    log_info "Deployment info saved to: $info_file"
}

# Generate user data script based on config file setup_commands (generic for all types)
generate_user_data() {
    if command -v yq >/dev/null 2>&1 && [[ -n "$CONFIG_FILE" ]]; then
        # Check if setup_commands exists and is a non-empty array
        local setup_count
        setup_count=$(yq e '.application.setup_commands | length' "$CONFIG_FILE" 2>/dev/null)
        if [[ "$setup_count" =~ ^[1-9][0-9]*$ ]]; then
            echo '#!/bin/bash'
            yq e '.application.setup_commands[]' "$CONFIG_FILE" | while read -r cmd; do
                echo "$cmd"
            done
            
            echo "# Scripts will be uploaded via SCP after instance is ready"

            # Mark setup complete (try for both ubuntu and ec2-user)
            echo 'touch /home/ubuntu/SETUP_COMPLETE || touch /home/ec2-user/SETUP_COMPLETE'
            return
        fi
    fi
    # Fallback for configs without setup_commands
    cat << 'EOF'
#!/bin/bash
apt-get update -y
apt-get install -y git curl wget htop vim
echo "Basic environment ready" > /home/ubuntu/ready.txt
EOF
}

# Cleanup AWS resources
cleanup_resources() {
    log_warning "This will terminate ALL AWS-Deployment instances and delete associated resources!"
    echo -n "Are you sure? (yes/no): "
    read -r confirmation
    
    [[ "$confirmation" != "yes" ]] && { log_info "Cleanup cancelled"; exit 0; }
    
    log_info "Finding AWS-Deployment resources..."
    
    # Find instances with our tag
    local instances
    instances=$(aws ec2 describe-instances \
        --filters "Name=tag:CreatedBy,Values=AWS-Deployment" "Name=instance-state-name,Values=running,pending,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
    
    if [[ -n "$instances" ]]; then
        log_info "Terminating instances: $instances"
        aws ec2 terminate-instances --instance-ids $instances
        log_info "Waiting for instances to terminate..."
        aws ec2 wait instance-terminated --instance-ids $instances
    fi
    
    # Cleanup key pairs
    local key_pairs
    key_pairs=$(aws ec2 describe-key-pairs \
        --query 'KeyPairs[?starts_with(KeyName, `aws-deployment-key-`)].KeyName' \
        --output text)
    
    for key in $key_pairs; do
        log_info "Deleting key pair: $key"
        aws ec2 delete-key-pair --key-name "$key"
    done
    
    # Cleanup security groups
    local security_groups
    security_groups=$(aws ec2 describe-security-groups \
        --query 'SecurityGroups[?starts_with(GroupName, `aws-deployment-sg-`)].GroupName' \
        --output text)
    
    for sg in $security_groups; do
        log_info "Deleting security group: $sg"
        aws ec2 delete-security-group --group-name "$sg" || true
    done
    
    log_success "Cleanup complete!"
}

# Validate spot configuration
validate_spot_config() {
    if [[ "$SPOT_ENABLED" == "true" ]]; then
        # Required fields when spot handling is enabled
        [[ -z "$S3_BUCKET" ]] && { log_error "s3_bucket is required when spot_handling.enabled=true"; exit 1; }
        [[ -z "$CONTAINER_NAME" ]] && { log_error "container_name is required when spot_handling.enabled=true"; exit 1; }
        
        # Required fields when S3 restore is enabled
        if [[ "$RESTORE_FROM_S3" == "true" ]]; then
            [[ -z "$JOB_ID" ]] && { log_error "job_id is required when restore_from_s3_on_boot=true"; exit 1; }
        fi
        
        log_info "Spot configuration validated successfully"
    fi
}

# Load configuration file
load_config() {
    local config_file="$1"
    [[ ! -f "$config_file" ]] && { log_error "Config file not found: $config_file"; exit 1; }
    
    if command -v yq >/dev/null 2>&1; then
        # Extract values from YAML
        INSTANCE_TYPE=$(yq e '.aws.instance_type // env(INSTANCE_TYPE) // "t2.micro"' "$config_file")
        REGION=$(yq e '.aws.region // env(REGION) // "us-east-1"' "$config_file")
        AVAILABILITY_ZONE=$(yq e '.aws.availability_zone' "$config_file")
        IAM_INSTANCE_PROFILE=$(yq e '.aws.iam_instance_profile' "$config_file")
        APP_TYPE=$(yq e '.application.type // env(APP_TYPE) // "generic"' "$config_file")
        AMI_ID=$(yq e '.aws.ami_id' "$config_file")
        SSH_USER=$(yq e '.aws.ssh_user' "$config_file")
        
        # Load spot handling configuration
        MARKET_TYPE=$(yq e '.aws.market_type' "$config_file")
        SPOT_MAX_PRICE=$(yq e '.aws.spot_max_price' "$config_file")
        SPOT_ENABLED=$(yq e '.spot_handling.enabled' "$config_file")
        CHECKPOINT_DEADLINE=$(yq e '.spot_handling.checkpoint_deadline_seconds' "$config_file")
        POLL_INTERVAL=$(yq e '.spot_handling.poll_interval_seconds' "$config_file")
        S3_BUCKET=$(yq e '.spot_handling.s3_bucket' "$config_file")
        S3_PREFIX=$(yq e '.spot_handling.s3_prefix' "$config_file")
        JOB_ID=$(yq e '.spot_handling.job_id' "$config_file")
        CONTAINER_NAME=$(yq e '.spot_handling.container_name' "$config_file")
        ERLANG_NODE=$(yq e '.spot_handling.erlang_node' "$config_file")
        ERLANG_COOKIE_FILE=$(yq e '.spot_handling.erlang_cookie_file' "$config_file")
        RESTORE_FROM_S3=$(yq e '.spot_handling.restore_from_s3_on_boot' "$config_file")
        USE_REBALANCE=$(yq e '.spot_handling.use_rebalance_recommendation' "$config_file")
        
        if [[ -z "$AMI_ID" || "$AMI_ID" == "null" ]]; then
            log_error "AMI ID (aws.ami_id) must be specified in the config file."
            exit 1
        fi
        if [[ -z "$SSH_USER" || "$SSH_USER" == "null" ]]; then
            log_error "SSH user (aws.ssh_user) must be specified in the config file."
            exit 1
        fi
        
        # Validate spot configuration
        validate_spot_config
        
        log_info "Loaded configuration from $config_file"
        log_info "Instance Type: $INSTANCE_TYPE"
        log_info "Region: $REGION"
        log_info "App Type: $APP_TYPE"
        log_info "AMI ID: $AMI_ID"
        log_info "SSH User: $SSH_USER"
        if [[ "$SPOT_ENABLED" == "true" ]]; then
            log_info "Spot Enabled: $SPOT_ENABLED"
            log_info "S3 Bucket: $S3_BUCKET"
            log_info "Job ID: $JOB_ID"
        fi
    else
        log_warning "yq not available, using environment variables or defaults"
        log_error "AMI ID must be specified and yq is required."
        exit 1
    fi
}

# Main function
main() {
    # Check AWS CLI
    if ! command -v aws >/dev/null 2>&1; then
        log_error "AWS CLI not found. Please install it first."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials not configured. Run: aws configure"
        exit 1
    fi
    
    create_directories
    parse_args "$@"
    
    # Load config file if specified
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"
    
    # Set defaults if not set
    INSTANCE_TYPE="${INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}"
    REGION="${REGION:-$DEFAULT_REGION}"
    APP_TYPE="${APP_TYPE:-$DEFAULT_APP_TYPE}"
    
    # Set AWS region
    export AWS_DEFAULT_REGION="$REGION"
    
    # Create S3 bucket if it doesn't exist
    if [[ "$SPOT_ENABLED" == "true" ]]; then
        if ! aws s3 ls "s3://$S3_BUCKET" >/dev/null 2>&1; then
            log_info "Creating S3 bucket: $S3_BUCKET"
            aws s3 mb "s3://$S3_BUCKET" --region "$REGION"
            log_success "S3 bucket created: $S3_BUCKET"
        fi
        
        # S3 will be used only for checkpoint storage
        log_info "S3 folder structure:"
        log_info "  s3://$S3_BUCKET/$S3_PREFIX/$JOB_ID/RUN_ID/ (checkpoints & logs)"
    fi
    
    launch_instance
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
