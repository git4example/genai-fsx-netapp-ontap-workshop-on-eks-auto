#!/bin/bash
# =============================================================================
# validate-participant-policy.sh
#
# Proves that a participant can still do everything the workshop asks of them
# in the AWS Console, WITHOUT deploying and WITHOUT changing anything. It uses
# the IAM policy simulator, which only evaluates policies; it never calls the
# service being tested.
#
# TWO MODES
#
#   1) File mode (default). Evaluates static/participant_policy.json on its own.
#      Works with any credentials, in any account, because the policy is passed
#      as a document. Use this before shipping a change to that file.
#
#        ./validate-participant-policy.sh
#
#   2) Principal mode (definitive). Evaluates the real WSParticipantRole in a
#      live workshop account, so it includes the managed policies attached
#      alongside the custom one: ReadOnlyAccess, AmazonEKSClusterPolicy,
#      AmazonSSMManagedInstanceCore. Most console browsing is granted by
#      ReadOnlyAccess, not by participant_policy.json, so only this mode
#      reflects what a participant truly experiences.
#
#        ./validate-participant-policy.sh --principal \
#          arn:aws:iam::<acct>:role/WSParticipantRole
#
# EXIT: 0 if every expectation held, 1 otherwise.
# =============================================================================
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'

POLICY_FILE="$(cd "$(dirname "$0")/.." && pwd)/participant_policy.json"
PRINCIPAL=""
REGION="${AWS_REGION:-us-west-2}"
ACCOUNT="111122223333"
CLUSTER="eksworkshop"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --principal) PRINCIPAL="$2"; shift 2 ;;
    --region)    REGION="$2";    shift 2 ;;
    --account)   ACCOUNT="$2";   shift 2 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

command -v aws >/dev/null || { echo "${RED}aws CLI not found${NC}"; exit 1; }
command -v jq  >/dev/null || { echo "${RED}jq not found${NC}"; exit 1; }

if [[ -n "$PRINCIPAL" ]]; then
  ACCOUNT=$(printf '%s' "$PRINCIPAL" | cut -d: -f5)
  MODE="principal"
else
  [[ -f "$POLICY_FILE" ]] || { echo "${RED}not found: $POLICY_FILE${NC}"; exit 1; }
  POLICY_JSON=$(jq -c . "$POLICY_FILE") || { echo "${RED}invalid JSON in $POLICY_FILE${NC}"; exit 1; }
  MODE="file"
fi

FS="arn:aws:fsx:${REGION}:${ACCOUNT}:file-system/fs-0123456789abcdef0"
VOL="arn:aws:fsx:${REGION}:${ACCOUNT}:volume/fsvol-0123456789abcdef0"
SVM="arn:aws:fsx:${REGION}:${ACCOUNT}:storage-virtual-machine/svm-0123456789abcdef0"
CL="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
NG="arn:aws:eks:${REGION}:${ACCOUNT}:nodegroup/${CLUSTER}/ng-1/abcdef"
STACK="arn:aws:cloudformation:${REGION}:${ACCOUNT}:stack/genaifsxworkshoponeks/abcdef"
SECRET="arn:aws:secretsmanager:${REGION}:${ACCOUNT}:secret:trident-fsx-ontap-svm-abcdef"

# action | resource | expect-in-file-mode | expect-in-principal-mode | why
CASES=(
  # --- granted by participant_policy.json, so both modes expect allowed
  "fsx:DescribeFileSystems|${FS}|allowed|allowed|Module 1 105: FSx console"
  "fsx:DescribeVolumes|${VOL}|allowed|allowed|Module 1 105 / Module 5: volume list"
  "fsx:DescribeStorageVirtualMachines|${SVM}|allowed|allowed|Module 1 105: SVM page"
  "fsx:DescribeSnapshots|${VOL}|allowed|allowed|Module 5 Part 3: snapshot policy"
  "fsx:UpdateFileSystem|${FS}|allowed|allowed|Module 7 Step 3: throughput change"
  "eks:ListClusters|*|allowed|allowed|Module 030: EKS console list"
  "eks:DescribeCluster|${CL}|allowed|allowed|Module 030: cluster overview"
  "eks:AccessKubernetesApi|${CL}|allowed|allowed|EKS console Resources tab"
  "eks:ListNodegroups|${CL}|allowed|allowed|Module 2: Compute tab"
  "eks:DescribeNodegroup|${NG}|allowed|allowed|Module 2: node detail"
  "cloudformation:DescribeStacks|${STACK}|allowed|allowed|023_vs_code: Outputs tab"
  "ec2:DescribeInstances|*|allowed|allowed|EC2 console"
  "ec2:DescribeSubnets|*|allowed|allowed|Module 7 710: subnet to AZ"
  "ec2:DescribeNetworkInterfaces|*|allowed|allowed|Module 7 710: ENI discovery"
  "ec2:GetManagedResourceVisibility|*|allowed|allowed|EC2 console, Auto Mode nodes"
  "elasticloadbalancing:DescribeLoadBalancers|*|allowed|allowed|ALB console"
  "secretsmanager:GetSecretValue|${SECRET}|allowed|allowed|SVM password, trident-fsx-* only"
  "sts:GetCallerIdentity|*|allowed|allowed|account id lookup"

  # --- console reads that come from ReadOnlyAccess, NOT from participant_policy.
  #     Denied in file mode is CORRECT; they must be allowed in principal mode.
  "s3:ListAllMyBuckets|*|denied|allowed|S3 console (ReadOnlyAccess)"
  "ssm:DescribeInstanceInformation|*|denied|allowed|SSM console (ReadOnlyAccess)"
  "cloudwatch:GetMetricData|*|denied|allowed|CloudWatch metrics (ReadOnlyAccess)"
  "logs:DescribeLogGroups|*|denied|allowed|CloudWatch Logs (ReadOnlyAccess)"
  "ec2:DescribeRouteTables|*|denied|allowed|Module 7 route tables (ReadOnlyAccess)"
  "fsx:ListTagsForResource|${VOL}|denied|allowed|FSx console Tags tab (ReadOnlyAccess)"

  # --- deliberately removed. Another identity does these; participant must not.
  "fsx:CreateVolume|${FS}|denied|denied|Trident, via trident-controller role"
  "fsx:DeleteVolume|${VOL}|denied|denied|Trident / VSCode server role"
  "fsx:UpdateVolume|${VOL}|denied|denied|VSCode server role (Module 5 CLI)"
  "fsx:CreateSnapshot|${VOL}|denied|denied|Trident, via the ONTAP API"
  "fsx:TagResource|${VOL}|denied|denied|Trident, via trident-controller role"
  "ec2:ModifyManagedResourceVisibility|*|denied|denied|deploy script, VSCode server role"
  "sts:AssumeRole|*|denied|denied|nothing in the workshop assumes a role"
)

echo "Mode    : ${MODE}"
[[ "$MODE" == "file" ]] && echo "Policy  : ${POLICY_FILE}" || echo "Role    : ${PRINCIPAL}"
echo "Region  : ${REGION}   Account: ${ACCOUNT}"
[[ "$MODE" == "file" ]] && echo "${DIM}Note: rows marked ReadOnlyAccess are expected to be denied here; run${NC}"
[[ "$MODE" == "file" ]] && echo "${DIM}      --principal against a live event to confirm those.${NC}"
echo

pass=0; fail=0
for row in "${CASES[@]}"; do
  IFS='|' read -r action resource want_file want_principal why <<< "$row"
  want=$([[ "$MODE" == "file" ]] && echo "$want_file" || echo "$want_principal")

  if [[ "$MODE" == "file" ]]; then
    raw=$(aws iam simulate-custom-policy --policy-input-list "$POLICY_JSON" \
            --action-names "$action" --resource-arns "$resource" \
            --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null)
  else
    raw=$(aws iam simulate-principal-policy --policy-source-arn "$PRINCIPAL" \
            --action-names "$action" --resource-arns "$resource" \
            --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null)
  fi

  case "$raw" in
    allowed)                   got=allowed ;;
    implicitDeny|explicitDeny) got=denied  ;;
    *)                         got="ERROR(${raw:-no-response})" ;;
  esac

  if [[ "$got" == "$want" ]]; then
    printf "  ${GREEN}OK${NC}    %-44s %-8s %s\n" "$action" "$got" "$why"; ((pass++))
  else
    printf "  ${RED}FAIL${NC}  %-44s got=%-8s want=%-8s %s\n" "$action" "$got" "$want" "$why"; ((fail++))
  fi
done

echo
if (( fail == 0 )); then
  echo "${GREEN}All ${pass} checks passed.${NC}"
  [[ "$MODE" == "file" ]] && echo "Next: re-run with --principal against a live event for the definitive check."
  exit 0
else
  echo "${RED}${fail} failed${NC}, ${pass} passed. Do not ship."
  echo "${YELLOW}A FAIL where want=allowed means the policy is too tight and that workshop step will break.${NC}"
  echo "${YELLOW}A FAIL where want=denied means a permission we intended to remove is still granted.${NC}"
  exit 1
fi
