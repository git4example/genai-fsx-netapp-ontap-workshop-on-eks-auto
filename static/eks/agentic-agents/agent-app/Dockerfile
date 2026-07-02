FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir strands-agents strands-agents-tools openai fastapi uvicorn mcp

COPY agent.py .

ENV DATA_DIR=/data
ENV AGENT_ROLE="general assistant"
ENV LLM_ENDPOINT="http://litellm-service.default.svc.cluster.local:4000/v1"
ENV LLM_MODEL_ID="workshop-llm-tools"
ENV LLM_API_KEY="not-needed"

ENTRYPOINT ["python", "agent.py"]
CMD ["--serve"]
