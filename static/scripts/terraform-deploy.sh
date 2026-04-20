#!/bin/bash
terraform --version

# Create VPC
echo '=== Create VPC for EKS Cluster ==='
terraform apply -target="module.vpc" --auto-approve 

# Create EKS Cluster and FSx ONTAP File System (including SVM and Volume)
echo '=== Create EKS Cluster and FSx ONTAP File System ==='
terraform apply -target="aws_fsx_ontap_file_system.fsx_ontap" -target="aws_fsx_ontap_storage_virtual_machine.fsx_ontap_svm" -target="aws_fsx_ontap_volume.fsx_ontap_volume" -target="module.eks" --auto-approve

echo "Terraform Apply for rest of the resources ..."
terraform apply --auto-approve

echo "Deployment completed."
