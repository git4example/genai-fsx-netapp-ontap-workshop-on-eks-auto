---
title : "Prepare Team Data on FSxN"
weight : 610
---

## Overview

In this section, you will create **two isolated data volumes** on your FSx for NetApp ONTAP file system — one for each team's AI agent. You'll then **import** these existing volumes into Kubernetes via Trident, and populate them with sample documents representing real enterprise data.

This simulates a real-world scenario where customers **already have data volumes on FSxN** (perhaps migrated from on-premises via SnapMirror, or from existing workloads) and want to give AI agents secure access to that data through Kubernetes.

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

##### Step 2: Create Data Volumes on FSxN

Create two separate ONTAP volumes — one for Finance data and one for IT Operations data. In a real-world scenario, these would be **pre-existing volumes** on FSxN (e.g., replicated from on-premises via SnapMirror or created by another team).

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create Finance data volume (10GB)
aws fsx create-volume \
  --volume-type ONTAP \
  --name finance_agent_data \
  --ontap-configuration '{
    "JunctionPath": "/finance_agent_data",
    "SizeInMegabytes": 10240,
    "StorageVirtualMachineId": "'$FSXN_SVM_ID'",
    "StorageEfficiencyEnabled": true,
    "TieringPolicy": {"CoolingPeriod": 31, "Name": "AUTO"},
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION

echo "Created volume: finance_agent_data"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create IT Operations data volume (10GB)
aws fsx create-volume \
  --volume-type ONTAP \
  --name itops_agent_data \
  --ontap-configuration '{
    "JunctionPath": "/itops_agent_data",
    "SizeInMegabytes": 10240,
    "StorageVirtualMachineId": "'$FSXN_SVM_ID'",
    "StorageEfficiencyEnabled": true,
    "TieringPolicy": {"CoolingPeriod": 31, "Name": "AUTO"},
    "SecurityStyle": "UNIX"
  }' --region $AWS_REGION

echo "Created volume: itops_agent_data"
:::

Wait for volumes to become available:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "Waiting for volumes to become available..."
while true; do
  STATUS=$(aws fsx describe-volumes --region $AWS_REGION \
    --filters Name=file-system-id,Values=$FSXN_FS_ID \
    --query "Volumes[?Name=='finance_agent_data' || Name=='itops_agent_data'].Lifecycle" \
    --output text)
  if echo "$STATUS" | grep -qv "CREATING"; then
    break
  fi
  echo "  Still creating... checking again in 15s"
  sleep 15
done

aws fsx describe-volumes --region $AWS_REGION \
  --filters Name=file-system-id,Values=$FSXN_FS_ID \
  --query "Volumes[?Name=='finance_agent_data' || Name=='itops_agent_data'].{Name:Name, Status:Lifecycle}" \
  --output table
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
-----------------------------------------
|            DescribeVolumes            |
+--------------------+------------------+
|        Name        |     Status       |
+--------------------+------------------+
|  finance_agent_data|    AVAILABLE     |
|  itops_agent_data  |    AVAILABLE     |
+--------------------+------------------+
:::

##### Step 3: Import Existing Volumes into Kubernetes via Trident

Now we bring these **existing ONTAP volumes** into Kubernetes using Trident's volume import feature. This is the pattern you would use when you already have data on FSxN (e.g., migrated from on-prem via SnapMirror) and want Kubernetes pods to consume it.

:::alert{header="Why import instead of dynamic provisioning?" type="info"}
Trident can either **create new volumes** (dynamic provisioning via PVC) or **import existing ones**. Import is the right choice when:
- Data already lives on ONTAP volumes (e.g., replicated from on-prem)
- Another team created the volumes outside of Kubernetes
- You want to preserve the volume name and junction path

The `tridentctl import` command tells Trident: "take ownership of this existing ONTAP volume and expose it as a Kubernetes PVC — without copying or moving any data."
:::

First, create the PVC definitions that Trident will bind to the imported volumes:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/agentic-agents
cat finance-agent-pvc.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: finance-agent-data-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ontap-nas-sc
  resources:
    requests:
      storage: 10Gi
:::

Now import the volumes using `tridentctl` (available inside the Trident controller pod). We first copy the PVC definitions into the pod, then run the import:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the Trident controller pod name
export TRIDENT_POD=$(kubectl get pod -n trident -l app=controller.csi.trident.netapp.io -o jsonpath='{.items[0].metadata.name}')
echo "Trident controller pod: $TRIDENT_POD"

# Copy PVC files into the Trident controller pod
kubectl cp finance-agent-pvc.yaml trident/${TRIDENT_POD}:/tmp/finance-agent-pvc.yaml -c trident-main
kubectl cp itops-agent-pvc.yaml trident/${TRIDENT_POD}:/tmp/itops-agent-pvc.yaml -c trident-main
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Import finance_agent_data volume — Trident takes ownership and creates a PVC
kubectl exec -n trident ${TRIDENT_POD} -c trident-main -- \
  tridentctl import volume backend-ontap-nas finance_agent_data \
  --filename /tmp/finance-agent-pvc.yaml -n trident
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Import itops_agent_data volume
kubectl exec -n trident ${TRIDENT_POD} -c trident-main -- \
  tridentctl import volume backend-ontap-nas itops_agent_data \
  --filename /tmp/itops-agent-pvc.yaml -n trident
:::

Verify the PVCs are bound:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl get pvc finance-agent-data-pvc itops-agent-data-pvc
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
NAME                     STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
finance-agent-data-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   10Gi       RWX            ontap-nas-sc
itops-agent-data-pvc     Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   10Gi       RWX            ontap-nas-sc
:::

:::alert{header="What just happened?" type="info"}
Trident imported the existing ONTAP volumes without moving or copying any data. The volumes now appear as standard Kubernetes PVCs that any pod can mount. If these volumes had contained data replicated from on-premises via SnapMirror, that data would be immediately accessible to Kubernetes workloads — **zero data movement required**.
:::

##### Step 4: Populate Volumes with Sample Data

Deploy a Kubernetes Job that mounts both volumes via the Trident-managed PVCs and populates them with realistic sample documents:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl delete job populate-agent-data --ignore-not-found
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
In a real environment, these volumes would already contain terabytes of business data — financial systems exports, audit logs, operational runbooks. The import step would simply expose that existing data to Kubernetes. The key point: **Trident import brings existing ONTAP data into Kubernetes without any data movement** — the AI agents access the original volume directly.
:::

---

### Summary

You have created two FSxN volumes (simulating pre-existing enterprise data), imported them into Kubernetes via Trident, and populated them with sample data for the Finance and IT Operations teams. In the next section, you will configure FSxN's native access controls (export policies and UNIX permissions) to restrict which agents can access which volumes.

