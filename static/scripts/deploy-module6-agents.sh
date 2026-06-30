#!/bin/bash
# =============================================================================
# Module 6: Agentic AI with FSxN Native Access Control — Quick Deploy
#
# This script automates all steps from Module 6 (sections 610–640) for rapid
# testing or demo setup. For learning purposes, participants should follow
# the step-by-step instructions in the workshop documentation.
#
# Prerequisites:
#   - Modules 1-2 completed (EKS cluster, Trident, vLLM running)
#   - kubectl configured for the eksworkshop cluster
#   - AWS_REGION set in environment
#   - Docker available for building the agent image
# =============================================================================

set -euo pipefail

# --- Resolve workshop directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "${SCRIPT_DIR}/../../static/eks" ]]; then
    WORKSHOP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    EKS_AGENTS_DIR="${WORKSHOP_DIR}/static/eks/agentic-agents"
elif [[ -d "${SCRIPT_DIR}/../eks" ]]; then
    WORKSHOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    EKS_AGENTS_DIR="${WORKSHOP_DIR}/eks/agentic-agents"
else
    echo "ERROR: Could not detect workshop directory layout."
    exit 1
fi

echo "============================================================"
echo "  Module 6: Agentic AI with FSxN Access Control — Quick Deploy"
echo "============================================================"
echo "Workshop directory: $WORKSHOP_DIR"
echo "Agents directory: $EKS_AGENTS_DIR"

# --- Validate prerequisites ---
if [[ -z "${AWS_REGION:-}" ]]; then
    read -p "AWS_REGION is not set. Enter your AWS region (e.g., us-west-2): " AWS_REGION
    export AWS_REGION
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach the cluster."
    echo "  Try: aws eks update-kubeconfig --name eksworkshop --region $AWS_REGION"
    exit 1
fi

if ! kubectl get svc vllm-mistral7b-service >/dev/null 2>&1; then
    echo "ERROR: vLLM service not found. Complete Module 2 first."
    exit 1
fi

echo ""
echo "============================================================"
echo "  Step 1: Retrieve FSxN Details"
echo "============================================================"

export FSXN_FS_ID=$(aws fsx describe-file-systems --region $AWS_REGION \
  --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" \
  --output text)

export FSXN_MGMT_IP=$(aws fsx describe-file-systems --region $AWS_REGION \
  --file-system-ids $FSXN_FS_ID \
  --query "FileSystems[0].OntapConfiguration.Endpoints.Management.IpAddresses[0]" \
  --output text)

export FSXN_SVM_ID=$(aws fsx describe-storage-virtual-machines \
  --filters Name=file-system-id,Values=$FSXN_FS_ID \
  --query "StorageVirtualMachines[0].StorageVirtualMachineId" --output text --region $AWS_REGION)

export FSXN_SVM_NAME=$(aws fsx describe-storage-virtual-machines \
  --filters Name=file-system-id,Values=$FSXN_FS_ID \
  --query "StorageVirtualMachines[0].Name" --output text --region $AWS_REGION)

FSXN_SECRET_NAME=$(aws secretsmanager list-secrets --region $AWS_REGION \
  --query "SecretList[?starts_with(Name,'trident-fsx-ontap-svm-')].Name" --output text)
export FSXN_SVM_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "$FSXN_SECRET_NAME" \
  --query 'SecretString' --output text --region $AWS_REGION)

export FSXN_NFS_IP=$(aws fsx describe-storage-virtual-machines \
  --filters Name=file-system-id,Values=$FSXN_FS_ID \
  --query "StorageVirtualMachines[0].Endpoints.Nfs.IpAddresses[0]" --output text --region $AWS_REGION)

echo "FSx ONTAP FS ID: $FSXN_FS_ID"
echo "Management IP: $FSXN_MGMT_IP"
echo "NFS IP: $FSXN_NFS_IP"
echo "SVM: $FSXN_SVM_NAME ($FSXN_SVM_ID)"

echo ""
echo "============================================================"
echo "  Step 2: Create Data Volumes"
echo "============================================================"

# Create Finance volume
echo "Creating finance_agent_data volume..."
aws fsx create-volume \
  --volume-type ONTAP \
  --name finance_agent_data \
  --ontap-configuration '{
    "JunctionPath": "/finance_data",
    "SizeInMegabytes": 10240,
    "StorageVirtualMachineId": "'$FSXN_SVM_ID'",
    "StorageEfficiencyEnabled": true,
    "TieringPolicy": {"CoolingPeriod": 31, "Name": "AUTO"},
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION 2>/dev/null || echo "Volume may already exist, continuing..."

# Create IT Ops volume
echo "Creating itops_agent_data volume..."
aws fsx create-volume \
  --volume-type ONTAP \
  --name itops_agent_data \
  --ontap-configuration '{
    "JunctionPath": "/it_ops_data",
    "SizeInMegabytes": 10240,
    "StorageVirtualMachineId": "'$FSXN_SVM_ID'",
    "StorageEfficiencyEnabled": true,
    "TieringPolicy": {"CoolingPeriod": 31, "Name": "AUTO"},
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION 2>/dev/null || echo "Volume may already exist, continuing..."

echo "Waiting for volumes to become available..."
while true; do
  STATUS=$(aws fsx describe-volumes --region $AWS_REGION \
    --filters Name=file-system-id,Values=$FSXN_FS_ID \
    --query "Volumes[?Name=='finance_agent_data' || Name=='itops_agent_data'].Lifecycle" \
    --output text)
  if echo "$STATUS" | grep -qv "CREATING"; then
    break
  fi
  echo "  Still creating... checking again in 15s"
  sleep 15
done

aws fsx describe-volumes --region $AWS_REGION \
  --filters Name=file-system-id,Values=$FSXN_FS_ID \
  --query "Volumes[?Name=='finance_agent_data' || Name=='itops_agent_data'].{Name:Name, Status:Lifecycle}" \
  --output table

echo ""
echo "============================================================"
echo "  Step 3: Populate Data Volumes"
echo "============================================================"

cd "$EKS_AGENTS_DIR"

# Delete previous job if exists
kubectl delete job populate-agent-data --ignore-not-found 2>/dev/null || true

# Apply the data population job (needs FSXN_NFS_IP)
envsubst '$FSXN_NFS_IP' < populate-agent-data-job.yaml | kubectl apply -f -

echo "Waiting for data population to complete..."
kubectl wait --for=condition=complete job/populate-agent-data --timeout=300s
kubectl logs job/populate-agent-data

echo ""
echo "============================================================"
echo "  Step 4: Set UNIX Permissions on Volumes"
echo "============================================================"

kubectl delete job set-volume-permissions --ignore-not-found 2>/dev/null || true

envsubst '$FSXN_NFS_IP' < set-volume-permissions-job.yaml | kubectl apply -f -

echo "Waiting for permissions to be set..."
kubectl wait --for=condition=complete job/set-volume-permissions --timeout=120s
kubectl logs job/set-volume-permissions

echo ""
echo "============================================================"
echo "  Step 5: Configure Export Policies"
echo "============================================================"

export POD_CIDR=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}')
echo "Pod CIDR: $POD_CIDR"

# Create export policies
echo "Creating export policy: finance_agents_only..."
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  -X POST "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "finance_agents_only",
    "svm": {"name": "'${FSXN_SVM_NAME}'"},
    "rules": [
      {
        "clients": [{"match": "'${POD_CIDR}'"}],
        "ro_rule": ["sys"],
        "rw_rule": ["never"],
        "superuser": ["none"],
        "protocols": ["nfs3", "nfs4"]
      }
    ]
  }' 2>/dev/null || echo "Policy may already exist"

echo "Creating export policy: itops_agents_only..."
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  -X POST "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "itops_agents_only",
    "svm": {"name": "'${FSXN_SVM_NAME}'"},
    "rules": [
      {
        "clients": [{"match": "'${POD_CIDR}'"}],
        "ro_rule": ["sys"],
        "rw_rule": ["never"],
        "superuser": ["none"],
        "protocols": ["nfs3", "nfs4"]
      }
    ]
  }' 2>/dev/null || echo "Policy may already exist"

echo "Creating export policy: deny_all..."
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  -X POST "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "deny_all",
    "svm": {"name": "'${FSXN_SVM_NAME}'"},
    "rules": [
      {
        "clients": [{"match": "0.0.0.0/0"}],
        "ro_rule": ["never"],
        "rw_rule": ["never"],
        "superuser": ["none"],
        "protocols": ["nfs3", "nfs4"]
      }
    ]
  }' 2>/dev/null || echo "Policy may already exist"

# Apply export policies to volumes
echo "Applying export policies to volumes..."
FINANCE_VOL_UUID=$(curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/storage/volumes?name=finance_agent_data&svm.name=${FSXN_SVM_NAME}" | \
  jq -r '.records[0].uuid')

ITOPS_VOL_UUID=$(curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/storage/volumes?name=itops_agent_data&svm.name=${FSXN_SVM_NAME}" | \
  jq -r '.records[0].uuid')

if [[ -n "$FINANCE_VOL_UUID" && "$FINANCE_VOL_UUID" != "null" ]]; then
    curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
      -X PATCH "https://${FSXN_MGMT_IP}/api/storage/volumes/${FINANCE_VOL_UUID}" \
      -H "Content-Type: application/json" \
      -d '{"nas": {"export_policy": {"name": "finance_agents_only"}}}'
    echo "Applied finance_agents_only to finance volume"
fi

if [[ -n "$ITOPS_VOL_UUID" && "$ITOPS_VOL_UUID" != "null" ]]; then
    curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
      -X PATCH "https://${FSXN_MGMT_IP}/api/storage/volumes/${ITOPS_VOL_UUID}" \
      -H "Content-Type: application/json" \
      -d '{"nas": {"export_policy": {"name": "itops_agents_only"}}}'
    echo "Applied itops_agents_only to itops volume"
fi

echo ""
echo "============================================================"
echo "  Step 6: Create Namespaces"
echo "============================================================"

kubectl create namespace agent-finance 2>/dev/null || echo "Namespace agent-finance already exists"
kubectl create namespace agent-itops 2>/dev/null || echo "Namespace agent-itops already exists"
kubectl create namespace agent-malicious 2>/dev/null || echo "Namespace agent-malicious already exists"

kubectl label namespace agent-finance team=finance role=authorized --overwrite
kubectl label namespace agent-itops team=itops role=authorized --overwrite
kubectl label namespace agent-malicious team=external role=unauthorized --overwrite

echo ""
echo "============================================================"
echo "  Step 7: Set Agent Container Image"
echo "============================================================"

export AGENT_IMAGE="public.ecr.aws/parikshit/fsxn-strands-agent:latest"
echo "Using pre-built agent image: $AGENT_IMAGE"

echo ""
echo "============================================================"
echo "  Step 8: Deploy All Three Agents"
echo "============================================================"

cd "$EKS_AGENTS_DIR"

envsubst '$FSXN_NFS_IP $AGENT_IMAGE' < finance-agent-deployment.yaml | kubectl apply -f -
envsubst '$FSXN_NFS_IP $AGENT_IMAGE' < itops-agent-deployment.yaml | kubectl apply -f -
envsubst '$AGENT_IMAGE' < malicious-agent-deployment.yaml | kubectl apply -f -

echo "Waiting for agent pods to start..."
sleep 15

echo ""
echo "=== Finance Agent ==="
kubectl get pods -n agent-finance
echo ""
echo "=== IT Ops Agent ==="
kubectl get pods -n agent-itops
echo ""
echo "=== Malicious Agent ==="
kubectl get pods -n agent-malicious

echo ""
echo "============================================================"
echo "  Module 6 Deployment Complete!"
echo "============================================================"
echo ""
echo "Test commands:"
echo ""
echo "  # Finance Agent — should succeed"
echo "  kubectl exec -n agent-finance deployment/finance-agent -- python agent.py 'List all files in my data directory'"
echo ""
echo "  # IT Ops Agent — should succeed"
echo "  kubectl exec -n agent-itops deployment/itops-agent -- python agent.py 'Show me the incident response runbook'"
echo ""
echo "  # Malicious Agent — should be BLOCKED"
echo "  kubectl exec -n agent-malicious deployment/malicious-agent -- sh -c 'mount -t nfs4 ${FSXN_NFS_IP}:/finance_data /mnt 2>&1'"
echo ""
echo "FSxN NFS IP: $FSXN_NFS_IP"
echo "Agent Image: $AGENT_IMAGE"
echo ""
