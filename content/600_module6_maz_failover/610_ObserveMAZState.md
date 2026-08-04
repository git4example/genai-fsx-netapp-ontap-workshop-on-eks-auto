---
title : "Observe Multi-AZ State"
weight : 610
---

## Overview

Before triggering a failover, let's first observe the current state of your Multi-AZ FSx for ONTAP file system — which AZ is active, which is standby, and confirm that your vLLM pod is actively serving inference requests.

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
The **preferred subnet** is where the active file server runs *when both nodes are healthy*. It is a **configuration preference**, not a live indicator of which side is currently serving traffic. To determine the currently-active side after a takeover, you need to inspect the file system's endpoint ENIs — we will do that in Step 3.
:::

##### Step 3: Determine which side is currently active

The FSx ONTAP floating endpoints (management LIF, intercluster LIF, NFS data LIF) live on ENIs. The ENI that currently owns those IPs lives in the actively-serving subnet. We can use that to discover which AZ is active right now.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Pull the ENIs that the file system currently uses for its endpoints
ACTIVE_ENI=$(aws fsx describe-file-systems \
  --file-system-ids $FSX_ID --region $AWS_REGION \
  --query "FileSystems[0].NetworkInterfaceIds[0]" \
  --output text)

ACTIVE_SUBNET=$(aws ec2 describe-network-interfaces \
  --network-interface-ids $ACTIVE_ENI --region $AWS_REGION \
  --query "NetworkInterfaces[0].SubnetId" \
  --output text)

ACTIVE_AZ=$(aws ec2 describe-subnets --subnet-ids $ACTIVE_SUBNET \
  --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)

echo "Currently-active file server is in AZ: $ACTIVE_AZ (subnet: $ACTIVE_SUBNET)"
:::

Right now, with no failover yet triggered, this should match `$PREFERRED_AZ` from Step 2. After the failover in the next page, we will run the same command and observe that it has moved.

##### Step 4: Confirm vLLM is healthy and serving inference

1. Check the vLLM pod status:

::code[kubectl get pod -l app=vllm-mistral-inf2-server]{language=bash showLineNumbers=false showCopyAction=true}

The pod should show `Running` with `1/1` containers ready.

2. Send a test inference request from inside the pod to confirm the model is responding:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
VLLM_POD=$(kubectl get pod -l app=vllm-mistral-inf2-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec $VLLM_POD -- curl -s http://localhost:8000/v1/models | python3 -m json.tool
:::

You should see the `mistral-7b-neuron` model listed, confirming the inference engine is active.

3. Note which AZ the vLLM pod's node is in:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
VLLM_NODE=$(kubectl get pod -l app=vllm-mistral-inf2-server -o jsonpath='{.items[0].spec.nodeName}')
POD_AZ=$(kubectl get node $VLLM_NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
echo "vLLM pod node AZ: $POD_AZ"
echo "Active FSx AZ:    $ACTIVE_AZ"
:::

:::alert{header="Key observation" type="info"}
The vLLM pod's node and the active FSx file server may be in the **same** AZ or **different** AZs — both work. With Multi-AZ FSx for ONTAP, NFS traffic is routed to the active file server regardless of which AZ the client is in. During failover, the floating endpoint IPs are re-homed to the new active node via VPC route table updates (no DNS change, no client reconfiguration).
:::

##### Step 5: View the file system in the FSx console

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx/) and click on your file system.

2. On the file system details page, note the **Preferred subnet** and **Standby subnet** fields.

3. Click on the **Network & security** tab to see both file server ENIs. Each has its own subnet/AZ. The endpoint IPs (management/intercluster/NFS) currently route to the active side.

## Summary

You have confirmed that your FSx for ONTAP file system is in Multi-AZ mode, identified which AZ is currently active, and verified that the vLLM pod is healthy and serving inference. In the next section, you will trigger a planned failover and observe how the storage layer flips to the standby AZ while the vLLM pod keeps serving.
