
---

## User
*6/9/2026, 1:22:44 PM*

Here is the scenario: I want to demo the AgentCore AI agent to start another vLLM pod (that is loading the Mistral LLM) on my existing self-hosted stack, when it hits a threshold i set in my task definition in the input prompt (i.e. alert me via email when my total tokens get hits 10000, and once it hits 15000 token used spin-up another vLLM pod (also linked the same LLM model i am hosting on a shared persistent volume)... this is to show an Ai Agent can scale out on our behalf based on a task we define.

---

## Assistant
*6/9/2026, 1:22:44 PM*

Yes, absolutely — this is a perfect **agentic auto-scaling** demo. An AgentCore agent can both monitor metrics AND take infrastructure actions (like spinning up a new vLLM pod). Here's how it would work:

---

## The Concept

```
AgentCore Agent (monitoring loop)
        ↓
    Grafana/Prometheus API → checks token counter
        ↓
    10,000 tokens → Tool: send_email(alert)
        ↓
    15,000 tokens → Tool: scale_vllm(replicas+1)
                          ↓
                    Kubernetes API / EKS
                          ↓
                    New vLLM pod spins up
                    (same model, same PVC)
```

---

## Architecture

| Component | Role |
|-----------|------|
| **AgentCore Agent** | Orchestrates the monitoring + actions |
| **Tool 1: `query_grafana`** | Reads token counter from your dashboard |
| **Tool 2: `send_email`** | Sends alert via SES/SMTP |
| **Tool 3: `scale_vllm`** | Calls Kubernetes API to add a pod |
| **Kubernetes (EKS or self-managed)** | Hosts your vLLM deployment |
| **PersistentVolume (PVC)** | Shared model weights (e.g., EFS/FSx) — new pods mount the same volume |

---

## The Tools You'd Create

### Tool 1: Query Token Metrics
```python
def query_grafana(metric: str) -> int:
    """Query Prometheus/Grafana for current token count."""
    resp = requests.get(
        "http://prometheus:9090/api/v1/query",
        params={"query": "sum(vllm_prompt_tokens_total) + sum(vllm_generation_tokens_total)"}
    )
    return int(resp.json()["data"]["result"][0]["value"][1])
```

### Tool 2: Send Email Alert
```python
def send_email(subject: str, body: str, recipient: str):
    """Send notification via Amazon SES."""
    ses_client.send_email(...)
```

### Tool 3: Scale vLLM Deployment (the key one 🔑)
```python
def scale_vllm(namespace: str, deployment: str, replicas: int):
    """Scale the vLLM Kubernetes deployment to N replicas."""
    from kubernetes import client, config
    config.load_incluster_config()  # or kubeconfig
    apps_v1 = client.AppsV1Api()

    # Patch the deployment replica count
    apps_v1.patch_namespaced_deployment_scale(
        name=deployment,
        namespace=namespace,
        body={"spec": {"replicas": replicas}}
    )
    return f"Scaled {deployment} to {replicas} replicas"
```

This works because your vLLM pods are defined as a **Kubernetes Deployment** where:
- All pods mount the same **PersistentVolumeClaim** (ReadOnlyMany, e.g., EFS) with the Mistral model weights
- A **Service** (or load balancer) distributes traffic across all vLLM pods

---

## The Agent's Behavior (Natural Language Task Definition)

When you type in Open WebUI:

> *"Monitor my total token usage. Email me at akbariw@amazon.com when it hits 10,000. When it reaches 15,000, scale my vLLM deployment to 2 pods. Check every 60 seconds."*

The AgentCore agent interprets this as:

```
LOOP every 60s:
    tokens = query_grafana("total_tokens")

    IF tokens >= 10,000 AND not already_alerted:
        send_email("Token Alert", "You've hit 10K tokens", "akbariw@amazon.com")
        already_alerted = True

    IF tokens >= 15,000 AND current_replicas < 2:
        scale_vllm(namespace="llm", deployment="vllm-mistral", replicas=2)
        send_email("Scale-out", "Scaled to 2 vLLM pods", "akbariw@amazon.com")
```

---

## Kubernetes Setup (Pre-requisite)

Your vLLM deployment would look like this:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-mistral
  namespace: llm
spec:
  replicas: 1  # Agent will change this
  selector:
    matchLabels:
      app: vllm-mistral
  template:
    spec:
      containers:
      - name: vllm
        image: vllm/vllm-openai:latest
        args:
          - --model=/models/mistral-7b-instruct
          - --port=8000
        volumeMounts:
        - name: model-weights
          mountPath: /models
          readOnly: true
      volumes:
      - name: model-weights
        persistentVolumeClaim:
          claimName: mistral-model-pvc  # Shared EFS/FSx volume
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-mistral-svc
spec:
  selector:
    app: vllm-mistral
  ports:
  - port: 8000
  type: ClusterIP  # Load balances across all pods
```

When the agent scales from 1 → 2 replicas:
- New pod starts, mounts the same PVC (`mistral-model-pvc`)
- Loads the model into GPU memory
- The Service automatically routes traffic to both pods

---

## Why This is a Great Demo

It shows an AI agent that:

| Capability | What it demonstrates |
|------------|---------------------|
| **Natural language task definition** | User defines thresholds in plain English |
| **Monitoring** | Agent autonomously polls metrics |
| **Alerting** | Agent sends notifications when conditions are met |
| **Infrastructure action** | Agent scales compute resources without human intervention |
| **Self-healing/scaling** | The LLM serving layer auto-scales based on demand |

This is exactly the **"agentic infrastructure"** pattern — an AI agent managing AI infrastructure.

---

## Security Note

For the `scale_vllm` tool, the AgentCore agent needs a **Kubernetes ServiceAccount** with RBAC permissions to patch deployments. You'd scope this tightly:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: llm
rules:
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  verbs: ["patch", "get"]
  resourceNames: ["vllm-mistral"]  # Only this deployment
```

---

---
