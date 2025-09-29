# DXNN Spot Instance Deployment

Deploy DXNN neural network training on AWS spot instances with automatic interruption handling. Clean, simple, cost-effective.

## 🚀 Quick Start

### 1. Setup AWS Credentials (One-time)

.\setup-credentials.ps1   # Windows (PowerShell)
./setup-credentials.sh    # Mac/Linux/WSL

### 2. Deploy DXNN Spot Instance

./docker-deploy.sh -c config/dxnn-spot-prod.yml    # Production spot instance

### 3. Monitor Your Training

ssh -i output/your-key.pem ubuntu@PUBLIC_IP        # Connect to instance
sudo tail -f /var/log/spot-watch.log               # Monitor spot interruptions
tmux attach -t trader                              # View DXNN training

### 4. Clean Up When Done

./docker-deploy.sh -x                              # Terminate instances

That's it! 🎉

## 💰 Spot Instance Benefits

- **90% Cost Savings** - Pay spot prices instead of on-demand
- **Automatic Interruption Handling** - Graceful checkpoint and restore
- **S3 Backup** - Training state preserved across interruptions
- **Seamless Recovery** - New instances automatically restore from S3


## 📜 What You Get

- **Spot Instance** - c5.2xlarge (dev) or c5.4xlarge (prod) at spot prices
- **DXNN Training** - Automatically starts neural network training
- **Spot Monitoring** - Watches for interruptions every 2 seconds
- **S3 Backup** - Automatic checkpoint upload to S3
- **Auto Restore** - New instances resume from latest S3 checkpoint
- **SSH Access** - Private key automatically generated
- **Monitoring** - Production monitoring dashboard included

## 🛠️ Available Commands

./docker-deploy.sh -c config/dxnn-spot.yml         # Deploy development spot instance
./docker-deploy.sh -c config/dxnn-spot-prod.yml    # Deploy production spot instance
./docker-deploy.sh -s                              # Interactive shell for debugging
./docker-deploy.sh -x                              # Clean up all AWS resources
./docker-deploy.sh -h                              # Show help

## 📊 Monitoring Commands

scripts/monitor-production.sh                      # Run production monitoring dashboard
sudo tail -f /var/log/spot-watch.log              # Watch spot interruption logs
sudo systemctl status spot-watch                  # Check spot watcher status
tmux attach -t trader                             # View DXNN training session
/usr/local/bin/dxnn_ctl checkpoint                # Manual checkpoint
/usr/local/bin/dxnn_ctl restore                   # Manual restore

## 📁 Configuration Files

Available in config/:

- **dxnn-spot.yml** - Development spot instance (c5.2xlarge, $0.30 max)
- **dxnn-spot-prod.yml** - Production spot instance (c5.4xlarge, $0.50 max)

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
│   ├── dxnn-spot.yml              # Development spot configuration
│   └── dxnn-spot-prod.yml         # Production spot configuration
├── scripts/
│   ├── spot-watch.sh              # Spot interruption monitor
│   ├── spot-watch.service         # Systemd service definition
│   ├── dxnn_ctl                   # DXNN control interface
│   ├── restore-from-s3.sh         # S3 checkpoint restore
│   ├── simple-s3-upload.sh        # S3 upload (no AWS CLI)
│   ├── simple-s3-download.sh      # S3 download (no AWS CLI)
│   └── monitor-production.sh      # Production monitoring dashboard
├── deploy.sh                      # Core deployment logic
├── docker-deploy.sh               # Main deployment wrapper
├── Dockerfile                     # Container definition
├── setup-credentials.sh           # AWS credentials setup
├── setup-credentials.ps1          # Windows credentials setup
├── IAM-Policy-Spot.md             # Required IAM permissions
├── spot-policy.json               # IAM policy JSON
└── SPOT_INSTANCE_IMPLEMENTATION.md # Complete implementation guide
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
ssh -i output/your-key.pem ubuntu@NEW_IP
ls -la /var/lib/dxnn/checkpoints/          # Check restored files
sudo tail -f /var/log/spot-restore.log     # View restore logs
sudo tail -f /var/log/cloud-init-output.log
tmux attach -t trader                      # Monitor resumed training

Detach from tmux: Ctrl+b then d
```

## 🎯 Example Workflow

```bash
# 1. Setup credentials (one-time)
./setup-credentials.sh

# 2. Deploy production spot instance
./docker-deploy.sh -c config/dxnn-spot-prod.yml

# 3. Monitor training
ssh -i output/your-key.pem ubuntu@PUBLIC_IP
tmux attach -t trader

# 4. If spot terminates, just redeploy
./docker-deploy.sh -c config/dxnn-spot-prod.yml    # Automatically resumes!

# 5. Cleanup when done
./docker-deploy.sh -x
```

---

**DXNN Neural Networks. Spot Instances. Automatic Recovery. 90% Cost Savings.** 🚀
