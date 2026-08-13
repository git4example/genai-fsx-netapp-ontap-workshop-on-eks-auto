---
title : "Deploy Strands AI Agents"
weight : 430
---

## Overview

In this section, you will deploy **three AI agents** built with the [AWS Strands Agents SDK](https://github.com/strands-agents/sdk-python). Each agent:

---
##### Step 1: Deploy All Three Agents

All agents deploy into the **same Kubernetes namespace** (`agents`), and mount the **same PVC** (`agent-shared-data`). The only difference is the UID and the `DATA_DIR` subdirectory:

| Agent | UID | DATA_DIR | Purpose |
|-------|-----|----------|---------|
| Finance Agent | 1001 | `/data/finance` | Access financial reports |
| IT Ops Agent | 1002 | `/data/itops` | Access runbooks and logs |
| Malicious Agent | 1099 | `/data` | Attempt to access everything |

Each agent has its **own manifest file** (`finance-agent-deployment.yaml`, `itops-agent-deployment.yaml`, `malicious-agent-deployment.yaml`) so you can deploy, inspect, or delete them individually. Deploy all three:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/agentic-agents
export AGENT_IMAGE="public.ecr.aws/parikshit/fsxn-strands-agent:latest"
for manifest in finance-agent-deployment.yaml itops-agent-deployment.yaml malicious-agent-deployment.yaml; do
  envsubst '$AGENT_IMAGE' < "$manifest" | kubectl apply -f -
done
:::

:::alert{header="Tip" type="info"}
Because each agent is a separate manifest, you can redeploy a single agent (e.g., after changing its role or UID) without touching the others. For example: `envsubst '$AGENT_IMAGE' < finance-agent-deployment.yaml | kubectl apply -f -`
:::


::::expand{header="Click to here to review the Strands AI Agent code (agent.py)"}

::code[cat /home/participant/environment/eks/agentic-agents/agent-app/agent.py]{language=bash showLineNumbers=false showCopyAction=true}

:::code[]{language=python showLineNumbers=true showCopyAction=false}
# agent.py: Strands AI Agent with FSxN file-access tools
import os
import glob
from strands import Agent, tool
from strands.models.openai import OpenAIModel

# Connect to the LiteLLM AI Gateway, which routes tool-calls to Bedrock
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
##### Step 2: Verify All Agents Are Running

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

FSxN's POSIX permissions enforce who can read what, whereas the Kubernetes deployment doesn't enforce any data boundary. This is storage-level security.
:::

##### Step 3: Confirm the Data Layer Permissions

Now that a pod is mounting the shared volume, you can check the data ownership & permissions that were set on the data stored within the FSx for NetApp volume (PVC) during workshop provisioning:

::code[kubectl exec -n agents deploy/finance-agent -- ls -la /data/]{language=bash showLineNumbers=false showCopyAction=true}

You should see `finance` (owned by 1001) and `itops` (owned by 1002), both with mode `drwxr-x---` (750):

:::code{showCopyAction=false showLineNumbers=false language=bash}
drwxr-x---    5 1001     1001          4096 Aug  5 09:40 finance
drwxr-x---    5 1002     1002          4096 Aug  5 09:40 itops
:::

:::alert{header="What this output highlights" type="info"}
Mode `750` means **owner** can read, write, and enter the directory; **group** can read and enter; **everyone else gets nothing**. Since each directory is owned by a different UID and the agents run as different UIDs, neither agent falls into the other's owner or group category.

This is the boundary you will test in the next section. Note that the `finance-agent` pod can *list* both directories here, because `/data` itself is world-readable, but listing a directory name is not the same as reading the files inside it.
:::

---

### Summary

You have deployed three AI agents with identical capabilities but different UIDs into a single namespace. They all mount the same shared FSxN volume. In the next section, you will query each agent and prove that POSIX permissions on FSxN enforce data boundaries: the Finance agent reads finance data, IT Ops reads its data, and the Malicious agent is denied access to both.
