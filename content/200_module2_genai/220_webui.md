---
title : "Deploy Open WebUI chat application to interact with model"
weight : 220
---
## Overview

In this section you will deploy the Open WebUI (chatbot UI client), and run through example prompts and view Generative-AI output.

### How to consume an Inference endpoint from an Inference engine.
A chatbot UI can interact with an Inference engine by accessing the Inference engine endpoint. The **"Open WebUI"** application is designed to consume any OpenAI-compatible endpoint. In this workshop, Open WebUI connects to the **LiteLLM AI Gateway** deployed in the previous step, which intelligently routes chat requests to the self-hosted Mistral-7B model on Inferentia. The Open WebUI application allows users to interact with the LLM model through a chat-based interface. To use the Open WebUI application, you need to deploy the application container and configure it to point at the AI Gateway endpoint, then connect to the Open WebUI URL and start chatting with the LLM model.

<br></br>

-------------------------
### Step 1: Deploy the Open WebUI pod.
-------------------------

We will deploy Open WebUI using its official Helm chart. The chart values are defined in `open-webui-helm/values.yaml` and pre-configured to connect to the vLLM Mistral service deployed in the previous step.

1. Add the Open WebUI Helm repository:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
helm repo add open-webui https://helm.openwebui.com/
helm repo update
:::

2. Install Open WebUI with the Helm chart. This provisions an Application Load Balancer for the chat interface.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/genai
helm upgrade --install open-webui open-webui/open-webui \
  -n default \
  -f open-webui-helm/values.yaml
:::

::::expand{header="Optional: Restrict ALB access to your IP (for on-demand / local laptop deployments only)"}

If you are running this workshop from your **own laptop** (not the workshop VSCode IDE), you can lock down the ALB to your public IP. **Do not run this from the VSCode IDE** — the detected IP would be the IDE instance's IP, not your laptop's, and you would lock yourself out.

1. Detect your public IP:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "Restricting ALB to: ${MY_IP}/32"
:::

2. Re-run the helm install with the IP restriction:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/genai
helm upgrade --install open-webui open-webui/open-webui \
  -n default \
  -f open-webui-helm/values.yaml \
  --set-string ingress.annotations."alb\.ingress\.kubernetes\.io/inbound-cidrs"="${MY_IP}/32"
:::

If your IP changes later, re-run the same command to refresh the restriction.

::::

3. Let's obtain the URL ADDRESS of the Open WebUI Chat interface by running the below command (if you don't get a URL address output, run the command again after a few seconds)

::code[kubectl get ing]{language=bash showLineNumbers=false showCopyAction=true}

![WebUI_url](/static/images/WebUI_url.png)

4. The Open WebUI and load balancer will take up-to **2 minutes to come online**. Once you have waited 2 minutes, copy above the URL ADDRESS into a web browser as "*http://<-URL-ADDRESS->*". This will open a Open WebUI chat client interface.

:::alert{header="Note" type="info"}
Make sure your URL is "**http:**//<-URL-ADDRESS->" and doesn't start with "**https:**". Some browser like chrome try **"https"** by default if you dont provide protocol.
:::


5. In the Open WebUI interface you will see a drop down in the top menu bar, used to select your model. Select **workshop-llm** from the drop down, and start chatting with your newly deployed Generative AI chat application.

:::alert{header="Why 'workshop-llm'?" type="info"}
The model name shown in OpenWebUI is the **virtual model name** defined in the LiteLLM AI Gateway config. Behind the scenes, your chat requests are routed to the self-hosted Mistral-7B model on Inferentia. The gateway abstracts the backend — consumers see a logical model name, not the physical deployment details. This is a common enterprise pattern for managing multiple LLM backends through a single gateway.
:::

If you don't see the model in the dropdown, please refresh the WebUI page. (Remember from the previous lab module, that the vLLM Pod and the model load into memory will take approx. 7 minutes)

![Open WebUI](/static/images/OpenWebUI.png)

You can also see when vLLM Pod and the Mistral model has been loaded into the vLLM memory by running below command into your terminal session, and seeing the "*Application startup complete*" in the output.

::code[kubectl logs <your-vLLM-pod-name> -f]{language=bash showLineNumbers=false showCopyAction=true}



6. You have now successfully deployed a Generative AI Chatbot as a containerized application running on Amazon EKS, with the cached Mistral-7B model hosted on Amazon FSx for NetApp ONTAP, and the compute powered by AWS Inferentia Accelerators.

-------------------------

### Step 2: Run example input prompt queries and view Generative-AI output.

---

Task 1  | Scripting task
---

- Ask the Chatbot to generate a quick script for us. Copy and paste the below example prompt into the Chatbot (or write your own).

::code[write a Linux bash script that creates files, taking inputs for the size of the file (in terms of KB), the number of files to create, the number of concurrent file creation threads for the script to execute, where each file has the words "this is a test file" in it. Each created filename starts with "test" and has a 5 digit suffix appended to it, starting with 00000]{language=bash showLineNumbers=false showCopyAction=true}



Task 2  | Language translation task
---

-  Ask the Chatbot to perform a language translation, without telling it what language the document is in.
-  Download the document : https://pages.awscloud.com/rs/112-TZM-766/images/AWS-Summit-Japan-2025-EXPO-Guide.pdf



- Open the PDF, go to page 4, and copy one of the session descriptions thats in  Japanese (for example the one shown in the image below). You can copy a section by highlighting a section of the Japanese text using your mouse, then select copy.



![AWS Summit Tokyo session](/static/images/aws_summit_tokyo_session.jpg)



- Then ask the Chatbot to perform the following:

::code[translate this : <paste the Japanese language section that you copied>]{language=bash showLineNumbers=false showCopyAction=true}



Task 3  | Context for input prompts using a context document
---


For this testing, lets first ask the Chatbot the following question, without any context documents :
- Ask the Chatbot "What is MCP"

<br>

- Then ask "What is the guidance for deploying an MCP server"

<br>

- Without context or a reference document, its not talking about the **Model Context Protocol Server** that we were asking about in relation to Generative AI.  
<br>


:::alert{header="Note" type="info"}
You can give the Chatbot context for prompts by attaching files directly to the prompt, or by creating a library of documents (Workspaces -> knowledge) that you can reference in your prompts.
:::


- Now lets give the Chatbot some context for our query on MCP. Download this file, which we will use to apply local context: https://d1.awsstatic.com/solutions/guidance/architecture-diagrams/deploying-model-context-protocol-servers-on-aws.pdf

<br></br>

- In your Chatbot session click on the "**+**" icon in your prompt, and select **Upload files**, and select the file you downloaded.

<br>

- Now run the same prompt again ""What is the guidance for deploying an MCP server"

<br>

- As you can see, the GenAI application used the attached file for local context to provide a more specific response to query we were looking for, in terms of Generative-AI.

<br>

- You have now completed this module. **DO NOT CLOSE** your Open WebUI Chatbot browser session, you will need this for the next module of the workshop



### Summary
You have now completed this module, and have deployed your own Generative-AI Chatbot using an Open WebUI client to interface to vLLM inference engine, which is serving the Mistral-7B LLM, from an FSx for NetApp ONTAP-backed Persistent Volume. You have also seen the different Generative-AI output capabilities of the model by running different prompt scenarios.
