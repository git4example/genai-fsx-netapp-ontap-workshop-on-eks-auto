---
title : "Deploy Generative AI Chat application"
weight : 200
---

## Module Overview

In this module, you will configure and deploy a Generative-AI chatbot application on Kubernetes, by deploying a vLLM Pod and a WebUI Pod on an Amazon EKS cluster, store and access the Mistral-7B model using Amazon FSx for NetApp ONTAP with the Trident CSI driver for ONTAP-backed persistent storage, and leverage AWS Inferentia Accelerators as the accelerated compute for your Generative AI workload.

The storage architecture uses the NetApp Astra Trident CSI driver to dynamically provision ONTAP-backed volumes. A Kubernetes Job loads the model data onto the persistent volume before the vLLM inference pod starts.

![lab-image](/static/images/lab-image.png)
