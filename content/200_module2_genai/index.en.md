---
title : "Module 2: Deploy Generative AI Chat application"
weight : 200
---

## Module overview

In this module, you will configure and deploy A Generative-AI chatbot application on Kubernetes (Amazon EKS).
- You will deploy a vLLM Pod and a WebUI Pod on an existing Amazon EKS cluster
- The vLLM Pod will run on the AWS Inferentia Accelerators (AI Compute).
- The vLLM Pod will access the Mistral-7B model, which is stored on the FSx for NetApp based Persistent Volume.
- The storage architecture uses the NetApp Astra Trident CSI driver with ONTAP-backed volumes. The Mistral-7B model was pre-loaded onto the FSx for NetApp volume during workshop provisioning, so the vLLM inference pod can start serving without waiting for a model download.
