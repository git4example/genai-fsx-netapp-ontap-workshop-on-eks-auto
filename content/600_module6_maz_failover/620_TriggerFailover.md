---
title : "Trigger Live Failover"
weight : 620
---

## Overview

In this section you will trigger a **live failover and failback** of your FSx for ONTAP file system by performing an online **throughput capacity upgrade**. A throughput capacity change on a Multi-AZ file system requires both nodes of the HA pair to be replaced one at a time, which forces an internal takeover and failback as a side effect. This is a fully supported, online operation — throughput capacity update reliably reproduces the same data path behavior and lets you watch the route table flip in real time.

What you will observe:
- The route table associated with your FSx file system has an entry for the floating endpoint range (typically `198.19.255.0/24`) pointing at the **preferred** ENI.
- During the update, FSx upgrades the standby node first, takes over to it (route entry flips to the **standby** ENI), upgrades the preferred node, then fails back (route entry flips back to the **preferred** ENI).
- The vLLM pod stays running throughout. The prober from `failover-test.sh` shows continuous HTTP 200 with at most a small latency bump on one or two probes during each route flip.

:::alert{header="What happens during this operation" type="info"}
1. FSx provisions new file server hardware in the standby AZ at the new throughput capacity and joins it to the HA pair.
2. The active node fails over to the new standby node — the route table entry for the floating endpoint range now points at the standby ENI. NFS clients see a brief pause and continue.
3. FSx provisions new file server hardware in the preferred AZ at the new throughput capacity.
4. The file system fails back to the preferred node — the route table entry flips back to the preferred ENI.
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

The script opens a `kubectl port-forward` tunnel to the vLLM service and probes `/v1/models` every 5 seconds, logging the status code **and per-call latency** in milliseconds. Keep this running.

:::alert{header="What to watch for" type="info"}
With a properly-configured Multi-AZ FSx ONTAP setup, you will see **continuous HTTP 200** through both the takeover and the failback. The interesting signal is the **latency column**: during each route table update you may see one or two probes spike to a few hundred milliseconds. Two latency bumps over the operation are expected — one for takeover, one for failback. A sustained run of non-200 codes would indicate something is genuinely broken (route table mis-registration, security group, etc.) rather than expected transient behavior.

Why /v1/models stays 200: vLLM holds the model registry in memory and the model weights are mmap'd at startup, so this endpoint does not touch NFS on every request. That is exactly the resilience we want to demonstrate.
:::

##### Step 2: Note the Preferred and Standby ENIs

Identify which ENI currently belongs to the preferred subnet and which belongs to the standby subnet. The route table entries for the FSx floating endpoint range will point at one of these, and the pointer will flip during the failover.

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx/). Make sure you are in the workshop's region.
2. From the left pane select **File systems**, then click your file system ID.
3. Click the **Network & Security** tab.
4. Note the **Network interface** value shown for the **Preferred subnet** and the one shown for the **Standby subnet**. Record both ENI IDs in a notepad — during the failover you will see the route table swap from the preferred ENI to the standby ENI, then back.

![Network & Security tab](/static/images/network_security.png)

##### Step 3: Confirm the route table currently points at the Preferred ENI

1. On the same **Network & Security** tab, click the **Route table** link associated with your FSx file system.
2. In the route table's **Routes** tab, look for the entry with destination in the floating endpoint range — typically `198.19.255.0/24` (this range is allocated outside the VPC CIDR for FSx ONTAP Multi-AZ floating LIFs).

:::alert{header="Important" type="info"}
Notice that traffic to the `198.19.255.x` floating endpoint range is currently routed through the **ENI associated with the Preferred subnet** that you noted in Step 2. After failover, this entry will point at the **Standby subnet ENI**. After failback (when the operation completes), it will point back at the Preferred subnet ENI again.
:::

![Route table before failover](/static/images/routes.png)

##### Step 4: Trigger the failover by updating Throughput Capacity

1. Back in the FSx file system page, click the **Summary** tab.
2. Find the **Throughput capacity** field. Click the **Update** button next to it.

![Throughput capacity in Summary](/static/images/throughput_capacity.png)

3. In the dialog, pick a value **different from the current one**. For example, if your file system is currently 128 MB/s, choose **256 MB/s**. If it is currently 256 MB/s, choose 128 or 512. Any change triggers the same internal takeover/failback sequence; the absolute value does not matter for this exercise.
4. Click **Update**.

![Update Throughput Capacity dialog](/static/images/update_throughput_capacity.png)

The file system enters an `Updating` state and the operation begins.

##### Step 5: Watch the route table flip during failover

1. Refresh the route table view from Step 3 every 30-60 seconds.
2. Within a few minutes, the route entry for `198.19.255.0/24` (or whatever the floating endpoint range shows) will change from pointing at the **Preferred ENI** to pointing at the **Standby ENI**. The active node has just failed over.

![Route table during failover (now pointing at standby ENI)](/static/images/routes_2.png)

3. You can monitor the overall operation status from the FSx console's **Updates** tab on the file system details page.

![Updates tab](/static/images/update_tab.png)

4. Switch to your **second terminal** and watch the prober. During the route flip you should see one of two patterns:
   - **Best case (typical):** continuous `HTTP 200` with one or two entries showing elevated latency (a few hundred ms to a few seconds) at the moment of the flip, then back to baseline.
   - **Edge case:** one or two `HTTP 000` entries if the port-forward tunnel itself was racing against the failover. The script auto-restarts the tunnel and recovers.

##### Step 6: Watch the failback complete

The throughput capacity update is **not** done after the first route flip. FSx still needs to upgrade the preferred node, and once that is done it fails back so the preferred node is active again.

1. Continue refreshing the route table. Within another few minutes, the entry will flip **back** to pointing at the **Preferred ENI**. That is the failback.
2. The **Updates** tab in the FSx console will show the operation status as `Completed`.
3. The file system **Summary** page will show the new throughput capacity value.
4. In the prober terminal you should see a second small latency bump corresponding to the failback, then steady 200s at baseline latency.

:::alert{header="Two flips, not one" type="info"}
Throughput capacity changes on Multi-AZ ONTAP perform two route-table updates: takeover (preferred → standby) and failback (standby → preferred). Each shows up as a brief latency bump in the prober. This is actually a richer demo than a single one-way failover because you see the system recover end-to-end without any manual intervention.
:::

##### Step 7: Verify zero data loss and end-to-end inference

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

You should receive a valid response. The meaningful proof of failover correctness is the route table flip you observed in Steps 5-6 plus the prober continuity from `failover-test.sh`; this final inference call simply confirms the model is still functional end-to-end after the operation.

3. Stop the prober in your second terminal with `Ctrl+C`.

##### Troubleshooting

If you see sustained non-200 responses for more than a couple of minutes during either flip:

- Confirm the file system is registered with the **EKS private route tables** rather than the VPC main route table:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query 'FileSystems[0].OntapConfiguration.RouteTableIds'
:::
- Confirm the security group on the FSx ENIs allows TCP 2049 from the EKS node security group.

---

## Summary

You have demonstrated a **live failover and failback** of an FSx for ONTAP Multi-AZ file system by performing an online throughput capacity upgrade:

- **Zero RPO** — synchronous replication means no data was lost.
- **Two observable route flips** — takeover (preferred → standby) and failback (standby → preferred) — directly visible in the VPC route table.
- **Brief, transparent interruption** — the prober showed continuous `HTTP 200` with at most a small latency bump at each flip.
- **No pod restart, no DNS change** — failover is implemented by updating the route table entry for the floating endpoint range. The vLLM pod was unaffected; only the underlying ENI ownership of those IPs changed. This is why the Terraform configuration registers the FSx file system against the **EKS private route tables** rather than letting it default to the VPC main route table.
- **Bonus:** the operation also delivers a real throughput capacity upgrade. You picked the failover mechanism *and* got new performance characteristics in the same step.

This is what makes FSx for ONTAP Multi-AZ a strong fit for production GenAI serving: the storage layer survives a full AZ failure with no manual intervention, and routine maintenance operations like throughput upgrades exercise the same takeover/failback path so you can be confident the unplanned-failure case will behave identically.
