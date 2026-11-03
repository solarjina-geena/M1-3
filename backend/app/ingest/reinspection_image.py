"""최종검사 일보 비고란 캡처 이미지 → Claude 가 재검사 항목을 읽는다 (미리보기 전용, DB 에 쓰지 않음).

화면(관리 화면 '최종검사 재검사' 탭)이 긴 변 1,568px JPEG 로 줄여 보낸다. 읽은 값은 'AI 판독값 — 사람 확인 전'이고,
사람이 모델·LOT·본검사를 고르고 저장해야 m13_reinspection_save 로 들어간다.
마킹코드(ZIC 등)는 조견표 규칙으로 CA 제품 LOT 날짜를 계산하되, 한 글자라도 못 읽으면 날짜를 만들지 않는다(추정 금지).
"""
from __future__ import annotations

import base64
import json
import re

import anthropic

from ..config import settings
from .journal_payload import marking_code_date, norm_date

PROMPT = """이 이미지는 iMEB3 최종검사 작업일보의 '비고'란을 캡처한 것입니다. 비고란에는 이미 검사한 LOT 을 다시 보는
재검사(재검, 현미경검사, 선별) 내용이 손글씨로 적혀 있습니다. 재검사 한 건마다 항목을 하나씩 만드세요.

읽을 것:
- model: IV / OV / HSV 중 적혀 있는 것. 적혀 있지 않으면 UNKNOWN (추측 금지).
- date_raw: 재검 날짜가 적혀 있으면 원문 그대로('9/23', '26.09.23'). 없으면 null.
- method: '현미경'이면 MICROSCOPE, '재검·선별·육안'이면 VISUAL, 모르면 UNKNOWN.
- lots: 대상 LOT 마다 한 줄. mark = 적힌 그대로(세 글자 마킹코드 예 ZIC·ZH4, 또는 LOT 코드 260903D1, 못 읽은 글자는 '?' 예 'Z?C'),
  box_count = 그 LOT 옆 BOX 수(예 'ZIO : 16 Box' → 16), qty_ea = 그 LOT 의 낱개 수가 적혀 있을 때만.
- qty_raw: 재검 합계 수량 원문('=> 38,400EA', '2BOX'), qty_ea: 합계 낱개 수가 숫자로 적혀 있을 때만, box_count: 합계 BOX 수가 적혀 있을 때만.
- defects: 재검에서 나온 불량 이름(원문 그대로, 예 'L/C 찍힘')과 수량('불량: 173EA' → 173). 불량명이 재검 제목에만 있으면(예 'L/C 찍힘 재검 … 불량 173EA') 그 이름을 씁니다. 수량을 못 읽으면 null.
- raw_text: 그 항목에 해당하는 비고 원문 전체.
규칙: 적힌 그대로 읽고 합산·환산하지 않습니다. 사람 이름은 적지 않습니다. 재검과 무관한 메모는 uncertain_notes 에 짧게 남깁니다."""

SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["entries", "uncertain_notes"],
    "properties": {
        "entries": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["model", "date_raw", "method", "lots", "qty_raw", "qty_ea", "box_count", "defects", "raw_text"],
            "properties": {
                "model": {"type": "string", "enum": ["IV", "OV", "HSV", "UNKNOWN"]},
                "date_raw": {"type": ["string", "null"]},
                "method": {"type": "string", "enum": ["VISUAL", "MICROSCOPE", "UNKNOWN"]},
                "lots": {"type": "array", "items": {"type": "object", "additionalProperties": False, "required": ["mark", "box_count", "qty_ea"],
                                                    "properties": {"mark": {"type": "string"}, "box_count": {"type": ["integer", "null"]}, "qty_ea": {"type": ["integer", "null"]}}}},
                "qty_raw": {"type": ["string", "null"]},
                "qty_ea": {"type": ["integer", "null"]},
                "box_count": {"type": ["integer", "null"]},
                "defects": {"type": "array", "items": {"type": "object", "additionalProperties": False, "required": ["name_raw", "qty"],
                                                       "properties": {"name_raw": {"type": "string"}, "qty": {"type": ["integer", "null"]}}}},
                "raw_text": {"type": "string"},
            }}},
        "uncertain_notes": {"type": "array", "items": {"type": "string"}},
    },
}

EA_PER_BOX = 480   # 최종검사 수량 규칙: BOX × 480 + 낱개


def resolve_mark(mark: str, base: str | None) -> dict:
    """LOT 표기 하나 → CA 제품 LOT 날짜/코드. 못 읽은 글자가 있으면 날짜 없음."""
    m = (mark or "").strip().upper()
    if re.fullmatch(r"\d{6}[DN]\d+", m):
        return {"mark": m, "lot_code": m, "lot_date": f"20{m[:2]}-{m[2:4]}-{m[4:6]}", "how": "LOT 코드 그대로"}
    d = marking_code_date(m, base)
    if d:
        return {"mark": m, "lot_code": None, "lot_date": d, "how": f"마킹코드 {m} → 조견표 CA 제품 LOT 날짜 {d}"}
    return {"mark": m, "lot_code": None, "lot_date": None, "how": "읽지 못한 글자가 있어 날짜를 정하지 않음 — LOT 을 직접 고르세요"}


async def read_reinspection_note(data: bytes, media_type: str, base_date: str | None) -> dict:
    if not settings.anthropic_key:
        raise RuntimeError("ANTHROPIC_API_KEY 가 없습니다.")
    b64 = base64.standard_b64encode(data).decode("utf-8")
    async with anthropic.AsyncAnthropic(api_key=settings.anthropic_key, timeout=90.0, max_retries=0) as client:
        resp = await client.messages.create(
            model=settings.anthropic_model, max_tokens=4000,
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": b64}},
                {"type": "text", "text": PROMPT + (f"\n\n참고: 이 일보의 검사일은 {base_date} 입니다." if base_date else "")}]}],
            output_config={"format": {"type": "json_schema", "schema": SCHEMA}},
        )
    if resp.stop_reason == "refusal":
        raise RuntimeError("모델이 이 요청을 거절했습니다(refusal).")
    out = json.loads("".join(b.text for b in resp.content if b.type == "text"))
    for e in out["entries"]:
        e["date"] = norm_date(e.get("date_raw"), base_date) if e.get("date_raw") else None
        base = e["date"] or base_date
        e["lots"] = [{**resolve_mark(x.get("mark", ""), base), "box_count": x.get("box_count"), "qty_ea": x.get("qty_ea")} for x in e.get("lots") or []]
        if e.get("box_count") is None and e["lots"] and all(x.get("box_count") is not None for x in e["lots"]):
            e["box_count"] = sum(x["box_count"] for x in e["lots"])
        if e.get("qty_ea") is None and e.get("box_count") is not None:
            e["qty_ea_suggested"] = e["box_count"] * EA_PER_BOX
            e["qty_note"] = f"BOX {e['box_count']} × {EA_PER_BOX} (최종검사 수량 규칙) — 확인 후 저장"
    return {**out, "ai_generated": True, "model": resp.model,
            "usage": {"input_tokens": resp.usage.input_tokens, "output_tokens": resp.usage.output_tokens}}
