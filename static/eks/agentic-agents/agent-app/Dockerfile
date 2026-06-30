FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir strands-agents strands-agents-tools openai

COPY agent.py .

ENV DATA_DIR=/data
ENV AGENT_ROLE="general assistant"
ENV LLM_ENDPOINT="http://vllm-mistral7b-service.default.svc.cluster.local/v1"

ENTRYPOINT ["python", "agent.py"]
