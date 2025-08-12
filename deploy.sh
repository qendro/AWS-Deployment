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
AWS EC2 Deployment Tool

USAGE:
    $0 [OPTIONS] [CONFIG_FILE]

OPTIONS:
    -h, --help              Show this help message
    -t, --type TYPE         Instance type (default: ${DEFAULT_INSTANCE_TYPE})
    -r, --region REGION     AWS region (default: ${DEFAULT_REGION})
    -a, --app-type TYPE     Application type (default: ${DEFAULT_APP_TYPE})
    -c, --config FILE       Configuration file to use
    --list-configs          List available configuration templates
    --cleanup               Clean up all AWS resources
    --ssh INSTANCE_ID       Connect to instance via SSH

EXAMPLES:
    # Quick deploy with defaults
    $0

    # Deploy with specific instance type
    $0 -t t3.small

    # Deploy using config file
    $0 -c myapp.yml

    # Deploy DXNN/Erlang application
    $0 -a dxnn

    # Cleanup all resources
    $0 --cleanup

    # SSH to running instance
    $0 --ssh i-1234567890abcdef0

SUPPORTED APP TYPES:
    - generic     : Basic Linux instance
    - dxnn        : DXNN/Erlang environment
    - nodejs      : Node.js application server
    - python      : Python application server
    - docker      : Docker host

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
            -t|--type)
                INSTANCE_TYPE="$2"
                shift 2
                ;;
            -r|--region)
                REGION="$2"
                shift 2
                ;;
            -a|--app-type)
                APP_TYPE="$2"
                shift 2
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --list-configs)
                list_configs
                exit 0
                ;;
            --cleanup)
                cleanup_resources
                exit 0
                ;;
            --ssh)
                ssh_to_instance "$2"
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

# List available configuration templates
list_configs() {
    log_info "Available configuration templates:"
    if [[ -d "$CONFIG_DIR" ]]; then
        find "$CONFIG_DIR" -name "*.yml" -o -name "*.yaml" | while read -r config; do
            basename="$(basename "$config")"
            echo "  - $basename"
            # Show description if available
            if command -v yq >/dev/null 2>&1; then
                desc=$(yq e '.metadata.description // ""' "$config" 2>/dev/null)
                [[ -n "$desc" ]] && echo "    Description: $desc"
            fi
        done
    else
        log_warning "No config directory found at $CONFIG_DIR"
    fi
}

# SSH to instance
ssh_to_instance() {
    local instance_id="$1"
    [[ -z "$instance_id" ]] && { log_error "Instance ID required"; exit 1; }
    
    local key_file="$OUTPUT_DIR/${instance_id}-key.pem"
    [[ ! -f "$key_file" ]] && { log_error "SSH key not found: $key_file"; exit 1; }
    
    local public_ip
    public_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null)
    
    [[ "$public_ip" == "None" || -z "$public_ip" ]] && {
        log_error "Could not get public IP for instance $instance_id"
        exit 1
    }
    
    log_info "Connecting to instance $instance_id at $public_ip"
    ssh -i "$key_file" -o StrictHostKeyChecking=no ec2-user@"$public_ip"
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
        --cidr 0.0.0.0/0
    
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
    
    # Save deployment info
    local info_file="$OUTPUT_DIR/deployment-$timestamp.json"
    # Use relative path for SSH key in info and log output
    local ssh_key_path="./output/${key_name}-key.pem"
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
    "ssh_key_file": "$ssh_key_path",
    "ssh_command": "ssh -i $ssh_key_path $SSH_USER@$public_ip"
}
EOF
    
    log_success "Deployment complete!"
    log_info "Instance ID: $instance_id"
    log_info "Public IP: $public_ip"
    log_info "SSH Command: ssh -i $ssh_key_path $SSH_USER@$public_ip"
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
            
            # Add spot watcher files if spot handling is enabled
            if [[ "$SPOT_ENABLED" == "true" ]]; then
                echo "# Install spot watcher and control shim"
                echo "cat > /usr/local/bin/spot-watch.sh << 'SPOT_SCRIPT_EOF'"
                
                # Template the spot-watch.sh with config values
                sed -e "s/CHECKPOINT_DEADLINE=60/CHECKPOINT_DEADLINE=$CHECKPOINT_DEADLINE/g" \
                    -e "s/POLL_INTERVAL=2/POLL_INTERVAL=$POLL_INTERVAL/g" \
                    -e "s|S3_BUCKET=\"dxnn-checkpoints\"|S3_BUCKET=\"$S3_BUCKET\"|g" \
                    -e "s|S3_PREFIX=\"dxnn\"|S3_PREFIX=\"$S3_PREFIX\"|g" \
                    -e "s|JOB_ID=\"dxnn-training-001\"|JOB_ID=\"$JOB_ID\"|g" \
                    -e "s|CONTAINER_NAME=\"dxnn-app\"|CONTAINER_NAME=\"$CONTAINER_NAME\"|g" \
                    -e "s|ERLANG_NODE=\"dxnn@127.0.0.1\"|ERLANG_NODE=\"$ERLANG_NODE\"|g" \
                    -e "s|ERLANG_COOKIE_FILE=\"/var/lib/dxnn/.erlang.cookie\"|ERLANG_COOKIE_FILE=\"$ERLANG_COOKIE_FILE\"|g" \
                    -e "s/USE_REBALANCE=false/USE_REBALANCE=$USE_REBALANCE/g" \
                    scripts/spot-watch.sh
                
                echo "SPOT_SCRIPT_EOF"
                
                echo "cat > /usr/local/bin/dxnn_ctl << 'CTL_SCRIPT_EOF'"
                sed -e "s|ERLANG_NODE=\"dxnn@127.0.0.1\"|ERLANG_NODE=\"$ERLANG_NODE\"|g" \
                    -e "s|ERLANG_COOKIE_FILE=\"/var/lib/dxnn/.erlang.cookie\"|ERLANG_COOKIE_FILE=\"$ERLANG_COOKIE_FILE\"|g" \
                    scripts/dxnn_ctl
                echo "CTL_SCRIPT_EOF"
                
                echo "cat > /etc/systemd/system/spot-watch.service << 'SERVICE_EOF'"
                cat scripts/spot-watch.service
                echo "SERVICE_EOF"
                
                echo "chmod +x /usr/local/bin/spot-watch.sh /usr/local/bin/dxnn_ctl"
                echo "mkdir -p /run"
                echo "systemctl daemon-reload"
                
                # Start watcher after container is running
                echo "systemctl enable spot-watch"
                echo "systemctl start spot-watch"
                
                # Add restore from S3 if enabled
                if [[ "$RESTORE_FROM_S3" == "true" ]]; then
                    echo "cat > /usr/local/bin/restore-from-s3.sh << 'RESTORE_SCRIPT_EOF'"
                    sed -e "s|S3_BUCKET=\"dxnn-checkpoints\"|S3_BUCKET=\"$S3_BUCKET\"|g" \
                        -e "s|S3_PREFIX=\"dxnn\"|S3_PREFIX=\"$S3_PREFIX\"|g" \
                        -e "s|JOB_ID=\"dxnn-training-001\"|JOB_ID=\"$JOB_ID\"|g" \
                        -e "s|CONTAINER_NAME=\"dxnn-app\"|CONTAINER_NAME=\"$CONTAINER_NAME\"|g" \
                        scripts/restore-from-s3.sh
                    echo "RESTORE_SCRIPT_EOF"
                    echo "chmod +x /usr/local/bin/restore-from-s3.sh"
                    echo "/usr/local/bin/restore-from-s3.sh"
                fi
            fi
            
            # Mark setup complete (try for both ubuntu and ec2-user)
            echo 'touch /home/ubuntu/SETUP_COMPLETE || touch /home/ec2-user/SETUP_COMPLETE'
            return
        fi
    fi
    # Fallback to legacy logic if no setup_commands
    local app_type="$1"
    cat << 'EOF'
#!/bin/bash
yum update -y
yum install -y git curl wget htop vim
EOF
    case "$app_type" in
        dxnn)
            cat << 'EOF'
# Install Erlang/OTP
yum install -y erlang
echo "DXNN environment ready" > /home/ec2-user/dxnn-ready.txt
EOF
            ;;
        nodejs)
            cat << 'EOF'
# Install Node.js
curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
yum install -y nodejs npm
echo "Node.js environment ready" > /home/ec2-user/nodejs-ready.txt
EOF
            ;;
        python)
            cat << 'EOF'
# Install Python 3 and pip
yum install -y python3 python3-pip
echo "Python environment ready" > /home/ec2-user/python-ready.txt
EOF
            ;;
        docker)
            cat << 'EOF'
# Install Docker
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user
echo "Docker environment ready" > /home/ec2-user/docker-ready.txt
EOF
            ;;
        generic|*)
            cat << 'EOF'
echo "Generic Linux environment ready" > /home/ec2-user/ready.txt
EOF
            ;;
    esac
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
    
    launch_instance
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi