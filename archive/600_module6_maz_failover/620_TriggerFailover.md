---
title : "Trigger Live Failover"
weight : 620
---

## Overview

In this section you will trigger a **live failover and failback** of your FSx for ONTAP file system by performing an online **throughput capacity upgrade**. A throughput capacity change on a Multi-AZ file system requires both nodes of the HA pair to be replaced one at a time, which forces an internal takeover and failback as a side effect. This is a fully supported, online operation, and a throughput capacity update reliably reproduces the same data path behavior and lets you watch the route table flip in real time.

What you will observe:
- The route table associated with your FSx file system has an entry for the floating endpoint range (typically `198.19.255.0/24`) pointing at the **preferred** ENI.
- During the update, FSx upgrades the standby node first, takes over to it (route entry flips to the **standby** ENI), upgrades the preferred node, then fails back (route entry flips back to the **preferred** ENI).
- The vLLM pod stays running throughout. The prober from `failover-test.sh` shows continuous HTTP 200 with at most a small latency bump on one or two probes during each route flip.

:::alert{header="What happens during this operation" type="info"}
1. FSx provisions new file server hardware in the standby AZ at the new throughput capacity and joins it to the HA pair.
2. The active node fails over to the new standby node, so the route table entry for the floating endpoint range now points at the standby ENI. NFS clients see a brief pause and continue.
3. FSx provisions new file server hardware in the preferred AZ at the new throughput capacity.
4. The file system fails back to the preferred node, and the route table entry flips back to the preferred ENI.
5. All data is intact throughout because replication is synchronous (zero RPO).
:::

---

##### Step 1: Start the continuous inference probe (background)

Before triggering the change, start the prober in a second terminal so you can watch the data plane in real time.

Open a **second terminal** in your VS Code IDE and run:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd $HOME/environment/scripts
chmod +x failover-test.sh
./failover-test.sh
:::

The script opens a `kubectl port-forward` tunnel to the vLLM service and probes `/v1/models` every 5 seconds, logging the status code **and per-call latency** in milliseconds. Keep this running, and you'll watch it stay at `HTTP 200` throughout the failover.

##### Step 2: Locate the ENIs and the route table entry

The FSx for NetApp floating endpoint range (typically `198.19.255.0/24`, allocated outside the VPC CIDR for Multi-AZ floating LIFs) is routed to the **Preferred subnet's ENI** today. During the operation this pointer flips to the **Standby ENI**, then back. That flip is the failover you'll watch.

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx/) (ensure you select your workshop region). Then click on *File Systems* from the left hand menu, Click on your listed File System ID. Click on the **Network & Security** tab.
2. Note the **Network interface** ID for the **Preferred subnet** and for the **Standby subnet** (jot both down).
3. Click the **Route table** link on that tab. In the **Routes** tab, find the `198.19.255.0/24` entry, which currently targets the **Preferred ENI**.

![Route table before failover](/static/images/routes.png)

##### Step 3: Trigger the failover by updating Throughput Capacity

1. On the file system **Summary** tab, find **Throughput capacity** and click **Update**.
2. Pick any value **different from the current one** (e.g. 128 → 256 MB/s). The absolute value doesn't matter, since any change forces the internal takeover/failback. Click **Update**.

![Update Throughput Capacity dialog](/static/images/update_throughput_capacity.png)

The file system enters `Updating` and the operation begins.

##### Step 4: Watch the route table flip (takeover, then failback)

Refresh the route table view every 30-60 seconds. You'll see **two flips** over the next several minutes:

1. **Takeover**: the `198.19.255.0/24` entry changes from the **Preferred ENI** to the **Standby ENI**.
2. **Failback**: once FSx finishes upgrading the preferred node, the entry flips **back** to the **Preferred ENI**. The **Updates** tab then shows `Completed` and the **Summary** page shows the new throughput value.

![Route table during failover (now pointing at standby ENI)](/static/images/routes_2.png)

Meanwhile, watch the prober in your **second terminal**: it should stay at continuous `HTTP 200`, with just **one small latency bump per flip** (two total), then baseline.

::::expand{header="Why two flips, and what the edge cases look like"}

Throughput capacity changes on Multi-AZ ONTAP perform **two** route-table updates, takeover (preferred → standby) and failback (standby → preferred), so you see the system recover end-to-end with no manual intervention. This is a richer demo than a single one-way failover.

In the prober you may occasionally see one or two `HTTP 000` entries (rather than elevated-latency 200s) if the `kubectl port-forward` tunnel itself raced the failover; the script auto-restarts the tunnel and recovers. A *sustained* run of non-200s (more than a couple of minutes) would indicate a real problem. See Troubleshooting below.

**Why `/v1/models` stays 200:** vLLM holds the model registry in memory and mmaps the weights at startup, so this endpoint doesn't touch NFS on every request, which is exactly the resilience we want to show.

::::

##### Step 5: Verify zero data loss and end-to-end inference

1. Confirm the model files are still present on the volume:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
VLLM_POD=$(kubectl get pod -l app=vllm-mistral-inf2-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec $VLLM_POD -- ls /work-dir/Mistral-7B-Instruct-v0.3/ | head -5
:::

You should see the model files unchanged from before the failover.

2. Send a real inference request to confirm end-to-end behavior:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec $VLLM_POD -- curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-7b-neuron","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":50}' \
  | python3 -m json.tool
:::

You should receive a valid response. The meaningful proof of failover correctness is the **route table flip you observed in Step 4** plus the prober continuity from `failover-test.sh`; this final inference call simply confirms the model is still functional end-to-end after the operation.

3. Stop the prober in your second terminal with `Ctrl+C`.

::::expand{header="Troubleshooting: sustained non-200 responses"}

If you see sustained non-200 responses for more than a couple of minutes during either flip:

- Confirm the file system is registered with the **EKS private route tables** rather than the VPC main route table:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query 'FileSystems[0].OntapConfiguration.RouteTableIds'
:::
- Confirm the security group on the FSx ENIs allows TCP 2049 from the EKS node security group.

::::

---

## Summary

You have demonstrated a **live failover and failback** of an FSx for ONTAP Multi-AZ file system by performing an online throughput capacity upgrade:

- **Zero RPO**: synchronous replication means no data was lost.
- **Two observable route flips**: takeover (preferred → standby) and failback (standby → preferred), both directly visible in the VPC route table.
- **Brief, transparent interruption**: the prober showed continuous `HTTP 200` with at most a small latency bump at each flip.
- **No pod restart, no DNS change**: failover is implemented by updating the route table entry for the floating endpoint range. The vLLM pod was unaffected; only the underlying ENI ownership of those IPs changed. This is why the Terraform configuration registers the FSx file system against the **EKS private route tables** rather than letting it default to the VPC main route table.
- **Bonus:** the operation also delivers a real throughput capacity upgrade. You picked the failover mechanism *and* got new performance characteristics in the same step.

This is what makes FSx for ONTAP Multi-AZ a strong fit for production GenAI serving: the storage layer survives a full AZ failure with no manual intervention, and routine maintenance operations like throughput upgrades exercise the same takeover/failback path so you can be confident the unplanned-failure case will behave identically.
