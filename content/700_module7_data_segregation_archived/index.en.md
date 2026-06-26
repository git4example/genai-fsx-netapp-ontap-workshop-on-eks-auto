---
title : "Multi-Model Data Segregation with On-Premises to Cloud Replication"
weight : 700
---

## Module Overview

In enterprise environments, customers often have **petabytes of data on-premises** and need to deploy **multiple AI models** in the cloud — each with access to only a **specific subset** of that data. This module demonstrates how to achieve secure, model-level data segregation by replicating data from an on-premises NetApp ONTAP system to AWS using Amazon FSx for NetApp ONTAP's native SnapMirror replication.

:::alert{header="On-Premises Focus" type="info"}
The primary scenario this module addresses is **on-premises to cloud** data movement. Customers keep their petabyte-scale data on-prem and selectively replicate only the subsets each cloud-hosted model needs. For workshop purposes, we simulate the on-premises environment using a second FSx for ONTAP file system in a different region (cross-region), but the SnapMirror workflow is identical to a true on-prem-to-cloud deployment using physical NetApp ONTAP hardware.
:::

You will:
1. Simulate an on-premises data center (representing a customer's on-prem NetApp ONTAP with petabytes of data) using a second FSx for ONTAP file system
2. Create isolated data volumes representing different business domains on the "on-prem" system
3. Selectively replicate only the relevant data subsets from on-premises to cloud using SnapMirror
4. Deploy two different LLM models (Mistral-7B and Phi-2), each with access to only its designated data volume
5. **Prove isolation** by attempting cross-model data access and observing it being denied

This pattern addresses a critical enterprise requirement: **data governance at the model level** — ensuring that a model trained or inferencing on finance data cannot access healthcare data, and vice versa. The bulk of the customer's data (petabytes) remains securely on-premises; only the specific subsets required for cloud-based inference are replicated.

![data-segregation-architecture](/static/images/data-segregation-architecture.png)

---

## Architecture

```
CUSTOMER ON-PREMISES                             AWS CLOUD
(NetApp ONTAP — Simulated via                   (Region A — e.g. us-west-2)
 FSx ONTAP in Region B)
┌────────────────────────────────┐              ┌──────────────────────────────────────┐
│  On-Prem NetApp ONTAP         │              │  EKS Cluster                         │
│  (Petabytes of Data)          │              │                                      │
│                                │              │  Namespace: model-finance            │
│  SVM: onprem-svm              │              │                                      │
│  ├─ Vol: finance_data (50GB)  │──SnapMirror──│→ PVC-A ──→ Model A (Mistral-7B)     │
│  │    └─ Finance datasets     │  (On-Prem    │           (can ONLY see finance)      │
│  │                            │   to Cloud)  │                                      │
│  ├─ Vol: health_data (50GB)   │──SnapMirror──│→ PVC-B ──→ Model B (Phi-2)          │
│  │    └─ Healthcare datasets  │  (On-Prem    │           (can ONLY see healthcare)   │
│  │                            │   to Cloud)  │  Namespace: model-healthcare         │
│  └─ Vol: retail_data (50GB)   │              │                                      │
│       └─ NOT replicated       │              │  (retail data stays on-prem)         │
│                                │              │                                      │
│  + Other volumes (PBs)        │              │                                      │
│    NOT needed in cloud        │              │                                      │
└────────────────────────────────┘              └──────────────────────────────────────┘
```

**Key Design Principles:**
- **On-premises data stays on-premises** — Only the specific subsets required by cloud models are replicated. Petabytes of unneeded data never leave the customer's data center.
- **Selective replication (On-Prem → Cloud)** — SnapMirror replicates at the volume level, so you choose exactly which datasets move to the cloud.
- **Volume-level isolation** — Each model gets its own PVC backed by a separate ONTAP volume. No shared access.
- **Namespace isolation** — Kubernetes RBAC prevents cross-namespace PVC access.
- **Export policy enforcement** — ONTAP export policies restrict NFS access at the storage layer.

---

::::expand{header="Click here to learn more about SnapMirror and cross-region data movement"}

#### NetApp SnapMirror for On-Premises to Cloud Replication

**SnapMirror** is NetApp ONTAP's native replication technology that efficiently mirrors data between ONTAP systems — whether on-premises or in AWS. Key characteristics:

- **On-prem to cloud native** — SnapMirror works identically between physical on-premises NetApp ONTAP and Amazon FSx for NetApp ONTAP. No data transformation or middleware needed.
- **Volume-level granularity** — You choose exactly which volumes to replicate. A customer with 500 volumes on-prem can replicate just 2 of them to the cloud.
- **Block-level incremental** — After the initial baseline copy, only changed blocks are transferred, making ongoing replication bandwidth-efficient even over WAN links.
- **Cross-region support** — FSx for ONTAP supports SnapMirror between file systems in different AWS regions, or between on-premises ONTAP and FSx for ONTAP (hybrid cloud).
- **Read-only destination** — Replicated volumes on the destination are read-only (DP type), which is perfect for inference workloads that only need to read model/data files.

#### Why This Matters for Enterprise GenAI (On-Prem to Cloud)

Consider a financial services company with 5 PB of data in their on-premises data center:
- They want to deploy a fraud detection model in AWS that needs access to transaction data (200 GB)
- They want to deploy a customer service chatbot in AWS that needs product documentation (50 GB)
- The remaining 4.75 PB **must never leave the on-premises data center** due to regulatory requirements

SnapMirror enables this by replicating only the specific volumes from on-prem to cloud. Combined with ONTAP export policies and Kubernetes RBAC, you achieve defense-in-depth data governance while keeping the bulk of sensitive data securely on-premises.

::::

:::alert{header="Prerequisites" type="info"}
This module assumes you have completed Modules 1-2 and have a working EKS cluster with the Trident CSI driver installed. The on-premises NetApp ONTAP environment is simulated using a pre-provisioned FSx for ONTAP file system in a secondary region (cross-region replication). In a real deployment, this would be the customer's physical on-prem NetApp ONTAP cluster connected to AWS via Direct Connect or VPN, with SnapMirror replicating over that link.
:::

