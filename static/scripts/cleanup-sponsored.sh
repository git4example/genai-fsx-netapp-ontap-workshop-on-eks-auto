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

echo "============================================================"
echo "  Workshop Cleanup Script"
echo "============================================================"

export CLUSTER_NAME=${CLUSTER_NAME:-eksworkshop}
echo "AWS_REGION: $AWS_REGION"
echo "CLUSTER_NAME: $CLUSTER_NAME"
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true

echo ""
echo "============================================================"
echo "  Module 3 Cleanup: Observability Stack"
echo "============================================================"

cd /home/participant/environment/eks/genai/observability/ 2>/dev/null || true

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

cd /home/participant/environment/eks/genai 2>/dev/null || true

# Delete application workloads (reverse order)
echo "Deleting Open WebUI..."
kubectl delete -f open-webui.yaml --ignore-not-found 2>/dev/null || true

echo "Deleting vLLM deployment..."
kubectl delete -f mistral-ontap.yaml --ignore-not-found 2>/dev/null || true

# Wait for pods to terminate and inf2 node to drain
echo "Waiting for vLLM pod to terminate..."
kubectl wait --for=delete pod -l app=vllm-mistral-inf2-server --timeout=120s 2>/dev/null || true

# Delete Inferentia NodePool (this will drain and terminate inf2 nodes)
echo "Deleting Inferentia NodePool..."
kubectl delete -f inferentia_nodepool.yaml --ignore-not-found 2>/dev/null || true

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

cd /home/participant/environment/eks/FSxONTAP 2>/dev/null || true

# Delete model loading job
echo "Deleting model-download Job..."
kubectl delete job model-download --ignore-not-found 2>/dev/null || true

# Delete PVC (reclaimPolicy is Retain, so PV and ONTAP volume are preserved)
echo "Deleting PVC (ONTAP volume preserved due to Retain policy)..."
kubectl delete -f ontap-pvc.yaml --ignore-not-found 2>/dev/null || true

# Delete StorageClass
echo "Deleting StorageClass..."
kubectl delete -f ontap-storage-class.yaml --ignore-not-found 2>/dev/null || true

# Delete TridentBackendConfig
echo "Deleting TridentBackendConfig..."
kubectl delete -f trident-backend-config.yaml --ignore-not-found 2>/dev/null || true

# Delete ONTAP secret
echo "Deleting FSx ONTAP secret..."
kubectl delete -f fsx-ontap-secret.yaml --ignore-not-found 2>/dev/null || true

# Verify PV/PVC cleanup
kubectl get pv,pvc 2>/dev/null || true

# Uninstall Trident Operator
echo "Uninstalling Trident Operator..."
helm uninstall trident-operator -n trident 2>/dev/null || true

# Wait for Trident pods to terminate
echo "Waiting for Trident pods to terminate..."
kubectl wait --for=delete pod -l app=controller.csi.trident.netapp.io -n trident --timeout=60s 2>/dev/null || true

# Delete trident namespace
echo "Deleting trident namespace..."
kubectl delete namespace trident --ignore-not-found 2>/dev/null || true

# Delete eksctl IAM service account stack
echo "Deleting eksctl IAM service account CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name "eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-trident-trident-controller" \
    --region $AWS_REGION 2>/dev/null || true

echo "Waiting for IAM stack deletion..."
aws cloudformation wait stack-delete-complete \
    --stack-name "eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-trident-trident-controller" \
    --region $AWS_REGION 2>/dev/null || true

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
echo "  cd /home/participant/environment/terraform"
echo "  terraform destroy --auto-approve"
echo ""
