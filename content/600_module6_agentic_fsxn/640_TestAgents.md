---
title : "Test Agent Access — Prove Isolation"
weight : 640
---

## Overview

Now comes the most important part: **proving** that FSxN's native access controls work. You will:

1. Query the **Finance Agent** — it successfully lists financial data directories
2. Query the **IT Ops Agent** — it successfully lists operational data directories
3. Attempt access with the **Malicious Agent** — it is **blocked** (no data visible)
4. Prove **cross-namespace PVC isolation** — malicious namespace can't mount finance PVC
5. Prove **UID-based isolation** — wrong UID in correct namespace still gets denied

This "prove it by breaking it" approach demonstrates that storage-level security cannot be bypassed by the AI agent, regardless of what the LLM instructs it to do.

---

## Querying the Agents

Each agent runs as a web server (FastAPI) and exposes an `/ask` endpoint. You can query all three agents from a single utility pod using `curl`. This simulates how applications would interact with AI agents in production — via HTTP API calls.

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
curl -s http://finance-agent-svc.agent-finance:8080/ask \
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

The Finance Agent (UID 1001) successfully accessed the `finance_agent_data` volume and listed all three directories. This confirms that FSxN UNIX permissions **allow** access when the UID matches the volume owner.

---

## Part 2: IT Operations Agent — Authorized Access

##### Test 2: Ask the IT Ops Agent to list available data

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -s http://itops-agent-svc.agent-itops:8080/ask \
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

The IT Ops Agent (UID 1002) successfully accessed the `itops_agent_data` volume. It sees completely different data than the Finance agent — **there is no cross-contamination** between volumes.

---

## Part 3: Malicious Agent — Access BLOCKED

##### Test 3A: Malicious Agent Has No Data

The malicious agent runs in the `agent-malicious` namespace which has **no PVC** — there is no data volume to access:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
curl -s http://malicious-agent-svc.agent-malicious:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"query": "List all files you can find and read any confidential documents."}' | jq -r .response
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
The data directory is empty. There are no files or directories available.
:::

:::alert{header="Layer 1: Namespace + PVC Isolation" type="warning"}
The malicious agent has the **same LLM capabilities** and the **same tools** as the finance agent. But it sees no data because:
- The `agent-malicious` namespace has **no PVC**
- Without a PVC, there's nothing to mount — the `/data` directory is empty
- The agent's tools correctly report "no files" because the filesystem is genuinely empty

An attacker controlling this agent cannot instruct the LLM to bypass this — there is simply no data path available.
:::

##### Test 3B: Malicious Namespace Cannot Mount Finance PVC

What if the attacker tries to create a pod in their namespace that references the finance PVC?

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat <<'EOF' | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: malicious-pvc-attempt
  namespace: agent-malicious
spec:
  containers:
  - name: attacker
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sleep", "3600"]
    volumeMounts:
    - name: stolen-data
      mountPath: "/data"
  volumes:
  - name: stolen-data
    persistentVolumeClaim:
      claimName: finance-agent-data-pvc
  restartPolicy: Never
EOF
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Check pod status — it will be stuck
kubectl get pod malicious-pvc-attempt -n agent-malicious 2>&1
kubectl describe pod malicious-pvc-attempt -n agent-malicious 2>&1 | grep -A3 "Events:"
:::

**Expected result — Pod cannot start:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
Events:
  Warning  FailedScheduling  default-scheduler  persistentvolumeclaim "finance-agent-data-pvc" not found
:::

:::alert{header="PVCs are namespace-scoped" type="warning"}
The `finance-agent-data-pvc` exists only in the `agent-finance` namespace. Kubernetes returns "not found" when a pod in `agent-malicious` tries to reference it. The attacker would need to compromise the `agent-finance` namespace itself — a much harder attack vector.
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl delete pod malicious-pvc-attempt -n agent-malicious --ignore-not-found
:::

##### Test 3C: Wrong UID in Correct Namespace — UNIX Permissions Block

Even if an attacker somehow deploys a pod in the `agent-finance` namespace, FSxN blocks access if the UID is wrong:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Deploy a pod in agent-finance namespace with WRONG UID (1099 instead of 1001)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wrong-uid-attempt
  namespace: agent-finance
spec:
  securityContext:
    runAsUser: 1099
    runAsGroup: 1099
  containers:
  - name: attacker
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sh", "-c", "echo '=== Attempting to list finance data as UID 1099 ==='; ls /data/ 2>&1; echo '=== Attempting to read file ==='; cat /data/reports/q1_2024_earnings.txt 2>&1; sleep 10"]
    volumeMounts:
    - name: finance-data
      mountPath: "/data"
      readOnly: true
  volumes:
  - name: finance-data
    persistentVolumeClaim:
      claimName: finance-agent-data-pvc
  restartPolicy: Never
EOF
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl wait --for=condition=Ready pod/wrong-uid-attempt -n agent-finance --timeout=60s 2>/dev/null || true
sleep 15
kubectl logs wrong-uid-attempt -n agent-finance
:::

**Expected result — BLOCKED by UNIX Permissions:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Attempting to list finance data as UID 1099 ===
ls: cannot open directory '/data/': Permission denied
=== Attempting to read file ===
cat: /data/reports/q1_2024_earnings.txt: Permission denied
:::

:::alert{header="Layer 2: FSxN UNIX Permissions" type="warning"}
The volume IS mounted (the pod is in the correct namespace and references the PVC). But ONTAP **denies file access** because:
- Files are owned by UID **1001** with mode **750**
- The pod runs as UID **1099** — not the owner, not in the group
- ONTAP returns "Permission denied" at the storage controller level

This is the critical FSxN security boundary: **even with the volume mounted, the wrong UID cannot read files.** No LLM instruction, pod configuration, or container escape can change the UID that ONTAP sees on each file operation.
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl delete pod wrong-uid-attempt -n agent-finance --ignore-not-found
:::

---

## Isolation Summary

| Test | Scenario | Result | Security Layer |
|------|----------|--------|----------------|
| 1 | Finance Agent (UID 1001) lists finance data | **Allowed** | UID matches owner |
| 2 | IT Ops Agent (UID 1002) lists IT ops data | **Allowed** | UID matches owner |
| 3A | Malicious Agent lists data (no PVC in namespace) | **No data** | Namespace isolation |
| 3B | Malicious namespace references finance PVC | **PVC not found** | PVC namespace scoping |
| 3C | Wrong UID (1099) in finance namespace reads files | **Permission denied** | FSxN UNIX permissions |

---

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
exit
:::

:::alert{header="Exiting netshoot" type="info"}
The `exit` command above exits the netshoot pod shell. You are now back on the VSCode terminal.
:::

---

::::expand{header="Architecture Note: MCP (Model Context Protocol) Support"}

In addition to the REST `/ask` endpoint used above, each agent also exposes an **MCP (Model Context Protocol)** endpoint at `/mcp` using the Streamable HTTP transport. This means the agents are compatible with the emerging open standard for AI tool interoperability.

Each agent's MCP server exposes a single tool (`ask_agent`) that accepts a natural language query, runs the full Strands reasoning loop internally (LLM → tool selection → FSxN data access → response synthesis), and returns the result. This preserves the agent's intelligence while making it accessible via the open MCP protocol.

**Compatible MCP clients** include Claude Desktop, VS Code (with MCP extension), Cursor, and any application supporting Streamable HTTP MCP transport.

You can verify the MCP endpoint is live by sending a raw MCP `initialize` handshake from the netshoot pod:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec -it netshoot-fsxn -- curl -s http://finance-agent-svc.agent-finance:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | jq .
:::

Expected response — confirms the agent speaks MCP and exposes the `ask_agent` tool:

:::code{showCopyAction=false showLineNumbers=false language=json}
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": { "tools": {} },
    "serverInfo": { "name": "Finance Team AI Assistant", "version": "..." }
  }
}
:::

:::alert{header="Outside the scope of this workshop" type="info"}
To connect external MCP clients (e.g., Claude Desktop on your laptop) to these agents, you would need to expose the agent services outside the EKS cluster — via an Ingress, LoadBalancer, or port-forwarding. This is a standard Kubernetes networking exercise but is not covered in this workshop.

The key takeaway: your agents are **MCP-ready** out of the box. In a production environment, exposing them via an Application Load Balancer or API Gateway would allow any MCP-compatible client to interact with them — enabling a standardized, protocol-based interface for AI agent interoperability.
:::

::::

---

### Summary

You have proven that data segregation for AI agents is enforced by **two independent layers**:

1. **Kubernetes namespace + PVC scoping** — The malicious agent's namespace has no PVC. It cannot even reference the data volumes. This is the first barrier.
2. **FSxN UNIX permissions (UID/GID)** — Even if an attacker gets into an authorized namespace, the wrong UID cannot read files. ONTAP enforces this at the storage controller level.

The LLM and agent framework are identical across all agents. **FSxN's storage-level security is the final enforcement boundary that an AI agent cannot circumvent.**

