---
title : "FSx for ONTAP Volume Snapshots"
weight : 520
hidden : true
---

## Overview

In this module you will explore **ONTAP volume snapshots**, one of the most powerful data management features of Amazon FSx for NetApp ONTAP. Snapshots are **point-in-time, read-only copies** of your volume data. They are **space-efficient** because they only consume storage for data that has changed since the snapshot was taken.

FSx for ONTAP provides two complementary snapshot mechanisms:

1. **Automatic ONTAP snapshots**: scheduled by the ONTAP snapshot policy (`default`), configured in the Trident backend. These run on a fixed schedule (hourly, daily, weekly) and are accessible via the `.snapshot` directory on the volume.
2. **Kubernetes VolumeSnapshots**: on-demand, Kubernetes-native snapshots created through the CSI snapshot API. These are managed as Kubernetes objects and can be used to create new PVCs (clones).

In this exercise, you will:
1. Create an on-demand Kubernetes VolumeSnapshot of your model data (always visible immediately)
2. Verify that automatic ONTAP snapshots are enabled (configured in **Module 1: Configure FSx for NetApp storage for model hosting**)
3. View snapshots and understand recovery options
4. (Optional) View snapshots using the AWS CLI

:::alert{header="How ONTAP Snapshots Work" type="info"}
Unlike traditional backup methods that copy all data, ONTAP snapshots use a **redirect-on-write** mechanism. When data is modified after a snapshot is taken, only the changed blocks consume additional space. This means snapshots are created almost instantly and are extremely storage-efficient, even for large volumes containing AI model data.
:::

---

## Part 1: Create an On-Demand Kubernetes VolumeSnapshot

Kubernetes VolumeSnapshots let you create point-in-time snapshots on demand, for example before fine-tuning a model or modifying training data. These snapshots are fully Kubernetes-native, managed through `kubectl`, and are visible immediately after creation.

##### Step 1: Install the VolumeSnapshot CRDs

Kubernetes VolumeSnapshots require the **external-snapshotter** Custom Resource Definitions (CRDs) to be installed on the cluster. These CRDs define the `VolumeSnapshotClass`, `VolumeSnapshot`, and `VolumeSnapshotContent` resources. EKS Auto Mode does not install these by default.

:::alert{header="Note" type="info"}
Trident installs its own internal snapshot CRDs (`tridentsnapshots.trident.netapp.io`), but the **Kubernetes-native** VolumeSnapshot CRDs and controller (`snapshot.storage.k8s.io`) are a separate cluster-wide component maintained by the [kubernetes-csi/external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter) project. Both pieces are required: the CRDs (Step 1) **and** the standalone snapshot-controller Deployment (Step 2). Without the controller, a `VolumeSnapshot` you create will sit forever with empty `READYTOUSE` and `SNAPSHOTCONTENT` columns because nothing is translating it into a `VolumeSnapshotContent`.
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

##### Step 2: Install the snapshot-controller Deployment

The CRDs alone do not process snapshot requests; they only define the resource types. The **standalone snapshot-controller** is a cluster-wide Deployment that watches `VolumeSnapshot` objects and creates the corresponding `VolumeSnapshotContent` objects, which Trident's `csi-snapshotter` sidecar then turns into real ONTAP snapshots. Both pieces are required.

1. Install the snapshot-controller RBAC and Deployment:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
:::

2. Scale the Deployment to a single replica. The upstream manifest defaults to two replicas for leader-elected high availability. For this workshop we only need one, which keeps resource usage minimal on the workshop nodes and the leader-election overhead is unnecessary at this scale.

::code[kubectl -n kube-system scale deploy/snapshot-controller --replicas=1]{language=bash showLineNumbers=false showCopyAction=true}

3. Wait for the rollout to complete:

::code[kubectl -n kube-system rollout status deploy/snapshot-controller]{language=bash showLineNumbers=false showCopyAction=true}

4. Confirm the snapshot-controller pod is Running:

::code[kubectl -n kube-system get pods -l app.kubernetes.io/name=snapshot-controller]{language=bash showLineNumbers=false showCopyAction=true}

You should see one pod with `1/1 Running`:

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
NAME                                   READY   STATUS    RESTARTS   AGE
snapshot-controller-XXXXXXXXXX-XXXXX   1/1     Running   0          30s
:::

:::alert{header="Troubleshooting tip" type="info"}
If a `VolumeSnapshot` you create later in this module stays with empty `READYTOUSE` and `SNAPSHOTCONTENT` columns and `kubectl describe volumesnapshot <name>` shows no `Events` and no `Status` block, the snapshot-controller is the first thing to check. Run `kubectl -n kube-system logs deploy/snapshot-controller --tail=200` and look for either RBAC errors or `the server could not find the requested resource` errors against `volumesnapshotcontents` (which would indicate a missing CRD from Step 1).
:::

##### Step 3: Create a VolumeSnapshotClass

The `VolumeSnapshotClass` tells Kubernetes which CSI driver to use for snapshots. This is analogous to a `StorageClass` for volumes.

1. Navigate to the working directory:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/FSxONTAP
:::

::::expand{header="Optional: click to view the volume-snapshot-class.yaml manifest"}

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
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

::::

Key points:
- **driver**: `csi.trident.netapp.io`, which uses the Trident CSI driver to create ONTAP snapshots
- **deletionPolicy: Retain**: the underlying ONTAP snapshot is preserved even if the Kubernetes `VolumeSnapshot` object is deleted
- **is-default-class: "true"**: makes this the default snapshot class, so you don't need to specify it in every `VolumeSnapshot`

2. Apply the VolumeSnapshotClass:

::code[kubectl apply -f volume-snapshot-class.yaml]{language=bash showLineNumbers=false showCopyAction=true}

3. Verify it was created:

::code[kubectl get volumesnapshotclass]{language=bash showLineNumbers=false showCopyAction=true}

##### Step 4: Create an on-demand VolumeSnapshot

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

##### Step 5: Verify snapshots from within a pod

To confirm that both automatic ONTAP snapshots and the Kubernetes VolumeSnapshot are visible on the volume, inspect the `.snapshot` directory from a pod that mounts it.

1. The `netshoot-fsxn` pod already mounts the `ontap-model-claim` PVC, so confirm it is still running:

::code[kubectl get pod netshoot-fsxn]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="Not running? Click to start it"}

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl apply -f netshoot-fsxn.yaml
kubectl wait --for=condition=Ready pod/netshoot-fsxn --timeout=300s
:::

::::

2. List the `.snapshot` directory to see all snapshots on the volume:

::code[kubectl exec -it netshoot-fsxn -- ls -la /work-dir/.snapshot]{language=bash showLineNumbers=false showCopyAction=true}

You should see both the automatic ONTAP snapshots (named `hourly.<timestamp>`) and the Kubernetes VolumeSnapshot (named `snapshot-<uuid>`):

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
Defaulted container "netshoot" out of: netshoot, hf-cli, s5cmd
total 24K
drwxrwxrwx    6 4294967294 4294967294    4.0K Jul  1 07:49 .
drwxrwxrwx    3 4294967294 4294967294    4.0K Jul  1 05:04 ..
drwxrwxrwx    3 4294967294 4294967294    4.0K Jul  1 05:04 hourly.2026-07-01_0505
drwxrwxrwx    3 4294967294 4294967294    4.0K Jul  1 05:04 hourly.2026-07-01_0605
drwxrwxrwx    3 4294967294 4294967294    4.0K Jul  1 05:04 hourly.2026-07-01_0705
drwxrwxrwx    3 4294967294 4294967294    4.0K Jul  1 05:04 snapshot-e76743b6-2a87-4c67-86ce-27a4e21eecf8
:::

:::alert{header="Note" type="info"}
The `hourly.<date>_<time>` snapshots are created by the ONTAP `default` snapshot policy at 5 minutes past each hour. If you don't see them yet, the first scheduled snapshot hasn't fired (wait until the next hour mark). The `snapshot-<uuid>` entry is the Kubernetes VolumeSnapshot you created in Step 4. Each snapshot directory contains a full read-only copy of the volume data at that point in time.
:::

3. Verify the model data is intact inside a snapshot:

::code[kubectl exec -it netshoot-fsxn -- sh -c 'ls /work-dir/.snapshot/snapshot-*/Mistral-7B-Instruct-v0.3/']{language=bash showLineNumbers=false showCopyAction=true}

##### Step 6: Create a PVC from the snapshot (clone)

One of the most powerful features of VolumeSnapshots is the ability to create a new PVC from a snapshot. This creates a **space-efficient clone** of the data, ideal for experimentation, A/B testing, or creating isolated environments.

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

## Part 2: Automatic ONTAP Snapshots

In addition to on-demand Kubernetes VolumeSnapshots, FSx for ONTAP also provides **automatic scheduled snapshots** via the ONTAP snapshot policy. When you configured the Trident backend in **Module 1**, the `TridentBackendConfig` included these snapshot defaults:

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
defaults:
  snapshotPolicy: "default"
  snapshotReserve: "10"
  snapshotDir: "true"
:::

This means every volume **provisioned by Trident** automatically gets:
- **snapshotPolicy: "default"**: automatic hourly (6), daily (2), and weekly (2) snapshots
- **snapshotReserve: "10"**: 10% of volume capacity reserved for snapshot data
- **snapshotDir: "true"**: the `.snapshot` directory is accessible from within pods

:::alert{header="These defaults apply to provisioned volumes, not imported ones" type="info"}
The `defaults` block above only applies to volumes Trident **creates**. The model volume you are inspecting was pre-provisioned by Terraform and **imported** by Trident, so it keeps the snapshot policy and reserve it was created with: `default` policy (set in Terraform) and ONTAP's standard 5% reserve rather than 10%.

That difference is worth noticing: when you import existing storage, the storage team's settings win. It is one of the practical trade-offs between importing pre-provisioned volumes and letting Trident provision them.
:::

##### Step 7: Verify the snapshot policy on your volume

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

You should see `SnapshotPolicy: default`, confirming that automatic snapshots are active. These are the same `hourly.*` snapshots you observed in the `.snapshot` directory in Step 5.

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

##### Clean up

No later module needs the `netshoot-fsxn` utility pod, so you can delete it now that the snapshot exercises are complete:

::code[kubectl delete pod netshoot-fsxn]{language=bash showLineNumbers=false showCopyAction=true}

---

## Summary

In this section, you have:
- Created a `VolumeSnapshotClass` for Kubernetes-native on-demand snapshots
- Created an on-demand `VolumeSnapshot` of the model data PVC using `kubectl` (immediately visible)
- Verified snapshots from within a pod using the `.snapshot` directory
- Learned how to create space-efficient clones from snapshots using `dataSource`
- Verified that automatic ONTAP snapshots are enabled on the model volume (`snapshotPolicy: "default"`), and learned that Trident's backend `defaults` apply to volumes it provisions rather than to imported ones
- Viewed snapshots in the FSx console
- (Optional) Managed snapshot policies via the AWS CLI

FSx for ONTAP provides both on-demand Kubernetes-native snapshots (always available immediately) and automatic scheduled ONTAP snapshots through Trident's CSI integration. Together, these give you comprehensive data protection for AI/ML workloads: on-demand snapshots for point-in-time captures before experiments, and automatic snapshots for ongoing protection.
