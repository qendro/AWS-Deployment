#!/bin/bash

# Simple AWS Deployment via Docker (Mac/Linux/WSL)

CONFIG="config/dxnn-spot.yml"
SHELL_MODE=false
CLEANUP=false

# Color functions
info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

# Show help
show_help() {
    echo -e "\033[1;34mDXNN Spot Instance Deployment\033[0m"
    echo "============================="
    echo ""
    echo "USAGE:"
    echo "    ./docker-deploy.sh [-c config.yml] [-s] [-x] [-h]"
    echo ""
    echo "OPTIONS:"
    echo "    -c FILE     Configuration file (default: config/dxnn-spot.yml)"
    echo "    -s          Open interactive shell"
    echo "    -x          Clean up all AWS resources"
    echo "    -h          Show this help"
    echo ""
    echo "EXAMPLES:"
    echo "    ./docker-deploy.sh -c config/dxnn-spot-prod.yml  # Production"
    echo "    ./docker-deploy.sh -c config/dxnn-spot.yml       # Development"
    echo "    ./docker-deploy.sh -x                            # Clean up"
    exit 0
}

# Parse arguments
while getopts "c:sxh" opt; do
  case ${opt} in
    c) CONFIG="$OPTARG" ;;
    s) SHELL_MODE=true ;;
    x) CLEANUP=true ;;
    h) show_help ;;
    *) show_help ;;
  esac
done

echo -e "\033[1;34mSimple AWS Deployment\033[0m"
echo "===================="

# Check Docker availability
info "Checking Docker availability..."
if ! docker --version &>/dev/null; then
    error "Docker not found or not running!"
    warn "Please install Docker Desktop: https://www.docker.com/products/docker-desktop"
    exit 1
fi
success "Docker found: $(docker --version)"

if ! docker info &>/dev/null; then
    error "Docker daemon not running! Please start Docker Desktop."
    exit 1
fi
success "Docker daemon is running"

# Build image if needed
if ! docker image inspect aws-deployment:latest &>/dev/null; then
    info "Building AWS-Deployment Docker image..."
    if ! docker buildx build --platform linux/arm64 -t aws-deployment:latest .; then
        error "Failed to build Docker image"
        exit 1
    fi
    success "Docker image built successfully"
fi

# Ensure .env file exists
if [ ! -f ".env" ]; then
    warn "No .env file found. Run ./setup-credentials.sh first."
    exit 1
fi

# Prepare docker run arguments
docker_run_args=(
    run --rm -it
    -v "$(pwd):/aws-deployment"
    --env-file .env
)

# Shell mode
if $SHELL_MODE; then
    info "Opening interactive shell in AWS-Deployment container..."
    docker "${docker_run_args[@]}" aws-deployment:latest /bin/bash
    exit $?
fi

# Cleanup mode
if $CLEANUP; then
    info "Cleaning up AWS resources..."
    docker "${docker_run_args[@]}" aws-deployment:latest --cleanup
    exit $?
fi

# Default deploy
info "Running AWS deployment..."
docker "${docker_run_args[@]}" aws-deployment:latest -c "$CONFIG"
exit_code=$?

if [ $exit_code -eq 0 ]; then
    success "Operation completed successfully!"
else
    error "Operation failed with exit code: $exit_code"
fi

exit $exit_code
