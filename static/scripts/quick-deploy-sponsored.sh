#!/bin/bash
# =============================================================================
# Workshop quick-deploy-sponsored.sh — All participant commands in execution order
#
# This script mirrors the workshop instructions from Modules 1–3.
# It can be used as a quick rundown to configure everything and test
# the workshop command execution end-to-end.
#
# Prerequisites:
#   - VSCode IDE instance with AWS credentials configured
#   - Environment variables: AWS_REGION, AWS_ACCOUNTID
#   - EKS cluster "eksworkshop" already provisioned via Terraform
#   - FSx for ONTAP file system, SVM, and volume already provisioned
# =============================================================================

set -euo pipefail

echo "============================================================"
echo "  Workshop Quick Setup Script"
echo "============================================================"

# --- Initial setup ---
aws sts get-caller-identity

export CLUSTER_NAME=eksworkshop
echo "AWS_REGION: $AWS_REGION"
echo "AWS_ACCOUNTID: $AWS_ACCOUNTID"
echo "CLUSTER_NAME: $CLUSTER_NAME"
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

# --- Step 2: Create the IAM policy ---
aws iam create-policy \
        --policy-name Amazon_FSx_ONTAP_Trident_CSI_Driver \
        --policy-document file://trident-csi-driver.json

# --- Step 3: Create service account for Trident ---
eksctl create iamserviceaccount \
    --region $AWS_REGION \
    --cluster=$CLUSTER_NAME \
    --namespace trident \
    --name=trident-controller \
    --attach-policy-arn arn:aws:iam::$AWS_ACCOUNTID:policy/Amazon_FSx_ONTAP_Trident_CSI_Driver \
    --role-name=trident-controller \
    --role-only \
    --approve

# --- Step 4: Save the Role ARN ---
export ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-trident-trident-controller" --query "Stacks[0].Outputs[0].OutputValue" --region $AWS_REGION --output text)
echo "ROLE_ARN: $ROLE_ARN"

# --- Step 5: Deploy Trident CSI driver via Helm ---
helm repo add netapp-trident https://netapp.github.io/trident-helm-chart
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

# --- Step 6: Configure Trident backend for FSx ONTAP ---
cd /home/participant/environment/eks/FSxONTAP

# Step 6.7: Retrieve SVM password from Secrets Manager
SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'trident-fsx-ontap-svm-')].Name" --output text --region $AWS_REGION)
SVM_PASSWORD=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query "SecretString" --output text --region $AWS_REGION)
echo "SVM Password retrieved from secret: $SECRET_NAME"

# Step 6.8: Update secret manifest
sed -i'' -e "s/SVM_PASSWORD/$SVM_PASSWORD/g" fsx-ontap-secret.yaml

# Step 6.9: Apply the secret
kubectl apply -f fsx-ontap-secret.yaml

# Step 6.10: Retrieve SVM management LIF and name
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text --region $AWS_REGION)
SVM_MGMT_LIF=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].Endpoints.Management.DNSName" --output text --region $AWS_REGION)
SVM_NAME=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].Name" --output text --region $AWS_REGION)
echo "SVM Management LIF: $SVM_MGMT_LIF"
echo "SVM Name: $SVM_NAME"

# Step 6.11: Update and apply TridentBackendConfig
sed -i'' -e "s/SVM_MGMT_LIF/$SVM_MGMT_LIF/g" trident-backend-config.yaml
sed -i'' -e "s/SVM_NAME/$SVM_NAME/g" trident-backend-config.yaml
kubectl apply -f trident-backend-config.yaml

# Step 6.12: Verify backend
echo "Waiting for Trident backend to register..."
sleep 15
kubectl get tridentbackendconfig -n trident

echo ""
echo "============================================================"
echo "  Module 1: Create StorageClass and PVC (Dynamic Provisioning)"
echo "============================================================"

cd /home/participant/environment/eks/FSxONTAP

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
cd /home/participant/environment/terraform

helm upgrade --install neuron-helm-chart \
    oci://public.ecr.aws/neuron/neuron-helm-chart \
    --namespace kube-system \
    --version 1.5.0 \
    -f ./helm-values/neuron-values.yaml

# --- Step 2: Create Inferentia NodePool ---
NODE_ROLE=$(cd /home/participant/environment/terraform && terraform output --raw eks_node_iam_role_name)
cd /home/participant/environment/eks/genai
sed -i'' -e "s/NODE_ROLE/$NODE_ROLE/g" inferentia_nodepool.yaml

kubectl apply -f inferentia_nodepool.yaml
kubectl get nodepool,nodeclass inferentia

# --- Step 3: Load Mistral-7B model onto FSx ONTAP volume ---
cd /home/participant/environment/eks/FSxONTAP
kubectl apply -f model-loading-job.yaml

echo "Waiting for model-download Job to complete (timeout: 1800s)..."
echo "Tip: In another terminal, run: kubectl logs -f job/model-download"
kubectl wait --for=condition=complete job/model-download --timeout=1800s

# --- Step 4: Deploy vLLM ---
cd /home/participant/environment/eks/genai

FSX_ONTAP_AZ=$(aws fsx describe-file-systems --region $AWS_REGION --query "FileSystems[?FileSystemType=='ONTAP'].SubnetIds[0]" --output text | head -1 | xargs -I {} aws ec2 describe-subnets --subnet-ids {} --query 'Subnets[0].AvailabilityZone' --output text)
echo "FSX_ONTAP_AZ: $FSX_ONTAP_AZ"

sed -i'' -e "s/FSX_ONTAP_AZ/$FSX_ONTAP_AZ/g" mistral-ontap.yaml
kubectl apply -f mistral-ontap.yaml

# Deploy Open WebUI
kubectl apply -f open-webui.yaml

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

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

cd /home/participant/environment/eks/genai/observability/

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
