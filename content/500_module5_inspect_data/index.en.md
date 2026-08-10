---
title : "Module 5 (Optional): Inspect vLLM & Neuron tools"
weight : 500
---

:::alert{header="Optional Module" type="info"}
This module is optional. You can skip it and proceed directly to the next module if time is limited.
:::

## Module Overview

One Persistent Volume can be shared with many Pods. Imagine the scenario where you need to host many AI models, or vast amounts of training data-sets, which will be accessed by countless Pods in your workload. You can store this data on a single Persistent Volume (PV) backed by Amazon FSx for NetApp ONTAP. This will allow you to have a centralized high-performance data store to service your application Pods, instead of creating countless individual local storage volumes attached to each of your countless Pods. This helps eliminate the inefficiency of duplicated data across local volumes, and also the wait time associated with copying data into each of the local volumes when you start a new Pod, decreasing Pod startup latency.

In this module, you will log into the vLLM pod and perform the following;
- View the Mistral model data structure and how it is stored on the persistent volume.
- Inspect Neuron cores and use Neuron tools to monitor performance.
