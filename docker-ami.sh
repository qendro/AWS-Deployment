#!/bin/bash

# Docker wrapper for AMI Manager

# Color functions
info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

echo -e "\033[1;34mDXNN AMI Manager (Docker)\033[0m"
echo "=========================="

# Check Docker availability
info "Checking Docker availability..."
if ! docker --version &>/dev/null; then
    error "Docker not found or not running!"
    warn "Please install Docker Desktop: https://www.docker.com/products/docker-desktop"
    exit 1
fi

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

# Run ami-manager.sh in container
info "Running AMI Manager in container..."
docker run --rm -it \
    -v "$(pwd):/aws-deployment" \
    --env-file .env \
    --entrypoint /aws-deployment/ami-manager.sh \
    aws-deployment:latest "$@"

exit_code=$?

if [ $exit_code -eq 0 ]; then
    success "Operation completed successfully!"
else
    error "Operation failed with exit code: $exit_code"
fi

exit $exit_code
