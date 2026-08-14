---
title: 'Connect to your AWS lab environment'
chapter: false
weight: 23
---

## Connect to the Open-Source VSCode IDE for access to the AWS lab environment
Ref : [code-server](https://github.com/coder/code-server)

Throughout this workshop you will run commands from a browser-based **VSCode IDE** (code-server) that has already been provisioned for you, pre-loaded with all the workshop files, the AWS CLI, `kubectl`, `eksctl`, Terraform, and Helm. You do not install anything locally; you simply open the IDE in your browser and use its built-in terminal to copy-paste the commands provided in each module.

:::alert{header="Use Google Chrome" type="warning"}
Please use **Google Chrome** for this workshop. Firefox users may experience issues with copy-paste into the IDE terminal.
:::

Follow these steps to open your IDE:

1. Open the [AWS CloudFormation console](https://console.aws.amazon.com/cloudformation) and select the **`genaifsxworkshoponeks`** stack.
2. Select the **Outputs** tab (see image below).
3. Copy the temporary **Password** value, then click the **URL** value to launch the VSCode IDE in a new browser tab.

![CloudFormation console showing the genaifsxworkshoponeks stack in CREATE_COMPLETE, with the Outputs tab selected and two rows listed: Password (VSCode-Server Password) and URL (VSCode-Server URL), the URL value being a cloudfront.net link ending in ?folder=/home/participant/environment](/static/images/cfn-output.png)

4. In the VSCode login page that opens, paste the **Password** you copied and click **Submit**.

5. When prompted, select a **VSCode UI theme** (either option is fine).

![Get started with VS Code](/static/images/get-started-with-vs-code.png)

![VS Code for the Web "Get Started" page with the "Choose your theme" step expanded, showing a Browse Color Themes button on the left and four theme previews on the right: Dark Modern, Light Modern, Dark High Contrast, and Light High Contrast](/static/images/select-theme.png)

6. Open a terminal: from the top menu choose **Terminal → New Terminal** (or click the **TERMINAL** tab if one is already open), then maximize the terminal panel so you have room to work.

![The VS Code bottom panel with the TERMINAL tab selected next to PROBLEMS, OUTPUT, DEBUG CONSOLE, PORTS and CODE REFERENCE LOG, showing a bash prompt reading participant:~/environment$, and the maximize-panel icon highlighted at the far right of the toolbar](/static/images/maximize.png)

:::alert{header="This terminal is your workspace for the whole workshop" type="info"}
Every command in the following modules is run from this VSCode terminal. The workshop files live under `/home/participant/environment/`, and you can browse them in the IDE's file explorer on the left, and open any YAML or script to inspect it as you go.
:::


## Update the kube-config file for Amazon EKS cluster:
Before you can start running all the Kubernetes commands included in this workshop, you need to update the kube-config file with the proper configuration to access EKS cluster. To do so, in your VSCode terminal run the below commands:

::code[export CLUSTER_NAME=eksworkshop]{language=bash showLineNumbers=false showCopyAction=true}

:::alert{header="Note" type="info"}
The first time you copy-paste a command in the VSCode IDE, your browser may ask permission to read the clipboard. Please select **"Allow"**.

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

You now have a VSCode IDE Server environment set-up ready to use your Amazon EKS Cluster! You may now proceed with the next step.
