"""작업일보 1장 = JournalPayload. 입력 경로(폼·엑셀·CSV·이미지)가 모두 이 형식으로 모여 m13_journal_save 로 간다.

사슬(LOT 연결)을 잇는 칸은 inputs(상위 공정 LOT)와 materials(원자재 LOT)다. 이 두 칸이 비면 사슬이 끊긴다.
"""
from __future__ import annotations

import re
from datetime import date
from typing import Literal, Optional

from pydantic import BaseModel, Field, field_validator

ProcessCode = Literal["IMEB3_INJECTION", "IMEB3_STITCHING", "IMEB3_WINDING", "IMEB3_CA_PRESS", "IMEB3_FINAL_INSPECTION"]
ModelCode = Literal["IV", "OV", "HSV"]
MATERIAL_CODES = {"RESIN": "IMEB3_RESIN", "BOBBIN": "IMEB3_BOBBIN", "LEAD_PIN": "IMEB3_LEAD_PIN", "INSERT": "IMEB3_LEAD_PIN_INSERT",
                  "WIRE": "IMEB3_WIRE", "UPPER_CASE": "IMEB3_UPPER_CASE", "LOWER_CASE": "IMEB3_LOWER_CASE"}
# 상위 공정 규칙: 어느 부품이 어느 공정의 산출물인가 (사슬을 잇는 핵심 규칙)
UPSTREAM_OF = {"IMEB3_STITCHING": "IMEB3_INJECTION", "IMEB3_WINDING": "IMEB3_STITCHING", "IMEB3_CA_PRESS": "IMEB3_WINDING"}


NAME_RE = re.compile(r"[가-힣]{2,4}")


def mask_name(raw: str | None) -> str | None:
    """'홍길동(판독)' -> '홍*동(판독)'. 검사자·작업자 실명은 DB 에 두지 않는다(사용자 지시 2026-10-29)."""
    if not raw:
        return None

    def _m(m):
        n = m.group(0)
        return n[0] + "*" * (len(n) - 2) + n[-1] if len(n) > 2 else n[0] + "*"
    return NAME_RE.sub(_m, str(raw))[:60]


def mask_person(raw: str | None) -> str | None:
    """사람 이름 하나(작업자·검사자 칸) → 가운데를 가린 표시명. 한글은 mask_name 과 같고, 영문 표기 이름(외국인 작업자)도
    단어마다 첫·끝 글자만 남긴다('Nguyen Van' → 'N****n V*n'). 실명은 DB 에 두지 않는다."""
    if not raw or not str(raw).strip():
        return None
    s = mask_name(str(raw).strip())

    def _w(m):
        w = m.group(0)
        return w[0] + "*" * (len(w) - 2) + w[-1] if len(w) > 2 else w[0] + "*"
    return re.sub(r"[A-Za-z]{2,}", _w, s)[:60]


def scrub_names(text: str | None, names: list[str]) -> str | None:
    """자유 문장(비고·메모)에 같은 이름이 다시 나오면 그 자리도 가린다."""
    if not text:
        return text
    for n in sorted({x.strip() for x in names if x and x.strip()}, key=len, reverse=True):
        text = text.replace(n, mask_person(n) or n)
    return text


def marking_code_date(code: str | None, base: str | None) -> str | None:
    """CA 제품 LOT 마킹코드(조견표) → 생산일. 'Z' + 월 글자(A=1월 … L=12월) + 일 글자(A=1 … Z=26, 2~6=27~31일).
    예: ZHF=8/6, ZIU=9/21, ZH4=8/29. 한 글자라도 못 읽었으면('?') None — 추정하지 않는다.
    연도는 검사일(base) 기준, 마킹 월이 검사 월보다 뒤면 전년도."""
    c = str(code or "").strip().upper()
    m = re.fullmatch(r"Z([A-L])([A-Z2-6])", c)
    if not m:
        return None
    month = ord(m.group(1)) - 64
    day = ord(m.group(2)) - 64 if m.group(2).isalpha() else 25 + int(m.group(2))
    try:
        b = date.fromisoformat(base) if base else date.today()
        year = b.year - 1 if month > b.month else b.year
        return date(year, month, day).isoformat()
    except ValueError:
        return None


def norm_date(raw: str | None, base: str | None = None) -> str | None:
    """'26.07.02' / '2/20' / '8.28' / '2026-08-10' -> 'YYYY-MM-DD'. base(작업일)보다 미래면 작년으로."""
    if not raw:
        return None
    t = str(raw).strip()
    m = re.search(r"(\d{4})-(\d{1,2})-(\d{1,2})", t)
    if m:
        y, mo, d = map(int, m.groups())
    else:
        m = re.search(r"(\d{2})[./](\d{1,2})[./](\d{1,2})", t)
        if m:
            y, mo, d = 2000 + int(m.group(1)), int(m.group(2)), int(m.group(3))
        else:
            m = re.search(r"(\d{1,2})[./](\d{1,2})", t)
            if not m:
                return None
            mo, d = int(m.group(1)), int(m.group(2))
            y = int((base or date.today().isoformat())[:4])
            try:
                if base and date(y, mo, d) > date.fromisoformat(base):
                    y -= 1
            except ValueError:
                return None
    try:
        return date(y, mo, d).isoformat()
    except ValueError:
        return None


class InputLot(BaseModel):
    """상위 공정에서 넘어온 LOT. process 를 비우면 공정 순서 규칙(UPSTREAM_OF)으로 채운다.
    component: BOBBIN(사출품 보빈) / INSERT(스티칭품 리드핀 인서트). BA 일보에는 둘 다 적히는데, 인서트 날짜가 스티칭 LOT 이고
    보빈 날짜는 같은 보빈을 쓴 스티칭 일보를 찾는 열쇠다(변환기 규칙과 동일)."""
    component: Optional[Literal["BOBBIN", "INSERT"]] = None
    process: Optional[ProcessCode] = None
    lot_date: Optional[str] = Field(None, description="YYYY-MM-DD. 원문이 '8.28' 같은 표기면 raw 에 두고 비워도 됨")
    lot_code: Optional[str] = None
    raw: Optional[str] = Field(None, description="일보에 적힌 원문 그대로")
    note: Optional[str] = None


class MaterialUse(BaseModel):
    """원자재. 공정별 필수: 사출=수지(RESIN), 스티칭=리드핀(LEAD_PIN), 권선 BA=와이어(WIRE, 스핀들별 여러 개), 압입 CA=상/하부 케이스."""
    material: str = Field(description="IMEB3_RESIN, IMEB3_LEAD_PIN, IMEB3_WIRE, IMEB3_UPPER_CASE, IMEB3_LOWER_CASE 또는 짧은 키(RESIN, WIRE ...)")
    lot_date: Optional[str] = None
    raw: Optional[str] = None
    qty: Optional[float] = None
    unit: Optional[str] = None
    spindle: Optional[str] = Field(None, description="와이어처럼 스핀들/열별로 LOT 이 다르면 위치 표기")


class Defect(BaseModel):
    name: str
    qty: Optional[int] = Field(None, description="숫자로 읽을 수 없으면 비우고 raw 에 원문")
    raw: Optional[str] = None


class InspectionLot(BaseModel):
    raw: Optional[str] = Field(None, description="예: 'ZH4=2BOX'. 열(컬럼)마다 LOT=BOX 를 하나씩")
    marking_code: Optional[str] = Field(None, description="3자리 마킹코드 예: ZH4")
    lot_date: Optional[str] = Field(None, description="마킹코드가 가리키는 CA 생산일(조견표). 모르면 비움")
    boxes: Optional[int] = None


class WorkerName(BaseModel):
    """작업자(근무 현황·작업자 칸). 이름 원문은 서버에서 가린 뒤 버린다 → mqi.worker(가린 표시명) + worker_assignment(생산 실행 FK)."""
    name: str = Field(description="작업자 이름 원문(서버가 가운데를 가림)")
    role: Optional[Literal["OPERATOR", "SETUP", "SUPERVISOR", "OTHER"]] = Field(None, description="작업자=OPERATOR, 셋업=SETUP, 반장·조장=SUPERVISOR")


class Source(BaseModel):
    method: Literal["MANUAL", "EXCEL", "CSV", "IMAGE", "FIRESTORE"] = "MANUAL"
    file: Optional[str] = None
    page: Optional[int] = None
    note: Optional[str] = None


class JournalPayload(BaseModel):
    model: ModelCode
    process: ProcessCode
    work_date: str = Field(description="YYYY-MM-DD")
    shift: Literal["D", "N"] = "D"
    sequence: int = 1
    gross_output_qty: Optional[int] = Field(None, description="생산량(또는 검사량). 원문 그대로의 숫자")
    good_qty: Optional[int] = None
    defect_qty: Optional[int] = None
    work_minutes: Optional[int] = None
    raw_quantity_text: Optional[str] = None
    output_lot_code: Optional[str] = None
    # ---- 최종검사 전용 ----
    inspection_type: Optional[Literal["FINAL", "REINSPECTION", "IN_PROCESS"]] = None
    inspection_round: Optional[Literal[1, 2]] = Field(None, description="1=1차검사(신입·타라인 지원), 2=2차검사(iMEB3 전담 검사자, 실제 검사 수량). 원문 '1차/2차' 표기 또는 검사자로 판단")
    inspection_method: Optional[Literal["VISUAL_MANUAL", "MICROSCOPE"]] = None
    inspector_raw: Optional[str] = Field(None, description="검사자 이름 원문. 저장 전 가운데를 *로 가린다(normalized). 전담/신입 구분용")
    remarks_raw: Optional[str] = Field(None, description="비고란 원문 전체. 재검·현미경검사·보강 수량·리워크 메모가 여기 있다")
    # ---- 조립(BA/CA) 전용 ----
    rework_qty: Optional[int] = Field(None, description="비고에 '리워크 N EA' 가 있으면 수량")
    rework_note: Optional[str] = None
    equipment_raw: Optional[str] = Field(None, description="설비/금형/프로그램 번호 등 원문")
    inputs: list[InputLot] = Field(default_factory=list)
    materials: list[MaterialUse] = Field(default_factory=list)
    defects: list[Defect] = Field(default_factory=list)
    lots: list[InspectionLot] = Field(default_factory=list, description="최종검사일 때 검사한 제품 LOT 목록")
    workers_raw: list[WorkerName] = Field(default_factory=list, description="생산 공정 작업자(근무 현황) 이름 원문. 저장 전 가운데를 *로 가린다(normalized)")
    source: Source = Field(default_factory=Source)
    replace: bool = Field(False, description="같은 모델·날짜·교대·공정·순번 일보가 이미 있을 때 이전 원자재·불량·작업자 행을 VOID 하고 다시 저장")
    reason: Optional[str] = None

    @field_validator("work_date")
    @classmethod
    def _d(cls, v: str) -> str:
        n = norm_date(v)
        if not n:
            raise ValueError(f"작업일 형식 오류: {v}")
        return n

    def normalized(self) -> dict:
        """RPC 에 보낼 dict. 날짜 정규화, 상위 공정 자동 채움, 자재 코드 정리."""
        d = self.model_dump()
        for i in d["inputs"]:
            i["lot_date"] = norm_date(i.get("lot_date") or i.get("raw"), self.work_date)
            if not i.get("process"):
                i["process"] = UPSTREAM_OF.get(self.process)
        d["inputs"] = [i for i in d["inputs"] if i.get("process") and (i.get("lot_date") or i.get("lot_code"))]
        if self.process == "IMEB3_CA_PRESS" and not any(i.get("process") == "IMEB3_WINDING" for i in d["inputs"]):
            # 조립일보 한 장에 권선(BA)·압입(CA)이 같이 적히고, CA 는 같은 장의 BA 산출물을 압입한다(변환기와 같은 규칙).
            # 같은 날·같은 모델 BA LOT 이 투입 → 사슬이 CA 에서 끊기지 않는다. 날짜 추정이 아니라 양식 구조에 따른 연결이다.
            d["inputs"].append({"component": None, "process": "IMEB3_WINDING", "lot_date": self.work_date, "lot_code": None,
                                "raw": "같은 조립일보 BA", "note": "같은 조립일보의 권선(BA) LOT → 압입(CA) 투입(양식 규칙)"})
        for m in d["materials"]:
            m["material"] = MATERIAL_CODES.get(str(m["material"]).upper(), m["material"])
            m["lot_date"] = norm_date(m.get("lot_date") or m.get("raw"), self.work_date)
        for l in d["lots"]:
            l["lot_date"] = norm_date(l.get("lot_date"), None)
            if not l.get("marking_code") and l.get("raw"):
                mm = re.match(r"\s*([A-Z0-9?]{3})", str(l["raw"]).upper())
                l["marking_code"] = mm.group(1) if mm else None
            if not l.get("lot_date") and l.get("marking_code"):
                # 조견표(Z+월+일)로 세 글자가 모두 읽힌 경우에만 날짜를 푼다. '?' 가 있으면 비워 둔다
                # → RPC 가 UNRESOLVED 로 저장. 검사일에 가장 가까운 LOT 같은 추정 연결은 하지 않는다.
                l["lot_date"] = marking_code_date(l["marking_code"], self.work_date)
                if l["lot_date"]:
                    l["lot_date_rule"] = "marking_code_table"
            if l.get("boxes") is None and l.get("raw"):
                mb = re.search(r"[=:]?\s*(\d+)\s*box", str(l["raw"]), re.I)
                l["boxes"] = int(mb.group(1)) if mb else None
        if self.process == "IMEB3_FINAL_INSPECTION":
            d["inspected_qty"] = self.gross_output_qty
        # ---- 사람 이름: 검사자·작업자 모두 가린 표시명만 남기고 원문은 버린다. 자유 문장에 같은 이름이 있으면 그 자리도 가린다.
        raw_names = [w["name"] for w in d.get("workers_raw") or [] if w.get("name")]
        if d.get("inspector_raw"):
            raw_names.append(d["inspector_raw"])
            d["inspector_masked"] = mask_person(d["inspector_raw"])
        d.pop("inspector_raw", None)   # 실명은 저장하지 않는다
        d["workers_masked"] = [{"name": mask_person(w["name"]), "role": w.get("role") or "OPERATOR"}
                               for w in d.pop("workers_raw", None) or [] if mask_person(w.get("name"))]
        if raw_names:
            for k in ("remarks_raw", "rework_note", "raw_quantity_text", "equipment_raw"):
                d[k] = scrub_names(d.get(k), raw_names)
            d["source"]["note"] = scrub_names(d["source"].get("note"), raw_names)
            for row in d["inputs"] + d["materials"] + d["defects"] + d["lots"]:
                for k in ("raw", "note"):
                    if row.get(k):
                        row[k] = scrub_names(row[k], raw_names)
        # ---- BA 일보의 보빈 날짜(변환기와 같은 규칙): 사출 LOT 을 바로 잇지 않는다.
        #      원문은 원자재 사용(보빈, LOT 없음)으로 남기고, 날짜는 RPC 가 '15일 안 같은 보빈 날짜를 쓴 스티칭 LOT' 을 찾는 열쇠로만 쓴다.
        if self.process == "IMEB3_WINDING":
            keep, bob = [], []
            for i in d["inputs"]:
                if i.get("component") == "BOBBIN":
                    bob.append(i)
                else:
                    keep.append(i)
            d["inputs"] = keep
            d["ba_bobbin_dates"] = sorted({i["lot_date"] for i in bob if i.get("lot_date")})
            for i in bob:
                d["materials"].append({"material": "IMEB3_BOBBIN", "lot_date": None, "raw": i.get("raw") or i.get("lot_date"),
                                       "qty": None, "unit": None, "spindle": None,
                                       "note": "BA 보빈 날짜는 스티칭 일보 매칭 근거로만 사용(사출 LOT 직접 연결 안 함)"})
        d["reason"] = self.reason or f"작업일보 입력({self.source.method}) {self.source.file or ''} p{self.source.page or ''}".strip()
        return d
