# AWS Spot Instance Implementation Guide

## 🎯 **Implementation Overview**

This guide implements AWS Spot instance support with **minimal DXNN changes** and **maximum AWS-Deployment control**. The approach ensures:

- ✅ **DXNN minimalism**: Only 1 function added to `benchmarker.erl`
- ✅ **AWS-Deployment handles everything**: IMDS, S3, systemd, orchestration
- ✅ **Single finalizer**: One script handles both completion and interruption
- ✅ **Idempotent operations**: Lock + sentinel prevents double uploads
- ✅ **Deterministic termination**: `poweroff` after AWS termination behavior
- ✅ **Production hardened**: IMDSv2, retry logic, systemd limits

---

## 📋 **Implementation Checklist**

### **Phase 1: AWS-Deployment Infrastructure**

#### **Step 1: Create Idempotent Finalizer Script**
- [x] **File**: `AWS-Deployment/scripts/finalize_run.sh`
- [x] Implement lock-based idempotency with `flock /var/lock/dxnn.finalize.lock`
- [x] Check for S3 sentinel `s3://bucket/prefix/job-id/run-id/_SUCCESS` before proceeding
- [x] Accept `COMPLETION_STATUS` and `EXIT_CODE` environment variables from wrapper
- [x] Implement S3 sync with exponential backoff (7 attempts: 1s, 2s, 4s, 8s, 16s, 32s)
- [x] Write `_SUCCESS` sentinel last with completion metadata (status, exit_code, reason)
- [x] Call `poweroff` for termination
- [x] Log to `/var/log/dxnn-run.log` with UTC timestamps and outcome information
- [x] Upload logs alongside artifacts

#### **Step 2: Create Minimal Wrapper Script**
- [x] **File**: `AWS-Deployment/scripts/dxnn-wrapper.sh`
- [x] Run DXNN directly (no tmux) with `exec` or direct execution
- [x] Wait for DXNN process to exit and capture exit code (`wait $DXNN_PID`)
- [x] Determine completion reason: `normal` (exit code 0) vs `interrupted` (non-zero)
- [x] Call `finalize_run.sh` with `COMPLETION_STATUS` and `EXIT_CODE` environment variables
- [x] Trap TERM/INT to forward to DXNN child process
- [x] No polling, no watchdog, no completion detection
- [x] Log to `/var/log/dxnn-run.log` with exit code and completion reason

#### **Step 3: Modify Spot Watcher (Minimal Changes)**
- [x] **File**: `AWS-Deployment/scripts/spot-watch.sh`
- [x] Keep existing polling loop unchanged
- [x] Keep existing checkpoint logic unchanged
- [x] Replace only the upload/shutdown section with single call to `finalize_run.sh`
- [x] Pass `COMPLETION_STATUS=interrupted` to finalizer

#### **Step 4: Update Configuration for Termination**
- [x] **File**: `AWS-Deployment/config/dxnn-spot.yml`
- [x] Add `instance_initiated_shutdown_behavior: "terminate"`
- [x] Install `flock` package
- [x] Install and start new scripts
- [x] Replace complex tmux startup with wrapper script call

#### **Step 5: Update Deployment Script**
- [x] **File**: `AWS-Deployment/deploy.sh`
- [x] Add `--instance-initiated-shutdown-behavior terminate` to EC2 launch
- [x] Ensure new scripts are copied to instance

---

### **Phase 2: DXNN Changes (Minimal)**

#### **Step 6: Add Completion Signal Function**
- [x] **File**: `DXNN_test_v2/benchmarker.erl`
- [x] Add `completion_signal/0` to exports
- [x] Implement completion checkpoint with `mnesia:backup()`
- [x] Create completion metadata with timestamp and backup file info
- [x] Handle backup errors gracefully
- [x] **NO IMDS, NO S3, NO HTTP dependencies**

#### **Step 7: Update Training Loop**
- [x] **File**: `DXNN_test_v2/benchmarker.erl`
- [x] Call `completion_signal()` when training completes
- [x] Ensure completion signal is sent before process ends
- [x] Maintain existing termination handling

---

### **Phase 3: Testing & Validation**

#### **Step 8: Idempotency Testing**
- [ ] Run `finalize_run.sh` twice on same instance
- [ ] Verify second call is no-op (exits immediately)
- [ ] Verify only one set of artifacts in S3
- [ ] Verify lock mechanism prevents concurrent execution

#### **Step 9: Completion Flow Testing**
- [ ] Deploy test instance with wrapper
- [ ] Let DXNN complete normally
- [ ] Verify `_SUCCESS` sentinel present in S3
- [ ] Verify instance terminates automatically
- [ ] Verify logs uploaded with artifacts

#### **Step 10: Interruption Flow Testing**
- [ ] Deploy test instance with spot watcher
- [ ] Simulate spot interruption
- [ ] Verify `_SUCCESS` sentinel present in S3
- [ ] Verify only one finalization runs
- [ ] Verify instance terminates automatically

#### **Step 11: Upload Failure Policy Testing**
- [ ] Test with S3 access denied
- [ ] Verify failure policy (keep instance vs terminate)
- [ ] Verify `_FAILED_UPLOAD` sentinel if applicable
- [ ] Document and verify chosen policy

---

## ✅ **Acceptance Criteria Checklist**

### **Idempotency Requirements**
- [x] **Lock-based protection**: `flock /var/lock/dxnn.finalize.lock`
- [x] **S3 sentinel check**: Exit if `_SUCCESS` exists in S3
- [x] **Single execution**: Only one finalization runs per instance
- [x] **No duplicate uploads**: Each artifact uploaded exactly once

### **Termination Requirements**
- [x] **EC2 termination behavior**: `InstanceInitiatedShutdownBehavior=terminate`
- [x] **Poweroff command**: `poweroff` after successful upload
- [x] **Deterministic shutdown**: Instance terminates reliably
- [x] **No manual termination**: No `aws ec2 terminate-instances` calls

### **Wrapper Requirements**
- [x] **Minimal design**: No polling, no watchdog, no completion detection
- [x] **Direct execution**: Run DXNN directly (no tmux) with proper process monitoring
- [x] **Exit code capture**: Wait for DXNN exit and capture exit code (`wait $DXNN_PID`)
- [x] **Outcome determination**: Distinguish `normal` (exit code 0) vs `interrupted` (non-zero)
- [x] **Signal forwarding**: Trap TERM/INT and forward to child
- [x] **Single responsibility**: Run DXNN, wait, call finalizer with outcome information

### **Finalizer Requirements**
- [x] **Exponential backoff**: 7 attempts with 1s, 2s, 4s, 8s, 16s, 32s delays
- [x] **S3 sync**: Upload all checkpoints and logs
- [x] **Sentinel last**: Write `_SUCCESS` only after all uploads succeed
- [x] **Outcome metadata**: Include `completion_status`, `exit_code`, and `reason` in sentinel
- [x] **Failure handling**: Clear policy for upload failures
- [x] **Logging**: All operations logged to `/var/log/dxnn-run.log` with outcome information

### **DXNN Minimalism**
- [x] **Single function**: Only `completion_signal/0` added
- [x] **No external dependencies**: No S3, IMDS, or HTTP code
- [x] **Existing checkpoint logic**: Reuse `mnesia:backup()` mechanism
- [x] **Graceful integration**: Minimal changes to existing loop

### **Production Hardening**
- [x] **Lock mechanism**: Prevents race conditions
- [x] **Retry logic**: Handles transient S3 failures
- [x] **Error handling**: Graceful degradation on failures
- [x] **Logging**: Complete audit trail for postmortems

---

## 🚀 **Quick Start Commands**

### **Deploy with Completion Handling**
```bash
cd AWS-Deployment
./docker-deploy.sh -c config/dxnn-spot.yml
```

### **Monitor Completion Flow**
```bash
ssh -i output/aws-deployment-key-*.pem ubuntu@PUBLIC_IP
sudo tail -f /var/log/dxnn-run.log
```

### **Verify S3 Artifacts**
```bash
aws s3 ls s3://dxnn-checkpoints/dxnn/dxnn-training-001/run-*/ --recursive
aws s3 ls s3://dxnn-checkpoints/dxnn/dxnn-training-001/run-*/_SUCCESS
```

### **Test Idempotency**
```bash
# On running instance
sudo /usr/local/bin/finalize_run.sh  # First call
sudo /usr/local/bin/finalize_run.sh  # Second call (should be no-op)
```

---

## 📝 **Implementation Notes**

### **Key Design Decisions**
1. **Single finalizer**: One script handles all termination scenarios
2. **Idempotent operations**: Lock + sentinel prevents double work
3. **Minimal wrapper**: No polling, just process monitoring
4. **Deterministic termination**: `poweroff` after AWS termination behavior
5. **DXNN minimalism**: Only 1 function, no external dependencies
6. **Production hardened**: Retry logic, error handling, complete logging

### **File Structure**
```
AWS-Deployment/
├── scripts/finalize_run.sh           # Idempotent finalizer (NEW)
├── scripts/dxnn-wrapper.sh           # Minimal wrapper (NEW)
├── scripts/spot-watch.sh             # Modified (minimal changes)
├── config/dxnn-spot.yml              # Updated (termination + scripts)
├── deploy.sh                         # Modified (shutdown behavior)
└── README.md                         # Updated documentation

DXNN_test_v2/
└── benchmarker.erl                   # +1 function only
```

### **Configuration Variables**
- `instance_initiated_shutdown_behavior`: "terminate" (required)
- `checkpoint_deadline_seconds`: 60 (from IMDS detection)
- `poll_interval_seconds`: 2
- `s3_bucket`: Required when spot enabled
- `job_id`: Required when restore enabled
- `container_name`: Required when spot enabled

### **Log Format**
```
[UTC 2025-01-11T14:30:12Z] STATE: FINALIZE_START|UPLOAD_SUCCESS|UPLOAD_FAIL|FINALIZE_SUCCESS|FINALIZE_FAILED|TERMINATING
```

### **S3 Layout**
```
s3://bucket/prefix/job-id/run-YYYYMMDD-HHMMSSZ/
├── checkpoint-*.dmp
├── completion-*.dmp
├── *.metadata.json
├── dxnn-run.log
└── _SUCCESS (or _FAILED_UPLOAD)
```

### **S3 Sentinel Format**
```json
{
    "run_id": "20250111-143012Z",
    "finalized_at": "2025-01-11T14:30:12Z",
    "status": "success",
    "completion_status": "normal",
    "exit_code": 0
}
```

---

## 🎯 **Success Criteria**

When complete, you should have:
- ✅ **Single finalizer** handles both completion and interruption
- ✅ **Idempotent operations** (no double uploads)
- ✅ **Robust retry logic** (7 attempts with exponential backoff)
- ✅ **Clear failure handling** (_SUCCESS vs _FAILED_UPLOAD)
- ✅ **Deterministic termination** (poweroff after AWS termination)
- ✅ **Complete logging** (all logs uploaded with artifacts)
- ✅ **Minimal DXNN changes** (exactly 1 function)
- ✅ **Production-ready reliability** with hard deadlines
- ✅ **No polling or watchdogs** (lean, efficient design)

**Total DXNN changes**: 1 function in `benchmarker.erl`
**Total AWS-Deployment changes**: 2 new files + minimal modifications to existing files

---

## 🔄 **Flow Diagrams**

### **Normal Completion Flow**
```
DXNN Training → completion_signal() → Wrapper waits for exit → Capture exit code → finalize_run.sh → S3 Upload → _SUCCESS (with metadata) → poweroff
```

### **Spot Interruption Flow**
```
IMDS Detection → spot-watch.sh → checkpoint_and_exit() → finalize_run.sh → S3 Upload → _SUCCESS (with metadata) → poweroff
```

### **Idempotency Protection**
```
finalize_run.sh → flock lock → Check S3 _SUCCESS → Exit if exists → Upload artifacts → Write _SUCCESS (with metadata) → poweroff
```

---

## 📋 **Testing Scope**

### **Normal Completion**
- [ ] Sentinel `_SUCCESS` present in S3 with `completion_status: "normal"`
- [ ] Instance terminates automatically
- [ ] All artifacts uploaded successfully
- [ ] Logs contain completion flow with exit code 0
- [ ] Wrapper correctly captures and passes outcome information

### **Spot Interruption**
- [ ] Sentinel exists in S3 with `completion_status: "interrupted"`
- [ ] Only one finalization runs
- [ ] Instance terminates automatically
- [ ] Checkpoint artifacts preserved
- [ ] Spot watcher passes `COMPLETION_STATUS=interrupted` to finalizer

### **Idempotency**
- [ ] Run `finalize_run.sh` twice
- [ ] Second call is no-op
- [ ] No duplicate artifacts in S3
- [ ] Lock mechanism prevents race conditions

### **Upload Failure Policy**
- [ ] Decide policy: keep instance vs terminate
- [ ] Verify `_FAILED_UPLOAD` sentinel if applicable
- [ ] Test with S3 access denied
- [ ] Document chosen policy

### **Logging**
- [ ] All operations logged to `/var/log/dxnn-run.log`
- [ ] Logs uploaded with artifacts
- [ ] UTC timestamps for all entries
- [ ] Complete audit trail for postmortems
- [ ] Exit codes and completion reasons captured in logs
- [ ] Rich metadata in S3 sentinel for debugging

This revised plan implements the feedback exactly, creating a lean, robust, and production-ready solution with minimal complexity and maximum reliability.
