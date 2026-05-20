#!/bin/bash
# =============================================================================
# FSx for ONTAP Multi-AZ Failover Test Script
# =============================================================================
# Continuously probes the vLLM /v1/models endpoint via a local kubectl
# port-forward tunnel and logs the HTTP status code + latency on every call.
# Run this in a second terminal BEFORE triggering an FSx ONTAP Multi-AZ
# failover to observe whether the inference endpoint stays serving.
#
# Why kubectl port-forward instead of an Ingress / LoadBalancer?
#   - The vLLM Service is type ClusterIP - only routable from inside the pod
#     network. A direct curl from the VS Code Server cannot hit a ClusterIP.
#   - Port-forward opens a TCP tunnel from VS Code Server -> EKS API server ->
#     vLLM pod. No infrastructure changes are needed and no public exposure
#     is added.
#
# What this probe actually demonstrates:
#   - In a properly-architected Multi-AZ FSx ONTAP + Trident NFS setup, the
#     vLLM pod stays running on the same inf2 node throughout a storage-side
#     failover. /v1/models reads in-memory state, so the EXPECTED behavior is
#     continuous HTTP 200 responses with at most a small latency bump during
#     the failover window. Any non-200 indicates something genuinely broke.
#
# Requirements before running:
#   - vLLM deployment is Running and vllm-mistral7b-service is created.
#   - kubectl is configured for the workshop EKS cluster.
#
# Usage:
#   chmod +x failover-test.sh
#   ./failover-test.sh
#
# Press Ctrl+C to stop.
# =============================================================================

set -uo pipefail

NAMESPACE="${NAMESPACE:-default}"
SERVICE_NAME="${SERVICE_NAME:-vllm-mistral7b-service}"
LOCAL_PORT="${LOCAL_PORT:-18000}"
SERVICE_PORT="${SERVICE_PORT:-80}"
PROBE_INTERVAL_SECONDS="${PROBE_INTERVAL_SECONDS:-5}"
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-10}"
PORT_FORWARD_READY_TIMEOUT="${PORT_FORWARD_READY_TIMEOUT:-30}"

PF_PID=""
PF_LOG="$(mktemp -t failover-pf.XXXXXX.log)"

cleanup() {
  echo ""
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  rm -f "$PF_LOG"
  echo "Stopped."
  exit 0
}
trap cleanup INT TERM

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach the cluster. Ensure kubeconfig is configured."
  echo "  Try: aws eks update-kubeconfig --name eksworkshop --region \$AWS_REGION"
  exit 1
fi

if ! kubectl -n "$NAMESPACE" get svc "$SERVICE_NAME" >/dev/null 2>&1; then
  echo "ERROR: Service $NAMESPACE/$SERVICE_NAME not found."
  echo "       Deploy mistral-ontap.yaml first (Module 2 step)."
  exit 1
fi

# Make sure the chosen local port is not already bound. If it is, increment
# until we find a free one (handy when the script is re-run before the OS
# has released the previous port).
while ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${LOCAL_PORT}\$"; do
  LOCAL_PORT=$((LOCAL_PORT + 1))
done

# ----------------------------------------------------------------------------
# Start (or restart) the port-forward in the background.
# ----------------------------------------------------------------------------
start_port_forward() {
  : > "$PF_LOG"
  kubectl -n "$NAMESPACE" port-forward "svc/${SERVICE_NAME}" \
          "${LOCAL_PORT}:${SERVICE_PORT}" \
          >"$PF_LOG" 2>&1 &
  PF_PID=$!

  # Wait until kubectl prints "Forwarding from 127.0.0.1:<port>" or the
  # process dies.
  local elapsed=0
  while (( elapsed < PORT_FORWARD_READY_TIMEOUT )); do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      return 1
    fi
    if grep -q "Forwarding from 127.0.0.1:${LOCAL_PORT}" "$PF_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

ensure_port_forward() {
  if [[ -z "$PF_PID" ]] || ! kill -0 "$PF_PID" 2>/dev/null; then
    if ! start_port_forward; then
      return 1
    fi
  fi
  return 0
}

echo "Starting kubectl port-forward to svc/${SERVICE_NAME} on localhost:${LOCAL_PORT} ..."
if ! ensure_port_forward; then
  echo "ERROR: port-forward did not become ready within ${PORT_FORWARD_READY_TIMEOUT}s."
  echo "       Last output:"
  sed 's/^/  /' "$PF_LOG"
  cleanup
fi

PROBE_URL="http://127.0.0.1:${LOCAL_PORT}/v1/models"

cat <<EOF
==============================================
 FSx ONTAP Multi-AZ Failover Monitor
==============================================
 Service         : ${NAMESPACE}/${SERVICE_NAME}
 Local tunnel    : 127.0.0.1:${LOCAL_PORT} -> svc:${SERVICE_PORT}
 Probe URL       : ${PROBE_URL}
 Polling interval: ${PROBE_INTERVAL_SECONDS}s
 Per-call timeout: ${PROBE_TIMEOUT_SECONDS}s
 Press Ctrl+C to stop
==============================================
EOF

# ----------------------------------------------------------------------------
# Probe loop. Auto-restart the port-forward if it dies (e.g. transient API
# server hiccup). Keep timing every call so a small latency bump during the
# failover window is visible even when status stays 200.
# ----------------------------------------------------------------------------
while true; do
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  if ! ensure_port_forward; then
    printf '%s  -----  -----  port-forward unavailable, will retry\n' "$TIMESTAMP"
    sleep "$PROBE_INTERVAL_SECONDS"
    continue
  fi

  read -r CODE LATENCY_S < <(
    curl -s -o /dev/null \
      -w '%{http_code} %{time_total}\n' \
      --max-time "$PROBE_TIMEOUT_SECONDS" \
      "$PROBE_URL" \
    || echo "000 0.000"
  )
  LATENCY_MS=$(awk -v t="$LATENCY_S" 'BEGIN { printf "%d", t * 1000 }')

  case "$CODE" in
    200)
      printf '%s  HTTP %s  %5sms  OK\n' \
             "$TIMESTAMP" "$CODE" "$LATENCY_MS"
      ;;
    000)
      printf '%s  HTTP %s  %5sms  no response (tunnel or pod stalled)\n' \
             "$TIMESTAMP" "$CODE" "$LATENCY_MS"
      ;;
    *)
      printf '%s  HTTP %s  %5sms  unexpected status\n' \
             "$TIMESTAMP" "$CODE" "$LATENCY_MS"
      ;;
  esac

  sleep "$PROBE_INTERVAL_SECONDS"
done
