---
title : "Observe Multi-AZ State"
weight : 510
---

## Overview

Before triggering a failover, let's first observe the current state of your Multi-AZ FSx for ONTAP file system — which AZ is active, which is standby, and confirm that your vLLM pod is actively serving inference requests.

##### Step 1: Check the current active/standby state

1. Run the following command to view the file system's Multi-AZ configuration:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
FSX_ID=$(aws fsx describe-file-systems --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text --region $AWS_REGION)
aws fsx describe-file-systems --file-system-ids $FSX_ID --region $AWS_REGION \
  --query "FileSystems[0].{DeploymentType:OntapConfiguration.DeploymentType,PreferredSubnet:OntapConfiguration.PreferredSubnetId,StandbySubnet:SubnetIds[?@ != OntapConfiguration.PreferredSubnetId] | [0],Lifecycle:Lifecycle}" \
  --output table
:::

You should see:
- **DeploymentType**: `MULTI_AZ_1`
- **PreferredSubnet**: The subnet ID where the active file server is currently running
- **Lifecycle**: `AVAILABLE`

2. Map the subnets to Availability Zones:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
PREFERRED_SUBNET=$(aws fsx describe-file-systems --file-system-ids $FSX_ID --region $AWS_REGION --query "FileSystems[0].OntapConfiguration.PreferredSubnetId" --output text)
PREFERRED_AZ=$(aws ec2 describe-subnets --subnet-ids $PREFERRED_SUBNET --region $AWS_REGION --query "Subnets[0].AvailabilityZone" --output text)
echo "Active file server AZ: $PREFERRED_AZ"

ALL_SUBNETS=$(aws fsx describe-file-systems --file-system-ids $FSX_ID --region $AWS_REGION --query "FileSystems[0].SubnetIds" --output text)
echo "File system subnets: $ALL_SUBNETS"
:::

:::alert{header="Note" type="info"}
The **preferred subnet** is where the active file server runs under normal conditions. After a failover, the active file server moves to the standby subnet. After a failback (or another planned failover), it returns to the preferred subnet.
:::

##### Step 2: Confirm vLLM is serving inference

Before we trigger a failover, let's confirm the vLLM pod is healthy and actively serving requests.

1. Check the vLLM pod status:

::code[kubectl get pod -l app=vllm-mistral-inf2-server]{language=bash showLineNumbers=false showCopyAction=true}

The pod should show `Running` with `1/1` containers ready.

2. Send a test inference request to confirm the model is responding:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
VLLM_POD=$(kubectl get pod -l app=vllm-mistral-inf2-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec $VLLM_POD -- curl -s http://localhost:8000/v1/models | python3 -m json.tool
:::

You should see the `mistral-7b-neuron` model listed, confirming the inference engine is active.

3. Note which AZ the vLLM pod's node is in:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
VLLM_NODE=$(kubectl get pod -l app=vllm-mistral-inf2-server -o jsonpath='{.items[0].spec.nodeName}')
kubectl get node $VLLM_NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'
echo ""
:::

:::alert{header="Key observation" type="info"}
Note the AZ of the vLLM pod's node and the AZ of the active FSx file server. With Multi-AZ FSx for ONTAP, the pod can be in **either** AZ and still access the data — NFS traffic is routed to the active file server regardless of which AZ the client is in. During failover, the NFS endpoint automatically resolves to the new active file server.
:::

##### Step 3: View the file system in the FSx console

1. Navigate to the [Amazon FSx console](https://console.aws.amazon.com/fsx/) and click on your file system.

2. On the file system details page, note the **Preferred subnet** and **Standby subnet** fields. The preferred subnet is where the active file server is currently running.

3. Click on the **Network & security** tab to see both the preferred and standby network interfaces (ENIs). Each has its own IP address, but the DNS endpoints always resolve to the active one.

## Summary

You have confirmed that your FSx for ONTAP file system is running in Multi-AZ mode with an active file server in the preferred AZ. The vLLM pod is healthy and serving inference requests. In the next section, you will trigger a planned failover and observe the behavior.
