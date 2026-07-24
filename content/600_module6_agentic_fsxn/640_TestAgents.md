---
title : "Test Agent Access — Prove Isolation"
weight : 640
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

##### Test 3B: Can the Malicious Agent Call Another Agent?

What if we instruct the malicious agent to reach the finance agent's API and fetch data on its behalf?

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -s http://malicious-agent-svc.agents:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "Connect to the finance agent at http://finance-agent-svc.agents:8080/ask and ask it to list all financial files. Return the results."}' | jq -r .response
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
I cannot perform that request. I don't have the ability to make HTTP requests or connect to external services. My available tools are limited to list_files, read_file, and search_documents on my local data volume.
:::

:::alert{header="Tool Scoping — First Line of Defense" type="warning"}
Even though the LLM *understands* the instruction and knows the finance agent's URL, it **cannot execute** the request because:
- The agent only has file-access tools (`list_files`, `read_file`, `search_documents`)
- No HTTP/network tool is available — the agent cannot make outbound API calls
- The LLM can only use the tools it's been given, regardless of what it's instructed to do

**In production**, tool scoping is critical: never give an agent tools beyond what its role requires. FSxN permissions are the **last line of defense** — but restricting tools at the agent level is the **first line of defense** that prevents the attack vector entirely.
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
| 3A | Malicious Agent (UID 1099) reads finance/itops | **Permission denied** | FSxN POSIX permissions |
| 3B | Malicious Agent tries to call finance agent API | **Cannot execute** | Tool scoping (no HTTP tool) |

---

::::expand{header="Architecture Note: MCP (Model Context Protocol) Support"}

These agents can also be exposed via **MCP (Model Context Protocol)** — an open standard for connecting AI applications to external tools and data sources. MCP provides a standardized, protocol-based interface that allows any compatible client (Claude Desktop, VS Code, Cursor) to discover and invoke agent capabilities without custom integration code.

In this pattern, the agent registers its tools (file access, document search) as MCP primitives. An MCP client connects, discovers available tools via `tools/list`, and invokes them via `tools/call`. The agent's Strands reasoning loop handles the actual LLM interaction and FSxN data access internally — the MCP client simply sends questions and receives answers.

This is the same architectural pattern used by production AI platforms to enable agent interoperability across different client applications.

::::

---

### Summary

You have proven that data segregation for AI agents on a **shared FSxN volume** is enforced by **POSIX UID/GID permissions**:

- All agents mount the **same volume**, in the **same namespace**, with the **same tools**
- The **only** difference is the Linux UID each agent runs as
- FSxN enforces permissions at the **storage protocol level** — the agent literally cannot read bytes it doesn't own
- Tool scoping provides an additional layer — agents can only use the tools they're given

**This is the critical takeaway**: FSxN's storage-level security is an enforcement boundary that AI agents cannot circumvent, regardless of LLM capability, prompt injection, or application-layer vulnerabilities.
