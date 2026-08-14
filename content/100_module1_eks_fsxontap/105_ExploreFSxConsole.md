---
title : "Explore FSx for NetApp"
weight : 105
---

## Overview

In this module you will explore the pre-provisioned FSx for ONTAP file system for the workshop. If you are new to NetApp ONTAP, this will help you understand the key concepts such as; **file systems**, **Storage Virtual Machines (SVMs)**, **volumes**, **NFS access**, **snapshots**, and **data tiering**. You will also see the storage layer that Trident will connect your Kubernetes workloads to.

##### Understanding FSx for ONTAP architecture

- **File system**: The top-level resource. It defines the SSD storage capacity, throughput, and deployment type (Single-AZ or Multi-AZ). Think of it as the physical storage cluster.
- **Storage Virtual Machine (SVM)**: A logical storage server within the file system. Each SVM has its own NFS/SMB endpoints and credentials. A single file system can host multiple SVMs for multi-tenant isolation.
- **Volume**: A logical data container within an SVM. Volumes are where your data lives. The Trident CSI driver creates FSx NetApp volumes automatically when you dynamically create a PVC.
- **NFS access**: FSx NetApp volumes are accessed over NFS (TCP port 2049). The Trident CSI driver mounts volumes into your Kubernetes pods using NFS v4.1.
- **Snapshots**: Point-in-time, read-only copies of a volume. Snapshots are space-efficient (they only store changed blocks) and can be used for backup, recovery, or cloning.
- **Data tiering**: FSx for NetApp can automatically tier infrequently accessed data from high-performance SSD storage to lower-cost capacity pool storage, reducing costs while keeping data accessible.


##### View your FSx for ONTAP file system in the console

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx/).

2. From the top right hand corner, select the **AWS region** that was provided to you for this lab (i.e. us-west-2), before continuing.

![aws_region](/static/images/aws_region.png)

3. In the FSx console you will see a list of your file systems. You should see the FSx for NetApp ONTAP file system that was pre-provisioned for you as part of the lab. The **File system type** column will show **ONTAP**.

4. Click on the **File system ID** of your FSx for ONTAP file system to view its details.

5. On the file system details page, you can see the key configuration for your ONTAP file system:
   - **Deployment type**: Multi-AZ (the file system spans two Availability Zones for high availability with automatic failover)
   - **SSD storage capacity**: The total SSD storage provisioned for the file system (1024 GiB in this lab)
   - **Throughput capacity**: The sustained throughput the file system can deliver (512 MB/s in this lab)
   - **VPC and Subnets**: The networking configuration, which places the file system across two subnets in the same VPC as your EKS cluster
   - **Preferred subnet**: The AZ where the active file server runs under normal conditions
   - **Standby subnet**: The AZ where the standby file server is ready for automatic failover

:::alert{header="" type="info"}
FSx for NetApp ONTAP Multi-AZ file systems provide **zero RPO** (Recovery Point Objective) and automatic failover between Availability Zones. Data is synchronously replicated between the preferred and standby subnets. The failover is transparent to NFS clients, and Kubernetes pods continue to access the volume without interruption because the DNS endpoints automatically resolve to the active file server. You will trigger a live failover and watch this for yourself in **Module 7**.
:::

##### View the Storage Virtual Machine (SVM)

6. On the file system details page, click on the **Storage virtual machines** tab.

7. You will see the SVM that was created for this lab. Click on the **SVM ID** to view its details.

8. On the SVM details page, the **Summary** panel shows:
   - **SVM name**: The name of the SVM, e.g. `eksworkshop-svm` (this is the value used in the Trident backend configuration)
   - **SVM ID**: The unique identifier, e.g. `svm-0d76a00b3bfedcdb7`
   - **File system ID**: The parent file system


9. Now click on the **Endpoints** tab to see the SVM's access endpoints:
   - **Management DNS name**: The management LIF endpoint that Trident uses to communicate with the SVM
   - **NFS DNS name**: The NFS data LIF endpoint that Kubernetes pods use to mount volumes

The SVM acts as a logical storage server. It has its own DNS endpoints, credentials (`vsadmin`), and security settings. In a production environment, you could create multiple SVMs on a single file system to isolate different data use-cases, each with their own endpoints and access controls.

:::alert{header="" type="info"}
**Notice the shared floating IP -** The **Management DNS name** and **NFS DNS name** resolve to the *same* address (e.g. `198.19.107.123`). This is the Multi-AZ **floating IP**, which lives outside your VPC CIDR and automatically moves to whichever Availability Zone is hosting the active file server. This is exactly what makes failover transparent to your pods, and it is why the Trident StorageClass in this workshop does not pin volumes to a single AZ.

:::

##### View the existing ONTAP volumes

10. From the SVM details page, click on the **Volumes** tab. You should see three volumes, all pre-created for you before the workshop began:

| Volume name | Path | Size | What it holds |
|---|---|---|---|
| `eksworkshop_svm_root` | `/` | 1 GiB | The SVM's internal root volume, created automatically by ONTAP |
| `model` | `/model` | 100 GiB | The Mistral-7B model, pre-loaded during workshop provisioning |
| `agent_shared_data` | `/agent_data` | 10 GiB | The finance and IT datasets used by the AI agents in a later module |

:::alert{header="" type="info"}
**Why the model volume already exists -** The `model` and `agent_shared_data` volumes were created by Terraform script used to deploy the workshop, and the Mistral-7B model was downloaded onto `/model` automatically, to save you 5 minutes during the lab.

Because these FSx volumes already exist, we dont need to use the Trident CSI driver to create them. Instead we use the **static-Provisioning** to use the Trident CSI driver to **import** the existing volume as a Persistent Volumes (PV). then make a claim to that volumes using a PersistentVolumeClaim (PVC).
:::

:::alert{header="" type="warning"}
If you use **Dynamic Provisioning** to create the PVC, the FSx volume names will appear with a machine-generated (i.e. `trident_pvc_8603f702_54b7_4096_b18f_29b82ac2f698`), which are created by Trident CSI driver on demand in response to a PersistentVolumeClaim.
:::

##### View FSx for ONTAP monitoring and performance

11. Navigate back to the file system details page by clicking on the **File system ID** in the breadcrumb navigation at the top.

12. Select the **Monitoring & performance** tab. At the top of this tab you will find four views, selectable via radio buttons: **Summary**, **Storage**, **Performance**, and **CloudWatch alarms**.

13. Leave **Summary** selected. This view shows **Warnings and CloudWatch alarms** followed by a **File system activity** section with the following panels:
    - **Available primary storage capacity**: Free space remaining on the SSD (primary) storage tier, in bytes
    - **Total client throughput**: Bytes per second read and written by NFS clients
    - **Total client IOPS**: Operations per second from NFS clients
    - **Average latency**: Milliseconds per operation
    - **Storage distribution**: A pie chart breaking down how capacity is consumed
    - **Storage efficiency savings**: Space reclaimed by ONTAP deduplication and compression, shown in bytes and as a percentage

14. Use the time-range selector (**1h**, **3h**, **12h**, **1d**, **3d**, **1w**, or **Custom**) above the panels to change the window the graphs cover.

:::alert{header="" type="info"}
Most of these graphs will be flat at zero, because no pods are mounting it yet. After you deploy the vLLM inference pod, you will see sustained read IOPS and client throughput as the model is read from FSx for ONTAP.

**Storage efficiency savings** is the exception and may already show a non-zero value, because ONTAP deduplicates and compresses the model data that was pre-loaded during workshop provisioning.
:::

## Summary

You have now explored the FSx for ONTAP file system in the AWS console and understand the storage architecture: **file systems** contain **SVMs**, which in turn contain **volumes** accessible over **NFS**.
