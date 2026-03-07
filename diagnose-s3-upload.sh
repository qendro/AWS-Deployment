#!/bin/bash
# Diagnostic script for S3 upload issues

echo "=== S3 Upload Diagnostics ==="
echo ""

echo "1. Checking AWS Environment Detection:"
echo "   - Checkpoint directory exists:"
ls -ld /var/lib/dxnn/checkpoints/ 2>/dev/null && echo "     ✓ YES" || echo "     ✗ NO"

echo "   - S3_BUCKET environment variable:"
if [[ -n "$S3_BUCKET" ]]; then
    echo "     ✓ Set to: $S3_BUCKET"
else
    echo "     ✗ NOT SET"
fi

echo "   - POPULATION_ID environment variable:"
if [[ -n "$POPULATION_ID" ]]; then
    echo "     ✓ Set to: $POPULATION_ID"
else
    echo "     ✗ NOT SET"
fi

echo "   - LINEAGE_ID environment variable:"
if [[ -n "$LINEAGE_ID" ]]; then
    echo "     ✓ Set to: $LINEAGE_ID"
else
    echo "     ✗ NOT SET"
fi

echo ""
echo "2. Checking Checkpoint Files:"
checkpoint_count=$(find /var/lib/dxnn/checkpoints/ -maxdepth 1 -type d -name "checkpoint-*" 2>/dev/null | wc -l)
echo "   - Number of checkpoints: $checkpoint_count"
if [[ $checkpoint_count -gt 0 ]]; then
    echo "   - Latest checkpoint:"
    latest=$(find /var/lib/dxnn/checkpoints/ -maxdepth 1 -type d -name "checkpoint-*" 2>/dev/null | sort -r | head -1)
    echo "     $latest"
    ls -lh "$latest" 2>/dev/null | head -10
fi

echo ""
echo "3. Checking DXNN Logs for S3 Upload Events:"
echo "   - Searching for 's3_upload' in logs:"
grep -i "s3_upload" /home/ubuntu/dxnn-trader/logs/*.log 2>/dev/null | tail -10 || echo "     No s3_upload events found"

echo ""
echo "4. Checking System Logs:"
echo "   - Last 20 lines of dxnn-run.log:"
tail -20 /var/log/dxnn-run.log 2>/dev/null || echo "     Log file not found"

echo ""
echo "5. Checking if finalize_run.sh is executable:"
if [[ -x /usr/local/bin/finalize_run.sh ]]; then
    echo "   ✓ finalize_run.sh is executable"
else
    echo "   ✗ finalize_run.sh NOT executable or not found"
fi

echo ""
echo "6. Checking DXNN Process Status:"
if tmux has-session -t trader 2>/dev/null; then
    echo "   ✓ DXNN tmux session is running"
    echo "   - Last 10 lines of tmux output:"
    tmux capture-pane -t trader -p | tail -10
else
    echo "   ✗ DXNN tmux session NOT running"
fi

echo ""
echo "7. Checking Erlang checkpoint configuration:"
if [[ -f /home/ubuntu/dxnn-trader/config.erl ]]; then
    echo "   - checkpoint_enabled setting:"
    grep "checkpoint_enabled" /home/ubuntu/dxnn-trader/config.erl || echo "     Not found in config"
else
    echo "   ✗ config.erl not found"
fi

echo ""
echo "8. Testing Manual S3 Upload:"
echo "   Run this command to test: sudo /usr/local/bin/dxnn_ctl upload"

echo ""
echo "=== End Diagnostics ==="
