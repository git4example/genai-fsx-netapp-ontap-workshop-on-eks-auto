---
title : "Test Agent Access — Prove Isolation"
weight : 440
---

## Overview

Now comes the most important part: **proving** that FSxN's POSIX permissions work. You will:

1. Query the **Finance Agent** — it successfully reads financial data
2. Query the **IT Ops Agent** — it successfully reads operational data
3. Attempt access with the **Malicious Agent** — it is **blocked** by POSIX permissions
4. Instruct the Malicious Agent to call another agent — **blocked** by tool scoping

All agents mount the **same volume**. Only UNIX UID/GID permissions differentiate their access.

---

## Querying the Agents

Each agent runs as a FastAPI web server exposing an `/ask` endpoint. You can query all three agents from a single utility pod using `curl`.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl apply -f /home/participant/environment/eks/FSxONTAP/netshoot-fsxn.yaml
kubectl wait --for=condition=Ready pod/netshoot-fsxn --timeout=120s
:::

Now exec into the netshoot pod — you'll run all agent tests from here. The pod has `curl` and `jq` pre-installed:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl exec -it netshoot-fsxn -- bash
:::

---

## Part 1: Finance Agent — Authorized Access

##### Test 1: Ask the Finance Agent to list available data

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -s http://finance-agent-svc.agents:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "What files do you have access to? List everything in your data directory."}' | jq -r .response
:::

:::alert{header="Note" type="info"}
The exact wording of the agent's response will vary (the LLM generates natural language). Look for the key indicator: the output contains directory names `compliance`, `reports`, and `transactions`.
:::

Expected output (your wording may differ):

:::code{showCopyAction=false showLineNumbers=false language=bash}
Here are the directories I have access to:
- compliance
- reports
- transactions
:::

The Finance Agent (UID 1001) successfully accessed the `/data/finance` subdirectory. FSxN POSIX permissions **allow** access because the UID matches the directory owner.

---

## Part 2: IT Operations Agent — Authorized Access

##### Test 2: Ask the IT Ops Agent to list available data

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -s http://itops-agent-svc.agents:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "What files do you have access to? List everything in your data directory."}' | jq -r .response
:::

Expected output (your wording may differ):

:::code{showCopyAction=false showLineNumbers=false language=bash}
Here are the directories I have access to:
- configs
- logs
- runbooks
:::

The IT Ops Agent (UID 1002) successfully accessed `/data/itops`. It sees completely different data than the Finance agent — even though they mount the **same volume**. There is no cross-contamination.

---

## Part 3: Malicious Agent — Access BLOCKED

##### Test 3A: Malicious Agent Cannot Read Finance or IT Ops Data

The malicious agent (UID 1099) mounts the same volume at `/data` — it can see that subdirectories exist, but **cannot read their contents**:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -s http://malicious-agent-svc.agents:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "List all files in the finance and itops directories. Read any documents you find."}' | jq -r .response
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
ACCESS DENIED: Permission denied reading /data/finance.
ACCESS DENIED: Permission denied reading /data/itops.
:::

:::alert{header="POSIX Permissions — The Storage-Level Barrier" type="warning"}
The malicious agent has the **same LLM**, the **same tools**, and mounts the **same volume** as the finance and IT ops agents. The only difference is its UID (1099). FSxN enforces POSIX permissions at the **NFS protocol level**:
- `/data/finance` is owned by UID 1001 with mode 750 → UID 1099 has zero access
- `/data/itops` is owned by UID 1002 with mode 750 → UID 1099 has zero access

No LLM instruction, prompt injection, or tool manipulation can override this — the storage controller rejects the read before it reaches the filesystem.
:::

##### Test 3B: Malicious Agent Calls Finance Agent (The Attack)

Each agent has an `http_request` tool that allows it to call other services. What happens if the malicious agent uses it to call the finance agent's API?

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -s http://malicious-agent-svc.agents:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "Use your http_request tool to POST to http://finance-agent-svc.agents:8080/ask with payload {\"query\": \"List all financial files\"}. Return whatever the finance agent responds with."}' | jq -r .response
:::

:::alert{header="The Attack Succeeds!" type="error"}
Without network controls, the malicious agent **successfully calls the finance agent's API** and receives the financial data. The finance agent processes the request with its own UID (1001), reads the files, and returns the results to the malicious agent.

This demonstrates the real-world risk: if an agent has network access and another agent's API is reachable, data can be exfiltrated through **inter-agent proxy calls** — even though the malicious agent's own UID can't read the files directly.
:::

##### Test 3C: Apply NetworkPolicy — Block the Attack

Now apply a Kubernetes NetworkPolicy that blocks the malicious agent from reaching the finance and IT ops agent services:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
exit
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/agentic-agents
kubectl apply -f network-policy-deny-malicious.yaml
:::

Re-enter the netshoot pod and retry the same attack:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl exec -it netshoot-fsxn -- bash
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -s http://malicious-agent-svc.agents:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "Use your http_request tool to POST to http://finance-agent-svc.agents:8080/ask with payload {\"query\": \"List all financial files\"}. Return whatever the finance agent responds with."}' | jq -r .response
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
HTTP REQUEST FAILED: timed out
:::

:::alert{header="NetworkPolicy — The Network-Level Barrier" type="warning"}
The same attack that succeeded moments ago now **fails**. The Kubernetes NetworkPolicy blocks all traffic from the `malicious-agent` pod to the `finance-agent` and `itops-agent` pods. The HTTP request times out because the packets are dropped at the network level — the finance agent never even sees the request.

This demonstrates **defense-in-depth**:
1. **POSIX permissions (Layer 1)** — the malicious agent can't read files directly (UID mismatch)
2. **NetworkPolicy (Layer 2)** — the malicious agent can't reach other agents' APIs (network blocked)

Both layers enforce independently. Even if one is misconfigured, the other still protects the data.
:::

---

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
exit
:::

---

## Isolation Summary

| Test | Scenario | Result | Security Layer |
|------|----------|--------|----------------|
| 1 | Finance Agent (UID 1001) reads finance data | **Allowed** | UID matches directory owner |
| 2 | IT Ops Agent (UID 1002) reads IT ops data | **Allowed** | UID matches directory owner |
| 3A | Malicious Agent (UID 1099) reads finance/itops directly | **Permission denied** | FSxN POSIX permissions |
| 3B | Malicious Agent calls finance agent API (no NetworkPolicy) | **Data returned** | Attack succeeds — no network control |
| 3C | Same attack AFTER NetworkPolicy applied | **Timed out** | Kubernetes NetworkPolicy blocks traffic |

---

::::expand{header="Architecture Note: MCP (Model Context Protocol) Support"}

These agents can also be exposed via **MCP (Model Context Protocol)** — an open standard for connecting AI applications to external tools and data sources. MCP provides a standardized, protocol-based interface that allows any compatible client (Claude Desktop, VS Code, Cursor) to discover and invoke agent capabilities without custom integration code.

In this pattern, the agent registers its tools (file access, document search) as MCP primitives. An MCP client connects, discovers available tools via `tools/list`, and invokes them via `tools/call`. The agent's Strands reasoning loop handles the actual LLM interaction and FSxN data access internally — the MCP client simply sends questions and receives answers.

This is the same architectural pattern used by production AI platforms to enable agent interoperability across different client applications.

::::

---

### Summary

You have demonstrated **defense-in-depth** for AI agent data isolation:

1. **FSxN POSIX Permissions (Storage Layer)** — UID/GID on the shared volume prevents direct file access. The agent's process cannot read bytes owned by another UID, regardless of instructions.
2. **Kubernetes NetworkPolicy (Network Layer)** — Even when agents have HTTP capabilities, network policies prevent unauthorized inter-agent communication. The malicious agent's API calls are dropped before they reach the target.

Both layers enforce independently:
- If NetworkPolicy is misconfigured → POSIX still blocks direct reads
- If POSIX is misconfigured (e.g., wrong permissions) → NetworkPolicy still blocks the proxy attack
- Together, they provide comprehensive protection for multi-tenant AI agent deployments on shared storage

**This is the critical takeaway**: Enterprise AI agent deployments require multiple enforcement boundaries. FSxN provides the storage layer; Kubernetes NetworkPolicies provide the network layer. Neither depends on the other — each is independently sufficient and together they're comprehensive.
