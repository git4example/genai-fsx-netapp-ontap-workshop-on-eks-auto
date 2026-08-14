---
title : "Observe Multi-AZ State"
weight : 710
---

## Overview

Before triggering a failover, let's first observe the current state of your Multi-AZ FSx for ONTAP file system: which AZ is active, which is standby, and confirm that your vLLM pod is actively serving inference requests.

##### Step 1: Discover the file system and both subnets

1. Capture the file system ID and its two subnet IDs into shell variables:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
export FSX_ID=$(aws fsx describe-file-systems \
  --query "FileSystems[?FileSystemType=='ONTAP'] | [0].FileSystemId" \
  --output text \
  --region $AWS_REGION)

export PREFERRED_SUBNET=$(aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query "FileSystems[0].OntapConfiguration.PreferredSubnetId" \
  --output text)

# All subnets the file system is registered with (preferred + standby)
export ALL_SUBNETS=$(aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query "FileSystems[0].SubnetIds" \
  --output text)

# Standby subnet = whichever subnet in the list is NOT the preferred one
for s in $ALL_SUBNETS; do
  if [ "$s" != "$PREFERRED_SUBNET" ]; then export STANDBY_SUBNET="$s"; fi
done

echo "FSX_ID:           $FSX_ID"
echo "PREFERRED_SUBNET: $PREFERRED_SUBNET"
echo "STANDBY_SUBNET:   $STANDBY_SUBNET"
:::

2. Confirm the file system is `MULTI_AZ_1` and `AVAILABLE`:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query "FileSystems[0].{DeploymentType:OntapConfiguration.DeploymentType,Lifecycle:Lifecycle}" \
  --output table
:::

You should see `DeploymentType: MULTI_AZ_1` and `Lifecycle: AVAILABLE`.

##### Step 2: Map subnets to Availability Zones

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
PREFERRED_AZ=$(aws ec2 describe-subnets --subnet-ids $PREFERRED_SUBNET \
  --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)
STANDBY_AZ=$(aws ec2 describe-subnets --subnet-ids $STANDBY_SUBNET \
  --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)

echo "Preferred AZ (active under normal conditions): $PREFERRED_AZ"
echo "Standby AZ (takes over on failover):           $STANDBY_AZ"
:::

:::alert{header="What 'Preferred' means" type="info"}
The **preferred subnet** is where the active file server runs *when both nodes are healthy*. It is a **configuration preference**, not a live indicator of which side is currently serving traffic. To determine the currently-active side after a takeover, you need to inspect the file system's endpoint ENIs, which we will do in Step 3.
:::

##### Step 3: Confirm vLLM is healthy and serving inference

1. Check the vLLM pod status and confirm the model is responding:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
VLLM_POD=$(kubectl get pod -l app=vllm-mistral-inf2-server -o jsonpath='{.items[0].metadata.name}')
kubectl get pod $VLLM_POD
kubectl exec $VLLM_POD -- curl -s http://localhost:8000/v1/models | python3 -m json.tool
:::

The pod should show `Running` (`1/1` ready) and you should see the `mistral-7b-neuron` model listed, confirming the inference engine is active. This is the workload that must **keep serving** through the failover you trigger next.

:::alert{header="AZ placement doesn't matter" type="info"}
The vLLM pod's node and the active FSx file server may be in the **same** or **different** AZs, and both work. With Multi-AZ FSx for ONTAP, NFS traffic is routed to the active file server regardless of which AZ the client runs in. During failover the floating endpoint IPs are re-homed to the new active node via VPC route table updates, with no DNS change and no client reconfiguration.
:::

::::expand{header="Optional: determine which AZ is actively serving right now (CLI)"}

The FSx ONTAP floating endpoints (management LIF, intercluster LIF, NFS data LIF) live on ENIs. The ENI that currently owns those IPs sits in the actively-serving subnet, so you can use it to identify the active AZ:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
ACTIVE_ENI=$(aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query "FileSystems[0].NetworkInterfaceIds[0]" --output text)
ACTIVE_SUBNET=$(aws ec2 describe-network-interfaces \
  --network-interface-ids $ACTIVE_ENI --region $AWS_REGION \
  --query "NetworkInterfaces[0].SubnetId" --output text)
ACTIVE_AZ=$(aws ec2 describe-subnets --subnet-ids $ACTIVE_SUBNET \
  --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)
echo "Currently-active file server is in AZ: $ACTIVE_AZ"
:::

With no failover yet triggered, this matches `$PREFERRED_AZ` from Step 2. In the next section you'll watch the active side flip, most visibly via the VPC route table.

::::

## Summary

You have confirmed your FSx for ONTAP file system is Multi-AZ, identified the preferred and standby AZs, and verified the vLLM pod is serving inference. In the next section, you will trigger a planned failover and watch the storage layer flip to the standby AZ while the vLLM pod keeps serving.
