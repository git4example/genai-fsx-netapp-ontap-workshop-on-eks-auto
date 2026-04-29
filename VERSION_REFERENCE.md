# Software Version Reference

This file tracks all version-pinned software components in this workshop for maintenance and update purposes.

## Versions (as of April 2026)

### Terraform Providers (`static/terraform/main.tf`)

| Component | Version | Notes |
|---|---|---|
| **AWS Provider** (`hashicorp/aws`) | `5.99.1` | v6.x available but breaking change; stay on 5.x |
| **Kubernetes Provider** (`hashicorp/kubernetes`) | `2.37.1` | ✅ Current |
| **Helm Provider** (`hashicorp/helm`) | `2.17.0` | ✅ Current |
| **kubectl Provider** (`gavinbunney/kubectl`) | `>= 1.19` | Open constraint |

### Terraform Modules (`static/terraform/main.tf`)

| Component | Version | Notes |
|---|---|---|
| **EKS Module** (`terraform-aws-modules/eks/aws`) | `20.37.1` | ✅ Current |
| **VPC Module** (`terraform-aws-modules/vpc/aws`) | `5.21.0` | ✅ Current (v6 not yet stable) |
| **EKS Blueprints Addons** (`aws-ia/eks-blueprints-addons/aws`) | `1.23.0` | ✅ Updated from 1.21.0 |
| **EKS Data Addons** (`aws-ia/eks-data-addons/aws`) | `1.38.0` | ✅ Updated from 1.37.2 |

### Helm Charts (`static/scripts/quick-deploy-sponsored.sh`)

| Component | Version | Notes |
|---|---|---|
| **Neuron Helm Chart** (`public.ecr.aws/neuron/neuron-helm-chart`) | `1.5.0` | ✅ Updated from 1.2.0 |
| **Trident Operator** (`netapp-trident/trident-operator`) | `100.2602.0` | ✅ Updated from 100.2502.1 (adds K8s 1.35 support) |

### Container Images

| Component | Image Tag | File | Notes |
|---|---|---|---|
| **vLLM Neuron** | `0.9.1-neuronx-py311-sdk2.26.1-ubuntu22.04` | `static/eks/genai/mistral-ontap.yaml` | SDK 2.26.1 required for inf2.xlarge (see mistral-ontap.yaml header) |
| **Neuron Scheduler** | `2.29.148.0` | `static/terraform/helm-values/neuron-values.yaml` | ✅ Updated from 2.28.4.0 |
| **kube-scheduler (EKS Distro)** | `v1.35.2-eks-1-35-8` | `static/terraform/helm-values/neuron-values.yaml` | ✅ Updated to match EKS 1.35 |
| **Neuron Monitor** | `1.9.0` | `static/eks/genai/observability/neuron-monitor.yaml` | ✅ Updated from 1.3.0 |
| **Open WebUI** | `latest-v0.9.1` | `static/eks/genai/open-webui-helm/values.yaml` | Deployed via Helm chart |
| **HuggingFace CLI** | `slim` | `static/eks/FSxONTAP/model-loading-job.yaml` | Unpinned (`slim` tag) |

### EKS / Kubernetes

| Component | Version | Notes |
|---|---|---|
| **EKS Cluster Version** | `1.35` (parameterized via `--EKS_VERSION--`) | Default in CFN: `1.35`, kubectl: `1.35.0` |
| **Karpenter API** | `karpenter.sh/v1` + `eks.amazonaws.com/v1` | EKS Auto Mode native |

---

## Update History (April 2026)

| Component | Previous | Updated To | File |
|---|---|---|---|
| EKS Blueprints Addons | 1.21.0 | 1.23.0 | `static/terraform/main.tf` |
| EKS Data Addons | 1.37.2 | 1.38.0 | `static/terraform/main.tf` |
| Neuron Helm Chart | 1.2.0 | 1.5.0 | `static/scripts/quick-deploy-sponsored.sh` |
| Trident Operator | 100.2502.1 | 100.2602.0 | `static/scripts/quick-deploy-sponsored.sh` |
| Neuron Scheduler | 2.28.4.0 | 2.29.148.0 | `static/terraform/helm-values/neuron-values.yaml` |
| kube-scheduler (EKS Distro) | v1.33.4-eks-1-33-13 | v1.35.2-eks-1-35-8 | `static/terraform/helm-values/neuron-values.yaml` |
| Neuron Monitor | 1.3.0 | 1.9.0 | `static/eks/genai/observability/neuron-monitor.yaml` |
| EKS Cluster Version | 1.33 | 1.35 | `static/GenAIFSXWorkshopOnEKS.yaml` (EKSClusterVersion param) |
| kubectl Version | 1.33.0 | 1.35.0 | `static/GenAIFSXWorkshopOnEKS.yaml` (KubectlVersion param) |
| vLLM Neuron Image | 0.16.0-sdk2.29.0 | 0.9.1-sdk2.26.1 | `static/eks/genai/mistral-ontap.yaml` (SDK 2.26.1 for inf2.xlarge) |
| Trident (workshop instructions) | 100.2502.1 | 100.2602.0 | `content/100_module1_eks_fsxl/110_DeployAmazonFSxLustreCSIDriverToEKS.md` |

---

## Not Updated (requires migration planning)

| Component | Current | Latest | Reason |
|---|---|---|---|
| **AWS Provider** | 5.99.1 | 6.9.0 | Major version — breaking changes, must coordinate with EKS/VPC modules |
| **VPC Module** | 5.21.0 | 6.6.1 | Major version — interdependent with AWS Provider v6 |

---

## Files Containing Version References

| File | What's versioned |
|---|---|
| `static/GenAIFSXWorkshopOnEKS.yaml` | EKS cluster version, kubectl version (CFN parameters) |
| `static/terraform/main.tf` | Terraform providers, EKS/VPC/Blueprints module versions |
| `static/terraform/helm-values/neuron-values.yaml` | Neuron scheduler image, kube-scheduler image |
| `static/eks/genai/mistral-ontap.yaml` | vLLM Neuron container image |
| `static/eks/genai/observability/neuron-monitor.yaml` | Neuron monitor container image |
| `static/eks/genai/open-webui-helm/values.yaml` | Open WebUI container image, helm chart config |
| `static/eks/FSxONTAP/model-loading-job.yaml` | HuggingFace CLI image |
| `static/scripts/quick-deploy-sponsored.sh` | Neuron Helm chart version, Trident operator version |

---

## Version Check Commands

```bash
# Terraform modules
curl -s "https://registry.terraform.io/v1/modules/terraform-aws-modules/eks/aws" | jq '.version'
curl -s "https://registry.terraform.io/v1/modules/terraform-aws-modules/vpc/aws" | jq '.version'
curl -s "https://registry.terraform.io/v1/modules/aws-ia/eks-blueprints-addons/aws" | jq '.version'
curl -s "https://registry.terraform.io/v1/modules/aws-ia/eks-data-addons/aws" | jq '.version'

# Neuron container images (ECR Public)
aws ecr-public describe-image-tags --repository-name neuron/neuron-helm-chart --region us-east-1 --query 'imageTagDetails[*].imageTag' --output table
aws ecr-public describe-image-tags --repository-name neuron/neuron-monitor --region us-east-1 --query 'imageTagDetails[*].imageTag' --output table
aws ecr-public describe-image-tags --repository-name neuron/neuron-scheduler --region us-east-1 --query 'imageTagDetails[*].imageTag' --output table
aws ecr-public describe-image-tags --repository-name neuron/pytorch-inference-vllm-neuronx --region us-east-1 --query 'imageTagDetails[*].imageTag' --output table

# Trident Operator Helm chart
helm search repo netapp-trident/trident-operator --versions | head -5
```
