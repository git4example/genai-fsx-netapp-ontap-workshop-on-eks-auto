---
title : "Understand Pre-configured Items"
weight : 410
---

## Overview

The AI Agent data & permissions has been **pre-configured during workshop provisioning**, so you can focus on deploying and testing agents rather than infrastructure setup. This page explains what was setup, and why to give context.

---

### Workshop pre-configured items

During workshop provisioning, the following was automatically set up:

1. **FSx for NetApp ONTAP Volume**: `agent_shared_data` (10 GiB) at junction path `/agent_data`
2. **Kubernetes Namespace**: `agents` (all three AI Agents were deployed into this namespace)
3. **PVC**: `agent-shared-data` importing the volume via Trident
4. **Data Population on volume**: dummy data for finance and IT ops files
5. **UNIX Permissions**: per-directory UID/GID ownership set

### Directory layout on the shared volume

All AI Agents mount the **same volume** at `/data`. Access is controlled by **POSIX UID/GID** on subdirectories:

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

### How access control works

| Agent | UID | DATA_DIR | Can Read `/data/finance/` | Can Read `/data/itops/` |
|-------|-----|----------|--------------------------|------------------------|
| Finance Agent | 1001 | `/data/finance` | Yes, UID matches owner | No, not owner, not in group |
| IT Ops Agent | 1002 | `/data/itops` | No, not owner, not in group | Yes, UID matches owner |
| Malicious Agent | 1099 | `/data` | No, permission denied | No, permission denied |


### Verify the pre-configured setup

You can verify everything is in place:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Check namespace exists
kubectl get namespace agents

# Check PVC is bound
kubectl get pvc -n agents agent-shared-data

:::

The namespace should exist and the PVC should show `Bound`.

---

## Summary

The shared volume is ready with team data pre-loaded and POSIX permissions set. In the next section, you'll deploy three AI agents that mount this volume, and prove that only the correct UID can access each team's data.
