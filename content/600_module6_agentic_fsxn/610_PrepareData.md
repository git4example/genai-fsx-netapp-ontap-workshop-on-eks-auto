---
title : "Prepare Team Data on FSxN"
weight : 610
---

## Overview

In this section, you will create **two isolated data volumes** on your FSx for NetApp ONTAP file system — one for each team's AI agent. You'll populate them with sample documents that represent real enterprise data: financial reports for the Finance team, and operational runbooks/logs for the IT Operations team.

This simulates how enterprises store different business domains' data on separate ONTAP volumes, each with its own access controls — ensuring that an AI agent for one team cannot access another team's sensitive data.

---

##### Step 1: Set Environment Variables

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the primary FSx ONTAP file system ID (filter by ONTAP type)
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

# Retrieve SVM password from Secrets Manager (secret name starts with trident-fsx-ontap-svm-)
export FSXN_SECRET_NAME=$(aws secretsmanager list-secrets --region $AWS_REGION \
  --query "SecretList[?starts_with(Name,'trident-fsx-ontap-svm-')].Name" --output text)
export FSXN_SVM_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "$FSXN_SECRET_NAME" \
  --query 'SecretString' --output text --region $AWS_REGION)

echo "FSx ONTAP FS ID: $FSXN_FS_ID"
echo "Management IP: $FSXN_MGMT_IP"
echo "SVM: $FSXN_SVM_NAME ($FSXN_SVM_ID)"
echo "Secret: $FSXN_SECRET_NAME"
:::

##### Step 2: Create Isolated Data Volumes

Create two separate volumes — one for Finance data and one for IT Operations data. Each volume will have its own junction path (mount point within the SVM namespace).

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create Finance data volume (10GB)
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
  }' --region $AWS_REGION

echo "Created volume: finance_agent_data (/finance_data)"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create IT Operations data volume (10GB)
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
  }' --region $AWS_REGION

echo "Created volume: itops_agent_data (/it_ops_data)"
:::

Wait for volumes to become available:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "Waiting for volumes to become available..."
sleep 60

aws fsx describe-volumes --region $AWS_REGION \
  --filters Name=file-system-id,Values=$FSXN_FS_ID \
  --query "Volumes[?Name=='finance_agent_data' || Name=='itops_agent_data'].{Name:Name, Status:Lifecycle, JunctionPath:OntapConfiguration.JunctionPath}" \
  --output table
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
------------------------------------------------------
|                  DescribeVolumes                   |
+-------------+--------------+---------------------+
| JunctionPath|    Name      |      Status         |
+-------------+--------------+---------------------+
| /finance_data| finance_agent_data |  AVAILABLE   |
| /it_ops_data | itops_agent_data   |  AVAILABLE   |
+-------------+--------------+---------------------+
:::

##### Step 3: Populate Volumes with Sample Data

Deploy a Kubernetes Job that mounts both volumes and populates them with realistic sample documents.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/agentic-agents
kubectl apply -f populate-agent-data-job.yaml
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Wait for data population to complete
kubectl wait --for=condition=complete job/populate-agent-data --timeout=300s -n default
:::

Verify the data was created:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl logs job/populate-agent-data
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Populating Finance Data Volume ===
  Created: /finance_data/reports/q1_2024_earnings.txt
  Created: /finance_data/reports/q2_2024_earnings.txt
  Created: /finance_data/reports/annual_budget_2024.txt
  Created: /finance_data/transactions/vendor_payments_jan.csv
  Created: /finance_data/transactions/vendor_payments_feb.csv
  Created: /finance_data/compliance/sox_audit_notes.txt
  Created: /finance_data/compliance/expense_policy.txt

=== Populating IT Operations Data Volume ===
  Created: /it_ops_data/runbooks/eks_cluster_restart.md
  Created: /it_ops_data/runbooks/database_failover.md
  Created: /it_ops_data/runbooks/incident_response.md
  Created: /it_ops_data/logs/app_errors_2024-03.log
  Created: /it_ops_data/logs/deployment_history.log
  Created: /it_ops_data/configs/network_topology.yaml
  Created: /it_ops_data/configs/monitoring_alerts.yaml

=== Data population complete ===
Finance volume: 7 files across 3 directories
IT Ops volume:  7 files across 3 directories
:::

:::alert{header="Enterprise Context" type="info"}
In a real environment, these volumes would contain terabytes of actual business data — financial systems exports, audit logs, operational runbooks, infrastructure documentation. The data might be replicated from on-premises via SnapMirror (as shown in Module 7 — Multi-Model Data Segregation with On-Premises to Cloud Replication). The key point: **each volume is a self-contained data domain** with independent access controls at the storage layer.
:::

---

### Summary

You have created two isolated FSxN volumes with sample data for the Finance and IT Operations teams. In the next section, you will configure FSxN's native access controls (export policies and UNIX permissions) to restrict which agents can access which volumes.

