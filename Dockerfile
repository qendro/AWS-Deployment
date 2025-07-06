# AWS-Deployment Docker Image (ARM64-Targeted)
# Containerized environment for AWS deployment
# Optimized for Apple Silicon (M1/M2/M3) or ARM64 systems

FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV AWS_CLI_VERSION=2.27.49

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    git \
    ssh \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install ARM64-compatible AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf awscliv2.zip aws/

# Install yq for YAML parsing (ARM64 build)
RUN curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Create working directory
WORKDIR /aws-deployment

# Copy deployment scripts and configs
COPY deploy.sh .
COPY scripts/ ./scripts/
COPY config/ ./config/

# Make scripts executable
RUN chmod +x deploy.sh && \
    find scripts/ -name "*.sh" -exec chmod +x {} \;

# Create directories for SSH keys and outputs
RUN mkdir -p /root/.ssh /aws-deployment/output

# Set default entrypoint
ENTRYPOINT ["./deploy.sh"]

# Default command shows help
CMD ["--help"]
