---
title : "View FSx for ONTAP details in the Amazon FSx console"
weight : 131
---

## Overview

In the previous steps you deployed the Trident CSI driver, configured a backend connection to your FSx for ONTAP file system, and created a StorageClass and PVC for dynamic provisioning. Let's take a moment to explore the FSx for ONTAP file system in the AWS console and understand the key ONTAP concepts: **file systems**, **Storage Virtual Machines (SVMs)**, **volumes**, **NFS access**, **snapshots**, and **data tiering**.

##### Understanding FSx for ONTAP architecture

Before navigating the console, here is a quick overview of how FSx for ONTAP organizes storage:

:::alert{header="FSx for ONTAP concepts" type="info"}
- **File system** — The top-level resource. It defines the SSD storage capacity, throughput, and deployment type (Single-AZ or Multi-AZ). Think of it as the physical storage cluster.
- **Storage Virtual Machine (SVM)** — A logical storage server within the file system. Each SVM has its own NFS/SMB endpoints and credentials. A single file system can host multiple SVMs for multi-tenant isolation.
- **Volume** — A logical data container within an SVM. Volumes are where your data lives. Each volume has a **junction path** (like a mount point) and can be accessed via NFS. The Trident CSI driver creates ONTAP volumes automatically when you create a PVC.
- **NFS access** — ONTAP volumes are accessed over NFS (TCP port 2049). The Trident CSI driver mounts volumes into your Kubernetes pods using NFS v4.1.
- **Snapshots** — Point-in-time, read-only copies of a volume. Snapshots are space-efficient (they only store changed blocks) and can be used for backup, recovery, or cloning.
- **Data tiering** — FSx for ONTAP can automatically tier infrequently accessed data from high-performance SSD storage to lower-cost capacity pool storage, reducing costs while keeping data accessible.
:::

##### View your FSx for ONTAP file system in the console

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx/).

2. From the top right hand corner, select the **AWS region** that was provided to you for this lab (i.e. us-west-2), before continuing.

![aws_region](/static/images/aws_region.png)

3. In the FSx console you will see a list of your file systems. You should see the FSx for ONTAP file system that was pre-provisioned for you as part of the lab. The **File system type** column will show **ONTAP**.

4. Click on the **File system ID** of your FSx for ONTAP file system to view its details.

5. On the file system details page, you can see the key configuration for your ONTAP file system:
   - **Deployment type** — Single-AZ (the file system runs in a single Availability Zone)
   - **SSD storage capacity** — The total SSD storage provisioned for the file system (1024 GiB in this lab)
   - **Throughput capacity** — The sustained throughput the file system can deliver (256 MB/s in this lab)
   - **VPC and Subnets** — The networking configuration, which places the file system in the same VPC as your EKS cluster

:::alert{header="Note" type="info"}
FSx for ONTAP allows you to **update the SSD storage capacity** and **throughput capacity** independently and online. You can scale up storage when you need more space, or increase throughput when you need more performance — without any downtime. Additionally, ONTAP's **data tiering** feature automatically moves cold data to capacity pool storage, so you only pay SSD prices for actively accessed data.
:::

##### View the Storage Virtual Machine (SVM)

6. On the file system details page, click on the **Storage virtual machines** tab.

7. You will see the SVM that was created for this lab. Click on the **SVM ID** to view its details.

8. On the SVM details page, note the following:
   - **SVM name** — The name of the SVM (this is the value used in the Trident backend configuration)
   - **Management DNS name** — The management LIF endpoint that Trident uses to communicate with the SVM (this is the `managementLIF` value in your TridentBackendConfig)
   - **NFS DNS name** — The NFS data LIF endpoint that Kubernetes pods use to mount volumes
   - **Protocols** — NFS should be listed as an enabled protocol

:::alert{header="Note" type="info"}
The SVM acts as a logical storage server. It has its own DNS endpoints, credentials (`vsadmin`), and security settings. In a production environment, you could create multiple SVMs on a single file system to isolate different teams or applications — each with their own NFS endpoints and access controls.
:::

##### View the ONTAP volumes

9. From the SVM details page, click on the **Volumes** tab. Alternatively, you can navigate to the **Volumes** section from the left-hand navigation menu in the FSx console.

10. You will see the volumes on your file system. There are two types of volumes to note:
    - **Root volume** (`eksworkshop_svm_root` or similar) — This is the SVM's root volume, created automatically. It is used internally by ONTAP.
    - **Data volume(s)** — These are the volumes where your data is stored. If Trident has already provisioned a volume for your PVC, you will see it listed here with a name like `trident_pvc_...`.

11. Click on a data volume to view its details. Key properties include:
    - **Junction path** — The NFS mount path for this volume (e.g., `/trident_pvc_...`). This is the path that gets mounted inside your Kubernetes pods.
    - **Volume size** — The size of the volume (100 GiB for the model storage PVC)
    - **Volume style** — FLEXVOL (the standard ONTAP volume type)
    - **Tiering policy** — Controls how data is tiered between SSD and capacity pool storage. A policy of `Auto` means infrequently accessed data is automatically moved to capacity pool storage.

::::expand{header="About ONTAP data tiering policies (click to expand)"}

FSx for ONTAP supports several tiering policies:

- **None** — All data stays on SSD storage. Best for latency-sensitive workloads.
- **Snapshot-only** — Only data in snapshots (not the active file system) is tiered to capacity pool. This is the default.
- **Auto** — Infrequently accessed data (including active file system data and snapshot data) is automatically tiered to capacity pool storage. Data is moved back to SSD when accessed again.
- **All** — All data is tiered to capacity pool storage as soon as possible. Best for archival or infrequently accessed data.

For this workshop, the volume uses the **Auto** tiering policy, which provides a good balance between performance and cost.

::::

##### View FSx for ONTAP monitoring and performance

12. Navigate back to the file system details page by clicking on the **File system ID** in the breadcrumb navigation at the top.

13. Scroll to the bottom of the screen and click on the **Monitoring & performance** tab. Here you can view performance metrics for your ONTAP file system across several dimensions:
    - **Summary** — Overall file system health, SSD storage utilization, and capacity pool utilization
    - **SSD IOPS** — Read and write IOPS on the SSD storage tier
    - **Throughput** — Network throughput (data read/written per second)
    - **Network I/O** — Detailed network performance metrics
    - **Capacity pool utilization** — How much data has been tiered to capacity pool storage (relevant when using Auto or All tiering policies)

:::alert{header="Note" type="info"}
The monitoring dashboard is useful for understanding how your workloads interact with the storage system. For example, during model loading (when the Kubernetes Job downloads the Mistral-7B model), you will see a spike in write throughput. During inference (when vLLM reads the model), you will see sustained read IOPS. Over time, if the model data is not accessed frequently, the Auto tiering policy will move it to capacity pool storage, which you can observe in the capacity pool utilization metrics.
:::


## Summary
You have now completed this module. Through this module you have learnt about the FSx for ONTAP storage architecture — how **file systems** contain **SVMs**, which in turn contain **volumes** accessible over **NFS**. You explored key ONTAP features including **snapshots** for point-in-time data protection, **data tiering** for automatic cost optimization between SSD and capacity pool storage, and the ability to independently scale storage capacity and throughput online. These capabilities make FSx for ONTAP a flexible and cost-effective storage backend for Kubernetes workloads like the GenAI inference pipeline you are building in this workshop.
