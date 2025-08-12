#!/bin/bash
set -euo pipefail

# Production DXNN Spot Instance Monitoring Script
# Usage: ./monitor-production.sh [instance_ip] [ssh_key_path]

INSTANCE_IP="${1:-54.166.246.241}"
SSH_KEY="${2:-output/aws-deployment-key-20250812-161307-key.pem}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if instance is reachable
check_connectivity() {
    log_info "Checking connectivity to $INSTANCE_IP..."
    if ssh $SSH_OPTS ubuntu@$INSTANCE_IP "echo 'Connected'" >/dev/null 2>&1; then
        log_success "Instance is reachable"
        return 0
    else
        log_error "Cannot connect to instance"
        return 1
    fi
}

# Monitor system health
monitor_system() {
    log_info "=== SYSTEM HEALTH MONITORING ==="
    
    ssh $SSH_OPTS ubuntu@$INSTANCE_IP "
    echo -e '${BLUE}Uptime:${NC}'
    uptime
    echo
    
    echo -e '${BLUE}Load Average (16 cores available):${NC}'
    cat /proc/loadavg
    echo
    
    echo -e '${BLUE}Memory Usage:${NC}'
    free -h
    echo
    
    echo -e '${BLUE}Disk Usage:${NC}'
    df -h /var/lib/dxnn /var/log
    echo
    "
}

# Monitor DXNN application
monitor_dxnn() {
    log_info "=== DXNN APPLICATION MONITORING ==="
    
    ssh $SSH_OPTS ubuntu@$INSTANCE_IP "
    echo -e '${BLUE}DXNN Health Check:${NC}'
    /usr/local/bin/health-check.sh
    echo
    
    echo -e '${BLUE}DXNN Process Status:${NC}'
    ps aux | grep beam.smp | grep -v grep | head -1
    echo
    
    echo -e '${BLUE}Recent DXNN Output:${NC}'
    sudo -u ubuntu tmux capture-pane -t trader -p | tail -5
    echo
    
    echo -e '${BLUE}Checkpoint Directory:${NC}'
    ls -la /var/lib/dxnn/checkpoints/ | head -10
    echo
    "
}

# Monitor spot watcher
monitor_spot_watcher() {
    log_info "=== SPOT WATCHER MONITORING ==="
    
    ssh $SSH_OPTS ubuntu@$INSTANCE_IP "
    echo -e '${BLUE}Spot Watcher Service Status:${NC}'
    sudo systemctl status spot-watch --no-pager -l
    echo
    
    echo -e '${BLUE}Recent Spot Watcher Logs:${NC}'
    sudo tail -10 /var/log/spot-watch.log
    echo
    
    echo -e '${BLUE}Spot Watcher Process:${NC}'
    ps aux | grep spot-watch | grep -v grep
    echo
    "
}

# Monitor S3 connectivity
monitor_s3() {
    log_info "=== S3 CONNECTIVITY MONITORING ==="
    
    ssh $SSH_OPTS ubuntu@$INSTANCE_IP "
    echo -e '${BLUE}Testing S3 Upload:${NC}'
    echo 'Monitor test - $(date)' > /tmp/monitor-test.txt
    if /usr/local/bin/simple-s3-upload.sh /tmp/monitor-test.txt dxnn-prod/monitoring/test-$(date +%s).txt; then
        echo -e '${GREEN}S3 Upload: OK${NC}'
    else
        echo -e '${RED}S3 Upload: FAILED${NC}'
    fi
    rm -f /tmp/monitor-test.txt
    echo
    
    echo -e '${BLUE}IAM Role Status:${NC}'
    TOKEN=\$(curl -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' -s)
    ROLE=\$(curl -s -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/iam/security-credentials/)
    echo \"IAM Role: \$ROLE\"
    echo
    "
}

# Performance metrics
monitor_performance() {
    log_info "=== PERFORMANCE METRICS ==="
    
    ssh $SSH_OPTS ubuntu@$INSTANCE_IP "
    echo -e '${BLUE}CPU Usage (Top 5 processes):${NC}'
    top -bn1 | head -12 | tail -7
    echo
    
    echo -e '${BLUE}Network Statistics:${NC}'
    ss -tuln | grep -E ':(22|4369|9100)' | head -5
    echo
    
    echo -e '${BLUE}Disk I/O:${NC}'
    iostat -x 1 1 | tail -n +4 | head -5
    echo
    "
}

# Error checking
check_errors() {
    log_info "=== ERROR CHECKING ==="
    
    ssh $SSH_OPTS ubuntu@$INSTANCE_IP "
    echo -e '${BLUE}Recent System Errors:${NC}'
    sudo journalctl --since '1 hour ago' -p err --no-pager | tail -5
    echo
    
    echo -e '${BLUE}DXNN Crash Dumps:${NC}'
    ls -la /var/log/erl_crash.dump 2>/dev/null || echo 'No crash dumps found'
    echo
    
    echo -e '${BLUE}Cloud-init Status:${NC}'
    sudo cloud-init status
    echo
    "
}

# Main monitoring function
main() {
    echo "======================================"
    echo "DXNN Production Monitoring Dashboard"
    echo "Instance: $INSTANCE_IP"
    echo "Time: $(date)"
    echo "======================================"
    echo
    
    if ! check_connectivity; then
        exit 1
    fi
    
    monitor_system
    monitor_dxnn
    monitor_spot_watcher
    monitor_s3
    monitor_performance
    check_errors
    
    log_success "Monitoring complete!"
}

# Run main function
main "$@"