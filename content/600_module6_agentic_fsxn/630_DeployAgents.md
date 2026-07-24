---
title : "Deploy Strands AI Agents"
weight : 630
---

## Overview

In this section, you will deploy **three AI agents** built with the [AWS Strands Agents SDK](https://github.com/strands-agents/sdk-python). Each agent:

- Uses the **LiteLLM AI Gateway** (`workshop-llm-tools` model) — which routes to Amazon Bedrock Claude Haiku 4.5 for reliable tool-calling
- Has the **same tool capabilities** (list files, read files, search documents)
- Mounts the **same shared FSxN volume** via the `agent-shared-data` PVC
- Runs with a specific **UID** that determines which subdirectory it can access

The difference: **POSIX UID/GID permissions on FSxN** determine which data each agent can actually read — same volume, same tools, only the UID differs.

:::alert{header="AI Gateway Model Routing" type="info"}
In Module 2, you deployed the LiteLLM AI Gateway with two named models:
- **`workshop-llm`** → self-hosted Mistral-7B (used by OpenWebUI for chat)
- **`workshop-llm-tools`** → Bedrock Claude Haiku 4.5 (used by agents for tool-calling)

These agents request `workshop-llm-tools` because agentic workloads require reliable structured tool execution. The gateway routes this to Bedrock Claude Haiku 4.5, which excels at selecting and calling tools with properly formatted arguments.
:::

---

##### Step 1: Review the Agent Application Code

::::expand{header="Click to review agent.py — the Strands AI Agent code"}

::code[cat /home/participant/environment/eks/agentic-agents/agent-app/agent.py]{language=bash showLineNumbers=false showCopyAction=true}

:::code[]{language=python showLineNumbers=true showCopyAction=false}
# agent.py — Strands AI Agent with FSxN file-access tools
import os
import glob
from strands import Agent, tool
from strands.models.openai import OpenAIModel

# Connect to the LiteLLM AI Gateway — routes tool-calls to Bedrock
model = OpenAIModel(
    client_args={
        "base_url": os.environ.get("LLM_ENDPOINT", "http://litellm-service.default.svc.cluster.local:4000/v1"),
        "api_key": os.environ.get("LLM_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("LLM_MODEL_ID", "workshop-llm-tools"),
)

DATA_DIR = os.environ.get("DATA_DIR", "/data")

@tool
def list_files(directory: str = "") -> str:
    """List files and directories in the agent's data volume."""
    # ... reads from DATA_DIR, returns contents or ACCESS DENIED

@tool
def read_file(filepath: str) -> str:
    """Read the contents of a file from the agent's data volume."""
    # ... reads file, returns content or ACCESS DENIED

@tool
def search_documents(query: str) -> str:
    """Search for a keyword across all documents."""
    # ... searches files, returns matches or ACCESS DENIED
:::

::::

##### Step 2: Deploy All Three Agents

All agents deploy into the **same namespace** (`agents`) and mount the **same PVC** (`agent-shared-data`). The only difference is the UID and the `DATA_DIR` subdirectory:

| Agent | UID | DATA_DIR | Purpose |
|-------|-----|----------|---------|
| Finance Agent | 1001 | `/data/finance` | Access financial reports |
| IT Ops Agent | 1002 | `/data/itops` | Access runbooks and logs |
| Malicious Agent | 1099 | `/data` | Attempt to access everything |

Deploy all three agents:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/agentic-agents
export AGENT_IMAGE="public.ecr.aws/parikshit/fsxn-strands-agent:latest"
envsubst '$AGENT_IMAGE' < agents-deployment.yaml | kubectl apply -f -
:::

##### Step 3: Verify All Agents Are Running

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl get pods -n agents
kubectl get svc -n agents
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
NAME                              READY   STATUS    RESTARTS   AGE
finance-agent-xxxxx-xxxxx         1/1     Running   0          30s
itops-agent-xxxxx-xxxxx           1/1     Running   0          30s
malicious-agent-xxxxx-xxxxx       1/1     Running   0          30s

NAME                  TYPE        CLUSTER-IP       PORT(S)    AGE
finance-agent-svc     ClusterIP   172.20.x.x       8080/TCP   30s
itops-agent-svc       ClusterIP   172.20.x.x       8080/TCP   30s
malicious-agent-svc   ClusterIP   172.20.x.x       8080/TCP   30s
:::

:::alert{header="Key Point" type="info"}
All three agents use the **same container image**, the **same LiteLLM AI Gateway endpoint**, and mount the **same PVC**. The only differences are:
- **UID** (set via `securityContext.runAsUser` in the deployment)
- **DATA_DIR** (environment variable pointing to the agent's subdirectory)

FSxN's POSIX permissions enforce who can read what — the Kubernetes deployment doesn't enforce any data boundary. This is storage-level security.
:::

---

### Summary

You have deployed three AI agents with identical capabilities but different UIDs into a single namespace. They all mount the same shared FSxN volume. In the next section, you will query each agent and prove that POSIX permissions on FSxN enforce data boundaries — the Finance agent reads finance data, IT Ops reads its data, and the Malicious agent is denied access to both.
