#!/bin/bash
# Debug script to check what files enumerate_artifacts finds

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <key-file> <instance-ip>"
    exit 1
fi

KEY_FILE="$1"
INSTANCE_IP="$2"

echo "=== Debugging Artifact Enumeration ==="
echo "Instance: $INSTANCE_IP"
echo ""

ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$INSTANCE_IP" << 'ENDSSH'
cd /home/ubuntu/dxnn-trader

echo "--- Files in root directory ---"
ls -lah | grep -E '\.log|\.erl' || echo "No log/erl files in root"

echo ""
echo "--- Mnesia directory ---"
ls -lah Mnesia.nonode@nohost/ 2>/dev/null || echo "Mnesia directory not found"

echo ""
echo "--- Logs directory structure ---"
find logs -type f 2>/dev/null || echo "Logs directory not found or empty"

echo ""
echo "--- Searching for agent_trades.log ---"
find . -name "agent_trades.log" -type f 2>/dev/null || echo "No agent_trades.log found"

echo ""
echo "--- Config file ---"
ls -lah config.erl 2>/dev/null || echo "config.erl not found"

echo ""
echo "--- Simulating enumerate_artifacts ---"
ARTIFACT_DIRS=("Mnesia.nonode@nohost" "logs")
ARTIFACT_FILES=("config.erl")

for dir in "${ARTIFACT_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        echo "Found directory: $dir"
        find "$dir" -type f | head -20
    else
        echo "Missing directory: $dir"
    fi
done

for file in "${ARTIFACT_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        echo "Found file: $file"
    else
        echo "Missing file: $file"
    fi
done
ENDSSH

echo ""
echo "=== Debug Complete ==="
