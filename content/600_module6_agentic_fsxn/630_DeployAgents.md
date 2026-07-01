---
title : "Deploy Strands AI Agents"
weight : 630
---

## Overview

In this section, you will deploy **three AI agents** built with the [AWS Strands Agents SDK](https://github.com/strands-agents/sdk-python). Each agent:

- Uses the **LiteLLM AI Gateway** (`workshop-llm` model) — which routes tool-calling requests to Amazon Bedrock Claude Haiku 4.5 for reliable structured tool use
- Has the **same tool capabilities** (list files, read files, search documents)
- Runs with a specific **UID/GID** that determines which volume's files it can access
- Mounts FSxN volumes via **Trident-managed PVCs**

The difference: **ONTAP's UNIX permissions** determine which data each agent can actually read — based purely on UID.

:::alert{header="AI Gateway Intelligent Routing" type="info"}
In Module 2, you deployed the LiteLLM AI Gateway that routes requests based on capabilities. When these agents send requests with **tools** (function schemas), the gateway automatically routes them to **Bedrock Claude Haiku 4.5** — a model with strong tool-calling capability. The agents don't need to know which model serves them; the gateway handles this transparently.

In production with larger self-hosted models (70B+), you could route everything locally. The gateway pattern remains valuable for cost optimization, failover, and routing complex agentic workloads to the most capable available model.
:::

---

##### Step 1: Review the Agent Application Code

Each agent is a Python application using Strands Agents SDK. Let's review the code:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/agentic-agents
cat agent-app/agent.py
:::

:::code[]{language=python showLineNumbers=true showCopyAction=false}
# agent.py — Strands AI Agent with FSxN file-access tools
import os
import glob
from strands import Agent, tool
from strands.models.openai import OpenAIModel

# Connect to the LiteLLM AI Gateway — routes tool-calls to Bedrock automatically
model = OpenAIModel(
    client_args={
        "base_url": os.environ.get("LLM_ENDPOINT", "http://litellm-service.default.svc.cluster.local:4000/v1"),
        "api_key": os.environ.get("LLM_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("LLM_MODEL_ID", "workshop-llm"),
)

DATA_DIR = os.environ.get("DATA_DIR", "/data")
AGENT_ROLE = os.environ.get("AGENT_ROLE", "general assistant")


@tool
def list_files(directory: str = "") -> str:
    """List files and directories in the agent's data volume."""
    target = os.path.join(DATA_DIR, directory)
    try:
        entries = os.listdir(target)
        return f"Contents of /{directory or '.'}:\n" + "\n".join(
            f"  {'[DIR] ' if os.path.isdir(os.path.join(target, e)) else '      '}{e}"
            for e in sorted(entries))
    except PermissionError:
        return f"ACCESS DENIED: Permission denied reading {target}."
    except FileNotFoundError:
        return f"NOT FOUND: Directory '{directory}' does not exist."


@tool
def read_file(filepath: str) -> str:
    """Read the contents of a file from the agent's data volume."""
    target = os.path.join(DATA_DIR, filepath)
    try:
        with open(target, 'r') as f:
            content = f.read(4096)
        return f"=== Content of {filepath} ===\n{content}"
    except PermissionError:
        return f"ACCESS DENIED: Permission denied reading '{filepath}'."
    except FileNotFoundError:
        return f"NOT FOUND: File '{filepath}' does not exist."


@tool
def search_documents(query: str) -> str:
    """Search for a keyword across all documents in the agent's data volume."""
    results = []
    try:
        for filepath in glob.glob(os.path.join(DATA_DIR, "**/*"), recursive=True):
            if os.path.isfile(filepath):
                try:
                    with open(filepath, 'r') as f:
                        content = f.read()
                    if query.lower() in content.lower():
                        rel_path = os.path.relpath(filepath, DATA_DIR)
                        for i, line in enumerate(content.split('\n'), 1):
                            if query.lower() in line.lower():
                                results.append(f"  {rel_path}:{i}: {line.strip()[:100]}")
                                break
                except PermissionError:
                    results.append(f"  ACCESS DENIED: Cannot read {os.path.relpath(filepath, DATA_DIR)}")
    except PermissionError:
        return "ACCESS DENIED: Cannot traverse the data directory."
    if results:
        return f"Search results for '{query}':\n" + "\n".join(results[:10])
    return f"No results found for '{query}' in accessible documents."
:::

##### Step 2: Review the Agent Container Image

The agent is packaged as a container. Review the Dockerfile to understand what's included:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat agent-app/Dockerfile
:::

:::code[]{language=dockerfile showLineNumbers=true showCopyAction=false}
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir strands-agents strands-agents-tools openai
COPY agent.py .
ENV DATA_DIR=/data
ENV AGENT_ROLE="general assistant"
ENV LLM_ENDPOINT="http://litellm-service.default.svc.cluster.local:4000/v1"
ENV LLM_MODEL_ID="workshop-llm"
ENV LLM_API_KEY="not-needed"
ENTRYPOINT ["python", "agent.py"]
:::

For this workshop, we provide a **pre-built container image** so you don't need to build or push anything:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
export AGENT_IMAGE="public.ecr.aws/parikshit/fsxn-strands-agent:latest"
echo "Using pre-built agent image: $AGENT_IMAGE"
:::

##### Step 3: Deploy the Finance Agent (UID 1001)

The Finance Agent runs as **UID 1001**, matching the ownership on the `finance_agent_data` volume. It mounts the finance PVC and can read all finance documents.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat finance-agent-deployment.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: finance-agent
  namespace: agent-finance
spec:
  replicas: 1
  selector:
    matchLabels:
      app: finance-agent
  template:
    spec:
      securityContext:
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
      containers:
      - name: agent
        image: "${AGENT_IMAGE}"
        env:
        - name: AGENT_ROLE
          value: "Finance Team AI Assistant"
        - name: DATA_DIR
          value: "/data"
        - name: LLM_ENDPOINT
          value: "http://litellm-service.default.svc.cluster.local:4000/v1"
        - name: LLM_MODEL_ID
          value: "workshop-llm"
        - name: LLM_API_KEY
          value: "not-needed"
        volumeMounts:
        - name: finance-data
          mountPath: "/data"
          readOnly: true
        command: ["sleep", "infinity"]
      volumes:
      - name: finance-data
        persistentVolumeClaim:
          claimName: finance-agent-data-pvc
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
envsubst '$AGENT_IMAGE' < finance-agent-deployment.yaml | kubectl apply -f -
:::

##### Step 4: Deploy the IT Operations Agent (UID 1002)

The IT Ops Agent runs as **UID 1002**, matching the ownership on the `itops_agent_data` volume.

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
envsubst '$AGENT_IMAGE' < itops-agent-deployment.yaml | kubectl apply -f -
:::

##### Step 5: Deploy the Malicious Agent (UID 1099)

The malicious agent runs as **UID 1099** (unauthorized). It has no matching volume ownership — ONTAP will deny all file reads.

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
envsubst '$AGENT_IMAGE' < malicious-agent-deployment.yaml | kubectl apply -f -
:::

##### Step 6: Verify All Agents Are Running

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "=== Finance Agent (UID 1001) ==="
kubectl get pods -n agent-finance -l app=finance-agent

echo ""
echo "=== IT Ops Agent (UID 1002) ==="
kubectl get pods -n agent-itops -l app=itops-agent

echo ""
echo "=== Malicious Agent (UID 1099) ==="
kubectl get pods -n agent-malicious -l app=malicious-agent
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Finance Agent (UID 1001) ===
NAME                             READY   STATUS    RESTARTS   AGE
finance-agent-6d4f8b9c7-x2k4m   1/1     Running   0          45s

=== IT Ops Agent (UID 1002) ===
NAME                            READY   STATUS    RESTARTS   AGE
itops-agent-5c7a3e8d1-p9n2w    1/1     Running   0          42s

=== Malicious Agent (UID 1099) ===
NAME                               READY   STATUS    RESTARTS   AGE
malicious-agent-8b2c6f4a9-m3k7j   1/1     Running   0          38s
:::

:::alert{header="Key Differences Between Agents" type="info"}
All three agents use the **same container image** and the **same LiteLLM AI Gateway endpoint**. The only differences:

| Agent | UID | Volume Mounted | Can Read? |
|-------|-----|---------------|-----------|
| Finance | 1001 | finance_agent_data (via PVC) | Yes — UID matches owner |
| IT Ops | 1002 | itops_agent_data (via PVC) | Yes — UID matches owner |
| Malicious | 1099 | No volume (or wrong UID if mounted) | No — UID doesn't match any owner |

The LLM gives all agents the same reasoning capability. **ONTAP UNIX permissions are what differentiates their access.**
:::

---

### Summary

You have deployed three AI agents with identical capabilities but different UIDs. The Finance and IT Ops agents have the correct UID to read their designated volumes, while the Malicious agent's UID (1099) doesn't match any volume's ownership. In the next section, you will interact with each agent and prove that ONTAP's UNIX permissions enforce the data boundaries.

