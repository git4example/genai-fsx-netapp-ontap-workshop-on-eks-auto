---
title : "Dynamic Provisioning of PVCs using FSx for NetApp"
weight : 810
---
-------------------------------------------------------------

## Overview

With the Trident CSI driver deployed and the backend configured, you can now set up **dynamic provisioning** for your FSx for ONTAP storage. Dynamic provisioning means you do not need to manually create a PersistentVolume (PV). Instead, you define a **StorageClass** that tells Trident how to provision volumes, and then create a **PersistentVolumeClaim (PVC)** that references that StorageClass. Trident automatically creates the underlying ONTAP volume and the corresponding PV when the PVC is applied.

This is simpler than the static provisioning approach (where an admin must manually create the PV with specific volume handles, DNS names, and mount names), and it is the recommended pattern for FSx for ONTAP with Trident.

In this section you will:
1. Apply a StorageClass that uses the `csi.trident.netapp.io` provisioner
2. Apply a small demo PersistentVolumeClaim and watch Trident dynamically provision an ONTAP volume for it
3. Verify that the StorageClass is created, the PVC is Bound, and the Trident backend is healthy

:::alert{header="About the model volume" type="info"}
The **Mistral-7B model volume** was **pre-provisioned and pre-loaded during workshop setup**, so the model data is already on FSx for ONTAP, so you won't wait for a multi-gigabyte download in the next module. In this section you'll use a small **throwaway demo volume** to learn how Trident dynamic provisioning works, without touching the model volume. See the callout at the end of this page for details on how the model volume is wired.
:::

##### Step 1: Navigate to the working directory

1. Run the below command to change to the correct working directory for the FSx for ONTAP manifests.

::code[cd /home/participant/environment/eks/FSxONTAP]{language=bash showLineNumbers=false showCopyAction=true}

##### Step 2: Create the StorageClass

The StorageClass defines how Trident provisions new ONTAP volumes. Let's review the StorageClass manifest:

1. Review the StorageClass manifest:

::::expand{header="Click to view ontap-storage-class.yaml"}

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
volumeBindingMode: Immediate
allowedTopologies:
  - matchLabelExpressions:
      - key: topology.kubernetes.io/zone
        values:
          - us-west-2a
          - us-west-2b
          - us-west-2c
          - us-west-2d
mountOptions:
  - nfsvers=4.1
:::

::::

Key points about this StorageClass:
- **provisioner**: `csi.trident.netapp.io`, which tells Kubernetes to use the Trident CSI driver
- **reclaimPolicy**: `Retain`. When a PVC is deleted, the underlying ONTAP volume and PV are preserved rather than automatically deleted. This protects the model data from accidental PVC deletion.
- **backendType**: `ontap-nas`, which provisions NFS based volumes on the ONTAP backend
- **provisioningType**: `thin`, which uses thin provisioning so storage is allocated on demand
- **snapshots**: `true`, which enables snapshot support for volumes created by this class
- **allowVolumeExpansion**: `true`, which allows you to resize volumes after creation
- **nfsvers=4.1**: uses NFS version 4.1 for improved performance and security
- **volumeBindingMode + allowedTopologies**: FSx for ONTAP's NFS endpoint is reachable from every Availability Zone, so Trident advertises no zone topology. With `Immediate` binding the CSI provisioner needs an explicit zone list to satisfy its accessibility requirement; without it, PVCs fail with *"no available topology found"*. The zones are populated for your region in the next step.

2. Apply the StorageClass manifest. You already created this in Module 1, so `kubectl apply` is a no-op here, and is repeated so this module stands on its own:

::code[kubectl apply -f ontap-storage-class.yaml]{language=bash showLineNumbers=false showCopyAction=true}

3. Verify the StorageClass has been created:

::code[kubectl get storageclass ontap-nas-sc]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see the results as below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME           PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
ontap-nas-sc   csi.trident.netapp.io      Retain          Immediate           true                   10s
:::

::::

##### Step 3: Create a demo PersistentVolumeClaim (dynamic provisioning)

Now create a small PersistentVolumeClaim (PVC) that references the StorageClass. When you apply this PVC, Trident **dynamically provisions** a brand-new ONTAP volume and creates the corresponding PV automatically, with no manual PV creation needed. This is the core pattern you'll use for any application storage on FSx for ONTAP.

1. Review the demo PVC manifest:

::::expand{header="Click to view demo-pvc.yaml"}

::code[cat demo-pvc.yaml]{language=bash showLineNumbers=false showCopyAction=true}

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# demo-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ontap-nas-sc
  resources:
    requests:
      storage: 1Gi
:::

::::

Key points about this PVC:
- **name**: `demo-claim`, a throwaway claim used purely to demonstrate dynamic provisioning
- **accessModes**: `ReadWriteMany`, which allows multiple pods to mount the volume concurrently. In production, you may have 100s of pods mounting the same volume.
- **storageClassName**: `ontap-nas-sc`, which references the StorageClass you just created, which tells Kubernetes to use Trident for provisioning
- **storage**: `1Gi`, small because this volume is only for demonstration

2. Apply the PVC manifest:

::code[kubectl apply -f demo-pvc.yaml]{language=bash showLineNumbers=false showCopyAction=true}

3. Verify that the PVC is **Bound**. When the status shows `Bound`, Trident has successfully provisioned an ONTAP volume and created the PV automatically.

::code[kubectl get pvc demo-claim]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see the results as below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME         STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
demo-claim   Bound    pvc-abcd1234-ef56-7890-abcd-ef1234567890   1Gi        RWX            ontap-nas-sc   15s
:::

::::

:::alert{header="Note" type="info"}
Notice that the **VOLUME** column shows a PV name that was automatically generated by Trident (e.g., `pvc-abcd1234-...`). You did not need to create this PV manually; Trident handled it for you based on the StorageClass and backend configuration.
:::

4. This demo volume has served its purpose. You can delete it now (the model volume you'll use in the next module is separate and untouched):

::code[kubectl delete pvc demo-claim]{language=bash showLineNumbers=false showCopyAction=true}

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

::::expand{header="How the Mistral-7B model volume is wired (pre-provisioned + pre-loaded)"}

You just used **dynamic provisioning** for the demo volume, where Trident created a fresh ONTAP volume on demand. The **model volume** works a little differently:

- During Terraform provisioning, a dedicated ONTAP volume named **`model`** (junction path `/model`) was created ahead of time.
- During workshop setup, that volume was **imported** into Kubernetes via a PVC named `ontap-model-claim`, and the **pre-compiled Mistral-7B-Instruct-v0.3 model was downloaded onto it**.
- The import is driven by three annotations on the PVC:

:::code[]{language=yaml showLineNumbers=false showCopyAction=false}
annotations:
  trident.netapp.io/importOriginalName: "model"      # existing volume name
  trident.netapp.io/importBackendUUID: "<uuid>"      # backend UUID, not its name
  trident.netapp.io/importNoRename: "true"           # keep the name "model"
:::

  `importBackendUUID` takes the backend's **UUID**, which is generated when the backend registers, so the manifest is templated at deploy time rather than checked in with a fixed value. And without `importNoRename`, Trident would rename the ONTAP volume to `trident_pvc_<uuid>` on import, discarding the meaningful name.

:::alert{header="Verifying an import actually happened" type="info"}
Trident **silently ignores** annotation keys it does not recognise, so a typo produces no warning and no error. The PVC still reaches `Bound`, but against a brand-new empty volume created by dynamic provisioning. The only reliable check is the ONTAP volume name recorded on the PV:

```bash
kubectl get pv -o custom-columns='PV:.metadata.name,CLAIM:.spec.claimRef.name,ONTAP_VOLUME:.spec.csi.volumeAttributes.internalName'
```

This lists every volume at once, so you can compare them side by side:

```
PV                                         CLAIM               ONTAP_VOLUME
pvc-c2b8f1b9-9622-4c5c-968f-7f9602e0f3b3   ontap-model-claim   model
pvc-d7756871-2a22-4937-ba50-98e31facf05a   agent-shared-data   agent_shared_data
pvc-2dafb4be-71ee-42e4-9d57-aca021d18c5d   demo-claim          trident_pvc_2dafb4be_71ee_42e4_9d57_aca021d18c5d
```

The contrast is the whole lesson on this page. `ontap-model-claim` shows `model`, the pre-provisioned volume it **imported**. `demo-claim` shows a machine-generated `trident_pvc_<uuid>` name, the volume Trident **created** for it. If an import silently failed, its row would show a `trident_pvc_*` name too.
:::
- This is why, in the next module, the vLLM pod can start serving almost immediately, because the model data is already on FSx for ONTAP, so there's no multi-gigabyte download to wait for.

**Dynamic provisioning** (demo volume) and **volume import** (model volume) are the two ways Trident connects Kubernetes PVCs to ONTAP storage. You'll see the import pattern again in the Agentic AI module, where a pre-provisioned shared volume holds the finance and IT Ops data.

::::

## Summary

In this section you created a StorageClass (`ontap-nas-sc`) that configures Trident to provision thin-provisioned NFS volumes on your FSx for ONTAP backend, and used a demo PersistentVolumeClaim to watch Trident **dynamically provision** an ONTAP volume, automatically creating the PersistentVolume and the underlying ONTAP volume with no manual PV creation. The Mistral-7B model volume was pre-provisioned and pre-loaded during workshop setup (via the volume-import pattern), so it's ready for the vLLM deployment in the next module without any download wait.
