#!/bin/bash
# =============================================================================
# validate-volumes.sh — READ-ONLY validation of PV / PVC / ONTAP volume wiring
#
# Answers one question definitively: are the workshop PVCs bound to the
# PRE-PROVISIONED Terraform volumes ("model", "agent_shared_data"), or did
# Trident dynamically provision brand-new volumes instead?
#
# The authoritative field is .spec.csi.volumeAttributes.internalName on the PV
# — that is the real FlexVol name on ONTAP.
#   internalName == "model"              -> volume was IMPORTED
#   internalName == "trident_pvc_<uuid>" -> volume was DYNAMICALLY PROVISIONED
#
# Nothing here mutates cluster or storage state. Safe to run on a live
# workshop environment.
#
# Usage:  ./validate-volumes.sh
#   AWS_REGION is auto-detected if not set.
# =============================================================================

# NOTE: deliberately NOT using `set -e` — every check should run even if an
# earlier one fails, so you get the full picture in one pass.

MODEL_CLAIM="ontap-model-claim"        # namespace: default
AGENT_CLAIM="agent-shared-data"        # namespace: agents
AGENT_NS="agents"
BACKEND_NAME="fsx-ontap-nas"

: "${AWS_REGION:=$(aws configure get region 2>/dev/null || echo us-west-2)}"
export AWS_REGION

hdr() { echo; echo "============================================================"; echo "  $*"; echo "============================================================"; }

# -----------------------------------------------------------------------------
hdr "1. THE DECIDING CHECK — PV -> real ONTAP volume name"
# -----------------------------------------------------------------------------
echo "If ONTAP_VOL shows 'model' / 'agent_shared_data'  -> import WORKED"
echo "If ONTAP_VOL shows 'trident_pvc_<uuid>'           -> dynamic provisioning"
echo
kubectl get pv -o custom-columns=\
'PV:.metadata.name,'\
'CLAIM:.spec.claimRef.name,'\
'NS:.spec.claimRef.namespace,'\
'ONTAP_VOL:.spec.csi.volumeAttributes.internalName,'\
'BACKEND:.spec.csi.volumeAttributes.backend,'\
'RECLAIM:.spec.persistentVolumeReclaimPolicy,'\
'SIZE:.spec.capacity.storage'

# -----------------------------------------------------------------------------
hdr "2. Trident's own volume records"
# -----------------------------------------------------------------------------
kubectl get tridentvolumes -n trident -o custom-columns=\
'PV:.metadata.name,'\
'ONTAP_VOL:.config.internalName,'\
'REQUESTED:.config.size,'\
'POOL:.pool,'\
'MANAGED:.config.importNotManaged' 2>/dev/null || echo "(no tridentvolumes found)"

# -----------------------------------------------------------------------------
hdr "3. Did Trident record an import? (checks the REAL annotations)"
# -----------------------------------------------------------------------------
# The only annotations Trident actually honours are importOriginalName /
# importBackendUUID / notManaged / importNoRename. Trident *injects* these
# itself on a successful import, so their presence proves an import occurred.
for pair in "default/$MODEL_CLAIM" "$AGENT_NS/$AGENT_CLAIM"; do
    ns="${pair%%/*}"; claim="${pair##*/}"
    echo "--- $ns/$claim ---"
    kubectl get pvc "$claim" -n "$ns" -o jsonpath='{.metadata.annotations}' 2>/dev/null | tr ',' '\n' | sed 's/^[{ ]*//'
    echo
done
echo "Look for: trident.netapp.io/importOriginalName  (present = real import)"
echo "Ignore:   trident.netapp.io/importVolume        (not a real Trident key)"

# -----------------------------------------------------------------------------
hdr "4. PVC / PV / StorageClass state"
# -----------------------------------------------------------------------------
kubectl get pvc -A
echo
kubectl get storageclass ontap-nas-sc -o custom-columns=\
'NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDMODE:.volumeBindingMode'
echo
echo "NOTE: reclaimPolicy=Retain means FlexVols SURVIVE PVC deletion —"
echo "      orphaned volumes accumulate on FSxN across redeploys."

# -----------------------------------------------------------------------------
hdr "5. Trident backend health + UUID"
# -----------------------------------------------------------------------------
kubectl get tridentbackendconfig -n trident
echo
echo "Backend UUID (needed if you ever fix import via importBackendUUID):"
kubectl get tbe -n trident -o custom-columns='TBE:.metadata.name,BACKEND:.backendName,UUID:.backendUUID' 2>/dev/null

# -----------------------------------------------------------------------------
hdr "6. GROUND TRUTH from AWS — every volume on the filesystem"
# -----------------------------------------------------------------------------
FSX_ID=$(aws fsx describe-file-systems --region "$AWS_REGION" \
    --query "FileSystems[?FileSystemType=='ONTAP'].FileSystemId" --output text 2>/dev/null | head -1)

if [ -n "$FSX_ID" ]; then
    echo "FileSystemId: $FSX_ID   (region: $AWS_REGION)"
    echo
    aws fsx describe-volumes --region "$AWS_REGION" \
      --query "Volumes[?FileSystemId=='$FSX_ID'].{Name:Name,Junction:OntapConfiguration.JunctionPath,Bytes:OntapConfiguration.SizeInBytes,State:Lifecycle}" \
      --output table
    echo
    echo "Expected if import is BROKEN: 'model' and 'agent_shared_data' exist"
    echo "but are unused, alongside larger trident_pvc_* volumes."
    echo "(111.11 GiB = 100Gi / 0.9 — the 10% snapshotReserve markup.)"
else
    echo "Could not resolve an ONTAP filesystem in $AWS_REGION — skipping."
fi

# -----------------------------------------------------------------------------
hdr "7. Trident controller log — any import activity at all?"
# -----------------------------------------------------------------------------
kubectl logs -n trident deploy/trident-controller -c trident-main --since=48h 2>/dev/null \
  | grep -iE 'import|unsupported annotation' | tail -15
echo "(no output = Trident never attempted an import — the fake annotations"
echo " were silently ignored, which is the failure mode we suspect)"

hdr "DONE"
echo "Decisive line is section 1. Run validate-volume-contents.sh next to"
echo "confirm WHERE the model and agent data physically landed."
