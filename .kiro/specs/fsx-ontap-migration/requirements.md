# Requirements Document

## Introduction

This document specifies the requirements for migrating the GenAI FSx Workshop on EKS from Amazon FSx for Lustre to Amazon FSx for NetApp ONTAP. The current workshop uses FSx for Lustre with an S3-linked backend to store and serve the Mistral-7B-Instruct model for inference on EKS with AWS Inferentia accelerators. FSx for Lustre natively imports model data from S3 on first access, but FSx for NetApp ONTAP does not have this transparent S3 integration. This migration requires replacing the CSI driver, Kubernetes storage manifests, model loading strategy, CloudFormation/Terraform infrastructure, and all workshop content (Hugo markdown modules) to reflect the new storage backend.

## Glossary

- **FSx_for_ONTAP**: Amazon FSx for NetApp ONTAP — a fully managed shared storage service built on the NetApp ONTAP file system, providing NFS, SMB, and iSCSI access protocols with features such as snapshots, cloning, and data tiering.
- **Trident_CSI_Driver**: NetApp Astra Trident — an open-source CSI driver that provides dynamic and static storage provisioning for Kubernetes using NetApp storage backends including FSx for NetApp ONTAP.
- **FSx_for_Lustre**: Amazon FSx for Lustre — a high-performance parallel file system with native S3 data repository integration for transparent import/export of data.
- **Workshop_Content**: The Hugo-based markdown files under `content/` that form the instructional modules of the workshop site.
- **Kubernetes_Manifests**: The YAML files under `static/eks/` that define Kubernetes resources such as PersistentVolumes, PersistentVolumeClaims, StorageClasses, Deployments, and Jobs.
- **CloudFormation_Template**: The AWS CloudFormation YAML template (`GenAIFSXWorkshopOnEKS.yaml`) that provisions the workshop infrastructure including VPC, EKS cluster, and storage resources.
- **Terraform_Configuration**: The Terraform files (under `terraform/`) that provision VPC, EKS cluster, FSx file system, and related resources for the workshop.
- **Model_Loading_Job**: A Kubernetes Job that downloads the Mistral-7B model from a source (such as HuggingFace or S3) and writes it to the FSx for ONTAP persistent volume before the vLLM inference pod starts.
- **vLLM_Deployment**: The Kubernetes Deployment that runs the vLLM inference engine container, loading the Mistral-7B model from the persistent volume and serving an OpenAI-compatible API.
- **EKS_Cluster**: The Amazon Elastic Kubernetes Service cluster running in EKS Auto Mode with Inferentia node pools for accelerated inference.
- **SVM**: Storage Virtual Machine — a logical storage entity within an FSx for ONTAP file system that serves data to clients and contains one or more volumes.
- **ONTAP_Volume**: A logical data container within an SVM on FSx for ONTAP, mountable via NFS or iSCSI through the Trident CSI driver.

## Requirements

### Requirement 1: Replace FSx for Lustre CSI Driver with Trident CSI Driver

**User Story:** As a workshop participant, I want to deploy the NetApp Astra Trident CSI driver on the EKS cluster, so that I can provision and manage persistent volumes backed by FSx for NetApp ONTAP.

#### Acceptance Criteria

1. WHEN the workshop participant runs the Trident CSI driver installation commands, THE Trident_CSI_Driver SHALL be deployed to the EKS_Cluster in the `trident` namespace with all controller and node pods in a Running state.
2. THE Trident_CSI_Driver SHALL be installed using Helm with a pinned chart version that is compatible with the EKS_Cluster Kubernetes version (1.33).
3. WHEN the Trident_CSI_Driver is deployed, THE Trident_CSI_Driver SHALL register the `csi.trident.netapp.io` CSI driver with the Kubernetes API server.
4. THE Workshop_Content for Module 1 SHALL include step-by-step instructions for creating an IAM policy with permissions for FSx for ONTAP API operations (fsx:DescribeFileSystems, fsx:DescribeVolumes, fsx:DescribeStorageVirtualMachines, and related actions) instead of the current FSx for Lustre and S3 permissions.
5. THE Workshop_Content for Module 1 SHALL include instructions for creating a Trident backend configuration resource that references the pre-provisioned FSx_for_ONTAP file system and SVM.

### Requirement 2: Replace FSx for Lustre Kubernetes Storage Resources with FSx for ONTAP Resources

**User Story:** As a workshop participant, I want to create Kubernetes PersistentVolume and PersistentVolumeClaim resources backed by FSx for NetApp ONTAP, so that my vLLM inference pod can mount high-performance shared storage for model data.

#### Acceptance Criteria

1. THE Kubernetes_Manifests SHALL include a TridentBackendConfig resource that configures the Trident CSI driver to connect to the pre-provisioned FSx_for_ONTAP file system using the SVM management LIF endpoint and NFS protocol.
2. THE Kubernetes_Manifests SHALL include a StorageClass resource with the `csi.trident.netapp.io` provisioner that references the Trident backend configuration.
3. WHEN the workshop participant applies the PersistentVolumeClaim manifest, THE Trident_CSI_Driver SHALL provision a PersistentVolume backed by an ONTAP_Volume on the FSx_for_ONTAP file system.
4. THE PersistentVolumeClaim SHALL request ReadWriteMany access mode so that multiple pods can mount the volume concurrently.
5. THE PersistentVolume SHALL be mountable at the `/work-dir` path inside containers, matching the existing mount path convention used by the vLLM_Deployment.

### Requirement 3: Implement Model Loading Strategy for FSx for ONTAP

**User Story:** As a workshop participant, I want the Mistral-7B model data to be loaded onto the FSx for ONTAP volume before the vLLM pod starts, so that the inference engine can access the model without requiring native S3 integration.

#### Acceptance Criteria

1. THE Kubernetes_Manifests SHALL include a Model_Loading_Job definition that downloads the Mistral-7B-Instruct-v0.3 model data and writes it to the FSx_for_ONTAP-backed PersistentVolume.
2. WHEN the Model_Loading_Job runs, THE Model_Loading_Job SHALL download the model from a specified source (HuggingFace registry or a pre-staged S3 bucket using the AWS CLI) and store it under the `/work-dir/Mistral-7B-Instruct-v0.3/` directory on the persistent volume.
3. WHEN the Model_Loading_Job completes successfully, THE Model_Loading_Job SHALL have written all model weight files, tokenizer files, and configuration files to the persistent volume so that the total model data is present and complete.
4. THE Model_Loading_Job SHALL mount the same PersistentVolumeClaim used by the vLLM_Deployment so that model data is written to the shared volume.
5. THE Workshop_Content SHALL explain the difference between the FSx for Lustre transparent S3 import approach and the explicit model loading approach required for FSx for ONTAP.
6. IF the Model_Loading_Job fails due to network errors or insufficient storage, THEN THE Model_Loading_Job SHALL be configured with a `restartPolicy` of `OnFailure` so that Kubernetes retries the job automatically.

### Requirement 4: Update vLLM Deployment to Use FSx for ONTAP Storage

**User Story:** As a workshop participant, I want the vLLM inference deployment to reference the FSx for ONTAP-backed PersistentVolumeClaim, so that the inference engine loads the model from the ONTAP volume.

#### Acceptance Criteria

1. THE Kubernetes_Manifests SHALL include an updated vLLM_Deployment YAML file (`mistral-ontap.yaml`) that references a PersistentVolumeClaim backed by FSx_for_ONTAP instead of the `fsx-lustre-claim`.
2. THE vLLM_Deployment SHALL mount the FSx_for_ONTAP PersistentVolumeClaim at the `/work-dir` path and set the `MODEL_ID` environment variable to `/work-dir/Mistral-7B-Instruct-v0.3/`.
3. THE vLLM_Deployment SHALL retain the existing Neuron scheduler configuration, Inferentia tolerations, availability zone affinity, health probes, and resource requests for `aws.amazon.com/neuron`.
4. WHEN the vLLM_Deployment pod starts, THE vLLM_Deployment SHALL load the model from the FSx_for_ONTAP-backed persistent volume and expose the inference API on port 8000.

### Requirement 5: Update Infrastructure Provisioning for FSx for ONTAP

**User Story:** As a workshop operator, I want the infrastructure-as-code templates to provision an FSx for NetApp ONTAP file system instead of FSx for Lustre, so that the workshop environment is ready for participants.

#### Acceptance Criteria

1. THE Terraform_Configuration SHALL provision an FSx_for_ONTAP file system with a single-AZ deployment type, an SVM, and an ONTAP_Volume with sufficient capacity to store the Mistral-7B model (minimum 50 GiB usable).
2. THE Terraform_Configuration SHALL create the FSx_for_ONTAP file system in the same VPC and subnet as the EKS_Cluster, with a security group that allows NFS traffic (TCP port 2049) from the EKS worker node security group.
3. THE Terraform_Configuration SHALL output the SVM management LIF DNS name, the NFS LIF IP address, and the ONTAP_Volume junction path as Terraform outputs for use in Trident backend configuration.
4. THE CloudFormation_Template SHALL be updated to remove FSx for Lustre resource creation and S3 bucket linking, and replace them with FSx for ONTAP resource creation including the file system, SVM, and volume.
5. THE Terraform_Configuration SHALL remove the FSx for Lustre file system resource, the S3 data repository association, and the S3 bucket used for model staging.
6. THE Terraform_Configuration SHALL include a model loading mechanism (either a Kubernetes Job triggered via Terraform or a pre-provisioning step documented in the setup instructions) that populates the ONTAP_Volume with the Mistral-7B model data before participants begin the workshop.

### Requirement 6: Update Workshop Content for Module 1 (Storage Configuration)

**User Story:** As a workshop participant, I want Module 1 to teach me about FSx for NetApp ONTAP and the Trident CSI driver, so that I understand the storage architecture used in the workshop.

#### Acceptance Criteria

1. THE Workshop_Content for Module 1 SHALL replace all references to FSx for Lustre with FSx for NetApp ONTAP, including the module title, overview text, and architecture diagrams.
2. THE Workshop_Content for Module 1 SHALL include an introduction section explaining FSx for ONTAP concepts: file systems, SVMs, volumes, NFS access, snapshots, and data tiering.
3. THE Workshop_Content for Module 1 SHALL include step-by-step instructions for deploying the Trident CSI driver using Helm, creating the Trident backend configuration, creating the StorageClass, and creating the PersistentVolumeClaim.
4. THE Workshop_Content for Module 1 SHALL include instructions for verifying that the Trident CSI driver pods are running, the backend is registered, and the PVC is bound.
5. THE Workshop_Content for Module 1 SHALL replace the current static provisioning instructions (manual PV creation with FSx Lustre volume handle, DNS name, and mount name) with Trident-based dynamic provisioning instructions.

### Requirement 7: Update Workshop Content for Module 2 (GenAI Deployment)

**User Story:** As a workshop participant, I want Module 2 to guide me through deploying the vLLM inference pod using FSx for ONTAP storage, so that I can run the GenAI chatbot application.

#### Acceptance Criteria

1. THE Workshop_Content for Module 2 SHALL reference the updated `mistral-ontap.yaml` deployment file instead of `mistral-fsxl.yaml`.
2. THE Workshop_Content for Module 2 SHALL include a step for running the Model_Loading_Job and verifying that the model data is present on the persistent volume before deploying the vLLM pod.
3. THE Workshop_Content for Module 2 SHALL explain that FSx for ONTAP does not transparently import data from S3, and that the model must be explicitly loaded onto the volume.
4. THE Workshop_Content for Module 2 SHALL retain all existing instructions for Neuron helm chart installation, Inferentia NodePool creation, and Open WebUI deployment.

### Requirement 8: Update Workshop Content for Module 4 (Data Inspection and Replication)

**User Story:** As a workshop participant, I want Module 4 to demonstrate FSx for ONTAP data management features instead of FSx for Lustre S3 integration, so that I learn about ONTAP-specific capabilities.

#### Acceptance Criteria

1. THE Workshop_Content for Module 4 SHALL replace the FSx for Lustre S3 data export and S3 cross-region replication exercise with an FSx for ONTAP-relevant data management exercise.
2. THE Workshop_Content for Module 4 SHALL include an exercise demonstrating at least one of the following FSx for ONTAP features: volume snapshots, FlexClone volumes, or SnapMirror replication.
3. THE Workshop_Content for Module 4 SHALL retain the existing instructions for inspecting the Mistral-7B model data structure and using Neuron tools (neuron-ls, neuron-top) inside the vLLM pod.
4. THE Workshop_Content for Module 4 SHALL update the model directory path references from `Mistral-7B-Instruct-v0.2` to `Mistral-7B-Instruct-v0.3` to match the updated model version.

### Requirement 9: Update Introduction and Setup Content

**User Story:** As a workshop participant, I want the introduction and setup pages to accurately describe the FSx for ONTAP-based architecture, so that I understand the workshop objectives before starting.

#### Acceptance Criteria

1. THE Workshop_Content for the Introduction page SHALL replace all references to FSx for Lustre with FSx for NetApp ONTAP, including the description of the storage layer, the model hosting approach, and the architecture diagram.
2. THE Workshop_Content for the Introduction page SHALL include a description of FSx for NetApp ONTAP and the Trident CSI driver alongside the existing descriptions of vLLM, EKS, and Inferentia.
3. THE Workshop_Content for the Setup page SHALL update the on-demand deployment instructions to reference the updated CloudFormation template and Terraform configuration that provisions FSx for ONTAP instead of FSx for Lustre.
4. THE Workshop_Content for the Setup page SHALL update the IAM policy example to include FSx for ONTAP permissions (fsx:CreateFileSystem, fsx:CreateStorageVirtualMachine, fsx:CreateVolume, and related actions) instead of FSx for Lustre and S3 permissions.

### Requirement 10: Update Install and Cleanup Scripts

**User Story:** As a workshop participant, I want the install and cleanup scripts to work with FSx for ONTAP resources, so that I can set up and tear down the workshop environment correctly.

#### Acceptance Criteria

1. THE install script (`install.sh`) SHALL replace the FSx for Lustre CSI driver installation commands with Trident CSI driver installation commands using Helm.
2. THE install script SHALL replace the FSx for Lustre file system discovery commands (`aws fsx describe-file-systems` with LustreConfiguration queries) with FSx for ONTAP file system and SVM discovery commands.
3. THE install script SHALL replace the `sed` commands that populate FSx Lustre volume handle, DNS name, and mount name in PV manifests with commands that populate Trident backend configuration parameters (SVM management LIF, NFS LIF, volume junction path).
4. THE cleanup script (`cleanup.sh`) SHALL replace the FSx for Lustre CSI driver uninstall commands with Trident CSI driver uninstall commands.
5. THE cleanup script SHALL remove references to FSx Lustre PV/PVC names (`fsx-lustre-claim`, `fsx-pv`) and replace them with the FSx for ONTAP PVC names.
6. IF the install script encounters an FSx for ONTAP file system that is not in an AVAILABLE state, THEN THE install script SHALL display an error message and exit with a non-zero status code.

### Requirement 11: Maintain Workshop Functional Parity

**User Story:** As a workshop operator, I want the migrated workshop to deliver the same end-to-end learning experience (deploying a GenAI chatbot with high-performance storage on EKS), so that participants achieve the same learning objectives.

#### Acceptance Criteria

1. THE migrated workshop SHALL enable participants to deploy a functional vLLM inference endpoint serving the Mistral-7B model on EKS with Inferentia accelerators, using FSx_for_ONTAP as the persistent storage backend.
2. THE migrated workshop SHALL enable participants to interact with the Mistral-7B model through the Open WebUI chatbot interface, with the same user experience as the current FSx for Lustre-based workshop.
3. THE migrated workshop SHALL retain Module 3 (Observability dashboard) without modification, as it is independent of the storage backend.
4. THE migrated workshop SHALL complete within approximately 2 hours, matching the current workshop duration target.
5. WHEN the vLLM pod reads model data from the FSx_for_ONTAP-backed persistent volume, THE FSx_for_ONTAP file system SHALL provide sufficient throughput and latency performance for the vLLM pod to load the model and begin serving inference requests within 10 minutes of pod scheduling.
