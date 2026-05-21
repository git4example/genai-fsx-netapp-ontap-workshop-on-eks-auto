---
title : "Trigger Live Failover"
weight : 520
---

## Overview

In this section you will trigger a **planned failover** (a manually initiated takeover) of your FSx for ONTAP file system. This simulates an AZ failure scenario and demonstrates that:
- The storage layer fails over with zero data loss (zero RPO)
- The vLLM inference pod continues to serve requests with at most a brief latency bump
- No manual intervention is needed — the takeover is transparent to applications

:::alert{header="What happens during failover" type="info"}
1. The active file server in the preferred AZ is taken over by its standby peer in the other AZ.
2. The standby file server promotes to active.
3. FSx updates the VPC route tables registered with the file system so the floating endpoint IPs (management LIF, intercluster LIF, NFS data LIF) now forward to the ENIs of the new active node. **DNS records do not change**; the IPs are stable.
4. NFS clients (pods) see a brief pause on any operation that needs to traverse the wire, then resume against the new active node.
5. All data is intact because replication is synchronous (zero RPO).
:::

:::alert{header="API support note" type="warning"}
As of this workshop, AWS does not expose a dedicated public CLI action for "fail over an FSx for ONTAP Multi-AZ file system." The supported way to trigger a planned failover is through the **AWS Console** (or via certain `update-file-system` operations that internally trigger an HA failover as a side effect, e.g. throughput capacity changes — but those take far longer and are not a clean teaching demo). This module uses the Console approach.
:::

---

##### Step 1: Start the continuous inference probe (background)

Before triggering the failover, start the prober in a second terminal so you can watch the behavior in real time.

Open a **second terminal** in your VS Code IDE and run:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd $HOME/environment/scripts
chmod +x failover-test.sh
./failover-test.sh
:::

The script opens a `kubectl port-forward` tunnel to the vLLM service and probes `/v1/models` every 5 seconds, logging the status code **and per-call latency** in milliseconds.

Keep this running. You should see lines like:

```
2026-05-20T03:14:10Z  HTTP 200    37ms  OK
2026-05-20T03:14:15Z  HTTP 200    35ms  OK
```

:::alert{header="What to watch for" type="info"}
With a properly-configured Multi-AZ FSx ONTAP setup, you will see **continuous HTTP 200** through the failover. The interesting signal is the **latency column**: during the few seconds the route table update is in flight, you may see one or two probes spike to a few hundred milliseconds (or up to the script's per-call timeout). That latency bump is the failover window. A sustained run of non-200 codes would indicate something is genuinely broken (route table mis-registration, security group, etc.) rather than expected transient behavior.

Why /v1/models stays 200: vLLM holds the model registry in memory and the model weights are mmap'd at startup, so this endpoint does not touch NFS on every request. That is exactly the resilience we want to demonstrate.
:::

##### Step 2: Capture the active AZ before failover

Back in your **first terminal**, capture which AZ is currently active so you can compare after the failover:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Re-derive the FSx ID in case this is run independently
export FSX_ID=$(aws fsx describe-file-systems \
  --query "FileSystems[?FileSystemType=='ONTAP'] | [0].FileSystemId" \
  --output text --region $AWS_REGION)

# The ENI that currently owns the floating endpoints lives in the active subnet
PRE_ENI=$(aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query "FileSystems[0].NetworkInterfaceIds[0]" --output text)
PRE_SUBNET=$(aws ec2 describe-network-interfaces \
  --network-interface-ids $PRE_ENI --region $AWS_REGION \
  --query "NetworkInterfaces[0].SubnetId" --output text)
PRE_AZ=$(aws ec2 describe-subnets --subnet-ids $PRE_SUBNET \
  --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)

echo "Active AZ before failover: $PRE_AZ ($PRE_SUBNET)"
echo "Time:                      $(date '+%H:%M:%S')"
:::

##### Step 3: Trigger the planned failover from the FSx Console

1. Open the [Amazon FSx console](https://console.aws.amazon.com/fsx/) in a new browser tab.
2. Select your ONTAP file system (its ID matches the `$FSX_ID` you captured above).
3. Click **Actions** in the upper right.
4. Choose **Failover file system** (the wording may also appear as **Failover to standby**, depending on the console version).
5. Confirm the failover in the dialog.

The Console shows the file system **Status** transitioning briefly during the takeover, then returning to **Available**.

##### Step 4: Watch the prober during failover

Switch back to your **second terminal** while the failover is in progress. You should observe one of two patterns over a window of 30-90 seconds:

- **Best case (typical):** continuous `HTTP 200` with one or two entries showing elevated latency (a few hundred ms to a few seconds) during the route flip, then back to baseline.
- **Edge case:** one or two `HTTP 000` entries if the port-forward tunnel itself was racing against the failover. The script auto-restarts the tunnel and recovers.

If you see sustained non-200 responses for more than 90 seconds, something is wrong. Likely culprits:
- The file system is not registered with the EKS private route tables (check `aws fsx describe-file-systems --query 'FileSystems[0].OntapConfiguration.RouteTableIds'`).
- The vLLM pod was rescheduled to a node that does not have NFS mounts of the affected volume (check `kubectl describe pod` for restart reasons).

##### Step 5: Confirm the active AZ moved

Run the same active-AZ query as Step 2 and compare:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
POST_ENI=$(aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query "FileSystems[0].NetworkInterfaceIds[0]" --output text)
POST_SUBNET=$(aws ec2 describe-network-interfaces \
  --network-interface-ids $POST_ENI --region $AWS_REGION \
  --query "NetworkInterfaces[0].SubnetId" --output text)
POST_AZ=$(aws ec2 describe-subnets --subnet-ids $POST_SUBNET \
  --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)

echo "Active AZ before failover: $PRE_AZ"
echo "Active AZ after failover:  $POST_AZ"
:::

The post-failover AZ should be **different** from the pre-failover AZ. Note that `OntapConfiguration.PreferredSubnetId` itself does not change — it is your configuration preference, not a live state field. The currently-active side is determined from the file system's ENIs as shown above.

##### Step 6: Verify zero data loss and end-to-end inference

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

You should receive a valid response. Note that this only proves the **model** is still functional — the meaningful proof of failover correctness is the active-AZ change in Step 5 plus the prober continuity in Step 4.

3. Stop the prober in your second terminal with `Ctrl+C`.

---

## Summary

You have demonstrated **live failover** of an FSx for ONTAP Multi-AZ file system:

- **Zero RPO** — synchronous replication means no data was lost.
- **Brief, transparent interruption** — the prober showed continuous `HTTP 200` with at most a small latency bump during the route table update.
- **No pod restart** — the compute layer (EKS pod) was unaffected; only the storage path's underlying ENI ownership changed.
- **No DNS change, no client reconfiguration** — failover is implemented via VPC route table updates against the route tables registered with the file system. This is why the Terraform configuration registers the FSx file system against the **EKS private route tables** rather than letting it default to the VPC main route table.

This is what makes FSx for ONTAP Multi-AZ a strong fit for production GenAI serving: the storage layer survives a full AZ failure with no manual intervention, and EKS Auto Mode separately handles compute-side resilience.
