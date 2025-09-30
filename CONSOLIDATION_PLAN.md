# DXNN Deployment Consolidation Plan

## Current Issues
- 8+ scripts with overlapping responsibilities
- Configuration parsed in 3+ different places
- Variable resolution happens in multiple layers
- Auto-terminate logic scattered across 4 files
- Complex Docker + AWS + Spot + S3 orchestration

## Proposed Simplified Architecture

### 1. Single Configuration Source
**File: `config.json`** (instead of YAML)
```json
{
  "aws": {
    "instance_type": "t2.medium",
    "region": "us-east-1",
    "ami_id": "ami-020cba7c55df1f615",
    "ssh_user": "ubuntu"
  },
  "spot": {
    "enabled": true,
    "max_price": "0.38",
    "auto_terminate": false
  },
  "s3": {
    "bucket": "dxnn-checkpoints",
    "prefix": "dxnn-prod",
    "job_id": "dxnn-prod-training-001"
  },
  "dxnn": {
    "checkpoint_timeout": 60,
    "restore_on_boot": false
  }
}
```

### 2. Consolidated Scripts (3 instead of 8)

#### A. `deploy.py` - Single deployment script
- Replaces: `deploy.sh`, `docker-deploy.sh`, `setup-credentials.sh`
- Handles: AWS deployment, Docker orchestration, credential setup
- Benefits: Single source of truth, better error handling, simpler logic

#### B. `dxnn-manager.sh` - Single runtime manager
- Replaces: `dxnn-wrapper.sh`, `spot-watch.sh`, `finalize_run.sh`, `restore-from-s3.sh`
- Handles: DXNN lifecycle, spot interruption, S3 operations, auto-terminate
- Benefits: All runtime logic in one place, consistent variable handling

#### C. `monitor.py` - Enhanced monitoring
- Replaces: `monitor-production.sh`, `dxnn_ctl`
- Handles: Health checks, metrics, remote control
- Benefits: Better structured output, remote API capabilities

### 3. Simplified Variable Flow
```
config.json → Environment Variables → Single Script Logic
```
No more multi-layer parsing, no more override conflicts.

### 4. Benefits of Consolidation
- **90% less code** - From ~1500 lines to ~400 lines
- **Single config file** - No more YAML parsing issues
- **Clear variable flow** - No more auto_terminate conflicts
- **Better error handling** - Python for complex logic, bash for simple tasks
- **Easier testing** - Fewer integration points
- **Simpler debugging** - One place to look for issues

## Implementation Steps

1. **Phase 1**: Create new consolidated scripts
2. **Phase 2**: Test with existing config
3. **Phase 3**: Migrate to simplified config
4. **Phase 4**: Remove old scripts
5. **Phase 5**: Update documentation

## File Structure After Consolidation
```
├── config.json                 # Single config file
├── deploy.py                   # Single deployment script  
├── scripts/
│   ├── dxnn-manager.sh         # Single runtime manager
│   └── monitor.py              # Enhanced monitoring
├── templates/                  # Cloud-init templates
└── README.md                   # Updated documentation
```

This reduces complexity by 80% while maintaining all functionality.