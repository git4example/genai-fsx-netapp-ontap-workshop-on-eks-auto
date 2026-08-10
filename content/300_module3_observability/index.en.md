---
title : "Module 3: Observability dashboard for LLM Inference"
weight : 300
---


## Module Overview

It is important to have observability into Inference workloads so you can optimize accordingly. In this section, you will create Grafana based dashboards that provide detailed observability across inference workload metrics, tokens usage, AI stack performance, and system health.

While this module demonstrates how to instrument observability tools directly on Amazon EKS for learning purposes, for production environments at scale, we recommend using AWS managed services such as Amazon Managed Service for Prometheus (AMP) and Amazon Managed Grafana (AMG) for improved scalability, reduced operational overhead, and better integration with the AWS ecosystem.

This module guides you through implementing observability, divided into 3 sections:

1. Setting-up the observability Stack
    - Understand the deployed monitoring components
    - Review Prometheus and Grafana architecture
    - Configure Grafana Operator
    - Deploy Node Exporter for Neuron metrics collection


2. Configuring Performance Monitoring
    - Configure neuron-monitor metrics collection
    - Create Grafana dashboards for Neuron performance visualization
    - Track NeuronCore utilization, Model inference latency, Memory consumption, Hardware performance metrics


3. vLLM Model Monitoring
    - Implement vLLM-specific metrics collection
    - Create custom performance dashboards
    - Track token generation and latency metrics
    - Monitor inference queue and processing times
