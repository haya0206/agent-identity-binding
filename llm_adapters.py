"""상용 모델(gpt-6-luna 등)을 Vanna v2.0.2에 꽂기 위한 LLM 서비스 어댑터.

IdentityBoundPostgresRunner와 같은 방침 -- site-packages를 건드리지 않고
서브클래스로만 바꾼다. 프롬프트·툴 스키마·에이전트 루프는 그대로다.

왜 필요한가
-----------
gpt-6-luna는 /v1/chat/completions 에서 function tool 과 reasoning 을 동시에
쓸 수 없다. 실제 400 응답:

    Function tools with reasoning_effort are not supported for gpt-6-luna in
    /v1/chat/completions. To use function tools, use /v1/responses or set
    reasoning_effort to 'none'.

그래서 두 경로를 모두 제공한다.

  ChatNoReasoningLlmService  -- chat.completions + reasoning_effort='none'
      reasoning 이 꺼진다. 대신 vLLM/Qwen 베이스라인과 **완전히 같은 코드
      경로**를 쓰므로 base_url 과 model 만 다른 비교가 된다.

  ResponsesLlmService        -- /v1/responses, reasoning 켜짐
      Vanna 2.0.2 의 OpenAIResponsesService 를 쓸 수 없어 다시 구현했다.
      그쪽 _extract() 는 툴콜을 output[].content[].tool_call.function 에서
      찾는데, 실제 Responses API 는 최상위 output 항목으로

          output[0].type == 'function_call'
          output[0].name, output[0].arguments

      를 돌려준다. 따라서 원본 파서는 **툴콜을 항상 0개로 읽는다**. 그 상태로
      실험을 돌리면 에이전트가 SQL 을 한 번도 실행하지 않아 세 조건 모두
      n_sql=0 / 노출 0 이 되고, 완벽한 방어처럼 보이지만 사실은 어댑터가
      고장난 것이다. (2026-10-01 gpt-6-luna 로 실측 확인)
      원본은 base_url 도 받지 않아 vLLM 을 가리킬 수 없다.

선택
----
    LLM_BACKEND=chat       기존 OpenAILlmService (vLLM/Qwen 베이스라인; 기본값)
    LLM_BACKEND=chat_noreason
    LLM_BACKEND=responses
"""
from __future__ import annotations

import json
import os
from typing import Any, AsyncGenerator, Dict, List, Optional

from vanna.core.llm import LlmRequest, LlmResponse, LlmService, LlmStreamChunk
from vanna.core.tool import ToolCall, ToolSchema
from vanna.integrations.openai import OpenAILlmService


class ChatNoReasoningLlmService(OpenAILlmService):
    """chat.completions, reasoning off. 베이스라인과 같은 코드 경로."""

    def _build_payload(self, request: LlmRequest) -> Dict[str, Any]:
        payload = super()._build_payload(request)
        payload["reasoning_effort"] = "none"
        return payload


class ResponsesLlmService(LlmService):
    """/v1/responses. reasoning 켜진 채로 tool calling 이 된다."""

    def __init__(
        self,
        model: Optional[str] = None,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        reasoning_effort: Optional[str] = None,
    ) -> None:
        from openai import AsyncOpenAI

        kwargs: Dict[str, Any] = {}
        if api_key or os.getenv("OPENAI_API_KEY"):
            kwargs["api_key"] = api_key or os.getenv("OPENAI_API_KEY")
        if base_url:
            kwargs["base_url"] = base_url
        self.client = AsyncOpenAI(**kwargs)
        self.model = model or os.getenv("OPENAI_MODEL", "gpt-6-luna")
        self.reasoning_effort = reasoning_effort

    async def send_request(self, request: LlmRequest) -> LlmResponse:
        resp = await self.client.responses.create(**self._payload(request))
        text, tools = self._extract(resp)
        return LlmResponse(
            content=text,
            tool_calls=tools or None,
            finish_reason=getattr(resp, "status", None),
            usage=self._usage(resp),
            metadata={"request_id": getattr(resp, "id", None)},
        )

    async def stream_request(
        self, request: LlmRequest
    ) -> AsyncGenerator[LlmStreamChunk, None]:
        # 실험은 send_request 만 쓴다. 스트리밍은 비스트리밍 1회로 대신한다.
        resp = await self.send_request(request)
        yield LlmStreamChunk(
            content=resp.content,
            tool_calls=resp.tool_calls,
            finish_reason=resp.finish_reason,
        )

    async def validate_tools(self, tools: List[Any]) -> List[str]:
        return []

    # ---- helpers ----

    def _payload(self, request: LlmRequest) -> Dict[str, Any]:
        # Responses API 는 툴 왕복을 role 메시지가 아니라 전용 항목으로 주고받는다.
        #   어시스턴트 툴콜 -> {"type":"function_call",        "call_id", "name", "arguments"}
        #   툴 실행 결과    -> {"type":"function_call_output", "call_id", "output"}
        # chat.completions 의 role="tool" + tool_call_id 를 그대로 넘기면 왕복이 끊긴다.
        items: List[Dict[str, Any]] = []
        for m in request.messages:
            if m.role == "tool":
                items.append(
                    {
                        "type": "function_call_output",
                        "call_id": m.tool_call_id,
                        "output": m.content or "",
                    }
                )
                continue
            if m.role == "assistant" and m.tool_calls:
                if m.content:
                    items.append({"role": "assistant", "content": m.content})
                for tc in m.tool_calls:
                    items.append(
                        {
                            "type": "function_call",
                            "call_id": tc.id,
                            "name": tc.name,
                            "arguments": json.dumps(tc.arguments, ensure_ascii=False),
                        }
                    )
                continue
            items.append({"role": m.role, "content": m.content})

        p: Dict[str, Any] = {"model": self.model, "input": items}
        if request.system_prompt:
            p["instructions"] = request.system_prompt
        if request.max_tokens:
            p["max_output_tokens"] = request.max_tokens
        if request.tools:
            p["tools"] = [self._serialize_tool(t) for t in request.tools]
        if self.reasoning_effort:
            p["reasoning"] = {"effort": self.reasoning_effort}
        return p

    @staticmethod
    def _extract(resp: Any):
        """툴콜은 최상위 output 항목(type='function_call')으로 온다.

        id 는 반드시 call_id 를 쓴다. 다음 턴의 function_call_output 이 이 값으로
        짝을 찾으므로, 항목 자체의 id(fc_...)를 쓰면 왕복이 깨진다.
        """
        text = getattr(resp, "output_text", None)
        calls: List[ToolCall] = []
        for item in getattr(resp, "output", None) or []:
            if getattr(item, "type", None) != "function_call":
                continue
            args = getattr(item, "arguments", None)
            if not isinstance(args, (dict, list)):
                try:
                    args = json.loads(args) if args else {}
                except json.JSONDecodeError:
                    args = {"_raw": args}
            call_id = getattr(item, "call_id", None) or getattr(item, "id", None) or ""
            calls.append(
                ToolCall(id=call_id, name=getattr(item, "name", None), arguments=args)
            )
        return text, calls

    @staticmethod
    def _usage(resp: Any) -> Optional[Dict[str, int]]:
        u = getattr(resp, "usage", None)
        if not u:
            return None
        return {
            "input_tokens": getattr(u, "input_tokens", 0) or 0,
            "output_tokens": getattr(u, "output_tokens", 0) or 0,
            "total_tokens": getattr(u, "total_tokens", 0) or 0,
        }

    @staticmethod
    def _serialize_tool(tool: Any) -> Dict[str, Any]:
        if isinstance(tool, ToolSchema):
            return {
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters,
                "strict": False,
            }
        if isinstance(tool, dict):
            if "type" in tool:
                return tool
            return {
                "type": "function",
                "name": tool["name"],
                "description": tool["description"],
                "parameters": tool["parameters"],
                "strict": tool.get("strict", False),
            }
        if hasattr(tool, "model_dump"):
            d = tool.model_dump()
            return {
                "type": "function",
                "name": d["name"],
                "description": d["description"],
                "parameters": d["parameters"],
                "strict": d.get("strict", False),
            }
        raise TypeError(f"Unsupported tool schema type: {type(tool)!r}")


def build_llm():
    """LLM_BACKEND 환경변수로 백엔드를 고른다."""
    backend = os.getenv("LLM_BACKEND", "chat")
    model = os.environ["VLLM_MODEL"]
    api_key = os.getenv("OPENAI_API_KEY", "dummy")
    base_url = os.getenv("VLLM_BASE_URL", "http://localhost:8000/v1")

    if backend == "chat":
        return OpenAILlmService(model=model, api_key=api_key, base_url=base_url)
    if backend == "chat_noreason":
        return ChatNoReasoningLlmService(model=model, api_key=api_key, base_url=base_url)
    if backend == "responses":
        # 공식 엔드포인트면 base_url 을 넘기지 않는다(SDK 기본값 사용).
        bu = None if "api.openai.com" in base_url else base_url
        return ResponsesLlmService(
            model=model,
            api_key=api_key,
            base_url=bu,
            reasoning_effort=os.getenv("REASONING_EFFORT") or None,
        )
    raise SystemExit(f"unknown LLM_BACKEND={backend!r} (chat|chat_noreason|responses)")
