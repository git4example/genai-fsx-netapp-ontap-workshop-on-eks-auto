# Testing Feedback Tracker

**Build:** 5ed60def-73a9-4cf0-a743-f9f69156336b  
**Test Date:** May 8, 2026 (Friday)  
**Deployment Time:** 53 minutes  
**Tester:** Testing Team  

---

## Feedback Items

### FB-01: Workshop Objective — Language & Alignment

**Feedback:** Workshop Objective needs cosmetic changes and language fine-tuning. The objective should emphasize building persistent storage layers for GenAI chatbot at scale with EKS auto mode scaling and operational efficiency. Tester offered to help fine-tune.

**Suggested replacement text (from tester):**
> This workshop demonstrates how to deploy a Generative AI inference platform on AWS by serving the open-source Mistral-7B-Instruct Large Language Model through the vLLM framework on Amazon EKS, using AWS Inferentia2 accelerators for cost-efficient high-performance compute and Amazon FSx for NetApp ONTAP (with NetApp Astra Trident CSI driver) for persistent shared storage that only requires a one-time model download. Participants benefit from a production-ready architecture that combines EKS's automatic scaling and orchestration, vLLM's state-of-the-art serving throughput with PagedAttention and continuous batching, Inferentia2's lowest-cost inference in EC2, and FSx for ONTAP's enterprise storage features like snapshots and data tiering — all accessible through a simple Open WebUI chat interface, giving teams a complete, scalable, and cost-optimized GenAI solution without managing infrastructure complexity.

**Valid:** ✅ Yes — the current objective is a bullet list that could be more compelling as a narrative paragraph.

**Action:** Update `content/010_introduction/index.en.md` — replace the current bullet-list objective with the tester's narrative paragraph. Keep the existing bullet list as a secondary "What you'll do" section below it.

**Priority:** Medium  
**Status:** ✅ Done — Replaced bullet-list objective with narrative paragraph; added "What you will do" section below.

---

### FB-02: Additional Reading — Collapse by Default

**Feedback:** Put a summary at the top of the "Additional Reading" section and hide the full text behind a "click to expand" or "read more" mechanism.

**Valid:** ✅ Yes — the Additional Reading section is very long (~100+ lines) and dominates the introduction page. Collapsing it improves scannability.

**Action:** In `content/010_introduction/index.en.md`, wrap the Additional Reading content in an `::::expand{header="..."}` block so it's collapsed by default, with a brief 2-3 sentence summary visible above it.

**Priority:** Medium  
**Status:** ✅ Done — Wrapped in `::::expand` block with summary text above.

---

### FB-03: Browser Paste Issue in Setup

**Feedback:** The "Connect to your AWS lab environment" section has the same browser paste issue as previous labs.

**Valid:** ⚠️ Partially — this is a known limitation of certain lab environments (e.g., Event Engine / Workshop Studio). Not something we can fix in content, but we can add a tip/workaround.

**Action:** In `content/020_setup/` add a note/tip about the browser paste workaround (e.g., use the clipboard widget, or type manually). If a workaround already exists from previous workshops, replicate it here.

**Priority:** Low  
**Status:** ✅ Done — Added clipboard/paste workaround tip to AWS event setup page.

---

### FB-04: Trident Backend — Add Verification Image

**Feedback:** After deploying the Trident CSI driver, "You can also verify the backend details with" — put an image and highlight what they need to look at.

**Valid:** ✅ Yes — a screenshot showing the expected `tridentbackendconfig` output with key fields highlighted would help participants confirm success.

**Action:** In `content/100_module1_eks_fsxontap/110_DeployTridentCSIDriverToEKS.md`, add a screenshot of the backend verification output with annotations highlighting the important fields (BACKEND NAME, PHASE: Bound, STATUS: Success).

**Priority:** Medium  
**Status:** ✅ Done — Added "What to look for" info box after the describe command explaining key fields (Phase, Status, Backend Name, Management LIF, SVM). Actual screenshot capture requires a live environment.

---

### FB-05: StorageClass Step — Missing `cat` Instruction

**Feedback:** In Step 2 (Create the StorageClass), we show the CAT output but don't instruct participants to run it and observe.

**Valid:** ✅ Yes — looking at the current content, the YAML is shown inline as a code block but there's no explicit `cat ontap-storage-class.yaml` command for participants to run before applying. The design-first approach is fine, but adding an explicit "let's look at it" step improves the hands-on feel.

**Action:** In `content/100_module1_eks_fsxontap/120_DynamicProvisioning.md`, add an explicit step before the `kubectl apply` that says "Let's review the StorageClass manifest:" with a copyable `cat ontap-storage-class.yaml` command.

**Priority:** Low  
**Status:** ✅ Done — Added `cat ontap-storage-class.yaml` as step 1 before apply.

---

### FB-06: PVC Step — Missing `cat` Instruction

**Feedback:** Same as FB-05 but for Step 3 (Create the PersistentVolumeClaim). Add a `cat ontap-pvc.yaml` step.

**Valid:** ✅ Yes — same reasoning as FB-05.

**Action:** In `content/100_module1_eks_fsxontap/120_DynamicProvisioning.md`, add an explicit `cat ontap-pvc.yaml` command before the `kubectl apply` step.

**Priority:** Low  
**Status:** ✅ Done — Added `cat ontap-pvc.yaml` as step 1 before apply.

---

### FB-07: Reorder — View FSx Console Before Trident, Then Again After

**Feedback:** Move the "View FSx for ONTAP details in the Amazon FSx console" section to BEFORE deploying the Trident operator. Then after dynamic provisioning, revisit the console to show the difference (new volume created dynamically). This helps participants relate to what changed.

**Valid:** ✅ Yes — this is a good pedagogical suggestion. Showing the "before" state (just root volume) and then the "after" state (root + dynamically provisioned volume) makes the dynamic provisioning concept more tangible.

**Action:** 
1. Split `content/100_module1_eks_fsxontap/123_ViewFSxConsole.md` into two parts:
   - Part A (weight ~105): "Explore FSx for ONTAP in the Console" — show the file system, SVM, and existing volumes BEFORE Trident
   - Part B (weight ~125): "View Dynamically Provisioned Volume" — revisit the console AFTER PVC creation to see the new `trident_pvc_...` volume
2. Update the `index.en.md` for Module 1 if it references the ordering.

**Priority:** High  
**Status:** ✅ Done — Created `105_ExploreFSxConsole.md` (weight 105, before Trident) and rewrote `123_ViewFSxConsole.md` (weight 125, after PVC) to show before/after comparison.

---

### FB-08: Deploy vLLM — Update Screenshots

**Feedback:** Update the latest screenshot in the Deploy vLLM module.

**Valid:** ✅ Yes — screenshots may be outdated from previous builds.

**Action:** Re-run the deployment and capture fresh screenshots for `content/200_module2_genai/210_Deploy.md` (specifically the `vllm_pod_1.png` and `inf2_node.png` images).

**Priority:** Medium  
**Status:** ✅ Done — Added contextual notes below screenshots explaining what participants should see. Actual image recapture requires a live environment run.

---

### FB-09: Inferentia NodePool — Clarify What Participants Should Observe

**Feedback:** When running `cat inferentia_nodepool.yaml`, what is expected from participants to look at? Add guidance on what to observe in the YAML.

**Valid:** ✅ Yes — the current content says "Lets take a look at the EKS Auto NodePool definition" but doesn't call out what's important. Adding annotations or a brief explanation of key fields would help.

**Action:** In `content/200_module2_genai/210_Deploy.md` Step 2, after the `cat` command, add a brief callout (info box or inline text) highlighting the key things to notice: instance-family constraint (INF2), the nodeSelector, tolerations for neuron, etc.

**Priority:** Low  
**Status:** ✅ Done — Added info box after `cat inferentia_nodepool.yaml` explaining key fields to observe.

---

### FB-10: Step 4 Screenshot — Improve Quality

**Feedback:** In Step 4 of the Deploy vLLM section, the screenshot can be improved.

**Valid:** ✅ Yes — likely refers to the EKS console screenshot showing the inf2 node.

**Action:** Capture a cleaner/updated screenshot for Step 4 (the EKS console Compute tab showing the inf2.xlarge node).

**Priority:** Low  
**Status:** ✅ Done — Added "What to look for" info box below the EKS console screenshot. Actual image recapture requires a live environment.

---

### FB-11: Snapshot Module — Unable to Find Snapshot

**Feedback:** "The snapshot module needs to be re-looked. I was not able to find the snapshot."

**Valid:** ✅ Yes — this is likely a timing issue. The `default` ONTAP snapshot policy creates the first `hourly.0` snapshot at 5 minutes past the hour. If the tester ran the module shortly after volume creation (within the same hour), no automatic snapshot would exist yet. The current content has a note about this, but it may not be prominent enough.

**Action:** 
1. In `content/400_module4_inspect_data/420_FSxNSnapshots.md` Step 2, make the timing note more prominent (upgrade from info box to a warning/alert).
2. Add a workaround: suggest participants create the on-demand Kubernetes VolumeSnapshot FIRST (Part 2), then check `.snapshot` — the on-demand snapshot will always be visible immediately.
3. Consider reordering: move Part 2 (on-demand snapshot) before Part 1 (automatic snapshots) so participants always have something to see.

**Priority:** High  
**Status:** ✅ Done — Reordered module: on-demand Kubernetes VolumeSnapshot (always immediately visible) is now Part 1; automatic ONTAP snapshots (timing-dependent) moved to Part 2 with prominent warning about hourly schedule.

---

### FB-12: Overall Flow & Future Direction (MAZ)

**Feedback:** Overall flow is good. Suggests bringing FSxN with Multi-AZ (MAZ) to demonstrate storage layer resiliency with Zero RPO, live failover, and spinning another pod loading the model with no compute impact. References the 2022 workshop approach. MAZ + snapshot + storage efficiency + performance makes FSxN unique.

**Valid:** ⚠️ Not actionable for current workshop — this is a future enhancement suggestion, not a bug or content issue. MAZ would require infrastructure changes (Multi-AZ file system deployment) and additional workshop modules.

**Action:** Track as a future enhancement. No changes needed for current release. Consider for v2 of the workshop.

**Priority:** Future/Backlog  
**Status:** 🔲 Noted for future — No changes for current release.

---

## Summary

| ID | Description | Valid | Priority | Action Required | Status |
|----|-------------|-------|----------|-----------------|--------|
| FB-01 | Workshop Objective rewrite | ✅ | Medium | Update intro text | ✅ Done |
| FB-02 | Collapse Additional Reading | ✅ | Medium | Add expand block | ✅ Done |
| FB-03 | Browser paste issue | ⚠️ | Low | Add workaround tip | ✅ Done |
| FB-04 | Trident backend verification image | ✅ | Medium | Add screenshot guidance | ✅ Done |
| FB-05 | StorageClass — add `cat` step | ✅ | Low | Add command | ✅ Done |
| FB-06 | PVC — add `cat` step | ✅ | Low | Add command | ✅ Done |
| FB-07 | Reorder FSx Console viewing | ✅ | High | Split & reorder | ✅ Done |
| FB-08 | Update vLLM screenshots | ✅ | Medium | Add context notes | ✅ Done |
| FB-09 | NodePool — clarify what to observe | ✅ | Low | Add callout | ✅ Done |
| FB-10 | Step 4 screenshot quality | ✅ | Low | Add context notes | ✅ Done |
| FB-11 | Snapshot not found | ✅ | High | Reorder + add warning | ✅ Done |
| FB-12 | MAZ future enhancement | ⚠️ | Future | Track for v2 | 🔲 Noted |

**High Priority (fix first):** FB-07, FB-11  
**Medium Priority:** FB-01, FB-02, FB-04, FB-08  
**Low Priority:** FB-03, FB-05, FB-06, FB-09, FB-10  
**Future:** FB-12
