#!/bin/bash

aws sts get-caller-identity

export CLUSTER_NAME=eksworkshop
echo $AWS_REGION
echo $CLUSTER_NAME
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# --- Trident CSI IAM Policy ---
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

aws iam create-policy \
        --policy-name Trident_CSI_Driver \
        --policy-document file://trident-csi-driver.json

eksctl create iamserviceaccount \
    --region $AWS_REGION \
    --cluster=$CLUSTER_NAME \
    --namespace trident \
    --name=trident-csi-controller-sa \
    --attach-policy-arn arn:aws:iam::$AWS_ACCOUNTID:policy/Trident_CSI_Driver \
    --role-name=trident-csi-controller-sa \
    --role-only \
    --approve

export ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-trident-trident-csi-controller-sa" --query "Stacks[0].Outputs[0].OutputValue" --region $AWS_REGION --output text)
echo $ROLE_ARN

# --- Install Trident Operator via Helm ---
helm repo add netapp-trident https://netapp.github.io/trident-helm-chart
helm repo update

helm install trident-operator netapp-trident/trident-operator \
    --version 100.2502.1 \
    --set cloudProvider="AWS" \
    --set cloudIdentity="'eks.amazonaws.com/role-arn: ${ROLE_ARN}'" \
    --namespace trident \
    --create-namespace

kubectl get pods -n trident

# --- Discover FSx for ONTAP file system ---
cd /home/participant/environment/eks/FSxONTAP

ONTAP_FS=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].[FileSystemId,Lifecycle,OntapConfiguration.Endpoints.Management.DNSName]" --output json)
ONTAP_COUNT=$(echo $ONTAP_FS | jq length)

if [ "$ONTAP_COUNT" -eq 0 ]; then
    echo "ERROR: No FSx for ONTAP file systems found in this region."
    exit 1
fi

# Use the first ONTAP file system
FSX_ID=$(echo $ONTAP_FS | jq -r '.[0][0]')
FSX_STATUS=$(echo $ONTAP_FS | jq -r '.[0][1]')

echo "FSx ONTAP File System ID: $FSX_ID"
echo "FSx ONTAP Status: $FSX_STATUS"

if [ "$FSX_STATUS" != "AVAILABLE" ]; then
    echo "ERROR: FSx for ONTAP file system $FSX_ID is not AVAILABLE (current status: $FSX_STATUS). Please wait and try again."
    exit 1
fi

# Get the AZ for the ONTAP file system
FSX_ONTAP_AZ=$(aws fsx describe-file-systems --file-system-ids $FSX_ID --query "FileSystems[0].SubnetIds[0]" --output text)
FSX_ONTAP_AZ=$(aws ec2 describe-subnets --subnet-ids $FSX_ONTAP_AZ --query "Subnets[0].AvailabilityZone" --output text)
echo "FSx ONTAP AZ: $FSX_ONTAP_AZ"

# Get SVM details
SVM_INFO=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].[Endpoints.Management.DNSName,Name]" --output json)
SVM_MGMT_LIF=$(echo $SVM_INFO | jq -r '.[0]')
SVM_NAME=$(echo $SVM_INFO | jq -r '.[1]')

echo "SVM Management LIF: $SVM_MGMT_LIF"
echo "SVM Name: $SVM_NAME"

# Get SVM password from Secrets Manager (Terraform creates with prefix trident-fsx-ontap-svm-)
SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'trident-fsx-ontap-svm-')].Name" --output text 2>/dev/null)
if [ -z "$SECRET_NAME" ]; then
    echo "WARNING: Could not find SVM password secret (trident-fsx-ontap-svm-*). Using placeholder."
    SVM_PASSWORD="SVM_PASSWORD"
else
    SVM_PASSWORD=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query "SecretString" --output text 2>/dev/null)
    echo "SVM Password retrieved from secret: $SECRET_NAME"
fi

# --- Populate ONTAP templates ---
sed -i'' -e "s/SVM_MGMT_LIF/$SVM_MGMT_LIF/g" trident-backend-config.yaml
sed -i'' -e "s/SVM_NAME/$SVM_NAME/g" trident-backend-config.yaml
sed -i'' -e "s/SVM_PASSWORD/$SVM_PASSWORD/g" fsx-ontap-secret.yaml

echo "--- TridentBackendConfig ---"
cat trident-backend-config.yaml
echo "--- Secret ---"
cat fsx-ontap-secret.yaml

# --- Apply ONTAP Kubernetes resources in order ---
kubectl apply -f fsx-ontap-secret.yaml
kubectl apply -f trident-backend-config.yaml
kubectl apply -f ontap-storage-class.yaml
kubectl apply -f ontap-pvc.yaml
kubectl apply -f model-loading-job.yaml

echo "Waiting for model-download Job to complete (timeout: 1800s)..."
kubectl wait --for=condition=complete job/model-download --timeout=1800s

# --- Deploy GenAI workloads ---
cd /home/participant/environment/eks/genai
kubectl apply -f inferentia_nodepool.yaml
kubectl get nodepool,ec2nodeclass inferentia

helm upgrade --install neuron-helm-chart \
    oci://public.ecr.aws/neuron/neuron-helm-chart \
    --namespace kube-system \
    --version 1.2.0 \
    -f ./helm-values/neuron-values.yaml

# Update AZ in mistral-ontap.yaml and deploy vLLM
sed -i'' -e "s/FSX_ONTAP_AZ/$FSX_ONTAP_AZ/g" mistral-ontap.yaml
kubectl apply -f mistral-ontap.yaml

kubectl apply -f open-webui.yaml

kubectl get ing
