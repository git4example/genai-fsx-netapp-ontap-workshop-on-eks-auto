---
title : "Multi-AZ Resiliency and Live Failover"
weight : 500
---

## Module Overview

In this module you will explore one of the most powerful capabilities of Amazon FSx for NetApp ONTAP: **Multi-AZ high availability with zero RPO (Recovery Point Objective)**. Your FSx for ONTAP file system is deployed in a Multi-AZ configuration, meaning it maintains an active file server in one Availability Zone and a standby file server in a second AZ, with synchronous data replication between them.

You will:
1. Understand the Multi-AZ architecture and how automatic failover works
2. Observe the current active/standby state of your file system
3. Trigger a planned failover and observe that the vLLM inference pod continues serving without interruption
4. Verify zero data loss (zero RPO) after failover

This demonstrates how FSx for ONTAP provides **storage layer resiliency** for your GenAI workloads — the compute layer (EKS pods) is unaffected during a storage failover because the NFS endpoints automatically resolve to the active file server.

![maz-architecture](/static/images/maz-failover.png)

---

::::expand{header="Click here to learn more about FSx for ONTAP Multi-AZ architecture"}

#### How Multi-AZ Works

FSx for ONTAP Multi-AZ file systems deploy an active/standby pair of file servers across two Availability Zones:

- **Preferred subnet (Active)** — The AZ where the file system actively serves data under normal conditions
- **Standby subnet (Standby)** — The AZ where a standby file server maintains a synchronous copy of all data

**Synchronous replication** ensures that every write to the active file server is simultaneously written to the standby. This means:
- **Zero RPO** — No data is lost during failover (the standby always has the latest data)
- **Automatic failover** — If the active AZ experiences an issue, the standby automatically promotes to active within ~60 seconds
- **Transparent to clients** — NFS clients (including Kubernetes pods) reconnect automatically because the DNS endpoints resolve to the new active file server

#### Why This Matters for GenAI Workloads

For inference workloads like vLLM serving the Mistral-7B model:
- The model data on the FSx for ONTAP volume is always available, even during an AZ failure
- Pods can be scheduled in either AZ and still access the same data via NFS
- No manual intervention is needed — the failover is fully automatic
- The vLLM pod may experience a brief NFS reconnection (~30-60 seconds) but does not crash or lose state

::::
