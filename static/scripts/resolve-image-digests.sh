#!/bin/bash
# =============================================================================
# resolve-image-digests.sh
#
# Re-resolves the sha256 digests for the workshop's custom ECR Public images
# and, with --write, updates every file that references them.
#
# WHY DIGESTS
#   A mutable tag such as :latest or :slim means the image can change without
#   any change to this repo. A workshop that passed end-to-end testing can then
#   break with nothing to show in git history. Pinning by digest makes each
#   deployment reproducible, and makes an intentional image update a visible
#   commit.
#
# WHEN TO RUN
#   After rebuilding and pushing any of these images. Run with --write, review
#   the diff, commit it.
#
# USAGE
#   ./resolve-image-digests.sh            # report only, changes nothing
#   ./resolve-image-digests.sh --write    # rewrite the references in place
#
# No AWS credentials are needed: ECR Public serves manifests anonymously.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
ACCEPT='application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json'
REGISTRY="public.ecr.aws"
NAMESPACE="parikshit"

# repo:tag pairs to resolve. Keep in step with the references in the repo.
IMAGES=(
  "fsxn-strands-agent:latest"
  "huggingface-cli:slim"
  "s5cmd:latest"
  "openwebui:latest-v0.9.1"
)

command -v curl   >/dev/null || { echo "${RED}curl not found${NC}"; exit 1; }
command -v shasum >/dev/null || { echo "${RED}shasum not found${NC}"; exit 1; }

resolve() {  # repo tag -> prints digest, or empty on failure
  local repo="$1" tag="$2" tok body dig code
  tok=$(curl -s --max-time 25 \
        "https://${REGISTRY}/token/?scope=repository:${NAMESPACE}/${repo}:pull&service=${REGISTRY}" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [[ -n "$tok" ]] || return 1
  body=$(mktemp)
  curl -sS --max-time 40 -o "$body" -H "Authorization: Bearer $tok" -H "Accept: ${ACCEPT}" \
       "https://${REGISTRY}/v2/${NAMESPACE}/${repo}/manifests/${tag}" || { rm -f "$body"; return 1; }
  # An OCI digest is the sha256 of the raw manifest bytes.
  dig="sha256:$(shasum -a 256 "$body" | awk '{print $1}')"
  # Prove it by fetching the same manifest back by digest.
  code=$(curl -s --max-time 40 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $tok" -H "Accept: ${ACCEPT}" \
        "https://${REGISTRY}/v2/${NAMESPACE}/${repo}/manifests/${dig}")
  rm -f "$body"
  [[ "$code" == "200" ]] || return 1
  printf '%s' "$dig"
}

changed=0; failed=0
for spec in "${IMAGES[@]}"; do
  repo="${spec%%:*}"; tag="${spec##*:}"
  printf "%-24s " "$repo:$tag"
  if ! dig=$(resolve "$repo" "$tag"); then
    echo "${RED}could not resolve${NC}"; ((failed++)); continue
  fi
  echo "$dig"

  # What the repo currently references. Two shapes are in use: an inline
  # repo@sha256:... reference, and the Helm values file, which keeps the
  # repository and the tag on separate lines so the digest rides on the tag.
  cur=$(grep -rhoE "${REGISTRY}/${NAMESPACE}/${repo}@sha256:[a-f0-9]{64}" "$ROOT/content" "$ROOT/static" 2>/dev/null | head -1 | sed 's/.*@//')
  if [[ -z "$cur" ]]; then
    while IFS= read -r vf; do
      grep -q "${REGISTRY}/${NAMESPACE}/${repo}\$" "$vf" || continue
      cur=$(grep -oE "^\s*tag:\s*\S*@sha256:[a-f0-9]{64}" "$vf" | head -1 | sed 's/.*@//')
      [[ -n "$cur" ]] && break
    done < <(grep -rl "${REGISTRY}/${NAMESPACE}/${repo}" "$ROOT/static" 2>/dev/null)
  fi
  if [[ -z "$cur" ]]; then
    echo "  ${YELLOW}not currently pinned in the repo${NC}"
  elif [[ "$cur" == "$dig" ]]; then
    echo "  ${GREEN}already current${NC}"
    continue
  else
    echo "  ${YELLOW}repo has ${cur}${NC}"
  fi

  if (( WRITE )); then
    # replace an existing pin, or a bare tag reference, with the new digest
    while IFS= read -r f; do
      perl -pi -e "s{\Q${REGISTRY}/${NAMESPACE}/${repo}\E\@sha256:[a-f0-9]{64}}{${REGISTRY}/${NAMESPACE}/${repo}\@${dig}}g" "$f"
      perl -pi -e "s{\Q${REGISTRY}/${NAMESPACE}/${repo}:${tag}\E(?![\w.-])}{${REGISTRY}/${NAMESPACE}/${repo}\@${dig}}g" "$f"
    done < <(grep -rlE "${REGISTRY}/${NAMESPACE}/${repo}([:@]|\$)" "$ROOT/content" "$ROOT/static" 2>/dev/null)
    # the Helm values file carries the digest on the tag line
    ow="$ROOT/static/eks/genai/open-webui-helm/values.yaml"
    if [[ "$repo" == "openwebui" && -f "$ow" ]]; then
      perl -pi -e "s{^(\s*tag:\s*\Q${tag}\E)(\@sha256:[a-f0-9]{64})?\s*\$}{\$1\@${dig}\n}" "$ow"
    fi
    echo "  ${GREEN}updated${NC}"; ((changed++))
  fi
done

echo
if (( failed )); then
  echo "${RED}${failed} image(s) could not be resolved.${NC}"; exit 1
fi
if (( WRITE )); then
  echo "${GREEN}${changed} reference set updated.${NC} Review with: git diff"
else
  echo "Report only. Re-run with --write to update the files."
fi
