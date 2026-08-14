---
title: 'On-demand Workshop'
chapter: false
weight: 21
---

**On-demand workshops** are workshops that you deploy in your own environment. These are different to **AWS Sponsored workshops**, where AWS will provide you with a temporary workshop lab account, which already has the workshop provisioned in it.


:::alert{header="Important" type="warning"}
If you are at an AWS event, please **SKIP** this section and go straight to the **[AWS Sponsored Workshop](/020-setup/022-aws-event)**
:::


## Part 1: Identify an Amazon EC2 instance that you can use for the initial workshop provisioning

To deploy the workshop script (in part 2 of this module), you will need access to a Linux based Amazon Linux 2023 Amazon EC2 instance, with an Amazon EBS GP3 volume with at least 100GB free capacity (to download the LLM model data and other items required for the workshop)

This Linux based EC2 instance also needs to have the required AWS account access and permissions in-order to run the commands outlined below, along with being able to create AWS resources required for this workshop (as shown below).

The workshop deploys the following AWS services via CloudFormation and Terraform:

* Amazon EKS (cluster, nodegroups, access entries, addons)
* Amazon EC2 + VPC (networking, security groups, launch templates, jumpbox instance)
* Amazon FSx for NetApp ONTAP (file system, SVM, volumes)
* AWS IAM (roles, policies, OIDC provider for IRSA, service-linked roles)
* AWS KMS (customer-managed keys for EKS secrets and FSx encryption)
* AWS Secrets Manager (SVM admin password, VSCode server password)
* Amazon S3 (workshop asset bucket; the Mistral model is NOT staged in S3)
* Amazon CloudWatch Logs (EKS control-plane logs)
* Elastic Load Balancing (for the Open WebUI front-end)
* AWS Systems Manager (agent on the jumpbox)

Below is an EXAMPLE of a broad IAM policy that you could use, which includes all the required permissions for both CloudFormation and Terraform deployments. This is suitable for the EC2 jumpbox role that runs the deployment script:

:::code{showCopyAction=false showLineNumbers=true language=json}
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:GetCallerIdentity",
                "sts:AssumeRole",
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
                "ssm:*",
                "elasticloadbalancing:*",
                "ecr-public:GetAuthorizationToken"
            ],
            "Resource": "*"
        }
    ]
}
:::

:::alert{header="Note" type="info"}
The VSCode jumpbox role that the CloudFormation stack creates inside the workshop uses a tighter, scoped least-privilege policy. See `static/vscode_instance_role_policy.json` in the repo for the exact policy applied to the in-workshop jumpbox.
:::


## Part 2: Automated workshop deployment script

The below workshop automated deployment script handles setup tasks including:
- Tool installation (AWS CLI, Docker, Git, jq)
- Repository cloning
- Syncing workshop files (`terraform/`, `eks/`, `scripts/`) to an S3 asset bucket
- Creating AWS resources: Amazon EKS cluster, Amazon EC2 instance, Amazon FSx for NetApp ONTAP file system
- Deployment of the VSCode IDE terminal (which you will use to interact with the workshop)
- CloudFormation stack deployment with monitoring
- Deployment validation and access information

:::alert{header="Model staging" type="info"}
The Mistral-7B model is **not** staged to S3 by this script. It is pulled directly from HuggingFace (`Hello2pariksit/Mistral-7B-Instruct-v0.3-neuron`) into the FSx for NetApp ONTAP volume by a Kubernetes Job that runs automatically **during workshop provisioning** (so participants don't wait for it). This is a one-time download (~30 GB, ~3 minutes) that persists across pod restarts.
:::

1. Run the below commands to start the automated workshop environment deployment script:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
curl -O https://raw.githubusercontent.com/git4example/genai-fsx-netapp-ontap-workshop-on-eks-auto/mainline/static/scripts/quick-deploy-on-demand.sh
chmod +x quick-deploy-on-demand.sh
./quick-deploy-on-demand.sh
:::

**Deployment time will take approx:** ~45 minutes (complete infrastructure deployment)

2. Wait until you see the following output on your screen before progressing to **Part 3: Use the VS Code IDE to access the workshop**

![Final line of terminal output reading "[INFO] Setup completed successfully! Ready for workshop learning experience."](/static/images/ondemand_setup_complete.png)



## Part 3: Use the VS Code IDE to access the workshop

You have now completed the workshop deployment and its components.

Click on the following link to access your **[Open source VSCode IDE](/023_vs_code)** and begin the workshop.


## Part 4: Workshop cleanup, once you have finished

When you're finished with the workshop, use the cleanup script to remove all resources:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
# Navigate to scripts directory (if not already there)
cd genai-fsx-netapp-ontap-workshop-on-eks-auto/static/scripts

# Run cleanup script
./cleanup-on-demand.sh
:::

**Cleanup Features**:
- Interactive confirmation for each cleanup step
- CloudFormation stack deletion with progress monitoring
- FSx for ONTAP file system and related resource removal
- Local files and temporary data cleanup
- Verification commands to confirm resource removal

**Time**: ~30-60 minutes (CloudFormation deletion of complex resources)

:::alert{header="Important" type="warning"}
Always run the cleanup script after completing the workshop to avoid unexpected AWS charges.
:::
