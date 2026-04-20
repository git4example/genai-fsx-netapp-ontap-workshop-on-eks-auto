---
title : "FSx for ONTAP Volume Snapshots"
weight : 410
---

## Overview

In this module you will explore **ONTAP volume snapshots**, one of the most powerful data management features of Amazon FSx for NetApp ONTAP. Snapshots are **point-in-time, read-only copies** of your volume data. They are **space-efficient** because they only consume storage for data that has changed since the snapshot was taken — the initial snapshot is nearly instantaneous and uses almost no additional space.

Snapshots are useful for a variety of scenarios:
- **Data protection**: Quickly recover from accidental deletions or corruption by restoring to a previous snapshot.
- **Experimentation**: Take a snapshot before fine-tuning a model or modifying training data, so you can easily roll back if needed.
- **Auditing and compliance**: Maintain point-in-time records of your model artifacts and data.

In this exercise, you will:
1. Discover your FSx for ONTAP volume ID
2. Create a snapshot of the volume that holds your Mistral-7B model data
3. View the snapshot in the FSx console
4. List snapshots using the AWS CLI
5. Understand how snapshots can be used for data recovery

:::alert{header="How ONTAP Snapshots Work" type="info"}
Unlike traditional backup methods that copy all data, ONTAP snapshots use a **redirect-on-write** mechanism. When data is modified after a snapshot is taken, only the changed blocks consume additional space. This means snapshots are created almost instantly and are extremely storage-efficient — even for large volumes containing AI model data.
:::

##### Step 1: Discover your FSx for ONTAP Volume ID

Before creating a snapshot, you need to find the Volume ID of the ONTAP volume that stores your model data. You can retrieve this using the FSx for ONTAP file system ID.

1. Navigate to your VS Code IDE terminal and run the following command to get your FSx for ONTAP file system ID:

::code[FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text)]{language=bash showLineNumbers=false showCopyAction=true}

2. Now use the file system ID to find the volume ID. The volume with the junction path `/model` is the one backing your persistent volume:

::code[VOLUME_ID=$(aws fsx describe-volumes --filters Name=file-system-id,Values=$FSX_ID --query "Volumes[?OntapConfiguration.JunctionPath=='/model'].VolumeId" --output text)]{language=bash showLineNumbers=false showCopyAction=true}

3. Verify the volume ID was retrieved:

::code[echo "Volume ID: $VOLUME_ID"]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see output similar to below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
Volume ID: fsvol-0abc1234def56789a
:::

::::

##### Step 2: Create a volume snapshot

Now create a snapshot of the volume that contains your Mistral-7B model data. This snapshot captures the exact state of the volume at this point in time.

1. Run the following AWS CLI command to create a snapshot:

::code[aws fsx create-snapshot --name "model-snapshot-$(date +%Y%m%d-%H%M%S)" --volume-id $VOLUME_ID]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see output similar to below, click to expand"}

:::code[]{language=json showLineNumbers=false showCopyAction=false}
{
    "Snapshot": {
        "ResourceARN": "arn:aws:fsx:us-west-2:123456789012:snapshot/fsvolsnap-0abc1234def56789a",
        "SnapshotId": "fsvolsnap-0abc1234def56789a",
        "Name": "model-snapshot-20250101-120000",
        "VolumeId": "fsvol-0abc1234def56789a",
        "Lifecycle": "CREATING",
        "CreationTime": "2025-01-01T12:00:00+00:00"
    }
}
:::

::::

:::alert{header="Note" type="info"}
The snapshot creation is nearly instantaneous. The `Lifecycle` status will quickly transition from `CREATING` to `AVAILABLE`. Because ONTAP snapshots use redirect-on-write technology, no data is physically copied — the snapshot simply preserves references to the current data blocks.
:::

2. Save the snapshot ID for later use:

::code[SNAPSHOT_ID=$(aws fsx describe-snapshots --filters Name=volume-id,Values=$VOLUME_ID --query "Snapshots[?Name!=\`null\`] | sort_by(@, &CreationTime) | [-1].SnapshotId" --output text)]{language=bash showLineNumbers=false showCopyAction=true}

::code[echo "Snapshot ID: $SNAPSHOT_ID"]{language=bash showLineNumbers=false showCopyAction=true}

##### Step 3: View the snapshot in the FSx console

1. Navigate to the Amazon FSx console:

Open the [Amazon FSx console](https://console.aws.amazon.com/fsx)

2. Click on your FSx for ONTAP file system in the list.

3. Select the **Volumes** tab to see the volumes in your file system.

4. Click on the volume with the junction path `/model`.

5. Select the **Snapshots** tab. You will see the snapshot you just created, along with any automatic snapshots that ONTAP creates based on the default snapshot policy.

:::alert{header="Automatic Snapshots" type="info"}
FSx for ONTAP automatically creates snapshots based on the volume's snapshot policy. By default, ONTAP retains hourly, daily, and weekly snapshots. The snapshot you created manually is in addition to these automatic snapshots. You can customize the snapshot policy to match your data protection requirements.
:::

##### Step 4: List snapshots using the AWS CLI

You can also list all snapshots for your volume using the AWS CLI.

1. Run the following command to list all snapshots for your volume:

::code[aws fsx describe-snapshots --filters Name=volume-id,Values=$VOLUME_ID --query "Snapshots[].{Name:Name,SnapshotId:SnapshotId,Lifecycle:Lifecycle,CreationTime:CreationTime}" --output table]{language=bash showLineNumbers=false showCopyAction=true}

::::expand{header="You should see output similar to below, click to expand"}

:::code[]{language=bash showLineNumbers=false showCopyAction=false}
---------------------------------------------------------------------------------------------------------
|                                          DescribeSnapshots                                            |
+----------------------------+------------------+-------------------------------+------------------------+
|        CreationTime        |    Lifecycle      |            Name               |      SnapshotId        |
+----------------------------+------------------+-------------------------------+------------------------+
|  2025-01-01T12:00:00+00:00|  AVAILABLE        |  model-snapshot-20250101-120000|  fsvolsnap-0abc1234... |
+----------------------------+------------------+-------------------------------+------------------------+
:::

::::

The output shows all snapshots for your volume, including the name, snapshot ID, lifecycle status, and creation time. The `AVAILABLE` status confirms the snapshot is ready and can be used for data recovery.

##### Step 5: Understand snapshot-based data protection and recovery

ONTAP volume snapshots provide several data protection capabilities:

**Restoring individual files from a snapshot**

Each ONTAP snapshot is accessible through a hidden `.snapshot` directory at the root of the volume. If you accidentally delete or modify a file, you can recover it directly from the snapshot without performing a full volume restore.

For example, if you were inside a pod with the volume mounted, you could access snapshot data at:

:::code[]{language=bash showLineNumbers=true showCopyAction=false}
# List available snapshots from within a pod
ls /work-dir/.snapshot/

# View model files from a specific snapshot
ls /work-dir/.snapshot/model-snapshot-20250101-120000/Mistral-7B-Instruct-v0.3/
:::

**Creating a new volume from a snapshot**

You can create a new ONTAP volume from a snapshot, which gives you a full copy of the data at that point in time. This is useful for:
- Creating a test environment with production model data
- Rolling back to a known-good state after a failed experiment
- Sharing a consistent copy of model artifacts with another team

**FlexClone volumes**

FSx for ONTAP also supports **FlexClone** volumes, which are writable clones created from snapshots. FlexClone volumes are space-efficient — they share unchanged data blocks with the parent volume and only consume additional space for new or modified data. This is ideal for running parallel experiments with different model configurations without duplicating the entire dataset.

:::alert{header="Key Takeaway" type="success"}
ONTAP volume snapshots give you fast, space-efficient data protection for your AI model data. Combined with features like FlexClone, you can create lightweight copies of your data for experimentation, testing, and disaster recovery — all without the overhead of full data copies or complex replication pipelines.
:::

## Summary

In this section, you have:
- Discovered your FSx for ONTAP volume ID using the AWS CLI
- Created a point-in-time snapshot of the volume containing your Mistral-7B model data
- Viewed the snapshot in the FSx console and listed snapshots using the AWS CLI
- Learned how ONTAP snapshots can be used for data protection, file-level recovery, and creating space-efficient clones

Unlike the traditional approach of replicating data to S3 buckets across regions, ONTAP snapshots provide instant, space-efficient data protection directly at the storage layer. This is particularly valuable for AI/ML workloads where model data can be large and needs to be protected without impacting inference performance.
