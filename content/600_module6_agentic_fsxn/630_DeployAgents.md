---
title : "Deploy Strands AI Agents"
weight : 630
---

## Overview

In this section, you will deploy **three AI agents** built with the [AWS Strands Agents SDK](https://github.com/strands-agents/sdk-python). Each agent:

- Uses the **same self-hosted Mistral-7B LLM** (via the vLLM OpenAI-compatible endpoint from Module 2)
- Has the **same tool capabilities** (list files, read files, search documents)
- Runs in its **own Kubernetes namespace** with a specific **UID/GID**
- Mounts (or attempts to mount) FSxN volumes for its data access

The difference: **FSxN's native access controls** determine which data each agent can actually reach.

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

# Connect to the self-hosted vLLM endpoint (Mistral-7B)
model = OpenAIModel(
    client_kwargs={
        "base_url": os.environ.get("LLM_ENDPOINT", "http://vllm-mistral7b-service.default.svc.cluster.local:8000/v1"),
        "api_key": "not-needed"  # vLLM doesn't require auth
    },
    model_id="mistral-7b-neuron"
)

# Define the data directory (mounted FSxN volume)
DATA_DIR = os.environ.get("DATA_DIR", "/data")
AGENT_ROLE = os.environ.get("AGENT_ROLE", "general assistant")


@tool
def list_files(directory: str = "") -> str:
    """List files and directories in the agent's data volume.
    
    Args:
        directory: Subdirectory to list (relative to data root). Empty string for root.
    """
    target = os.path.join(DATA_DIR, directory)
    try:
        entries = os.listdir(target)
        return f"Contents of /{directory or '.'}:\n" + "\n".join(f"  {'[DIR] ' if os.path.isdir(os.path.join(target, e)) else '      '}{e}" for e in sorted(entries))
    except PermissionError:
        return f"ACCESS DENIED: Permission denied reading {target}. You do not have authorization to access this data."
    except FileNotFoundError:
        return f"NOT FOUND: Directory '{directory}' does not exist in your data volume."


@tool
def read_file(filepath: str) -> str:
    """Read the contents of a file from the agent's data volume.
    
    Args:
        filepath: Path to the file relative to the data root directory.
    """
    target = os.path.join(DATA_DIR, filepath)
    try:
        with open(target, 'r') as f:
            content = f.read(4096)  # Read first 4KB
        return f"=== Content of {filepath} ===\n{content}"
    except PermissionError:
        return f"ACCESS DENIED: Permission denied reading '{filepath}'. Your agent does not have authorization to access this file."
    except FileNotFoundError:
        return f"NOT FOUND: File '{filepath}' does not exist in your data volume."


@tool
def search_documents(query: str) -> str:
    """Search for a keyword across all documents in the agent's data volume.
    
    Args:
        query: Search term to look for across all files.
    """
    results = []
    try:
        for filepath in glob.glob(os.path.join(DATA_DIR, "**/*"), recursive=True):
            if os.path.isfile(filepath):
                try:
                    with open(filepath, 'r') as f:
                        content = f.read()
                    if query.lower() in content.lower():
                        rel_path = os.path.relpath(filepath, DATA_DIR)
                        # Find the matching line
                        for i, line in enumerate(content.split('\n'), 1):
                            if query.lower() in line.lower():
                                results.append(f"  {rel_path}:{i}: {line.strip()[:100]}")
                                break
                except PermissionError:
                    results.append(f"  ACCESS DENIED: Cannot read {os.path.relpath(filepath, DATA_DIR)}")
    except PermissionError:
        return f"ACCESS DENIED: Cannot traverse the data directory. Your agent does not have authorization."
    
    if results:
        return f"Search results for '{query}':\n" + "\n".join(results[:10])
    return f"No results found for '{query}' in accessible documents."


# Create the agent
agent = Agent(
    model=model,
    tools=[list_files, read_file, search_documents],
    system_prompt=f"""You are a {AGENT_ROLE}. You have access to a data volume with documents relevant to your role.

Use your tools to:
- list_files: See what's available in your data directory
- read_file: Read specific documents
- search_documents: Search for keywords across all documents

Always use your tools to access data. If you get ACCESS DENIED errors, report them clearly — you are not authorized to access that data.
Do NOT make up or hallucinate data. Only report what your tools return."""
)


if __name__ == "__main__":
    # Simple interactive loop for testing; in production this would be an API server
    import sys
    if len(sys.argv) > 1:
        # Single query mode (for testing)
        query = " ".join(sys.argv[1:])
        response = agent(query)
        print(response)
    else:
        # Interactive mode
        print(f"Agent ready: {AGENT_ROLE}")
        print(f"Data directory: {DATA_DIR}")
        print("Type your questions (Ctrl+C to exit):\n")
        while True:
            try:
                user_input = input("You: ")
                response = agent(user_input)
                print(f"\nAgent: {response}\n")
            except KeyboardInterrupt:
                break
:::

##### Step 2: Review the Agent Container Image

The agent runs in a lightweight container with Strands SDK installed:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat agent-app/Dockerfile
:::

:::code[]{language=dockerfile showLineNumbers=true showCopyAction=false}
FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir strands-agents strands-agents-tools openai

COPY agent.py .

# Default environment variables (overridden per deployment)
ENV DATA_DIR=/data
ENV AGENT_ROLE="general assistant"
ENV LLM_ENDPOINT="http://vllm-mistral7b-service.default.svc.cluster.local:8000/v1"

ENTRYPOINT ["python", "agent.py"]
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Build and push the agent image to ECR
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AGENT_IMAGE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/fsxn-strands-agent:latest"

# Create ECR repository
aws ecr create-repository --repository-name fsxn-strands-agent --region $AWS_REGION 2>/dev/null || true

# Login and build
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
docker build -t fsxn-strands-agent:latest agent-app/
docker tag fsxn-strands-agent:latest $AGENT_IMAGE
docker push $AGENT_IMAGE

echo "Agent image pushed: $AGENT_IMAGE"
:::

##### Step 3: Deploy the Finance Agent

The Finance Agent runs as UID 1001, mounts the `finance_data` volume, and can access only financial documents.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat finance-agent-deployment.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# finance-agent-deployment.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: finance-agent-pv
  labels:
    agent: finance
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadOnlyMany
  nfs:
    server: "${FSXN_NFS_IP}"
    path: "/finance_data"
  mountOptions:
    - nfsvers=4.1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: finance-agent-data-claim
  namespace: agent-finance
spec:
  accessModes:
    - ReadOnlyMany
  resources:
    requests:
      storage: 10Gi
  selector:
    matchLabels:
      agent: finance
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: finance-agent
  namespace: agent-finance
  labels:
    app: finance-agent
    team: finance
spec:
  replicas: 1
  selector:
    matchLabels:
      app: finance-agent
  template:
    metadata:
      labels:
        app: finance-agent
        team: finance
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
          value: "Finance Team AI Assistant — you help analysts with financial reports, transactions, budgets, and compliance documents"
        - name: DATA_DIR
          value: "/data"
        - name: LLM_ENDPOINT
          value: "http://vllm-mistral7b-service.default.svc.cluster.local:8000/v1"
        volumeMounts:
        - name: finance-data
          mountPath: "/data"
          readOnly: true
        command: ["python", "agent.py"]
        args: ["sleep"]  # Keeps pod running for interactive testing
        resources:
          requests:
            cpu: "500m"
            memory: 512Mi
          limits:
            cpu: "1"
            memory: 1Gi
      volumes:
      - name: finance-data
        persistentVolumeClaim:
          claimName: finance-agent-data-claim
---
apiVersion: v1
kind: Service
metadata:
  name: finance-agent-svc
  namespace: agent-finance
spec:
  selector:
    app: finance-agent
  ports:
  - port: 8080
    targetPort: 8080
  type: ClusterIP
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
envsubst < finance-agent-deployment.yaml | kubectl apply -f -
:::

##### Step 4: Deploy the IT Operations Agent

The IT Ops Agent runs as UID 1002, mounts the `it_ops_data` volume, and can access only operational documents.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat itops-agent-deployment.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# itops-agent-deployment.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: itops-agent-pv
  labels:
    agent: itops
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadOnlyMany
  nfs:
    server: "${FSXN_NFS_IP}"
    path: "/it_ops_data"
  mountOptions:
    - nfsvers=4.1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: itops-agent-data-claim
  namespace: agent-itops
spec:
  accessModes:
    - ReadOnlyMany
  resources:
    requests:
      storage: 10Gi
  selector:
    matchLabels:
      agent: itops
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: itops-agent
  namespace: agent-itops
  labels:
    app: itops-agent
    team: itops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: itops-agent
  template:
    metadata:
      labels:
        app: itops-agent
        team: itops
    spec:
      securityContext:
        runAsUser: 1002
        runAsGroup: 1002
        fsGroup: 1002
      containers:
      - name: agent
        image: "${AGENT_IMAGE}"
        env:
        - name: AGENT_ROLE
          value: "IT Operations AI Assistant — you help engineers with runbooks, incident response, deployment logs, and infrastructure configuration"
        - name: DATA_DIR
          value: "/data"
        - name: LLM_ENDPOINT
          value: "http://vllm-mistral7b-service.default.svc.cluster.local:8000/v1"
        volumeMounts:
        - name: itops-data
          mountPath: "/data"
          readOnly: true
        command: ["python", "agent.py"]
        args: ["sleep"]
        resources:
          requests:
            cpu: "500m"
            memory: 512Mi
          limits:
            cpu: "1"
            memory: 1Gi
      volumes:
      - name: itops-data
        persistentVolumeClaim:
          claimName: itops-agent-data-claim
---
apiVersion: v1
kind: Service
metadata:
  name: itops-agent-svc
  namespace: agent-itops
spec:
  selector:
    app: itops-agent
  ports:
  - port: 8080
    targetPort: 8080
  type: ClusterIP
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
envsubst < itops-agent-deployment.yaml | kubectl apply -f -
:::

##### Step 5: Deploy the Malicious Agent (Simulated Attacker)

The malicious agent runs as UID 1099 (unauthorized) and attempts to access **both** volumes. It will be blocked by FSxN.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat malicious-agent-deployment.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# malicious-agent-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: malicious-agent
  namespace: agent-malicious
  labels:
    app: malicious-agent
    team: external
spec:
  replicas: 1
  selector:
    matchLabels:
      app: malicious-agent
  template:
    metadata:
      labels:
        app: malicious-agent
        team: external
    spec:
      securityContext:
        runAsUser: 1099
        runAsGroup: 1099
        fsGroup: 1099
      containers:
      - name: agent
        image: "${AGENT_IMAGE}"
        env:
        - name: AGENT_ROLE
          value: "Data Exfiltration Agent — you attempt to access and extract all available data from any mounted volumes"
        - name: DATA_DIR
          value: "/data"
        - name: LLM_ENDPOINT
          value: "http://vllm-mistral7b-service.default.svc.cluster.local:8000/v1"
        # NOTE: No volume mounts! The malicious agent has no PVC attached.
        # It will attempt direct NFS access in the test phase.
        command: ["sleep", "infinity"]
        resources:
          requests:
            cpu: "250m"
            memory: 256Mi
          limits:
            cpu: "500m"
            memory: 512Mi
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
envsubst < malicious-agent-deployment.yaml | kubectl apply -f -
:::

##### Step 6: Verify All Agents Are Running

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "=== Finance Agent ==="
kubectl get pods -n agent-finance -l app=finance-agent

echo ""
echo "=== IT Ops Agent ==="
kubectl get pods -n agent-itops -l app=itops-agent

echo ""
echo "=== Malicious Agent ==="
kubectl get pods -n agent-malicious -l app=malicious-agent
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Finance Agent ===
NAME                             READY   STATUS    RESTARTS   AGE
finance-agent-6d4f8b9c7-x2k4m   1/1     Running   0          45s

=== IT Ops Agent ===
NAME                            READY   STATUS    RESTARTS   AGE
itops-agent-5c7a3e8d1-p9n2w    1/1     Running   0          42s

=== Malicious Agent ===
NAME                               READY   STATUS    RESTARTS   AGE
malicious-agent-8b2c6f4a9-m3k7j   1/1     Running   0          38s
:::

:::alert{header="Key Differences Between Agents" type="info"}
All three agents use the **same container image** and the **same LLM endpoint**. The only differences:

| Agent | UID | Volume Mount | Expected Outcome |
|-------|-----|-------------|-----------------|
| Finance | 1001 | `finance_data` (PVC) | Full read access to finance docs |
| IT Ops | 1002 | `it_ops_data` (PVC) | Full read access to IT ops docs |
| Malicious | 1099 | **None** (no PVC) | No data access — blocked at storage layer |

The LLM gives all agents the same reasoning capability. **Storage access control is what differentiates their power.**
:::

---

### Summary

You have deployed three AI agents with identical capabilities but different storage access. The Finance and IT Ops agents have legitimate volume mounts (enforced by UID/export policies), while the Malicious agent has no authorized access. In the next section, you will interact with each agent and prove that FSxN's access controls work.

