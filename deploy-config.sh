#!/bin/bash
set -e

# Deploy config.erl and manage GitHub versions on DXNN instances

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
${BLUE}DXNN Config Deployment${NC}

USAGE:
    $0 -i KEY_FILE -h HOST [OPTIONS]

REQUIRED:
    -i, --key FILE          SSH private key file
    -h, --host HOST         Instance hostname or IP

OPTIONS:
    -c, --config FILE       config.erl file to upload
    -b, --branch BRANCH     Git branch/tag to checkout
    -u, --user USER         SSH user (default: ubuntu)
    -s, --start             Start DXNN after deployment
    --no-compile            Skip Erlang compilation
    --dry-run               Show what would be done without executing

EXAMPLES:
    # Deploy config only
    $0 -i output/key.pem -h 54.123.45.67 -c ~/config.erl

    # Deploy config and switch to branch
    $0 -i output/key.pem -h 54.123.45.67 -c ~/config.erl -b feature/new-strategy

    # Switch branch and start training
    $0 -i output/key.pem -h 54.123.45.67 -b v2.1.0 --start

EOF
}

# Parse arguments
SSH_KEY=""
HOST=""
CONFIG_FILE=""
GIT_BRANCH=""
SSH_USER="ubuntu"
START_DXNN=false
COMPILE=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--key) SSH_KEY="$2"; shift 2 ;;
        -h|--host) HOST="$2"; shift 2 ;;
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -b|--branch) GIT_BRANCH="$2"; shift 2 ;;
        -u|--user) SSH_USER="$2"; shift 2 ;;
        -s|--start) START_DXNN=true; shift ;;
        --no-compile) COMPILE=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Validate required arguments
if [[ -z "$SSH_KEY" || -z "$HOST" ]]; then
    log_error "Missing required arguments"
    show_help
    exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
    log_error "SSH key not found: $SSH_KEY"
    exit 1
fi

# Ensure correct permissions on SSH key
chmod 600 "$SSH_KEY" 2>/dev/null || true

if [[ -n "$CONFIG_FILE" && ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

# SSH command wrapper
ssh_exec() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    fi
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${HOST}" "$@"
}

scp_upload() {
    local src="$1"
    local dst="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would upload: $src -> $dst"
        return 0
    fi
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$src" "${SSH_USER}@${HOST}:${dst}"
}

# Check SSH connectivity with retries
log_info "Testing SSH connection to $HOST..."
log_info "Using key: $SSH_KEY"
log_info "User: $SSH_USER"

MAX_RETRIES=5
RETRY_COUNT=0
RETRY_DELAY=5

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if ssh_exec "echo 'SSH OK'" 2>&1; then
        log_success "SSH connection established"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            log_warning "SSH connection failed (attempt $RETRY_COUNT/$MAX_RETRIES), retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
            RETRY_DELAY=$((RETRY_DELAY * 2))  # Exponential backoff
        else
            log_error "Cannot connect to $HOST after $MAX_RETRIES attempts"
            log_error "Troubleshooting:"
            log_error "  1. Check if instance is running and ready"
            log_error "  2. Check security group allows SSH (port 22) from 0.0.0.0/0"
            log_error "  3. Verify key file: ls -la $SSH_KEY"
            log_error "  4. Wait a few minutes for instance to fully boot"
            log_error "  5. Test manually: ssh -i $SSH_KEY ${SSH_USER}@${HOST}"
            exit 1
        fi
    fi
done

# Upload config.erl if provided
if [[ -n "$CONFIG_FILE" ]]; then
    log_info "Uploading config.erl..."
    
    # Validate config locally first
    if [[ "$COMPILE" == "true" && "$DRY_RUN" == "false" ]]; then
        log_info "Validating config.erl syntax..."
        if command -v erlc >/dev/null 2>&1; then
            if ! erlc -o /tmp "$CONFIG_FILE" 2>/dev/null; then
                log_error "Config file has syntax errors"
                exit 1
            fi
            rm -f /tmp/config.beam
            log_success "Config syntax valid"
        else
            log_warning "erlc not found locally, skipping validation"
        fi
    fi
    
    # Upload atomically
    scp_upload "$CONFIG_FILE" "/tmp/config.erl.tmp"
    ssh_exec "mv /tmp/config.erl.tmp /home/ubuntu/dxnn-trader/config.erl"
    
    log_success "Config uploaded"
    
    # Compile on remote
    if [[ "$COMPILE" == "true" ]]; then
        log_info "Compiling config.erl on instance..."
        if ssh_exec "cd /home/ubuntu/dxnn-trader && erlc config.erl" 2>&1; then
            log_success "Config compiled successfully"
        else
            log_error "Config compilation failed"
            exit 1
        fi
    fi
fi

# Switch Git branch if provided
if [[ -n "$GIT_BRANCH" ]]; then
    log_info "Switching to branch/tag: $GIT_BRANCH..."
    
    ssh_exec << EOF
set -e
cd /home/ubuntu/dxnn-trader

# Fetch latest
git fetch origin

# Check if branch/tag exists
if git rev-parse --verify "origin/$GIT_BRANCH" >/dev/null 2>&1; then
    # Remote branch
    git checkout "$GIT_BRANCH"
    git pull origin "$GIT_BRANCH"
elif git rev-parse --verify "$GIT_BRANCH" >/dev/null 2>&1; then
    # Local branch or tag
    git checkout "$GIT_BRANCH"
else
    echo "ERROR: Branch/tag not found: $GIT_BRANCH"
    exit 1
fi

echo "Current commit: \$(git rev-parse --short HEAD)"
EOF
    
    log_success "Switched to $GIT_BRANCH"
    
    # Recompile after git checkout
    if [[ "$COMPILE" == "true" ]]; then
        log_info "Recompiling DXNN after branch switch..."
        ssh_exec "cd /home/ubuntu/dxnn-trader && make clean && make" 2>&1 | tail -5
        log_success "DXNN recompiled"
    fi
fi

# Start DXNN if requested
if [[ "$START_DXNN" == "true" ]]; then
    log_info "Starting DXNN training..."
    
    # Check if already running
    if ssh_exec "tmux has-session -t trader 2>/dev/null"; then
        log_warning "DXNN session already exists"
        read -p "Kill existing session and restart? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            ssh_exec "tmux kill-session -t trader"
            log_info "Killed existing session"
        else
            log_info "Keeping existing session"
            exit 0
        fi
    fi
    
    # Start via wrapper script
    if ssh_exec "test -x /usr/local/bin/dxnn-wrapper.sh"; then
        ssh_exec "nohup /usr/local/bin/dxnn-wrapper.sh > /dev/null 2>&1 &"
        sleep 2
        
        if ssh_exec "tmux has-session -t trader 2>/dev/null"; then
            log_success "DXNN started successfully"
            log_info "Attach with: ssh -i $SSH_KEY ${SSH_USER}@${HOST} -t 'tmux attach -t trader'"
        else
            log_error "DXNN failed to start"
            log_info "Check logs: ssh -i $SSH_KEY ${SSH_USER}@${HOST} 'tail -f /var/log/dxnn-run.log'"
            exit 1
        fi
    else
        log_error "dxnn-wrapper.sh not found on instance"
        exit 1
    fi
fi

# Summary
echo ""
log_success "Deployment complete!"
echo ""
if [[ -n "$CONFIG_FILE" ]]; then
    echo "  Config: Uploaded and compiled"
fi
if [[ -n "$GIT_BRANCH" ]]; then
    echo "  Branch: $GIT_BRANCH"
    current_commit=$(ssh_exec "cd /home/ubuntu/dxnn-trader && git rev-parse --short HEAD" 2>/dev/null || echo "unknown")
    echo "  Commit: $current_commit"
fi
if [[ "$START_DXNN" == "true" ]]; then
    echo "  Status: Running"
fi
echo ""
log_info "Connect: ssh -i $SSH_KEY ${SSH_USER}@${HOST}"
log_info "Attach: tmux attach -t trader"
log_info "Logs: tail -f /var/log/dxnn-run.log"
echo ""
