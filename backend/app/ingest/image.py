"""작업일보 사진/PDF 한 장 -> Claude 가 읽어 JournalPayload 목록으로 (미리보기 전용, DB 에 쓰지 않음).

팀 OCR 흐름(원본 → 추출값 → 사람 검토 → 업무 테이블)과 같은 의미다. 여기서는 추출을 Claude 비전이 맡고,
사람이 미리보기에서 승인해야 m13_journal_save 로 들어간다.
"""
from __future__ import annotations

import base64
import json
import re
from typing import Literal

import anthropic
from pydantic import BaseModel, Field, ValidationError

from ..config import settings
from .journal_payload import JournalPayload, scrub_names

PROMPT = """이 이미지는 iMEB3 제조 작업일보(사출·스티칭·조립(BA 권선/CA 압입)·최종검사 중 하나)입니다.
한 장에 여러 모델(IV/OV/HSV)이나 여러 공정·여러 라인(L1/L2)이 있으면 작업일보 항목을 여러 개로 나눠 주세요.
조립일보는 BA(권선)와 CA(압입)가 한 장에 같이 있습니다. BA 와 CA 를 각각 별도 항목으로 만들고 수량도 따로 적습니다(같은 날 같은 LOT).

공정별로 반드시 읽어야 하는 항목 (칸이 비어 있으면 raw 에 'BLANK', 못 읽으면 'UNCERTAIN' 이라고 적되 항목 자체는 빼지 마세요):
- 사출(BB, IMEB3_INJECTION): 생산량(주/야 따로면 둘 다), 수지(RESIN) LOT 과 사용량(kg), 수지 품명/코드(equipment_raw 나 raw 에), 설비/금형, 불량.
- 스티칭(BS, IMEB3_STITCHING): 생산량, 투입 보빈 LOT 날짜(inputs, component=BOBBIN), 리드핀(LEAD_PIN) 입고 LOT 날짜(materials), 불량(위치도·전장 등), 작업시간.
- 권선 BA(IMEB3_WINDING): 생산량, 인서트(리드핀 인서트 보빈) LOT 날짜(inputs, component=INSERT ← 스티칭 LOT), 보빈 LOT 날짜(inputs, component=BOBBIN),
  와이어(WIRE) LOT — 스핀들/열별로 날짜가 여러 개면 전부 materials 에 각각(spindle 표기), 리드핀 LOT 이 적혀 있으면 materials 에, 프로그램/턴/설비(equipment_raw),
  불량(비전1차·비전2차·용접·SET-UP 등), 작업시간, 비고.
- 압입 CA(IMEB3_CA_PRESS): 생산량, 상부/하부 케이스(UPPER_CASE/LOWER_CASE) LOT 날짜(materials), 불량(깊이·저항·내경 등), 작업시간,
  비고에 '리워크 N EA' 가 있으면 rework_qty / rework_note. BA 수량이 비어 있고 CA 만 있으면 리워크일 수 있으니 비고를 꼭 적습니다.
- 최종검사(IMEB3_FINAL_INSPECTION): 검사량, 검사자 이름(inspector_raw; 서버가 가립니다), 1차/2차 검사 표기(inspection_round),
  열(컬럼)마다 LOT 코드=BOX 수('ZH4=2BOX' 형태, lots), 불량 항목별 수량, 검사시간, 비고란 원문 전체(remarks_raw — 재검·현미경검사·보강 수량이 여기 있음).
  비고가 재검/현미경검사 내용이면 inspection_type=REINSPECTION 또는 inspection_method=MICROSCOPE 로 별도 항목을 만듭니다.

규칙:
- 숫자는 적힌 그대로 읽습니다. 읽을 수 없거나 불확실하면 그 항목은 비우고 raw 에 보이는 대로 적습니다. 추측해서 채우지 않습니다. 합산·조정하지 않습니다.
- 날짜 표기('8.28', '7/22', '26.9.4')는 raw 에 원문 그대로 두고 lot_date 는 비워도 됩니다(서버가 정규화).
- work_date 는 반드시 YYYY-MM-DD 형식으로 적습니다(연도가 없으면 요일·문맥으로 추정). 글자가 흐려 불확실하면 가장 그럴듯한 날짜를 적고 그 사정은 uncertain_notes 에 씁니다. work_date 에 'UNCERTAIN' 같은 글자를 넣지 않습니다.
- 모델이 IV/OV/HSV 중 어느 것인지 확실하지 않으면 그 항목을 만들지 말고 uncertain_notes 에 이유를 적습니다. OV/HSV 합산 양식이면 합산 수량을 나누지 않습니다.
- 사람 이름: 생산 공정의 작업자(작업자 칸·근무 현황)는 workers_raw 에 한 명씩(name, 역할을 알면 role: 작업자=OPERATOR, 셋업=SETUP, 반장·조장=SUPERVISOR),
  최종검사 검사자는 inspector_raw 에 적습니다. 서버가 가운데 글자를 가려 저장하고 원문은 버립니다. 이름을 비고·note 같은 다른 칸에 옮겨 적지 않습니다.
- 페이지에 있는데 위 항목에 없는 정보는 source.note 에 짧게 남깁니다.
"""


class Extraction(BaseModel):
    document_type: Literal["INJECTION", "STITCHING", "ASSEMBLY", "FINAL_INSPECTION", "UNKNOWN"]
    journals: list[JournalPayload] = Field(default_factory=list)
    uncertain_notes: list[str] = Field(default_factory=list)


def file_name_date(name: str | None) -> str | None:
    """파일명에 적힌 작업일(폴더 정리 규칙 '20260923-1.pdf' 등). 있으면 이것이 기준, 없으면 None(AI 판독 날짜로 보완).
    인식: 2026-09-23 · 2026.09.23 · 20260923 · 26.09.23 · 파일명 맨 앞 260923. 달력에 없는 날짜는 버린다."""
    import re
    from datetime import date
    n = (name or "").rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    if re.match(r"(?i)(kakaotalk|img|pxl|screenshot|스크린샷|photo|camera|scan)[_ -]", n):
        return None   # 메신저·카메라·스캐너가 붙인 저장 시각이지 작업일이 아니다 → AI 판독 날짜로 보완
    pats = [(r"(?<!\d)(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)", 1), (r"(?<!\d)(\d{2})\.(\d{1,2})\.(\d{1,2})(?!\d)", 2), (r"^(\d{2})(\d{2})(\d{2})(?!\d)", 2)]
    for pat, kind in pats:
        m = re.search(pat, n)
        if not m:
            continue
        y, mo, d = (int(g) for g in m.groups())
        if kind == 2:
            y += 2000
        try:
            return date(y, mo, d).isoformat()
        except ValueError:
            continue
    return None


def _json_text(text: str) -> str:
    """모델 응답에서 JSON 객체 부분만 떼어 낸다(코드 블록 표시나 앞뒤 설명이 붙어도 허용)."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t[3:]
        if t.rstrip().endswith("```"):
            t = t.rstrip()[:-3]
    a, b = t.find("{"), t.rfind("}")
    if a < 0 or b < a:
        raise RuntimeError("모델 응답에 JSON 객체가 없습니다: " + t[:200])
    return t[a:b + 1]


# 구조화 출력(output_config.format)은 이 스키마에서 'compiled grammar is too large'(HTTP 400)로 거절되므로,
# 스키마를 시스템 프롬프트로 주고 JSON 텍스트로 받아 pydantic 으로 검증한다.
SYSTEM = ("응답은 아래 JSON Schema 를 따르는 JSON 객체 하나만 출력합니다. 코드 블록 표시나 설명 문장을 붙이지 않습니다. "
          "스키마에 없는 키는 쓰지 않고, 값을 모르면 null 또는 빈 배열로 둡니다.\n"
          + json.dumps(Extraction.model_json_schema(), ensure_ascii=False))


KIND_KO = {"INJECTION": "사출", "STITCHING": "스티칭(BS)", "ASSEMBLY": "조립(BA 권선·CA 압입)", "FINAL_INSPECTION": "최종검사"}


async def extract_from_image(data: bytes, media_type: str, filename: str, kind: str | None = None) -> dict:
    """kind = 관리 화면에서 고른 작업일보 탭(사출·BS·조립·최종검사). Claude 에 힌트로 주고, 읽은 종류와 다르면 경고."""
    hint = (f"\n\n사용자가 고른 작업일보 종류: {KIND_KO[kind]} ({kind}). 이 종류로 읽되, 사진이 실제로 다른 종류면 "
            "document_type 은 사진 그대로 적고 uncertain_notes 에 그 사실을 씁니다.") if kind in KIND_KO else ""
    if not settings.anthropic_key:
        raise RuntimeError("ANTHROPIC_API_KEY 가 backend/.env.personal 에 없습니다.")
    b64 = base64.standard_b64encode(data).decode("utf-8")
    block = ({"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": b64}}
             if media_type == "application/pdf" else
             {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": b64}})
    # Async 요청은 브라우저 취소/연결 종료 시 백엔드에서도 취소할 수 있게 한다.
    # 제한 시간과 재시도 횟수를 고정해 관리 화면이 무기한 대기하지 않게 한다.
    async with anthropic.AsyncAnthropic(api_key=settings.anthropic_key, timeout=150.0, max_retries=0) as client:
        response = await client.messages.create(
            model=settings.anthropic_model,
            max_tokens=16000,
            system=SYSTEM,
            messages=[{"role": "user", "content": [block, {"type": "text", "text": PROMPT + hint + f"\n\n파일 이름: {filename} (이름에 날짜가 있으면 작업일·연도 추정에 참고하세요. 양식에는 연도가 없는 경우가 많습니다.)"}]}],
        )
    if response.stop_reason == "refusal":
        raise RuntimeError("모델이 이 요청을 거절했습니다(refusal).")
    if response.stop_reason == "max_tokens":
        raise RuntimeError("모델 응답이 길이 제한에 걸려 잘렸습니다. 한 장씩 올려 주세요.")
    text = "".join(b.text for b in response.content if b.type == "text")
    try:
        raw = json.loads(_json_text(text))
    except ValueError as e:
        raise RuntimeError(f"모델 응답을 JSON 으로 읽을 수 없습니다: {e}") from e
    if not isinstance(raw, dict):
        raise RuntimeError("모델 응답이 JSON 객체가 아닙니다.")
    doc_type = raw.get("document_type") if raw.get("document_type") in ("INJECTION", "STITCHING", "ASSEMBLY", "FINAL_INSPECTION") else "UNKNOWN"
    notes = [str(n) for n in raw.get("uncertain_notes") or []]
    if kind in KIND_KO and doc_type not in (kind, "UNKNOWN"):
        notes.insert(0, f"⚠ 고른 탭은 {KIND_KO[kind]} 작업일보인데 Claude 는 {KIND_KO.get(doc_type, doc_type)} 작업일보로 읽었습니다. 사진과 탭을 확인하세요.")
    # 작업일보 항목은 한 건씩 검증한다. 한 항목의 날짜 표기 오류가 나머지 항목까지 버리지 않게 하고,
    # 실패한 항목은 엑셀 업로드와 같은 모양(ok=False, error, raw)으로 화면에 보여 준다.
    items = []
    fdate = file_name_date(filename)   # 파일명 날짜가 있으면 기준(폴더 정리 규칙), 없으면 AI 가 읽은 날짜로 보완
    for k, jraw in enumerate(raw.get("journals") or []):
        try:
            if fdate and isinstance(jraw, dict):
                jraw = {**jraw, "work_date": fdate}
            j = JournalPayload.model_validate(jraw)
            j.source.method = "IMAGE"
            j.source.file = j.source.file or filename
            ai_date = (raw.get("journals") or [])[k].get("work_date") if isinstance((raw.get("journals") or [])[k], dict) else None
            items.append({"ok": True, "payload": j.model_dump(), "normalized": j.normalized(),
                          "date_source": "FILE" if fdate else "AI", "ai_work_date": ai_date})
        except ValidationError as e:
            first = e.errors()[0]
            loc = ".".join(str(x) for x in first.get("loc", ()))
            items.append({"ok": False, "row": k + 1, "error": f"{first.get('msg')} (항목 {loc})",
                          "raw": jraw if isinstance(jraw, dict) else {"value": str(jraw)}})
    # 불확실 메모에 사람 이름(검사자·작업자)이 섞여 화면에 나오지 않게 가린다(저장은 원래 안 함)
    names = [n for j in (raw.get("journals") or []) if isinstance(j, dict)
             for n in [j.get("inspector_raw")] + [w.get("name") for w in (j.get("workers_raw") or []) if isinstance(w, dict)] if n and isinstance(n, str)]
    if names:
        notes = [scrub_names(n, names) or n for n in notes]
        notes = [re.sub(r"(['‘“\"])([가-힣])[가-힣]([가-힣])(['’”\"])", r"\1\2*\3\4", n) for n in notes]
    return {"document_type": doc_type, "items": items, "uncertain_notes": notes, "file_date": fdate,
            "usage": {"input_tokens": response.usage.input_tokens, "output_tokens": response.usage.output_tokens}}
