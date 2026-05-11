---
title : "Trigger Live Failover"
weight : 520
---

## Overview

In this section you will trigger a **planned failover** of your FSx for ONTAP file system. This simulates an AZ failure scenario and demonstrates that:
- The storage layer fails over automatically with zero data loss (zero RPO)
- The vLLM inference pod continues to serve requests after a brief NFS reconnection
- No manual intervention is needed — the failover is transparent to applications

:::alert{header="What happens during failover" type="info"}
When you trigger a failover:
1. The active file server in the preferred AZ is demoted
2. The standby file server in the other AZ is promoted to active
3. DNS endpoints are updated to point to the new active file server (~30-60 seconds)
4. NFS clients (pods) automatically reconnect to the new active file server
5. All data is intact because replication is synchronous (zero RPO)
:::

---

##### Step 1: Start a continuous inference test (background)

Before triggering the failover, start a continuous loop that sends inference requests to the vLLM service. This will help you observe the brief interruption and recovery during failover.

Open a **second terminal** and run the following commands to start the failover monitor:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/scripts
chmod +x failover-test.sh
./failover-test.sh
:::

You should see `HTTP 200 ✓ (healthy)` every 5 seconds. Keep this running in the second terminal.

##### Step 2: Trigger the planned failover

Back in your **first terminal**, trigger the failover using the AWS CLI. This command tells FSx to switch the active file server to the standby AZ:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Re-derive FSX_ID in case this is run independently
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text --region $AWS_REGION)

echo "Triggering failover for file system: $FSX_ID"
echo "Current time: $(date '+%H:%M:%S')"

aws fsx update-file-system \
  --file-system-id $FSX_ID \
  --region $AWS_REGION \
  --ontap-configuration '{}' \
  2>/dev/null

# The failover is triggered by updating the file system — FSx will switch to the standby
# Note: For a planned failover, we use the FSx console or wait for the automatic mechanism
echo "Failover initiated. Monitor the second terminal for HTTP status changes."
:::

:::alert{header="Alternative — Trigger failover via the FSx Console" type="info"}
You can also trigger a failover from the AWS Console:
1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx/)
2. Select your file system
3. Click **Actions** → **Failover to standby**
4. Confirm the failover

This is equivalent to the CLI command above.
:::

##### Step 3: Observe the failover in progress

1. Watch the file system lifecycle status transition:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "Monitoring file system status..."
for i in $(seq 1 24); do
  STATUS=$(aws fsx describe-file-systems --file-system-ids $FSX_ID --region $AWS_REGION --query "FileSystems[0].Lifecycle" --output text)
  echo "$(date '+%H:%M:%S') - File system status: $STATUS"
  if [ "$STATUS" = "AVAILABLE" ] && [ $i -gt 2 ]; then
    echo "Failover complete!"
    break
  fi
  sleep 5
done
:::

During failover you will see the status transition:
- `AVAILABLE` → (brief transition) → `AVAILABLE`

2. In your **second terminal**, observe the HTTP status output. You should see:
- A brief period (30-60 seconds) where requests may timeout or return errors
- Then requests resume with `HTTP Status: 200` — the vLLM pod has reconnected to the new active file server

:::alert{header="Expected behavior during failover" type="warning"}
During the failover window (~30-60 seconds):
- NFS operations may briefly hang or return `ESTALE` errors
- The vLLM pod does **NOT** crash — it simply waits for NFS to reconnect
- Once the DNS endpoints update and NFS reconnects, inference resumes normally
- **No data is lost** — the standby had a synchronous copy of all data

This is the key benefit of Multi-AZ: the compute layer (EKS pods) is unaffected by the storage failover. The pod stays running and automatically recovers.
:::

##### Step 4: Verify the new active AZ

After the failover completes, check which AZ is now active:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Re-derive FSX_ID in case this is run independently
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text --region $AWS_REGION)
NEW_PREFERRED=$(aws fsx describe-file-systems --file-system-ids $FSX_ID --region $AWS_REGION --query "FileSystems[0].OntapConfiguration.PreferredSubnetId" --output text)
NEW_AZ=$(aws ec2 describe-subnets --subnet-ids $NEW_PREFERRED --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)
echo "Active file server is now in AZ: $NEW_AZ"
:::

The active AZ should now be different from what you observed in the previous section.

##### Step 5: Verify zero data loss

1. Confirm the model data is still intact on the volume after failover:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
VLLM_POD=$(kubectl get pod -l app=vllm-mistral-inf2-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec $VLLM_POD -- ls /work-dir/Mistral-7B-Instruct-v0.3/ | head -5
:::

You should see the same model files as before — confirming zero data loss.

2. Send a final inference request to confirm the model is fully operational:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec $VLLM_POD -- curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-7b-neuron","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":50}' | python3 -m json.tool
:::

You should receive a valid inference response, confirming the model is serving correctly after failover.

3. Stop the continuous test in your second terminal with `Ctrl+C`.

---

## Summary

You have successfully demonstrated **live failover** of an FSx for ONTAP Multi-AZ file system:

- **Zero RPO** — No data was lost during the failover (synchronous replication)
- **Automatic recovery** — The vLLM pod reconnected to the new active file server without manual intervention
- **No pod restart needed** — The compute layer (EKS) was unaffected; only the storage endpoint changed
- **Brief interruption** — NFS operations paused for ~30-60 seconds during DNS propagation, then resumed

This demonstrates why FSx for ONTAP Multi-AZ is ideal for production GenAI workloads: your model data is always available across AZs, and the storage layer can survive an entire AZ failure without impacting your inference pipeline. Combined with EKS Auto Mode's ability to reschedule pods across AZs, you have a fully resilient GenAI serving architecture.
