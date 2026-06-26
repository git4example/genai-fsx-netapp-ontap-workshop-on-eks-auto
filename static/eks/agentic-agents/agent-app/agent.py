import os
import glob
from strands import Agent, tool
from strands.models.openai import OpenAIModel

model = OpenAIModel(
    client_kwargs={
        "base_url": os.environ.get("LLM_ENDPOINT", "http://vllm-mistral7b-service.default.svc.cluster.local:8000/v1"),
        "api_key": "not-needed"
    },
    model_id="mistral-7b-neuron"
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


agent = Agent(
    model=model,
    tools=[list_files, read_file, search_documents],
    system_prompt=f"""You are a {AGENT_ROLE}. You have access to a data volume with documents relevant to your role.

Use your tools to:
- list_files: See what's available in your data directory
- read_file: Read specific documents
- search_documents: Search for keywords across all documents

Always use your tools to access data. If you get ACCESS DENIED errors, report them clearly — you are not authorized to access that data.
Do NOT make up or hallucinate data. Only report what your tools return."""
)


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        query = " ".join(sys.argv[1:])
        response = agent(query)
        print(response)
    else:
        print(f"Agent ready: {AGENT_ROLE}")
        print(f"Data directory: {DATA_DIR}")
        print("Type your questions (Ctrl+C to exit):\n")
        while True:
            try:
                user_input = input("You: ")
                response = agent(user_input)
                print(f"\nAgent: {response}\n")
            except KeyboardInterrupt:
                break
