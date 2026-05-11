---
title : "Configure storage for model hosting using Amazon FSx for NetApp ONTAP"
weight : 100
---

## Module Overview

In this workshop the **Mistral-7B-Instruct** model is stored on an Amazon FSx for NetApp ONTAP file system, which the vLLM container will use for the Generative AI ChatBot application.

In this module you will deploy and integrate the **NetApp Astra Trident CSI driver** with your Amazon EKS cluster, configure a **TridentBackendConfig** to connect to the pre-provisioned FSx for ONTAP file system, create a **StorageClass** for dynamic provisioning, and create a **PersistentVolumeClaim** to provision an ONTAP volume for model storage. You will learn about Kubernetes storage concepts such as CSI drivers, StorageClasses, PersistentVolumeClaims, and dynamic provisioning with Trident. The infrastructure for this module comprises an Amazon EKS cluster with EC2 worker nodes and an Amazon FSx for NetApp ONTAP file system.


![fsxn-architecture](/static/images/fsxn-architecture.png)
<!-- TODO: Replace with FSx for ONTAP architecture diagram -->

---

# Additional Reading

This section covers Kubernetes storage concepts and how they integrate with FSx for NetApp ONTAP through the Trident CSI driver. Expand below to learn more.

::::expand{header="Click here to read about Kubernetes storage concepts and FSx for ONTAP integration"}

#### Kubernetes storage concepts, and integration with FSx for NetApp ONTAP

**CSI driver** - The Container Storage Interface (CSI) is a standard for exposing block and file storage systems to Container Orchestration Systems like Kubernetes, allowing Kubernetes to natively manage persistent storage for containerized applications.

**NetApp Astra Trident** is an open-source CSI driver that provides dynamic storage provisioning for Kubernetes using NetApp storage backends, including Amazon FSx for NetApp ONTAP. Trident integrates with FSx for ONTAP to automatically create and manage ONTAP volumes when Kubernetes users request persistent storage. It connects to the FSx for ONTAP Storage Virtual Machine (SVM) via a `TridentBackendConfig` resource and provisions NFS-backed volumes on demand.

**TridentBackendConfig** - A custom Kubernetes resource that tells the Trident CSI driver how to connect to a specific storage backend. For FSx for ONTAP, the TridentBackendConfig specifies the SVM management LIF endpoint, the SVM name, and the credentials needed to communicate with the ONTAP file system. Once created, Trident registers the backend and can provision volumes from it.

**StorageClass** - A StorageClass provides a way for EKS administrators to describe the "classes" of storage they offer. Different storage classes might map to different storage types (i.e. different AWS Storage Service types such as Amazon FSx, or Amazon EBS, or Amazon EFS), or to backup policies. Kubernetes is unopinionated about what these storage classes represent. In this workshop, the StorageClass uses the `csi.trident.netapp.io` provisioner to dynamically create ONTAP NAS volumes.

**Persistent volume (PV)** - is a storage volume mapped to an EKS cluster. With Trident-based dynamic provisioning, PVs are automatically created by the CSI driver when a PersistentVolumeClaim is submitted. A Persistent Volume's lifecycle goes beyond the life of a Pod, making it an ideal choice for Pods that require access to shared data which needs to be persisted beyond the life of the Pods that use the storage volume.

**Persistent volume claim (PVC)** - Persistent Volume Claim (PVC) is the request for storage volume by a user. Claims can request specific size and access modes (e.g., they can be mounted ReadWriteOnce, ReadOnlyMany or ReadWriteMany). In this workshop, the PVC uses `ReadWriteMany` access mode so that both the model loading Job and the vLLM inference pod can mount the volume concurrently.


**Dynamic provisioning with Trident:**

With Trident and FSx for ONTAP, this workshop uses **dynamic provisioning** — the recommended approach for ONTAP-backed storage in Kubernetes. The workflow is:

1. An administrator deploys the Trident CSI driver and creates a `TridentBackendConfig` that connects Trident to the FSx for ONTAP file system and SVM.
2. An administrator creates a `StorageClass` that references the Trident provisioner and the ONTAP backend.
3. A user submits a `PersistentVolumeClaim` (PVC) referencing the StorageClass. Trident automatically provisions a new ONTAP volume on the file system and creates the corresponding PersistentVolume — no manual PV creation is needed.
4. Pods reference the PVC to mount the dynamically provisioned volume at the desired path (e.g., `/work-dir`).

This eliminates the need for administrators to manually create PersistentVolume definitions or look up storage-specific details like volume handles or DNS names. Trident handles the full lifecycle of the volume, including creation, mounting, and deletion.

::::
