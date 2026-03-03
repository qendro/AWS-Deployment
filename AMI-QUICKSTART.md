# AMI-Based Deployment Quick Start

## Prerequisites

- AWS CLI configured with credentials
- Docker Desktop running (for deployment container)
- SSH access to AWS instances

## Step 1: Create Custom AMI (One-Time)

```bash
# Create AMI with default settings
./ami-manager.sh --create

# Or with custom name and DXNN version
./ami-manager.sh --create \
    --name "dxnn-trader-v2.1" \
    --dxnn-version "v2.1.0"

# This takes ~10-15 minutes
# Output will show: AMI ID: ami-0123456789abc
```

## Step 2: Update Config with AMI ID

Edit `config/dxnn-spot-ami.yml`:

```yaml
aws:
  ami_id: "ami-0123456789abc"  # Replace with your AMI ID
```

## Step 3: Launch Instance

```bash
# Launch from custom AMI
./docker-deploy.sh -c config/dxnn-spot-ami.yml

# Note the public IP from output
# SSH Command: ssh -i ./output/aws-deployment-key-TIMESTAMP-key.pem ubuntu@PUBLIC_IP
```

## Step 4: Deploy Configuration

```bash
# Upload your custom config.erl and start training
./deploy-config.sh \
    -i output/aws-deployment-key-TIMESTAMP-key.pem \
    -h PUBLIC_IP \
    -c /Users/qendrim/Documents/DXNN_Main/DXNN-Trader-v2/config.erl \
    -b main \
    --start

# Or just switch to a different branch
./deploy-config.sh \
    -i output/key.pem \
    -h PUBLIC_IP \
    -b feature/new-strategy \
    --start
```

## Step 5: Monitor Training

```bash
# SSH into instance
ssh -i output/key.pem ubuntu@PUBLIC_IP

# Attach to tmux session
tmux attach -t trader

# Detach: Ctrl+b then d

# View logs
tail -f /var/log/dxnn-run.log
```

## Step 6: Remote Erlang Shell (Optional)

```bash
# Terminal 1: Create SSH tunnel
ssh -i output/key.pem \
    -L 4369:localhost:4369 \
    -L 9000-9100:localhost:9000-9100 \
    ubuntu@PUBLIC_IP

# Terminal 2: Connect via Erlang
# First, get the cookie from the instance
ssh -i output/key.pem ubuntu@PUBLIC_IP "cat /var/lib/dxnn/.erlang.cookie"

# Save it locally
echo "COOKIE_VALUE" > ~/.erlang.cookie
chmod 600 ~/.erlang.cookie

# Get instance hostname
HOSTNAME=$(ssh -i output/key.pem ubuntu@PUBLIC_IP "hostname -f")

# Connect
erl -name debug@127.0.0.1 \
    -setcookie $(cat ~/.erlang.cookie) \
    -remsh dxnn@$HOSTNAME

# Now you can run Erlang commands:
# observer:start().
# ets:tab2list(dxnn_config).
```

## Common Workflows

### Launch Multiple Instances with Different Configs

```bash
# Instance 1: Production config
./docker-deploy.sh -c config/dxnn-spot-ami.yml
./deploy-config.sh -i output/key1.pem -h IP1 -c config-prod.erl -b main --start

# Instance 2: Experimental config
./docker-deploy.sh -c config/dxnn-spot-ami.yml
./deploy-config.sh -i output/key2.pem -h IP2 -c config-experimental.erl -b feature/test --start

# Instance 3: Different fitness function
./docker-deploy.sh -c config/dxnn-spot-ami.yml
./deploy-config.sh -i output/key3.pem -h IP3 -c config-sharpe.erl -b main --start
```

### Update Running Instance

```bash
# Update config without restarting
./deploy-config.sh -i output/key.pem -h IP -c new-config.erl

# Switch branch and restart
./deploy-config.sh -i output/key.pem -h IP -b v2.2.0 --start
```

### Check Instance Status

```bash
# SSH and check
ssh -i output/key.pem ubuntu@IP

# Check if DXNN is running
tmux has-session -t trader && echo "Running" || echo "Not running"

# Check spot watcher
sudo systemctl status spot-watch

# View recent logs
tail -20 /var/log/dxnn-run.log
```

## AMI Management

### List Your AMIs

```bash
./ami-manager.sh --list
```

### Delete Old AMI

```bash
./ami-manager.sh --delete ami-0123456789abc
```

### Delete All AMIs

```bash
./ami-manager.sh --delete-all
```

### Update AMI (New Version)

```bash
# Create new AMI with updated DXNN version
./ami-manager.sh --create --name "dxnn-trader-v2.2" --dxnn-version "v2.2.0"

# Update config files with new AMI ID
# Edit config/dxnn-spot-ami.yml

# Delete old AMI
./ami-manager.sh --delete ami-OLD-AMI-ID
```

## Troubleshooting

### Instance Won't Start

```bash
# Check user-data logs
ssh -i output/key.pem ubuntu@IP
sudo cat /var/log/cloud-init-output.log
```

### Config Upload Fails

```bash
# Test SSH connectivity
ssh -i output/key.pem ubuntu@IP echo "SSH OK"

# Check if READY_FOR_CONFIG exists
ssh -i output/key.pem ubuntu@IP "test -f /home/ubuntu/READY_FOR_CONFIG && echo 'Ready' || echo 'Not ready'"
```

### DXNN Won't Start

```bash
# Check logs
ssh -i output/key.pem ubuntu@IP
tail -f /var/log/dxnn-run.log
tail -f /var/log/dxnn-setup.log

# Try manual start
cd /home/ubuntu/dxnn-trader
/usr/local/bin/dxnn-wrapper.sh
```

### Remote Shell Won't Connect

```bash
# Verify Erlang node is running with distribution
ssh -i output/key.pem ubuntu@IP
tmux attach -t trader
# Look for: "Starting with distributed Erlang: dxnn@hostname"

# Check if ports are open in security group
# Need: 22, 4369, 9000-9100

# Verify cookie matches
ssh -i output/key.pem ubuntu@IP "cat /var/lib/dxnn/.erlang.cookie"
cat ~/.erlang.cookie
# Should be identical
```

## Cost Optimization

### Spot Instance Pricing

```bash
# Check current spot prices
aws ec2 describe-spot-price-history \
    --instance-types c7i.4xlarge \
    --start-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --product-descriptions "Linux/UNIX" \
    --query 'SpotPriceHistory[*].[AvailabilityZone,SpotPrice]' \
    --output table
```

### AMI Storage Costs

- AMI storage: ~$0.05/GB-month
- Typical DXNN AMI: ~10GB = $0.50/month
- Keep only 2-3 recent AMIs to minimize costs

## Next Steps

1. Create your first AMI
2. Launch a test instance
3. Deploy a config and verify training works
4. Set up remote shell access for debugging
5. Launch production instances with different configs

## Support

- Documentation: `AMI-STRATEGY.md`
- Issues: Check `/var/log/dxnn-*.log` files
- AWS Logs: CloudWatch Logs (if configured)
