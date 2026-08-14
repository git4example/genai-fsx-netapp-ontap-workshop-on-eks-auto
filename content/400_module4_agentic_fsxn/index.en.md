---
title : "Module 4: Agentic AI with FSxN Native Access Control"
weight : 400
---

## Module overview

Within enterprise environments, **multiple AI agents** could be accessing a shared data layer (such as a FSx for Netapp based file share), where each AI Agent requires access to **only its designated data or folders**. This module demonstrates how FSx for NetApp ONTAP's **native POSIX permissions** (UID/GID ownership + file mode) enforces data boundaries for AI agents, even when all agents share the same volume, same namespace, and same LLM backend.

To view the data boundary enforcement, in this module you will deploy **three AI Agents** using [AWS Strands Agents SDK](https://github.com/strands-agents/sdk-python) (open source). Two of the AI Agent have distinct roles and related data access (Finance Agent & IT Operations Agent), and a third AI Agent will be used to simulate a Malicious AI Agent that will try to access data that it doesn't have access to, via different methods.

All AI Agents mount the **same PVC** (`agent-shared-data`) which is hosted on an FSx for NetApp volume. There is no volume-level isolation, no namespace separation, and no Kubernetes RBAC involved. The **ONLY** access control mechanism is POSIX UID/GID permissions set on the FSxN volume subdirectories.

The AI agent data volume and permissions are already configured for you as part of the workshop provisioning, so you can simply test out the lab scenario.

| Agent | Role | UID | Data Path the Agent Can Access | Purpose |
|-------|------|-----|-----------|-----------|
| **Finance Agent** | Financial analyst | 1001 | `/data/finance` | Access financial reports |
| **IT Operations Agent** | IT Ops assistant | 1002 | `/data/itops` | Access runbooks and logs |
| **Malicious Agent** | Simulated attacker | 1099 | **Neither**, permission denied | Attempt to access everything |

:::alert{header="Why This Matters" type="info"}
As organizations deploy autonomous AI agents that can read, analyze, and act on data, **storage-level access control** becomes critical. Unlike application-layer auth that agents could potentially bypass, FSx for NetApp enforces permissions at the **NFS protocol level**, so the AI agents are only authorized to access their configured data, regardless of what the LLM instructs the AI Agents to do.
:::

---

## Architecture

![Agent architecture: three agents in the agents namespace mount one shared FSx for ONTAP volume, where POSIX ownership grants the Finance and IT Ops agents read access to their own directory and denies the Malicious agent, while all three reach the same LiteLLM AI Gateway](/static/images/Agent-Architecture.png)


---

::::expand{header="Click here to learn about AWS Strands Agents SDK"}

### AWS Strands Agents SDK

**Strands Agents** is an open-source Python SDK by AWS for building AI agents with tool-use capabilities. Key features:

- **Model-agnostic**: works with any OpenAI-compatible endpoint (including self-hosted vLLM)
- **Tool-based architecture**: agents have callable tools (Python functions) they can invoke based on user prompts
- **Lightweight**: minimal dependencies, easy to deploy as a container
- **Conversation loop**: agent reasons about the query, selects tools, executes them, and synthesizes a response

In this module, each agent has file-access tools (`list_files`, `read_file`, `search_documents`) that operate against its mounted FSxN volume. The LLM decides which tool to call; the storage layer decides whether the call succeeds.

::::
