---
title : "Configure FSxN Native Access Control"
weight : 620
---

## Overview

In this section, you will configure **FSx for NetApp ONTAP's native security mechanisms** to enforce data segregation between AI agents. This demonstrates the RBAC capabilities of FSxN — giving each agent pod exactly the access it needs and nothing more.

You will configure two independent security layers:

1. **Export Policies** — Control which pod IP ranges (CIDRs) can NFS-mount each volume
2. **UNIX Permissions** — Control which UIDs/GIDs can read files even if the volume is mounted

This defense-in-depth approach means that even if one layer is bypassed, the other still blocks unauthorized access.

---

##### Step 1: Identify Pod Network CIDRs

First, determine the pod CIDR ranges for each agent namespace. We'll use Kubernetes Network Policies combined with ONTAP export policies to restrict access.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create namespaces for each agent
kubectl create namespace agent-finance
kubectl create namespace agent-itops
kubectl create namespace agent-malicious

# Label them for identification
kubectl label namespace agent-finance team=finance role=authorized
kubectl label namespace agent-itops team=itops role=authorized
kubectl label namespace agent-malicious team=external role=unauthorized
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the cluster's pod CIDR (we'll use pod IPs for export policies)
export POD_CIDR=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}')
echo "Pod CIDR: $POD_CIDR"
:::

:::alert{header="Export Policy Strategy" type="info"}
In production, you would use more granular CIDR ranges (e.g., per-namespace pod CIDRs via Multus or VPC-CNI prefix delegation). For this workshop, we demonstrate the concept using pod IP addresses that we capture after deployment. The principle is identical: **the ONTAP export policy only allows specific IP ranges to mount each volume**.
:::

##### Step 2: Create Export Policies via ONTAP REST API

Configure export policies on the FSxN SVM so that:
- `finance_data` volume → accessible only by finance agent pods
- `it_ops_data` volume → accessible only by IT ops agent pods
- Both volumes → **deny** the malicious agent pods

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create export policy for Finance data volume
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  -X POST "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "finance_agents_only",
    "svm": {"name": "'${FSXN_SVM_NAME}'"},
    "rules": [
      {
        "clients": [{"match": "'${POD_CIDR}'"}],
        "ro_rule": ["sys"],
        "rw_rule": ["never"],
        "superuser": ["none"],
        "protocols": ["nfs3", "nfs4"]
      }
    ]
  }'

echo "Created export policy: finance_agents_only"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create export policy for IT Ops data volume
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  -X POST "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "itops_agents_only",
    "svm": {"name": "'${FSXN_SVM_NAME}'"},
    "rules": [
      {
        "clients": [{"match": "'${POD_CIDR}'"}],
        "ro_rule": ["sys"],
        "rw_rule": ["never"],
        "superuser": ["none"],
        "protocols": ["nfs3", "nfs4"]
      }
    ]
  }'

echo "Created export policy: itops_agents_only"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create a restrictive export policy that DENIES all access (for testing the malicious agent)
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  -X POST "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "deny_all",
    "svm": {"name": "'${FSXN_SVM_NAME}'"},
    "rules": [
      {
        "clients": [{"match": "0.0.0.0/0"}],
        "ro_rule": ["never"],
        "rw_rule": ["never"],
        "superuser": ["none"],
        "protocols": ["nfs3", "nfs4"]
      }
    ]
  }'

echo "Created export policy: deny_all (blocks everyone)"
:::

##### Step 3: Apply Export Policies to Volumes

Assign the restrictive export policies to each volume:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get volume UUIDs
export FINANCE_VOL_UUID=$(curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/storage/volumes?name=finance_agent_data&svm.name=${FSXN_SVM_NAME}" | \
  jq -r '.records[0].uuid')

export ITOPS_VOL_UUID=$(curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/storage/volumes?name=itops_agent_data&svm.name=${FSXN_SVM_NAME}" | \
  jq -r '.records[0].uuid')

echo "Finance volume UUID: $FINANCE_VOL_UUID"
echo "IT Ops volume UUID: $ITOPS_VOL_UUID"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Apply finance export policy to finance volume
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  -X PATCH "https://${FSXN_MGMT_IP}/api/storage/volumes/${FINANCE_VOL_UUID}" \
  -H "Content-Type: application/json" \
  -d '{
    "nas": {
      "export_policy": {"name": "finance_agents_only"}
    }
  }'

echo "Applied 'finance_agents_only' policy to finance_data volume"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Apply IT ops export policy to IT ops volume
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  -X PATCH "https://${FSXN_MGMT_IP}/api/storage/volumes/${ITOPS_VOL_UUID}" \
  -H "Content-Type: application/json" \
  -d '{
    "nas": {
      "export_policy": {"name": "itops_agents_only"}
    }
  }'

echo "Applied 'itops_agents_only' policy to it_ops_data volume"
:::

##### Step 4: Configure UNIX Permissions (Second Layer)

Set ownership and permissions on the volume files so that even if a volume could be mounted, only the correct UID can read the data:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Deploy a job to set UNIX ownership and permissions
kubectl apply -f set-volume-permissions-job.yaml
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl wait --for=condition=complete job/set-volume-permissions --timeout=120s
kubectl logs job/set-volume-permissions
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
Setting permissions on /finance_data...
  chown -R 1001:1001 /finance_data
  chmod -R 750 /finance_data
  Verified: only UID 1001 (finance agent) can read

Setting permissions on /it_ops_data...
  chown -R 1002:1002 /it_ops_data
  chmod -R 750 /it_ops_data
  Verified: only UID 1002 (IT ops agent) can read

Permission setup complete.
  finance_data: owner=1001, group=1001, mode=750
  it_ops_data:  owner=1002, group=1002, mode=750
:::

:::alert{header="Defense in Depth — Two Layers" type="warning"}
We now have **two independent security layers** protecting each volume:

**Layer 1 — Export Policy (Network Level):** Controls which IP addresses can NFS-mount the volume. The malicious agent pod's IP won't match the allowed CIDR.

**Layer 2 — UNIX Permissions (File Level):** Even if an attacker somehow mounts the volume, only the designated UID (1001 for finance, 1002 for IT ops) can read files. The malicious agent runs as UID 1099 and gets "Permission denied."

These layers are enforced by the **ONTAP storage controller itself** — not by the application, not by Kubernetes, not by the LLM. The agent cannot bypass them regardless of what instructions it receives.
:::

##### Step 5: Verify Export Policy Configuration

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# List all export policies on the SVM
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies?svm.name=${FSXN_SVM_NAME}" | \
  jq '.records[] | {name: .name, id: .id}'
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Show rules for finance policy
curl -sk -u "vsadmin:${FSXN_SVM_PASS}" \
  "https://${FSXN_MGMT_IP}/api/protocols/nfs/export-policies?name=finance_agents_only&svm.name=${FSXN_SVM_NAME}&fields=rules" | \
  jq '.records[0].rules[] | {clients: .clients[].match, ro_rule: .ro_rule, rw_rule: .rw_rule}'
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
{
  "clients": "10.0.x.0/24",
  "ro_rule": ["sys"],
  "rw_rule": ["never"]
}
:::

---

### Summary

You have configured FSxN's native access control with two independent security layers:
1. **Export policies** restrict which pod IPs can mount each volume at the NFS protocol level
2. **UNIX permissions** restrict which UIDs can read files at the filesystem level

In the next section, you will deploy the AI agents using Strands Agents SDK — each running with its designated UID and in its designated namespace.

