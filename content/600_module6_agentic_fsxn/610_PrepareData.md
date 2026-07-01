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
|         DescribeVolumes         |
+---------------------+-----------+
|        Name         |  Status   |
+---------------------+-----------+
|  finance_agent_data |  CREATED  |
|  itops_agent_data   |  CREATED  |
+---------------------+-----------+
:::

##### Step 3: Create Namespaces and Import Volumes into Kubernetes via Trident

First, create isolated namespaces for each agent. The PVCs will be created **inside** these namespaces — meaning the malicious agent's namespace will have no PVC and therefore no access to any data volume.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create namespaces for each agent team
kubectl create namespace agent-finance 2>/dev/null || true
kubectl create namespace agent-itops 2>/dev/null || true
kubectl create namespace agent-malicious 2>/dev/null || true
:::

Now we bring the **existing ONTAP volumes** into Kubernetes using Trident's **annotation-based volume import**. Each PVC is created in its designated team's namespace — this is the first layer of access control.

:::alert{header="Why import instead of dynamic provisioning?" type="info"}
Trident can either **create new volumes** (dynamic provisioning via PVC) or **import existing ones**. Import is the right choice when:
- Data already lives on ONTAP volumes (e.g., replicated from on-prem)
- Another team created the volumes outside of Kubernetes
- You want to preserve the volume name and junction path

When Trident sees a PVC with the `trident.netapp.io/importVolume` annotation, it adopts the named ONTAP volume and exposes it as a Kubernetes PVC — **without copying or moving any data**.
:::

Review the PVC definition with import annotations:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/agentic-agents
cat finance-agent-pvc.yaml
:::

```yaml {linenos=true hl_lines=["6-8"]}
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: finance-agent-data-pvc
  namespace: agent-finance
  annotations:
    trident.netapp.io/importVolume: "finance_agent_data"
    trident.netapp.io/importBackend: "fsx-ontap-nas"
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ontap-nas-sc
  resources:
    requests:
      storage: 10Gi
```

The key annotations:
- `trident.netapp.io/importVolume` — The exact ONTAP volume name to import
- `trident.netapp.io/importBackend` — The Trident backend that manages this volume

Notice the PVC is in the `agent-finance` namespace — only pods in that namespace can mount it.

Apply both PVCs to trigger the import:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Import finance_agent_data volume into the agent-finance namespace
kubectl apply -f finance-agent-pvc.yaml

# Import itops_agent_data volume into the agent-itops namespace
kubectl apply -f itops-agent-pvc.yaml
:::

Verify the PVCs are bound:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl get pvc -n agent-finance finance-agent-data-pvc
kubectl get pvc -n agent-itops itops-agent-data-pvc
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
NAME                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
finance-agent-data-pvc    Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   10Gi       RWX            ontap-nas-sc   <unset>                 8s

NAME                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
itops-agent-data-pvc      Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   10Gi       RWX            ontap-nas-sc   <unset>                 8s
:::

:::alert{header="Two layers of access control in place" type="info"}
1. **Namespace scoping** — The finance PVC exists only in `agent-finance`; the IT ops PVC only in `agent-itops`. The `agent-malicious` namespace has **no PVC** — there's nothing for a malicious pod to mount.
2. **UNIX permissions** (configured in the next section) — Even within the authorized namespace, only the correct UID can read files.

Trident imported the existing ONTAP volumes without moving or copying data. If these volumes contained data replicated from on-premises via SnapMirror, that data would be immediately accessible — **zero data movement required**.
:::

##### Step 4: Populate Volumes with Sample Data

Deploy Kubernetes Jobs in each namespace to populate the volumes with sample documents. Each job runs in its own namespace and mounts the PVC available in that namespace:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Populate finance data (job runs in agent-finance namespace)
kubectl apply -f populate-finance-data-job.yaml
kubectl wait --for=condition=complete job/populate-finance-data -n agent-finance --timeout=300s

# Populate IT ops data (job runs in agent-itops namespace)
kubectl apply -f populate-itops-data-job.yaml
kubectl wait --for=condition=complete job/populate-itops-data -n agent-itops --timeout=300s
:::

Verify the data was created:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "=== Finance Data ==="
kubectl logs job/populate-finance-data -n agent-finance

echo ""
echo "=== IT Ops Data ==="
kubectl logs job/populate-itops-data -n agent-itops
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Finance Data ===
=== Populating Finance Data Volume ===
  Created: /finance_data/reports/q1_2024_earnings.txt
  Created: /finance_data/reports/q2_2024_earnings.txt
  Created: /finance_data/reports/annual_budget_2024.txt
  Created: /finance_data/transactions/vendor_payments_jan.csv
  Created: /finance_data/transactions/vendor_payments_feb.csv
  Created: /finance_data/compliance/sox_audit_notes.txt
  Created: /finance_data/compliance/expense_policy.txt

Finance volume: 7 files across 3 directories

=== IT Ops Data ===
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
IT Ops volume: 7 files across 3 directories
:::

:::alert{header="Enterprise Context" type="info"}
In a real environment, these volumes would already contain terabytes of business data — financial systems exports, audit logs, operational runbooks. The import step would simply expose that existing data to Kubernetes. The key point: **Trident import brings existing ONTAP data into Kubernetes without any data movement** — the AI agents access the original volume directly.
:::

---

### Summary

You have created two FSxN volumes (simulating pre-existing enterprise data), imported them into Kubernetes via Trident, and populated them with sample data for the Finance and IT Operations teams. In the next section, you will configure FSxN's native access controls (export policies and UNIX permissions) to restrict which agents can access which volumes.

