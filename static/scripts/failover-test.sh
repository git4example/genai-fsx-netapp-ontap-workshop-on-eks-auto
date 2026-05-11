#!/bin/bash
# =============================================================================
# FSx for ONTAP Multi-AZ Failover Test Script
# =============================================================================
# This script sends continuous inference requests to the vLLM service every 5
# seconds and logs the HTTP status code with a timestamp. Run this in a second
# terminal BEFORE triggering a failover to observe the brief interruption and
# automatic recovery.
#
# Usage:
#   chmod +x failover-test.sh
#   ./failover-test.sh
#
# Press Ctrl+C to stop.
# =============================================================================

# Quick sanity check — kubectl should already be configured via .bashrc/kubeconfig
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl cannot reach the cluster. Ensure kubeconfig is configured."
  echo "  Try: aws eks update-kubeconfig --name eksworkshop --region \$AWS_REGION"
  exit 1
fi

VLLM_SVC_IP=$(kubectl get svc vllm-mistral7b-service -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -z "$VLLM_SVC_IP" ]; then
  echo "ERROR: Could not find vllm-mistral7b-service. Is the vLLM deployment running?"
  exit 1
fi

echo "=============================================="
echo " FSx ONTAP Multi-AZ Failover Monitor"
echo "=============================================="
echo " vLLM Service IP: $VLLM_SVC_IP"
echo " Polling interval: 5 seconds"
echo " Press Ctrl+C to stop"
echo "=============================================="
echo ""

while true; do
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://$VLLM_SVC_IP:80/v1/models 2>/dev/null)
  TIMESTAMP=$(date '+%H:%M:%S')

  if [ "$RESPONSE" = "200" ]; then
    echo "$TIMESTAMP - HTTP $RESPONSE ✓ (healthy)"
  elif [ "$RESPONSE" = "000" ]; then
    echo "$TIMESTAMP - HTTP $RESPONSE ✗ (timeout/connection refused - failover in progress)"
  else
    echo "$TIMESTAMP - HTTP $RESPONSE ⚠ (unexpected status)"
  fi

  sleep 5
done
