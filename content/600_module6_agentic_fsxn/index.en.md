---
title : "Agentic AI with FSxN Native Access Control"
weight : 600
---

## Module Overview

In enterprise environments, **multiple AI agents** may operate against a shared storage layer — each requiring access to **only its designated data domain**. This module demonstrates how Amazon FSx for NetApp ONTAP's **native security features** (export policies, UNIX permissions, and volume-level isolation) enforce strict data boundaries for AI agents, preventing unauthorized access even when agents share the same cluster and LLM backend.

You will build **three AI agents** using [AWS Strands Agents SDK](https://github.com/strands-agents/sdk-python) (open source), each with a distinct role:

| Agent | Role | Data Access | Outcome |
|-------|------|-------------|---------|
| **Finance Agent** | Financial analyst | `/finance_data` volume only | Answers questions about financial reports |
| **IT Operations Agent** | IT Ops assistant | `/it_ops_data` volume only | Answers questions about runbooks and logs |
| **Malicious Agent** | Simulated attacker | Attempts both volumes | **Blocked** by FSxN native permissions |

:::alert{header="Why This Matters" type="info"}
As organizations deploy autonomous AI agents that can read, analyze, and act on data, **storage-level access control** becomes critical. Unlike application-layer auth that agents could potentially bypass, FSxN enforces permissions at the **storage protocol level** — the agent literally cannot read bytes it's not authorized to access, regardless of what the LLM instructs it to do.
:::

---

## Architecture

```
                         ┌─────────────────────────────────────────────────────────┐
                         │  EKS Cluster                                            │
                         │                                                         │
                         │  ┌──────────────────────────────────────────────────┐   │
                         │  │  Self-Hosted LLM (vLLM - Mistral-7B)            │   │
                         │  │  OpenAI-compatible API endpoint                  │   │
                         │  └────────────────────┬─────────────────────────────┘   │
                         │                       │ API calls                        │
                         │         ┌─────────────┼──────────────┐                  │
                         │         │             │              │                  │
                         │         ▼             ▼              ▼                  │
                         │  ┌────────────┐ ┌────────────┐ ┌────────────┐          │
                         │  │  Finance   │ │  IT Ops    │ │  Malicious │          │
                         │  │  Agent     │ │  Agent     │ │  Agent     │          │
                         │  │  (Strands) │ │  (Strands) │ │  (Strands) │          │
                         │  │            │ │            │ │            │          │
                         │  │ UID: 1001  │ │ UID: 1002  │ │ UID: 1099  │          │
                         │  │ Pod CIDR:A │ │ Pod CIDR:B │ │ Pod CIDR:C │          │
                         │  └─────┬──────┘ └─────┬──────┘ └──────┬─────┘          │
                         │        │              │               │                │
                         └────────┼──────────────┼───────────────┼────────────────┘
                                  │              │               │
                         ┌────────┼──────────────┼───────────────┼────────────────┐
                         │  FSx for NetApp ONTAP │               │                │
                         │        │              │               │                │
                         │        ▼              ▼               ▼                │
                         │  ┌────────────┐ ┌────────────┐  ┌─────────────────┐   │
                         │  │finance_data│ │ it_ops_data│  │  BLOCKED ✗      │   │
                         │  │            │ │            │  │                 │   │
                         │  │Export: CIDR │ │Export: CIDR│  │ Export Policy:  │   │
                         │  │  A only    │ │  B only    │  │ Denies CIDR C  │   │
                         │  │            │ │            │  │                 │   │
                         │  │Owner: 1001 │ │Owner: 1002 │  │ UNIX Perms:    │   │
                         │  │Perms: 0750 │ │Perms: 0750 │  │ Denies UID 1099│   │
                         │  └────────────┘ └────────────┘  └─────────────────┘   │
                         │                                                        │
                         └────────────────────────────────────────────────────────┘
```

**FSxN Security Layers Demonstrated:**

| Layer | Mechanism | What It Blocks |
|-------|-----------|---------------|
| **Export Policy** | IP/CIDR-based NFS access rules per volume | Unauthorized pod subnets cannot mount the volume |
| **UNIX Permissions** | UID/GID ownership + file mode (0750) | Even if mounted, wrong UID cannot read files |
| **Volume Isolation** | Separate ONTAP volumes per domain | No shared filesystem namespace between domains |

---

::::expand{header="Click here to learn about AWS Strands Agents SDK"}

#### AWS Strands Agents SDK

**Strands Agents** is an open-source Python SDK by AWS for building AI agents with tool-use capabilities. Key features:

- **Model-agnostic** — works with any OpenAI-compatible endpoint (including self-hosted vLLM)
- **Tool-based architecture** — agents have callable tools (Python functions) they can invoke based on user prompts
- **Lightweight** — minimal dependencies, easy to deploy as a container
- **Conversation loop** — agent reasons about the query, selects tools, executes them, and synthesizes a response

In this module, each agent has file-access tools (`list_files`, `read_file`, `search_documents`) that operate against its mounted FSxN volume. The LLM decides which tool to call; the storage layer decides whether the call succeeds.

::::

:::alert{header="Prerequisites" type="info"}
This module assumes you have completed **Modules 1-2** and have:
- A working EKS cluster with Trident CSI driver installed
- The vLLM Mistral-7B inference endpoint running (`vllm-mistral7b-service`)
- The primary FSx for NetApp ONTAP file system available
:::

