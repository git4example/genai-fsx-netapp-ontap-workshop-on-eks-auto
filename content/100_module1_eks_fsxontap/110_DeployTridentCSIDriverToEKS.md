---
title : "Configure FSx for NetApp storage on EKS"
weight : 110
---

## Overview

Imagine the scenario:
- You need to host many AI models, or vast amounts of training data-sets, which will be accessed by hundreds of Pods in your workload.
- You can store this data in a operationally efficient and performant way on a single high-performant Persistent Volume (PV) backed by Amazon FSx for NetApp ONTAP, instead of each Pod using its own small local instance-based storage.
- FSx for ONTAP provides fully managed shared storage built on the NetApp ONTAP file system, offering NFS access, snapshots, cloning, and automatic data tiering between SSD and capacity pool storage.
- The NetApp Astra Trident CSI driver integrates FSx for ONTAP with Kubernetes, enabling dynamic volume provisioning so your Pods can mount high-performance shared storage without manual PV creation.

In this module you will:
- Deploy the **NetApp Astra Trident CSI driver** within your Amazon EKS cluster
- Configure a **TridentBackendConfig** that connects Trident to the pre-provisioned FSx for NetApp volume (using Kubernetes static-provisioing),
- Create a **StorageClass**, and **import** the two existing ONTAP volumes as PersistentVolumeClaims.
- You will learn about Kubernetes storage concepts such as CSI drivers, StorageClasses, PersistentVolumeClaims.
- The infrastructure for this module comprises an Amazon EKS cluster with EC2 worker nodes, and an Amazon FSx for NetApp ONTAP file system.


:::alert{header="Note" type="info"}
For an AWS Sponsored Workshop, the FSx for ONTAP file system, SVM, and Security Group have been pre-created for you.
:::

For more information about networking requirements for FSx for ONTAP, please refer to the [official documentation](https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/limit-access-security-groups.html).



##### Step 1: Create an IAM policy that allows the Trident CSI driver to make AWS API calls on your behalf

1. Copy and run the below command in your **VSCode IDE** to create the trident-csi-driver.json file.

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
    --version 100.2606.0 \
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
export SVM_PASSWORD
echo "SVM Password retrieved from secret: $SECRET_NAME"
:::

8. Apply the Secret containing the SVM `vsadmin` credentials, substituting the `$SVM_PASSWORD` placeholder with the actual password retrieved above.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/FSxONTAP
envsubst '$SVM_PASSWORD' < fsx-ontap-secret.yaml | kubectl apply -f -
:::

9. Next, retrieve the SVM management LIF and SVM name from your FSx for ONTAP file system.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text --region $AWS_REGION)
SVM_MGMT_LIF=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].Endpoints.Management.DNSName" --output text --region $AWS_REGION)
SVM_NAME=$(aws fsx describe-storage-virtual-machines --filters "Name=file-system-id,Values=$FSX_ID" --query "StorageVirtualMachines[0].Name" --output text --region $AWS_REGION)
export SVM_MGMT_LIF SVM_NAME
echo "SVM Management LIF: $SVM_MGMT_LIF"
echo "SVM Name: $SVM_NAME"
:::

10. Apply the TridentBackendConfig, substituting the `$SVM_MGMT_LIF` and `$SVM_NAME` placeholders with the values retrieved above.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
envsubst '$SVM_MGMT_LIF $SVM_NAME' < trident-backend-config.yaml | kubectl apply -f -
:::

11. Verify that the Trident backend has been registered successfully.

::code[kubectl get tridentbackendconfig -n trident]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see the results as below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME               BACKEND NAME   BACKEND UUID                           PHASE   STATUS
backend-ontap-nas  fsx-ontap-nas  6ca7c511-649b-4be4-a1eb-c8cdc5496ea9   Bound   Success
:::

::::

You can also verify the backend details with:

::code[kubectl describe tridentbackendconfig backend-ontap-nas -n trident]{language=bash showLineNumbers=false showCopyAction=true}

:::alert{header="What to look for" type="info"}
In the output of the `describe` command, verify the following key fields:
- **Phase: Bound**: confirms the backend is connected to the FSx for ONTAP file system
- **Status: Success**: confirms the backend is healthy and ready to provision volumes
- **Backend Name: fsx-ontap-nas**: the logical name for this backend
- **Management LIF**: should match your SVM's management DNS name
- **SVM**: should match your SVM name

If the Phase shows anything other than `Bound` or the Status is not `Success`, check the Trident controller logs with `kubectl logs -n trident -l app=controller.csi.trident.netapp.io`.
:::

##### Step 7: Create the StorageClass

A `StorageClass` tells Kubernetes which provisioner to use for a PersistentVolumeClaim. This one points at the Trident CSI driver and the ONTAP backend you just registered.

12. The StorageClass needs the list of Availability Zones in your region, so collect them first. This workshop can be deployed to several regions, so the list is read from the region you are actually running in rather than hard-coded:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
export AZ_LIST_JSON=$(aws ec2 describe-availability-zones --region $AWS_REGION \
  --query "AvailabilityZones[?State=='available'].ZoneName" --output json | tr -d ' \n')
echo "AZ_LIST_JSON: $AZ_LIST_JSON"
:::

You should see a compact list of the zones in your region, for example `["us-west-2a","us-west-2b","us-west-2c","us-west-2d"]`.

13. Apply the StorageClass, substituting that list:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
envsubst '$AZ_LIST_JSON' < ontap-storage-class.yaml | kubectl apply -f -
kubectl get storageclass ontap-nas-sc
:::

::::expand{header="Why this StorageClass lists availability zones (click to expand)"}

FSx for ONTAP Multi-AZ presents a single **floating** NFS endpoint that is reachable from every Availability Zone, so Trident correctly advertises no zone topology of its own. With `volumeBindingMode: Immediate`, the CSI provisioner still wants an explicit zone list, and without one it fails with:

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
error generating accessibility requirements: no available topology found
:::

The `allowedTopologies` block supplies the region's zones so the provisioner has something to resolve. `Immediate` is deliberate, because `WaitForFirstConsumer` would leave a PVC that has no pod yet `Pending` forever, which matters because the volumes below are imported before any pod mounts them.

The zones have to match the region you are deployed in. A StorageClass listing zones from some other region gives the provisioner topology it can never satisfy, and every PVC against it stays `Pending`. That is why the manifest ships with an `${AZ_LIST_JSON}` placeholder instead of a fixed list.

::::

##### Step 8: Import the pre-provisioned ONTAP volumes

Rather than creating new storage, you will **import** the two ONTAP volumes that already exist: `model` (holding the Mistral-7B model) and `agent_shared_data` (holding the AI agent datasets). Trident builds a PersistentVolume around an existing volume instead of allocating new capacity.

14. Trident identifies the backend by **UUID**, which is generated when the backend registers. Retrieve it:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
export BACKEND_UUID=$(kubectl get tbe -n trident \
  -o jsonpath='{.items[?(@.backendName=="fsx-ontap-nas")].backendUUID}')
echo "BACKEND_UUID: $BACKEND_UUID"
:::

15. Apply both import PVCs, substituting the UUID:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl create namespace agents 2>/dev/null || true
envsubst '$BACKEND_UUID' < ontap-pvc.yaml | kubectl apply -f -
envsubst '$BACKEND_UUID' < ../agentic-agents/agent-shared-pvc.yaml | kubectl apply -f -
:::

::::expand{header="Optional: click to view the import annotations"}

:::code[]{language=yaml showLineNumbers=false showCopyAction=false}
annotations:
  trident.netapp.io/importOriginalName: "model"      # existing ONTAP volume name
  trident.netapp.io/importBackendUUID: "<uuid>"      # backend UUID, not its name
  trident.netapp.io/importNoRename: "true"           # keep the name "model"
:::

Without `importNoRename`, a managed import renames the ONTAP volume to `trident_pvc_<uuid>`, discarding the meaningful name the storage team gave it.

::::

16. Confirm both PVCs are **Bound**:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl get pvc ontap-model-claim
kubectl get pvc -n agents agent-shared-data
:::

17. Verify the volumes were genuinely **imported** rather than newly created:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl get pv -o custom-columns='PV:.metadata.name,CLAIM:.spec.claimRef.name,ONTAP_VOLUME:.spec.csi.volumeAttributes.internalName'
:::

:::alert{header="This check matters" type="warning"}
`ONTAP_VOLUME` must read **`model`** and **`agent_shared_data`**. If it shows `trident_pvc_<uuid>`, Trident ignored the import annotations and provisioned brand-new empty volumes instead, so the model data would be missing and vLLM would fail to start. Trident does not warn when it ignores an unrecognised annotation, so this is the only reliable way to confirm an import succeeded.
:::

## Summary

In this section you created an IAM policy with FSx for ONTAP and Secrets Manager permissions, created a service account for the Trident CSI driver, deployed the driver using Helm, configured a Trident backend connected to your FSx for ONTAP file system and SVM, created a StorageClass, and imported the two pre-provisioned ONTAP volumes as PersistentVolumeClaims. Your pods can now mount FSx for ONTAP as persistent storage. If you would also like to watch Trident **dynamically provision** a brand-new volume, work through the optional Dynamic Provisioning module later.
