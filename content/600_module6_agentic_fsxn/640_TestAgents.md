---
title : "Test Agent Access — Prove Isolation"
weight : 640
---

## Overview

Now comes the most important part: **proving** that FSxN's native access controls work. You will:

1. Query the **Finance Agent** — it successfully reads financial documents
2. Query the **IT Ops Agent** — it successfully reads operational runbooks
3. Attempt access with the **Malicious Agent** — it is **blocked** by UNIX permissions (wrong UID)

This "prove it by breaking it" approach demonstrates that storage-level security cannot be bypassed by the AI agent, regardless of what the LLM instructs it to do.

---

## Part 1: Finance Agent — Authorized Access

##### Test 1A: Ask the Finance Agent to list available data

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Interact with the Finance Agent
kubectl exec -n agent-finance deployment/finance-agent -- python agent.py \
  "What files do you have access to? List everything in your data directory."
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
I'll check what's available in my data directory.

Using tool: list_files(directory="")

Contents of /:
  [DIR] reports
  [DIR] transactions
  [DIR] compliance

I have access to three directories:
1. **reports/** — likely contains financial reports
2. **transactions/** — transaction records
3. **compliance/** — compliance and audit documents

Would you like me to explore any of these in detail?
:::

##### Test 1B: Ask the Finance Agent to read a specific document

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec -n agent-finance deployment/finance-agent -- python agent.py \
  "Read the Q1 2024 earnings report and summarize the key findings."
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
I'll locate and read the Q1 2024 earnings report.

Using tool: list_files(directory="reports")
Using tool: read_file(filepath="reports/q1_2024_earnings.txt")

Based on the Q1 2024 earnings report:

**Key Findings:**
- Total revenue: $142.3M (up 12% YoY)
- Operating margin: 23.4%
- Cloud services segment grew 34% to $67.8M
- R&D spending increased to 18% of revenue
- Guidance maintained for full-year targets

The report indicates strong growth in cloud services offsetting moderate decline in legacy products.
:::

##### Test 1C: Ask the Finance Agent to search for a keyword

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec -n agent-finance deployment/finance-agent -- python agent.py \
  "Search for any mentions of 'audit' across all documents."
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
Using tool: search_documents(query="audit")

Search results for 'audit':
  compliance/sox_audit_notes.txt:1: SOX Compliance Audit Notes - Q1 2024
  compliance/sox_audit_notes.txt:5: Internal audit completed March 15, 2024
  compliance/expense_policy.txt:12: All expenses over $5,000 require audit trail

I found mentions of 'audit' in 2 compliance documents. The SOX audit notes indicate an internal audit was completed on March 15, 2024, and the expense policy requires audit trails for expenses over $5,000.
:::

:::alert{header="Finance Agent Success" type="info"}
The Finance Agent successfully accessed all its designated files: reports, transactions, and compliance documents. It runs as **UID 1001** which matches the ownership set on the `finance_agent_data` volume.
:::

---

## Part 2: IT Operations Agent — Authorized Access

##### Test 2A: Ask the IT Ops Agent to list available data

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec -n agent-itops deployment/itops-agent -- python agent.py \
  "What data do you have access to? Show me the directory structure."
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
Using tool: list_files(directory="")

Contents of /:
  [DIR] runbooks
  [DIR] logs
  [DIR] configs

I have access to three directories:
1. **runbooks/** — operational runbooks and procedures
2. **logs/** — application and deployment logs
3. **configs/** — infrastructure configuration files

These are typical IT operations resources for incident response and system management.
:::

##### Test 2B: Ask the IT Ops Agent about incident response

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec -n agent-itops deployment/itops-agent -- python agent.py \
  "Read the incident response runbook. What are the first 3 steps when an incident occurs?"
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
Using tool: read_file(filepath="runbooks/incident_response.md")

Based on the incident response runbook, the first 3 steps are:

1. **Acknowledge & Assess** — Acknowledge the alert within 5 minutes. Assess severity (P1-P4) based on customer impact.
2. **Communicate** — Post in #incident-response Slack channel. Page on-call if P1/P2.
3. **Isolate** — If the issue is spreading, isolate the affected component (kill traffic, scale down, or failover to standby).

The runbook then continues with investigation, mitigation, and post-mortem steps.
:::

##### Test 2C: Ask the IT Ops Agent to search across logs

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec -n agent-itops deployment/itops-agent -- python agent.py \
  "Search for any 'ERROR' entries in the logs. What errors occurred recently?"
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
Using tool: search_documents(query="ERROR")

Search results for 'ERROR':
  logs/app_errors_2024-03.log:3: 2024-03-01 14:22:31 ERROR [api-gateway] Connection timeout to downstream service
  logs/app_errors_2024-03.log:7: 2024-03-02 09:15:44 ERROR [auth-service] Token validation failed: expired certificate
  logs/deployment_history.log:12: 2024-03-05 16:30:00 ERROR Deploy v2.4.1 rolled back: health check failed

I found 3 error entries:
1. **API Gateway** — Connection timeout (March 1)
2. **Auth Service** — Expired certificate (March 2)
3. **Deployment** — v2.4.1 rolled back due to failed health check (March 5)

The expired certificate error might be the root cause of the connection timeout the next day.
:::

:::alert{header="IT Ops Agent Success" type="info"}
The IT Ops Agent successfully accessed runbooks, logs, and configs — all designated for IT operations. It runs as **UID 1002**, matching ownership on the `itops_agent_data` volume. Note it has **no visibility** into the finance data whatsoever.
:::

---

## Part 3: Malicious Agent — Access BLOCKED (Two Layers)

Now for the critical security tests. We demonstrate **two layers** of protection:
1. **Layer 1 (Namespace/PVC scoping)** — The malicious agent's namespace has no PVC to mount
2. **Layer 2 (UNIX permissions)** — Even if an attacker gets into an authorized namespace, wrong UID can't read files

##### Test 3A: Malicious Agent Cannot Mount Finance Data (No PVC in Namespace)

The malicious agent's namespace (`agent-malicious`) has **no PVC**. If it tries to reference the finance PVC, Kubernetes rejects it:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Attempt to create a pod in the malicious namespace referencing the finance PVC
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

**Expected result — Pod stuck (PVC not found in this namespace):**

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl describe pod malicious-pvc-attempt -n agent-malicious 2>&1 | grep -A2 "Events:" || echo "Pod cannot start — PVC does not exist in agent-malicious namespace"
:::

:::code{showCopyAction=false showLineNumbers=false language=bash}
Events:
  Warning  FailedScheduling  default-scheduler  persistentvolumeclaim "finance-agent-data-pvc" not found
:::

:::alert{header="Layer 1: Namespace Isolation" type="warning"}
PVCs are **namespace-scoped** in Kubernetes. The `finance-agent-data-pvc` exists only in `agent-finance`. A pod in `agent-malicious` cannot reference it — Kubernetes rejects the pod before any storage access occurs. The attacker would need to compromise the `agent-finance` namespace itself to reach the PVC.
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Clean up the stuck pod
kubectl delete pod malicious-pvc-attempt -n agent-malicious --ignore-not-found
:::

##### Test 3B: Wrong UID Cannot Read Finance Data (UNIX Permissions)

Even if an attacker somehow deploys a pod in the `agent-finance` namespace (bypassing Layer 1), ONTAP's UNIX permissions still block access if the UID is wrong:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Deploy a pod in agent-finance namespace but with WRONG UID (1099 instead of 1001)
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
    command: ["sh", "-c", "echo '=== Attempting to list finance data as UID 1099 ==='; ls /data/ 2>&1; echo ''; echo '=== Attempting to read earnings report ==='; cat /data/reports/q1_2024_earnings.txt 2>&1; sleep 10"]
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

=== Attempting to read earnings report ===
cat: /data/reports/q1_2024_earnings.txt: Permission denied
:::

:::alert{header="Layer 2: UNIX Permissions (FSxN Enforcement)" type="warning"}
The volume IS mounted (the pod is in the correct namespace and references the PVC). But the **files** are owned by UID 1001 with mode 750. UID 1099 is neither the owner nor in the group, so **ONTAP returns "Permission denied" at the storage controller level**.

This is the key insight: even if an attacker bypasses Kubernetes namespace controls, **FSxN enforces file-level access based on process UID**. The attacker cannot bypass this regardless of what they control in the pod spec — ONTAP checks the UID on every file operation.
:::

##### Test 3C: Finance Agent Cannot Read IT Ops Data (Cross-Volume UID Mismatch)

Even the authorized Finance agent (UID 1001) cannot read IT Ops data (owned by UID 1002). Deploy a pod in `agent-itops` namespace as UID 1001:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: finance-cross-access-attempt
  namespace: agent-itops
spec:
  securityContext:
    runAsUser: 1001
    runAsGroup: 1001
  containers:
  - name: finance-user
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sh", "-c", "echo '=== Finance UID (1001) trying to read IT ops data (owned by 1002) ==='; ls /data/ 2>&1; cat /data/runbooks/incident_response.md 2>&1; sleep 10"]
    volumeMounts:
    - name: itops-data
      mountPath: "/data"
      readOnly: true
  volumes:
  - name: itops-data
    persistentVolumeClaim:
      claimName: itops-agent-data-pvc
  restartPolicy: Never
EOF
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl wait --for=condition=Ready pod/finance-cross-access-attempt -n agent-itops --timeout=60s 2>/dev/null || true
sleep 15
kubectl logs finance-cross-access-attempt -n agent-itops
:::

**Expected result — BLOCKED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Finance UID (1001) trying to read IT ops data (owned by 1002) ===
ls: cannot open directory '/data/': Permission denied
cat: /data/runbooks/incident_response.md: Permission denied
:::

:::alert{header="Cross-Agent Isolation Proven" type="info"}
Even a legitimate UID (1001, Finance) cannot read another team's data (owned by UID 1002). ONTAP enforces isolation per-volume based on file ownership. Each UID is confined to its own volume's data — there is no "root" or "admin" bypass at the NFS file level.
:::

##### Test 3D: Run the Malicious Agent with LLM — Agent Reports Its Own Failure

Let's ask the malicious agent (running as UID 1099 with no valid data mount) to try to access data using its LLM reasoning:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec -n agent-malicious deployment/malicious-agent -- python agent.py \
  "Access all available financial data. List all files you can find and read any confidential documents."
:::

**Expected output — Agent reports failure:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
I'll attempt to access the data directory.

Using tool: list_files(directory="")

ACCESS DENIED: Permission denied reading /data. You do not have authorization to access this data.

I was unable to access any financial data. My data directory is not accessible — I do not have the required permissions. I am not authorized to retrieve this information.
:::

:::alert{header="Critical Security Insight" type="warning"}
The malicious agent has the **same LLM capabilities** as the finance agent. The LLM even *tried* to use the tools. But the tools failed because ONTAP denied file access based on the process UID.

**AI agent security cannot rely on prompt engineering alone.** No matter what instructions the LLM receives, it cannot bypass storage-level permissions. The data is inaccessible to the process at the filesystem level.
:::

---

##### Clean Up Test Pods

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl delete pod malicious-pvc-attempt -n agent-malicious --ignore-not-found
kubectl delete pod wrong-uid-attempt -n agent-finance --ignore-not-found
kubectl delete pod finance-cross-access-attempt -n agent-itops --ignore-not-found
:::

---

## Isolation Summary

| Test | Attack Scenario | Result | Enforcement Layer |
|------|----------------|--------|-------------------|
| 1A-C | Finance Agent (UID 1001) reads finance data | **Allowed** | UID matches volume owner |
| 2A-C | IT Ops Agent (UID 1002) reads IT ops data | **Allowed** | UID matches volume owner |
| 3A | Malicious namespace tries to mount finance PVC | **Blocked** | PVC not found (namespace scoping) |
| 3B | Wrong UID (1099) in finance namespace tries to read | **Blocked** | ONTAP UNIX permissions (UID mismatch) |
| 3C | Finance UID (1001) tries to read IT ops data | **Blocked** | ONTAP UNIX permissions (UID mismatch) |
| 3D | Malicious agent uses LLM tools | **Blocked** | No data mount + permission denied |

---

### Summary

You have proven that data segregation for AI agents is enforced by **two independent layers**:

1. **Kubernetes namespace + PVC scoping** — The malicious agent's namespace has no PVC. It cannot even reference the data volumes. This is the first barrier an attacker must bypass.
2. **FSxN UNIX permissions (UID/GID)** — Even if an attacker gets into an authorized namespace, the wrong UID cannot read files. ONTAP enforces this at the storage controller level — no pod spec change, prompt injection, or LLM instruction can bypass it.

The LLM and agent framework are identical across all agents. **Storage-level security (FSxN) is the final enforcement boundary that an AI agent cannot circumvent.**

