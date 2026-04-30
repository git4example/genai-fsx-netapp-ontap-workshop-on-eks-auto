#!/bin/bash
# =============================================================================
# Workshop cleanup-sponsored.sh — Reverse of quick-deploy-sponsored.sh
#
# This script tears down all resources created by the workshop instructions
# (Modules 1–3) or by quick-deploy-sponsored.sh. Resources are deleted in
# reverse order to respect dependencies.
#
# Prerequisites:
#   - kubectl configured for the eksworkshop cluster
#   - Environment variables: AWS_REGION, AWS_ACCOUNTID, CLUSTER_NAME
# =============================================================================

set -uo pipefail  # Don't use -e; we want to continue on individual failures

# --- Resolve workshop directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "${SCRIPT_DIR}/../../static/eks" ]]; then
    WORKSHOP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    TERRAFORM_DIR="${WORKSHOP_DIR}/static/terraform"
    EKS_ONTAP_DIR="${WORKSHOP_DIR}/static/eks/FSxONTAP"
    EKS_GENAI_DIR="${WORKSHOP_DIR}/static/eks/genai"
    OBSERVABILITY_DIR="${EKS_GENAI_DIR}/observability"
elif [[ -d "${SCRIPT_DIR}/../eks" ]]; then
    WORKSHOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    TERRAFORM_DIR="${WORKSHOP_DIR}/terraform"
    EKS_ONTAP_DIR="${WORKSHOP_DIR}/eks/FSxONTAP"
    EKS_GENAI_DIR="${WORKSHOP_DIR}/eks/genai"
    OBSERVABILITY_DIR="${EKS_GENAI_DIR}/observability"
else
    echo "ERROR: Could not detect workshop directory layout."
    echo "Expected eks/ and terraform/ directories near: $SCRIPT_DIR"
    exit 1
fi

echo "============================================================"
echo "  Workshop Cleanup Script"
echo "============================================================"
echo "Workshop directory: $WORKSHOP_DIR"

# --- Helper: delete a CloudFormation stack (handles termination protection) ---
delete_cfn_stack() {
    local stack_name="$1"
    local region="$2"

    local status
    status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
    echo "  Stack: $stack_name  Status: $status"

    if [[ "$status" == "NOT_FOUND" || "$status" == "DELETE_COMPLETE" ]]; then
        echo "  Stack not found or already deleted, skipping."
        return 0
    fi

    echo "  Disabling termination protection..."
    if ! aws cloudformation update-termination-protection \
        --no-enable-termination-protection \
        --stack-name "$stack_name" --region "$region" 2>&1; then
        echo "  WARNING: Could not disable termination protection (missing cloudformation:UpdateTerminationProtection permission)."
        echo "  Skipping stack deletion. Delete manually from the CloudFormation console."
        return 1
    fi

    echo "  Deleting stack..."
    aws cloudformation delete-stack --stack-name "$stack_name" --region "$region"

    echo "  Waiting for deletion (timeout: 5 minutes)..."
    aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$region" 2>/dev/null \
        || echo "  Stack deletion timed out or failed — check the CloudFormation console."
}

# Auto-detect AWS_ACCOUNTID if not set
if [[ -z "${AWS_ACCOUNTID:-}" ]]; then
    export AWS_ACCOUNTID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
fi

# Prompt for AWS_REGION if not set
if [[ -z "${AWS_REGION:-}" ]]; then
    read -p "AWS_REGION is not set. Enter your AWS region (e.g., us-west-2): " AWS_REGION
    export AWS_REGION
fi

export CLUSTER_NAME=${CLUSTER_NAME:-eksworkshop}
echo "AWS_REGION: $AWS_REGION"
echo "AWS_ACCOUNTID: ${AWS_ACCOUNTID:-unknown}"
echo "CLUSTER_NAME: $CLUSTER_NAME"
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true

echo ""
echo "============================================================"
echo "  Module 3 Cleanup: Observability Stack"
echo "============================================================"

cd "$OBSERVABILITY_DIR" 2>/dev/null || true

# Delete monitoring resources (reverse order of apply)
kubectl delete -f vllm-neuron-dashboard-configmap.yaml --ignore-not-found 2>/dev/null || true
kubectl delete -f neuron-servicemonitor.yaml --ignore-not-found 2>/dev/null || true
kubectl delete -f neuron-monitor.yaml --ignore-not-found 2>/dev/null || true
kubectl delete -f vllm-servicemonitor.yaml --ignore-not-found 2>/dev/null || true

# Delete optional dashboards if they were deployed
kubectl delete -f vllm-performance-dashboard.yaml --ignore-not-found 2>/dev/null || true
kubectl delete -f vllm-query-statistics.yaml --ignore-not-found 2>/dev/null || true
kubectl delete -f neuron-monitoring-configmap.yaml --ignore-not-found 2>/dev/null || true

# Uninstall Kube Prometheus Stack
echo "Uninstalling kube-prometheus-stack..."
helm uninstall kube-prometheus-stack -n kube-system 2>/dev/null || true

# Clean up CRDs left behind by prometheus stack
kubectl delete crd alertmanagerconfigs.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd alertmanagers.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd podmonitors.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd probes.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd prometheusagents.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd prometheuses.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd prometheusrules.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd scrapeconfigs.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd servicemonitors.monitoring.coreos.com --ignore-not-found 2>/dev/null || true
kubectl delete crd thanosrulers.monitoring.coreos.com --ignore-not-found 2>/dev/null || true

echo "Module 3 cleanup complete."

echo ""
echo "============================================================"
echo "  Module 2 Cleanup: vLLM, Open WebUI, Neuron, NodePool"
echo "============================================================"

cd "$EKS_GENAI_DIR" 2>/dev/null || true

# Delete application workloads (reverse order)
echo "Uninstalling Open WebUI..."
helm uninstall open-webui -n default 2>/dev/null || true

echo "Deleting vLLM deployment..."
kubectl delete deployment vllm-mistral-inf2-deployment --ignore-not-found 2>/dev/null || true
kubectl delete service vllm-mistral7b-service --ignore-not-found 2>/dev/null || true

# Wait for pods to terminate and inf2 node to drain
echo "Waiting for vLLM pod to terminate..."
kubectl wait --for=delete pod -l app=vllm-mistral-inf2-server --timeout=120s 2>/dev/null || true

# Delete Inferentia NodePool (this will drain and terminate inf2 nodes)
echo "Deleting Inferentia NodePool..."
kubectl delete nodepool inferentia --ignore-not-found 2>/dev/null || true
kubectl delete nodeclass inferentia --ignore-not-found 2>/dev/null || true

# Wait for inf2 node to be removed
echo "Waiting for inf2 node to terminate (up to 5 minutes)..."
sleep 30
kubectl get nodes 2>/dev/null || true

# Uninstall Neuron Helm Chart
echo "Uninstalling Neuron Helm Chart..."
helm uninstall neuron-helm-chart -n kube-system 2>/dev/null || true

echo "Module 2 cleanup complete."

echo ""
echo "============================================================"
echo "  Module 1 Cleanup: Storage, Trident, IAM"
echo "============================================================"

cd "$EKS_ONTAP_DIR" 2>/dev/null || true

# Delete model loading job
echo "Deleting model-download Job..."
kubectl delete job model-download --ignore-not-found 2>/dev/null || true

# Delete PVC first (Trident needs the backend to process PVC deletion)
echo "Deleting PVC (ONTAP volume preserved due to Retain policy)..."
kubectl delete -f ontap-pvc.yaml --ignore-not-found 2>/dev/null || true

# Delete StorageClass
echo "Deleting StorageClass..."
kubectl delete -f ontap-storage-class.yaml --ignore-not-found 2>/dev/null || true

# Delete TridentBackendConfig (must happen while Trident operator is still running)
echo "Deleting TridentBackendConfig..."
kubectl delete -f trident-backend-config.yaml --ignore-not-found --timeout=30s 2>/dev/null || true

# If TBC is stuck in Deleting state, remove the finalizer to unblock it
if kubectl get tbc backend-ontap-nas -n trident -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    echo "TridentBackendConfig stuck in Deleting state, removing finalizer..."
    kubectl patch tbc backend-ontap-nas -n trident --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
fi

# Delete ONTAP secret
echo "Deleting FSx ONTAP secret..."
kubectl delete -f fsx-ontap-secret.yaml --ignore-not-found 2>/dev/null || true

# Delete VolumeSnapshotClass (if created in Module 4)
echo "Deleting VolumeSnapshotClass..."
kubectl delete -f volume-snapshot-class.yaml --ignore-not-found 2>/dev/null || true

# Delete any VolumeSnapshots created in Module 4
echo "Deleting VolumeSnapshots..."
kubectl delete volumesnapshot --all --ignore-not-found 2>/dev/null || true

# Delete VolumeSnapshot CRDs (installed by deploy script)
echo "Deleting VolumeSnapshot CRDs..."
kubectl delete crd volumesnapshotclasses.snapshot.storage.k8s.io --ignore-not-found 2>/dev/null || true
kubectl delete crd volumesnapshotcontents.snapshot.storage.k8s.io --ignore-not-found 2>/dev/null || true
kubectl delete crd volumesnapshots.snapshot.storage.k8s.io --ignore-not-found 2>/dev/null || true

# Verify PV/PVC cleanup
kubectl get pv,pvc 2>/dev/null || true

# Uninstall Trident Operator (after all Trident CRDs are deleted)
echo "Uninstalling Trident Operator..."
helm uninstall trident-operator -n trident 2>/dev/null || true

# Wait for Trident pods to terminate
echo "Waiting for Trident pods to terminate..."
kubectl wait --for=delete pod -l app=controller.csi.trident.netapp.io -n trident --timeout=60s 2>/dev/null || true

# Remove finalizers from any remaining Trident CRDs (prevents namespace stuck in Terminating)
echo "Cleaning up Trident custom resources..."
for crd in tridentbackends tridentbackendconfigs tridentnodes tridentversions tridentvolumes tridentvolumepublications tridentvolumetransactions tridentsnapshots tridentactionsnapshotrestores tridentstorageclasses; do
    for resource in $(kubectl get ${crd}.trident.netapp.io -n trident -o name 2>/dev/null); do
        kubectl patch $resource -n trident --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    done
done

# Delete trident namespace
echo "Deleting trident namespace..."
kubectl delete namespace trident --ignore-not-found --timeout=30s 2>/dev/null || true

# Delete eksctl IAM service account stack
EKSCTL_STACK_NAME="eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-trident-trident-controller"
echo "Deleting eksctl IAM service account CloudFormation stack..."
delete_cfn_stack "$EKSCTL_STACK_NAME" "$AWS_REGION"

# Delete IAM policy
echo "Deleting IAM policy Amazon_FSx_ONTAP_Trident_CSI_Driver..."
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNTID}:policy/Amazon_FSx_ONTAP_Trident_CSI_Driver"
aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true

# Clean up local files
echo "Cleaning up local files..."
rm -f trident-csi-driver.json 2>/dev/null || true

echo "Module 1 cleanup complete."

echo ""
echo "============================================================"
echo "  Cleanup Complete!"
echo "============================================================"
echo ""
echo "Remaining infrastructure (EKS cluster, VPC, FSx ONTAP) is"
echo "managed by Terraform and the CloudFormation stack. These are"
echo "NOT deleted by this script."
echo ""
echo "To destroy all infrastructure:"
echo "  cd $TERRAFORM_DIR"
echo "  terraform destroy --auto-approve"
echo ""
