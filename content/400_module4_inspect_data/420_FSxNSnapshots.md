---
title : "FSx for ONTAP Volume Snapshots"
weight : 420
---

## Overview

In this module you will explore **ONTAP volume snapshots**, one of the most powerful data management features of Amazon FSx for NetApp ONTAP. Snapshots are **point-in-time, read-only copies** of your volume data. They are **space-efficient** because they only consume storage for data that has changed since the snapshot was taken — the initial snapshot is nearly instantaneous and uses almost no additional space.

Snapshots are useful for a variety of scenarios:
- **Data protection**: Quickly recover from accidental deletions or corruption by restoring to a previous snapshot.
- **Experimentation**: Take a snapshot before fine-tuning a model or modifying training data, so you can easily roll back if needed.
- **Auditing and compliance**: Maintain point-in-time records of your model artifacts and data.

:::alert{header="How ONTAP Snapshots Work" type="info"}
Unlike traditional backup methods that copy all data, ONTAP snapshots use a **redirect-on-write** mechanism. When data is modified after a snapshot is taken, only the changed blocks consume additional space. This means snapshots are created almost instantly and are extremely storage-efficient — even for large volumes containing AI model data.
:::

## Snapshot Policies

FSx for ONTAP manages snapshots through **snapshot policies** — schedules that define when snapshots are created and how many are retained. There are three built-in policies:

| Policy | Hourly | Daily | Weekly | Use case |
|---|---|---|---|---|
| **default** | 6 (5 min past the hour) | 2 (Mon–Sat at 00:10) | 2 (Sun at 00:15) | Most workloads |
| **default-1weekly** | 6 | 2 | 1 | Same as default, fewer weekly |
| **none** | — | — | — | No automatic snapshots |

When Trident dynamically provisions a volume, it sets the snapshot policy to `none` by default. In this exercise, you will enable the `default` snapshot policy on the Trident-provisioned volume that holds your Mistral-7B model data, and then view the snapshots from within a pod.

##### Step 1: Discover the Trident-provisioned volume

The model data lives on a volume that was dynamically provisioned by Trident when you created the `ontap-model-claim` PVC. We trace from the PVC to the PV to find the underlying ONTAP volume.

1. Get the ONTAP volume name from the PersistentVolume:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
ONTAP_VOL_NAME=$(kubectl get pv $(kubectl get pvc ontap-model-claim -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeAttributes.internalName}')
echo "ONTAP Volume Name: $ONTAP_VOL_NAME"
:::

2. Look up the FSx Volume ID for this volume:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text)
VOLUME_ID=$(aws fsx describe-volumes --filters Name=file-system-id,Values=$FSX_ID --query "Volumes[?Name=='${ONTAP_VOL_NAME}'].VolumeId" --output text)
echo "Volume ID: $VOLUME_ID"
:::

3. Check the current snapshot policy on this volume:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
aws fsx describe-volumes --volume-ids $VOLUME_ID --query "Volumes[0].OntapConfiguration.SnapshotPolicy" --output text
:::

::::expand{header="You should see output similar to below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
none
:::

::::

The policy is `none` because Trident sets this by default when provisioning volumes. This means no automatic snapshots are being taken.

##### Step 2: Enable the default snapshot policy

Update the volume to use the `default` snapshot policy. This enables automatic hourly, daily, and weekly snapshots.

1. Run the following command to update the snapshot policy:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
aws fsx update-volume --volume-id $VOLUME_ID \
  --ontap-configuration '{"SnapshotPolicy":"default"}'
:::

2. Verify the policy was updated:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
aws fsx describe-volumes --volume-ids $VOLUME_ID --query "Volumes[0].OntapConfiguration.SnapshotPolicy" --output text
:::

::::expand{header="You should see output similar to below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
default
:::

::::

:::alert{header="Note" type="info"}
The `default` policy creates the first hourly snapshot at 5 minutes past the next hour. You don't need to wait for this — in the next step, you'll see how to access snapshots from within a pod. If you've just enabled the policy, the `.snapshot` directory may initially be empty until the first scheduled snapshot is taken.
:::

##### Step 3: View the snapshot in the FSx console

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx).

2. Click on your FSx for ONTAP file system in the list.

3. Select the **Volumes** tab to see the volumes in your file system.

4. Click on the Trident-provisioned volume (its name starts with `trident_pvc_...`). This is the volume that holds your model data.

5. In the volume details, verify that the **Snapshot policy** now shows `default`.

:::alert{header="Automatic Snapshots" type="info"}
With the `default` policy enabled, ONTAP will automatically create snapshots on the following schedule: up to 6 hourly, 2 daily (Mon–Sat), and 2 weekly (Sunday). Snapshot times are based on the file system's time zone (UTC by default). The oldest snapshots are automatically deleted to make room for newer ones.
:::

##### Step 4: Access snapshots from within a pod

Each ONTAP snapshot is accessible through a hidden `.snapshot` directory at the root of the volume. This means you can browse and recover files from any snapshot directly from within a pod — no restore operation needed.

1. From your vLLM pod (or any pod with the volume mounted), you can list available snapshots:

:::code[]{language=bash showLineNumbers=true showCopyAction=false}
# List available snapshots from within a pod
ls /work-dir/.snapshot/

# View model files from a specific snapshot
ls /work-dir/.snapshot/<snapshot-name>/Mistral-7B-Instruct-v0.3/
:::

:::alert{header="Note" type="info"}
If you just enabled the `default` policy, the `.snapshot` directory may be empty until the first scheduled snapshot is taken (at 5 minutes past the next hour). You can check back after the hour to see the first snapshot appear.
:::

##### Step 5: Understand snapshot-based data protection and recovery

ONTAP volume snapshots provide several data protection capabilities:

**Restoring individual files from a snapshot**

If you accidentally delete or modify a file, you can recover it directly from the `.snapshot` directory without performing a full volume restore. Simply copy the file from the snapshot back to the active volume:

:::code[]{language=bash showLineNumbers=true showCopyAction=false}
# Example: recover a deleted config file from the most recent hourly snapshot
cp /work-dir/.snapshot/hourly.0/Mistral-7B-Instruct-v0.3/config.json \
   /work-dir/Mistral-7B-Instruct-v0.3/config.json
:::

**FlexClone volumes**

FSx for ONTAP supports **FlexClone** volumes, which are writable clones created from snapshots. FlexClone volumes are space-efficient — they share unchanged data blocks with the parent volume and only consume additional space for new or modified data. This is ideal for running parallel experiments with different model configurations without duplicating the entire dataset.

**Custom snapshot policies**

You can create custom snapshot policies using the ONTAP CLI or REST API to match your specific data protection requirements. For example, you might create a policy that takes snapshots every 15 minutes during business hours for a production inference workload.

For more information, see [Snapshot policies](https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/snapshots-ontap.html) in the FSx for ONTAP User Guide.

:::alert{header="Key Takeaway" type="success"}
ONTAP volume snapshots give you fast, space-efficient data protection for your AI model data. By enabling the `default` snapshot policy, you get automatic hourly, daily, and weekly snapshots with no additional configuration. Combined with features like FlexClone, you can create lightweight copies of your data for experimentation, testing, and disaster recovery — all without the overhead of full data copies.
:::

## Summary

In this section, you have:
- Discovered the Trident-provisioned ONTAP volume that stores your Mistral-7B model data
- Enabled the `default` snapshot policy to activate automatic hourly, daily, and weekly snapshots
- Learned how to access snapshots from within a pod via the `.snapshot` directory
- Understood how ONTAP snapshots can be used for file-level recovery and creating space-efficient clones

ONTAP snapshots provide instant, space-efficient data protection directly at the storage layer. This is particularly valuable for AI/ML workloads where model data can be large and needs to be protected without impacting inference performance.
