#!/bin/bash
#
# validate-model-preload.sh
#
# Standalone validation of the MODEL pre-load mechanics that the CloudFormation
# SSM document (PreloadAgentDataDocument) performs during workshop provisioning.
#
# The CFN -> Terraform -> SSM orchestration cannot be tested without a full
# account deploy, but the underlying kubectl steps CAN be validated on any
# existing cluster that already has:
#   - The Trident CSI driver installed and a healthy "fsx-ontap-nas" backend
#   - The pre-provisioned ONTAP "model" volume (junction /model) from Terraform
#   - The "ontap-nas-sc" StorageClass applied
#
# Run this manually on such a cluster. If every step passes, the SSM document
# is just wrapping these verified commands.
#
# Usage:  ./validate-model-preload.sh
#
set -euo pipefail

# Resolve the repo's manifest directory relative to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FSXN_DIR="${SCRIPT_DIR}/../eks/FSxONTAP"

echo "=== Pre-flight: Trident backend + StorageClass present ==="
kubectl get tridentbackendconfig -n trident
kubectl get storageclass ontap-nas-sc

echo
echo "=== Step 1: Import the pre-provisioned 'model' volume as ontap-model-claim ==="
kubectl apply -f "${FSXN_DIR}/ontap-pvc.yaml"

echo "Waiting for ontap-model-claim to bind (import can take ~30s)..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/ontap-model-claim --timeout=120s
kubectl get pvc ontap-model-claim

echo
echo "=== Step 2: Run the model download job onto the imported volume ==="
# Public HuggingFace repo (Hello2pariksit/Mistral-7B-Instruct-v0.3-neuron) — no HF token required.
kubectl apply -f "${FSXN_DIR}/model-loading-job.yaml"

echo "Waiting for model-download job to complete (pre-compiled model ~29GB, typically ~5 min)..."
kubectl wait --for=condition=complete job/model-download --timeout=900s
kubectl logs job/model-download | tail -20

echo
echo "=== Step 3: Confirm the model files landed on the volume ==="
kubectl run model-check --rm -i --restart=Never \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  --overrides='{"spec":{"containers":[{"name":"model-check","image":"public.ecr.aws/amazonlinux/amazonlinux:2023","command":["ls","-la","/work-dir/Mistral-7B-Instruct-v0.3/"],"volumeMounts":[{"name":"persistent-storage","mountPath":"/work-dir"}]}],"volumes":[{"name":"persistent-storage","persistentVolumeClaim":{"claimName":"ontap-model-claim"}}]}}' \
  -- ls -la /work-dir/Mistral-7B-Instruct-v0.3/

echo
echo "=== VALIDATION COMPLETE ==="
echo "If you see model-*.safetensors, tokenizer, and config files above, the"
echo "import-PVC + model-download mechanics are correct. The SSM document in"
echo "GenAIFSXWorkshopOnEKS.yaml runs these same steps at provision time."
