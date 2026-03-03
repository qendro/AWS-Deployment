#!/bin/bash
set -e

# AMI Manager for DXNN Deployment
# Create, list, and delete custom AMIs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_BASE_AMI="ami-020cba7c55df1f615"  # Ubuntu 24.04 LTS
DEFAULT_INSTANCE_TYPE="t3.medium"
AMI_PREFIX="dxnn-trader"
DXNN_REPO="https://github.com/qendro/DXNN-Trader-v2.git"
DXNN_VERSION="main"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << EOF
${BLUE}DXNN AMI Manager${NC}

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --create                Create new AMI
    --list                  List all DXNN AMIs
    --delete AMI_ID         Delete specific AMI
    --delete-all            Delete all DXNN AMIs
    --force                 Skip confirmation prompts
    
CREATE OPTIONS:
    --name NAME             Custom AMI name (default: auto-generated)
    --dxnn-version VERSION  DXNN-Trader git branch/tag (default: main)
    --region REGION         AWS region (default: us-east-1)
    --base-ami AMI_ID       Base Ubuntu AMI (default: ami-020cba7c55df1f615)
    
EXAMPLES:
    $0 --create
    $0 --create --name "dxnn-trader-custom" --dxnn-version "v2.1.0"
    $0 --list
    $0 --delete ami-0123456789abc
    $0 --delete-all
    $0 --delete-all --force

EOF
}

# Parse arguments
ACTION=""
AMI_NAME=""
AMI_ID=""
FORCE=false
REGION="${AWS_DEFAULT_REGION:-$DEFAULT_REGION}"
BASE_AMI="$DEFAULT_BASE_AMI"

while [[ $# -gt 0 ]]; do
    case $1 in
        --create) ACTION="create"; shift ;;
        --list) ACTION="list"; shift ;;
        --delete) ACTION="delete"; AMI_ID="$2"; shift 2 ;;
        --delete-all) ACTION="delete-all"; shift ;;
        --force) FORCE=true; shift ;;
        --name) AMI_NAME="$2"; shift 2 ;;
        --dxnn-version) DXNN_VERSION="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --base-ami) BASE_AMI="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

[[ -z "$ACTION" ]] && { show_help; exit 1; }

export AWS_DEFAULT_REGION="$REGION"

# Check AWS CLI
if ! command -v aws >/dev/null 2>&1; then
    log_error "AWS CLI not found"
    exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS credentials not configured"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# List AMIs
list_amis() {
    log_info "Listing DXNN AMIs in region: $REGION"
    
    amis=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=${AMI_PREFIX}-*" \
        --query 'Images[*].[ImageId,Name,CreationDate,State]' \
        --output text | sort -k3 -r)
    
    if [[ -z "$amis" ]]; then
        log_warning "No DXNN AMIs found"
        return 0
    fi
    
    echo ""
    printf "%-22s %-50s %-25s %-10s\n" "AMI ID" "Name" "Created" "State"
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────"
    echo "$amis" | while read -r ami_id name created state; do
        printf "%-22s %-50s %-25s %-10s\n" "$ami_id" "$name" "$created" "$state"
    done
    echo ""
}

# Delete specific AMI
delete_ami() {
    local ami_id="$1"
    
    log_info "Fetching AMI details: $ami_id"
    
    ami_info=$(aws ec2 describe-images \
        --image-ids "$ami_id" \
        --query 'Images[0].[Name,BlockDeviceMappings[0].Ebs.SnapshotId]' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "$ami_info" ]]; then
        log_error "AMI not found: $ami_id"
        return 1
    fi
    
    ami_name=$(echo "$ami_info" | cut -f1)
    snapshot_id=$(echo "$ami_info" | cut -f2)
    
    if [[ "$FORCE" != "true" ]]; then
        echo ""
        log_warning "About to delete:"
        echo "  AMI ID: $ami_id"
        echo "  Name: $ami_name"
        echo "  Snapshot: $snapshot_id"
        echo ""
        read -p "Are you sure? (yes/no): " confirmation
        [[ "$confirmation" != "yes" ]] && { log_info "Cancelled"; return 0; }
    fi
    
    log_info "Deregistering AMI: $ami_id"
    aws ec2 deregister-image --image-id "$ami_id"
    
    if [[ -n "$snapshot_id" && "$snapshot_id" != "None" ]]; then
        log_info "Deleting snapshot: $snapshot_id"
        aws ec2 delete-snapshot --snapshot-id "$snapshot_id" || log_warning "Failed to delete snapshot"
    fi
    
    log_success "Deleted AMI: $ami_id"
}

# Delete all AMIs
delete_all_amis() {
    log_info "Finding all DXNN AMIs..."
    
    ami_ids=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=${AMI_PREFIX}-*" \
        --query 'Images[*].ImageId' \
        --output text)
    
    if [[ -z "$ami_ids" ]]; then
        log_warning "No DXNN AMIs found"
        return 0
    fi
    
    ami_count=$(echo "$ami_ids" | wc -w)
    
    if [[ "$FORCE" != "true" ]]; then
        echo ""
        log_warning "About to delete $ami_count AMI(s):"
        list_amis
        read -p "Are you sure? (yes/no): " confirmation
        [[ "$confirmation" != "yes" ]] && { log_info "Cancelled"; return 0; }
    fi
    
    for ami_id in $ami_ids; do
        delete_ami "$ami_id"
    done
    
    log_success "Deleted $ami_count AMI(s)"
}

# Create AMI
create_ami() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local ami_name="${AMI_NAME:-${AMI_PREFIX}-${timestamp}}"
    local key_name="ami-build-key-${timestamp}"
    local sg_name="ami-build-sg-${timestamp}"
    local instance_name="ami-build-${timestamp}"
    
    log_info "Creating DXNN AMI: $ami_name"
    log_info "Base AMI: $BASE_AMI"
    log_info "DXNN Version: $DXNN_VERSION"
    log_info "Region: $REGION"
    
    # Generate SSH key
    log_info "Generating SSH key pair..."
    local key_file="$OUTPUT_DIR/${key_name}.pem"
    aws ec2 create-key-pair \
        --key-name "$key_name" \
        --query 'KeyMaterial' \
        --output text > "$key_file"
    chmod 600 "$key_file"
    
    # Create security group
    log_info "Creating security group..."
    aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "Temporary SG for AMI creation" >/dev/null
    
    aws ec2 authorize-security-group-ingress \
        --group-name "$sg_name" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 >/dev/null
    
    # Create user-data script
    local user_data_file="$OUTPUT_DIR/ami-build-user-data.sh"
    cat > "$user_data_file" << 'USERDATA_EOF'
#!/bin/bash
set -e

# Update system
apt-get update -y
apt-get upgrade -y

# Install packages
apt-get install -y \
    erlang \
    git \
    vim \
    htop \
    tree \
    build-essential \
    tmux \
    chrony \
    jq \
    openssl \
    unzip \
    curl \
    wget

# Configure chrony
systemctl enable chrony
systemctl start chrony

# Install yq
curl -L https://github.com/mikefarah/yq/releases/download/v4.35.1/yq_linux_amd64 \
    -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# Install AWS CLI v2
tmpdir=$(mktemp -d)
arch=$(uname -m)
if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
    cli_url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
else
    cli_url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
fi
curl -Ls "$cli_url" -o "$tmpdir/awscliv2.zip"
unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
"$tmpdir/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
rm -rf "$tmpdir"

# Create directory structure
mkdir -p /var/lib/dxnn/checkpoints
mkdir -p /var/log
mkdir -p /opt

# Set permissions
chown -R ubuntu:ubuntu /var/lib/dxnn
chmod 755 /var/lib/dxnn/checkpoints

# System optimizations
cat >> /etc/sysctl.conf << 'SYSCTL_EOF'
vm.swappiness=10
net.core.rmem_max=134217728
net.core.wmem_max=134217728
SYSCTL_EOF
sysctl -p

# Logrotate for spot-watch
cat > /etc/logrotate.d/spot-watch << 'LOGROTATE_EOF'
/var/log/spot-watch.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
LOGROTATE_EOF

# Create log files
touch /var/log/spot-watch.log
touch /var/log/dxnn-run.log
touch /var/log/dxnn-setup.log
touch /var/log/dxnn-restore.log
chown ubuntu:ubuntu /var/log/dxnn-*.log
chmod 644 /var/log/dxnn-*.log

# Mark setup complete
touch /root/ami-setup-complete
echo "AMI setup completed at $(date -u)" > /root/ami-setup-complete

USERDATA_EOF
    
    # Launch build instance
    log_info "Launching build instance..."
    local instance_id
    instance_id=$(aws ec2 run-instances \
        --image-id "$BASE_AMI" \
        --instance-type "$DEFAULT_INSTANCE_TYPE" \
        --key-name "$key_name" \
        --security-groups "$sg_name" \
        --user-data "file://$user_data_file" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$instance_name},{Key=Purpose,Value=AMI-Build}]" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    log_success "Build instance launched: $instance_id"
    
    # Wait for instance to be running
    log_info "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$instance_id"
    
    # Get public IP
    local public_ip
    public_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    log_info "Instance IP: $public_ip"
    
    # Wait for SSH
    log_info "Waiting for SSH access..."
    for i in {1..30}; do
        if ssh -i "$key_file" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null ubuntu@"$public_ip" "echo 'SSH ready'" >/dev/null 2>&1; then
            log_success "SSH connection established"
            break
        fi
        log_info "SSH attempt $i/30..."
        sleep 10
    done
    
    # Wait for user-data to complete
    log_info "Waiting for system setup to complete..."
    for i in {1..60}; do
        if ssh -i "$key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@"$public_ip" "test -f /root/ami-setup-complete" 2>/dev/null; then
            log_success "System setup completed"
            break
        fi
        log_info "Setup check $i/60..."
        sleep 10
    done
    
    # Upload scripts
    log_info "Uploading DXNN scripts..."
    scp -i "$key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        scripts/*.sh ubuntu@"$public_ip":/tmp/ 2>/dev/null || true
    scp -i "$key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        scripts/dxnn_ctl ubuntu@"$public_ip":/tmp/ 2>/dev/null || true
    scp -i "$key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        scripts/*.service ubuntu@"$public_ip":/tmp/ 2>/dev/null || true
    
    # Install scripts and clone DXNN
    log_info "Installing scripts and cloning DXNN-Trader..."
    ssh -i "$key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@"$public_ip" << EOF
set -e

# Install scripts
sudo cp /tmp/*.sh /usr/local/bin/ 2>/dev/null || true
sudo cp /tmp/dxnn_ctl /usr/local/bin/ 2>/dev/null || true
sudo chmod +x /usr/local/bin/*.sh /usr/local/bin/dxnn_ctl

# Install systemd services
sudo cp /tmp/*.service /etc/systemd/system/ 2>/dev/null || true
sudo systemctl daemon-reload

# Clone DXNN-Trader to /opt
cd /opt
sudo git clone $DXNN_REPO dxnn-trader-base
cd dxnn-trader-base
sudo git checkout $DXNN_VERSION
sudo chown -R ubuntu:ubuntu /opt/dxnn-trader-base

# Cleanup
rm -f /tmp/*.sh /tmp/*.service /tmp/dxnn_ctl

echo "Installation completed at \$(date -u)" | sudo tee -a /root/ami-setup-complete
EOF
    
    log_success "Scripts and DXNN installed"
    
    # Stop instance
    log_info "Stopping instance for AMI creation..."
    aws ec2 stop-instances --instance-ids "$instance_id" >/dev/null
    aws ec2 wait instance-stopped --instance-ids "$instance_id"
    
    # Create AMI
    log_info "Creating AMI image..."
    local new_ami_id
    new_ami_id=$(aws ec2 create-image \
        --instance-id "$instance_id" \
        --name "$ami_name" \
        --description "DXNN Trader AMI - DXNN:$DXNN_VERSION - Created:$timestamp" \
        --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=$ami_name},{Key=DXNNVersion,Value=$DXNN_VERSION},{Key=Created,Value=$timestamp}]" \
        --query 'ImageId' \
        --output text)
    
    log_success "AMI creation initiated: $new_ami_id"
    
    # Wait for AMI to be available
    log_info "Waiting for AMI to be available (this may take several minutes)..."
    aws ec2 wait image-available --image-ids "$new_ami_id"
    
    log_success "AMI is now available: $new_ami_id"
    
    # Cleanup
    log_info "Cleaning up build resources..."
    aws ec2 terminate-instances --instance-ids "$instance_id" >/dev/null
    aws ec2 delete-key-pair --key-name "$key_name" 2>/dev/null || true
    rm -f "$key_file"
    
    # Wait a bit before deleting security group
    sleep 10
    aws ec2 delete-security-group --group-name "$sg_name" 2>/dev/null || \
        log_warning "Could not delete security group (may need manual cleanup)"
    
    rm -f "$user_data_file"
    
    echo ""
    log_success "AMI created successfully!"
    echo ""
    echo "  AMI ID: $new_ami_id"
    echo "  Name: $ami_name"
    echo "  DXNN Version: $DXNN_VERSION"
    echo "  Region: $REGION"
    echo ""
    log_info "Update your config YAML with: ami_id: \"$new_ami_id\""
    echo ""
}

# Main execution
case "$ACTION" in
    create) create_ami ;;
    list) list_amis ;;
    delete) delete_ami "$AMI_ID" ;;
    delete-all) delete_all_amis ;;
    *) log_error "Unknown action: $ACTION"; exit 1 ;;
esac
