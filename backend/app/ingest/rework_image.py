"""리워크 작업일보(CA 공정) 사진·PDF → Claude 판독 (2026-11-07 팀장 요청).

양식: 날짜 + 모델(IV·OV·HSV)마다 두 칸
  - 용접부 리워크: 총불량수량 · 진성불량(수량 + 유형 손글씨) · 가성불량 · 투입수량 · S/N(마킹코드 + 시리얼 시작~끝)
  - 조립부 리워크: 유형(저항·깊이·내경·마킹) × 수량·진성불량·가성불량, 총수량, S/N, 작업자
결과는 칸 하나 = 리워크 1건(rework_record). 사람 이름은 가린 이름만 돌려준다(원문은 버림).
"""
from __future__ import annotations

import base64
import json
import re

import anthropic

from ..config import settings
from .image import _json_text, file_name_date
from .journal_payload import mask_person
from .reinspection_image import resolve_mark

PROMPT = """이 이미지는 iMEB3 '리워크 작업일보'입니다. 날짜와, 모델(IV·OV·HSV) 라인마다 '용접부 리워크' 칸과 '조립부 리워크' 칸이 있습니다.
용접부 리워크 = 보빈아세이(BA) 상태 제품을 넣어 BA 에서 리워크한 기록(총불량 → 진성/가성 → 양품을 CA 공정에 투입), 조립부 리워크 = 그 제품이 압입(CA) 공정을 지나며 나온 불량 유형·수량.
값이 하나라도 적힌 칸만 blocks 에 넣습니다(완전히 빈 칸은 넣지 않음). 숫자는 적힌 그대로, 못 읽으면 null 로 두고 uncertain_notes 에 적습니다.

- 용접부 리워크(part = "WELD"): total_qty=총불량수량, true_qty=진성불량 수량, true_types=진성불량 칸 옆에 손글씨로 적힌 유형과 수량
  (예: '권선불량 4' → [{"name":"권선불량","qty":4}], 'pin찍힘 9EA' → [{"name":"핀찍힘","qty":9}], 유형만 있고 수량이 없으면 qty=null),
  false_qty=가성불량, input_qty=투입수량.
- 조립부 리워크(part = "ASSEMBLY"): rows = 유형 줄(저항·깊이·내경·마킹)마다 {"type": 유형, "qty": 수량, "true": 진성불량, "false": 가성불량} — 빈 줄은 빼기.
  total_qty/true_qty/false_qty = '총수량' 줄. 줄 옆 손글씨 메모는 note 에.
- S/N 칸: 'ZJL 119875-119932' 같은 표기 → mark="ZJL"(영문·숫자 마킹코드 3글자), serial_start="119875", serial_end="119932". 마킹이 뒤에 붙어도 같음.
  끝 번호가 앞자리를 생략해 짧게 적혀 있으면 시작 번호 앞자리를 붙여 완성하고 uncertain_notes 에 적습니다.
- 작업자(조립부 리워크 옆 '작업자:')는 workers 에 이름 그대로(서버가 가립니다). 이름을 note 등 다른 칸에 옮겨 적지 않습니다.
- raw 에는 그 칸의 글자를 짧게 그대로 적습니다(이름 제외).

JSON 하나만 출력:
{"work_date": "YYYY-MM-DD 또는 null", "workers": ["..."],
 "blocks": [{"model": "IV|OV|HSV", "part": "WELD|ASSEMBLY", "total_qty": 0, "true_qty": 0, "true_types": [{"name": "", "qty": 0}],
             "false_qty": 0, "input_qty": 0, "rows": [{"type": "", "qty": 0, "true": 0, "false": 0}],
             "mark": "", "serial_start": "", "serial_end": "", "note": "", "raw": ""}],
 "uncertain_notes": ["..."]}"""


def _int(v):
    try:
        return None if v in (None, "") else int(float(str(v).replace(",", "")))
    except ValueError:
        return None


def _findings(b: dict) -> list[dict]:
    """진성(유형별)·가성 → 리워크 재검 불량 줄."""
    out = []
    if b["part"] == "WELD":
        named = 0
        for t in b.get("true_types") or []:
            q = _int(t.get("qty"))
            if t.get("name") and q:
                out.append({"class": "TRUE", "name": str(t["name"]).strip(), "qty": q}); named += q
        if (b.get("true_qty") or 0) > named:
            out.append({"class": "TRUE", "name": None, "qty": b["true_qty"] - named})
        if b.get("false_qty"):
            out.append({"class": "FALSE", "name": "가성", "qty": b["false_qty"]})
    else:
        for r in b.get("rows") or []:
            t = str(r.get("type") or "").strip()
            if _int(r.get("true")):
                out.append({"class": "TRUE", "name": t + " 불량" if t else None, "qty": _int(r.get("true"))})
            if _int(r.get("false")):
                out.append({"class": "FALSE", "name": t + " 가성" if t else "가성", "qty": _int(r.get("false"))})
    return out


def normalize(raw: dict, filename: str) -> dict:
    fdate = file_name_date(filename)
    date = fdate or raw.get("work_date")
    workers = [mask_person(str(w)) for w in (raw.get("workers") or []) if w]
    names = [str(w) for w in (raw.get("workers") or []) if w]
    blocks = []
    for k, b in enumerate(raw.get("blocks") or []):
        if not isinstance(b, dict) or b.get("model") not in ("IV", "OV", "HSV") or b.get("part") not in ("WELD", "ASSEMBLY"):
            continue
        x = {"key": f"b{k}", "model": b["model"], "part": b["part"], "work_date": date,
             "total_qty": _int(b.get("total_qty")), "true_qty": _int(b.get("true_qty")), "false_qty": _int(b.get("false_qty")),
             "input_qty": _int(b.get("input_qty")),
             "true_types": [{"name": t.get("name"), "qty": _int(t.get("qty"))} for t in (b.get("true_types") or []) if isinstance(t, dict)],
             "rows": [{"type": r.get("type"), "qty": _int(r.get("qty")), "true": _int(r.get("true")), "false": _int(r.get("false"))}
                      for r in (b.get("rows") or []) if isinstance(r, dict)],
             "mark": (b.get("mark") or "").strip().upper() or None,
             "serial_start": re.sub(r"\D", "", str(b.get("serial_start") or "")) or None,
             "serial_end": re.sub(r"\D", "", str(b.get("serial_end") or "")) or None,
             "note": b.get("note") or None, "raw": b.get("raw") or None,
             "workers_masked": workers if b["part"] == "ASSEMBLY" else []}
        for n in names:   # 메모에 이름이 섞이면 가린다
            for f in ("note", "raw"):
                if x[f] and n in x[f]:
                    x[f] = x[f].replace(n, mask_person(n))
        m = resolve_mark(x["mark"], date) if x["mark"] else {}
        x["mark_date"] = m.get("lot_date")
        x["mark_how"] = m.get("how")
        x["ca_lot_code"] = (m["lot_date"][2:4] + m["lot_date"][5:7] + m["lot_date"][8:10] + "D1") if m.get("lot_date") else None
        checks = []
        if x["serial_start"] and x["serial_end"] and int(x["serial_end"]) < int(x["serial_start"]):
            checks.append("S/N 끝이 시작보다 작음")
        t, f = x["true_qty"] or 0, x["false_qty"] or 0
        if x["total_qty"] is not None and (t or f) and x["total_qty"] != t + f:
            checks.append(f"총 {x['total_qty']} ≠ 진성 {t} + 가성 {f}")
        if x["part"] == "WELD" and x["input_qty"] is not None and f and x["input_qty"] != f:
            checks.append(f"투입 {x['input_qty']} ≠ 가성 {f}")
        if x["serial_start"] and x["serial_end"]:
            n = int(x["serial_end"]) - int(x["serial_start"]) + 1
            want = x["input_qty"] if x["part"] == "WELD" else x["total_qty"]
            x["serial_count"] = n
        if x["mark"] and not x["mark_date"]:
            checks.append("마킹코드를 날짜로 풀지 못함(CA LOT 미연결로 저장)")
        x["check"] = " · ".join(checks) or None
        x["findings"] = _findings(x)
        blocks.append(x)
    # 시작 투입수량(양식에 칸이 없어 기본값을 넣고 화면에서 고친다, 팀장 2026-11-07): 용접부 = 총불량수량, 조립부 = 같은 모델 용접부의 CA 투입수량
    for x in blocks:
        if x["part"] == "WELD":
            x["start_qty"] = x["total_qty"]
        else:
            w = next((y for y in blocks if y["part"] == "WELD" and y["model"] == x["model"]), None)
            x["start_qty"] = w["input_qty"] if w else None
    notes = [str(n) for n in raw.get("uncertain_notes") or []]
    for n in names:
        notes = [s.replace(n, mask_person(n)) for s in notes]
    return {"work_date": date, "date_source": "FILE" if fdate else "AI", "blocks": blocks, "uncertain_notes": notes}


async def read_rework(data: bytes, media_type: str, filename: str) -> dict:
    if not settings.anthropic_key:
        raise RuntimeError("ANTHROPIC_API_KEY 가 없습니다.")
    b64 = base64.standard_b64encode(data).decode("utf-8")
    block = ({"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": b64}}
             if media_type == "application/pdf" else {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": b64}})
    async with anthropic.AsyncAnthropic(api_key=settings.anthropic_key, timeout=150.0, max_retries=0) as client:
        resp = await client.messages.create(
            model=settings.anthropic_model, max_tokens=8000,
            system="응답은 JSON 객체 하나만 출력합니다. 코드 블록 표시나 설명 문장을 붙이지 않습니다.",
            messages=[{"role": "user", "content": [block, {"type": "text", "text": PROMPT + f"\n\n파일 이름: {filename}"}]}])
    if resp.stop_reason == "refusal":
        raise RuntimeError("모델이 이 요청을 거절했습니다(refusal).")
    text = "".join(b.text for b in resp.content if b.type == "text")
    try:
        raw = json.loads(_json_text(text))
    except ValueError as e:
        raise RuntimeError(f"모델 응답을 JSON 으로 읽을 수 없습니다: {e}") from e
    out = normalize(raw if isinstance(raw, dict) else {}, filename)
    out["usage"] = {"input_tokens": resp.usage.input_tokens, "output_tokens": resp.usage.output_tokens}
    return out
