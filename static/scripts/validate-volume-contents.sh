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
# Read-only: every command is ls / du / stat / mount / df. Pods are --rm.
# =============================================================================

hdr() { echo; echo "============================================================"; echo "  $*"; echo "============================================================"; }

# -----------------------------------------------------------------------------
hdr "1. MODEL VOLUME  (PVC: ontap-model-claim, ns: default)"
# -----------------------------------------------------------------------------
kubectl run netshoot-model --rm -i --tty --image=nicolaka/netshoot --restart=Never \
  --overrides='
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
        echo \"--- total size ---\";
        du -sh /model-vol/Mistral-7B-Instruct-v0.3/ 2>/dev/null;
        echo;
        echo \"--- expect 17 files; count: ---\";
        ls -1 /model-vol/Mistral-7B-Instruct-v0.3/ 2>/dev/null | wc -l;
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
# The stat loop matters: Module 4's RBAC/defense-in-depth demo depends on
# per-agent UID ownership and directory modes being correct on FSxN.
kubectl run netshoot-agent -n agents --rm -i --tty --image=nicolaka/netshoot --restart=Never \
  --overrides='
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
        echo \"--- POSIX owners + modes (Module 4 RBAC depends on this) ---\";
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
