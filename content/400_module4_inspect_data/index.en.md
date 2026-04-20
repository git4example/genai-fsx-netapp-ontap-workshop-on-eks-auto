---
title : "Inspect vLLM & Neuron tools, and manage data with ONTAP snapshots"
weight : 400
---

## Module Overview

One Persistent Volume can be shared with many Pods. Imagine the scenario where you need to host many AI models, or vast amounts of training data-sets, which will be accessed by countless Pods in your workload. You can store this data on a single Persistent Volume (PV) backed by Amazon FSx for NetApp ONTAP. This will allow you to have a centralized high-performance data store to service your application Pods, instead of creating countless individual local storage volumes attached to each of your countless Pods. This helps eliminate the inefficiency of duplicated data across local volumes, and also the wait time associated with copying data into each of the local volumes when you start a new Pod, decreasing Pod startup latency.

FSx for NetApp ONTAP provides built-in data management features such as volume snapshots, which allow you to create point-in-time copies of your data with minimal overhead. Snapshots are space-efficient and can be used to quickly restore data or create clones for testing and experimentation.

In this module, you will log into the vLLM pod and perform the following;
- View the Mistral model data structure and how it is stored on the persistent volume.
- Inspect Neuron cores and use Neuron tools to monitor performance.
- Create and manage FSx for ONTAP volume snapshots to protect your model data.
