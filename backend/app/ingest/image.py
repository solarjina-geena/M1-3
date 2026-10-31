"""작업일보 사진/PDF 한 장 -> Claude 가 읽어 JournalPayload 목록으로 (미리보기 전용, DB 에 쓰지 않음).

팀 OCR 흐름(원본 → 추출값 → 사람 검토 → 업무 테이블)과 같은 의미다. 여기서는 추출을 Claude 비전이 맡고,
사람이 미리보기에서 승인해야 m13_journal_save 로 들어간다.
"""
from __future__ import annotations

import base64
from typing import Literal

import anthropic
from pydantic import BaseModel, Field

from ..config import settings
from .journal_payload import JournalPayload

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
- 모델이 IV/OV/HSV 중 어느 것인지 확실하지 않으면 그 항목을 만들지 말고 uncertain_notes 에 이유를 적습니다. OV/HSV 합산 양식이면 합산 수량을 나누지 않습니다.
- 작업자 이름은 적지 않습니다. 검사자 이름만 inspector_raw 에 적습니다(가려서 저장).
- 페이지에 있는데 위 항목에 없는 정보는 source.note 에 짧게 남깁니다.
"""


class Extraction(BaseModel):
    document_type: Literal["INJECTION", "STITCHING", "ASSEMBLY", "FINAL_INSPECTION", "UNKNOWN"]
    journals: list[JournalPayload] = Field(default_factory=list)
    uncertain_notes: list[str] = Field(default_factory=list)


async def extract_from_image(data: bytes, media_type: str, filename: str) -> dict:
    if not settings.anthropic_key:
        raise RuntimeError("ANTHROPIC_API_KEY 가 backend/.env.personal 에 없습니다.")
    b64 = base64.standard_b64encode(data).decode("utf-8")
    block = ({"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": b64}}
             if media_type == "application/pdf" else
             {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": b64}})
    # Async 요청은 브라우저 취소/연결 종료 시 백엔드에서도 취소할 수 있게 한다.
    # 제한 시간과 재시도 횟수를 고정해 관리 화면이 무기한 대기하지 않게 한다.
    async with anthropic.AsyncAnthropic(api_key=settings.anthropic_key, timeout=90.0, max_retries=0) as client:
        response = await client.messages.parse(
            model=settings.anthropic_model,
            max_tokens=16000,
            messages=[{"role": "user", "content": [block, {"type": "text", "text": PROMPT}]}],
            output_format=Extraction,
        )
    if response.stop_reason == "refusal":
        raise RuntimeError("모델이 이 요청을 거절했습니다(refusal).")
    ex: Extraction = response.parsed_output
    items = []
    for j in ex.journals:
        j.source.method = "IMAGE"
        j.source.file = j.source.file or filename
        items.append({"ok": True, "payload": j.model_dump(), "normalized": j.normalized()})
    return {"document_type": ex.document_type, "items": items, "uncertain_notes": ex.uncertain_notes,
            "usage": {"input_tokens": response.usage.input_tokens, "output_tokens": response.usage.output_tokens}}
