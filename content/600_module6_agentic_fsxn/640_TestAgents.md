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
kubectl exec deployment/finance-agent -- python agent.py \
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
kubectl exec deployment/finance-agent -- python agent.py \
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
kubectl exec deployment/finance-agent -- python agent.py \
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
kubectl exec deployment/itops-agent -- python agent.py \
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
kubectl exec deployment/itops-agent -- python agent.py \
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
kubectl exec deployment/itops-agent -- python agent.py \
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

## Part 3: Malicious Agent — Access BLOCKED

Now for the critical security test. The malicious agent runs as **UID 1099** — which doesn't match the ownership of either volume. Even though the volumes are mounted via Trident, ONTAP's UNIX permissions deny read access.

##### Test 3A: Malicious Agent Attempts to Read Finance Data (UID Mismatch)

We'll mount the finance volume into the malicious agent's pod and verify that UID 1099 cannot read files owned by UID 1001:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Deploy a test pod running as UID 1099 with the finance volume mounted
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: malicious-read-attempt
spec:
  securityContext:
    runAsUser: 1099
    runAsGroup: 1099
  containers:
  - name: attacker
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sh", "-c", "echo '=== Attempting to list finance data ==='; ls /data/ 2>&1; echo ''; echo '=== Attempting to read earnings report ==='; cat /data/reports/q1_2024_earnings.txt 2>&1; sleep 10"]
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
# Wait for pod to complete and check results
kubectl wait --for=condition=Ready pod/malicious-read-attempt --timeout=60s 2>/dev/null || true
sleep 15
kubectl logs malicious-read-attempt
:::

**Expected result — BLOCKED by UNIX Permissions:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Attempting to list finance data ===
ls: cannot open directory '/data/': Permission denied

=== Attempting to read earnings report ===
cat: /data/reports/q1_2024_earnings.txt: Permission denied
:::

:::alert{header="UNIX Permissions Enforcement" type="warning"}
The volume IS mounted (Trident handled the NFS mount successfully). But the **files** are owned by UID 1001 with mode 750. UID 1099 (malicious agent) is neither the owner nor in the group, so ONTAP returns "Permission denied" at the storage controller level.

This is the key insight: **even when a volume is mounted, ONTAP enforces file-level access based on the process UID.** The malicious agent cannot bypass this regardless of what the LLM instructs it to do.
:::

##### Test 3B: Malicious Agent Attempts to Read IT Ops Data (UID Mismatch)

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Same test against IT ops volume
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: malicious-itops-attempt
spec:
  securityContext:
    runAsUser: 1099
    runAsGroup: 1099
  containers:
  - name: attacker
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sh", "-c", "echo '=== Attempting to list IT ops data ==='; ls /data/ 2>&1; echo ''; echo '=== Attempting to read runbook ==='; cat /data/runbooks/incident_response.md 2>&1; sleep 10"]
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
kubectl wait --for=condition=Ready pod/malicious-itops-attempt --timeout=60s 2>/dev/null || true
sleep 15
kubectl logs malicious-itops-attempt
:::

**Expected result — BLOCKED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Attempting to list IT ops data ===
ls: cannot open directory '/data/': Permission denied

=== Attempting to read runbook ===
cat: /data/runbooks/incident_response.md: Permission denied
:::

##### Test 3C: Finance Agent Cannot Read IT Ops Data (Cross-Volume UID Mismatch)

Even the authorized Finance agent (UID 1001) cannot read IT Ops data (owned by UID 1002):

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Deploy a pod as UID 1001 (finance) but mount the IT ops volume
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: finance-cross-access-attempt
spec:
  securityContext:
    runAsUser: 1001
    runAsGroup: 1001
  containers:
  - name: finance-user
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sh", "-c", "echo '=== Finance UID trying to read IT ops data ==='; ls /data/ 2>&1; cat /data/runbooks/incident_response.md 2>&1; sleep 10"]
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
kubectl wait --for=condition=Ready pod/finance-cross-access-attempt --timeout=60s 2>/dev/null || true
sleep 15
kubectl logs finance-cross-access-attempt
:::

**Expected result — BLOCKED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Finance UID trying to read IT ops data ===
ls: cannot open directory '/data/': Permission denied
cat: /data/runbooks/incident_response.md: Permission denied
:::

:::alert{header="Cross-Agent Isolation Proven" type="info"}
Even a legitimate agent (Finance, UID 1001) cannot read another team's data (IT Ops, owned by UID 1002). The isolation is enforced per-volume by ONTAP, not by Kubernetes namespace boundaries. Each UID is confined to its own volume's data.
:::

##### Test 3D: Run the Malicious Agent with LLM — Agent Reports Its Own Failure

Let's ask the malicious agent (running as UID 1099 with no valid data mount) to try to access data using its LLM reasoning:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl exec deployment/malicious-agent -- python agent.py \
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
kubectl delete pod malicious-read-attempt malicious-itops-attempt finance-cross-access-attempt --ignore-not-found
:::

---

## Isolation Summary

| Test | Agent/UID | Target Volume | Result | Enforcement |
|------|-----------|--------------|--------|-------------|
| 1A-C | Finance (UID 1001) | finance_agent_data | **Allowed** | UID 1001 = owner |
| 2A-C | IT Ops (UID 1002) | itops_agent_data | **Allowed** | UID 1002 = owner |
| 3A | Malicious (UID 1099) | finance_agent_data | **Denied** | UID 1099 ≠ owner (1001) |
| 3B | Malicious (UID 1099) | itops_agent_data | **Denied** | UID 1099 ≠ owner (1002) |
| 3C | Finance (UID 1001) | itops_agent_data | **Denied** | UID 1001 ≠ owner (1002) |
| 3D | Malicious (UID 1099) | any data via LLM | **Denied** | Tools return Permission Denied |

---

### Summary

You have proven that FSxN's UNIX permissions enforce data segregation for AI agents:

1. **Correct UID → access granted** — Finance agent (1001) reads finance data; IT Ops agent (1002) reads IT ops data
2. **Wrong UID → access denied** — Malicious agent (1099) is blocked from both volumes; Finance agent is blocked from IT ops data
3. **Storage-level enforcement** — ONTAP denies access at the file level, regardless of whether the volume is mounted or what the LLM instructs

The LLM and agent framework are identical across all agents. **Security is enforced by the ONTAP storage controller based on process UID** — making it impossible for a compromised or malicious AI agent to read data it's not authorized for.

