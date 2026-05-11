---
title : "Explore FSx for ONTAP in the AWS Console"
weight : 105
---

## Overview

Before deploying the Trident CSI driver and configuring dynamic provisioning, let's first explore the pre-provisioned FSx for ONTAP file system in the AWS console. This will help you understand the key ONTAP concepts — **file systems**, **Storage Virtual Machines (SVMs)**, **volumes**, **NFS access**, **snapshots**, and **data tiering** — and establish a baseline view of the storage before Trident creates any volumes.

##### Understanding FSx for ONTAP architecture

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
   - **Deployment type** — Multi-AZ (the file system spans two Availability Zones for high availability with automatic failover)
   - **SSD storage capacity** — The total SSD storage provisioned for the file system (1024 GiB in this lab)
   - **Throughput capacity** — The sustained throughput the file system can deliver (256 MB/s in this lab)
   - **VPC and Subnets** — The networking configuration, which places the file system across two subnets in the same VPC as your EKS cluster
   - **Preferred subnet** — The AZ where the active file server runs under normal conditions
   - **Standby subnet** — The AZ where the standby file server is ready for automatic failover

:::alert{header="Note" type="info"}
FSx for ONTAP Multi-AZ file systems provide **zero RPO** (Recovery Point Objective) and automatic failover between Availability Zones. Data is synchronously replicated between the preferred and standby subnets, so no data is lost during a failover event. The failover is transparent to NFS clients — Kubernetes pods continue to access the volume without interruption because the DNS endpoints automatically resolve to the active file server. You will explore this failover capability in a later module.
:::

##### View the Storage Virtual Machine (SVM)

6. On the file system details page, click on the **Storage virtual machines** tab.

7. You will see the SVM that was created for this lab. Click on the **SVM ID** to view its details.

8. On the SVM details page, note the following:
   - **SVM name** — The name of the SVM (this is the value that will be used in the Trident backend configuration)
   - **Management DNS name** — The management LIF endpoint that Trident will use to communicate with the SVM
   - **NFS DNS name** — The NFS data LIF endpoint that Kubernetes pods will use to mount volumes
   - **Protocols** — NFS should be listed as an enabled protocol

:::alert{header="Note" type="info"}
The SVM acts as a logical storage server. It has its own DNS endpoints, credentials (`vsadmin`), and security settings. In a production environment, you could create multiple SVMs on a single file system to isolate different teams or applications — each with their own NFS endpoints and access controls.
:::

##### View the existing ONTAP volumes

9. From the SVM details page, click on the **Volumes** tab. Alternatively, you can navigate to the **Volumes** section from the left-hand navigation menu in the FSx console.

10. At this point, you should only see the **root volume** (e.g., `eksworkshop_svm_root` or similar). This is the SVM's internal root volume, created automatically by ONTAP. There are no data volumes yet — those will be created dynamically by Trident when you apply a PersistentVolumeClaim in the next sections.

:::alert{header="Remember this view" type="warning"}
Take note of the current state: only the root volume exists. After you deploy Trident and create a PVC in the upcoming steps, you will return to this console to see the dynamically provisioned volume appear here. This before-and-after comparison demonstrates how Trident automates ONTAP volume creation through Kubernetes.
:::

##### View FSx for ONTAP monitoring and performance

11. Navigate back to the file system details page by clicking on the **File system ID** in the breadcrumb navigation at the top.

12. Scroll to the bottom of the screen and click on the **Monitoring & performance** tab. Here you can view performance metrics for your ONTAP file system across several dimensions:
    - **Summary** — Overall file system health, SSD storage utilization, and capacity pool utilization
    - **SSD IOPS** — Read and write IOPS on the SSD storage tier
    - **Throughput** — Network throughput (data read/written per second)
    - **Network I/O** — Detailed network performance metrics
    - **Capacity pool utilization** — How much data has been tiered to capacity pool storage

:::alert{header="Note" type="info"}
The monitoring dashboard is currently quiet since no workloads are running yet. After you deploy the model loading Job and vLLM inference pod in later modules, you will see activity in these metrics — write throughput during model download, and sustained read IOPS during inference.
:::

## Summary

You have now explored the FSx for ONTAP file system in the AWS console and understand the storage architecture — **file systems** contain **SVMs**, which in turn contain **volumes** accessible over **NFS**. Currently only the root volume exists. In the next sections, you will deploy the Trident CSI driver and create a PVC, which will dynamically provision a new ONTAP volume that you can verify back in this console.
