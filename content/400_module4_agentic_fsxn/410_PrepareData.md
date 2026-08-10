---
title : "Understanding the Pre-Configured Data Layer"
weight : 410
---

## Overview

The agent data environment was **pre-configured during workshop provisioning** so you can focus on deploying and testing agents rather than infrastructure setup. This page explains what was set up and why.

---

##### What Was Pre-Configured

During workshop provisioning, the following was automatically set up:

1. **FSx for NetApp ONTAP Volume**: `agent_shared_data` (10 GiB) at junction path `/agent_data`
2. **Kubernetes Namespace**: `agents` (all three agents deploy here)
3. **PVC**: `agent-shared-data` importing the volume via Trident
4. **Data Population**: dummy finance and IT ops files written to the volume
5. **UNIX Permissions**: per-directory UID/GID ownership set

##### Directory Layout on the Shared Volume

All agents mount the **same volume** at `/data`. Access is controlled by **POSIX UID/GID** on subdirectories:

:::code{showCopyAction=false showLineNumbers=false language=bash}
/data/                        (volume root, mounted by all agents)
├── finance/                  (owner: UID 1001, group: 1001, mode: 0750)
│   ├── reports/
│   │   ├── q1_2024_earnings.txt
│   │   ├── q2_2024_earnings.txt
│   │   └── annual_budget_2024.txt
│   ├── compliance/
│   │   ├── expense_policy.txt
│   │   └── sox_audit_notes.txt
│   └── transactions/
│       ├── vendor_payments_jan.csv
│       └── vendor_payments_feb.csv
│
└── itops/                    (owner: UID 1002, group: 1002, mode: 0750)
    ├── configs/
    │   ├── k8s_cluster_config.txt
    │   └── monitoring_endpoints.txt
    ├── logs/
    │   └── deployment_log_2024_06.txt
    └── runbooks/
        ├── incident_response.txt
        └── deployment_checklist.txt
:::

##### How Access Control Works

| Agent | UID | DATA_DIR | Can Read `/data/finance/` | Can Read `/data/itops/` |
|-------|-----|----------|--------------------------|------------------------|
| Finance Agent | 1001 | `/data/finance` | Yes, UID matches owner | No, not owner, not in group |
| IT Ops Agent | 1002 | `/data/itops` | No, not owner, not in group | Yes, UID matches owner |
| Malicious Agent | 1099 | `/data` | No, permission denied | No, permission denied |

:::alert{header="Key Insight" type="info"}
All three agents mount the **exact same PVC**, so there is no volume-level or namespace-level separation. The **only** difference between them is the Linux UID they run as. FSx for NetApp ONTAP enforces standard POSIX permissions at the NFS protocol level, so the agent process literally cannot read bytes that its UID doesn't have permission for, regardless of what the LLM instructs it to do.
:::

##### Verify the Pre-Configured Setup

You can verify everything is in place:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Check namespace exists
kubectl get namespace agents

# Check PVC is bound
kubectl get pvc -n agents agent-shared-data

:::

Once you have deployed the agents in the next section, you can confirm the ownership and modes on the shared volume from inside any agent pod:

::code[kubectl exec -n agents deploy/finance-agent -- ls -la /data/]{language=bash showLineNumbers=false showCopyAction=true}

You should see `finance` (owned by 1001) and `itops` (owned by 1002), both with mode `drwxr-x---` (750).

:::alert{header="Why check from inside an agent pod?" type="info"}
The shared volume's PVC lives in the `agents` namespace, and a pod can only mount PVCs from its own namespace, so the `netshoot-fsxn` pod in `default` cannot see this volume. Checking from an agent pod is also the more meaningful test: it shows the permissions exactly as the agent process sees them over NFS.
:::

---

### Summary

The shared volume is ready with team data pre-loaded and POSIX permissions set. In the next section, you'll deploy three AI agents that mount this volume, and prove that only the correct UID can access each team's data.
