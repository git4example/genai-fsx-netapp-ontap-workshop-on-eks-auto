#!/bin/bash
# =============================================================================
# validate-volume-contents.sh — READ-ONLY inspection of what is ON the volumes
#
# Mounts each workshop PVC into a short-lived netshoot pod and lists contents,
# sizes, POSIX ownership, and the underlying NFS export path.
#
# The `mount | grep` output is the useful cross-check: it prints the real NFS
# path being mounted, independently corroborating the PV's internalName.
#
# The two PVCs live in different namespaces (ontap-model-claim in `default`,
# agent-shared-data in `agents`), so a single pod cannot mount both — hence two
# separate pods below.
#
# NOTE ON POD LIFECYCLE: these pods are created detached, then waited on, then
# deleted explicitly. They deliberately do NOT use `kubectl run --rm -it`:
# on an EKS Auto Mode cluster scaled to zero nodes, a node has to be provisioned
# first (1-2 min), `-it` times out waiting for the TTY, and `--rm` then deletes
# the pod — destroying the very diagnostics you wanted. See run_probe() below.
#
# Read-only: every command is ls / du / stat / mount / df.
# =============================================================================

hdr() { echo; echo "============================================================"; echo "  $*"; echo "============================================================"; }

# run_probe <pod-name> <namespace> <overrides-json>
# Creates the pod, waits for it to finish (tolerating slow node scale-up),
# prints its logs, and cleans up. On timeout it dumps the pod's Events, which is
# what actually explains a Pending pod (no capacity, PVC unbound, image pull).
run_probe() {
    local pod="$1" ns="$2" overrides="$3"
    kubectl delete pod "$pod" -n "$ns" --ignore-not-found >/dev/null 2>&1

    if ! kubectl run "$pod" -n "$ns" --restart=Never \
            --image=nicolaka/netshoot --overrides="$overrides" >/dev/null; then
        echo "FAILED to create pod $ns/$pod"; return 1
    fi

    # 5 min: covers EKS Auto Mode provisioning a node from zero + image pull.
    echo "Waiting for $ns/$pod (a node may need to scale up first)..."
    if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
            "pod/$pod" -n "$ns" --timeout=300s >/dev/null 2>&1; then
        echo "Pod did not reach Succeeded. Current state and Events:"
        kubectl get pod "$pod" -n "$ns" 2>/dev/null
        kubectl describe pod "$pod" -n "$ns" 2>/dev/null | sed -n '/Events:/,$p'
        echo "--- logs (may be empty if it never started) ---"
        kubectl logs "$pod" -n "$ns" 2>/dev/null || true
        kubectl delete pod "$pod" -n "$ns" --ignore-not-found >/dev/null 2>&1
        return 1
    fi

    kubectl logs "$pod" -n "$ns"
    kubectl delete pod "$pod" -n "$ns" --ignore-not-found >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
hdr "1. MODEL VOLUME  (PVC: ontap-model-claim, ns: default)"
# -----------------------------------------------------------------------------
# The file count is 16 entries: 15 model/tokenizer/config files plus the .cache
# directory left behind by `hf download --local-dir`. HuggingFace reports
# "Fetching 17 files" because it counts differently — do not treat 17 as the
# expected value here.
run_probe netshoot-model default '
{
  "spec": {
    "containers": [{
      "name": "netshoot",
      "image": "nicolaka/netshoot",
      "command": ["sh","-c","
        echo \"--- NFS mount source (cross-checks internalName) ---\";
        mount | grep /model-vol;
        echo;
        echo \"--- capacity ---\";
        df -h /model-vol;
        echo;
        echo \"--- top level ---\";
        ls -la /model-vol/;
        echo;
        echo \"--- Mistral-7B model files ---\";
        ls -la /model-vol/Mistral-7B-Instruct-v0.3/ 2>/dev/null || echo \"MODEL DIR NOT FOUND\";
        echo;
        echo \"--- total size (expect ~27 GiB) ---\";
        du -sh /model-vol/Mistral-7B-Instruct-v0.3/ 2>/dev/null;
        echo;
        echo \"--- entry count (expect 16: 15 files + .cache) ---\";
        ls -1a /model-vol/Mistral-7B-Instruct-v0.3/ 2>/dev/null | grep -vc \"^\\.\\{1,2\\}$\";
        echo;
        echo \"--- required vLLM artifacts present? ---\";
        for f in config.json neuron_config.json model.pt model.safetensors.index.json tokenizer.json; do
          if [ -f \"/model-vol/Mistral-7B-Instruct-v0.3/$f\" ]; then echo \"  OK   $f\"; else echo \"  MISSING $f\"; fi;
        done;
        echo;
        echo \"--- .snapshot dir visible? (snapshotDir=true) ---\";
        ls -d /model-vol/.snapshot 2>/dev/null && ls /model-vol/.snapshot/ | head -5 || echo \"not visible\"
      "],
      "volumeMounts": [{"name":"model","mountPath":"/model-vol"}]
    }],
    "volumes": [{"name":"model","persistentVolumeClaim":{"claimName":"ontap-model-claim"}}]
  }
}'

# -----------------------------------------------------------------------------
hdr "2. AGENT DATA VOLUME  (PVC: agent-shared-data, ns: agents)"
# -----------------------------------------------------------------------------
# The stat loop matters: the Agentic AI module's access-control demo depends on
# per-agent UID ownership and directory modes being correct on FSxN.
run_probe netshoot-agent agents '
{
  "spec": {
    "containers": [{
      "name": "netshoot",
      "image": "nicolaka/netshoot",
      "command": ["sh","-c","
        echo \"--- NFS mount source ---\";
        mount | grep /agent-vol;
        echo;
        echo \"--- capacity ---\";
        df -h /agent-vol;
        echo;
        echo \"--- tree ---\";
        ls -laR /agent-vol/ | head -60;
        echo;
        echo \"--- per-dir sizes ---\";
        du -sh /agent-vol/* 2>/dev/null;
        echo;
        echo \"--- POSIX owners + modes (expect finance UID 1001, itops UID 1002, mode 750) ---\";
        find /agent-vol -maxdepth 2 -exec stat -c \"%u:%g %a %n\" {} \\; 2>/dev/null;
        echo;
        echo \"--- file counts per dir ---\";
        for d in /agent-vol/*/; do printf \"%s: %s files\n\" \"$d\" \"$(ls -1 \"$d\" 2>/dev/null | wc -l)\"; done
      "],
      "volumeMounts": [{"name":"agent","mountPath":"/agent-vol"}]
    }],
    "volumes": [{"name":"agent","persistentVolumeClaim":{"claimName":"agent-shared-data"}}]
  }
}'

hdr "DONE"
echo "Compare the 'NFS mount source' lines against section 1 of"
echo "validate-volumes.sh — they must agree on the ONTAP volume name."
