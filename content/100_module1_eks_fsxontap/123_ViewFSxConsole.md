---
title : "View Dynamically Provisioned Volume in the FSx Console"
weight : 125
---

## Overview

Now that you have deployed the Trident CSI driver, configured the backend, and created a StorageClass and PVC, let's return to the FSx console to see what changed. When you applied the PVC in the previous step, Trident automatically created a new ONTAP volume on your file system. Let's verify this and explore the volume properties.

##### View the new dynamically provisioned volume

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx/).

2. From the top right hand corner, confirm you are in the correct **AWS region** (i.e. us-west-2).

3. Click on the **File system ID** of your FSx for ONTAP file system.

4. Click on the **Volumes** tab (or navigate to **Volumes** from the left-hand menu).

5. You should now see a **new data volume** in addition to the root volume you saw earlier. The new volume will have a name starting with `trident_pvc_...` — this was created automatically by Trident when you applied the PVC.

:::alert{header="Before vs After" type="success"}
Compare what you see now to what you saw in the earlier "Explore FSx for ONTAP" section:
- **Before** (earlier section): Only the root volume existed
- **Now**: A new `trident_pvc_...` volume has appeared — dynamically provisioned by Trident

This demonstrates how the Trident CSI driver automates ONTAP volume creation through standard Kubernetes PVC requests. No manual volume creation was needed.
:::

6. Click on the `trident_pvc_...` data volume to view its details. Key properties include:
   - **Junction path** — The NFS mount path for this volume (e.g., `/trident_pvc_...`). This is the path that gets mounted inside your Kubernetes pods.
   - **Volume size** — 100 GiB (matching your PVC request)
   - **Volume style** — FLEXVOL (the standard ONTAP volume type)
   - **Tiering policy** — Controls how data is tiered between SSD and capacity pool storage. A policy of `Auto` means infrequently accessed data is automatically moved to capacity pool storage.
   - **Snapshot policy** — `default` (automatic hourly, daily, and weekly snapshots)

::::expand{header="About ONTAP data tiering policies (click to expand)"}

FSx for ONTAP supports several tiering policies:

- **None** — All data stays on SSD storage. Best for latency-sensitive workloads.
- **Snapshot-only** — Only data in snapshots (not the active file system) is tiered to capacity pool. This is the default.
- **Auto** — Infrequently accessed data (including active file system data and snapshot data) is automatically tiered to capacity pool storage. Data is moved back to SSD when accessed again.
- **All** — All data is tiered to capacity pool storage as soon as possible. Best for archival or infrequently accessed data.

For this workshop, the volume uses the **Auto** tiering policy, which provides a good balance between performance and cost.

::::

:::alert{header="Note" type="info"}
All of these volume properties (size, tiering policy, snapshot policy, junction path) were configured automatically by Trident based on the StorageClass and backend configuration you set up. In a production environment, you can customize these per-StorageClass to match different workload requirements — for example, a `hot-storage` class with `None` tiering for latency-sensitive inference, and a `cold-storage` class with `All` tiering for archived training data.
:::

## Summary

You have now confirmed that Trident dynamically provisioned an ONTAP volume when you created the PVC. The volume is configured with thin provisioning, NFS v4.1 access, automatic snapshots, and auto data tiering — all without any manual ONTAP administration. This volume will be used in the next module to store the Mistral-7B model data and serve it to the vLLM inference pod.
