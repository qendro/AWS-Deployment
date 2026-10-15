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
# Option 1: Deploy with custom files
./deploy-config.sh \
    -i output/aws-deployment-key-TIMESTAMP-key.pem \
    -h PUBLIC_IP \
    -c /path/to/config.erl /path/to/custom.hrl \
    -b main \
    --start

# Option 2: Deploy without files (GitHub code only)
./deploy-config.sh \
    -i output/aws-deployment-key-TIMESTAMP-key.pem \
    -h PUBLIC_IP \
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
# Deploy multiple files
./deploy-config.sh -i key.pem -h IP -c config.erl custom.hrl data.txt

# Deploy without files (GitHub only)
./deploy-config.sh -i key.pem -h IP -b main --start

# Switch branch only
./deploy-config.sh -i key.pem -h IP -b v2.1.0

# Deploy single file and start
./deploy-config.sh -i key.pem -h IP -c config.erl -b main --start
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
- **S3 Integration** - Automatic upload on completion or interruption
- **Lineage-Based Paths** - `s3://bucket/prefix/lineage_id/population_id/`
- **Metadata Tracking** - Full checkpoint metadata with lineage tracking
- **Run Bundle Uploads** - Uploads `Mnesia.nonode@nohost/`, `logs/`, optional `analytics/`, plus `_SUCCESS` and `_MANIFEST`
- **Single-Shot Protection** - Prevents duplicate interruption handling
- **Population ID Format** - `<timestamp>_<lineage_code>_run<N>` (e.g., `2026-03-04T01:33:22Z_p08s_run1`)
- **Lineage ID Format** - `<4-char code>` (e.g., `p08s`)
- **S3 Path Structure** - `s3://bucket/prefix/<lineage_id>/<population_id>/` (e.g., `s3://dxnn-checkpoints/dxnn-prod/p08s/2026-03-04T01:33:22Z_p08s_run1/`)
- **Dashboard Compatibility** - `DXNN-Dashboard` can load the run root directly and browse artifacts after load

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
sudo grep -E "^AUTO_TERMINATE(_DEFAULT)?=" /etc/dxnn-env   # Verify auto-terminate setting
```

`auto_terminate` powers off after artifacts and their success marker upload successfully, including diagnostics from failed or interrupted runs. Upload failures keep the instance running for recovery. `SAFE_MODE=true` disables poweroff.

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

Finalized artifacts use `S3_PREFIX/JOB_ID/POPULATION_ID/`. The lineage-level
`_LATEST_RUN` pointer records both identifiers, and restore also supports older
lineage-based artifact paths. For an explicit population override in the new
layout, supply `RESTORE_JOB_ID` together with `RESTORE_POPULATION_ID`.

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

# 3. Deploy files and start
./deploy-config.sh -i output/key.pem -h IP -c ~/my-config.erl ~/custom.hrl -b main --start

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
./deploy-config.sh -i key3.pem -h IP3 -b feature/test --start  # No custom files
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
# Update multiple files without restart
./deploy-config.sh -i output/key.pem -h IP -c new-config.erl custom.hrl

# Update without files (GitHub only)
./deploy-config.sh -i output/key.pem -h IP -b main

# Switch to new branch and restart
./deploy-config.sh -i output/key.pem -h IP -b v2.2.0 --start
```

## 📚 Documentation

- **AMI-STRATEGY.md** - Complete AMI-based deployment architecture and strategy
- **IAM-Policy-Spot.md** - Required IAM permissions for spot instances
- **MULTI-REGION-GUIDE.md** - Deploy instances in any AWS region
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

## OCI stage one: clean Ubuntu instances

`docker-oci.sh` manages Oracle Cloud Infrastructure VMs alongside the AWS
commands. It uses the same `aws-deployment:latest` ARM64 image, with pinned
`oci==2.187.2` and `PyYAML==6.0.3`. Dependency installation, key generation, SSH,
and Python checks run **inside Docker**. AWS credentials and `.env` are not
required. This stage installs no DXNN, Hermes, or other applications on the VM.

### Setup and configuration

Docker Desktop must be running. The wrapper rebuilds an older shared image
when its OCI dependency label is missing. To rebuild after changing Python,
configuration, or Docker dependencies:

```bash
docker buildx build --platform linux/arm64 --load -t aws-deployment:latest .
cp config/oci-qbot.example.yml config/oci-local.yml
```

Configure the root compartment **qendro77** using its tenancy OCID locally.
The example requests `qbot` in `us-chicago-1`, on-demand `VM.Standard.A1.Flex`,
2 OCPUs / 8 GB RAM, and exactly
`Canonical-Ubuntu-24.04-Minimal-aarch64-2026.09.18-0`. Choose either an image
OCID or an exact display name; missing or ambiguous names fail. An optional
`availability_domain` is a preference; other eligible ADs remain available
for capacity fallback. Attempts per AD are bounded to 1–3 per launch command.

The default example reuses the existing `qbot-vcn` / `qbot-public-subnet` and
`~/.ssh/qbot_oci_ed25519{,.pub}`. Alternatively supply the existing subnet OCID.
Existing resources are read and validated, never reconfigured or claimed as
owned. The previous ignored `output/qbot-oci-*` audit/attempt files are useful
context but are not imported as authoritative state. No qbot VM was created
by those attempts: all three Chicago ADs reported capacity exhaustion.

To create a separate minimal public network, replace `network.existing` with
the documented `network.create` block: a private IPv4 VCN, a `10.0.0.0/24`
public subnet, internet gateway, default route, and dedicated security list.
Set `ssh_source_cidr` to your real client IPv4 address/range. The tool allows
SSH from that range and outbound IPv4 traffic. A colliding network name fails;
select existing resources explicitly instead of creating duplicates.

Both SSH key paths must be supplied together. Relative SSH paths are resolved
from the YAML directory; `~` refers to your host home directory. Host absolute
paths, external YAML files, and earlier `/aws-deployment/...` paths are
supported. To generate a key pair, omit **both** key paths. The container
creates a persistent Ed25519 pair in ignored `output/oci/keys/`; private keys
are mode 0600. Supplied pairs must match, be unencrypted, and have private-key
permissions 0600 or stricter. The SSH username defaults in the example to
`ubuntu` and is explicit in YAML.

Use your existing OCI SDK configuration and signing-key files. The default
configuration is `~/.oci/config`, profile `DEFAULT`; alternate values are
selected through the environment:

```bash
# Reuse this repository's existing ignored OCI authentication files:
export OCI_CONFIG_FILE="$PWD/output/oci-auth/config"
export OCI_PROFILE=DEFAULT
# Optional override if the profile's signing-key path needs correction:
# export OCI_SIGNING_KEY_FILE="$HOME/.oci/oci_api_key.pem"
./docker-oci.sh --help
```

Configuration, signing keys, external YAML, and supplied SSH keys are mounted
read-only at their host paths. Relative signing-key paths resolve from the OCI
configuration directory. Nothing installs onto the host. Private keys and
credentials are excluded from the Docker build context and must stay outside
tracked configuration files. OCI state contains key references and public-key
fingerprints, not signing credentials or private-key contents. Temporary SSH
key copies exist only inside the running container and are removed afterward.

The launch uses automatic private/public IPv4, no IPv6, the image-default boot
volume size, Oracle-managed encryption keys, encryption in transit, required
IMDSv2 authorization headers, and `RESTORE_INSTANCE` after maintenance. It
leaves migration preference to Oracle. Oracle Cloud Agent stays enabled;
Compute Instance Monitoring is enabled and other supported optional plugins
(including Run Command and OS Management Hub) are disabled. No user-data,
custom boot-volume size, application provisioning, spot capacity, or resizing
is supported.

### Commands

```bash
./docker-oci.sh launch -c config/oci-local.yml
./docker-oci.sh list
./docker-oci.sh status qbot
./docker-oci.sh ssh qbot
./docker-oci.sh start qbot
./docker-oci.sh stop qbot
./docker-oci.sh reboot qbot

# Pick the storage behavior explicitly; there is no implicit default:
./docker-oci.sh terminate qbot --preserve-boot-volume
./docker-oci.sh terminate qbot --delete-boot-volume
# Optional cleanup of this tool's owned, unused network resources only:
./docker-oci.sh terminate qbot --delete-boot-volume --cleanup-network

# An explicit OCID works even without a local launch record:
./docker-oci.sh status ocid1.instance.oc1... --region us-chicago-1
```

Names resolve only to unambiguous recorded instances. Use an OCID if more than
one record matches. Unrecorded OCIDs use the profile region unless `--region`
is supplied. SSH needs a recorded key reference. `list` covers local OCI
records, and `status`/`list`/`ssh` fetch current lifecycle state and IPs from OCI.
Stop and reboot request graceful `SOFTSTOP` and `SOFTRESET` actions.

### Free-only eligibility and launch recovery

Set `mode: free-only` or explicitly authorize billing with `mode: paid`.
The tool never substitutes another shape or switches modes. Free-only mode
accepts Oracle platform Ubuntu images with OCI-advertised eligible A1 or
E2.1.Micro shapes and requires the tenancy home region. Its conservative
caps are 2 A1 OCPUs / 12 GB RAM, two E2.1.Micro instances, and 200 GB of combined
boot/block storage. These follow the current [Oracle Always Free documentation](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm),
reviewed October 11, 2026. The smaller A1 cap is used even on paid tenancies.
Recheck that documentation before changing the policy; older 4 OCPU / 24 GB
guides are not this implementation's policy.

Preflight inventories the tenancy's compartments and volumes, checks aggregate
A1 usage, and queries OCI [resource availability](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/limits/client/oci.limits.LimitsClient.html)
for eligible ADs, including regional and free-storage limits where published.
Missing permissions or unverifiable limits fail closed. It needs tenancy-wide
read visibility for free-only checks, plus the usual permissions to manage
instances and, only when requested, new network resources. These are launch
time checks; concurrent launches from other tools or future usage can change
billing eligibility. This tool does not enforce a tenancy billing budget.

Ignored `output/oci/` contains atomic mode-0600 JSON records, generated keys,
and SSH `known_hosts`. Records retain the instance OCID, region, AD, image,
network IDs/ownership, key references, retry tokens, and lifecycle progress.
A local lock serializes OCI commands. Keep these records to preserve ownership
and duplicate prevention; AWS/dashboard output records remain separate.

Before sending a launch request, the tool saves its AD, retry token, and
payload hash. Known capacity rejection permits a bounded fallback. A timeout,
generic server error, or ambiguous result stops fallback and retains the
pending request. Rerun **the same configuration** to reconcile the launch tag
or replay the same token and payload. [Oracle retry tokens expire after 24 hours](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/usingapi.htm);
after 23 hours, unresolved requests require manual inspection and the tool
refuses to mint a replacement token. Network creation uses the same recovery
principle. Do not delete records or change names to bypass an unresolved
request. Configuration or key changes for a recorded launch are rejected.

After creation, the tool immediately retains the OCID, waits up to 15 minutes
for RUNNING, then checks public IPv4 and retries SSH for up to five minutes.
It verifies Ubuntu's version and guest architecture. If guest verification
fails, the error explicitly says the instance was created; rerunning launch
verifies that same instance. A recorded terminated/stopped instance does not
cause a replacement launch; use lifecycle commands or a new name deliberately.

### Termination and storage

`--preserve-boot-volume` retains its data and continues consuming storage
allocation, potentially incurring charges. `--delete-boot-volume` permanently
deletes the boot volume and its data. The selected behavior and boot-volume
IDs are saved before termination; storage choice cannot change on a retry.
Termination preserves network resources by default.

`--cleanup-network` requires a local ownership record. It deletes only tagged
resources that this launch created, in dependency order, after checking for
other subnets, private IPs, and gateway route references. OCI dependency
conflicts stop cleanup and retain progress for a retry. Reused networks and
SSH keys are preserved. There is no compartment-wide cleanup. Partial network
creation without an instance OCID is retained for launch recovery; inspect and
remove those owned resources manually if abandoning the launch.

### Validation

Run the mocked failure-path tests without any cloud access:

```bash
docker run --rm --network none --entrypoint python3 \
  -v "$PWD:/aws-deployment:ro" -w /aws-deployment \
  aws-deployment:latest -m unittest discover -s tests -v
```

The Docker build, OCI help/YAML parsing, key generation, mocked capacity and
ambiguous-request recovery, free-only rejections, ownership cleanup, storage
choices, and AWS help entry points were checked inside Docker (the existing
AWS deployment help's STS credential guard was mocked). Read-only OCI
checks also confirmed the exact image, compatibility in all three Chicago
ADs, free-only limits, existing public network, and matching SSH keys.
**Live launch, lifecycle mutations, network creation/deletion, and successful
VM SSH verification remain untested:** implementation validation did not
change cloud resources, and previous qbot launches exhausted host capacity.
