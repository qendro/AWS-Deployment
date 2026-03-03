# AMI-Based Deployment Strategy

## Overview

This document outlines the transition from user-data-heavy deployments to a streamlined AMI-based approach. The goal is to eliminate user-data size limits, speed up instance launches, and provide better control over instance configuration.

## Problem Statement

Current deployment approach hits AWS user-data limits (16KB) because it includes:
- System package installation (erlang, git, tmux, chrony, etc.)
- AWS CLI installation
- GitHub repository cloning
- Script uploads via SCP
- Complex boot orchestration with trigger files
- Service configuration

This results in:
- Slow instance launches (5-10 minutes)
- Fragile deployments (network issues during setup)
- User-data size constraints
- Difficulty managing multiple instances with different configurations

## Solution: Custom AMI + SCP Configuration

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Custom AMI (Baked)                      │
├─────────────────────────────────────────────────────────────┤
│ • Ubuntu 24.04 Base                                         │
│ • All System Packages (erlang, git, tmux, etc.)            │
│ • AWS CLI v2                                                │
│ • All Scripts (/usr/local/bin/)                            │
│ • Systemd Services (spot-watch.service)                    │
│ • Base DXNN-Trader (/opt/dxnn-trader-base)                 │
│ • System Optimizations (sysctl, logrotate)                 │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│              Instance Launch (Minimal User-Data)            │
├─────────────────────────────────────────────────────────────┤
│ • Copy base DXNN-Trader to /home/ubuntu/                   │
│ • Enable spot-watch service                                 │
│ • Wait for configuration via SCP                            │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│              SCP Configuration Deployment                    │
├─────────────────────────────────────────────────────────────┤
│ • Upload custom config.erl                                  │
│ • Specify GitHub branch/tag to checkout                     │
│ • Trigger training start                                    │
└─────────────────────────────────────────────────────────────┘
```

## AMI Contents (Pre-Baked)

### System Packages
- erlang (latest stable)
- git, vim, htop, tree
- tmux (for session management)
- chrony (time synchronization)
- jq, yq (JSON/YAML processing)
- openssl, unzip
- build-essential

### AWS Tools
- AWS CLI v2 (pre-installed, no download needed)
- IMDSv2 configured

### Directory Structure
```
/var/lib/dxnn/
├── checkpoints/          # Checkpoint storage
└── .erlang.cookie        # Template (regenerated per instance)

/usr/local/bin/
├── spot-watch.sh         # Spot interruption monitor
├── dxnn_ctl              # DXNN control interface
├── restore-from-s3.sh    # S3 restore script
├── finalize_run.sh       # Finalization script
├── dxnn-wrapper.sh       # DXNN wrapper
├── dxnn-config.sh        # Config helper
└── health-check.sh       # Health check script

/opt/dxnn-trader-base/    # Base DXNN-Trader (read-only reference)
└── [DXNN-Trader files]

/etc/systemd/system/
└── spot-watch.service    # Spot watcher service (disabled by default)

/var/log/
├── spot-watch.log
├── dxnn-run.log
├── dxnn-setup.log
└── dxnn-restore.log
```

### System Optimizations
```bash
# /etc/sysctl.conf
vm.swappiness=10
net.core.rmem_max=134217728
net.core.wmem_max=134217728

# /etc/logrotate.d/spot-watch
/var/log/spot-watch.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
}
```

## Deployment Workflow

### 1. Create Custom AMI (One-Time)

```bash
# Create a new AMI from base Ubuntu
./ami-manager.sh --create

# This will:
# - Launch base Ubuntu instance
# - Install all packages and scripts
# - Clone base DXNN-Trader
# - Configure system optimizations
# - Create AMI snapshot
# - Tag with version and timestamp
# - Terminate build instance
```

**AMI Naming Convention**: `dxnn-trader-v{VERSION}-{TIMESTAMP}`
- Example: `dxnn-trader-v1.0-20260302-143022`

### 2. Launch Instance from AMI

```bash
# Update config file with your custom AMI ID
# config/dxnn-spot-prod.yml:
#   aws:
#     ami_id: "ami-YOUR-CUSTOM-AMI"

# Launch instance
./docker-deploy.sh -c config/dxnn-spot-prod.yml
```

**Minimal User-Data** (< 2KB):
```bash
#!/bin/bash
# Copy base DXNN-Trader to user directory
cp -r /opt/dxnn-trader-base /home/ubuntu/dxnn-trader
chown -R ubuntu:ubuntu /home/ubuntu/dxnn-trader

# Generate unique Erlang cookie
echo "dxnn_prod_$(openssl rand -hex 16)" > /var/lib/dxnn/.erlang.cookie
chown ubuntu:ubuntu /var/lib/dxnn/.erlang.cookie
chmod 600 /var/lib/dxnn/.erlang.cookie

# Enable spot watcher
systemctl enable spot-watch
systemctl start spot-watch

# Wait for config.erl via SCP
touch /home/ubuntu/READY_FOR_CONFIG
```

### 3. Deploy Configuration

```bash
# After instance launches, deploy your custom config
./deploy-config.sh -i output/key.pem -h PUBLIC_IP \
    -c /path/to/custom/config.erl \
    -b feature/new-strategy

# This will:
# - SCP config.erl to instance
# - Checkout specified GitHub branch
# - Start DXNN training
```

## Configuration Management

### Option A: Full config.erl Replacement (Recommended)

Upload a complete `config.erl` file with all your settings:

```bash
scp -i output/key.pem \
    /Users/qendrim/Documents/DXNN_Main/DXNN-Trader-v2/config.erl \
    ubuntu@PUBLIC_IP:/home/ubuntu/dxnn-trader/config.erl
```

### Option B: Runtime ETS Overrides

Use the built-in ETS override system for quick changes:

```erlang
% On the instance, in Erlang shell:
config:set(population_id, experiment_001).
config:set(fitness_function, curriculum_risk_penalty).
config:set(evaluations_limit, 50000).
```

### Option C: Environment Variables

Set configuration via environment variables in user-data:

```bash
export DXNN_POPULATION_ID="experiment_001"
export DXNN_FITNESS_FUNCTION="curriculum_risk_penalty"
```

## GitHub Version Control

### Specify Branch/Tag at Launch

```bash
# In your deployment script or SSH session:
cd /home/ubuntu/dxnn-trader
git fetch origin
git checkout feature/new-strategy  # or v2.1.0 tag
git pull
```

### Multiple Instances, Different Versions

```bash
# Instance 1: Production stable
git checkout v2.0.0

# Instance 2: Testing new features
git checkout feature/experimental-fitness

# Instance 3: Development
git checkout develop
```

## AMI Management

### Create New AMI

```bash
# Create AMI with default settings
./ami-manager.sh --create

# Create AMI with custom name
./ami-manager.sh --create --name "dxnn-trader-custom"

# Create AMI with specific DXNN-Trader version
./ami-manager.sh --create --dxnn-version "v2.1.0"
```

### List AMIs

```bash
# List all DXNN AMIs
./ami-manager.sh --list

# Output:
# AMI ID              Name                           Created              State
# ami-0123456789abc   dxnn-trader-v1.0-20260302     2026-03-02 14:30:22  available
# ami-0987654321def   dxnn-trader-v1.1-20260305     2026-03-05 09:15:10  available
```

### Delete AMIs

```bash
# Delete specific AMI
./ami-manager.sh --delete ami-0123456789abc

# Delete all DXNN AMIs (with confirmation)
./ami-manager.sh --delete-all

# Force delete without confirmation (dangerous!)
./ami-manager.sh --delete-all --force
```

### Update AMI

```bash
# When you need to update the base AMI:
# 1. Create new AMI
./ami-manager.sh --create --name "dxnn-trader-v1.1"

# 2. Update config files to use new AMI
# Edit config/dxnn-spot-prod.yml:
#   ami_id: "ami-NEW-AMI-ID"

# 3. Delete old AMI (optional)
./ami-manager.sh --delete ami-OLD-AMI-ID
```

## Benefits

### Performance
- **Launch time**: 5-10 minutes → 30-60 seconds
- **User-data size**: 15KB → 2KB
- **Network dependency**: High → Minimal

### Reliability
- **Package installation failures**: Eliminated
- **GitHub clone failures**: Moved to post-launch (retryable)
- **Script upload race conditions**: Eliminated

### Flexibility
- **Multiple instances**: Each can run different GitHub branches
- **Custom configs**: Per-instance config.erl via SCP
- **Version control**: AMI versions track infrastructure changes

### Cost
- **AMI storage**: ~$0.05/GB-month (~$0.50/month for 10GB AMI)
- **Faster launches**: Less wasted spot instance time
- **Reduced failures**: Fewer failed launches = less waste

## Migration Path

### Phase 1: Create First AMI ✓
- Run `ami-manager.sh --create`
- Verify AMI contains all required components
- Test launch from AMI

### Phase 2: Update Deployment Scripts
- Modify `deploy.sh` to use minimal user-data
- Update config YAML files with AMI ID
- Test instance launch

### Phase 3: Add SCP Configuration
- Create `deploy-config.sh` script
- Test config.erl upload
- Verify DXNN starts with custom config

### Phase 4: Add GitHub Branch Selection
- Add branch/tag selection to deployment
- Test multiple instances with different versions
- Document workflow

### Phase 5: Production Rollout
- Update all config files to use AMI
- Remove heavy user-data logic
- Monitor and optimize

## Configuration File Changes

### Before (User-Data Heavy)
```yaml
application:
  setup_commands:
    - "apt-get update -y"
    - "apt-get install -y erlang git vim htop tree build-essential tmux chrony jq openssl unzip"
    - "systemctl enable chrony && systemctl start chrony"
    - "curl -L https://github.com/mikefarah/yq/releases/download/v4.35.1/yq_linux_amd64 -o /usr/local/bin/yq"
    - "mkdir -p /var/lib/dxnn/checkpoints"
    - "git clone https://github.com/qendro/DXNN-Trader-v2.git dxnn-trader"
    # ... 30+ more lines
```

### After (AMI-Based)
```yaml
application:
  setup_commands:
    - "cp -r /opt/dxnn-trader-base /home/ubuntu/dxnn-trader"
    - "chown -R ubuntu:ubuntu /home/ubuntu/dxnn-trader"
    - "echo 'dxnn_prod_$(openssl rand -hex 16)' > /var/lib/dxnn/.erlang.cookie"
    - "chmod 600 /var/lib/dxnn/.erlang.cookie"
    - "systemctl enable spot-watch && systemctl start spot-watch"
    - "touch /home/ubuntu/READY_FOR_CONFIG"
```

## Troubleshooting

### AMI Creation Fails
```bash
# Check build instance logs
./ami-manager.sh --create --debug

# SSH into build instance
ssh -i output/ami-build-key.pem ubuntu@BUILD_IP
sudo tail -f /var/log/cloud-init-output.log
```

### Instance Won't Start from AMI
```bash
# Check user-data execution
ssh -i output/key.pem ubuntu@IP
sudo cat /var/log/cloud-init-output.log
sudo systemctl status spot-watch
```

### Config Upload Fails
```bash
# Verify SSH access
ssh -i output/key.pem ubuntu@IP echo "SSH OK"

# Check file permissions
ssh -i output/key.pem ubuntu@IP ls -la /home/ubuntu/dxnn-trader/
```

### DXNN Won't Start
```bash
# Check logs
ssh -i output/key.pem ubuntu@IP
sudo tail -f /var/log/dxnn-run.log
sudo tail -f /var/log/dxnn-setup.log

# Verify config.erl
cat /home/ubuntu/dxnn-trader/config.erl

# Check tmux session
tmux attach -t trader
```

## Security Considerations

### AMI Security
- AMIs are private by default (not publicly shared)
- No hardcoded credentials in AMI
- Erlang cookie regenerated per instance
- IAM instance profile for S3 access (no keys in AMI)

### Configuration Security
- config.erl may contain sensitive parameters
- Use SCP over SSH (encrypted)
- Consider AWS Secrets Manager for sensitive configs
- Restrict SSH key access

### GitHub Access
- For private repos, use SSH keys or deploy tokens
- Store credentials in AWS Secrets Manager
- Rotate credentials regularly

## Cost Analysis

### Current Approach (User-Data Heavy)
- Instance launch: 5-10 minutes
- Spot instance cost during setup: $0.05-0.10
- Failed launches: ~10% (network issues)
- Wasted cost per month: ~$5-10

### AMI Approach
- AMI storage: $0.50/month
- Instance launch: 30-60 seconds
- Spot instance cost during setup: $0.01
- Failed launches: <1%
- Net savings: ~$4-9/month per active deployment

**ROI**: Positive after first month, especially with multiple instances

## Future Enhancements

### Automated AMI Updates
- Scheduled AMI rebuilds (weekly/monthly)
- Automated testing of new AMIs
- Blue/green AMI deployment

### Configuration Templates
- Pre-built config.erl templates for common scenarios
- Configuration validation before upload
- Version control for configs

### Multi-Region Support
- Copy AMIs to multiple regions
- Region-specific deployment configs
- Automated failover

### Monitoring Integration
- AMI usage tracking
- Instance launch metrics
- Configuration drift detection

## References

- [AWS AMI Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIs.html)
- [AWS User Data Limits](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [Spot Instance Best Practices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html)

---

**Last Updated**: 2026-03-02  
**Version**: 1.0  
**Author**: DXNN Team
