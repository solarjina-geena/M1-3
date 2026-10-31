"""전체흐름(피시본) 대시보드용 행 변환.

M1-2 대시보드(frontend/index.html)는 Firestore 문서 모양의 행 목록(/api/data)으로 그래프를 직접 그린다.
여기서는 mqi 뷰 `public.m13_fishbone_rows`(공정 실행·최종검사 실행 한 행씩)를 그 모양으로 바꾼다.
화면 코드는 바꾸지 않고 데이터만 mqi 에서 준다는 원칙.

행 모양(화면이 읽는 키)
- id, run_id, process(INJECTION/STITCHING/BA/CA/FINAL_INSPECTION), variant(IV/OV/HSV), date, metric, value, unit, value_source,
  product, source{file,page}, details{shift, operator, production_lot_id, <자재 원문 키>...}
- 최종검사: inspection_date, details{inspector_raw, inspection_class_raw, lot_no_raw, box_size_ea}, trace_lot_mappings[...]
"""
from __future__ import annotations

import re
from typing import Any

PROCESS = {"IMEB3_INJECTION": "INJECTION", "IMEB3_STITCHING": "STITCHING", "IMEB3_WINDING": "BA",
           "IMEB3_CA_PRESS": "CA", "IMEB3_FINAL_INSPECTION": "FINAL_INSPECTION"}
# 자재 코드 → 화면이 아는 원문 키 (enrichFishboneGraph 의 공정별 키 목록과 같다)
MATERIAL_KEY = {"IMEB3_RESIN": "resin_lot_raw", "IMEB3_BOBBIN": "bobbin_lot_raw", "IMEB3_LEAD_PIN": "lead_pin_lot_raw",
                "IMEB3_LEAD_PIN_INSERT": "insert_lot_raw", "IMEB3_WIRE": "wire_lots_raw",
                "IMEB3_UPPER_CASE": "upper_case_lot_raw", "IMEB3_LOWER_CASE": "lower_case_lot_raw"}
BOX_EA = 480
_QTY_EA = re.compile(r"\+\s*([\d,]+)\s*EA", re.I)


def _source_status(vs: str | None) -> str:
    if vs == "EXCEL_TRANSCRIBED":
        return "HUMAN_VERIFIED"      # 회사 전산 엑셀 전사본 = 사람이 입력한 값
    if vs == "HUMAN_VERIFIED":
        return "HUMAN_VERIFIED"
    if vs and vs.startswith("UNCERTAIN"):
        return "UNCERTAIN"
    return "SOURCE_READ"


def _raw_of_input(note: str | None) -> str:
    """process_run_lot.evidence_note 'field=raw. 설명' 에서 raw 만."""
    s = str(note or "")
    s = s.split("=", 1)[1] if "=" in s else s
    return re.split(r"\.\s", s, 1)[0].strip()


def _add(details: dict, key: str, raw: str | None) -> None:
    raw = str(raw or "").strip()
    if not raw or raw.upper() == "BLANK":
        return
    vals = details.setdefault(key, [])
    if raw not in vals:
        vals.append(raw)


def _production_row(r: dict) -> dict:
    process = PROCESS.get(r["process_code"], r["process_code"])
    details: dict[str, Any] = {"shift": r.get("shift") or "D", "operator": r.get("operator") or "",
                               "production_lot_id": r.get("out_lot"), "work_type": r.get("work_type")}
    for m in r.get("materials") or []:
        key = MATERIAL_KEY.get(m.get("material"))
        if key:
            _add(details, key, m.get("raw"))
    for i in r.get("inputs") or []:
        field = str(i.get("field") or "")
        if field.startswith("ba_output"):
            continue                              # CA←BA 같은 일보 연결은 화면이 날짜·run 으로 스스로 잇는다
        raw = _raw_of_input(i.get("note"))
        if "insert" in field.lower():
            _add(details, "insert_lot_raw", raw)
        elif "bobbin" in field.lower():
            _add(details, "bobbin_lot_raw", raw)
        elif "lead_pin" in field.lower():
            _add(details, "lead_pin_lot_raw", raw)
    return {"id": r["id"], "run_id": r.get("run_id"), "process": process, "variant": r["variant"], "date": r["date"],
            "metric": "PRODUCTION_QTY", "value": r.get("value"), "unit": "EA", "value_source": _source_status(r.get("value_source")),
            "product": "iMEB3", "source": {"file": r.get("file"), "page": r.get("page")}, "details": details,
            "lot_id": r.get("out_lot"), "work_minutes": r.get("minutes"), "raw_value": r.get("raw_quantity_text")}


def _inspection_row(r: dict) -> dict:
    rnd = r.get("round")
    itype = r.get("insp_type") or "FINAL"
    cls = "재검" if itype == "REINSPECTION" else "1차검사" if rnd == 1 else "2차검사" if rnd == 2 else ""
    mappings, raws = [], []
    for l in r.get("lots") or []:
        raw = str(l.get("raw") or "")
        raws.append(raw)
        box = l.get("box")
        extra = _QTY_EA.search(raw)
        qty = l.get("qty") if l.get("qty") is not None else ((int(box) * BOX_EA + (int(extra.group(1).replace(",", "")) if extra else 0)) if box is not None else None)
        mappings.append({"trace_lot_id": l.get("ca_lot"), "lot_code": l.get("marking_code") or raw[:3], "product_lot_date": l.get("lot_date"),
                         "variant": r["variant"], "normalization_status": l.get("normalization_status") or ("MATCHED" if l.get("ca_lot") else "UNRESOLVED"),
                         "raw_lot_context": raw, "quantity_ea_derived": qty, "linkage_status": l.get("status")})
    details = {"inspector_raw": r.get("inspector") or "", "inspection_class_raw": cls, "lot_no_raw": "; ".join(raws),
               "box_size_ea": BOX_EA, "inspection_date": r["date"], "inspection_hours_raw": r.get("hours"), "inspection_type": itype}
    return {"id": r["id"], "run_id": r.get("run_id"), "process": "FINAL_INSPECTION", "variant": r["variant"], "date": r["date"],
            "inspection_date": r["date"], "metric": "INSPECTION_QTY", "value": r.get("value"), "unit": "EA",
            "value_source": _source_status(r.get("value_source")), "product": "iMEB3",
            "source": {"file": r.get("file"), "page": r.get("page")}, "details": details, "trace_lot_mappings": mappings}


def to_rows(view_rows: list[dict]) -> list[dict]:
    out = []
    for r in view_rows:
        if r.get("variant") not in ("IV", "OV", "HSV"):
            continue
        out.append(_inspection_row(r) if r.get("kind") == "inspection" else _production_row(r))
    out.sort(key=lambda x: (x["date"], x["process"], x["variant"], x["id"]))
    return out
