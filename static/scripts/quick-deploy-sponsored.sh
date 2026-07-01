#!/bin/bash
# =============================================================================
# Workshop quick-deploy-sponsored.sh — All participant commands in execution order
#
# This script mirrors the workshop instructions from Modules 1–3.
# It can be used as a quick rundown to configure everything and test
# the workshop command execution end-to-end.
#
# Prerequisites:
#   - AWS credentials configured (CLI, instance role, or environment variables)
#   - AWS_REGION set in environment, or script will prompt for it
#   - AWS_ACCOUNTID auto-detected from caller identity if not set
#   - EKS cluster "eksworkshop" already provisioned via Terraform
#   - FSx for ONTAP file system, SVM, and volume already provisioned
# =============================================================================

set -euo pipefail

# --- Resolve workshop directory ---
# Works in both layouts:
#   Project repo: static/scripts/ -> static/ contains eks/, terraform/
#   VSCode server: /home/participant/environment/scripts/ -> environment/ contains eks/, terraform/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try project repo layout first (script at static/scripts/, root is ../..)
if [[ -d "${SCRIPT_DIR}/../../static/eks" ]]; then
    WORKSHOP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    TERRAFORM_DIR="${WORKSHOP_DIR}/static/terraform"
    EKS_ONTAP_DIR="${WORKSHOP_DIR}/static/eks/FSxONTAP"
    EKS_GENAI_DIR="${WORKSHOP_DIR}/static/eks/genai"
    OBSERVABILITY_DIR="${EKS_GENAI_DIR}/observability"
# VSCode server layout (script at environment/scripts/, siblings are eks/, terraform/)
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
echo "  Workshop Quick Setup Script"
echo "============================================================"
echo "Workshop directory: $WORKSHOP_DIR"

# --- Initial setup ---
CALLER_IDENTITY=$(aws sts get-caller-identity --output json)
echo "$CALLER_IDENTITY" | jq .

# Auto-detect AWS_ACCOUNTID from caller identity if not set
if [[ -z "${AWS_ACCOUNTID:-}" ]]; then
    export AWS_ACCOUNTID=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
    echo "Auto-detected AWS_ACCOUNTID: $AWS_ACCOUNTID"
fi

# Prompt for AWS_REGION if not set
if [[ -z "${AWS_REGION:-}" ]]; then
    read -p "AWS_REGION is not set. Enter your AWS region (e.g., us-west-2): " AWS_REGION
    export AWS_REGION
fi

export CLUSTER_NAME=eksworkshop
echo "AWS_REGION: $AWS_REGION"
echo "AWS_ACCOUNTID: $AWS_ACCOUNTID"
echo "CLUSTER_NAME: $CLUSTER_NAME"

# Enable visibility of EKS Auto Mode managed EC2 instances in the console
aws ec2 modify-managed-resource-visibility --default-visibility visible --region $AWS_REGION 2>/dev/null || true
echo "EC2 managed resource visibility: enabled"

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

echo ""
echo "============================================================"
echo "  Module 1: Deploy Trident CSI Driver for FSx for ONTAP"
echo "============================================================"

# --- Step 1: Create IAM policy JSON ---
cat << EOF > trident-csi-driver.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "fsx:DescribeFileSystems",
                "fsx:DescribeVolumes",
                "fsx:DescribeStorageVirtualMachines",
                "fsx:CreateVolume",
                "fsx:DeleteVolume",
                "fsx:UpdateVolume",
                "fsx:TagResource",
                "fsx:UntagResource"
            ],
            "Resource": "*"
        },
        {
            "Action": "iam:CreateServiceLinkedRole",
            "Effect": "Allow",
            "Resource": "*",
            "Condition": {
                "StringLike": {
                    "iam:AWSServiceName": [
                        "fsx.amazonaws.com"
                    ]
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue"
            ],
            "Resource": "arn:aws:secretsmanager:*:*:secret:trident-fsx-*"
        }
    ]
}
EOF

# --- Step 2: Create the IAM policy (skip if already exists) ---
aws iam create-policy \
        --policy-name Amazon_FSx_ONTAP_Trident_CSI_Driver \
        --policy-document file://trident-csi-driver.json 2>&1 || echo "IAM policy already exists, continuing..."

# --- Step 3: Create service account for Trident (skip if already exists) ---
eksctl create iamserviceaccount \
    --region $AWS_REGION \
    --cluster=$CLUSTER_NAME \
    --namespace trident \
    --name=trident-controller \
    --attach-policy-arn arn:aws:iam::$AWS_ACCOUNTID:policy/Amazon_FSx_ONTAP_Trident_CSI_Driver \
    --role-name=trident-controller \
    --role-only \
    --approve 2>&1 || echo "IAM service account already exists, continuing..."

# --- Step 4: Save the Role ARN ---
export ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-trident-trident-controller" --query "Stacks[0].Outputs[0].OutputValue" --region $AWS_REGION --output text)
echo "ROLE_ARN: $ROLE_ARN"

# --- Step 5: Deploy Trident CSI driver via Helm ---
helm repo add netapp-trident https://netapp.github.io/trident-helm-chart --force-update
helm repo update

helm upgrade --install trident-operator netapp-trident/trident-operator \
    --version 100.2602.0 \
    --set cloudProvider="AWS" \
    --set cloudIdentity="'eks.amazonaws.com/role-arn: ${ROLE_ARN}'" \
    --namespace trident \
    --create-namespace

echo "Waiting for Trident pods to be ready..."
sleep 30
kubectl get pods -n trident

# --- Step 5b: Install Kubernetes VolumeSnapshot CRDs (required for Module 4) ---
echo "Installing VolumeSnapshot CRDs (external-snapshotter v8.2.0)..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml

# --- Step 5c: Install the standalone snapshot-controller Deployment ---
# CRDs alone do not process snapshot requests. The snapshot-controller is the
# cluster-wide Deployment that translates VolumeSnapshot objects into
# VolumeSnapshotContent objects, which Trident's csi-snapshotter sidecar then
# turns into real ONTAP snapshots. Without it, every VolumeSnapshot stays
# stuck with empty READYTOUSE / SNAPSHOTCONTENT columns indefinitely.
echo "Installing snapshot-controller (external-snapshotter v8.2.0)..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

# Scale to a single replica. Upstream defaults to 2 for leader-elected HA;
# the workshop only needs one and this keeps resource usage minimal.
kubectl -n kube-system scale deploy/snapshot-controller --replicas=1
kubectl -n kube-system rollout status deploy/snapshot-controller --timeout=120s
kubectl -n kube-system get pods -l app=snapshot-controller

# --- Step 6: Configure Trident backend for FSx ONTAP ---
cd "$EKS_ONTAP_DIR"

# Step 6.7: Retrieve SVM password from Secrets Manager
SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'trident-fsx-ontap-svm-')].Name" --output text --region $AWS_REGION)
SVM_PASSWORD=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query "SecretString" --output text --region $AWS_REGION)
echo "SVM Password retrieved from secret: $SECRET_NAME"

# Step 6.8: Apply the secret (envsubst replaces $SVM_PASSWORD in the template)
export SVM_PASSWORD
envsubst '$SVM_PASSWORD' < fsx-ontap-secret.yaml | kubectl apply -f -

# Step 6.10: Retrieve SVM management LIF and name
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text --region $AWS_REGION)
SVM_MGMT_LIF=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].Endpoints.Management.DNSName" --output text --region $AWS_REGION)
SVM_NAME=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].Name" --output text --region $AWS_REGION)
echo "SVM Management LIF: $SVM_MGMT_LIF"
echo "SVM Name: $SVM_NAME"

# Step 6.11: Apply TridentBackendConfig (envsubst replaces $SVM_MGMT_LIF and $SVM_NAME)
export SVM_MGMT_LIF SVM_NAME
envsubst '$SVM_MGMT_LIF $SVM_NAME' < trident-backend-config.yaml | kubectl apply -f -

# Step 6.12: Verify backend
echo "Waiting for Trident backend to register..."
sleep 15
kubectl get tridentbackendconfig -n trident

echo ""
echo "============================================================"
echo "  Module 1: Create StorageClass and PVC (Dynamic Provisioning)"
echo "============================================================"

cd "$EKS_ONTAP_DIR"

# Apply StorageClass
kubectl apply -f ontap-storage-class.yaml
kubectl get storageclass ontap-nas-sc

# Apply PVC
kubectl apply -f ontap-pvc.yaml
echo "Waiting for PVC to bind..."
sleep 10
kubectl get pvc ontap-model-claim

# Verify backend health
kubectl get tridentbackendconfig -n trident

echo ""
echo "============================================================"
echo "  Module 2: Deploy vLLM on AWS Inferentia"
echo "============================================================"

# --- Step 1: Install Neuron Helm Chart ---
cd "$TERRAFORM_DIR"

helm upgrade --install neuron-helm-chart \
    oci://public.ecr.aws/neuron/neuron-helm-chart \
    --namespace kube-system \
    --version 1.5.0 \
    -f "$TERRAFORM_DIR/helm-values/neuron-values.yaml"

# --- Step 2: Create Inferentia NodePool ---
NODE_ROLE=""
RAW_OUTPUT=$(cd "$TERRAFORM_DIR" 2>/dev/null && terraform output --raw eks_node_iam_role_name 2>/dev/null) || true
# Validate: a valid IAM role name is alphanumeric with hyphens/underscores, max 64 chars
CLEAN_ROLE=$(echo "$RAW_OUTPUT" | grep -oE '^[a-zA-Z0-9_+=,.@-]{1,64}$' | head -1 || true)
if [[ -n "$CLEAN_ROLE" ]]; then
    NODE_ROLE="$CLEAN_ROLE"
fi
if [[ -z "$NODE_ROLE" ]]; then
    echo "Could not retrieve NODE_ROLE from terraform output (state may be on another machine)."
    read -p "Enter the EKS node IAM role name: " NODE_ROLE
fi
echo "NODE_ROLE: $NODE_ROLE"
cd "$EKS_GENAI_DIR"
export NODE_ROLE
envsubst '$NODE_ROLE' < inferentia_nodepool.yaml | kubectl apply -f -
kubectl get nodepool,nodeclass inferentia

# --- Step 3: Load Mistral-7B model onto FSx ONTAP volume ---
cd "$EKS_ONTAP_DIR"

# Check if model-download job already completed
if kubectl get job model-download -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q "1"; then
    echo "Model download Job already completed, skipping..."
else
    kubectl delete job model-download --ignore-not-found 2>/dev/null || true
    kubectl apply -f model-loading-job.yaml

    echo "Waiting for model-download Job to complete (timeout: 1800s)..."./c
    echo "Tip: In another terminal, run: kubectl logs -f job/model-download"
    kubectl wait --for=condition=complete job/model-download --timeout=1800s
fi

# --- Step 4: Deploy vLLM ---
cd "$EKS_GENAI_DIR"

# For Multi-AZ, use the preferred subnet (where the active file server runs) for optimal latency
FSX_ONTAP_AZ=$(aws fsx describe-file-systems --region $AWS_REGION --query "FileSystems[?FileSystemType=='ONTAP'].OntapConfiguration.PreferredSubnetId" --output text | head -1 | xargs -I {} aws ec2 describe-subnets --subnet-ids {} --query 'Subnets[0].AvailabilityZone' --output text)
export FSX_ONTAP_AZ
echo "FSX_ONTAP_AZ (preferred/active): $FSX_ONTAP_AZ"

envsubst '$FSX_ONTAP_AZ' < mistral-ontap.yaml | kubectl apply -f -

# --- Step 4b: Deploy LiteLLM AI Gateway ---
echo "Deploying LiteLLM AI Gateway..."
kubectl apply -f "$EKS_GENAI_DIR/litellm-config.yaml"
export AWS_REGION
envsubst '$AWS_REGION' < "$EKS_GENAI_DIR/litellm-deployment.yaml" | kubectl apply -f -

echo "Waiting for LiteLLM gateway to be ready..."
kubectl rollout status deployment/litellm-gateway --timeout=120s

# Deploy Open WebUI via Helm (no IP restriction — runs from VSCode IDE)
helm repo add open-webui https://helm.openwebui.com/ --force-update
helm repo update

helm upgrade --install open-webui open-webui/open-webui \
  -n default \
  -f "$EKS_GENAI_DIR/open-webui-helm/values.yaml" \
  --wait --timeout 5m

echo "Waiting for vLLM pod to start (this takes ~7 minutes)..."
echo "You can monitor with: kubectl get pod -w"

# Show ingress URL
sleep 30
kubectl get ing

echo ""
echo "============================================================"
echo "  Module 3: Observability Stack (Prometheus + Grafana)"
echo "============================================================"

# --- Install Kube Prometheus Stack ---
SECRET_NAME=$(aws secretsmanager list-secrets --query 'SecretList[?contains(Name, `oss-grafana`)].Name' --output text)
GRAFANA_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id $SECRET_NAME \
    --query 'SecretString' \
    --output text)

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update

cd "$OBSERVABILITY_DIR"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace kube-system \
    --version 75.13.0 \
    -f kube-prom-stack.yaml \
    --set grafana.adminPassword=$GRAFANA_PASSWORD \
    --set grafana.service.type=LoadBalancer \
    --set grafana.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
    --set prometheus.service.type=LoadBalancer \
    --set prometheus.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing

# --- Deploy vLLM + Neuron monitoring ---
kubectl apply -f vllm-servicemonitor.yaml
kubectl apply -f neuron-monitor.yaml
kubectl apply -f neuron-servicemonitor.yaml
kubectl apply -f vllm-neuron-dashboard-configmap.yaml

# --- Show Grafana URL ---
echo "Waiting for Grafana LB..."
sleep 60
GRAFANA_URL=$(kubectl get svc -n kube-system kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo ""
echo "============================================================"
echo "  Setup Complete!"
echo "============================================================"
echo ""
echo "Open WebUI URL:"
kubectl get ing -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
echo ""
echo ""
echo "Grafana URL: http://$GRAFANA_URL"
echo "Grafana Username: admin"
echo "Grafana Password: $GRAFANA_PASSWORD"
echo ""
echo "vLLM pod status:"
kubectl get pod -l app=vllm-mistral-inf2-server
echo ""
