---
title : "Selective Data Replication with SnapMirror"
weight : 720
hidden : true
---

## Overview

In this section you will establish **SnapMirror replication** between the on-prem simulator and your cloud FSx for ONTAP file system. The critical point: you will replicate **only** the Finance and Healthcare volumes — the Retail volume stays on-prem, demonstrating that you control exactly which data subsets move to the cloud.

This is how enterprises manage petabyte-scale data: instead of moving everything, you selectively replicate only what each cloud-deployed model needs.

---

##### Step 1: Establish Cluster Peering Between File Systems

SnapMirror requires a trust relationship (cluster peering) between the source and destination ONTAP systems.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the cloud (destination) FSx ONTAP intercluster IP
export CLOUD_FS_ID=$(aws fsx describe-file-systems --region $AWS_REGION \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='genaifsxnworkshop']].FileSystemId" \
  --output text)

export CLOUD_INTERCLUSTER_IP=$(aws fsx describe-file-systems --region $AWS_REGION \
  --file-system-ids $CLOUD_FS_ID \
  --query "FileSystems[0].OntapConfiguration.Endpoints.Intercluster.IpAddresses[0]" \
  --output text)

echo "Cloud FS ID: $CLOUD_FS_ID"
echo "Cloud Intercluster IP: $CLOUD_INTERCLUSTER_IP"
echo "On-Prem Intercluster IP: $ONPREM_INTERCLUSTER_IP"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create cluster peer from on-prem to cloud
# Note: In production cross-region scenarios, you would use the intercluster LIFs
# For same-region simulation, the peering uses the intercluster endpoints directly

aws fsx create-data-repository-association --region $AWS_REGION 2>/dev/null || true

# Initiate cluster peering via ONTAP REST API on the on-prem system
# Generate a random passphrase for cluster peering
export PEER_PASSPHRASE=$(openssl rand -base64 16)

curl -sk -u "vsadmin:${ONPREM_SVM_PASS}" \
  -X POST "https://${ONPREM_MGMT_IP}/api/cluster/peers" \
  -H "Content-Type: application/json" \
  -d '{
    "remote": {
      "ip_addresses": ["'${CLOUD_INTERCLUSTER_IP}'"]
    },
    "authentication": {
      "passphrase": "'${PEER_PASSPHRASE}'"
    }
  }'
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Accept the peer on the cloud side
export CLOUD_MGMT_IP=$(aws fsx describe-file-systems --region $AWS_REGION \
  --file-system-ids $CLOUD_FS_ID \
  --query "FileSystems[0].OntapConfiguration.Endpoints.Management.IpAddresses[0]" \
  --output text)

export CLOUD_SVM_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "fsxn-svm-credentials" \
  --query 'SecretString' --output text | jq -r '.password')

curl -sk -u "vsadmin:${CLOUD_SVM_PASS}" \
  -X POST "https://${CLOUD_MGMT_IP}/api/cluster/peers" \
  -H "Content-Type: application/json" \
  -d '{
    "remote": {
      "ip_addresses": ["'${ONPREM_INTERCLUSTER_IP}'"]
    },
    "authentication": {
      "passphrase": "'${PEER_PASSPHRASE}'"
    }
  }'
:::

Verify the cluster peering is established:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -sk -u "vsadmin:${CLOUD_SVM_PASS}" \
  "https://${CLOUD_MGMT_IP}/api/cluster/peers" | jq '.records[] | {name, status: .status.state}'
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
{
  "name": "onprem-simulator",
  "status": "available"
}
:::

##### Step 2: Establish SVM Peering

After cluster peering, we need SVM-level peering to allow volume replication between the SVMs.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create SVM peer relationship
export CLOUD_SVM_NAME=$(aws fsx describe-storage-virtual-machines \
  --filters Name=file-system-id,Values=$CLOUD_FS_ID \
  --query "StorageVirtualMachines[0].Name" --output text)

curl -sk -u "vsadmin:${CLOUD_SVM_PASS}" \
  -X POST "https://${CLOUD_MGMT_IP}/api/svm/peers" \
  -H "Content-Type: application/json" \
  -d '{
    "svm": {"name": "'${CLOUD_SVM_NAME}'"},
    "peer": {
      "svm": {"name": "'${ONPREM_SVM_NAME}'"},
      "cluster": {"name": "onprem-simulator"}
    },
    "applications": ["snapmirror"]
  }'
:::

##### Step 3: Create Destination Volumes on Cloud FSx ONTAP

Before establishing SnapMirror relationships, we need to create the destination (data-protection) volumes on the cloud file system.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get cloud SVM ID
export CLOUD_SVM_ID=$(aws fsx describe-storage-virtual-machines \
  --filters Name=file-system-id,Values=$CLOUD_FS_ID \
  --query "StorageVirtualMachines[0].StorageVirtualMachineId" --output text)

# Create finance_data destination volume (DP type - read only)
aws fsx create-volume \
  --volume-type ONTAP \
  --name finance_data_dp \
  --ontap-configuration '{
    "JunctionPath": "/finance_data",
    "SizeInMegabytes": 51200,
    "StorageVirtualMachineId": "'$CLOUD_SVM_ID'",
    "StorageEfficiencyEnabled": true,
    "OntapVolumeType": "DP",
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create health_data destination volume (DP type - read only)
aws fsx create-volume \
  --volume-type ONTAP \
  --name health_data_dp \
  --ontap-configuration '{
    "JunctionPath": "/health_data",
    "SizeInMegabytes": 51200,
    "StorageVirtualMachineId": "'$CLOUD_SVM_ID'",
    "StorageEfficiencyEnabled": true,
    "OntapVolumeType": "DP",
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION
:::

:::alert{header="Notice: No retail_data volume" type="info"}
We are intentionally **NOT** creating a destination volume for `retail_data`. This data stays on-prem. Only the data subsets required by cloud-deployed models are replicated. In a petabyte-scale environment, this selective approach saves significant bandwidth and storage costs.
:::

Wait for destination volumes:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "Waiting for destination volumes..."
sleep 60

aws fsx describe-volumes --region $AWS_REGION \
  --filters Name=file-system-id,Values=$CLOUD_FS_ID \
  --query "Volumes[?Name=='finance_data_dp' || Name=='health_data_dp'].{Name:Name, Status:Lifecycle, Type:OntapConfiguration.OntapVolumeType}" \
  --output table
:::

##### Step 4: Establish SnapMirror Relationships

Now create the SnapMirror relationships to replicate data from on-prem to cloud.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create SnapMirror for finance_data
curl -sk -u "vsadmin:${CLOUD_SVM_PASS}" \
  -X POST "https://${CLOUD_MGMT_IP}/api/snapmirror/relationships" \
  -H "Content-Type: application/json" \
  -d '{
    "source": {
      "path": "'${ONPREM_SVM_NAME}':finance_data"
    },
    "destination": {
      "path": "'${CLOUD_SVM_NAME}':finance_data_dp"
    },
    "policy": {"name": "MirrorAllSnapshots"}
  }'

echo "SnapMirror created: finance_data -> finance_data_dp"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create SnapMirror for health_data
curl -sk -u "vsadmin:${CLOUD_SVM_PASS}" \
  -X POST "https://${CLOUD_MGMT_IP}/api/snapmirror/relationships" \
  -H "Content-Type: application/json" \
  -d '{
    "source": {
      "path": "'${ONPREM_SVM_NAME}':health_data"
    },
    "destination": {
      "path": "'${CLOUD_SVM_NAME}':health_data_dp"
    },
    "policy": {"name": "MirrorAllSnapshots"}
  }'

echo "SnapMirror created: health_data -> health_data_dp"
:::

##### Step 5: Initialize and Verify Replication

Trigger the initial baseline transfer:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Initialize the SnapMirror transfers
curl -sk -u "vsadmin:${CLOUD_SVM_PASS}" \
  "https://${CLOUD_MGMT_IP}/api/snapmirror/relationships" | \
  jq -r '.records[] | select(.destination.path | contains("finance_data_dp") or contains("health_data_dp")) | .uuid' | \
  while read uuid; do
    curl -sk -u "vsadmin:${CLOUD_SVM_PASS}" \
      -X PATCH "https://${CLOUD_MGMT_IP}/api/snapmirror/relationships/${uuid}" \
      -H "Content-Type: application/json" \
      -d '{"state": "snapmirrored"}'
    echo "Initialized transfer for relationship: $uuid"
  done
:::

Monitor the transfer progress:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Check SnapMirror status - wait until both show "snapmirrored"
echo "Waiting for initial replication to complete..."
sleep 30

curl -sk -u "vsadmin:${CLOUD_SVM_PASS}" \
  "https://${CLOUD_MGMT_IP}/api/snapmirror/relationships" | \
  jq '.records[] | {destination: .destination.path, state: .state, healthy: .healthy}'
:::

Expected output when replication is complete:

:::code{showCopyAction=false showLineNumbers=false language=bash}
{
  "destination": "cloud-svm:finance_data_dp",
  "state": "snapmirrored",
  "healthy": true
}
{
  "destination": "cloud-svm:health_data_dp",
  "state": "snapmirrored",
  "healthy": true
}
:::

:::alert{header="What just happened?" type="info"}
You have selectively replicated **only 2 out of 3** volumes from the on-prem simulator to the cloud. The `retail_data` volume remains exclusively on-prem. In a real petabyte-scale environment:
- **Finance data (200 TB)** → Replicated for the finance model
- **Healthcare data (150 TB)** → Replicated for the healthcare model  
- **Retail data (4.65 PB)** → Stays on-prem, not needed by cloud models

This selective approach saves ~93% in cross-region data transfer costs compared to replicating everything.
:::

---

### Summary

You have established SnapMirror replication between the on-prem simulator and your cloud FSx for ONTAP file system, selectively replicating only the data volumes required by your cloud-deployed models. In the next section, you will deploy two different AI models, each with access restricted to only its designated data volume.

