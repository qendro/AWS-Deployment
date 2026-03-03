#!/bin/bash
# Diagnostic script for DXNN spot instances

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <key-file> <instance-ip>"
    echo "Example: $0 output/key.pem 54.161.14.99"
    exit 1
fi

KEY_FILE="$1"
INSTANCE_IP="$2"

echo "=== DXNN Instance Diagnostics ==="
echo "Instance: $INSTANCE_IP"
echo "Time: $(date)"
echo ""

# Function to run SSH command
run_ssh() {
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$INSTANCE_IP" "$@"
}

echo "--- System Status ---"
run_ssh "uptime && free -h && df -h /"

echo ""
echo "--- DXNN Process Status ---"
run_ssh "tmux list-sessions 2>/dev/null || echo 'No tmux sessions'"
run_ssh "ps aux | grep -E 'beam|erl' | grep -v grep || echo 'No Erlang processes'"

echo ""
echo "--- DXNN Directory ---"
run_ssh "ls -lah /home/ubuntu/dxnn-trader/ 2>/dev/null || echo 'Directory not found'"
run_ssh "ls -lah /home/ubuntu/dxnn-trader/Mnesia.nonode@nohost/ 2>/dev/null || echo 'Mnesia not found'"
run_ssh "ls -lah /home/ubuntu/dxnn-trader/logs/ 2>/dev/null || echo 'Logs directory not found'"

echo ""
echo "--- Checking for Stray Files ---"
run_ssh "ls -lah /home/ubuntu/dxnn-trader/agent_trades.log 2>/dev/null || echo 'No agent_trades.log in root'"
run_ssh "ls -lah /home/ubuntu/dxnn-trader/logs/Benchmarker/ 2>/dev/null || echo 'Benchmarker directory not found'"

echo ""
echo "--- Configuration ---"
run_ssh "ls -lah /home/ubuntu/dxnn-trader/config.erl 2>/dev/null || echo 'config.erl not found'"
run_ssh "cat /home/ubuntu/READY_FOR_CONFIG 2>/dev/null && echo 'Instance ready for config' || echo 'Not ready'"

echo ""
echo "--- Recent Logs (last 50 lines) ---"
echo "=== dxnn-run.log ==="
run_ssh "sudo tail -50 /var/log/dxnn-run.log 2>/dev/null || echo 'Log not found'"

echo ""
echo "=== dxnn-setup.log ==="
run_ssh "sudo tail -50 /var/log/dxnn-setup.log 2>/dev/null || echo 'Log not found'"

echo ""
echo "=== spot-watch.log ==="
run_ssh "sudo tail -20 /var/log/spot-watch.log 2>/dev/null || echo 'Log not found'"

echo ""
echo "--- Service Status ---"
run_ssh "sudo systemctl status spot-watch --no-pager || true"

echo ""
echo "=== Diagnostics Complete ==="
