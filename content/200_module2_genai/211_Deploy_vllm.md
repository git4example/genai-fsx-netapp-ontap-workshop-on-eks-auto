---
title : "Deploy vLLM inference engine"
weight : 211
---

## Overview
In this module you will deploy the vLLM inference engine as a container pod on the Amazon EKS cluster.

##### Step 1: Deploy the vLLM application Pod

You will now deploy the vLLM pod, which will provide model serving capability through its inference endpoint. Once the vLLM Pod is online, it will load the pre-compiled Mistral-7B model from the FSx for NetApp ONTAP volume. Because the model includes pre-compiled Neuron artifacts, vLLM skips the compilation step and starts serving in approximately 3 - 5 minutes (compared to 15+ minutes without pre-compiled artifacts).

1. Run the below commands to update the mistral-ontap.yaml with your AWS environment variables.

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
cd /home/participant/environment/eks/genai
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
FSX_ONTAP_AZ=$(aws fsx describe-file-systems --region $AWS_REGION --query "FileSystems[?FileSystemType=='ONTAP'].OntapConfiguration.PreferredSubnetId" --output text | head -1 | xargs -I {} aws ec2 describe-subnets --subnet-ids {} --query 'Subnets[0].AvailabilityZone' --output text)
export FSX_ONTAP_AZ
:::

:::alert{header="Why pin to the FSx ONTAP preferred AZ?" type="info"}
Although your FSx for ONTAP file system is deployed in **Multi-AZ** mode (accessible from both AZs), we pin the vLLM pod to the **preferred AZ** (where the active file server runs) to minimize cross-AZ NFS latency and avoid cross-AZ data transfer costs. The model data is accessible from either AZ, but placing compute in the same AZ as the active storage provides optimal performance. If a failover occurs, the pod continues to work — it just routes NFS traffic cross-AZ until the file system fails back.
:::

2. Run the below command to deploy the vLLM Pod, substituting the `$FSX_ONTAP_AZ` placeholder with the availability zone retrieved above.


::code[envsubst '$FSX_ONTAP_AZ' < mistral-ontap.yaml | kubectl apply -f -]{language=bash showLineNumbers=false showCopyAction=true}


3. Now run the below command, and you will see the Inferentia node count increase to 1, as we have deployed a pod that requires the accelerated compute node. Note that the increase to a value of 1 can take 30 seconds to update.
::code[kubectl get nodepool,nodeclass inferentia]{language=bash showLineNumbers=false showCopyAction=true}

:::alert{header="Note" type="info"}
**The vLLM pod deployment will take approx. 7 minutes. You can continue to the next steps, and don't need to wait for this step to complete**.  
:::


4. Optionally inspect the vLLM deployment manifest to understand its configuration:

::::expand{header="Click to view mistral-ontap.yaml — vLLM deployment manifest"}

::code[cat mistral-ontap.yaml]{language=bash showLineNumbers=false showCopyAction=true}

:::alert{header="Note" type="info"}
You will notice a single pod deployment request, with a request for 2 AWS Inferentia NeuronCores, persistent storage using the PVC you created previously (`ontap-model-claim`), and also some model parameters. The model (including pre-compiled Neuron artifacts) was loaded onto this PVC by the Model Loading Job in Step 3. The `NEURON_COMPILED_ARTIFACTS` environment variable tells vLLM where to find the pre-compiled model, allowing it to skip the compilation step.
:::


:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# mistral-ontap.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-mistral-inf2-deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-mistral-inf2-server
  template:
    metadata:
      labels:
        app: vllm-mistral-inf2-server
    spec:
      automountServiceAccountToken: false
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values:
                - FSX_ONTAP_AZ                                  # <<<<< Replace with your FSx ONTAP AZ
      nodeSelector:
        node.kubernetes.io/instance-type: inf2.xlarge           # <<<<< Pin to inf2.xlarge
      tolerations:
      - key: "aws.amazon.com/neuron"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: inference-server
        image: public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.9.1-neuronx-py311-sdk2.26.1-ubuntu22.04
        command: ["vllm", "serve"]
        args:
        - /work-dir/Mistral-7B-Instruct-v0.3                  # <<<<< Local model path on ONTAP volume
        - --served-model-name=mistral-7b-neuron
        - --trust-remote-code
        - --tensor-parallel-size=2
        - --max-model-len=4096
        - --max-num-seqs=4
        - --device=neuron
        resources:                                             # <<<<< Neuron Resources
          requests:
            cpu: "2"
            memory: 8Gi
            aws.amazon.com/neuroncore: 2                       # <<<<< Neuron Resources Request
          limits:
            aws.amazon.com/neuroncore: 2                       # <<<<< Neuron Resources Limits
        env:
        - name: NEURON_COMPILED_ARTIFACTS
          value: /work-dir/Mistral-7B-Instruct-v0.3           # <<<<< Pre-compiled artifacts path
        volumeMounts:
        - name: persistent-storage
          mountPath: "/work-dir"                               # <<<<< FSx for ONTAP PVC mount
(...)
      volumes:
      - name: persistent-storage
        persistentVolumeClaim:
          claimName: ontap-model-claim                         # <<<<< FSx for ONTAP PVC
:::

::::

5. You can monitor the vLLM pod creation by running the below command periodically, until you see it transitioning to `Running` (usually when its at the 7 minute mark, this is where the vLLM is online and the model has been loaded into memory)

::code[kubectl get pod]{language=bash showLineNumbers=false showCopyAction=true}

![vllm_pod](/static/images/vllm_pod_1.png)

You can also see when vLLM Pod and the Mistral model has been loaded into the vLLM memory by running below command, and being able to see "*Application startup complete*" in the output.

::code[kubectl logs <your-vLLM-pod-name> -f]{language=bash showLineNumbers=false showCopyAction=true}


6. While you are waiting for the vLLM pod to deploy, you can inspect the EKS NodePools by navigating to the [Amazon EKS cluster Console](https://console.aws.amazon.com/eks)

7. Click on your cluster name (i.e. eksworkshop)

8. Click on the   **Compute** tab, you will see there is now a new AWS Inferentia **inf2.xlarge** compute node

![inf2_node](/static/images/inf2_node.png)

:::alert{header="What to look for" type="info"}
In the EKS console Compute tab, you should see the `inf2.xlarge` node listed under the **inferentia** NodePool. The node status should show **Ready**. This confirms that EKS Auto Mode provisioned the Inferentia accelerated compute node in response to the vLLM pod's resource request for `aws.amazon.com/neuroncore: 2`.
:::

9. Click on the **Node name**, where it will show you the capacity allocation and Pod details relating to the inf2.xlarge compute node


### Summary
You have deployed the vLLM inference engine with the Mistral-7B model on AWS Inferentia.

:::alert{header="Don't wait — deploy the AI Gateway in parallel" type="success"}
The vLLM pod takes ~7 minutes to reach `Running` and load the model. **You do not need to wait for it.** Continue straight to the next section and deploy the LiteLLM AI Gateway now — it starts independently of vLLM and only needs the vLLM *Service* to exist (which it already does). Both will be ready by the time you open the chat UI.
:::

Continue to the next section to deploy the AI Gateway, which will sit in front of vLLM and provide model routing capabilities.
