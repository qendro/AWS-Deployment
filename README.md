# DXNN Spot Instance Deployment

Deploy DXNN neural network training on AWS spot instances with automatic interruption handling. Clean, simple, cost-effective.

## 🚀 Quick Start

### AMI-Based Deployment (Recommended)

**1. Setup AWS Credentials (One-time)**
```bash
./setup-credentials.sh    # Mac/Linux/WSL
.\setup-credentials.ps1   # Windows (PowerShell)
```

**2. Create Custom AMI (One-time)**
```bash
./ami-manager.sh --create
# Takes ~10-15 minutes
# Note the AMI ID: ami-0123456789abc
```

**3. Update Config with AMI ID**
```bash
# Edit config/dxnn-spot-ami.yml
# Set: ami_id: "ami-YOUR-AMI-ID"
```

**4. Launch Instance**
```bash
./docker-deploy.sh -c config/dxnn-spot-ami.yml
# Note the public IP and key file
```

**5. Deploy Config & Start Training**
```bash
./deploy-config.sh \
    -i output/aws-deployment-key-TIMESTAMP-key.pem \
    -h PUBLIC_IP \
    -c /path/to/your/config.erl \
    -b main \
    --start
```

**6. Monitor Training**
```bash
ssh -i output/key.pem ubuntu@PUBLIC_IP
tmux attach -t trader    # Detach: Ctrl+b d
```

**7. Clean Up When Done**
```bash
./docker-deploy.sh -x    # Terminate instances
```

### Legacy Deployment (User-Data Heavy)

```bash
./docker-deploy.sh -c config/dxnn-spot-prod.yml
# Everything installed via user-data (slower, 5-10 min launch)
```

## 💰 Benefits

### Spot Instance Savings
- **90% Cost Savings** - Pay spot prices instead of on-demand
- **Automatic Interruption Handling** - Graceful checkpoint and restore
- **S3 Backup** - Training state preserved across interruptions
- **Seamless Recovery** - New instances automatically restore from S3

### AMI-Based Deployment
- **90% Faster Launches** - 30-60 seconds vs 5-10 minutes
- **No User-Data Limits** - Minimal bootstrap code (< 2KB)
- **Flexible Configs** - Different config.erl per instance via SCP
- **Version Control** - Different GitHub branches per instance
- **Remote Debugging** - Erlang shell access via SSH tunnel


## 📜 What You Get

- **Spot Instance** - c5.2xlarge (dev) or c5.4xlarge (prod) at spot prices
- **DXNN Training** - Automatically starts neural network training
- **Spot Monitoring** - Watches for interruptions every 2 seconds
- **S3 Backup** - Automatic checkpoint upload to S3
- **Auto Restore** - New instances resume from latest S3 checkpoint
- **SSH Access** - Private key automatically generated
- **Monitoring** - Production monitoring dashboard included

## 🛠️ Available Commands

### Deployment
```bash
./docker-deploy.sh -c config/dxnn-spot-ami.yml     # Deploy from custom AMI (fast)
./docker-deploy.sh -c config/dxnn-spot-prod.yml    # Deploy with user-data (legacy)
./docker-deploy.sh -s                              # Interactive shell for debugging
./docker-deploy.sh -x                              # Clean up all AWS resources
./docker-deploy.sh -h                              # Show help
```

### AMI Management
```bash
./ami-manager.sh --create                          # Create new AMI
./ami-manager.sh --create --name "custom-name"     # Create with custom name
./ami-manager.sh --list                            # List all DXNN AMIs
./ami-manager.sh --delete ami-0123456789abc        # Delete specific AMI
./ami-manager.sh --delete-all                      # Delete all DXNN AMIs
```

### Configuration Deployment
```bash
./deploy-config.sh -i key.pem -h IP -c config.erl  # Upload config
./deploy-config.sh -i key.pem -h IP -b v2.1.0      # Switch branch
./deploy-config.sh -i key.pem -h IP -c config.erl -b main --start  # Full deployment
```

## 📊 Monitoring Commands

scripts/monitor-production.sh                      # Run production monitoring dashboard
sudo tail -f /var/log/spot-watch.log              # Watch spot interruption logs
sudo systemctl status spot-watch                  # Check spot watcher status
tmux attach -t trader                             # View DXNN training session
/usr/local/bin/dxnn_ctl checkpoint                # Manual checkpoint
/usr/local/bin/dxnn_ctl restore                   # Manual restore

## 📁 Configuration Files

Available in config/:

- **dxnn-spot-ami.yml** - AMI-based deployment (recommended, fast launch)
- **dxnn-spot-prod.yml** - Production with user-data (legacy, c7i.4xlarge)
- **dxnn-spot.yml** - Development with user-data (legacy, c5.2xlarge)

## 🔧 Spot Instance Features

- **Interruption Monitoring** - 2-second polling via IMDSv2
- **Graceful Shutdown** - 60-second checkpoint deadline
- **S3 Integration** - No AWS CLI needed, uses AWS Signature v4
- **Deterministic Paths** - `s3://bucket/prefix/job-id/YYYY/MM/DD/HHMMSSZ/`
- **Metadata Tracking** - Full checkpoint metadata with job tracking
- **Single-Shot Protection** - Prevents duplicate interruption handling

## 🔧 Requirements

- **Docker Desktop** - For containerized deployment
- **AWS Account** - With programmatic access and spot instance permissions
- **S3 Bucket** - `dxnn-checkpoints` (created automatically)
- **IAM Role** - `DXNN-Spot-Profile` with S3 access (see IAM-Policy-Spot.md)
- **Mac/Linux Terminal** - For deployment commands

## 🐛 Troubleshooting

### Docker Issues
```bash
docker --version                      # Check Docker status
docker info                           # Check Docker info
```

### AWS Issues
```bash
aws sts get-caller-identity           # Check credentials
./setup-credentials.sh                # Recreate credentials
```

### Spot Instance Issues
```bash
ssh -i output/your-key.pem ubuntu@PUBLIC_IP        # Connect to instance
sudo systemctl status spot-watch                   # Check spot watcher
sudo tail -f /var/log/spot-watch.log              # View spot logs
sudo cloud-init status                            # Check setup status
```

### S3 Issues
```bash
/usr/local/bin/simple-s3-upload.sh file.txt test/file.txt    # Test S3 upload
aws s3 ls s3://dxnn-checkpoints/dxnn/ --recursive            # List checkpoints
```  


## 📁 Project Structure

```
AWS-Deployment/
├── config/
│   ├── dxnn-spot-ami.yml          # AMI-based deployment (recommended)
│   ├── dxnn-spot-prod.yml         # Production spot configuration (legacy)
│   └── dxnn-spot.yml              # Development spot configuration (legacy)
├── scripts/
│   ├── spot-watch.sh              # Spot interruption monitor
│   ├── spot-watch.service         # Systemd service definition
│   ├── dxnn_ctl                   # DXNN control interface
│   ├── dxnn-wrapper.sh            # DXNN wrapper with distributed Erlang
│   ├── dxnn-config.sh             # Configuration helper
│   ├── restore-from-s3.sh         # S3 checkpoint restore
│   ├── finalize_run.sh            # Finalization script
│   └── monitor-production.sh      # Production monitoring dashboard
├── ami-manager.sh                 # AMI creation and management
├── deploy-config.sh               # Config deployment via SCP
├── deploy.sh                      # Core deployment logic
├── docker-deploy.sh               # Main deployment wrapper
├── Dockerfile                     # Container definition
├── setup-credentials.sh           # AWS credentials setup
├── setup-credentials.ps1          # Windows credentials setup
├── AMI-STRATEGY.md                # AMI-based deployment strategy
├── IAM-Policy-Spot.md             # Required IAM permissions
└── spot-policy.json               # IAM policy JSON
```  

## 🧹 Cleanup

To remove all AWS resources created by this tool:

```bash
./docker-deploy.sh -x          # Terminate all instances and cleanup
```

⚠️ Warning: This will terminate ALL instances created by AWS-Deployment!

## 🔄 Spot Instance Recovery

**When your spot instance terminates, recovery is automatic:**

```bash
# Just launch a new instance with the same config
./docker-deploy.sh -c config/dxnn-spot-prod.yml
```


**What happens automatically:**
- New instance launches and finds latest checkpoint in S3
- DXNN resumes training from last saved state
- No manual intervention needed

---
**Deployment Note:**

The deployment process now uses a trigger file (`/home/ubuntu/SCRIPTS_READY`) to ensure all required scripts are uploaded before the DXNN application autostarts. The instance waits for this file before launching the training process. This guarantees that all scripts are present and executable, preventing race conditions during setup.

If you modify or add scripts, make sure the deployment process completes the upload and creates the `SCRIPTS_READY` file before expecting the application to start automatically.

---

**Manual verification (optional):**
```bash
./docker-deploy.sh -c config/dxnn-spot-prod.yml
ssh -i output/your-key.pem ubuntu@NEW_IP
ls -la /var/lib/dxnn/checkpoints/          # Check restored files
sudo tail -f /var/log/spot-restore.log     # View restore logs
sudo tail -f /var/log/cloud-init-output.log
tmux attach -t trader                      # Monitor resumed training
tmux kill-session -t trader


Detach from tmux: Ctrl+b then d

cat /var/log/dxnn-setup.log

```

## 🎯 Example Workflows

### Single Instance with Custom Config

```bash
# 1. Create AMI (one-time)
./ami-manager.sh --create

# 2. Launch instance
./docker-deploy.sh -c config/dxnn-spot-ami.yml

# 3. Deploy config and start
./deploy-config.sh -i output/key.pem -h IP -c ~/my-config.erl -b main --start

# 4. Monitor
ssh -i output/key.pem ubuntu@IP
tmux attach -t trader
```

### Multiple Instances with Different Configs

```bash
# Launch 3 instances with different strategies
./docker-deploy.sh -c config/dxnn-spot-ami.yml  # Instance 1
./docker-deploy.sh -c config/dxnn-spot-ami.yml  # Instance 2
./docker-deploy.sh -c config/dxnn-spot-ami.yml  # Instance 3

# Deploy different configs
./deploy-config.sh -i key1.pem -h IP1 -c config-sharpe.erl -b main --start
./deploy-config.sh -i key2.pem -h IP2 -c config-sortino.erl -b main --start
./deploy-config.sh -i key3.pem -h IP3 -c config-calmar.erl -b feature/test --start
```

### Remote Erlang Shell Access

```bash
# Terminal 1: SSH tunnel
ssh -i output/key.pem -L 4369:localhost:4369 -L 9000-9100:localhost:9000-9100 ubuntu@IP

# Terminal 2: Get cookie and connect
ssh -i output/key.pem ubuntu@IP "cat /var/lib/dxnn/.erlang.cookie" > ~/.erlang.cookie
chmod 600 ~/.erlang.cookie

HOSTNAME=$(ssh -i output/key.pem ubuntu@IP "hostname -f")
erl -name debug@127.0.0.1 -setcookie $(cat ~/.erlang.cookie) -remsh dxnn@$HOSTNAME

# Now run Erlang commands:
# observer:start().
# ets:tab2list(dxnn_config).
```

### Update Running Instance

```bash
# Update config without restart
./deploy-config.sh -i output/key.pem -h IP -c new-config.erl

# Switch to new branch and restart
./deploy-config.sh -i output/key.pem -h IP -b v2.2.0 --start
```

## 📚 Documentation

- **AMI-STRATEGY.md** - Complete AMI-based deployment architecture and strategy
- **IAM-Policy-Spot.md** - Required IAM permissions for spot instances
- **Updates.md** - Recent changes and updates

## 🔑 Key Features

- **AMI-Based Deployment** - Pre-baked images for instant launches
- **Spot Instance Support** - 90% cost savings with automatic interruption handling
- **S3 Checkpointing** - Automatic backup and restore
- **Distributed Erlang** - Remote shell access for debugging
- **Flexible Configuration** - Per-instance config.erl via SCP
- **Version Control** - Different GitHub branches per instance
- **Monitoring** - Built-in logging and health checks

---

**DXNN Neural Networks. Spot Instances. AMI-Based. 90% Cost Savings. 90% Faster Launches.** 🚀
