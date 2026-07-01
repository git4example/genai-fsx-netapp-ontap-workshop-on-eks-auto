# AgentCore & AI Agent on Self-Hosted LLM — Workshop "What Next" Ideas

**Purpose:** Capture the brainstorming and recommendation for elevating the
FlexAI (EKS + FSx for NetApp ONTAP) workshop — i.e. "after users complete
the sample prompts, WHAT NEXT using FSxN or S3 Access Point for FSxN?"

**Context / Timeline:**
- Concept to be locked and running by **end of June**.
- AWS + NetApp GTM events: **late July – mid Aug** will use this workshop.
- Possible follow-on events after that.
- Audience: storage-focused — storage must be the hero, not generic AI.

---

## How users run prompts today (current state)

The hands-on AI interaction lives entirely in **Module 2 → `220_webui.md`**:
- Users open **Open WebUI** (ALB URL), select the `mistral-7b-neuron` model, and run three canned prompts:
  1. A bash-scripting task.
  2. A Japanese → English translation task.
  3. A **basic RAG demo** — upload a PDF to Open WebUI and re-ask "What is the guidance for deploying an MCP server."
- Backend: vLLM OpenAI-compatible endpoint (`vllm-mistral7b-service`) on Inferentia2; model on the FSxN NFS PVC (`ontap-model-claim`).
- Modules 4 and 5 already make storage the hero (snapshots, Multi-AZ failover), but the **AI experience stops at chat + single-doc upload**.

**Gap:** After the prompts, there's no agentic or data-driven payoff that shows why FSxN / S3-on-FSxN matters for GenAI. Prompt #3 (PDF upload RAG) is the natural hook to extend.

---

## Design constraints for any "what next" addition

- **Make ONTAP the hero** — lean on multiprotocol (NFS + S3), snapshots, FlexClone, SnapMirror, dedup/compression, tiering, Multi-AZ.
- **Run on the existing stack** — reuse the vLLM endpoint, Inferentia2, EKS Auto. No GPUs, no heavy training.
- **Fit ~30–45 min** on top of the existing 2-hour workshop.
- **Lockable by end of June** with low demo risk.

---

## Ideas (ranked)

### 1. RAG agent over a multiprotocol FSxN corpus (NFS + S3 access point) — TOP PICK
A small RAG service + vector store where the **knowledge corpus lives once on an FSxN volume**, exposed two ways:
- **NFS** → mounted into the ingestion/agent pods and the vLLM pod.
- **S3 Access Point on FSxN** → the *same* files appear as S3 objects, consumed by the ingestion pipeline (embeddings) or by Bedrock Knowledge Bases.

**Flow users run:** drop a new document into the volume over NFS → it's *instantly* visible via the S3 access point (no copy/sync) → ingestion generates embeddings → ask the agent a question → it retrieves from the vector store and answers via the already-deployed Mistral endpoint.

**Why it wins:** "one dataset, two protocols, zero data movement" is the headline FSxN + S3 story. Then layer the ONTAP payoff — **snapshot the corpus before ingestion, FlexClone it for a parallel experiment, SnapMirror it to the DR region** already wired up in Module 5.

**Effort/risk:** Medium. Keep it CPU-light: `pgvector` or Chroma on EKS Auto general nodes, a thin LangChain/Strands agent, embeddings via a small CPU model.

**S3 Access Points for FSxN: CONFIRMED GA** — launched at re:Invent Dec 2025 ([announcement](https://aws.amazon.com/about-aws/whats-new/2025/12/amazon-fsx-netapp-ontap-s3-access/)). Available in all FSx for ONTAP regions. No dependency or timeline risk. AWS blogs already demonstrate the AI/ML use case with Bedrock, SageMaker, and analytics.

### 2. Tool-using agent that can act on the FSxN volume (agentic, function-calling)
An agent (Strands Agents or LangGraph against the vLLM OpenAI endpoint) with tools like `list_files`, `read_file`, `summarize_dataset`, and — the crowd-pleaser — `create_snapshot` / `flexclone_volume`. User asks "summarize every doc added today and snapshot the volume," and the agent does file ops + an ONTAP action.

**Effort/risk:** Medium. Mistral-7B function-calling is okay but not rock-solid; constrain to 2–3 well-scoped tools for reliable demos.

### 3. Vector DB *on* FSxN (storage-efficiency angle)
Pair with #1: put the vector index data dir on an FSxN PVC and show **dedup/compression savings on embeddings**, **instant FlexClone of the index** for test/prod split, and **snapshot/restore of the index** after a bad ingestion. Pure storage-value demo.

### 4. FlexClone for parallel GenAI experimentation ("golden dataset")
Instantly clone the 29 GB model/corpus volume (zero-space FlexClone) to run an A/B — e.g., two RAG corpora or two prompt configs — side by side without duplicating data. Strong, simple, low-risk; works even as a 15-min add-on.

### 5. Data-correlation use case
Agent correlates **structured + unstructured** data on FSxN: e.g., CSV/log files + a runbook → "what's the likely root cause?" Ties to the AWS + NetApp DevOps narrative. Good story, but curating a convincing dataset is the work; medium content effort.

### Lower priority / skip for now
- **Fine-tuning / continued pre-training pipeline** — too heavy for Inferentia + 2 hrs.
- **Multimodal / image RAG** — Mistral-7B is text-only.
- **Bedrock Knowledge Base directly on the S3 access point** — clean, but adds a Bedrock dependency and pulls focus off the self-hosted EKS + FSxN story.

---

## Recommendation

Lock **#1 (multiprotocol RAG) as the new Module 6**, with **#4 (FlexClone)** as the built-in "ONTAP payoff" step and **#3** folded in (vector store on FSxN). This single module delivers the key differentiator — *the same FSxN data serving inference over NFS and feeding RAG over S3, then snapshotted/cloned/replicated* — while reusing everything already deployed.

**S3 Access Points for FSxN: ✅ CONFIRMED GA (Dec 2025, re:Invent launch).**
No dependency — available wherever FSx for ONTAP is available. Ship the full NFS + S3 multiprotocol version directly.

**Remaining open question before building:**
- Pick the embedding path: small CPU embedding model (simplest, fully self-hosted) vs. reuse the Neuron node (richer Inferentia story, more complex).

**Proposed next deliverable:** Draft the Module 6 spec (requirements / design / tasks) plus a minimal manifest set (vector DB, ingestion job, agent, S3 access point) to get something running to demo.

---

## Reusable assets already in the repo

- vLLM OpenAI-compatible endpoint: `vllm-mistral7b-service` (Mistral-7B-Instruct-v0.3 on Inferentia2).
- FSxN NFS PVC: `ontap-model-claim` (StorageClass `ontap-nas-sc`, Trident `csi.trident.netapp.io`).
- Trident backend: `backend-ontap-nas`; VolumeSnapshotClass: `trident-snapshotclass`.
- Multi-AZ FSxN (Terraform `MULTI_AZ_1`, route tables registered to EKS private subnets).
- Open WebUI (Helm) already deployed with built-in RAG/knowledge support — candidate to extend with minimal new code.
