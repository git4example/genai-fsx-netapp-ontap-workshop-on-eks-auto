terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.99.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.37.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.17.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

provider "aws" {
  region = local.region
  alias  = "region1"
}

# Region 2 provider removed — no longer needed without S3 cross-region replication

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

locals {
  name   = "eksworkshop"
  region = "--AWS_REGION--"
  # region = "us-west-1"

  cluster_version = "--EKS_VERSION--"
  # cluster_version = "1.35"

  vpc_cidr = "10.0.0.0/16"

  # Map of unsupported AZ IDs for EKS per region
  unsupported_az_ids = {
    "us-east-1"    = ["use1-az3"]
    "us-west-1"    = ["usw1-az2"]
    "ca-central-1" = ["cac1-az3"]
  }

  # Get current region's unsupported AZ IDs
  region_unsupported_az_ids = lookup(local.unsupported_az_ids, data.aws_region.current.name, [])

  azs      = data.aws_availability_zones.available.names
  az_count = length(local.azs) # Get number of AZs in the region

  tags = {
    Blueprint   = local.name
    auto-delete = "no"
  }

  # Following is to check if WSParticipantRole role is present or not, to handle on-demand workshop in private accounts

  # Base access entries - this will always be created
  base_access_entries = {}

  # Define the role ARN
  ws_participant_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/WSParticipantRole"

  # Check if role exists first
  has_ws_participant_role = try(
    contains(data.aws_iam_roles.all.names, "WSParticipantRole"),
    false
  )

  # Use the check result to conditionally create access entry
  ws_participant_access = local.has_ws_participant_role ? {
    super-admin = {
      principal_arn = local.ws_participant_role_arn
      policy_associations = {
        this = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  } : {}

  # Merge access entries
  access_entries = merge(local.base_access_entries, local.ws_participant_access)
}

# Add this data source to get all IAM roles
data "aws_iam_roles" "all" {
  path_prefix = "/"
}


data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

data "aws_availability_zones" "available" {
  provider = aws.region1
  state    = "available"
  # This line tells Terraform to ignore these specific AZ IDs.
  exclude_zone_ids = local.region_unsupported_az_ids
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

################################################################################
# EKS Cluster
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.1"

  providers = {
    aws = aws.region1
  }

  cluster_name                             = local.name
  cluster_version                          = local.cluster_version
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API"
  cluster_enabled_log_types                = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  access_entries = local.access_entries

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  create_cloudwatch_log_group   = false
  create_cluster_security_group = true
  create_node_security_group    = false
  enable_irsa                   = true

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })

  depends_on = [
    module.vpc
  ]

}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.23.0"

  providers = {
    aws = aws.region1
  }

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # create_delay_dependencies = [for prof in module.eks.eks_managed_node_groups : prof.node_group_arn]

  #---------------------------------------
  # metrics server for EKS Cluster
  #---------------------------------------
  enable_metrics_server = true


  #---------------------------------------
  # Karpenter Autoscaler for EKS Cluster
  #---------------------------------------
  # enable_karpenter = true
  # karpenter_enable_spot_termination          = true
  # karpenter_enable_instance_profile_creation = true
  # karpenter = {
  #   chart_version       = "1.0.1"     # https://gallery.ecr.aws/karpenter/karpenter
  #   repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  #   repository_password = data.aws_ecrpublic_authorization_token.token.password
  # }

  # karpenter_node = {
  #   iam_role_use_name_prefix = false
  #   iam_role_additional_policies = {
  #     AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  #   }
  # }

  #---------------------------------------
  # AWS Load Balancer Controller Add-on
  #---------------------------------------
  # enable_aws_load_balancer_controller = true
  # turn off the mutating webhook for services because if you are using
  # service.beta.kubernetes.io/aws-load-balancer-type: external
  # aws_load_balancer_controller = {
  #   set = [{
  #     name  = "enableServiceMutatorWebhook"
  #     value = "false"
  #   }]
  # }

  #---------------------------------------
  # Prommetheus and Grafana stack
  #---------------------------------------
  #---------------------------------------------------------------
  # 1- Grafana port-forward `kubectl port-forward svc/kube-prometheus-stack-grafana 8080:80 -n kube-prometheus-stack`
  # 2- Grafana Admin user: admin
  # 3- Get sexret name from Terrafrom output: `terraform output grafana_secret_name`
  # 3- Get admin user password: `aws secretsmanager get-secret-value --secret-id <REPLACE_WIRTH_SECRET_ID> --region $AWS_REGION --query "SecretString" --output text`
  #---------------------------------------------------------------
  # enable_kube_prometheus_stack = true
  # kube_prometheus_stack = {
  #   values = [
  #     templatefile("${path.module}/helm-values/kube-prometheus.yaml", {
  #       storage_class_type = kubernetes_storage_class.default_gp3.id
  #     })
  #   ]
  #   chart_version = "75.13.0"
  #   set_sensitive = [
  #     {
  #       name  = "grafana.adminPassword"
  #       value = data.aws_secretsmanager_secret_version.admin_password_version.secret_string
  #     }
  #   ],
  # }

  tags = local.tags
  depends_on = [
    module.eks
  ]
}

#---------------------------------------------------------------
# Grafana Admin credentials resources
# Login to AWS secrets manager with the same role as Terraform to extract the Grafana admin password with the secret name as "grafana"
#---------------------------------------------------------------
data "aws_secretsmanager_secret_version" "admin_password_version" {
  secret_id  = aws_secretsmanager_secret.grafana.id
  depends_on = [aws_secretsmanager_secret_version.grafana]
}

resource "random_password" "grafana" {
  length           = 16
  special          = true
  override_special = "@_"
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "grafana" {
  name_prefix             = "${local.name}-oss-grafana"
  recovery_window_in_days = 0 # Set to zero for this example to force delete during Terraform destroy
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = random_password.grafana.result
}

#---------------------------------------------------------------
# Data on EKS Kubernetes Addons
#---------------------------------------------------------------
module "data_addons" {
  source  = "aws-ia/eks-data-addons/aws"
  version = "1.38.0" # ensure to update this to the latest/desired version

  oidc_provider_arn = module.eks.oidc_provider_arn

  #---------------------------------------------------------------
  # Neuron and NVIDIA Device Plugin Add-on
  #---------------------------------------------------------------
  # enable_aws_neuron_device_plugin  = true
  # aws_neuron_device_plugin_helm_config = {
  #   # version =  "1.1.1"
  #   create_namespace=true
  #   values  = [file("${path.module}/helm-values/neuron-values.yaml")]
  # }

  # enable_nvidia_device_plugin = true
  # nvidia_device_plugin_helm_config = {
  #   # version =  "0.17.0"
  #   name    = "nvidia-device-plugin"
  #   values  = [file("${path.module}/helm-values/nvidia-values.yaml")]
  # }
  depends_on = [
    module.eks
  ]
}

#---------------------------------------------------------------
# GP3 Encrypted Storage Class
#---------------------------------------------------------------
resource "kubernetes_annotations" "disable_gp2" {
  annotations = {
    "storageclass.kubernetes.io/is-default-class" : "false"
  }
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  force = true

  depends_on = [module.eks]
}

resource "kubernetes_storage_class" "default_gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    fsType    = "ext4"
    encrypted = true
    type      = "gp3"
  }

  depends_on = [kubernetes_annotations.disable_gp2]
}

################################################################################
# Network Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  providers = {
    aws = aws.region1
  }

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for i in range(local.az_count) : cidrsubnet(local.vpc_cidr, 4, i)]
  private_subnets = [for i in range(local.az_count) : cidrsubnet(local.vpc_cidr, 4, i + local.az_count)]


  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = 1
    "karpenter.sh/discovery"              = local.name
  }

  tags = local.tags
}


################################################################################
# Random string for unique naming
################################################################################
resource "random_string" "random" {
  length  = 12
  special = false
  upper   = false
  numeric = true
}

################################################################################
# Security Group for FSx ONTAP
################################################################################

resource "aws_security_group" "fsx_ontap_sg" {
  name        = "FSxONTAPSecurityGroup"
  provider    = aws.region1
  description = "Security Group for FSx for ONTAP NFS Access"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Allow NFS traffic from EKS worker nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.cluster_security_group_id]
  }

  ingress {
    description = "Allow NFS traffic from VPC CIDR"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  ingress {
    description = "Allow ONTAP management API (HTTPS) from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

################################################################################
# FSx for ONTAP File System
################################################################################

resource "random_password" "svm_password" {
  length           = 16
  special          = true
  override_special = "@_"
}

resource "aws_secretsmanager_secret" "fsx_ontap_svm_password" {
  name_prefix             = "trident-fsx-ontap-svm-"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "fsx_ontap_svm_password" {
  secret_id     = aws_secretsmanager_secret.fsx_ontap_svm_password.id
  secret_string = random_password.svm_password.result
}

resource "aws_fsx_ontap_file_system" "fsx_ontap" {
  provider             = aws.region1
  storage_capacity     = 1024
  subnet_ids           = [module.vpc.private_subnets[0]]
  deployment_type      = "SINGLE_AZ_1"
  throughput_capacity  = 256
  security_group_ids   = [aws_security_group.fsx_ontap_sg.id]
  preferred_subnet_id  = module.vpc.private_subnets[0]

  tags = merge(local.tags, {
    Name = "${local.name}-fsx-ontap"
  })

  depends_on = [
    module.vpc,
    aws_security_group.fsx_ontap_sg
  ]
}

resource "aws_fsx_ontap_storage_virtual_machine" "fsx_ontap_svm" {
  file_system_id             = aws_fsx_ontap_file_system.fsx_ontap.id
  name                       = "${local.name}-svm"
  svm_admin_password         = random_password.svm_password.result

  tags = merge(local.tags, {
    Name = "${local.name}-svm"
  })

  depends_on = [
    aws_fsx_ontap_file_system.fsx_ontap
  ]
}

resource "aws_fsx_ontap_volume" "fsx_ontap_volume" {
  name                       = "model"
  junction_path              = "/model"
  size_in_megabytes          = 102400 # 100 GiB
  storage_virtual_machine_id = aws_fsx_ontap_storage_virtual_machine.fsx_ontap_svm.id
  storage_efficiency_enabled = true

  tiering_policy {
    name = "AUTO"
  }

  tags = merge(local.tags, {
    Name = "${local.name}-ontap-volume"
  })

  depends_on = [
    aws_fsx_ontap_storage_virtual_machine.fsx_ontap_svm
  ]
}


################################################################################
# Kubernetes Manifests
################################################################################

resource "kubectl_manifest" "neuron-healthcheck-system-namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: neuron-healthcheck-system
    YAML
  depends_on = [
    module.eks
  ]
}


################################################################################
# Data source for FSx ONTAP subnet AZ lookup
################################################################################

data "aws_subnet" "fsx_ontap_subnet" {
  id = module.vpc.private_subnets[0]
}

#---------------------------------------------------------------
# Outputs
#---------------------------------------------------------------

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "eks_node_iam_role_name" {
  description = "IAM role name for EKS nodes"
  value       = module.eks.node_iam_role_name
}

output "fsx_ontap_id" {
  description = "FSx for ONTAP file system ID"
  value       = aws_fsx_ontap_file_system.fsx_ontap.id
}

output "svm_management_lif" {
  description = "SVM management LIF DNS name"
  value       = aws_fsx_ontap_storage_virtual_machine.fsx_ontap_svm.endpoints[0].management[0].dns_name
}

output "svm_name" {
  description = "SVM name"
  value       = aws_fsx_ontap_storage_virtual_machine.fsx_ontap_svm.name
}

output "svm_nfs_lif" {
  description = "NFS data LIF IP address"
  value       = aws_fsx_ontap_storage_virtual_machine.fsx_ontap_svm.endpoints[0].nfs[0].ip_addresses
}

output "ontap_volume_junction_path" {
  description = "ONTAP volume junction path"
  value       = aws_fsx_ontap_volume.fsx_ontap_volume.junction_path
}

output "fsx_ontap_az" {
  description = "Availability zone of the FSx ONTAP file system"
  value       = data.aws_subnet.fsx_ontap_subnet.availability_zone
}
