---
title : "Configure FSxN Native Access Control"
weight : 620
---

## Overview

In this section, you will configure **FSx for NetApp ONTAP's native security mechanisms** to enforce data segregation between AI agents. Even though all agents mount volumes through the same Trident CSI driver, ONTAP's **UNIX permissions** ensure that each agent can only read the files it's authorized to access.

You will configure two security layers:

1. **UNIX Permissions (UID/GID)** — The primary enforcement. Each volume's files are owned by a specific UID. Agents running as a different UID get "Permission denied."
2. **Export Policies** — Network-level guardrail restricting NFS access to only the EKS cluster subnet.

---

##### How Access Control Works with Trident

When a pod mounts a Trident-managed PVC, the NFS connection is established by the Trident CSI node plugin running on the EKS node. However, **file-level access** is still governed by the UID/GID of the process inside the pod:

:::code{showCopyAction=false showLineNumbers=false language=bash}
Pod (UID 1001) → reads file owned by UID 1001 → ALLOWED
Pod (UID 1099) → reads file owned by UID 1001, mode 750 → PERMISSION DENIED
:::

ONTAP enforces UNIX permissions at the storage controller level. The UID from the pod's `securityContext.runAsUser` is what ONTAP sees when the process attempts to read a file. This is enforced regardless of:
- What the LLM instructs the agent to do
- Whether the volume is mounted (it is — but reading is blocked)
- What container image the agent uses

---

##### Step 1: Configure UNIX Permissions (Primary Security Layer)

Set ownership and permissions on the volume files so that only the correct UID can read each volume's data:

- `finance_agent_data` → owned by UID **1001** (Finance agent)
- `itops_agent_data` → owned by UID **1002** (IT Ops agent)
- Both with mode **750** — owner can read/execute, group can read/execute, others get nothing

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/agentic-agents
kubectl delete job set-finance-permissions -n agent-finance --ignore-not-found
kubectl delete job set-itops-permissions -n agent-itops --ignore-not-found
kubectl apply -f set-volume-permissions-job.yaml
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl wait --for=condition=complete job/set-finance-permissions -n agent-finance --timeout=120s
kubectl wait --for=condition=complete job/set-itops-permissions -n agent-itops --timeout=120s

echo "=== Finance volume permissions ==="
kubectl logs job/set-finance-permissions -n agent-finance
echo ""
echo "=== IT Ops volume permissions ==="
kubectl logs job/set-itops-permissions -n agent-itops
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Finance volume permissions ===
Setting permissions on /data (finance volume)...
  chown -R 1001:1001 /data
  chmod -R 750 /data
  Verified: only UID 1001 (finance agent) can read
Permission setup complete: owner=1001, group=1001, mode=750

=== IT Ops volume permissions ===
Setting permissions on /data (IT ops volume)...
  chown -R 1002:1002 /data
  chmod -R 750 /data
  Verified: only UID 1002 (IT ops agent) can read
Permission setup complete: owner=1002, group=1002, mode=750
:::

:::alert{header="Why UID-based isolation works" type="info"}
When the Finance agent pod runs with `runAsUser: 1001`, every file operation from that pod authenticates as UID 1001 against ONTAP. Since the finance volume is owned by UID 1001 with mode 750:
- **Finance Agent (UID 1001)** → owner match → **can read**
- **IT Ops Agent (UID 1002)** → not owner, not in group → **permission denied**
- **Malicious Agent (UID 1099)** → not owner, not in group → **permission denied**

This is enforced by the **ONTAP storage controller**, not by the pod, not by Kubernetes, and not by the LLM. The agent cannot bypass it.
:::

##### Step 2: Configure Export Policies (Network Security Layer)

Export policies control which IP ranges can NFS-mount the volumes at the network level. Since Trident's CSI node pods perform the NFS mounts, we configure the export policy to allow only the EKS node subnet — blocking any unauthorized hosts from mounting the volumes.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the EKS node subnet CIDR from the node's internal IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
export NODE_CIDR=$(echo $NODE_IP | sed 's|\.[0-9]*$|.0/16|')
echo "Node IP: $NODE_IP"
echo "Node network range (for export policy): $NODE_CIDR"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create an export policy that only allows the EKS cluster to mount
RESPONSE=$(curl -sk -w "\n%{http_code}" -u "vsadmin:${FSXN_SVM_PASS}" \
  -X POST "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "eks_cluster_only",
    "svm": {"name": "'${FSXN_SVM_NAME}'"},
    "rules": [
      {
        "clients": [{"match": "'${NODE_CIDR}'"}],
        "ro_rule": ["sys"],
        "rw_rule": ["sys"],
        "superuser": ["sys"],
        "protocols": ["nfs3", "nfs4"]
      }
    ]
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "201" ]]; then
  echo "Export policy 'eks_cluster_only' created successfully (HTTP $HTTP_CODE)"
elif [[ "$HTTP_CODE" == "409" ]]; then
  echo "Export policy 'eks_cluster_only' already exists (HTTP $HTTP_CODE) — continuing"
else
  echo "Unexpected response (HTTP $HTTP_CODE):"
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
fi
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get volume UUIDs (Trident may have renamed them with a prefix)
export FINANCE_VOL_UUID=$(curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/storage/volumes?name=*finance_agent_data*&svm.name=${FSXN_SVM_NAME}" | \
  jq -r '.records[0].uuid')

export ITOPS_VOL_UUID=$(curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/storage/volumes?name=*itops_agent_data*&svm.name=${FSXN_SVM_NAME}" | \
  jq -r '.records[0].uuid')

echo "Finance volume UUID: $FINANCE_VOL_UUID"
echo "IT Ops volume UUID: $ITOPS_VOL_UUID"

if [[ "$FINANCE_VOL_UUID" == "null" || -z "$FINANCE_VOL_UUID" ]]; then
  echo "WARNING: Could not find finance volume. Check volume name."
fi
if [[ "$ITOPS_VOL_UUID" == "null" || -z "$ITOPS_VOL_UUID" ]]; then
  echo "WARNING: Could not find IT ops volume. Check volume name."
fi
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Apply the export policy to both volumes
echo "Applying export policy to finance volume..."
curl -sk -w " (HTTP %{http_code})\n" -u "vsadmin:${FSXN_SVM_PASS}" \
  -X PATCH "https://${FSXN_MGMT_IP}/api/storage/volumes/${FINANCE_VOL_UUID}" \
  -H "Content-Type: application/json" \
  -d '{"nas": {"export_policy": {"name": "eks_cluster_only"}}}'

echo "Applying export policy to IT ops volume..."
curl -sk -w " (HTTP %{http_code})\n" -u "vsadmin:${FSXN_SVM_PASS}" \
  -X PATCH "https://${FSXN_MGMT_IP}/api/storage/volumes/${ITOPS_VOL_UUID}" \
  -H "Content-Type: application/json" \
  -d '{"nas": {"export_policy": {"name": "eks_cluster_only"}}}'
:::

:::alert{header="Export Policy + UNIX Permissions = Defense in Depth" type="warning"}
The two layers work together:

| Layer | What It Controls | Enforced By |
|-------|-----------------|-------------|
| **Export Policy** | Which hosts can NFS-mount the volume (network level) | ONTAP — rejects mount from unauthorized IPs |
| **UNIX Permissions** | Which UIDs can read files (file level) | ONTAP — denies read/write for wrong UID |

Even if an attacker gains access to an EKS node (passing the export policy), they still need the correct UID to read files. And a malicious agent pod running with the wrong UID gets "Permission denied" from ONTAP — the storage controller enforces it, not the application.
:::

##### Step 3: Verify Configuration

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Verify export policies on the SVM
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies?svm.name=${FSXN_SVM_NAME}" | \
  jq '.records[] | {name: .name, id: .id}'
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Verify the export policy rules
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies?name=eks_cluster_only&svm.name=${FSXN_SVM_NAME}&fields=rules" | \
  jq '.records[0].rules[] | {clients: .clients[].match, ro_rule: .ro_rule, rw_rule: .rw_rule}'
:::

---

### Summary

You have configured FSxN's native access control:
1. **UNIX permissions** — Each volume's files are owned by a specific UID (1001 or 1002) with mode 750. Only the designated agent UID can read the files.
2. **Export policy** — Only EKS cluster nodes can NFS-mount the volumes, blocking access from any other hosts.

In the next section, you will deploy the AI agents using Strands Agents SDK — each running with its designated UID — and prove that UNIX permissions block unauthorized access.

