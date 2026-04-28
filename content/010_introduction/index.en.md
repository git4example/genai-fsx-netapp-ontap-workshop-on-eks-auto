---
title: 'Introduction'
weight: 10
---

Copyright Amazon Web Services, Inc. and its affiliates. All rights reserved. This sample code is made available under the MIT-0 license. See the [LICENSE](./LICENSE.en.md) file.

Errors or corrections? Contact ppariksh@amazon.com, akbariw@amazon.com

-------------------------------------------------------------
## Workshop Objective
In this workshop, you will learn how you can:
1. Deploy a Generative AI chatbot application by deploying:
- A vLLM and an Open WebUI Pod on an Amazon EKS cluster to serve Mistral-7B model 
- Storing and accessing the Mistral-7B model on an Amazon FSx for NetApp ONTAP file system (Persistent Volume).
- Leverage AWS Inferentia Accelerator as your accelerated compute, to power your Generative AI workload
- Deploy a Grafana dashboard to view Inference workload metrics
2. Let EKS Auto Mode scale the number of EKS managed nodes based on Pod requests, enabling operational efficiency at-scale.
3. Configure Amazon FSx for NetApp ONTAP with the NetApp Astra Trident CSI driver, as your performant and scalable data layer to host your model and training data




****Target Audience****: DevOps engineers, Machine Learning Scientists/Engineers, Container & Storage engineers, Cloud Architects

****Prerequisites****: Recommended to have an fundamental understanding of AWS containers, and AWS Cloud

****Duration****: Approximately take 2 hours.

![lab-image-3](/static/images/lab-image-3.png)

-----

# Additional reading

<br></br>


#### Generative AI and Machine Learning
Generative AI and Machine Learning (ML) is helping businesses transform the way they operate and innovate. Generative AI refers to a class of Artificial Intelligence that leverages Large Language Models (LLM) in order to generate new content from a prompt, content such as text, images, audio, and software code.

#### What is a Large Language Model (LLM)
Large Language Models (LLMs) are a type of machine learning model that is trained on vast amounts of text data to learn the patterns and structure of natural language. These models can then be used for a wide range of natural language processing tasks, such as text generation, question answering, and language translation. In this lab we are going to use the open-source Mistral-7B-Instruct model, which is a specific LLM model with 7 billion parameters. The "Instruct" in the name refers to the fact that this model has been trained to follow instructions and perform a wide variety of tasks, beyond just generating text, i.e. it is suitable for chat applications. You will be using this open source LLM model in this workshop.


#### What is vLLM
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

#### Deploying Mistral-7B-Instruct using a vLLM on Amazon EKS
To provide text generation inference capability with an OpenAI-compatible endpoint, we will deploy the Mistral-7B-Instruct model using the vLLM framework on Amazon Elastic Kubernetes Service (EKS). We will let EKS Auto to spin up the AWS inferentia2 EC2 node (Accelerated Compute designed for Generative AI), where it will launch a vLLM Pod from an container image.

#### What is Amazon EKS (Elastic Kubernetes Service)
[**Amazon EKS**](https://aws.amazon.com/eks/), is a managed service that makes it easy for you to deploy, run, manage and scale container based apps using Kubernetes on AWS, without installing and operating your own Kubernetes control plane or worker nodes. Amazon EKS clusters can scale to support thousands of containers, which makes it ideal for Generative AI and ML workloads, where you can tune and deploy LLMs on Amazon EKS. Amazon EKS serves as an effective orchestrator to help achieve rapid scale out and scale in that is required for Generative AI and ML workloads, optimal cost efficiency.

#### How to consume the Inference Service
You can connect to the Inference Service using the **"Open WebUI"** application, which is designed to consume the OpenAI-compatible endpoint provided by the vLLM-hosted Mistral-7B-Instruct model that you will deploy in the workshop. The Open WebUI application allows users to interact with the LLM model through a chat-based interface. To use the Open WebUI application, simply deploy the application container, and connect to the Open WebUI URL that is provided and start chatting with the LLM model. The WebUI application will handle the communication with the vLLM hosted Mistral-7B-Instruct model, providing a seamless user experience.

#### What is Amazon FSx for NetApp ONTAP
[**Amazon FSx for NetApp ONTAP**](https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/what-is-fsx-ontap.html) is a fully managed shared storage service built on the NetApp ONTAP file system. FSx for ONTAP provides feature-rich, fast, and flexible shared file storage that is broadly accessible from Linux, Windows, and macOS compute instances running on AWS or on-premises.

Key concepts of FSx for NetApp ONTAP include:

- **File systems**: The primary resource in FSx for ONTAP. You specify the SSD storage capacity and throughput when creating a file system. A file system can contain one or more Storage Virtual Machines (SVMs).
- **Storage Virtual Machines (SVMs)**: An SVM is an isolated file server within a file system. Each SVM has its own set of administrative credentials and endpoints for accessing data. SVMs serve data to clients and contain one or more volumes.
- **Volumes**: Logical data containers within an SVM. Volumes are where your data is stored and organized. They are mountable via NFS, SMB, or iSCSI protocols.
- **NFS access**: FSx for ONTAP volumes can be accessed via NFS (Network File System), which is the most common protocol for shared read-write access in Kubernetes environments.
- **Snapshots**: FSx for ONTAP supports point-in-time snapshots of volumes, enabling you to create instant backups and restore data quickly without consuming additional storage for unchanged data.
- **Data tiering**: FSx for ONTAP automatically tiers infrequently accessed data from high-performance SSD storage to a lower-cost capacity pool, optimizing storage costs while maintaining performance for active data.

#### What is NetApp Astra Trident
[**NetApp Astra Trident**](https://docs.netapp.com/us-en/trident/index.html) is an open-source Container Storage Interface (CSI) driver that provides dynamic and static storage provisioning for Kubernetes using NetApp storage backends, including Amazon FSx for NetApp ONTAP. Trident integrates natively with Kubernetes, enabling you to create PersistentVolumes backed by ONTAP volumes using standard Kubernetes StorageClass and PersistentVolumeClaim resources. In this workshop, Trident is installed via Helm and configured with a TridentBackendConfig resource that connects to the pre-provisioned FSx for ONTAP file system and SVM.


#### Storing and accessing your model and training data
In this workshop the **Mistral-7B-Instruct** LLM model data is loaded onto an [**Amazon FSx for NetApp ONTAP**](https://aws.amazon.com/fsx/netapp-ontap/) volume using a Kubernetes Job that downloads the model from HuggingFace. Unlike FSx for Lustre, which can transparently import data from a linked S3 bucket, FSx for ONTAP requires an explicit model loading step. A Kubernetes Job runs before the vLLM inference pod starts, downloading the model files and writing them to the FSx for ONTAP-backed PersistentVolume. The vLLM Inference engine Pod deployment uses a PersistentVolumeClaim (PVC) that is dynamically provisioned by the NetApp Astra Trident CSI driver, backed by an FSx for ONTAP volume. When the vLLM Pod starts up, it loads the LLM model data (into its memory) directly from the FSx for ONTAP file system via NFS.


#### Accelerating your Compute
[**AWS Inferentia accelerators**](https://aws.amazon.com/machine-learning/inferentia/) are designed by AWS to deliver high performance at the lowest cost in Amazon EC2 for your deep learning (DL) and generative AI inference applications, where Inferentia2-based Amazon EC2 Inf2 instances are optimized to deploy increasingly complex models, such as large language models (LLM).


#### What are AWS Inferentia Accelerators
[**AWS Inferentia accelerators**](https://aws.amazon.com/machine-learning/inferentia/) are custom built machine learning chips designed by Amazon Web Services (AWS) to accelerate the inference phase of machine learning. Inference involves using a trained model to make predictions or decisions based on new data. This phase is critical for real-time applications and services that require low latency and high throughput. AWS Inferentia2 is designed to deliver high throughput and low latency for a variety of inference workloads. AWS Inferentia accelerators deliver high performance at the lowest cost in Amazon EC2, where it supports popular machine learning frameworks such as TensorFlow, PyTorch, and MXNet. AWS Inferentia2 based Amazon EC2 Inf2 instances are optimized to deploy increasingly complex models, such as large language models (LLM) and latent diffusion models.


#### AWS Neuron SDK - Native Support for ML Frameworks
[**AWS Neuron SDK**](https://aws.amazon.com/machine-learning/neuron/) is an SDK with a compiler, runtime, and profiling tools that unlocks high-performance and cost-effective deep learning (DL) acceleration. AWS Neuron SDK helps developers deploy models on the AWS Inferentia accelerators, where it integrates natively with popular frameworks, such as PyTorch and TensorFlow, so that you can continue to use your existing code and workflows and run on Inferentia accelerators.
