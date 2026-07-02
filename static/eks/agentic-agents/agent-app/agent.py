import os
import sys
import io
import glob
from strands import Agent, tool
from strands.models.openai import OpenAIModel

model = OpenAIModel(
    client_args={
        "base_url": os.environ.get("LLM_ENDPOINT", "http://litellm-service.default.svc.cluster.local:4000/v1"),
        "api_key": os.environ.get("LLM_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("LLM_MODEL_ID", "workshop-llm-tools"),
)

DATA_DIR = os.environ.get("DATA_DIR", "/data")
AGENT_ROLE = os.environ.get("AGENT_ROLE", "general assistant")


@tool
def list_files(directory: str = "") -> str:
    """List files and directories in the agent's data volume.

    Args:
        directory: Subdirectory to list (relative to data root). Empty string for root.
    """
    target = os.path.join(DATA_DIR, directory)
    try:
        entries = os.listdir(target)
        if not entries:
            return f"EMPTY: The directory /{directory or '.'} contains no files or subdirectories. You have no data available."
        return f"Contents of /{directory or '.'}:\n" + "\n".join(
            f"  {'[DIR] ' if os.path.isdir(os.path.join(target, e)) else '      '}{e}"
            for e in sorted(entries)
        )
    except PermissionError:
        return f"ACCESS DENIED: Permission denied reading {target}. You do not have authorization to access this data."
    except FileNotFoundError:
        return f"NOT FOUND: Directory '{directory}' does not exist in your data volume."


@tool
def read_file(filepath: str) -> str:
    """Read the contents of a file from the agent's data volume.

    Args:
        filepath: Path to the file relative to the data root directory.
    """
    target = os.path.join(DATA_DIR, filepath)
    try:
        with open(target, 'r') as f:
            content = f.read(4096)
        return f"=== Content of {filepath} ===\n{content}"
    except PermissionError:
        return f"ACCESS DENIED: Permission denied reading '{filepath}'. Your agent does not have authorization to access this file."
    except FileNotFoundError:
        return f"NOT FOUND: File '{filepath}' does not exist in your data volume."


@tool
def search_documents(query: str) -> str:
    """Search for a keyword across all documents in the agent's data volume.

    Args:
        query: Search term to look for across all files.
    """
    results = []
    try:
        for filepath in glob.glob(os.path.join(DATA_DIR, "**/*"), recursive=True):
            if os.path.isfile(filepath):
                try:
                    with open(filepath, 'r') as f:
                        content = f.read()
                    if query.lower() in content.lower():
                        rel_path = os.path.relpath(filepath, DATA_DIR)
                        for i, line in enumerate(content.split('\n'), 1):
                            if query.lower() in line.lower():
                                results.append(f"  {rel_path}:{i}: {line.strip()[:100]}")
                                break
                except PermissionError:
                    results.append(f"  ACCESS DENIED: Cannot read {os.path.relpath(filepath, DATA_DIR)}")
    except PermissionError:
        return f"ACCESS DENIED: Cannot traverse the data directory. Your agent does not have authorization."

    if results:
        return f"Search results for '{query}':\n" + "\n".join(results[:10])
    return f"No results found for '{query}' in accessible documents."


# --- Strands Agent ---
agent = Agent(
    model=model,
    tools=[list_files, read_file, search_documents],
    system_prompt=f"""You are a {AGENT_ROLE}. You have access to a data volume with documents relevant to your role.

Use your tools to:
- list_files: See what's available in your data directory
- read_file: Read specific documents
- search_documents: Search for keywords across all documents

Always use your tools to access data. If you get ACCESS DENIED errors, report them clearly — you are not authorized to access that data.
If the data directory is empty, report that clearly — you have no data available.
Do NOT make up or hallucinate data. Only report what your tools return.
Keep responses concise — report the tool results directly without explaining what you would do next."""
)


def invoke_agent(query: str) -> str:
    """Invoke the agent with stdout suppressed (no streaming noise)."""
    old_stdout = sys.stdout
    sys.stdout = io.StringIO()
    try:
        response = agent(query)
    finally:
        sys.stdout = old_stdout
    return str(response)


# --- Server Mode (FastAPI + MCP) ---
def create_app():
    from collections.abc import AsyncIterator
    from contextlib import asynccontextmanager
    from fastapi import FastAPI
    from fastapi.responses import JSONResponse
    from mcp.server.fastmcp import FastMCP

    mcp_server = FastMCP(AGENT_ROLE)

    @mcp_server.tool()
    def ask_agent(query: str) -> str:
        """Ask this AI agent a question. The agent will use its tools to access data and provide an answer."""
        return invoke_agent(query)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        async with mcp_server.session_manager.run():
            yield

    app = FastAPI(title=f"Agent: {AGENT_ROLE}", lifespan=lifespan)

    # --- REST endpoint for simple curl access ---
    @app.post("/ask")
    async def ask(request: dict):
        query = request.get("query", "")
        if not query:
            return JSONResponse(status_code=400, content={"error": "query field is required"})
        response = invoke_agent(query)
        return {"response": response}

    @app.get("/health")
    async def health():
        return {"status": "healthy", "role": AGENT_ROLE, "data_dir": DATA_DIR}

    # --- MCP endpoint (Streamable HTTP) ---
    app.mount("/mcp", mcp_server.streamable_http_app())

    return app


if __name__ == "__main__":
    if "--serve" in sys.argv:
        import uvicorn
        app = create_app()
        uvicorn.run(app, host="0.0.0.0", port=8080)
    elif len(sys.argv) > 1:
        query = " ".join(a for a in sys.argv[1:] if a != "--serve")
        print(invoke_agent(query))
    else:
        print(f"Agent ready: {AGENT_ROLE}")
        print(f"Data directory: {DATA_DIR}")
        print(f"Run with --serve to start HTTP/MCP server on port 8080")
        print("Type your questions (Ctrl+C to exit):\n")
        while True:
            try:
                user_input = input("You: ")
                print(f"\nAgent: {invoke_agent(user_input)}\n")
            except KeyboardInterrupt:
                break
