---
title : "Deploy LiteLLM AI Gateway"
weight : 215
---

## Overview

In production environments, it is best practice to deploy an **AI Gateway** in front of the LLMs that you want to use. The AI Gateway acts as a proxy layer that provides intelligent AI request routing, observability, cost management,  intelligent model selection across different backend models, and  future flexibility. In this workshop, we will deploy [LiteLLM](https://github.com/BerriAI/litellm) as the AI Gateway. 


::::expand{header="Why an AI Gateway? [Click to see more]"}

In enterprise environments, you may self-host smaller LLM models for cost-effective inference where most of your requests are served. Then route less frequent but complex or deep reasoning requests to larger, more capable models. The AI Gateway pattern provides this intelligent routing capability:
- **Single service endpoint** for all consumers: one DNS name, multiple model backends
- **Model-per-workload routing**: consumers pick the right model for the job
- **Fallback and retry** across multiple backends
- **Cost tracking** and per-model usage visibility

With larger self-hosted models (70B+), you could route everything locally. The AI Gateway would still remain valuable from a failover, capability burst, cost optimization, and multi-model orchestration perspective.
::::


The AI Gateway exposes two named model endpoints through a single service:
- **`workshop-llm`** → self-hosted Mistral-7B model on your self-hosted AWS AI Stack (for Chatbot)
- **`workshop-llm-tools`** → Fully managed Amazon Bedrock Claude Haiku 4.5 model (tool-calling, reliable structured output)

To demonstrate AI Gateway and its capability, to serve different models, from different providers, to different consumers, whilst abstracting the actual backend model, in this workshop we have configured the following:
- The Open WebUI based Chatbot interface is configured to request the `workshop-llm` model (self-hosted Mistral-7B model), for chatbot related Q&A prompts;
- The AI-Agents we will deploy later in this workshop, will be configured to request the `workshop-llm-tools` model (served via fully managed Amazon Bedrock LLM models) for tool execution.  

:::alert{header="Deploy this now, no need to wait for vLLM" type="success"}
The vLLM pod from the previous section is still warming up (~5-7 minutes), but **you do not need to wait for it**. The LiteLLM gateway starts independently: its readiness check only validates the gateway itself, and it resolves the vLLM backend address lazily, per request. Deploy the gateway now (and OpenWebUI in the next section) **in parallel** while vLLM finishes loading the model in the background. By the time you open the chat UI, vLLM will be ready to serve.
:::

![LiteLLM AI Gateway routing: OpenWebUI requests the workshop-llm model and the Strands agents request workshop-llm-tools, both through the single litellm-service:4000/v1 endpoint, which routes them to self-hosted vLLM Mistral-7B on Inferentia and managed Bedrock Claude Haiku 4.5 respectively](/static/images/DeployLiteLLM-AIGateway.png)

---
### Deploy the AI Gateway (LiteLLM)


##### Step 1: Deploy the LiteLLM ConfigMap




:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f /home/participant/environment/eks/genai/litellm-config.yaml
:::


::::expand{header="Click here to view LiteLLM ConfigMap YAML"}

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
cat /home/participant/environment/eks/genai/litellm-config.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# litellm-config.yaml: AI Gateway routing configuration
model_list:
  - model_name: "workshop-llm"                                          # ← OpenWebUI uses this
    litellm_params:
      model: "openai/mistral-7b-neuron"
      api_base: "http://vllm-mistral7b-service.default.svc.cluster.local/v1"
      api_key: "not-needed"

  - model_name: "workshop-llm-tools"                                    # ← Agents use this
    litellm_params:
      model: "bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0"
:::

::::

##### Step 2: Deploy the LiteLLM Gateway

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/genai
export AWS_REGION
envsubst '$AWS_REGION' < litellm-deployment.yaml | kubectl apply -f -
:::

:::alert{header="Pod Identity for Bedrock Access" type="info"}
The Terraform script that provisioned this EKS cluster also created an **EKS Pod Identity Association** linking the `litellm` ServiceAccount to an IAM role with `bedrock:InvokeModel` permissions. When the LiteLLM pod starts, EKS automatically injects temporary AWS credentials, with no access keys or IRSA annotations needed.
:::

##### Step 3: Verify the gateway is ready

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl rollout status deployment/litellm-gateway --timeout=120s
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl get pods -l app=litellm-gateway
kubectl get svc litellm-service
:::

:::code{showCopyAction=false showLineNumbers=false language=bash}
NAME                                READY   STATUS    RESTARTS   AGE
litellm-gateway-7d4f8b9c7-x2k4m   1/1     Running   0          45s

NAME              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
litellm-service   ClusterIP   172.20.45.123   <none>        4000/TCP   45s
:::

---

### Summary

You have deployed the LiteLLM AI Gateway. It provides a single service endpoint (`litellm-service:4000`) that routes requests to the appropriate LLM backend based on model name. Continue to the next section to deploy the OpenWebUI chat interface, which connects through this gateway.
