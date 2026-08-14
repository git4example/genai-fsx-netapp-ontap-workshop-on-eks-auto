---
title : "Module 6 (Optional): Multi-AZ Resiliency and Live Failover"
weight : 600
hidden : true
---

:::alert{header="Optional Module" type="info"}
This module is optional. You can skip it and proceed directly to the next module if time is limited.
:::

## Module Overview

In this module you will explore one of the most powerful capabilities of Amazon FSx for NetApp ONTAP: **Multi-AZ high availability with zero RPO (Recovery Point Objective)**. Your FSx for ONTAP file system is deployed in a Multi-AZ configuration, meaning it maintains an active file server in one Availability Zone and a standby file server in a second AZ, with synchronous data replication between them.

You will:
1. Understand the Multi-AZ architecture and how automatic failover works
2. Observe the current active/standby state of your file system
3. Trigger a planned failover and observe that the vLLM inference pod continues serving without interruption
4. Verify zero data loss (zero RPO) after failover

This demonstrates how FSx for ONTAP provides **storage layer resiliency** for your GenAI workloads. The compute layer (EKS pods) is unaffected during a storage failover because the NFS endpoints automatically resolve to the active file server.

![maz-architecture](/static/images/maz-failover.png)

---

::::expand{header="Click here to learn more about FSx for ONTAP Multi-AZ architecture"}

#### How Multi-AZ Works

FSx for ONTAP Multi-AZ file systems deploy an active/standby pair of file servers across two Availability Zones:

- **Preferred subnet (Active under normal conditions)**: The AZ where the file system actively serves data when both nodes are healthy
- **Standby subnet**: The AZ where a standby file server maintains a synchronous copy of all data

**Synchronous replication** ensures that every write to the active file server is simultaneously written to the standby. This means:
- **Zero RPO**: No data is lost during failover (the standby always has the latest data)
- **Automatic takeover on AZ failure**: If the active AZ experiences an issue, the standby takes over within seconds; clients see a brief NFS pause and continue
- **Transparent to NFS clients**: The management LIF, intercluster LIF, and NFS data LIF are *floating endpoints*. Their IPs are stable; on takeover, FSx updates the registered VPC route tables so those IPs forward to the ENIs of the new active node. DNS records do not change.

#### Why route table registration matters

This is why the Terraform configuration registers the file system with the **EKS private subnet route tables** (the same ones the worker nodes use). Without that, FSx would update the VPC main route table on takeover, which the EKS worker nodes do not consult, and pods would lose connectivity to the file system after a failover even though everything looks healthy from the FSx side.

#### Why this matters for GenAI workloads

For inference workloads like vLLM serving the Mistral-7B model:
- The model data on the FSx for ONTAP volume is always available, even during an AZ failure
- Pods can be scheduled in either AZ and still access the same data via NFS
- No manual intervention is needed, and takeover is fully automatic if AWS detects a real AZ failure
- The vLLM pod does not crash. Active inference traffic served from the in-memory model continues uninterrupted; any subsequent disk-touching operation pauses for the few seconds the route table update takes, then resumes

::::

:::alert{header="Planned failover vs unplanned takeover" type="info"}
This module uses a **planned failover** (a manually triggered takeover via the FSx Console) to *simulate* what would happen during an unplanned AZ failure. The mechanics are identical from the client's perspective; the difference is only in who/what initiated it.
:::
