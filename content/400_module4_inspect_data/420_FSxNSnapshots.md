---
title : "FSx for ONTAP Volume Snapshots"
weight : 420
---

## Overview

In this module you will explore **ONTAP volume snapshots**, one of the most powerful data management features of Amazon FSx for NetApp ONTAP. Snapshots are **point-in-time, read-only copies** of your volume data. They are **space-efficient** because they only consume storage for data that has changed since the snapshot was taken.

FSx for ONTAP provides two complementary snapshot mechanisms:

1. **Automatic ONTAP snapshots** — scheduled by the ONTAP snapshot policy (`default`), configured in the Trident backend. These run on a fixed schedule (hourly, daily, weekly) and are accessible via the `.snapshot` directory on the volume.
2. **Kubernetes VolumeSnapshots** — on-demand, Kubernetes-native snapshots created through the CSI snapshot API. These are managed as Kubernetes objects and can be used to create new PVCs (clones).

In this exercise, you will:
1. Verify that automatic ONTAP snapshots are enabled (configured in Module 1)
2. Create an on-demand Kubernetes VolumeSnapshot of your model data
3. View snapshots and understand recovery options
4. (Optional) View snapshots using the AWS CLI

:::alert{header="How ONTAP Snapshots Work" type="info"}
Unlike traditional backup methods that copy all data, ONTAP snapshots use a **redirect-on-write** mechanism. When data is modified after a snapshot is taken, only the changed blocks consume additional space. This means snapshots are created almost instantly and are extremely storage-efficient — even for large volumes containing AI model data.
:::

---

## Part 1: Automatic ONTAP Snapshots

When you configured the Trident backend in Module 1, the `TridentBackendConfig` included these snapshot defaults:

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
defaults:
  snapshotPolicy: "default"
  snapshotReserve: "10"
  snapshotDir: "true"
:::

This means every volume provisioned by Trident automatically gets:
- **snapshotPolicy: "default"** — automatic hourly (6), daily (2), and weekly (2) snapshots
- **snapshotReserve: "10"** — 10% of volume capacity reserved for snapshot data (10 GiB on a 100 GiB volume — more than sufficient for static model data)
- **snapshotDir: "true"** — the `.snapshot` directory is accessible from within pods

##### Step 1: Verify the snapshot policy on your volume

1. Get the ONTAP volume name from the PersistentVolume:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
ONTAP_VOL_NAME=$(kubectl get pv $(kubectl get pvc ontap-model-claim -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeAttributes.internalName}')
echo "ONTAP Volume Name: $ONTAP_VOL_NAME"
:::

2. Look up the FSx Volume ID and check the snapshot policy:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text)
VOLUME_ID=$(aws fsx describe-volumes --filters Name=file-system-id,Values=$FSX_ID --query "Volumes[?Name=='${ONTAP_VOL_NAME}'].VolumeId" --output text)
aws fsx describe-volumes --volume-ids $VOLUME_ID --query "Volumes[0].OntapConfiguration.{SnapshotPolicy:SnapshotPolicy,SnapshotReserve:SnapshotReserveSize}" --output table
:::

You should see `SnapshotPolicy: default`, confirming that automatic snapshots are active.

##### Step 2: View automatic snapshots from within a pod

Each ONTAP snapshot is accessible through a hidden `.snapshot` directory at the root of the volume.

:::code[]{language=bash showLineNumbers=true showCopyAction=false}
# From within the vLLM pod or any pod with the volume mounted:
ls /work-dir/.snapshot/

# View model files from a specific snapshot
ls /work-dir/.snapshot/hourly.0/Mistral-7B-Instruct-v0.3/
:::

:::alert{header="Note" type="info"}
The `default` policy creates the first hourly snapshot at 5 minutes past the hour. If the `.snapshot` directory is empty, check back after the next hour mark.
:::

---

## Part 2: Kubernetes VolumeSnapshots (On-Demand)

While automatic ONTAP snapshots run on a schedule, **Kubernetes VolumeSnapshots** let you create point-in-time snapshots on demand — for example, before fine-tuning a model or modifying training data. These snapshots are fully Kubernetes-native and managed through `kubectl`.

##### Step 3: Install VolumeSnapshot CRDs

Kubernetes VolumeSnapshots require the **external-snapshotter** Custom Resource Definitions (CRDs) to be installed on the cluster. These CRDs define the `VolumeSnapshotClass`, `VolumeSnapshot`, and `VolumeSnapshotContent` resources. EKS Auto Mode does not install these by default.

:::alert{header="Note" type="info"}
Trident installs its own snapshot CRDs (`tridentsnapshots.trident.netapp.io`), but the **Kubernetes-native** VolumeSnapshot CRDs (`snapshot.storage.k8s.io`) are a separate component maintained by the [kubernetes-csi/external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter) project.
:::

1. Install the VolumeSnapshot CRDs:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
:::

2. Verify the CRDs are installed:

::code[kubectl get crd | grep snapshot.storage.k8s.io]{language=bash showLineNumbers=false showCopyAction=true}

You should see three CRDs:

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
volumesnapshotclasses.snapshot.storage.k8s.io    2026-04-30T00:00:00Z
volumesnapshotcontents.snapshot.storage.k8s.io   2026-04-30T00:00:00Z
volumesnapshots.snapshot.storage.k8s.io          2026-04-30T00:00:00Z
:::

##### Step 4: Create a VolumeSnapshotClass

The `VolumeSnapshotClass` tells Kubernetes which CSI driver to use for snapshots. This is analogous to a `StorageClass` for volumes.

1. Navigate to the working directory and review the manifest:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/FSxONTAP
cat volume-snapshot-class.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: trident-snapshotclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: csi.trident.netapp.io
deletionPolicy: Retain
:::

Key points:
- **driver**: `csi.trident.netapp.io` — uses the Trident CSI driver to create ONTAP snapshots
- **deletionPolicy: Retain** — the underlying ONTAP snapshot is preserved even if the Kubernetes `VolumeSnapshot` object is deleted
- **is-default-class: "true"** — makes this the default snapshot class, so you don't need to specify it in every `VolumeSnapshot`

2. Apply the VolumeSnapshotClass:

::code[kubectl apply -f volume-snapshot-class.yaml]{language=bash showLineNumbers=false showCopyAction=true}

3. Verify it was created:

::code[kubectl get volumesnapshotclass]{language=bash showLineNumbers=false showCopyAction=true}

##### Step 5: Create an on-demand VolumeSnapshot

Now create a snapshot of the `ontap-model-claim` PVC. Trident will create an ONTAP snapshot on the underlying volume via the CSI interface.

1. Create the VolumeSnapshot:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: model-snapshot
spec:
  volumeSnapshotClassName: trident-snapshotclass
  source:
    persistentVolumeClaimName: ontap-model-claim
EOF
:::

2. Wait for the snapshot to be ready:

::code[kubectl get volumesnapshot model-snapshot]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see output similar to below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME             READYTOUSE   SOURCEPVC           SOURCESNAPSHOTCONTENT   RESTORESIZE   SNAPSHOTCLASS           SNAPSHOTCONTENT                                    CREATIONTIME   AGE
model-snapshot   true         ontap-model-claim                           100Gi         trident-snapshotclass   snapcontent-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   10s            15s
:::

::::

When `READYTOUSE` shows `true`, the snapshot has been created successfully on the ONTAP volume.

3. View the snapshot details:

::code[kubectl describe volumesnapshot model-snapshot]{language=bash showLineNumbers=false showCopyAction=true}

##### Step 6: Verify snapshots from within a pod

To confirm that both automatic ONTAP snapshots and the Kubernetes VolumeSnapshot are visible on the volume, deploy a lightweight utility pod and inspect the `.snapshot` directory.

1. Deploy the netshoot pod (mounts the same `ontap-model-claim` PVC):

::code[kubectl apply -f netshoot-fsxn.yaml]{language=bash showLineNumbers=false showCopyAction=true}

2. Wait for the pod to be running:

::code[kubectl wait --for=condition=Ready pod/netshoot-fsxn --timeout=120s]{language=bash showLineNumbers=false showCopyAction=true}

3. List the `.snapshot` directory to see all snapshots on the volume:

::code[kubectl exec -it netshoot-fsxn -- ls -la /work-dir/.snapshot]{language=bash showLineNumbers=false showCopyAction=true}

You should see both the automatic ONTAP snapshots (named `hourly.0`, `daily.0`, etc.) and the Kubernetes VolumeSnapshot (named `snapshot-xxxxxxxx-...`):

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
Defaulted container "netshoot" out of: netshoot, hf-cli, s5cmd
total 16
drwxrwxrwx    4 4294967294 4294967294      4096 Apr 30 07:28 .
drwxrwxrwx    3 4294967294 4294967294      4096 Apr 30 07:16 ..
drwxrwxrwx    3 4294967294 4294967294      4096 Apr 30 07:16 hourly.0
drwxrwxrwx    3 4294967294 4294967294      4096 Apr 30 07:16 snapshot-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
:::

:::alert{header="Note" type="info"}
The `hourly.0` snapshot is created by the ONTAP `default` snapshot policy at 5 minutes past the hour. If you don't see it yet, the first scheduled snapshot hasn't fired. The `snapshot-xxxxxxxx-...` entry is the Kubernetes VolumeSnapshot you created in Step 5. Each snapshot directory contains a full read-only copy of the volume data at that point in time.
:::

4. Verify the model data is intact inside a snapshot:

::code[kubectl exec -it netshoot-fsxn -- sh -c 'ls /work-dir/.snapshot/snapshot-*/Mistral-7B-Instruct-v0.3/']{language=bash showLineNumbers=false showCopyAction=true}

5. Clean up the utility pod when done:

::code[kubectl delete pod netshoot-fsxn]{language=bash showLineNumbers=false showCopyAction=true}

##### Step 7: Create a PVC from the snapshot (clone)

One of the most powerful features of VolumeSnapshots is the ability to create a new PVC from a snapshot. This creates a **space-efficient clone** of the data — ideal for experimentation, A/B testing, or creating isolated environments.

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# Example: Create a new PVC from the snapshot
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-clone
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ontap-nas-sc
  resources:
    requests:
      storage: 100Gi
  dataSource:
    name: model-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
:::

:::alert{header="Key Takeaway" type="success"}
With Kubernetes VolumeSnapshots, you can take on-demand snapshots before any experiment and instantly create clones from those snapshots. The clones share unchanged data blocks with the original volume (ONTAP FlexClone), so they consume minimal additional storage. This is ideal for AI/ML workflows where you want to test different model configurations without duplicating the entire dataset.
:::

---

## Part 3: Check Snapshot policy config in the FSx Console

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx).

2. Click on your FSx for ONTAP file system.

3. Select the **Volumes** tab and click on the Trident-provisioned volume (its name starts with `trident_pvc_...`).

4. In the volume details, you can verify:
   - **Snapshot policy**: `default` (automatic snapshots enabled)
   - The volume is actively being protected by both automatic ONTAP snapshots and any Kubernetes VolumeSnapshots you created

---

## Part 4: (Optional) Managing Snapshots via AWS CLI

You can also view and manage the snapshot policy on Trident-provisioned volumes using the AWS CLI. While the Kubernetes-native approach (Parts 1–2) is preferred for on-demand snapshots, the AWS CLI is useful for administrative tasks like changing the snapshot policy.

##### View the current snapshot policy

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
ONTAP_VOL_NAME=$(kubectl get pv $(kubectl get pvc ontap-model-claim -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeAttributes.internalName}')
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text)
VOLUME_ID=$(aws fsx describe-volumes --filters Name=file-system-id,Values=$FSX_ID --query "Volumes[?Name=='${ONTAP_VOL_NAME}'].VolumeId" --output text)

aws fsx describe-volumes --volume-ids $VOLUME_ID \
  --query "Volumes[0].OntapConfiguration.{Name:Name,SnapshotPolicy:SnapshotPolicy,SizeMB:SizeInMegabytes,StorageEfficiency:StorageEfficiencyEnabled}" \
  --output table
:::

##### Change the snapshot policy

If you need to change the snapshot policy (for example, to disable automatic snapshots or switch to a different schedule), you can update the volume:

:::code[]{language=bash showLineNumbers=true showCopyAction=false}
# Switch to default-1weekly (fewer weekly snapshots)
aws fsx update-volume --volume-id $VOLUME_ID \
  --ontap-configuration '{"SnapshotPolicy":"default-1weekly"}'

# Disable automatic snapshots
aws fsx update-volume --volume-id $VOLUME_ID \
  --ontap-configuration '{"SnapshotPolicy":"none"}'

# Re-enable default policy
aws fsx update-volume --volume-id $VOLUME_ID \
  --ontap-configuration '{"SnapshotPolicy":"default"}'
:::

:::alert{header="Note" type="info"}
Modifying a Trident-managed volume's snapshot policy via the FSx API is safe and does not interfere with Trident's operation. However, the preferred approach is to configure the snapshot policy in the Trident backend configuration so that all new volumes are provisioned with the correct policy from the start.
:::

---

## Summary

In this section, you have:
- Verified that automatic ONTAP snapshots are enabled via the Trident backend configuration (`snapshotPolicy: "default"`, `snapshotReserve: "10"`)
- Created a `VolumeSnapshotClass` for Kubernetes-native on-demand snapshots
- Created an on-demand `VolumeSnapshot` of the model data PVC using `kubectl`
- Learned how to create space-efficient clones from snapshots using `dataSource`
- Viewed snapshots in the FSx console
- (Optional) Managed snapshot policies via the AWS CLI

FSx for ONTAP provides both automatic scheduled snapshots and Kubernetes-native on-demand snapshots through Trident's CSI integration. Together, these give you comprehensive data protection for AI/ML workloads — automatic snapshots for ongoing protection, and on-demand snapshots for point-in-time captures before experiments.
