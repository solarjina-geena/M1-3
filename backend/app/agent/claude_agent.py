"""대시보드 AI 창. Claude 가 도구(저장소 조회 함수)를 불러 답한다. 숫자는 항상 DB 조회 결과에서만 나온다.

- 도구 이름은 팀 챗봇 규약(docs/team/chatbot.md)의 함수명을 따른다: get_production_summary, get_lot_history, get_quality_results ...
- 읽기 전용. 이 창에서는 DB 에 쓰지 않는다.
"""
from __future__ import annotations

import json
from typing import Any

import anthropic

from ..config import settings
from ..repository.base import PROCESS_LABEL, Repository

SYSTEM = """당신은 제조 품질 데이터 분석 도우미입니다. 제품은 모델명 IV/OV/HSV 로만 부르고 제품 상표명은 답변에 쓰지 않습니다. 데이터는 Supabase mqi 스키마에 있고, 도구로만 조회합니다.
규칙:
- 숫자·날짜·LOT 코드는 반드시 도구 결과에서 가져옵니다. 도구가 돌려주지 않은 수치는 말하지 않습니다.
- 데이터 상태를 함께 말합니다: 연결은 CANDIDATE(후보)인지 CONFIRMED(확인)인지, 값은 UNVERIFIED/NEEDS_REVIEW 인지.
- 빈칸은 0 이 아닙니다. 기록이 없으면 "기록 없음"이라고 합니다.
- 공정 코드 표기: IMEB3_INJECTION=사출, IMEB3_STITCHING=스티칭, IMEB3_WINDING=권선(BA), IMEB3_CA_PRESS=압입(CA), IMEB3_FINAL_INSPECTION=최종검사.
- LOT 사슬이 끊긴 이유를 물으면 get_lot_chain_gaps 의 first_gap 을 그대로 전달합니다.
- LOT 표기: DB 의 LOT 코드는 YYMMDD+교대(D/N)+순번(예 260903D1 = 2026-09-03 주간 1번). 최종검사 일보의 세 글자 마킹코드(예 ZIC)는 조견표 규칙(Z=2026년, 두 번째 글자=월 A..L, 세 번째=일 A..Z,2..6)으로 CA 제품 LOT 날짜를 뜻합니다. get_lot_history 에 마킹코드나 날짜를 그대로 넣으면 변환해서 찾습니다. 결과의 resolved.how 를 한 줄로 알려 줍니다.
- 답은 화면에 평문으로 보입니다. 마크다운 기호(**, #, |표)를 쓰지 말고 짧은 문장과 '- ' 목록으로 씁니다. 도구 결과의 내부 키 이름(found, first_gap 같은 영문)은 그대로 쓰지 말고 우리말로 풀어 씁니다.
- 한국어로 간결하게 답합니다."""

TOOLS: list[dict[str, Any]] = [
    {"name": "get_production_summary", "description": "공정별 생산량·불량·작업일수 합계와 LOT 사슬 현황. model 을 주면 그 모델만.",
     "input_schema": {"type": "object", "properties": {"model": {"type": "string", "enum": ["IV", "OV", "HSV"]}}, "additionalProperties": False}, "strict": True},
    {"name": "get_process_series", "description": "한 공정의 일자별 생산량(또는 검사량)·불량·작업시간 시계열.",
     "input_schema": {"type": "object", "properties": {"process": {"type": "string", "enum": list(PROCESS_LABEL)}, "model": {"type": "string", "enum": ["IV", "OV", "HSV"]},
                                                       "date_from": {"type": "string"}, "date_to": {"type": "string"}},
                      "required": ["process"], "additionalProperties": False}, "strict": True},
    {"name": "get_quality_results", "description": "불량 유형별 수량 합계. process 를 비우면 전체.",
     "input_schema": {"type": "object", "properties": {"process": {"type": "string", "enum": list(PROCESS_LABEL)}, "model": {"type": "string", "enum": ["IV", "OV", "HSV"]},
                                                       "date_from": {"type": "string"}, "date_to": {"type": "string"}}, "additionalProperties": False}, "strict": True},
    {"name": "get_lot_history", "description": "LOT 하나의 상위·하위 연결, 투입 자재, 최종검사 결과. lot_code 에는 LOT 코드(260903D1), 최종검사 마킹코드(ZIC), 날짜(2026-09-03, 9/3) 중 아무거나 넣어도 된다.",
     "input_schema": {"type": "object", "properties": {"lot_code": {"type": "string"}, "model": {"type": "string", "enum": ["IV", "OV", "HSV"]}},
                      "required": ["lot_code"], "additionalProperties": False}, "strict": True},
    {"name": "get_lot_chain_gaps", "description": "CA 제품 LOT 마다 수지→사출→스티칭→권선→압입 사슬이 어디까지 이어졌는지와 끊긴 첫 자리(first_gap).",
     "input_schema": {"type": "object", "properties": {"model": {"type": "string", "enum": ["IV", "OV", "HSV"]}, "only_gaps": {"type": "boolean"}, "limit": {"type": "integer"}},
                      "additionalProperties": False}, "strict": True},
]


def run_tool(repo: Repository, name: str, args: dict) -> Any:
    if name == "get_production_summary":
        return repo.summary(args.get("model"))
    if name == "get_process_series":
        return repo.process_series(args["process"], args.get("model"), args.get("date_from"), args.get("date_to"))
    if name == "get_quality_results":
        return repo.defects(args.get("process"), args.get("model"), args.get("date_from"), args.get("date_to"))[:40]
    if name == "get_lot_history":
        return repo.lot_trace(args["lot_code"], args.get("model"))
    if name == "get_lot_chain_gaps":
        rows = repo.chain_gaps(args.get("model"), bool(args.get("only_gaps")))
        return rows[: int(args.get("limit") or 30)]
    raise ValueError(f"unknown tool {name}")


def chat(repo: Repository, history: list[dict], question: str) -> dict:
    """history: [{role, content(str)}] 이전 대화. 반환: {answer, tool_calls, usage, model}"""
    if not settings.anthropic_key:
        return {"answer": "ANTHROPIC_API_KEY 가 설정되지 않아 AI 답변을 할 수 없습니다. backend/.env.personal 에 키를 넣어 주세요.", "tool_calls": [], "usage": None, "model": None}
    client = anthropic.Anthropic(api_key=settings.anthropic_key)
    messages = [{"role": m["role"], "content": m["content"]} for m in history[-8:] if m.get("role") in ("user", "assistant") and m.get("content")]
    messages.append({"role": "user", "content": question})
    tool_calls = []
    usage = {"input_tokens": 0, "output_tokens": 0}
    response = None
    for _ in range(8):
        try:
            # 거절(refusal) 시 서버가 다른 모델로 이어서 답하도록 fallbacks 를 켠다.
            response = client.beta.messages.create(
                model=settings.anthropic_model, max_tokens=8000, system=SYSTEM, tools=TOOLS, messages=messages,
                output_config={"effort": "medium"},
                betas=["server-side-fallback-2026-07-01"], fallbacks="default",
            )
        except anthropic.AuthenticationError:
            return {"answer": "Anthropic API 키가 올바르지 않습니다.", "tool_calls": tool_calls, "usage": usage, "model": settings.anthropic_model}
        except anthropic.RateLimitError:
            return {"answer": "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.", "tool_calls": tool_calls, "usage": usage, "model": settings.anthropic_model}
        except anthropic.APIStatusError as e:
            return {"answer": f"AI 호출 오류({e.status_code}): {e.message}", "tool_calls": tool_calls, "usage": usage, "model": settings.anthropic_model}
        except anthropic.APIConnectionError:
            return {"answer": "AI 서버에 연결할 수 없습니다(네트워크).", "tool_calls": tool_calls, "usage": usage, "model": settings.anthropic_model}
        usage["input_tokens"] += response.usage.input_tokens
        usage["output_tokens"] += response.usage.output_tokens
        if response.stop_reason == "refusal":
            return {"answer": "모델이 이 질문에 답하지 않았습니다(refusal).", "tool_calls": tool_calls, "usage": usage, "model": response.model}
        uses = [b for b in response.content if b.type == "tool_use"]
        if not uses:
            break
        messages.append({"role": "assistant", "content": response.content})
        results = []
        for u in uses:
            try:
                out = run_tool(repo, u.name, dict(u.input))
                tool_calls.append({"tool": u.name, "input": dict(u.input), "rows": len(out) if isinstance(out, list) else 1})
                results.append({"type": "tool_result", "tool_use_id": u.id, "content": json.dumps(out, ensure_ascii=False, default=str)[:60000]})
            except Exception as e:  # noqa: BLE001
                tool_calls.append({"tool": u.name, "input": dict(u.input), "error": str(e)})
                results.append({"type": "tool_result", "tool_use_id": u.id, "content": f"error: {e}", "is_error": True})
        messages.append({"role": "user", "content": results})
    answer = "".join(b.text for b in response.content if b.type == "text") if response else ""
    return {"answer": answer or "(답변 없음)", "tool_calls": tool_calls, "usage": usage, "model": response.model if response else None}
