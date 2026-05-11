---
title : "Create StorageClass and PVC for Dynamic Provisioning"
weight : 120
---
-------------------------------------------------------------

## Overview

With the Trident CSI driver deployed and the backend configured, you can now set up **dynamic provisioning** for your FSx for ONTAP storage. Dynamic provisioning means you do not need to manually create a PersistentVolume (PV) — instead, you define a **StorageClass** that tells Trident how to provision volumes, and then create a **PersistentVolumeClaim (PVC)** that references that StorageClass. Trident automatically creates the underlying ONTAP volume and the corresponding PV when the PVC is applied.

This is simpler than the static provisioning approach (where an admin must manually create the PV with specific volume handles, DNS names, and mount names), and it is the recommended pattern for FSx for ONTAP with Trident.

In this section you will:
1. Apply a StorageClass that uses the `csi.trident.netapp.io` provisioner
2. Apply a PersistentVolumeClaim that requests 100 GiB of ReadWriteMany storage
3. Verify that the StorageClass is created, the PVC is Bound, and the Trident backend is healthy

##### Step 1: Navigate to the working directory

1. Run the below command to change to the correct working directory for the FSx for ONTAP manifests.

::code[cd /home/participant/environment/eks/FSxONTAP]{language=bash showLineNumbers=false showCopyAction=true}

##### Step 2: Create the StorageClass

The StorageClass defines how Trident provisions new ONTAP volumes. Let's review the StorageClass manifest:

1. Run the below command to view the StorageClass manifest (`ontap-storage-class.yaml`):

::code[cat ontap-storage-class.yaml]{language=bash showLineNumbers=false showCopyAction=true}

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# ontap-storage-class.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ontap-nas-sc
provisioner: csi.trident.netapp.io
reclaimPolicy: Retain
parameters:
  backendType: "ontap-nas"
  provisioningType: "thin"
  snapshots: "true"
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
:::

Key points about this StorageClass:
- **provisioner**: `csi.trident.netapp.io` — tells Kubernetes to use the Trident CSI driver
- **reclaimPolicy**: `Retain` — when a PVC is deleted, the underlying ONTAP volume and PV are preserved rather than automatically deleted. This protects the model data from accidental PVC deletion.
- **backendType**: `ontap-nas` — provisions NFS based volumes on the ONTAP backend
- **provisioningType**: `thin` — uses thin provisioning so storage is allocated on demand
- **snapshots**: `true` — enables snapshot support for volumes created by this class
- **allowVolumeExpansion**: `true` — allows you to resize volumes after creation
- **nfsvers=4.1** — uses NFS version 4.1 for improved performance and security

2. Apply the StorageClass manifest:

::code[kubectl apply -f ontap-storage-class.yaml]{language=bash showLineNumbers=false showCopyAction=true}

3. Verify the StorageClass has been created:

::code[kubectl get storageclass ontap-nas-sc]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see the results as below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME           PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
ontap-nas-sc   csi.trident.netapp.io      Retain          Immediate           true                   10s
:::

::::

##### Step 3: Create the PersistentVolumeClaim

Now create a PersistentVolumeClaim (PVC) that references the StorageClass. When you apply this PVC, Trident will automatically provision an ONTAP volume and create the corresponding PV — no manual PV creation is needed.

1. Let's review the PVC manifest (`ontap-pvc.yaml`):

::code[cat ontap-pvc.yaml]{language=bash showLineNumbers=false showCopyAction=true}

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# ontap-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ontap-model-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ontap-nas-sc
  resources:
    requests:
      storage: 100Gi
:::

Key points about this PVC:
- **name**: `ontap-model-claim` — this is the name that the vLLM deployment and model loading Job will reference
- **accessModes**: `ReadWriteMany` — allows multiple pods to mount the volume concurrently, for example this allows both the model loading Job and the vLLM pod can access the data. In produciton, you may be running 100s of pods to mount on this volume.
- **storageClassName**: `ontap-nas-sc` — references the StorageClass you just created, which tells Kubernetes to use Trident for provisioning
- **storage**: `100Gi` — sufficient for the Mistral-7B model (~29 GiB compiled) with room for cache artifacts

2. Apply the PVC manifest:

::code[kubectl apply -f ontap-pvc.yaml]{language=bash showLineNumbers=false showCopyAction=true}

3. Verify that the PVC is **Bound**. When the status shows `Bound`, Trident has successfully provisioned an ONTAP volume and created the PV automatically.

::code[kubectl get pvc ontap-model-claim]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see the results as below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME                STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
ontap-model-claim   Bound    pvc-abcd1234-ef56-7890-abcd-ef1234567890   100Gi      RWX            ontap-nas-sc   15s
:::

::::

:::alert{header="Note" type="info"}
Notice that the **VOLUME** column shows a PV name that was automatically generated by Trident (e.g., `pvc-abcd1234-...`). You did not need to create this PV manually — Trident handled it for you based on the StorageClass and backend configuration.
:::

##### Step 4: Verify the Trident backend is healthy

As a final check, confirm that the Trident backend is still registered and healthy after provisioning the volume.

::code[kubectl get tridentbackendconfig -n trident]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see the results as below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME               BACKEND NAME   BACKEND UUID                           PHASE   STATUS
backend-ontap-nas  fsx-ontap-nas  6ca7c511-649b-4be4-a1eb-c8cdc5496ea9   Bound   Success
:::

::::

The **STATUS** should show `Success` and the **PHASE** should show `Bound`, confirming that Trident is connected to your FSx for ONTAP file system and is ready to serve storage requests.

## Summary

In this section you have created a StorageClass (`ontap-nas-sc`) that configures Trident to provision thin-provisioned NFS volumes on your FSx for ONTAP backend, and a PersistentVolumeClaim (`ontap-model-claim`) that dynamically provisioned a 100 GiB volume. Trident automatically created the PersistentVolume and the underlying ONTAP volume — no manual PV creation was required. This PVC will be used by the model loading Job and the vLLM deployment in the next module to store and access the Mistral-7B model data.
