# Implementation Plan: FSx for ONTAP Migration

## Overview

This plan migrates the GenAI FSx Workshop on EKS from FSx for Lustre to FSx for NetApp ONTAP. Tasks are ordered so each step builds on the previous: new Kubernetes manifests first, then the updated vLLM deployment, then infrastructure (Terraform/CloudFormation), then scripts, then workshop content, and finally removal of obsolete files. All code uses YAML, Bash, HCL (Terraform), and Hugo Markdown — the same languages already in the project.

## Tasks

- [x] 1. Create FSx for ONTAP Kubernetes manifest files
  - [x] 1.1 Create the Trident backend Secret manifest (`static/eks/FSxONTAP/fsx-ontap-secret.yaml`)
    - Define a Kubernetes Secret in the `trident` namespace with `vsadmin` username and `SVM_PASSWORD` placeholder
    - Use `type: Opaque` with `stringData` fields for username and password
    - _Requirements: 2.1, 1.5_

  - [x] 1.2 Create the TridentBackendConfig manifest (`static/eks/FSxONTAP/trident-backend-config.yaml`)
    - Define a `TridentBackendConfig` resource in the `trident` namespace named `backend-ontap-nas`
    - Use `ontap-nas` storage driver with `SVM_MGMT_LIF` and `SVM_NAME` placeholders
    - Reference the `fsx-ontap-secret` credentials Secret
    - _Requirements: 2.1, 1.5_

  - [x] 1.3 Create the StorageClass manifest (`static/eks/FSxONTAP/ontap-storage-class.yaml`)
    - Define a StorageClass named `ontap-nas-sc` with provisioner `csi.trident.netapp.io`
    - Set `backendType: ontap-nas`, `provisioningType: thin`, `snapshots: true`
    - Enable volume expansion and set NFS 4.1 mount options
    - _Requirements: 2.2_

  - [x] 1.4 Create the PersistentVolumeClaim manifest (`static/eks/FSxONTAP/ontap-pvc.yaml`)
    - Define a PVC named `ontap-model-claim` with `ReadWriteMany` access mode
    - Reference `ontap-nas-sc` StorageClass and request 100Gi storage
    - _Requirements: 2.3, 2.4, 2.5_

  - [x] 1.5 Create the Model Loading Job manifest (`static/eks/FSxONTAP/model-loading-job.yaml`)
    - Define a Kubernetes Job named `model-download` using `public.ecr.aws/parikshit/huggingface-cli:slim` image
    - Download `mistralai/Mistral-7B-Instruct-v0.3` to `/work-dir/Mistral-7B-Instruct-v0.3`
    - Mount the `ontap-model-claim` PVC, set `restartPolicy: OnFailure` and `backoffLimit: 3`
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.6_

- [x] 2. Create updated vLLM deployment manifest for FSx ONTAP
  - [x] 2.1 Create `static/eks/genai/mistral-ontap.yaml`
    - Copy structure from existing `mistral-fsxl.yaml` and `vllm-mistral-7b-v03.yaml`
    - Update PVC reference from `fsx-lustre-claim` to `ontap-model-claim`
    - Update model path to `/work-dir/Mistral-7B-Instruct-v0.3/`
    - Use container image `public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.9.1-neuronx-py310-sdk2.25.0-ubuntu22.04`
    - Use `FSX_ONTAP_AZ` placeholder for AZ affinity
    - Add `/dev/shm` emptyDir volume for compilation
    - Update `served-model-name` to `mistralai/Mistral-7B-Instruct-v0.3`
    - Add `VLLM_NEURON_FRAMEWORK` env var set to `neuronx-distributed-inference`
    - Retain Neuron scheduler, Inferentia tolerations, health probes, resource requests, Service, and Prometheus annotations
    - _Requirements: 4.1, 4.2, 4.3, 4.4_

- [x] 3. Checkpoint - Verify all new Kubernetes manifests
  - Validate all new YAML manifests are syntactically correct
  - Verify PVC name `ontap-model-claim` is consistent across TridentBackendConfig, PVC, Job, and Deployment
  - Verify `/work-dir` mount path is consistent across Job and Deployment
  - Ensure all tests pass, ask the user if questions arise.

- [x] 4. Update Terraform configuration for FSx ONTAP provisioning
  - [x] 4.1 Create Terraform resources for FSx ONTAP (`terraform/` directory)
    - Add `aws_fsx_ontap_file_system` resource: Single-AZ deployment, 1024 GiB SSD, 256 MBps throughput
    - Add `aws_fsx_ontap_storage_virtual_machine` resource with NFS enabled
    - Add `aws_fsx_ontap_volume` resource: 100 GiB, junction path `/model`, tiering policy `AUTO`
    - Add security group rule allowing TCP 2049 (NFS) from EKS worker node security group
    - Add AWS Secrets Manager secret for SVM vsadmin credentials
    - Add Terraform outputs: `fsx_ontap_id`, `svm_management_lif`, `svm_name`, `svm_nfs_lif`, `ontap_volume_junction_path`, `fsx_ontap_az`
    - Remove FSx for Lustre file system resource, S3 data repository association, S3 buckets (model staging and 2nd region), and S3 replication configuration
    - _Requirements: 5.1, 5.2, 5.3, 5.5_

  - [x] 4.2 Validate Terraform configuration
    - Run `terraform validate` to confirm the updated configuration is syntactically correct
    - _Requirements: 5.1_

- [x] 5. Update CloudFormation template for FSx ONTAP
  - [x] 5.1 Update `static/GenAIFSXWorkshopOnEKS.yaml`
    - Remove FSx for Lustre file system creation resources and S3 bucket linking
    - Add FSx for ONTAP file system, SVM, and volume resources
    - Update security group rules: replace Lustre ports (TCP 988, 1021-1023) with NFS port (TCP 2049)
    - Update IAM policies for ONTAP API permissions (fsx:DescribeFileSystems, fsx:DescribeVolumes, fsx:DescribeStorageVirtualMachines, fsx:CreateVolume, etc.)
    - Add outputs for SVM management LIF and volume details
    - _Requirements: 5.4_

  - [x] 5.2 Validate CloudFormation template
    - Verify the template is valid YAML and follows CloudFormation syntax
    - _Requirements: 5.4_

- [x] 6. Checkpoint - Verify infrastructure changes
  - Ensure Terraform and CloudFormation changes are consistent with each other
  - Verify security group rules, IAM policies, and resource outputs align between Terraform and CloudFormation
  - Ensure all tests pass, ask the user if questions arise.

- [x] 7. Update install and cleanup scripts
  - [x] 7.1 Update `static/download/install.sh` for FSx ONTAP
    - Replace FSx for Lustre CSI IAM policy with Trident CSI IAM policy (ONTAP permissions)
    - Replace `helm install aws-fsx-csi-driver` with `helm install trident-operator` from `netapp-trident/trident-helm-chart` (version `100.2502.1`)
    - Replace FSx Lustre discovery commands (`aws fsx describe-file-systems` with `LustreConfiguration` queries) with ONTAP discovery (`aws fsx describe-storage-virtual-machines`, `aws fsx describe-volumes`)
    - Replace `sed` commands for Lustre PV template with `sed` commands for TridentBackendConfig template (SVM management LIF, SVM name, SVM password)
    - Add commands to apply TridentBackendConfig, StorageClass, Secret, PVC, and Model Loading Job
    - Add wait logic for Model Loading Job completion before deploying vLLM
    - Add FSx ONTAP availability check (exit with non-zero status if not AVAILABLE)
    - Replace `mistral-fsxl.yaml` references with `mistral-ontap.yaml`
    - Update AZ discovery from FSx Lustre to FSx ONTAP (`FSX_ONTAP_AZ` placeholder)
    - Remove sysprep and check resource deployment steps
    - _Requirements: 10.1, 10.2, 10.3, 10.6_

  - [x] 7.2 Update `static/download/cleanup.sh` for FSx ONTAP
    - Replace `helm uninstall aws-fsx-csi-driver` with `helm uninstall trident-operator -n trident`
    - Replace `kubectl delete -f mistral-fsxl.yaml` with `kubectl delete -f mistral-ontap.yaml`
    - Replace Lustre PV/PVC cleanup (`fsx-lustre-claim`, `fsx-pv`) with ONTAP PVC cleanup (`ontap-model-claim`)
    - Add deletion of TridentBackendConfig, StorageClass, and Secret resources
    - Remove sysprep and check resource cleanup commands (`fsx-lustre-claim-check`, `fsx-pv-check`, `fsx-lustre-claim-sysprep`, `fsx-pv-sysprep`)
    - Ensure ordered teardown: deployments/jobs first, then PVCs, then StorageClass, then TridentBackendConfig, then Secret, then Helm uninstall
    - _Requirements: 10.4, 10.5_

- [x] 8. Update workshop content - Introduction page
  - [x] 8.1 Update `content/010_introduction/index.en.md`
    - Replace all references to FSx for Lustre with FSx for NetApp ONTAP
    - Replace the "What is Amazon FSx for Lustre" section with a "What is Amazon FSx for NetApp ONTAP" section covering: file systems, SVMs, volumes, NFS access, snapshots, and data tiering
    - Add a "What is NetApp Astra Trident" section describing the Trident CSI driver
    - Update the "Storing and accessing your model and training data" section to describe the explicit model loading approach (Kubernetes Job) instead of transparent S3 import
    - Update the architecture diagram description to reference FSx for ONTAP instead of FSx for Lustre and S3
    - Update the workshop objective list to reference FSx for ONTAP
    - _Requirements: 9.1, 9.2_

- [x] 9. Update workshop content - Module 1 (Storage Configuration)
  - [x] 9.1 Update `content/100_module1_eks_fsxl/index.en.md`
    - Update module title from "Configure storage for model hosting using Amazon FSx for Lustre" to reference FSx for ONTAP
    - Replace module overview to describe FSx for ONTAP, Trident CSI driver, TridentBackendConfig, StorageClass, and dynamic provisioning
    - Update the "Additional reading" section: replace Lustre CSI driver description with Trident CSI driver description
    - Update storage concepts to cover Trident-based dynamic provisioning instead of Lustre static provisioning
    - _Requirements: 6.1, 6.2_

  - [x] 9.2 Update `content/100_module1_eks_fsxl/110_DeployAmazonFSxLustreCSIDriverToEKS.md`
    - Rename/update title from "Deploy CSI Driver for Amazon FSx for Lustre" to "Deploy Trident CSI Driver for Amazon FSx for NetApp ONTAP"
    - Replace the overview to describe FSx for ONTAP and Trident CSI driver
    - Replace the IAM policy creation steps: remove S3 and Lustre permissions, add ONTAP permissions (fsx:DescribeFileSystems, fsx:DescribeVolumes, fsx:DescribeStorageVirtualMachines, etc.) and Secrets Manager permissions
    - Replace the service account creation steps for Trident instead of Lustre CSI
    - Replace the Helm install commands: remove `aws-fsx-csi-driver` chart, add `netapp-trident/trident-operator` chart (version `100.2502.1`) with `--namespace trident --create-namespace`
    - Update verification commands to check Trident pods in `trident` namespace
    - Add step for creating the TridentBackendConfig resource that references the pre-provisioned FSx ONTAP file system and SVM
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 6.3_

  - [x] 9.3 Update `content/100_module1_eks_fsxl/120_StaticProvisioning.md`
    - Replace title from "Create Persistent Volume on EKS Cluster" to reflect dynamic provisioning with Trident
    - Replace the overview to explain Trident-based dynamic provisioning instead of static PV creation
    - Remove manual PV creation steps (FSx Lustre volume handle, DNS name, mount name)
    - Add steps for applying the StorageClass manifest and PVC manifest
    - Add verification steps: check StorageClass exists, PVC is Bound, Trident backend is registered
    - Update the summary to reflect dynamic provisioning
    - _Requirements: 6.3, 6.4, 6.5_

  - [x] 9.4 Update `content/100_module1_eks_fsxl/123_ViewFSxConsole.md`
    - Replace all FSx for Lustre console references with FSx for ONTAP console
    - Update instructions to navigate to FSx ONTAP file system details (file system, SVM, volumes)
    - Introduce FSx for ONTAP concepts: file systems, SVMs, volumes, NFS access, snapshots, data tiering
    - Update performance dashboard references for ONTAP metrics
    - _Requirements: 6.1, 6.2_

- [x] 10. Checkpoint - Verify Module 1 content updates
  - Ensure no residual FSx for Lustre references remain in Module 1 content
  - Verify all kubectl commands reference correct resource names (ontap-nas-sc, ontap-model-claim, backend-ontap-nas)
  - Ensure all tests pass, ask the user if questions arise.

- [x] 11. Update workshop content - Module 2 (GenAI Deployment)
  - [x] 11.1 Update `content/200_module2_genai/index.en.md`
    - Replace FSx for Lustre references with FSx for ONTAP in the module overview
    - Update the architecture description to mention Trident CSI and ONTAP-backed storage
    - _Requirements: 7.1_

  - [x] 11.2 Update `content/200_module2_genai/210_Deploy.md`
    - Add a new step before vLLM deployment for running the Model Loading Job
    - Include instructions to apply `model-loading-job.yaml` and wait for completion (`kubectl wait --for=condition=complete job/model-download`)
    - Include verification step to confirm model data is present on the PVC
    - Explain that FSx for ONTAP does not transparently import data from S3 and the model must be explicitly loaded
    - Replace `mistral-fsxl.yaml` references with `mistral-ontap.yaml`
    - Update AZ discovery commands from FSx Lustre to FSx ONTAP
    - Update `sed` command to use `FSX_ONTAP_AZ` placeholder
    - Update the inline YAML example to show the new `mistral-ontap.yaml` structure
    - Update PVC reference in explanatory notes from `fsx-lustre-claim` to `ontap-model-claim`
    - Retain all existing Neuron helm chart, Inferentia NodePool, and Open WebUI deployment instructions
    - _Requirements: 7.1, 7.2, 7.3, 7.4_

  - [x] 11.3 Update `content/200_module2_genai/220_webui.md`
    - Replace "FSx Lustre" references with "FSx for ONTAP" in the summary text
    - Update the final summary paragraph to reference ONTAP-backed persistent volume
    - _Requirements: 7.1_

- [x] 12. Update workshop content - Module 4 (Data Inspection)
  - [x] 12.1 Update `content/400_module4_inspect_data/index.en.md`
    - Replace FSx for Lustre references with FSx for ONTAP
    - Update module overview to describe ONTAP data management features (snapshots) instead of S3 export/replication
    - Remove bullet points about S3 data export and S3 cross-region replication
    - Add bullet points about ONTAP volume snapshots
    - _Requirements: 8.1_

  - [x] 12.2 Replace `content/400_module4_inspect_data/410_S3Replications.md` with ONTAP snapshot exercise
    - Replace the entire S3 replication exercise with an FSx for ONTAP volume snapshot exercise
    - Include steps for creating a volume snapshot using the FSx ONTAP console or AWS CLI
    - Include steps for viewing and restoring from a snapshot
    - Demonstrate at least one ONTAP-specific feature: volume snapshots
    - _Requirements: 8.1, 8.2_

  - [x] 12.3 Update `content/400_module4_inspect_data/411_InspectModelandNeuron.md`
    - Update model directory path references from `Mistral-7B-Instruct-v0.2` to `Mistral-7B-Instruct-v0.3`
    - Replace the FSx for Lustre S3 import explanation note with an FSx for ONTAP explanation (model loaded via Kubernetes Job, served via NFS)
    - Update working directory references from `eks/FSxL` to `eks/FSxONTAP`
    - Retain all Neuron tools instructions (neuron-ls, neuron-top) unchanged
    - _Requirements: 8.3, 8.4_

- [x] 13. Update workshop content - Setup pages
  - [x] 13.1 Update `content/020_setup/021_on_demand/index.en.md`
    - Update the IAM policy example to include FSx for ONTAP permissions instead of FSx for Lustre and S3 permissions
    - Update deployment script references to reflect ONTAP-based provisioning
    - _Requirements: 9.3, 9.4_

  - [x] 13.2 Update `content/020_setup/022_aws_event/index.en.md`
    - Update any references to FSx for Lustre with FSx for ONTAP if present
    - _Requirements: 9.3_

- [ ] 14. Remove obsolete FSx for Lustre files
  - [-] 14.1 Remove obsolete manifest and script files
    - Delete `static/download/sysprep.yaml` (Lustre HSM restore pre-warming job — no longer needed)
    - Delete `static/download/sysprep.sh` if it exists (Lustre sysprep script)
    - Delete `static/download/check.yaml` (Lustre data verification deployment — no longer needed)
    - Delete `static/eks/FSxL/fsxL-persistent-volume.yaml` (static Lustre PV — replaced by Trident dynamic provisioning)
    - Delete `static/eks/FSxL/fsxL-claim.yaml` (Lustre PVC — replaced by `ontap-pvc.yaml`)
    - Delete `static/eks/FSxL/fsxL-storage-class.yaml` (Lustre StorageClass — replaced by `ontap-storage-class.yaml`)
    - Delete `static/eks/FSxL/fsxL-dynamic-claim.yaml` (Lustre dynamic PVC — no longer needed)
    - Delete `static/eks/FSxL/pod.yaml` and `static/eks/FSxL/pod_performance.yaml` if they are Lustre-specific test pods
    - _Requirements: 6.5, 11.1_

- [~] 15. Final checkpoint - Full validation
  - Verify no residual FSx for Lustre references remain across all updated files (search for "Lustre", "fsx-lustre", "fsxL", "fsx-pv")
  - Verify PVC name consistency (`ontap-model-claim`) across all manifests, scripts, and content
  - Verify model path consistency (`/work-dir/Mistral-7B-Instruct-v0.3/`) across Job, Deployment, and content
  - Verify mount path consistency (`/work-dir`) across all resources
  - Confirm Module 3 (Observability) is untouched
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property-based testing does not apply to this feature (IaC, YAML manifests, shell scripts, markdown content)
- Module 3 (Observability) requires no changes and is not included in this plan
- The `static/eks/FSxL/` directory can be fully removed after task 14 if all files are Lustre-specific
