# DXNN Spot Instance Deployment Container

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

# Install AWS CLI v2 and yq
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf awscliv2.zip aws/ \
    && curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Create working directory
WORKDIR /aws-deployment

# Copy deployment files
COPY deploy.sh scripts/ config/ ./
RUN chmod +x deploy.sh && find scripts/ -name "*.sh" -exec chmod +x {} \;

# Set default entrypoint
ENTRYPOINT ["./deploy.sh"]

# Default command shows help
CMD ["--help"]
