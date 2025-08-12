# AWS Spot Instance Implementation Guide

## 🎯 **Implementation Overview**

This guide implements AWS Spot instance support with **minimal DXNN changes** and **maximum AWS-Deployment control**. The approach ensures:

- ✅ **DXNN minimalism**: Only 2 functions added to `benchmarker.erl`
- ✅ **AWS-Deployment handles everything**: IMDS, S3, systemd, orchestration
- ✅ **Hard deadlines**: 60s checkpoint timeout from IMDS detection
- ✅ **Single-shot protection**: Lock file prevents duplicate triggers
- ✅ **Deterministic S3 layout**: Job-based keying with UTC timestamps
- ✅ **Production hardened**: IMDSv2, retry logic, systemd limits

---

## 📋 **Implementation Checklist**

### **Phase 1: AWS-Deployment Infrastructure**

#### **Step 1: Create Spot Configuration Template**
- [x] **File**: `AWS-Deployment/config/dxnn-spot.yml`
- [x] Add spot instance configuration with all required fields
- [x] Set `market_type: "spot"` and `spot_max_price`
- [x] Configure `job_id` (required when restore enabled)
- [x] Set `use_rebalance_recommendation: false` (default OFF)
- [x] Include time sync (chrony) in setup commands
- [x] Install yq version (no AWS CLI needed)

#### **Step 2: Create Hardened Spot Watcher Script**
- [x] **File**: `AWS-Deployment/scripts/spot-watch.sh`
- [x] Implement single-shot protection with PID-based lock file
- [x] Add IMDSv2 token handling with TTL and refresh logic
- [x] Poll only `/latest/meta-data/spot/instance-action` by default
- [x] Gate rebalance behind `USE_REBALANCE` flag (default OFF)
- [x] Implement exact 3-retry S3 upload with 1s/2s/4s backoff
- [x] Use UTC timestamps with trailing Z in S3 keys
- [x] Create metadata.json with required fields: `job_id`, `instance_id`, `action`, `utc`, `version`
- [x] Start 60s checkpoint deadline from IMDS detection (not script start)
- [x] Upload immediately if checkpoint finishes early
- [x] Log state transitions: `DETECTED|CHECKPOINT_START|CHECKPOINT_OK|CHECKPOINT_TIMEOUT|UPLOAD_OK|UPLOAD_FAIL|SHUTDOWN`

#### **Step 3: Create Container Control Shim**
- [x] **File**: `AWS-Deployment/scripts/dxnn_ctl`
- [x] Implement clear exit codes: `0=ok`, `10=rpc_failed`, `11=benchmarker_error`
- [x] Handle Erlang cookie file validation
- [x] Support `checkpoint` and `restore` commands
- [x] Return proper exit codes for watcher error handling

#### **Step 4: Create Hardened Systemd Service**
- [x] **File**: `AWS-Deployment/scripts/spot-watch.service`
- [x] Add `After=network-online.target` (no Docker dependency)
- [x] Set `Restart=always` with `RestartSec=3`
- [x] Configure `StartLimitBurst=3` and `StartLimitIntervalSec=60`
- [x] Set `TimeoutStopSec=70` to stay under 2-minute SLA
- [x] Prevent restart storms and keep flow under 2 minutes

#### **Step 5: Create S3 Restore Script**
- [x] **File**: `AWS-Deployment/scripts/restore-from-s3.sh`
- [x] Make S3 primary source of truth
- [x] Find latest folder for specific `job_id`
- [x] Local fallback only if S3 unavailable and local has valid metadata.json
- [x] Log which source won: `S3_SOURCE` or `LOCAL_SOURCE`
- [x] Validate metadata.json contains `job_id` field

#### **Step 6: Modify deploy.sh for Spot Support**
- [x] **File**: `AWS-Deployment/deploy.sh`
- [x] Add spot instance launch support with `--instance-market-options`
- [x] Load all spot configuration from YAML
- [x] Add config validation function `validate_spot_config()`
- [x] Fail fast if required fields missing: `s3_bucket`, `container_name`, `job_id` (when restore enabled)
- [x] Provide clear error messages for missing configuration

#### **Step 7: Update User Data Generation**
- [x] **File**: `AWS-Deployment/deploy.sh` (generate_user_data function)
- [x] Template spot-watch.sh with config values
- [x] Install control shim (`dxnn_ctl`)
- [x] Create `/run` lock path
- [x] Start watcher after container is running
- [x] Add restore from S3 if `restore_from_s3_on_boot: true`
- [x] Ensure proper file permissions and systemd setup

#### **Step 8: Create IAM Policy**
- [x] **File**: `AWS-Deployment/IAM-Policy-Spot.md`
- [x] Limit S3 permissions to checkpoint prefix only
- [x] Include `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`
- [x] No broad wildcards, specific bucket and prefix
- [x] Add EC2 spot instance permissions

---

### **Phase 2: DXNN Changes (Minimal)**

#### **Step 9: Add Checkpoint Function**
- [x] **File**: `DXNN_test_v2/benchmarker.erl`
- [x] Add `checkpoint_and_exit/0` to exports
- [x] Implement checkpoint with `mnesia:backup()`
- [x] Add `file:sync()` before `init:stop()`
- [x] Create metadata.json with timestamp and backup file info
- [x] Handle backup errors gracefully
- [x] **NO IMDS, NO S3, NO HTTP dependencies**

#### **Step 10: Add Restore Function**
- [x] **File**: `DXNN_test_v2/benchmarker.erl`
- [x] Add `maybe_restore/0` to exports
- [x] Restore from latest checkpoint if present
- [x] No-op cleanly if no checkpoints exist
- [x] Handle restore errors gracefully
- [x] **NO IMDS, NO S3, NO HTTP dependencies**

#### **Step 11: Update Startup Sequence**
- [x] **File**: `DXNN_test_v2/benchmarker.erl`
- [x] Call `maybe_restore()` early in startup process
- [x] Ensure restore happens before training begins
- [x] Log restore success/failure

---

### **Phase 3: Testing & Validation**

#### **Step 12: Local Function Testing**
- [x] Test `checkpoint_and_exit/0` function locally
- [x] Verify checkpoint file creation in `/var/lib/dxnn/checkpoints/`
- [x] Test `maybe_restore/0` function locally
- [x] Verify state round-trip (checkpoint → restore)
- [x] Test error handling for missing files

#### **Step 13: Create S3 Bucket**
- [x] Create S3 bucket: `dxnn-checkpoints`
- [x] Set bucket policy for versioning (optional)
- [x] Test bucket access from local environment
- [x] Verify IAM permissions work correctly

#### **Step 14: Deploy Spot Instance**
- [x] Deploy with spot configuration: `./docker-deploy.sh -c config/dxnn-spot.yml`
- [x] Verify instance launches as spot instance
- [x] Check spot watcher service is running
- [x] Monitor logs: `sudo journalctl -u spot-watch -f`

#### **Step 15: Test Spot Interruption (Simulated)**
- [ ] SSH to spot instance
- [ ] Check spot watcher status: `sudo systemctl status spot-watch`
- [ ] Monitor logs: `sudo tail -f /var/log/spot-watch.log`
- [ ] Simulate interruption for testing
- [ ] Verify checkpoint creation and S3 upload
- [ ] Check metadata.json creation

#### **Step 16: Test Restore Process**
- [ ] Deploy new spot instance
- [ ] SSH to new instance
- [ ] Verify automatic restore from S3
- [ ] Check checkpoint files in `/var/lib/dxnn/checkpoints/`
- [ ] Verify S3 download and restore execution
- [ ] Confirm DXNN resumes from checkpoint

---

### **Phase 4: Production Deployment**

#### **Step 17: Create Production Configuration**
- [ ] **File**: `AWS-Deployment/config/dxnn-spot-prod.yml`
- [ ] Copy and modify for production environment
- [ ] Set production `job_id` and `s3_bucket`
- [ ] Configure production instance types and pricing
- [ ] Set appropriate security groups and networking

#### **Step 18: Deploy Production Instance**
- [ ] Deploy production spot instance
- [ ] Monitor deployment and service startup
- [ ] Verify all components are running correctly
- [ ] Test connectivity and basic functionality

#### **Step 19: Monitor and Validate**
- [ ] Monitor spot watcher logs: `sudo journalctl -u spot-watch -f`
- [ ] Check checkpoint creation frequency
- [ ] Monitor S3 uploads and storage usage
- [ ] Verify restore functionality on instance restarts
- [ ] Track performance metrics and error rates

---

## ✅ **Acceptance Criteria Checklist**

### **Timing Requirements**
- [ ] **From IMDS detection → shutdown command ≤ 120s**
- [ ] **Checkpoint deadline 60s from detection** (not script start)
- [ ] **Poll interval 2s** for fast response
- [ ] **S3 upload retry: 3 attempts with 1s/2s/4s backoff**

### **Single-Shot Protection**
- [ ] **Watcher is single-shot even across restarts**
- [ ] **PID-based lock file in `/run/dxnn_spot_triggered`**
- [ ] **Stale lock cleanup on startup**
- [ ] **No duplicate triggers or restart storms**

### **S3 Layout & Metadata**
- [ ] **S3 path format exactly**: `s3://<bucket>/<prefix>/<job_id>/YYYY/MM/DD/HHMMSSZ/`
- [ ] **UTC timestamps with trailing Z**
- [ ] **Required metadata.json**: `job_id`, `instance_id`, `action`, `utc`, `version`
- [ ] **Deterministic keying** (not instance-dependent)

### **Restore Logic**
- [ ] **S3 is primary source of truth**
- [ ] **Local fallback only if S3 unavailable and valid metadata**
- [ ] **On next boot with restore enabled, DXNN resumes from latest S3 for that job_id**
- [ ] **Clear logging of which source won**

### **DXNN Minimalism**
- [ ] **DXNN changed by exactly 2 functions**
- [ ] **No S3/IMDS in Erlang code**
- [ ] **No new dependencies**
- [ ] **Container control shim handles RPC**

### **IMDSv2 & Robustness**
- [ ] **IMDSv2 with token refresh on 401/403**
- [ ] **Never fall back to IMDSv1**
- [ ] **Token TTL 6 hours with refresh logic**
- [ ] **Poll only `/latest/meta-data/spot/instance-action` by default**

### **Systemd & Service Management**
- [ ] **Systemd restart limits and timeouts**
- [ ] **Proper service dependencies and ordering**
- [ ] **TimeoutStopSec=70 to stay under 2-minute SLA**
- [ ] **StartLimitBurst=3 prevents restart storms**

### **Configuration & Validation**
- [ ] **Config validation with fail-fast errors**
- [ ] **Required fields: `s3_bucket`, `container_name`, `job_id` (when restore enabled)**
- [ ] **Clear error messages for missing configuration**
- [ ] **All tunables in single config file**

---

## 🚀 **Quick Start Commands**

### **Deploy Spot Instance**
```bash
cd AWS-Deployment
./docker-deploy.sh -c config/dxnn-spot.yml
```

### **Monitor Spot Watcher**
```bash
ssh -i output/aws-deployment-key-*.pem ubuntu@PUBLIC_IP
sudo journalctl -u spot-watch -f
```

### **Check Checkpoints**
```bash
ls -la /var/lib/dxnn/checkpoints/
aws s3 ls s3://dxnn-checkpoints/dxnn/dxnn-training-001/ --recursive
```

### **Test Restore**
```bash
sudo /usr/local/bin/restore-from-s3.sh
```

---

## 📝 **Implementation Notes**

### **Key Design Decisions**
1. **DXNN minimalism**: Only 2 functions, no external dependencies
2. **AWS-Deployment control**: All IMDS, S3, systemd handling in deployment layer
3. **Hard deadlines**: 60s checkpoint timeout from detection, not script start
4. **Single-shot protection**: PID-based lock prevents duplicate work
5. **S3 primary**: Deterministic layout with job-based keying
6. **Production hardened**: IMDSv2, retry logic, systemd limits

### **File Structure**
```
AWS-Deployment/
├── config/dxnn-spot.yml              # Spot configuration
├── scripts/spot-watch.sh             # Interruption watcher
├── scripts/dxnn_ctl                  # Container control shim
├── scripts/spot-watch.service        # Systemd service
├── scripts/restore-from-s3.sh        # S3 restore script
├── IAM-Policy-Spot.md                # IAM permissions
└── deploy.sh                         # Modified deployment script

DXNN_test_v2/
└── benchmarker.erl                   # +2 functions only
```

### **Configuration Variables**
- `checkpoint_deadline_seconds`: 60 (from IMDS detection)
- `poll_interval_seconds`: 2
- `s3_bucket`: Required when spot enabled
- `job_id`: Required when restore enabled
- `container_name`: Required when spot enabled
- `use_rebalance_recommendation`: false (default OFF)

### **Log Format**
```
[UTC 2025-01-11T14:30:12Z] STATE: DETECTED|CHECKPOINT_START|CHECKPOINT_OK|CHECKPOINT_TIMEOUT|UPLOAD_OK|UPLOAD_FAIL|SHUTDOWN
```

---

## 🎯 **Success Criteria**

When complete, you should have:
- ✅ **Spot instances that gracefully handle interruptions**
- ✅ **Automatic checkpoint creation and S3 upload**
- ✅ **Seamless restore on new instances**
- ✅ **Minimal DXNN code changes** (exactly 2 functions)
- ✅ **Production-ready reliability** with hard deadlines
- ✅ **Deterministic S3 layout** for easy management
- ✅ **Single-shot protection** preventing duplicate work

**Total DXNN changes**: 2 functions in `benchmarker.erl`
**Total AWS-Deployment changes**: 8 new files + modifications to `deploy.sh`
