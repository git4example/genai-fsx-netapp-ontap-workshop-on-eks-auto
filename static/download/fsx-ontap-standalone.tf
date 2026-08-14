################################################################################
# Standalone FSx for ONTAP — for local testing against an existing EKS cluster
#
# This provisions ONLY the FSx ONTAP resources (file system, SVM, volume,
# security group, secret) needed to test the vLLM + Trident workflow.
#
# Prerequisites:
#   - An existing EKS cluster with kubectl access
#   - Trident CSI driver installed in the cluster
#   - The EKS cluster's VPC ID and private subnet IDs
#
# Usage:
#   cd static/terraform
#   cp fsx-ontap-standalone.tf /tmp/fsx-ontap-test/main.tf
#   cd /tmp/fsx-ontap-test
#   terraform init
#   terraform apply -var="vpc_id=vpc-xxx" \
#                   -var='private_subnet_ids=["subnet-aaa","subnet-bbb"]' \
#                   -var="eks_cluster_sg_id=sg-xxx" \
#                   -var="region=us-west-2"
#
# To control which AZ the file system lands in, pass a specific subnet:
#   terraform apply ... -var="preferred_subnet_id=subnet-ccc"
#
# After apply, use the outputs to configure Trident:
#   1. Create the K8s secret with the SVM password from Secrets Manager
#   2. Update trident-backend-config.yaml with svm_management_lif and svm_name
#   3. Apply StorageClass, PVC, and model-loading Job
################################################################################

terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

################################################################################
# Variables
################################################################################

variable "region" {
  description = "AWS region where the EKS cluster and FSx ONTAP will be deployed"
  type        = string
  default     = "us-west-2"
}

variable "vpc_id" {
  description = "VPC ID of the existing EKS cluster"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs in the EKS VPC (at least 2 required for Multi-AZ). FSx ONTAP will span both subnets for high availability."
  type        = list(string)
}

variable "preferred_subnet_id" {
  description = "Specific subnet ID to deploy FSx ONTAP into (controls the AZ). If not set, defaults to the first subnet in private_subnet_ids."
  type        = string
  default     = ""
}

variable "eks_cluster_sg_id" {
  description = "Security group ID of the EKS cluster (cluster SG, not node SG). Used to allow NFS traffic from worker nodes."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the EKS VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "fsx-ontap-test"
}

variable "storage_capacity_gb" {
  description = "FSx ONTAP file system storage capacity in GiB"
  type        = number
  default     = 1024
}

variable "throughput_capacity" {
  description = "FSx ONTAP throughput capacity in MBps"
  type        = number
  default     = 256
}

variable "volume_size_mb" {
  description = "ONTAP volume size in MiB (100 GiB = 102400)"
  type        = number
  default     = 102400
}

################################################################################
# Provider
################################################################################

provider "aws" {
  region = var.region
}

################################################################################
# Locals
################################################################################

locals {
  fsx_subnet_id = var.preferred_subnet_id != "" ? var.preferred_subnet_id : var.private_subnet_ids[0]
}

################################################################################
# Data Sources
################################################################################

data "aws_subnet" "fsx" {
  id = local.fsx_subnet_id
}

################################################################################
# Security Group for FSx ONTAP
################################################################################

resource "aws_security_group" "fsx_ontap" {
  name        = "${var.name_prefix}-fsx-ontap-sg"
  description = "Security Group for FSx for ONTAP NFS access from EKS"
  vpc_id      = var.vpc_id

  # NFS from EKS cluster security group
  ingress {
    description     = "NFS from EKS cluster SG"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.eks_cluster_sg_id]
  }

  # NFS from VPC CIDR (covers pods using VPC CNI)
  ingress {
    description = "NFS from VPC CIDR"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # ONTAP management API (for Trident CSI driver)
  ingress {
    description = "ONTAP management API (HTTPS) from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-fsx-ontap-sg"
  }
}

################################################################################
# SVM Password (stored in Secrets Manager)
################################################################################

resource "random_password" "svm" {
  length           = 16
  special          = true
  override_special = "@_"
}

resource "aws_secretsmanager_secret" "svm_password" {
  name_prefix             = "trident-fsx-ontap-svm-"
  recovery_window_in_days = 0
  tags = {
    Name = "${var.name_prefix}-svm-password"
  }
}

resource "aws_secretsmanager_secret_version" "svm_password" {
  secret_id     = aws_secretsmanager_secret.svm_password.id
  secret_string = random_password.svm.result
}

################################################################################
# FSx for ONTAP File System
################################################################################

resource "aws_fsx_ontap_file_system" "this" {
  storage_capacity    = var.storage_capacity_gb
  subnet_ids          = [var.private_subnet_ids[0], var.private_subnet_ids[1]]
  deployment_type     = "MULTI_AZ_1"
  throughput_capacity = var.throughput_capacity
  security_group_ids  = [aws_security_group.fsx_ontap.id]
  preferred_subnet_id = local.fsx_subnet_id

  tags = {
    Name = "${var.name_prefix}-fsx-ontap"
  }
}

################################################################################
# Storage Virtual Machine (SVM)
################################################################################

resource "aws_fsx_ontap_storage_virtual_machine" "this" {
  file_system_id     = aws_fsx_ontap_file_system.this.id
  name               = "${var.name_prefix}-svm"
  svm_admin_password = random_password.svm.result

  tags = {
    Name = "${var.name_prefix}-svm"
  }
}

################################################################################
# ONTAP Volume (for model storage)
################################################################################

resource "aws_fsx_ontap_volume" "model" {
  name                       = "model"
  junction_path              = "/model"
  size_in_megabytes          = var.volume_size_mb
  storage_virtual_machine_id = aws_fsx_ontap_storage_virtual_machine.this.id
  storage_efficiency_enabled = true

  tiering_policy {
    name = "AUTO"
  }

  tags = {
    Name = "${var.name_prefix}-model-volume"
  }
}

################################################################################
# Outputs
################################################################################

output "fsx_ontap_id" {
  description = "FSx for ONTAP file system ID"
  value       = aws_fsx_ontap_file_system.this.id
}

output "fsx_ontap_az" {
  description = "Availability zone of the FSx ONTAP file system"
  value       = data.aws_subnet.fsx.availability_zone
}

output "svm_name" {
  description = "SVM name (use in TridentBackendConfig spec.svm)"
  value       = aws_fsx_ontap_storage_virtual_machine.this.name
}

output "svm_management_lif" {
  description = "SVM management LIF DNS name (use in TridentBackendConfig spec.managementLIF)"
  value       = aws_fsx_ontap_storage_virtual_machine.this.endpoints[0].management[0].dns_name
}

output "svm_nfs_lif_ips" {
  description = "NFS data LIF IP addresses"
  value       = aws_fsx_ontap_storage_virtual_machine.this.endpoints[0].nfs[0].ip_addresses
}

output "svm_password_secret_arn" {
  description = "Secrets Manager ARN for the SVM password (use to create K8s secret)"
  value       = aws_secretsmanager_secret.svm_password.arn
}

output "volume_junction_path" {
  description = "ONTAP volume junction path"
  value       = aws_fsx_ontap_volume.model.junction_path
}

output "security_group_id" {
  description = "Security group ID for FSx ONTAP"
  value       = aws_security_group.fsx_ontap.id
}

output "next_steps" {
  description = "Post-apply instructions"
  value       = <<-EOT

    ============================================================
    FSx ONTAP provisioned. Next steps:
    ============================================================

    1. Get the SVM password:
       aws secretsmanager get-secret-value \
         --secret-id ${aws_secretsmanager_secret.svm_password.arn} \
         --query SecretString --output text

    2. Create the K8s secret for Trident:
       kubectl create secret generic fsx-ontap-secret \
         -n trident \
         --from-literal=username=vsadmin \
         --from-literal=password=<PASSWORD_FROM_STEP_1>

    3. Update trident-backend-config.yaml:
       - managementLIF: ${aws_fsx_ontap_storage_virtual_machine.this.endpoints[0].management[0].dns_name}
       - svm: ${aws_fsx_ontap_storage_virtual_machine.this.name}

    4. Apply Trident backend, StorageClass, and PVC. The StorageClass lists your
       region's availability zones, so substitute them in rather than applying
       the manifest as-is:
       kubectl apply -f trident-backend-config.yaml
       export AZ_LIST_JSON=$(aws ec2 describe-availability-zones --region $AWS_REGION \
         --query "AvailabilityZones[?State=='available'].ZoneName" --output json | tr -d ' \n')
       envsubst '$AZ_LIST_JSON' < ontap-storage-class.yaml | kubectl apply -f -
       kubectl apply -f ontap-pvc.yaml

    5. Run the model loading Job, then deploy vLLM.
    ============================================================
  EOT
}
