---
title : "Simulate On-Premises Data Center"
weight : 710
hidden : true
---

## Overview

In this section you will simulate an on-premises data center by creating isolated data volumes on a secondary FSx for NetApp ONTAP file system. In a real-world scenario, this would be your customer's on-premises NetApp ONTAP system holding petabytes of data across different business domains.

For this workshop, we will:
- Create three separate volumes representing different business domains (Finance, Healthcare, Retail)
- Populate them with dummy datasets
- Demonstrate that only specific volumes will be replicated to the cloud for model access

:::alert{header="Real-world context" type="info"}
In production, the "on-prem" system would be a physical NetApp ONTAP cluster in the customer's data center. The SnapMirror replication workflow is identical whether the source is on-premises ONTAP or an FSx for ONTAP file system in another region. We use a second FSx for ONTAP system here for workshop simplicity.
:::

---

##### Step 1: Set Environment Variables for the On-Prem Simulator

The workshop CloudFormation stack has provisioned a secondary FSx for ONTAP file system to act as our on-premises simulator. Let's retrieve its details.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the secondary "on-prem" FSx ONTAP file system details
export ONPREM_FS_ID=$(aws fsx describe-file-systems --region $AWS_REGION \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='onprem-simulator']].FileSystemId" \
  --output text)

export ONPREM_MGMT_IP=$(aws fsx describe-file-systems --region $AWS_REGION \
  --file-system-ids $ONPREM_FS_ID \
  --query "FileSystems[0].OntapConfiguration.Endpoints.Management.IpAddresses[0]" \
  --output text)

export ONPREM_INTERCLUSTER_IP=$(aws fsx describe-file-systems --region $AWS_REGION \
  --file-system-ids $ONPREM_FS_ID \
  --query "FileSystems[0].OntapConfiguration.Endpoints.Intercluster.IpAddresses[0]" \
  --output text)

echo "On-Prem FS ID: $ONPREM_FS_ID"
echo "On-Prem Management IP: $ONPREM_MGMT_IP"
echo "On-Prem Intercluster IP: $ONPREM_INTERCLUSTER_IP"
:::

You should see output similar to:

:::code{showCopyAction=false showLineNumbers=false language=bash}
On-Prem FS ID: fs-0abc123def456789
On-Prem Management IP: 198.19.255.x
On-Prem Intercluster IP: 198.19.255.x
:::

##### Step 2: Retrieve On-Prem SVM Credentials

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the on-prem SVM password from Secrets Manager
export ONPREM_SVM_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "fsxn-onprem-svm-credentials" \
  --query 'SecretString' --output text | jq -r '.password')

export ONPREM_SVM_NAME="onprem-svm"
echo "On-Prem SVM: $ONPREM_SVM_NAME"
:::

##### Step 3: Create Business Domain Volumes on the On-Prem Simulator

We will now create three volumes representing different business domain datasets. In the real world, these would already exist on your on-premises ONTAP system containing petabytes of data.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create Finance data volume (50GB)
aws fsx create-volume \
  --volume-type ONTAP \
  --name finance_data \
  --ontap-configuration '{
    "JunctionPath": "/finance_data",
    "SizeInMegabytes": 51200,
    "StorageVirtualMachineId": "'$(aws fsx describe-storage-virtual-machines \
      --filters Name=file-system-id,Values=$ONPREM_FS_ID \
      --query "StorageVirtualMachines[0].StorageVirtualMachineId" --output text)'",
    "StorageEfficiencyEnabled": true,
    "TieringPolicy": {"CoolingPeriod": 31, "Name": "AUTO"},
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create Healthcare data volume (50GB)
aws fsx create-volume \
  --volume-type ONTAP \
  --name health_data \
  --ontap-configuration '{
    "JunctionPath": "/health_data",
    "SizeInMegabytes": 51200,
    "StorageVirtualMachineId": "'$(aws fsx describe-storage-virtual-machines \
      --filters Name=file-system-id,Values=$ONPREM_FS_ID \
      --query "StorageVirtualMachines[0].StorageVirtualMachineId" --output text)'",
    "StorageEfficiencyEnabled": true,
    "TieringPolicy": {"CoolingPeriod": 31, "Name": "AUTO"},
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create Retail data volume (50GB) - this one will NOT be replicated
aws fsx create-volume \
  --volume-type ONTAP \
  --name retail_data \
  --ontap-configuration '{
    "JunctionPath": "/retail_data",
    "SizeInMegabytes": 51200,
    "StorageVirtualMachineId": "'$(aws fsx describe-storage-virtual-machines \
      --filters Name=file-system-id,Values=$ONPREM_FS_ID \
      --query "StorageVirtualMachines[0].StorageVirtualMachineId" --output text)'",
    "StorageEfficiencyEnabled": true,
    "TieringPolicy": {"CoolingPeriod": 31, "Name": "AUTO"},
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION
:::

Wait for the volumes to become available:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "Waiting for volumes to become available..."
sleep 60

aws fsx describe-volumes --region $AWS_REGION \
  --filters Name=file-system-id,Values=$ONPREM_FS_ID \
  --query "Volumes[].{Name:Name, Status:Lifecycle, Size:OntapConfiguration.SizeInMegabytes}" \
  --output table
:::

You should see all three volumes in `AVAILABLE` status:

:::code{showCopyAction=false showLineNumbers=false language=bash}
-----------------------------------------
|            DescribeVolumes            |
+---------------+--------+-------------+
|     Name      | Size   |   Status    |
+---------------+--------+-------------+
|  finance_data |  51200 |  AVAILABLE  |
|  health_data  |  51200 |  AVAILABLE  |
|  retail_data  |  51200 |  AVAILABLE  |
+---------------+--------+-------------+
:::

##### Step 4: Populate Volumes with Dummy Domain Data

Now we'll populate each volume with sample data representing different business domains. We'll use a Kubernetes Job that mounts the on-prem volumes and writes dummy datasets.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/data-segregation
kubectl apply -f populate-onprem-data-job.yaml
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Wait for data population to complete
kubectl wait --for=condition=complete job/populate-onprem-data --timeout=300s
:::

Verify the data was created:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl logs job/populate-onprem-data
:::

You should see output confirming the creation of dummy datasets:

:::code{showCopyAction=false showLineNumbers=false language=bash}
Creating finance domain data...
  - Created: /finance_data/transactions/2024_q1.csv (synthetic transaction records)
  - Created: /finance_data/risk_models/parameters.json (model parameters)
  - Created: /finance_data/compliance/audit_trail.log (compliance data)
Creating healthcare domain data...
  - Created: /health_data/patient_records/anonymized_dataset.parquet (anonymized records)
  - Created: /health_data/imaging/metadata_index.json (imaging metadata)
  - Created: /health_data/research/clinical_trials.csv (trial data)
Creating retail domain data...
  - Created: /retail_data/inventory/catalog.json (product catalog)
  - Created: /retail_data/customer_segments/profiles.parquet (customer segments)
  - Created: /retail_data/recommendations/model_features.csv (recommendation features)
Data population complete. Total: 9 datasets across 3 domains.
:::

:::alert{header="Important" type="warning"}
In a real-world scenario, these volumes would contain terabytes or petabytes of actual business data accumulated over years. The dummy data here represents the **structure** and **separation** you would see in production. The key takeaway is that each volume is a self-contained data domain with its own access controls.
:::

---

### Summary

You have successfully simulated an on-premises data environment with three isolated business domain volumes. In the next section, you will use SnapMirror to selectively replicate only the Finance and Healthcare volumes to the cloud — the Retail data will intentionally remain "on-prem" to demonstrate selective data movement.

