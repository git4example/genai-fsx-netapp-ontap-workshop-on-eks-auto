---
title : "Module 6 (Optional): Dynamic Provisioning of PVCs using FSx for NetApp"
weight : 600
---

## Module Overview

Throughout this workshop, the storage that backs the model and agent data was provisioned for you, either created ahead of time and **imported** into Kubernetes, or set up during workshop provisioning. This optional module steps back to show the **dynamic provisioning** workflow directly: how the NetApp Astra Trident CSI driver automatically creates a brand-new FSx for NetApp ONTAP volume the moment you submit a `PersistentVolumeClaim`, with no manual PersistentVolume creation.

You will:
1. Review the **StorageClass** that references the Trident provisioner
2. Submit a small throwaway **PersistentVolumeClaim** and watch Trident dynamically provision an ONTAP volume for it
3. Verify the PVC binds and the Trident backend is healthy

This is the recommended storage pattern for application workloads on FSx for ONTAP, and it complements the **volume import** pattern used elsewhere in the workshop for the pre-provisioned model and agent-data volumes.

:::alert{header="This module is optional" type="info"}
Dynamic provisioning is not required to complete the core workshop, since the model and agent volumes are already in place. Work through this module if you want hands-on experience with how Trident provisions storage on demand.
:::
