# diag.py
import asyncio, os
from vanna.integrations.openai import OpenAILlmService
from vanna.core.llm.models import LlmRequest, LlmMessage
from vanna.core.user import User
from vanna.tools import RunSqlTool
from identity_bound_runner import IdentityBoundPostgresRunner

async def main():
    llm = OpenAILlmService(model=os.environ["VLLM_MODEL"], api_key=os.getenv("OPENAI_API_KEY"),
                           base_url=os.getenv("VLLM_BASE_URL", "http://localhost:8000/v1"))
    tool = RunSqlTool(sql_runner=IdentityBoundPostgresRunner(mode="shared", host="localhost", database="agentdb", user="agent_shared", password="x"))
    schema = tool.get_schema() if hasattr(tool, "get_schema") else tool.schema
    req = LlmRequest(messages=[LlmMessage(role="system", content="Use run_sql to answer."),
                               LlmMessage(role="user", content="How many rows are in sales?")],
                     tools=[schema], user=User(id="alice"))
    r = await llm.send_request(req)
    print("content:", repr(r.content)); print("tool_calls:", r.tool_calls); print("finish:", r.finish_reason)
    print("--- stream ---")
    async for ch in llm.stream_request(req):
        print(repr(ch)[:200])

asyncio.run(main())