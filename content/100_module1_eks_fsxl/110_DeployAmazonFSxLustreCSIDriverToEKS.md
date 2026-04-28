---
title : "Deploy Trident CSI Driver for Amazon FSx for NetApp ONTAP"
weight : 110
---

## Overview

Imagine the scenario where you need to host many AI models, or vast amounts of training data-sets, which will be accessed by hundreds of Pods in your workload. You can store this data on a single Persistent Volume (PV) backed by Amazon FSx for NetApp ONTAP. FSx for ONTAP provides fully managed shared storage built on the NetApp ONTAP file system, offering NFS access, snapshots, cloning, and automatic data tiering between SSD and capacity pool storage. The NetApp Astra Trident CSI driver integrates FSx for ONTAP with Kubernetes, enabling dynamic volume provisioning so your Pods can mount high-performance shared storage without manual PV creation.

In this section, the following steps will guide you to create an IAM policy with the required FSx for ONTAP and Secrets Manager permissions, create a service account, deploy the Trident CSI driver using Helm, and configure a Trident backend that connects to your pre-provisioned FSx for ONTAP file system and SVM.

:::alert{header="Note" type="info"}
For an AWS Sponsored Workshop, the FSx for ONTAP file system, SVM, and Security Group have been pre-created for you.
:::

For more information about networking requirements for FSx for ONTAP, please refer to the [official documentation](https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/limit-access-security-groups.html).



##### Step 1: Create an IAM policy that allows the Trident CSI driver to make AWS API calls on your behalf

1. Copy and run the below command to create the trident-csi-driver.json file.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
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
:::

##### Step 2: Create the IAM policy

2. Copy and run the following command to create the IAM policy.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
aws iam create-policy \
        --policy-name Amazon_FSx_ONTAP_Trident_CSI_Driver \
        --policy-document file://trident-csi-driver.json
:::

##### Step 3: Create a Kubernetes service account for the Trident driver and attach the policy

3. Copy and run the below command to create the service account and attach the IAM policy created in Step 2.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
eksctl create iamserviceaccount \
    --region $AWS_REGION \
    --cluster=$CLUSTER_NAME \
    --namespace trident \
    --name=trident-controller \
    --attach-policy-arn arn:aws:iam::$AWS_ACCOUNTID:policy/Amazon_FSx_ONTAP_Trident_CSI_Driver \
    --role-name=trident-controller \
    --role-only \
    --approve
:::

::alert[ You need to wait for approx. 60 seconds for the above command to complete]

##### Step 4: Save the Role ARN that was created into a variable

4. Copy and run the below command, which will save the role ARN into the ROLE_ARN variable.

::code[export ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-trident-trident-controller" --query "Stacks[0].Outputs[0].OutputValue" --region $AWS_REGION --output text)]{language=bash showLineNumbers=false showCopyAction=true}

5. Copy the output of this ROLE_ARN into the notepad file you are using for the workshop.
::code[echo $ROLE_ARN]{language=bash showLineNumbers=false showCopyAction=true}


##### Step 5: Deploy the Trident CSI driver for FSx for NetApp ONTAP

6. Copy and run the following commands to deploy the Trident CSI driver.

**Add the NetApp Trident Helm repository**
:::code[]{language=bash showLineNumbers=true showCopyAction=true}
helm repo add netapp-trident https://netapp.github.io/trident-helm-chart
helm repo update
:::

**Install the Trident operator**
:::code[]{language=bash showLineNumbers=true showCopyAction=true}
helm upgrade --install trident-operator netapp-trident/trident-operator \
    --version 100.2602.0 \
    --set cloudProvider="AWS" \
    --set cloudIdentity="'eks.amazonaws.com/role-arn: ${ROLE_ARN}'" \
    --namespace trident \
    --create-namespace
:::

Verify that the Trident CSI driver has been installed successfully with the following command.

::code[kubectl get pods -n trident]{language=bash showLineNumbers=false showCopyAction=true}


::::expand{header="You should see the results as below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME                                  READY   STATUS    RESTARTS   AGE
trident-controller-68f86749df-k5g2j   6/6     Running   0          45s
trident-node-linux-abcde              2/2     Running   0          45s
trident-operator-7c94b5f9cf-x9z2k    1/1     Running   0          50s
:::

::::

##### Step 6: Create the Trident backend configuration for FSx for ONTAP

Now that the Trident CSI driver is running, you need to configure it to connect to your pre-provisioned FSx for ONTAP file system and SVM. This is done by creating a Kubernetes Secret with the SVM credentials and a TridentBackendConfig resource.

7. First, retrieve the SVM password from AWS Secrets Manager. The secret was created by Terraform with a name starting with `trident-fsx-ontap-svm-`.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'trident-fsx-ontap-svm-')].Name" --output text --region $AWS_REGION)
SVM_PASSWORD=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query "SecretString" --output text --region $AWS_REGION)
echo "SVM Password retrieved from secret: $SECRET_NAME"
:::

8. Replace the `SVM_PASSWORD` placeholder in the Secret manifest with the actual password.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/FSxONTAP
sed -i'' -e "s/SVM_PASSWORD/$SVM_PASSWORD/g" fsx-ontap-secret.yaml
:::

9. Apply the Secret containing the SVM `vsadmin` credentials.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl apply -f fsx-ontap-secret.yaml
:::

10. Next, retrieve the SVM management LIF and SVM name from your FSx for ONTAP file system, and update the TridentBackendConfig manifest.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text --region $AWS_REGION)
SVM_MGMT_LIF=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].Endpoints.Management.DNSName" --output text --region $AWS_REGION)
SVM_NAME=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].Name" --output text --region $AWS_REGION)
echo "SVM Management LIF: $SVM_MGMT_LIF"
echo "SVM Name: $SVM_NAME"
:::

11. Replace the placeholders in the TridentBackendConfig manifest and apply it.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
sed -i'' -e "s/SVM_MGMT_LIF/$SVM_MGMT_LIF/g" trident-backend-config.yaml
sed -i'' -e "s/SVM_NAME/$SVM_NAME/g" trident-backend-config.yaml
kubectl apply -f trident-backend-config.yaml
:::

12. Verify that the Trident backend has been registered successfully.

::code[kubectl get tridentbackendconfig -n trident]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see the results as below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME               BACKEND NAME   BACKEND UUID                           PHASE   STATUS
backend-ontap-nas  fsx-ontap-nas  6ca7c511-649b-4be4-a1eb-c8cdc5496ea9   Bound   Success
:::

::::

You can also verify the backend details with:

::code[kubectl describe tridentbackendconfig backend-ontap-nas -n trident]{language=bash showLineNumbers=false showCopyAction=true}

## Summary

In this section you have created an IAM policy with FSx for ONTAP and Secrets Manager permissions, created a service account for the Trident CSI driver, deployed the Trident CSI driver using Helm, and configured a Trident backend that connects to your FSx for ONTAP file system and SVM. In the next section you will create the StorageClass and PersistentVolumeClaim for dynamic volume provisioning, so your Pods can use FSx for ONTAP as persistent storage.
