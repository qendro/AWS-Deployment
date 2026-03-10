#!/bin/bash
set -e

# Deploy files and manage GitHub versions on DXNN instances

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
    -c, --config FILE...    One or more files to upload (optional)
    -b, --branch BRANCH     Git branch/tag to checkout
    -u, --user USER         SSH user (default: ubuntu)
    -s, --start             Start DXNN after deployment
    --auto-terminate        Auto-terminate instance on successful completion
    --no-compile            Skip Erlang compilation
    --dry-run               Show what would be done without executing

EXAMPLES:
    # Pull latest GitHub and compile (no file upload)
    $0 -i output/key.pem -h 54.123.45.67 -b main

    # Deploy single config file
    $0 -i output/key.pem -h 54.123.45.67 -c ~/config.erl

    # Deploy multiple files
    $0 -i output/key.pem -h 54.123.45.67 -c ~/config.erl ~/custom.hrl ~/data.txt

    # Deploy files and switch branch
    $0 -i output/key.pem -h 54.123.45.67 -c ~/config.erl -b feature/new-strategy

    # Switch branch and start training (no files)
    $0 -i output/key.pem -h 54.123.45.67 -b v2.1.0 --start

    # Deploy with auto-terminate on successful completion
    $0 -i output/key.pem -h 54.123.45.67 -c ~/config.erl -b main --start --auto-terminate

EOF
}

# Parse arguments
SSH_KEY=""
HOST=""
CONFIG_FILES=()
GIT_BRANCH=""
SSH_USER="ubuntu"
START_DXNN=false
AUTO_TERMINATE=false
COMPILE=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--key) SSH_KEY="$2"; shift 2 ;;
        -h|--host) HOST="$2"; shift 2 ;;
        -c|--config) 
            shift
            # Collect all files until next flag
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                CONFIG_FILES+=("$1")
                shift
            done
            ;;
        -b|--branch) GIT_BRANCH="$2"; shift 2 ;;
        -u|--user) SSH_USER="$2"; shift 2 ;;
        -s|--start) START_DXNN=true; shift ;;
        --auto-terminate) AUTO_TERMINATE=true; shift ;;
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

# Pull latest from GitHub (always, regardless of file uploads)
GIT_BRANCH=${GIT_BRANCH:-"main"}  # Default to main if not specified
log_info "Pulling latest code from branch: $GIT_BRANCH..."

ssh_exec << EOF
set -e
cd /home/ubuntu/dxnn-trader

# Stash any local changes
if ! git diff-index --quiet HEAD --; then
    echo "Stashing local changes..."
    git stash push -m "Auto-stash before deploy-config.sh pull at \$(date)"
fi

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

log_success "Pulled latest from $GIT_BRANCH"

# Upload files if provided (overwrites GitHub files)
if [[ ${#CONFIG_FILES[@]} -gt 0 ]]; then
    log_info "Uploading ${#CONFIG_FILES[@]} file(s) to override GitHub versions..."
    
    for config_file in "${CONFIG_FILES[@]}"; do
        filename=$(basename "$config_file")
        log_info "  Uploading: $filename"
        
        # Upload atomically (skip local validation - will validate on remote)
        scp_upload "$config_file" "/tmp/${filename}.tmp"
        ssh_exec "mv /tmp/${filename}.tmp /home/ubuntu/dxnn-trader/${filename}"
        log_success "  Uploaded: $filename"
    done
    
    log_success "All files uploaded"
    
    # Compile .erl files on remote
    if [[ "$COMPILE" == "true" ]]; then
        erl_count=0
        for config_file in "${CONFIG_FILES[@]}"; do
            filename=$(basename "$config_file")
            if [[ "$filename" == *.erl ]]; then
                erl_count=$((erl_count + 1))
            fi
        done
        
        if [[ $erl_count -gt 0 ]]; then
            log_info "Compiling $erl_count .erl file(s) on instance..."
            for config_file in "${CONFIG_FILES[@]}"; do
                filename=$(basename "$config_file")
                if [[ "$filename" == *.erl ]]; then
                    log_info "  Compiling: $filename"
                    if ssh_exec "cd /home/ubuntu/dxnn-trader && erlc $filename" 2>&1; then
                        log_success "  Compiled: $filename"
                    else
                        log_error "Compilation failed: $filename"
                        log_info "Showing compilation errors:"
                        ssh_exec "cd /home/ubuntu/dxnn-trader && erlc $filename" 2>&1 || true
                        exit 1
                    fi
                fi
            done
            log_success "All .erl files compiled"
        fi
    fi
else
    log_info "No files uploaded - using GitHub code only"
fi

# Compile all DXNN code
if [[ "$COMPILE" == "true" ]]; then
    log_info "Compiling all DXNN code..."
    if compile_output=$(ssh_exec "cd /home/ubuntu/dxnn-trader && rm -f *.beam && erl -noshell -eval 'make:all([load]), init:stop().'" 2>&1); then
        echo "$compile_output" | tail -10
        log_success "DXNN compiled successfully"
    else
        echo "$compile_output" | tail -50
        log_error "DXNN compilation failed"
        exit 1
    fi
fi

# Start DXNN if requested
if [[ "$START_DXNN" == "true" ]]; then
    log_info "Starting DXNN training..."
    
    # Validate required scripts exist
    log_info "Validating required scripts on instance..."
    MISSING_SCRIPTS=()
    for script in dxnn-wrapper.sh dxnn_ctl finalize_run.sh dxnn-config.sh; do
        if ! ssh_exec "test -x /usr/local/bin/$script" 2>/dev/null; then
            MISSING_SCRIPTS+=("$script")
        fi
    done
    
    if [ ${#MISSING_SCRIPTS[@]} -gt 0 ]; then
        log_error "Missing required scripts: ${MISSING_SCRIPTS[*]}"
        log_error "Instance may not be fully initialized. Wait a few minutes and try again."
        log_info "Or check cloud-init status: ssh -i $SSH_KEY ${SSH_USER}@${HOST} 'sudo cloud-init status'"
        exit 1
    fi
    log_success "All required scripts present"
    
    # Check if already running
    if ssh_exec "tmux has-session -t trader 2>/dev/null"; then
        log_warning "DXNN session already exists"
        if [[ "$DRY_RUN" == "false" ]]; then
            read -p "Kill existing session and restart? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                ssh_exec "tmux kill-session -t trader"
                log_info "Killed existing session"
            else
                log_info "Keeping existing session"
                exit 0
            fi
        fi
    fi
    
    # Verify DXNN directory exists and has code
    log_info "Verifying DXNN installation..."
    if ! ssh_exec "test -d /home/ubuntu/dxnn-trader" 2>/dev/null; then
        log_error "DXNN directory not found: /home/ubuntu/dxnn-trader"
        log_error "Instance may not be fully initialized. Wait for cloud-init to complete."
        exit 1
    fi
    
    if ! ssh_exec "test -f /home/ubuntu/dxnn-trader/launcher.erl" 2>/dev/null; then
        log_error "launcher.erl not found - DXNN code not cloned"
        log_error "Check cloud-init logs: ssh -i $SSH_KEY ${SSH_USER}@${HOST} 'sudo tail -100 /var/log/cloud-init-output.log'"
        exit 1
    fi
    log_success "DXNN installation verified"
    
    # Start via wrapper script
    log_info "Launching DXNN wrapper script..."
    ssh_exec "nohup /usr/local/bin/dxnn-wrapper.sh > /dev/null 2>&1 &"
    
    # Wait for tmux session to start
    log_info "Waiting for DXNN to initialize..."
    RETRY=0
    MAX_RETRY=10
    while [ $RETRY -lt $MAX_RETRY ]; do
        sleep 2
        if ssh_exec "tmux has-session -t trader 2>/dev/null"; then
            log_success "DXNN tmux session created"
            break
        fi
        RETRY=$((RETRY + 1))
        log_info "Waiting... ($RETRY/$MAX_RETRY)"
    done
    
    if ssh_exec "tmux has-session -t trader 2>/dev/null"; then
        # Verify Erlang shell is running
        sleep 3
        if ssh_exec "tmux capture-pane -t trader -p 2>/dev/null | grep -q 'Eshell\\|Erlang'" 2>/dev/null; then
            log_success "DXNN started successfully - Erlang shell active"
            log_info "Attach with: ssh -i $SSH_KEY ${SSH_USER}@${HOST} -t 'tmux attach -t trader'"
            log_info "Detach with: Ctrl+b then d"
        else
            log_warning "DXNN session exists but Erlang shell not detected"
            log_info "Check status: ssh -i $SSH_KEY ${SSH_USER}@${HOST} -t 'tmux attach -t trader'"
        fi
    else
        log_error "DXNN failed to start - tmux session not created"
        echo ""
        log_info "Diagnostic steps:"
        log_info "1. Check wrapper logs:"
        log_info "   ssh -i $SSH_KEY ${SSH_USER}@${HOST} 'tail -50 /var/log/dxnn-run.log'"
        echo ""
        log_info "2. Check if DXNN code exists:"
        log_info "   ssh -i $SSH_KEY ${SSH_USER}@${HOST} 'ls -la /home/ubuntu/dxnn-trader/'"
        echo ""
        log_info "3. Check cloud-init status:"
        log_info "   ssh -i $SSH_KEY ${SSH_USER}@${HOST} 'sudo cloud-init status'"
        echo ""
        log_info "4. Check cloud-init logs:"
        log_info "   ssh -i $SSH_KEY ${SSH_USER}@${HOST} 'sudo tail -100 /var/log/cloud-init-output.log'"
        echo ""
        log_info "5. Try manual start:"
        log_info "   ssh -i $SSH_KEY ${SSH_USER}@${HOST}"
        log_info "   cd /home/ubuntu/dxnn-trader"
        log_info "   erl -noshell -eval 'launcher:start().'"
        echo ""
        exit 1
    fi
fi

# Configure auto-terminate (always write explicit true/false to avoid stale state)
log_info "Configuring auto-terminate setting (AUTO_TERMINATE=$AUTO_TERMINATE)..."

ssh_exec << EOF
AUTO_TERMINATE_VALUE="$AUTO_TERMINATE"

if [ -f /etc/dxnn-env ]; then
    sudo sed -i "s/^AUTO_TERMINATE=.*/AUTO_TERMINATE=\$AUTO_TERMINATE_VALUE/" /etc/dxnn-env
    sudo sed -i "s/^AUTO_TERMINATE_DEFAULT=.*/AUTO_TERMINATE_DEFAULT=\$AUTO_TERMINATE_VALUE/" /etc/dxnn-env

    if ! grep -q "^AUTO_TERMINATE=" /etc/dxnn-env; then
        echo "AUTO_TERMINATE=\$AUTO_TERMINATE_VALUE" | sudo tee -a /etc/dxnn-env > /dev/null
    fi
    if ! grep -q "^AUTO_TERMINATE_DEFAULT=" /etc/dxnn-env; then
        echo "AUTO_TERMINATE_DEFAULT=\$AUTO_TERMINATE_VALUE" | sudo tee -a /etc/dxnn-env > /dev/null
    fi
else
    sudo bash -c "cat > /etc/dxnn-env" << DXNN_ENV
AUTO_TERMINATE=\$AUTO_TERMINATE_VALUE
AUTO_TERMINATE_DEFAULT=\$AUTO_TERMINATE_VALUE
DXNN_ENV
fi

echo "Current /etc/dxnn-env contents:"
sudo grep -E "^AUTO_TERMINATE(_DEFAULT)?=" /etc/dxnn-env || true
EOF

if [ $? -eq 0 ]; then
    if [[ "$AUTO_TERMINATE" == "true" ]]; then
        log_success "Auto-terminate enabled - instance will terminate only after successful completion"
        log_warning "⚠️  Failures will keep the instance running for debugging"
    else
        log_info "Auto-terminate disabled - instance will remain running after completion"
    fi
else
    log_error "Failed to configure auto-terminate"
    exit 1
fi

# Summary
echo ""
log_success "Deployment complete!"
echo ""
if [[ ${#CONFIG_FILES[@]} -gt 0 ]]; then
    echo "  Files: ${#CONFIG_FILES[@]} uploaded and compiled"
    for config_file in "${CONFIG_FILES[@]}"; do
        echo "    - $(basename "$config_file")"
    done
else
    echo "  Files: None (using GitHub code only)"
fi
if [[ -n "$GIT_BRANCH" ]]; then
    echo "  Branch: $GIT_BRANCH"
    current_commit=$(ssh_exec "cd /home/ubuntu/dxnn-trader && git rev-parse --short HEAD" 2>/dev/null || echo "unknown")
    echo "  Commit: $current_commit"
fi
if [[ "$START_DXNN" == "true" ]]; then
    echo "  Status: Running"
fi
if [[ "$AUTO_TERMINATE" == "true" ]]; then
    echo "  Auto-terminate: ⚠️  ENABLED - instance will terminate on successful completion"
fi
echo ""
log_info "Connect: ssh -i $SSH_KEY ${SSH_USER}@${HOST}"
log_info "Attach: tmux attach -t trader"
log_info "Logs: tail -f /var/log/dxnn-run.log"
echo ""
