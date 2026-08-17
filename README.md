
# Flexible AI on AWS + FSx NetApp - Self hosted Agentic-AI

## Workshop objective
Learn how to build your own self-hosted Generative-AI  application for performance, scale, and observability using an AWS AI stack of;

* **AWS Inferentia** - Accelerated Compute to power your Generative-AI application.
* **Amazon Elastic Kubernetes Service (EKS)** - Orchestration layer used to host Generative-AI & Agentic-AI applications.
* **Amazon FSx for NetApp ONTAP** - High-performance shared storage used to host LLM models and unstructured data.

---

### In this workshop you will build the following:

**1 - A Generative AI application & observability dashboards:** You will deploy a Generative-AI chatbot using; an Open WebUI chatbot interface, a vLLM (model serving engine), and an open-source Large Language Model (LLM), all hosted on an AWS based AI stack of:

**2 - An Agentic AI workflow:** You will deploy AI Agents (AWS Strands Agents) that integrate with your FSx for NetApp data.




## Repo structure

```bash
.
├── README.md
├── content
│   ├── 010_introduction
│   │   └── index.en.md
│   ├── 020_setup
│   │   ├── 021_on_demand
│   │   │   └── index.en.md
│   │   ├── 022_aws_event
│   │   │   └── index.en.md
│   │   └── index.en.md
│   ├── 023_vs_code
│   │   └── index.en.md
│   ├── 030_module_explore_eks_auto
│   │   └── index.en.md
│   ├── 100_module1_eks_fsxontap
│   │   ├── 105_ExploreFSxConsole.md
│   │   ├── 110_DeployTridentCSIDriverToEKS.md
│   │   └── index.en.md
│   ├── 200_module2_genai
│   │   ├── 210_Deploy.md
│   │   ├── 211_Deploy_vllm.md
│   │   ├── 215_DeployAIGateway.md
│   │   ├── 220_webui.md
│   │   └── index.en.md
│   ├── 300_module3_observability
│   │   ├── 310_settingObservabilityStack.md
│   │   ├── 320_vLLMandNeuronMonitoring.md
│   │   ├── 330_ConfiguratingNeuronMonitoring.md
│   │   └── index.en.md
│   ├── 400_module4_agentic_fsxn
│   │   ├── 410_PrepareData.md
│   │   ├── 430_DeployAgents.md
│   │   ├── 440_TestAgents.md
│   │   ├── 450_Summary.md
│   │   └── index.en.md
│   ├── 500_module5_inspect_data        # (Optional)
│   │   ├── 510_InspectModelandNeuron.md
│   │   ├── 520_FSxNSnapshots.md
│   │   └── index.en.md
│   ├── 600_module6_dynamic_prov        # (Optional)
│   │   ├── 610_dynamic_prov.md
│   │   └── index.en.md
│   ├── 700_module7_maz_failover        # (Optional)
│   │   ├── 710_ObserveMAZState.md
│   │   ├── 720_TriggerFailover.md
│   │   └── index.en.md
│   └── index.en.md
└── static
    ├── GenAIFSXWorkshopOnEKS.yaml
    ├── download
    │   └── fsx-ontap-standalone.tf
    ├── eks
    │   ├── FSxONTAP
    │   │   ├── fsx-ontap-secret.yaml
    │   │   ├── model-loading-job.yaml
    │   │   ├── netshoot-fsxn.yaml
    │   │   ├── ontap-pvc.yaml
    │   │   ├── ontap-storage-class.yaml
    │   │   ├── trident-backend-config.yaml
    │   │   └── volume-snapshot-class.yaml
    │   └── genai
    │       ├── inferentia_nodepool.yaml
    │       ├── mistral-ontap.yaml
    │       ├── observability/
    │       └── open-webui-helm/
    │           └── values.yaml
    ├── images
    │   └── [ workshop images ]
    ├── scripts
    │   ├── cleanup-on-demand.sh
    │   ├── cleanup-sponsored.sh
    │   ├── quick-deploy-on-demand.sh
    │   ├── quick-deploy-sponsored.sh
    │   ├── terraform-cleanup.sh
    │   ├── terraform-deploy.sh
    │   └── trident-csi-driver.json
    └── terraform
        ├── helm-values
        │   ├── neuron-values.yaml
        │   └── nvidia-values.yaml
        └── main.tf
```


### Part 1: Prerequisite for setting up an on-demand workshop (using your own AWS account)
Follow the below instructions to complete the required steps before you can launch the AWS CloudFormation Stack that will provision this workshop.

:::alert{header="Note" type="info"}
Here some of step you may feel as duplication of data, however its to align it with sponsored workshop setup and code managability.
:::


You will need a Linux based Amazon Linux 2023 based EC2 jump-box that is configured with an Amazon EBS GP3 based volume that has at least 100GB FREE. This EC2 jump-box also needs to have the required account access and permissions in-order to run the commands outline below, along with being able to create AWS resources required for this workshop.  


 **Note**: You may need IAM permissions attached to this EC2 instance role with following broad indicative permissions to provision workshop resouces

Here's a broad IAM policy that you may includes all the required permissions for both CloudFormation and Terraform deployments:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:GetCallerIdentity",
                "cloudformation:*",
                "cloudfront:*",
                "ec2:*",
                "eks:*",
                "iam:*",
                "fsx:*",
                "kms:*",
                "lambda:*",
                "logs:*",
                "s3:*",
                "secretsmanager:*",
                "sqs:*",
                "ssm:*",
                "elasticloadbalancing:*",
                "ecr-public:GetAuthorizationToken"
            ],
            "Resource": "*"
        }
    ]
}
```

`sqs` is required: the stack creates a queue that every provisioning step reports
progress to, so stack creation fails without it. `kms`, `eks`, `fsx` and
`elasticloadbalancing` cover the Terraform stage.

This breadth applies only to the instance you deploy *from*. The jumpbox created
*inside* the workshop uses a much narrower policy, the `WorkshopLeastPrivilege`
inline policy on `VSCodeInstanceRole` in `static/GenAIFSXWorkshopOnEKS.yaml`.


### Part 2: Automated workshop deployment


Run the automated deployment script :

```bash
# Point WORKSHOP_REPO_ORG at the GitHub org/user hosting this workshop
# (or your own fork), then clone and run the deployment script.
export WORKSHOP_REPO_ORG=<github-org-or-user-hosting-this-workshop>

git clone https://github.com/${WORKSHOP_REPO_ORG}/genai-fsx-netapp-ontap-workshop-on-eks-auto.git
cd genai-fsx-netapp-ontap-workshop-on-eks-auto/static/scripts
chmod +x quick-deploy-on-demand.sh
./quick-deploy-on-demand.sh
```

> The repository location is a variable, not a fixed URL, because the workshop
> is not yet published under an AWS-owned GitHub organisation. Once it is, set
> that org as the default in `quick-deploy-on-demand.sh` and this becomes a
> plain copy-paste again.

**Time**: ~45-60 minutes (complete infrastructure deployment)

The workshop automated deployment script that handles all setup tasks including:
- Tool installation (AWS CLI, Docker, Git, jq)
- Repository cloning
- S3 bucket creation and file uploads
- Mistral-7B model download and upload
- CloudFormation stack deployment with monitoring
- Deployment validation and access information


You have now completed the workshop deployment and have a VSCode IDE Server environment ready to use with your Amazon EKS Cluster!

### Part 3: Access your workshop

**Connect to your AWS lab environment via the Open source VSCode IDE**.

You will be using an Open source VSCode IDE terminal to copy and paste the required commands provided in this workshop modules. refer to this link for further information on the [VSCode IDE code-server](https://github.com/coder/code-server)

::alert[Note: Use Google chrome browser for the best user experience with VSCode IDE, as Firefox users may experience some issues with copy-paste commands.]{header="Important" type="warning"}

**Log into your VSCode IDE Instance:**
1. Navigate to the AWS CloudFormation console [link](https://console.aws.amazon.com/cloudformation) and select the `genaifsxworkshoponeks` stack
2. Click on Stack **Outputs**
3. Copy the **Password** and click on the URL to open the VSCode IDE interface
4. Enter the password you copied into the VSCode IDE interface


![CloudFormation console showing the genaifsxworkshoponeks stack in CREATE_COMPLETE, with the Outputs tab selected and two rows listed: Password (VSCode-Server Password) and URL (VSCode-Server URL), the URL value being a cloudfront.net link ending in ?folder=/home/participant/environment](/static/images/cfn-output.png)

5. Select your VSCode UI theme

![VS Code for the Web "Get Started" page with the "Choose your theme" step expanded, showing a Browse Color Themes button on the left and four theme previews on the right: Dark Modern, Light Modern, Dark High Contrast, and Light High Contrast](/static/images/select-theme.png)

6. Click the top right hand icon to maximize terminal window.

![The VS Code bottom panel with the TERMINAL tab selected next to PROBLEMS, OUTPUT, DEBUG CONSOLE, PORTS and CODE REFERENCE LOG, showing a bash prompt reading participant:~/environment$, and the maximize-panel icon highlighted at the far right of the toolbar](/static/images/maximize.png)


## Update the kube-config file for Amazon EKS cluster:
Before you can start running all the Kubernetes commands included in this workshop, you need to update the kube-config file with the proper configuration to access EKS cluster. To do so, in your VSCode terminal run the below commands:

::code[export CLUSTER_NAME=eksworkshop]{language=bash showLineNumbers=false showCopyAction=true}

:::alert{header="Note" type="info"}
When you first time copy-paste a command on VSCode IDE, your browser may ask you to allow permission to see informaiton on clipboard. Please select **"Allow"**.

![Browser permission prompt titled "Share clipboard?" asking whether the cloudfront.net site may see text and images copied to the clipboard, with Block and Allow buttons and Allow highlighted](/static/images/allow-clipboard.png)
:::


- Check if region and cluster names are set correctly

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo $AWS_REGION
echo $CLUSTER_NAME
:::


::code[aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION]{language=bash showLineNumbers=false showCopyAction=true}


## Test Amazon EKS cluster connectivity:
Run the command below just to see the connectivity to EKS Auto Cluster:

::code[kubectl get nodes]{language=bash showLineNumbers=false showCopyAction=true}

You should see one node provisioned which was provisioned by EKS Auto to run some of the core components required for the workshop.
![Terminal output of kubectl get nodes listing a single node in Ready status with no assigned roles, aged 35 minutes, running Kubernetes version v1.33.1-eks-b9364f6](/static/images/get-nodes.png)

You now now completed the workshop deployment and have a VSCode IDE Server environment ready to use with your Amazon EKS Cluster! Please proceed to the first module of the workshop **[Explore EKS Auto](/030_module_explore_eks_auto)**.

**Note:** Once you have completed the workshop, navigate back to this page, and the below section to perform the **Clean up** tasks.

### Part 4: Workshop cleanup

When you're finished with the workshop, use the cleanup script to remove all resources:

```bash
# Navigate to scripts directory (if not already there)
cd genai-fsx-netapp-ontap-workshop-on-eks-auto/static/scripts

# Run cleanup script
./cleanup-on-demand.sh
```

**Cleanup Features**:
- Interactive confirmation for each cleanup step
- CloudFormation stack deletion with progress monitoring
- Optional S3 bucket and contents removal
- Local files and temporary data cleanup
- Verification commands to confirm resource removal

**Time**: ~30-60 minutes (CloudFormation deletion of complex resources)

:::alert{header="Important" type="warning"}
Always run the cleanup script after completing the workshop to avoid unexpected AWS charges.
:::
