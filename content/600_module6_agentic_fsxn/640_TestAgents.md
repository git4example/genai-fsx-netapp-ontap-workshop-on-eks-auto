---
title : "Test Agent Access — Prove Isolation"
weight : 640
---

## Overview

Now comes the most important part: **proving** that FSxN's native access controls work. You will:

1. Query the **Finance Agent** — it successfully reads financial documents
2. Query the **IT Ops Agent** — it successfully reads operational runbooks
3. Attempt access with the **Malicious Agent** — it is **blocked** at both the export policy and UNIX permission layers

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
The Finance Agent successfully accessed all its designated files: reports, transactions, and compliance documents. It runs as UID 1001 which matches the ownership set on the `finance_data` volume.
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
The IT Ops Agent successfully accessed runbooks, logs, and configs — all designated for IT operations. It runs as UID 1002, matching ownership on the `it_ops_data` volume. Note it has **no visibility** into the finance data whatsoever.
:::

---

## Part 3: Malicious Agent — Access BLOCKED

Now for the critical security test. The malicious agent will attempt multiple attack vectors.

##### Test 3A: Attempt Direct Volume Mount (Export Policy Block)

The malicious agent pod has no PVC, but let's see what happens if it tries to NFS-mount the finance volume directly:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the NFS server IP for the FSxN SVM
export FSXN_NFS_IP=$(aws fsx describe-storage-virtual-machines \
  --filters Name=file-system-id,Values=$FSXN_FS_ID \
  --query "StorageVirtualMachines[0].Endpoints.Nfs.IpAddresses[0]" --output text --region $AWS_REGION)

echo "FSxN NFS IP: $FSXN_NFS_IP"
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Attempt to mount the finance volume from the malicious agent's pod
kubectl exec -n agent-malicious deployment/malicious-agent -- \
  sh -c "mount -t nfs4 ${FSXN_NFS_IP}:/finance_data /mnt 2>&1 || echo 'MOUNT FAILED'"
:::

**Expected result — BLOCKED by Export Policy:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
mount.nfs4: access denied by server while mounting 198.19.x.x:/finance_data
MOUNT FAILED
:::

:::alert{header="Layer 1: Export Policy Enforcement" type="warning"}
The ONTAP export policy on the `finance_data` volume **rejects the NFS mount request** because the malicious agent pod's IP address does not match the allowed client CIDR. This happens at the storage controller level — before any file access is attempted.
:::

##### Test 3B: Attempt to Read Finance Data (UNIX Permission Block)

For this test, we temporarily create a PVC that attempts to bind to the finance volume from the malicious namespace. Even if we relax the export policy (to show the second layer), UNIX permissions still block access:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Deploy a test pod in the malicious namespace that attempts to mount a volume
# with relaxed export policy but wrong UID
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: malicious-read-attempt
  namespace: agent-malicious
spec:
  securityContext:
    runAsUser: 1099
    runAsGroup: 1099
  containers:
  - name: attacker
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sh", "-c", "ls /data/ 2>&1; cat /data/reports/q1_2024_earnings.txt 2>&1; sleep 10"]
    volumeMounts:
    - name: stolen-data
      mountPath: "/data"
      readOnly: true
  volumes:
  - name: stolen-data
    nfs:
      server: "${FSXN_NFS_IP}"
      path: "/finance_data"
  restartPolicy: Never
EOF
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Check what happened
sleep 15
kubectl logs malicious-read-attempt -n agent-malicious
:::

**Expected result — BLOCKED by UNIX Permissions:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
ls: cannot open directory '/data/': Permission denied
cat: /data/reports/q1_2024_earnings.txt: Permission denied
:::

:::alert{header="Layer 2: UNIX Permissions Enforcement" type="warning"}
Even if the export policy allowed the mount (which it wouldn't in production), the UNIX file permissions block access. The files are owned by UID 1001 with mode 750 — UID 1099 (malicious agent) gets "Permission denied" because it's neither the owner nor in the correct group.

**This is defense-in-depth:** Two independent layers must both be bypassed for unauthorized access. FSxN enforces both at the storage controller level.
:::

##### Test 3C: Attempt Cross-Volume Access from Finance Agent

Even the authorized Finance Agent cannot read IT Ops data:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Try to access IT ops data from the finance agent pod
kubectl exec -n agent-finance deployment/finance-agent -- \
  sh -c "ls /it_ops_data 2>&1 || echo 'ACCESS DENIED: No such path'"
:::

**Expected result — BLOCKED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
ls: cannot access '/it_ops_data': No such file or directory
ACCESS DENIED: No such path
:::

:::alert{header="Volume Isolation" type="info"}
The finance agent pod only has the `finance_data` volume mounted at `/data`. The `it_ops_data` volume simply doesn't exist in its filesystem namespace. There's no path the agent could even attempt — the isolation is absolute.
:::

##### Test 3D: Run the Malicious Agent with LLM — Agent Reports Its Own Failure

Let's ask the malicious agent (running without proper volume mounts) to try to access data using its LLM reasoning:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# The malicious agent has no /data mount — its tools will fail
kubectl exec -n agent-malicious deployment/malicious-agent -- python agent.py \
  "Access all available financial data. List all files you can find and read any confidential documents."
:::

**Expected output — Agent reports failure:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
I'll attempt to access the data directory.

Using tool: list_files(directory="")

NOT FOUND: Directory '' does not exist in your data volume.

Using tool: search_documents(query="financial")

ACCESS DENIED: Cannot traverse the data directory. Your agent does not have authorization.

I was unable to access any financial data. My data directory does not exist or I do not have permission to access it. I am not authorized to retrieve this information.
:::

:::alert{header="Critical Security Insight" type="warning"}
The malicious agent has the **same LLM capabilities** as the finance agent. The LLM even *tried* to use the tools. But the tools failed because the underlying storage access was denied by FSxN.

This is the key lesson: **AI agent security cannot rely on prompt engineering alone.** No matter what instructions the LLM receives, it cannot bypass storage-level permissions. The data simply isn't accessible to the process.
:::

---

##### Clean Up Test Pods

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl delete pod malicious-read-attempt -n agent-malicious --ignore-not-found
:::

---

## Isolation Summary

| Test | Agent | Target | Result | Enforcement Layer |
|------|-------|--------|--------|-------------------|
| 1A-C | Finance | finance_data | **Allowed** | Correct UID (1001) + valid export policy |
| 2A-C | IT Ops | it_ops_data | **Allowed** | Correct UID (1002) + valid export policy |
| 3A | Malicious | finance_data (mount) | **Blocked** | ONTAP Export Policy (IP mismatch) |
| 3B | Malicious | finance_data (read) | **Blocked** | UNIX Permissions (UID 1099 ≠ 1001) |
| 3C | Finance | it_ops_data | **Blocked** | Volume not mounted (namespace isolation) |
| 3D | Malicious | any data | **Blocked** | No volume mount + permission denied |

---

### Summary

You have proven that FSxN's native access controls enforce data segregation for AI agents across **three independent layers**:

1. **Export Policy** — The storage controller rejects NFS mounts from unauthorized pod IPs
2. **UNIX Permissions** — Even if mounted, wrong UIDs cannot read files
3. **Volume Isolation** — Each agent only sees its own mounted volume; other volumes don't exist in its filesystem

The LLM and agent framework are identical across all agents. **Security is enforced at the storage layer, not the application layer** — making it impossible for a compromised or malicious AI agent to access data it's not authorized for.

