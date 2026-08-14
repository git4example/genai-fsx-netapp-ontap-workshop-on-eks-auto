---
title : "Deploy Observability dashboards"
weight : 320
---

## Overview

In this section you will setup & deploy Grafana based dashboards that will provide observability into inference workload, vLLM & Neuron (AWS Inferentina) performance metrics.


### vLLM inference engine monitoring setup

Run the below commands to deploy a Service Monitor configuration so that prometheus can scrape metrics from the vLLM service endpoint.

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
cd /home/participant/environment/eks/genai/observability/
kubectl apply -f vllm-servicemonitor.yaml
:::

### Neuron monitoring setup

Neuron monitor collects and exposes hardware metrics (utilization, memory usage, and temperature) from AWS Inferentia and Trainium chips through a Prometheus-compatible.

1. Run the below command to deploy the Neuron Monitor Deamonset and service to expose metrics

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f neuron-monitor.yaml
:::

2. Deploy Service Monitor to scrape metrics

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f neuron-servicemonitor.yaml
:::

### Deploy a combined vLLM inference and Neuron monitoring dashboard

3. Now that we have our vLLM and Neuron metrics collectors setup, run the below command to deploy our custom "**vLLM + Neuron monitoring**" Grafana based dashboard. This custom dashboard combines specific Inference metrics along with Neuron metrics into a single dashboard view.

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f vllm-neuron-dashboard-configmap.yaml
:::


### Log into the Grafana dashboard

1. Run the following command to get the Grafana dashboard URL, and logon credentials.

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
GRAFANA_URL=$(kubectl get svc -n kube-system kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
echo "Grafana URL: http://$GRAFANA_URL"
echo "Username: admin"
echo "Password: $GRAFANA_PASSWORD"
:::

![Terminal output of the three echo commands, printing the Grafana URL as an elb.us-west-2.amazonaws.com load balancer address, the username admin, and a redacted password](/static/images/grafana_url.png)

2. You will need to wait for 2 minutes for the Grafana URL load balancer to become online. Then open the Grafana URL (shown in the output) in your browser, and use the credentials shown to log-in.

<br>

3. Within the Grafana URL, click on the "**Dashboards**" option from the left window pane.

4. In the search field, enter the name of the dashboard you want to view, such as the "**vLLM + Neuron Monitoring Dashboard**" that you created in the pervious steps.

5. Click on the name that it returns to open the Grafana dashboard. **DO NOT CLOSE** this dashboard as you will revisit it in the below steps.

![Grafana Dashboards page with Dashboards selected in the left navigation, "vLLM + Neuron Monitoring Dashboard" typed into the search box, and a single matching result of type Dashboard listed below](/static/images/mistral_vllm_dash_1.png)

6. Now navigate back to your **Open WebUI Chatbot session**. If you accidently closed the web session, run the below command to get the URL and then open it (remember its a HTTP URL not a HTTPS).

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl get ing
:::

7. From the left hand window pane of the Open WebUI client, **right-click** on your **previous chat session** and select **Delete**.

![Open WebUI with the mistralai/Mistral-7B-Instruct-v0.2-neuron model selected, a saved chat highlighted under Today in the left sidebar, and its context menu open showing Share, Download, Rename, Pin, Clone, Move, Archive and Delete, with Delete highlighted](/static/images/new_chat.png)

8. From the left hand window pane of the Open WebUI client, right-click on **New Chat**

9. In the new chat session, generate some input prompts (i.e. ask the Chatbot some questions or give it a task)

10. Navigate back to your **vLLM + Neuron monitoring** dashboard to see the inference metrics related to your input prompts. Firstly click on the time range button and select *5min* or *15min* and select *Refresh*

![Top of the vLLM + Neuron Monitoring Dashboard showing the datasource and model_name selectors on the left, and on the right the time-range picker set to "Last 5 minutes" next to the Refresh button, with the NeuronCore & System CPU Utilization and Neuron Device & System Memory Usage panels beginning below](/static/images/refresh_dash.png)

11. You will now see Inference metrics (such as below) related to inference query load, input prompt tokens, output generated tokens, Neuron compute performance etc, based on your previous prompt query.

![The full vLLM + Neuron Monitoring Dashboard with six populated time-series panels: NeuronCore & System CPU Utilization peaking near 100 percent during inference, Neuron Device & System Memory Usage flat at roughly 24 GiB, vLLM Token Throughput rising to about 50 tokens per second, vLLM Request Token Distribution percentiles, vLLM Time to First Token around 5 seconds, and vLLM End-to-End Request Latency](/static/images/vLLMNeuronMonitoringDashboard.png)


## Summary

In this section, you have deployed a Grafana dashboard that provides observability across vLLM, Inference workload, and Neuron compute performance metrics.



---




### Optional: Additional metrics dashboards available for deployment

You can deploy any of the optional dashboards below to view different metrics. Once you deploy one of the below dashboards, simply search for them in Grafana dashboards to view them (as per the above step).


1. Deploy a dashboard called "vLLM Performance Statistics" on Grafana

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f vllm-performance-dashboard.yaml
:::

2. Deploy a dashboard called "vLLM Query Statistics" on Grafana

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f vllm-query-statistics.yaml
:::


3. Deploy a dashboard called "AWS Neuron Hardware Monitoring" on Grafana

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f neuron-monitoring-configmap.yaml
:::
