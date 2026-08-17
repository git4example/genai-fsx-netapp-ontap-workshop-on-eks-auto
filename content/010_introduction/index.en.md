---
title: 'Introduction'
weight: 10
---

Copyright Amazon Web Services, Inc. and its affiliates. All rights reserved. This sample code is made available under the MIT-0 license. See the [LICENSE](./LICENSE.en.md) file.

Errors or corrections? Please raise an issue in the workshop repository so the maintainers can pick it up.

-------------------------------------------------------------

## Workshop objective
Learn how to build your own self-hosted Generative-AI  application for performance, scale, and observability using an AWS AI stack that is comprised of;

* **Compute layer:** *AWS Inferentia* - Accelerated compute to power your Generative-AI application, using `inf2.xlarge` instances.
* **Workload hosting & Orchestration:** *Amazon Elastic Kubernetes Service (EKS)* - Host your Generative-AI & Agentic-AI applications.
* **Data layer:** *Amazon FSx for NetApp ONTAP* - Highly Available, High-performance shared storage used to host LLM models and unstructured data.

---

### In this workshop you will perform the following:

- **Build a Generative AI chatbot** - using open-source tools & model (Mistral-7B model, vLLM inference engine, Open WebUI interface)
- **Deploy Observability dashboards** - view token usage metrics & inference workload performance
- **Deploy an AI Gateway** - Enable flexibility across architecture and LLM models consumed
- **Deploy AI Agents** - and test Agentic-AI permissions boundaries enforced by Amazon FSx & Amazon EKS
- **Run through example prompt scenarios**

---

### Learning outcomes

By the end of this workshop you will be able to:

- **Provision accelerated inference capacity on EKS Auto Mode**, using a NodePool and NodeClass that constrain scheduling to AWS Inferentia instances, and explain why the Neuron device plugin and scheduler extension are required
- **Serve an open-weight LLM from shared storage**, deploying vLLM against a Mistral-7B model held on FSx for NetApp ONTAP and mounted over NFS by the Trident CSI driver
- **Choose between volume import and dynamic provisioning**, and verify which one Trident actually performed rather than trusting a `Bound` PVC
- **Front multiple model backends with a single endpoint**, routing self-hosted and Amazon Bedrock models through one AI gateway
- **Interpret inference telemetry**, reading token throughput, time to first token, and NeuronCore utilisation from Grafana to judge whether a deployment is healthy
- **Enforce data boundaries between AI agents** using FSx for NetApp ONTAP POSIX ownership and Kubernetes NetworkPolicies, and demonstrate that neither can be talked around by prompting
- **Use ONTAP snapshots for recovery and cloning** of model and application data

---

****Target Audience****: DevOps engineers, Machine Learning Scientists/Engineers, Platform engineers, Container & Storage engineers, Cloud Architects

****Prerequisites****: Recommended to have an fundamental understanding of AWS Cloud and Kubernetes

****Duration****: Approximately take 2 hours.

---

:::alert{header="Costs and cleanup" type="warning"}
**At an AWS-hosted event**, the lab account is provided for you and is deleted afterwards, so you incur no charges and no cleanup is required.

**Running this in your own account**, you pay for everything the workshop provisions. The significant items are the `inf2.xlarge` Inferentia instance that serves the model, the Multi-AZ FSx for NetApp ONTAP file system (1024 GiB SSD at 512 MB/s throughput), the EKS cluster, the Application Load Balancer, and the EC2 instance hosting the IDE. Expect single-digit US dollars per hour while everything is running, so a completed 2 hour run is modest, but an environment left running is not.

FSx for NetApp ONTAP and the Inferentia instance bill for as long as they exist, whether or not you are using them. Run the cleanup steps in the on-demand setup module as soon as you finish. Current pricing is on the [Amazon FSx for NetApp ONTAP](https://aws.amazon.com/fsx/netapp-ontap/pricing/), [Amazon EC2 Inf2](https://aws.amazon.com/ec2/instance-types/inf2/), and [Amazon EKS](https://aws.amazon.com/eks/pricing/) pricing pages.
:::

---

![Workshop architecture inside a VPC: an EKS cluster splits into an Inf2 node running vLLM and a C5 node running Open WebUI, the agents and a model-download Job. A user reaches Open WebUI through an ALB, Ingress and Service, and Open WebUI and the agents both call vLLM through the AI gateway. The Job pulls the Mistral 7B model from Hugging Face and writes it to FSx for NetApp ONTAP, which vLLM then reads](/static/images/fsxn-architecture.png)

-----

## Additional reading

This section covers the key technologies used in this workshop: Generative AI, LLMs, vLLM, Amazon EKS, Amazon FSx for NetApp ONTAP, NetApp Astra Trident, and AWS Inferentia accelerators. Expand below to learn more about each component.

::::expand{header="Click here to read more about the technologies used in this workshop"}

### Generative AI and machine learning
Generative AI and Machine Learning (ML) is helping businesses transform the way they operate and innovate. Generative AI refers to a class of Artificial Intelligence that leverages Large Language Models (LLM) in order to generate new content from a prompt, content such as text, images, audio, and software code.

### What is a large language model (LLM)
Large Language Models (LLMs) are a type of machine learning model that is trained on vast amounts of text data to learn the patterns and structure of natural language. These models can then be used for a wide range of natural language processing tasks, such as text generation, question answering, and language translation. In this lab we are going to use the open-source Mistral-7B-Instruct model, which is a specific LLM model with 7 billion parameters. The "Instruct" in the name refers to the fact that this model has been trained to follow instructions and perform a wide variety of tasks, beyond just generating text, i.e. it is suitable for chat applications. You will be using this open source LLM model in this workshop.


### What is vLLM
[**vLLM (Virtual Large Language Model)**](https://github.com/vllm-project/vllm) is an open-source, easy-to-use, library for LLM inference and serving. It provides a framework that allows LLM models such as Mistral-7B-Instruct, to be deployed to provide text generation inference. vLLM provides an API that is compatible with OpenAI API, making it easy to integrate LLM applications.

**vLLM is fast with:**
- State-of-the-art serving throughput
- Efficient management of attention key and value memory with PagedAttention
- Continuous batching of incoming request
- Fast model execution with CUDA/HIP graph

**vLLM is flexible and easy to use with:**
- Seamless integration with popular HuggingFace models
- OpenAI-compatible API server
- Prefix caching support
- Supports chipsets such as: AWS Neuron, NVIDIA GPUs and others,

### Deploying Mistral-7B-Instruct using a vLLM on Amazon EKS
To provide text generation inference capability with an OpenAI-compatible endpoint, we will deploy the Mistral-7B-Instruct model using the vLLM framework on Amazon Elastic Kubernetes Service (EKS). We will let EKS Auto to spin up the AWS inferentia2 EC2 node (Accelerated Compute designed for Generative AI), where it will launch a vLLM Pod from an container image.

### What is Amazon EKS (Elastic Kubernetes Service)
[**Amazon EKS**](https://aws.amazon.com/eks/), is a managed service that makes it easy for you to deploy, run, manage and scale container based apps using Kubernetes on AWS, without installing and operating your own Kubernetes control plane or worker nodes. Amazon EKS clusters can scale to support thousands of containers, which makes it ideal for Generative AI and ML workloads, where you can tune and deploy LLMs on Amazon EKS. Amazon EKS serves as an effective orchestrator to help achieve rapid scale out and scale in that is required for Generative AI and ML workloads, optimal cost efficiency.

### How to consume the inference service
You can connect to the Inference Service using the **"Open WebUI"** application, which is designed to consume the OpenAI-compatible endpoint provided by the vLLM-hosted Mistral-7B-Instruct model that you will deploy in the workshop. The Open WebUI application allows users to interact with the LLM model through a chat-based interface. To use the Open WebUI application, simply deploy the application container, and connect to the Open WebUI URL that is provided and start chatting with the LLM model. The WebUI application will handle the communication with the vLLM hosted Mistral-7B-Instruct model, providing a seamless user experience.

### What is Amazon FSx for NetApp ONTAP
[**Amazon FSx for NetApp ONTAP**](https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/what-is-fsx-ontap.html) is a fully managed shared storage service built on the NetApp ONTAP file system. FSx for ONTAP provides feature-rich, fast, and flexible shared file storage that is broadly accessible from Linux, Windows, and macOS compute instances running on AWS or on-premises.

Key concepts of FSx for NetApp ONTAP include:

- **File systems**: The primary resource in FSx for ONTAP. You specify the SSD storage capacity and throughput when creating a file system. A file system can contain one or more Storage Virtual Machines (SVMs).
- **Storage Virtual Machines (SVMs)**: An SVM is an isolated file server within a file system. Each SVM has its own set of administrative credentials and endpoints for accessing data. SVMs serve data to clients and contain one or more volumes.
- **Volumes**: Logical data containers within an SVM. Volumes are where your data is stored and organized. They are mountable via NFS, SMB, or iSCSI protocols.
- **NFS access**: FSx for ONTAP volumes can be accessed via NFS (Network File System), which is the most common protocol for shared read-write access in Kubernetes environments.
- **Snapshots**: FSx for ONTAP supports point-in-time snapshots of volumes, enabling you to create instant backups and restore data quickly without consuming additional storage for unchanged data.
- **Data tiering**: FSx for ONTAP automatically tiers infrequently accessed data from high-performance SSD storage to a lower-cost capacity pool, optimizing storage costs while maintaining performance for active data.

### What is NetApp Astra Trident
[**NetApp Astra Trident**](https://docs.netapp.com/us-en/trident/index.html) is an open-source Container Storage Interface (CSI) driver that provides dynamic and static storage provisioning for Kubernetes using NetApp storage backends, including Amazon FSx for NetApp ONTAP. Trident integrates natively with Kubernetes, enabling you to create PersistentVolumes backed by ONTAP volumes using standard Kubernetes StorageClass and PersistentVolumeClaim resources. In this workshop, Trident is installed via Helm and configured with a TridentBackendConfig resource that connects to the pre-provisioned FSx for ONTAP file system and SVM.


### Storing and accessing your model and training data
In this workshop the **Mistral-7B-Instruct** LLM model data is loaded onto an [**Amazon FSx for NetApp ONTAP**](https://aws.amazon.com/fsx/netapp-ontap/) volume using a Kubernetes Job that downloads the pre-compiled model from HuggingFace. This is a one-time operation: once the model data is on the FSx for ONTAP volume, it persists across pod restarts and redeployments, and it has already been done for you during workshop provisioning. The vLLM Inference engine Pod deployment uses a PersistentVolumeClaim (PVC) that the NetApp Astra Trident CSI driver binds to that pre-provisioned FSx for ONTAP volume. When the vLLM Pod starts up, it loads the LLM model data (into its memory) directly from the FSx for ONTAP file system via NFS.


### Accelerating your compute
[**AWS Inferentia accelerators**](https://aws.amazon.com/machine-learning/inferentia/) are designed by AWS to deliver high performance at the lowest cost in Amazon EC2 for your deep learning (DL) and generative AI inference applications, where Inferentia 2 based Amazon EC2 Inf2 instances are optimized to deploy increasingly complex models, such as large language models (LLM).


### What are AWS Inferentia accelerators
[**AWS Inferentia accelerators**](https://aws.amazon.com/machine-learning/inferentia/) are custom built machine learning chips designed by Amazon Web Services (AWS) to accelerate the inference phase of machine learning. Inference involves using a trained model to make predictions or decisions based on new data. This phase is critical for real-time applications and services that require low latency and high throughput. AWS Inferentia is designed to deliver high throughput and low latency for a variety of inference workloads. AWS Inferentia accelerators deliver high performance at the lowest cost in Amazon EC2, where it supports popular machine learning frameworks such as TensorFlow, PyTorch, and MXNet. AWS Inferentia-based Amazon EC2 Inf2 instances are optimized to deploy increasingly complex models, such as large language models (LLM) and latent diffusion models.


### AWS Neuron SDK, native support for ML frameworks
[**AWS Neuron SDK**](https://aws.amazon.com/machine-learning/neuron/) is an SDK with a compiler, runtime, and profiling tools that unlocks high-performance and cost-effective deep learning (DL) acceleration. AWS Neuron SDK helps developers deploy models on the AWS Inferentia accelerators, where it integrates natively with popular frameworks, such as PyTorch and TensorFlow, so that you can continue to use your existing code and workflows and run on Inferentia accelerators.

::::
