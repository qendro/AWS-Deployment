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
    python3 \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2 and yq
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf awscliv2.zip aws/ \
    && curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# OCI tooling is installed only in this shared deployment container.
COPY requirements-oci.txt /tmp/requirements-oci.txt
RUN python3 -m venv /opt/oci \
    && /opt/oci/bin/pip install --no-cache-dir -r /tmp/requirements-oci.txt
ENV PATH="/opt/oci/bin:${PATH}"
LABEL org.dxnn.oci-sdk="2.187.2"

# Create working directory
WORKDIR /aws-deployment

# Copy deployment files
COPY deploy.sh ./
COPY ami-manager.sh ./
COPY deploy-config.sh ./
COPY scripts/ ./scripts/
COPY config/ ./config/
RUN chmod +x deploy.sh ami-manager.sh deploy-config.sh && find scripts/ -name "*.sh" -exec chmod +x {} \;

# Set default entrypoint
ENTRYPOINT ["./deploy.sh"]

# Default command shows help
CMD ["--help"]
