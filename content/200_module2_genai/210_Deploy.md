---
title : "Configure AI compute nodepool & load model"
weight : 210
---

## Overview

In this section you will configure an AWS Inferentia nodepool (AI Compute) on the EKS cluster, and install the required AWS Neuron plugins that are required for using AWS Inferentia with Amazon EKS.

##### Step 1: Install Neuron Device Plugin, Scheduler & Node Problem Detector

In order to use the AWS Inferentia accelerated compute nodes with the Mistral LLM, we need to install the Neuron Device Plugin, Neuron Scheduler, and Neuron Node Problem Detector & Recovery on the EKS Cluster using a helm chart. Click on this link to learn more about the [AWS Neuron Helm Chart](https://aws.amazon.com/blogs/containers/announcing-aws-neuron-helm-chart/).

1. Copy & paste the below command into your terminal to install the neuron helm chart.

:::code{showCopyAction=true showLineNumbers=true language=bash}
cd /home/participant/environment/terraform

helm upgrade --install neuron-helm-chart \
    oci://public.ecr.aws/neuron/neuron-helm-chart \
    --namespace kube-system \
    --version 1.5.0 \
    -f ./helm-values/neuron-values.yaml
:::

You should see an output similar to the one below.

:::code{showCopyAction=false showLineNumbers=false language=bash}
Release "neuron-helm-chart" does not exist. Installing it now.
Pulled: public.ecr.aws/neuron/neuron-helm-chart:1.5.0
Digest: sha256:...
NAME: neuron-helm-chart
LAST DEPLOYED: Thu Jul 24 01:57:53 2025
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
:::

Lets take a moment to understand each of these components.

###### Neuron Device plugin

The Neuron device plugin exposes Neuron cores & devices to kubernetes as a resource, where `aws.amazon.com/neuroncore` and `aws.amazon.com/neuron` are the resources that the neuron device plugin registers with the kubernetes.

For more information on this, please refer [Neuron Device Plugin](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/containers/kubernetes-getting-started.html#neuron-device-plugin)


###### Neuron Scheduler
The Neuron scheduler extension is required for scheduling pods that require more than one Neuron core or device resource.

For more information on this, please refer [Neuron Scheduler Extension](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/containers/kubernetes-getting-started.html#neuron-scheduler-extension)

###### Neuron Node Problem Detector and Recovery

This component combines a Neuron-specific Node Problem Detector (NPD) with a Node Recovery controller. NPD watches kernel logs on each Neuron node for hardware errors (uncorrectable SRAM, HBM, and NeuronCore errors, as well as DMA errors) and surfaces them as Kubernetes node conditions. Node Recovery (enabled in this workshop via `npd.nodeRecovery.enabled`) reacts to those conditions by cordoning and replacing unhealthy nodes so that workloads reschedule onto healthy Neuron hardware.

CloudWatch metrics for Neuron hardware utilization and errors are published by a separate component, the **Neuron Monitor**, which you will install in **Module 3: Observability dashboard for LLM Inference**.

For more information on this, please refer to the [Neuron Node Problem Detector and Recovery](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/containers/tutorials/k8s-neuron-problem-detector-and-recovery.html) documentation.

#####  Step 2: Create EKS Auto Mode NodePool and EC2 NodeClass for AWS Inferentia Accelerators

The EKS Auto Mode configuration comes in the form of a NodePool Custom Resource (CR). The NodePool sets constraints on the EC2 nodes that can be used by EKS Auto Mode, the pods that can run on those EC2 nodes, where a NodePool can handle many different pod shapes. EKS Auto Mode makes scheduling and provisioning decisions based on pod attributes such as labels and affinity. An EKS cluster can have more than one NodePool, and in this workshop we will declare an additional inferentia NodePool.


1. Run the following command to create the EKS Auto Mode inferentia NodePool definition

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
NODE_ROLE=$(cd /home/participant/environment/terraform && terraform output --raw eks_node_iam_role_name)
cd /home/participant/environment/eks/genai
export NODE_ROLE
:::

2. This configuration will create a new nodepool for AWS Inferentia (using "INF2" type for instance-family), where the AWS INF2 compute nodes will power the Generative AI application (vLLM pod).

::::expand{header="Optional: click to view the inferentia_nodepool.yaml definition"}

::code[cat inferentia_nodepool.yaml]{language=bash showLineNumbers=false showCopyAction=true}

::::

:::alert{header="What to observe in the NodePool definition" type="info"}
When reviewing the output, pay attention to these key fields:
- **instance-family: ["inf2"]** — constrains EKS Auto Mode to only provision AWS Inferentia2 instances for this NodePool
- **instance-size: ["xlarge"]** — pins to `inf2.xlarge` (1 Inferentia2 chip with 2 NeuronCores)
- **nodeSelector / tolerations** — pods must explicitly request this NodePool via matching labels and tolerations
- **disruption policy** — controls how EKS Auto Mode handles node consolidation and expiry

These constraints ensure that only pods requesting Neuron resources get scheduled onto the expensive accelerated compute nodes.
:::

4. Let's deploy the inferentia NodePool, substituting the `$NODE_ROLE` placeholder with the IAM role name retrieved above.

::code[envsubst '$NODE_ROLE' < inferentia_nodepool.yaml | kubectl apply -f -]{language=bash showLineNumbers=false showCopyAction=true}

5. Verify NodePool and NodeClass:
::code[kubectl get nodepool,nodeclass inferentia]{language=bash showLineNumbers=false showCopyAction=true}

You should see an output similar to the one below. **Note** that you will initially see 0 nodes in the pool, that's because we haven't deployed any pods that need this accelerated compute node.

:::code{showCopyAction=false showLineNumbers=false language=bash}
NAME                               NODECLASS    NODES   READY   AGE
nodepool.karpenter.sh/inferentia   inferentia   0       True    11s

NAME                                     ROLE                                              READY   AGE
nodeclass.eks.amazonaws.com/inferentia   eksworkshop-eks-auto-20250103063226329700000003   True    11s
:::



##### Step 3: Verify the Mistral-7B Model is Present on the FSx for ONTAP Volume

:::alert{header="The model is already pre-loaded" type="success"}
To save you a multi-gigabyte download, the **pre-compiled Mistral-7B-Instruct-v0.3 model (with Neuron compiled artifacts) was already loaded onto an FSx for NetApp ONTAP volume during workshop provisioning**. The volume named `model` was imported into Kubernetes as the `ontap-model-claim` PVC (see the "How the model volume is wired" callout in the optional **Dynamic Provisioning** module). You do **not** need to download anything here — you'll simply confirm the model is present and then deploy vLLM against it.
:::

:::alert{header="Why store the model on FSx for ONTAP?" type="info"}
FSx for NetApp ONTAP is a fully-featured enterprise file system (NFS, SMB, iSCSI) with snapshots, clones, SnapMirror replication, compression, and deduplication. Here it serves as a high-performance shared volume for model data — the same volume can be mounted `ReadWriteMany` across pods. Because the model lives on persistent storage rather than being baked into the container image, it persists across pod restarts and can be reused by any pod that mounts the volume. Using pre-compiled Neuron artifacts also lets vLLM skip the compilation step and start serving quickly.
:::

Verify that the model data is present on the persistent volume:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl run model-check --rm -it --restart=Never \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  --overrides='{"spec":{"containers":[{"name":"model-check","image":"public.ecr.aws/amazonlinux/amazonlinux:2023","command":["ls","-la","/work-dir/Mistral-7B-Instruct-v0.3/"],"volumeMounts":[{"name":"persistent-storage","mountPath":"/work-dir"}]}],"volumes":[{"name":"persistent-storage","persistentVolumeClaim":{"claimName":"ontap-model-claim"}}]}}' \
  -- ls -la /work-dir/Mistral-7B-Instruct-v0.3/
:::

You should see the model weight files (e.g., `model-00001-of-00003.safetensors`), tokenizer files, and configuration files listed in the output. This confirms the model is ready for the vLLM inference pod.

### Summary
You have configured the EKS NodePool for AWS Inferentia accelerators and confirmed the pre-loaded Mistral-7B model is present on the FSx for NetApp ONTAP volume — ready for the vLLM deployment in the next section.
