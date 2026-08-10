---
title : "Inspect vLLM, Mistral-7B model, and Neuron performance tools"
weight : 510

---

## Overview

In this section, you will log-in to the vLLM Pod, inspect the Mistral-7B  model, Inspect Neuron cores and use Neuron tools to monitor performance.


##### Step 1: Login to vLLM Pod, Inspect LLM model data

1. Navigate to back to your VSCode IDE terminal and change to your working directory.

::code[cd /home/participant/environment/eks/FSxONTAP]{language=bash showLineNumbers=false showCopyAction=true}

2. Now lets log into the vLLM Pod, first we need to get the pod name by running the following command

::code[kubectl get pods]{language=bash showLineNumbers=false showCopyAction=true}

From the output, copy the name shown in your environment that starts with **vllm**

![vllm_name](/static/images/vllm_name.png)

3. Log into your vLLM pod by running the below command, by replacing the value of **YOUR-vLLM-POD-NAME** with the value you just copied.

::code[kubectl exec -it YOUR-vLLM-POD-NAME -- bash]{language=bash showLineNumbers=false showCopyAction=true}



4. We will now inspect the layout of the model data on the vLLM. When you run the below command you will see a mount point called **work-dir**, which is the mount location of your Persistent Volume Claim (backed by your FSx for NetApp ONTAP volume, served via NFS).


::code[df -h]{showCopyAction=true showLineNumbers=false language=bash}


![vllm_02](/static/images/vllm_02.png)

5. Lets inspect what's stored on this Persistent Volume which is mounted as */work-dir*

:::code{showCopyAction=true showLineNumbers=true language=bash}
cd /work-dir/
ls -ll
:::

You can see the Mistral-7B Model is stored here.

:::alert{header="Note" type="info"}
**All the files you see listed under */work-dir* were downloaded to the FSx for NetApp ONTAP volume by the Model Loading Kubernetes Job** that ran earlier in the workshop. The Job used the `huggingface-cli` tool to download the Mistral-7B-Instruct-v0.3 model directly from HuggingFace and wrote the files to the ONTAP-backed Persistent Volume. The vLLM pod mounts this same volume via NFS, giving it direct access to the model data. FSx for NetApp ONTAP serves the data over NFS (TCP 2049), providing low-latency, high-throughput access to the model files from the Persistent Volume.
:::




Lets have a look at what the model data structure looks like.

:::code{showCopyAction=true showLineNumbers=true language=bash}
cd Mistral-7B-Instruct-v0.3/
ls -ll
:::


Here is a description of the model data you are seeing in the Mistral model folder.

| File(s) | Purpose | Details |
|------|-----------|-----------|
| `model-00001-of-00003.safetensors` … `model-00003-of-00003.safetensors` | Original model weights in SafeTensors format | The Mistral-7B weights split across 3 shards (~14.5 GB total). SafeTensors is a safe, fast serialization format for tensors. |
| `consolidated.safetensors` | Consolidated model weights | A single-file copy of all weights, used by the Neuron runtime for efficient sharding across NeuronCores. |
| `model.pt` | Pre-compiled Neuron executable (NEFF) | Contains the compiled computation graph for Neuron hardware (SDK 2.26.1). This is what allows vLLM to skip on-the-fly compilation at startup. |
| `neuron_config.json` | Neuron compilation config | Records the compilation parameters (tp_degree, batch_size, seq_len, etc.) so the runtime can verify the NEFF matches the current deployment config. |
| `tokenizer.model`, `tokenizer.model.v3`, `tokenizer.json` | Tokenizer vocabulary and rules | Converts raw text to/from numerical tokens. The `.v3` variant is the Mistral v0.3 tokenizer with an expanded vocabulary. |
| `config.json`, `generation_config.json`, `params.json` | Model architecture and generation settings | Defines the model structure (hidden size, layers, heads, etc.) and default generation parameters. |
| `special_tokens_map.json`, `tokenizer_config.json` | Tokenizer configuration | Maps special tokens (BOS, EOS, PAD) and tokenizer settings. |

:::alert{header="Note" type="info"}
This workshop uses **pre-compiled Neuron artifacts** (`model.pt` + `neuron_config.json`) that were compiled with SDK 2.26.1 and uploaded to HuggingFace. When vLLM starts, it detects these artifacts via the `NEURON_COMPILED_ARTIFACTS` environment variable and loads them directly onto the NeuronCores, skipping the compilation step entirely. Without pre-compiled artifacts, the Neuron compiler (`neuronx-cc`) would need to compile the model on first startup, which takes 15+ minutes and requires significantly more memory than inf2.xlarge provides.
:::

::::expand{header="What is Neuron compilation and how are pre-compiled artifacts generated? (click to expand)"}

**Why compilation is needed**

Standard PyTorch models are designed for GPUs or CPUs. AWS Inferentia NeuronCores use a different instruction set, so the model's computation graph must be **compiled** into **NEFF (Neuron Executable File Format)**, an optimized binary that the Neuron hardware can execute directly. This compilation is performed by the **Neuron Compiler** (`neuronx-cc`), which is part of the AWS Neuron SDK.

**What happens during compilation**

The compiler takes the model's PyTorch operations, optimizes them for the Neuron architecture (operator fusion, memory layout, tensor parallelism across NeuronCores), and produces a `model.pt` file (the NEFF binary) along with a `neuron_config.json` that records the compilation parameters. These parameters include:
- **tp_degree**: tensor parallel degree (number of NeuronCores, e.g., 2)
- **batch_size**: maximum concurrent requests (e.g., 4)
- **seq_len**: maximum sequence length (e.g., 4096 tokens)
- **Neuron SDK version**: the compiled artifacts are tied to a specific SDK version

**How to generate pre-compiled artifacts**

Compilation is typically done on a larger instance (e.g., inf2.8xlarge or inf2.24xlarge) that has enough memory for the compiler. You run the same DLC container image used for inference. When the Neuron runtime detects no pre-compiled artifacts, it automatically invokes `neuronx-cc` to compile the model on first startup. Once compiled, the artifacts are saved alongside the model weights and can be uploaded to a model registry for reuse.

:::code{showCopyAction=false showLineNumbers=true language=bash}
# On a larger instance (e.g., inf2.8xlarge) with sufficient memory:
# 1. Run the vLLM DLC container with the model (it will auto-compile on first run)
docker run -v ./model:/work-dir \
  -e NEURON_COMPILED_ARTIFACTS=/work-dir/Mistral-7B-Instruct-v0.3 \
  public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.9.1-neuronx-py311-sdk2.26.1-ubuntu22.04 \
  vllm serve /work-dir/Mistral-7B-Instruct-v0.3 \
  --device neuron --tensor-parallel-size 2 \
  --max-model-len 4096 --max-num-seqs 4

# 2. The Neuron runtime inside the container detects no NEFF artifacts at
#    the NEURON_COMPILED_ARTIFACTS path, invokes neuronx-cc to compile,
#    and saves model.pt + neuron_config.json to that same directory.
#    This takes 15-30+ minutes.

# 3. After compilation completes, the compiled artifacts are stored
#    alongside the model weights in the mounted volume. Upload the
#    entire directory to HuggingFace or S3 for reuse.
:::

**Why pre-compilation matters for production**

| Approach | Startup time | Memory needed | Best for |
|---|---|---|---|
| Compile on first run | 15–30+ minutes | High (compiler overhead) | Development, one-off testing |
| Pre-compiled artifacts | 1–2 minutes | Low (just weight loading) | Production, workshops, CI/CD |

Pre-compiled artifacts must match the exact SDK version, tp_degree, batch_size, and seq_len of the deployment. If any parameter changes, the model must be recompiled.

For more information, see the [Neuron Compiler documentation](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/compiler/index.html).

::::



##### Step 2: Inspect Neuron cores config and performance

Run the below command to view the number of AWS Inferentia2 devices on your instance.

::code[neuron-ls]{showCopyAction=true showLineNumbers=false language=bash}

:::code[neuron-ls]{showCopyAction=false showLineNumbers=false language=bash}
instance-type: inf2.xlarge
instance-id: i-123456abcd00
+--------+--------+----------+--------+--------------+------+----------+------+---------+
| NEURON | NEURON |  NEURON  | NEURON |     PCI      | PID  |   CPU    | NUMA | RUNTIME |
| DEVICE | CORES  | CORE IDS | MEMORY |     BDF      |      | AFFINITY | NODE | VERSION |
+--------+--------+----------+--------+--------------+------+----------+------+---------+
| 0      | 2      | 0-1      | 32 GB  | 0000:00:1f.0 | 4290 | 0-3      | -1   | 2.28.23 |
+--------+--------+----------+--------+--------------+------+----------+------+---------+
:::

Let's view the performance of your AWS Inferentia2 node by running the **neuron-top** command. The neuron-top command provides information about NeuronCore and vCPU utilization, memory usage, loaded models, and Neuron applications.

::code[neuron-top]{showCopyAction=true showLineNumbers=false language=bash}

![neuron-top](/static/images/neuron-top.png)

Now re-size the neuron-top browser window and also the existing WebUI browser session to your Chatbot, so they are side-by-side on your monitor.

Ask the Chatbot a question, and then pay close attention to the **NeuronCores V2 utilization section** as your Chatbot processes your input/output tokens. Notice the optimized performance of AWS Inferentia2, which is designed to use all available Neuron core utilization capacity to process a request.

Press `q` to exit from `neuron-top` screen and return back to pod exec shell.

::code[q]{showCopyAction=true showLineNumbers=false language=bash}


Finally exit from the pod, and back to the terminal window for the next module.

::code[exit]{showCopyAction=true showLineNumbers=false language=bash}

## Summary

In this module you have logged into the vLLM, viewed the mounted PV and the hosted Mistal model data, and used the Neuron tools to monitor performance.
