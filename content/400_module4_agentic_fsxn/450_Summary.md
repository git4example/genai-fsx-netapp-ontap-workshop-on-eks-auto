---
title : "Security Summary & Enterprise Patterns"
weight : 450
---

## What You Demonstrated

In this module, you built a real-world scenario where **multiple AI agents** with different roles access a shared storage system, and validated that **FSx for NetApp** native security enforces strict data boundaries regardless of what the AI Agent or LLM attempts.

![Defense in depth summary: Layer 1 is POSIX permissions (UID/GID and mode 750) enforced at the storage level by FSxN, Layer 2 is a Kubernetes NetworkPolicy blocking inter-agent traffic. The Finance agent (UID 1001) and IT Ops agent (UID 1002) each read their own directory as owner, while the Malicious agent (UID 1099) is denied on both because it owns neither](/static/images/SecuritySummary.png)

---

## Key Takeaways

### 1. Storage-Level Security is Non-Bypassable by AI Agents

Unlike application-layer controls (API keys, prompt guardrails, output filters), **ONTAP storage security operates below the agent's execution layer**. The agent process literally cannot read bytes it's not authorized to access. No prompt injection, jailbreak, or tool manipulation can override filesystem-level permissions.

### 2. Defense-in-Depth with FSx for NetApp Native Features

| Security Layer | FSxN Feature | What It Controls |
|---------------|-------------|-----------------|
| **File Access** | UNIX Permissions (UID/GID) | Which process UIDs can read/write files |
| **Network Access** | Export Policies | Which host IPs can NFS-mount a volume |
| **Data Isolation** | Volumes | Separate filesystem namespaces per domain |
| **Protocol** | Read-Only Mounts | Agents can read but never modify source data |
| **Encryption** | In-transit + at-rest | Data encrypted with ONTAP native encryption |

### 3. FSx for NetApp features - Role in Agentic AI workloads

| Feature | Role in Agentic AI |
|---------|-------------------|
| **Export Policies** | Per-volume IP-based access control, agents from wrong subnet can't mount |
| **UNIX Security** | UID/GID permissions, wrong agent process can't read files |
| **Volumes** | Logical data isolation, each domain has its own volume |
| **SnapMirror** | Replicate on-prem data to cloud for agent consumption |
| **Snapshots** | Point-in-time recovery if an agent's action corrupts data |
| **FPolicy** | Audit logging of all file access (which agent read what, when) |
| **WORM / SnapLock** | Immutable data for compliance, agents can read but never delete |
| **Multi-AZ** | High availability, agents dont lose access to data |


### 4. Same LLM, Different Access = Safe Multi-Tenancy

All three agents used the **same Mistral-7B LLM endpoint**. The intelligence is shared; the data access is segregated. This pattern enables:
- **Cost efficiency**: One LLM serving multiple teams
- **Governance**: Each team's data stays within its boundary
- **Auditability**: ONTAP audit logs track every file access per UID

---

## Clean Up (Optional)

If you want to remove the resources created in this module:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Delete the agents namespace (this removes all three agents, their services,
# the shared PVC, the data-population job, and any NetworkPolicy within it)
kubectl delete namespace agents

# Optionally delete the shared FSxN agent-data volume
# aws fsx delete-volume --volume-id <agent-shared-data-vol-id> --region $AWS_REGION
:::

---

## Summary

Application-layer guardrails (prompt engineering, output filtering) can be bypassed. Storage-layer controls cannot be bypassed (export policies, UNIX permissions, volume isolation).This module demonstrated AI agent data segregation on a **single FSx for ONTAP file system**, and highlighted FSx for NetApp provides enterprise-grade, multi-layered access control that keeps AI agents within their authorized data boundaries.

You have now completed the workshop.

You can continue to the optional modules for this workshop.
