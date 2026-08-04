---
title : "Configure AI compute nodepool and load model"
weight : 210
---

## Overview

In this section you will configure an AWS Inferentia nodepool on the EKS cluster, and install the AWS Neuron plugins.

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

CloudWatch metrics for Neuron hardware utilization and errors are published by a separate component, the **Neuron Monitor**, which you will install in Module 3.

For more information on this, please refer to the [Neuron Node Problem Detector and Recovery](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/containers/tutorials/k8s-neuron-problem-detector-and-recovery.html) documentation.

#####  Step 2: Create EKS Auto Mode NodePool and EC2 NodeClass for AWS Inferentia Accelerators

The EKS Auto Mode configuration comes in the form of a NodePool Custom Resource (CR). The NodePool sets constraints on the EC2 nodes that can be used by EKS Auto Mode, the pods that can run on those EC2 nodes, where a NodePool can handle many different pod shapes. EKS Auto Mode makes scheduling and provisioning decisions based on pod attributes such as labels and affinity. An EKS cluster can have more than one NodePool, and in this workshop we will declare an additional inferentia NodePool.


1. Run the following command to create the EKS Auto Mode inferentia NodePool definition

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
NODE_ROLE=$(cd /home/participant/environment/terraform && terraform output --raw eks_node_iam_role_name)
cd /home/participant/environment/eks/genai
export NODE_ROLE
:::

2. Lets take a look at the EKS Auto NodePool definition for the inferentia NodePool before we apply it. This configuration will create a new nodepool for AWS Inferentia (using "INF2" type for instance-family), where the AWS INF2 compute nodes will power Generative AI application (vLLM pod).

::code[cat inferentia_nodepool.yaml]{language=bash showLineNumbers=false showCopyAction=true}

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



##### Step 3: Load the Mistral-7B Model onto the FSx for ONTAP Volume

:::alert{header="Important — Why is this step needed?" type="info"}
FSx for NetApp ONTAP is a fully-featured enterprise file system that supports NFS, SMB, and iSCSI, with features like snapshots, clones, SnapMirror replication, data compression, and deduplication. In this workshop we use it as a high-performance shared volume for model data — the same volume can be mounted `ReadWriteMany` across pods, enabling both the model loading Job and the vLLM inference pod to share a single copy of the model.

Because the model data lives on a persistent volume (rather than being baked into the container image or streamed on demand), we stage it onto the ONTAP-backed PVC once using a Kubernetes Job that downloads a **pre-compiled** Mistral-7B-Instruct-v0.3 model (with Neuron compiled artifacts) from HuggingFace directly onto the PVC. Using pre-compiled artifacts means vLLM can skip the Neuron compilation step and start serving immediately.

This is a **one-time operation**. Once the model data is on the FSx for ONTAP volume, it persists across pod restarts and redeployments. If the vLLM pod is deleted and recreated, it will load the model directly from the volume without needing to download it again. This is one of the key benefits of using persistent storage like FSx for ONTAP for inference workloads — the model is loaded once and reused by any pod that mounts the same volume.
:::

1. Apply the Model Loading Job manifest. This Job will download the pre-compiled Mistral-7B-Instruct-v0.3 model (including Neuron compiled artifacts) from HuggingFace and store it on the `ontap-model-claim` PVC that you created in Module 1.

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
cd /home/participant/environment/eks/FSxONTAP
kubectl apply -f model-loading-job.yaml
:::

2. The pre-compiled Mistral-7B model is approximately 29 GB, and the download typically completes in **5 minutes**. Please wait until the download completes before going

**[Optional]** - You can view the progress of the model download by opening a **second VSCode IDE terminal session**  and running the below command to monitor the progress.

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl logs -f job/model-download
:::

:::alert{header="Note" type="info"}
Please wait until the download completes before moving to the next sections.
:::

3. Verify that the model data has been successfully downloaded to the persistent volume. Run a quick check to confirm the model files are present:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl run model-check --rm -it --restart=Never \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  --overrides='{"spec":{"containers":[{"name":"model-check","image":"public.ecr.aws/amazonlinux/amazonlinux:2023","command":["ls","-la","/work-dir/Mistral-7B-Instruct-v0.3/"],"volumeMounts":[{"name":"persistent-storage","mountPath":"/work-dir"}]}],"volumes":[{"name":"persistent-storage","persistentVolumeClaim":{"claimName":"ontap-model-claim"}}]}}' \
  -- ls -la /work-dir/Mistral-7B-Instruct-v0.3/
:::

You should see the model weight files (e.g., `model-00001-of-00003.safetensors`), tokenizer files, and configuration files listed in the output. This confirms the model is ready for the vLLM inference pod.

### Summary
You have configured EKS Nodepool for AWS Inferentia AI Accelators, and loaded the Mistral-7B model onto an FSx for NetApp volume.
