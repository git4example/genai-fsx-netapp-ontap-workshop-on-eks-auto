---
title : "Module 1: Configure FSx for NetApp storage for model hosting"
weight : 100
---

## Module Overview

In this workshop the open-source **Mistral-7B-Instruct** AI model (LLM) is stored on an Amazon FSx for NetApp ONTAP volume. This FSx for NetApp volume is mounted as a persistent volume by the vLLM inference engine. The vLLM inference engine reads the model from the FSx volume, loads it into memory, and then serves that model to the Generative AI chatbot application.

In this module you will configure an FSx for NetApp instance to be used as the persistent storage layer within an Amazon EKS cluster, by deploying the **NetApp Astra Trident CSI driver** within the Amazon EKS cluster and connecting it to pre-provisioned FSx for NetApp ONTAP file system via a `TridentBackendConfig`. This establishes the storage foundation that the model and agent volumes are served from.

:::alert{header="Want to see dynamic provisioning hands-on?" type="info"}
In this module you will **import** two ONTAP volumes that were pre-provisioned for you. If you'd also like hands-on experience creating a `StorageClass` and watching Trident **dynamically provision** a brand-new ONTAP volume from a `PersistentVolumeClaim`, work through the optional **"Dynamic Provisioning of PVCs using FSx for NetApp"** module later in the workshop.
:::

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


**Two ways Trident connects a PVC to ONTAP storage:**

Trident supports both patterns, and this workshop uses each one:

**1. Volume import** — binding a PVC to an ONTAP volume that *already exists*. This is what the workshop uses for the `model` and `agent_shared_data` volumes, which were pre-provisioned by Terraform. It is also the common enterprise pattern: storage teams frequently create and govern ONTAP volumes ahead of time, then hand them to Kubernetes teams to consume. The PVC carries annotations naming the existing volume, and Trident creates the PersistentVolume around it instead of allocating new storage.

**2. Dynamic provisioning** — Trident creates a brand-new ONTAP volume on demand:

1. An administrator deploys the Trident CSI driver and creates a `TridentBackendConfig` that connects Trident to the FSx for ONTAP file system and SVM.
2. An administrator creates a `StorageClass` that references the Trident provisioner and the ONTAP backend.
3. A user submits a `PersistentVolumeClaim` (PVC) referencing the StorageClass. Trident automatically provisions a new ONTAP volume on the file system and creates the corresponding PersistentVolume — no manual PV creation is needed.
4. Pods reference the PVC to mount the dynamically provisioned volume at the desired path (e.g., `/work-dir`).

Either way, administrators never hand-write PersistentVolume definitions or look up storage-specific details like volume handles or DNS names — Trident handles the volume lifecycle. You can try dynamic provisioning yourself in the optional **Dynamic Provisioning** module.

::::
