"""Firestore 내보내기 CSV(M1-2) -> Supabase mqi 적재 SQL 변환기.

- DB에 직접 쓰지 않는다. outputs/ 에 SQL 파일과 보고서(md)만 만든다.
- 테이블·컬럼·허용값은 팀 기준 mqi 스키마 그대로 쓴다 (AGENTS.md 스키마 동일성 원칙).
- ID는 원본 키로 만든 고정 UUID(uuid5). 다시 실행해도 같은 ID → ON CONFLICT DO NOTHING 으로 재실행 안전.
- LOT 연결은 전부 CANDIDATE. 사람이 확인한 것만 나중에 CONFIRMED 로 바꾼다.
- 모델(IV/OV/HSV)이 불확실한 문서는 모델이 필수인 테이블에 넣지 않고 보고서의 '보류'에 남긴다.

LOT 연결 방식 (공정별 LOT + INPUT 연결):
  사출(INJECTION) ──OUTPUT→ 사출LOT ──INPUT→ 스티칭(STITCHING) ──OUTPUT→ 스티칭LOT ──INPUT→ 권선(WINDING/BA)
  ──OUTPUT→ BA LOT ──INPUT→ 압입(CA_PRESS/CA) ──OUTPUT→ CA LOT ←inspection_lot── 최종검사
  원소재(수지·리드핀·와이어·케이스)는 material_usage 로 공정 실행에 연결.

실행:  py tools/firestore_to_mqi.py [CSV경로]
"""
from __future__ import annotations

import csv
import json
import re
import sys
import uuid
from collections import Counter, OrderedDict, defaultdict
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CSV = ROOT.parent / "M1-2" / "firestore_import" / "20260801-20260930_firestore_unified.csv"
OUT_DIR = ROOT / "outputs"
SQL_OUT = OUT_DIR / "firestore_mqi_load.sql"
REPORT_OUT = OUT_DIR / "firestore_mqi_report.md"

NS = uuid.uuid5(uuid.NAMESPACE_URL, "m1-3.firestore.mqi")
DATASET = "FIRESTORE_2026_08_09_V1"
ACTOR = "m1-3-firestore-import"
REASON = "M1-2 Firestore 내보내기(2026-08~09) 를 mqi 양식으로 변환해 적재. LOT 연결은 모두 CANDIDATE."

VARIANTS = ("IV", "OV", "HSV")
# 팀 실제 DB의 공정 코드 규칙(IMEB3_INJECTION, IMEB3_WINDING, IMEB3_CA_PRESS)을 따른다.
PROCESS = OrderedDict([
    ("INJ", ("IMEB3_INJECTION", "INJECTION")),
    ("STI", ("IMEB3_STITCHING", "STITCHING")),
    ("BA", ("IMEB3_WINDING", "WINDING")),
    ("CA", ("IMEB3_CA_PRESS", "CA_PRESS")),
    ("FIN", ("IMEB3_FINAL_INSPECTION", "FINAL_INSPECTION")),
])
PROCESS_OF = {
    "INJECTION": "INJ", "COMPONENT_INJECTION": "INJ",
    "STITCHING": "STI",
    "BA": "BA", "ASSEMBLY_BA": "BA", "BA_WINDING": "BA",
    "CA": "CA", "ASSEMBLY_CA": "CA", "CA_PRESS_FIT": "CA",
    "FINAL_INSPECTION": "FIN", "FINAL_INSPECTION_SUPPLEMENT": "FIN", "COMPONENT_FINAL_INSPECTION": "FIN",
    "REINSPECTION": "FIN", "REWORK_FINAL_INSPECTION": "FIN",
    "REWORK_CARD": "CARD", "TIMELINE": "TIMELINE",
    "ASSEMBLY_REWORK": "REWORK",   # 조립 리워크 작업 기록 → rework_record (새 LOT 아님)
}
QTY_METRICS = {"production_qty", "production_quantity", "PRODUCTION_QTY"}
FIN_QTY_METRICS = {"inspection_qty", "INSPECTED_QTY", "inspection_quantity", "REINSPECTED_QTY", "page_evidence", "final_inspection_qty"}

# 원자재/부품 종류: (material_code, material_name, 상위 공정 그룹 or None)
#   상위 공정이 있는 부품(보빈=사출 산출물, 인서트=스티칭 산출물)은 production_lot INPUT 으로 연결한다.
MATERIAL = OrderedDict([
    ("RESIN", ("IMEB3_RESIN", "사출 수지", None)),
    ("BOBBIN", ("IMEB3_BOBBIN", "보빈(사출품)", "INJ")),
    ("LEAD_PIN", ("IMEB3_LEAD_PIN", "리드핀", None)),
    ("INSERT", ("IMEB3_LEAD_PIN_INSERT", "리드핀 인서트 보빈(스티칭품)", "STI")),
    ("WIRE", ("IMEB3_WIRE", "권선 와이어", None)),
    ("UPPER_CASE", ("IMEB3_UPPER_CASE", "상부 케이스", None)),
    ("LOWER_CASE", ("IMEB3_LOWER_CASE", "하부 케이스", None)),
])
MATERIAL_FIELDS = {
    "resin_lot_raw": "RESIN", "component_resin_lot_raw": "RESIN",
    # 수지 LOT 이 이미 코드/날짜로 정리된 필드(9월 양식)와 'RESIN_LOT:26.8.13' 형 링크
    "resin_lot_id": "RESIN", "resin_trace_lot_id": "RESIN", "resin_lot_trace_id": "RESIN", "resin_lot_date": "RESIN", "resin_lot_link": "RESIN",
    # 보빈(사출품): 8월·9월 양식이 필드 이름을 제각각 써서 전부 나열한다 (2026-10-29 깊이 1·2 대조 결과)
    "bobbin_lot_raw": "BOBBIN", "bobbin_production_lot_raw": "BOBBIN", "bobbin_lot_dates": "BOBBIN",
    "bobbin_lot": "BOBBIN", "bobbin_lots_raw": "BOBBIN", "bobbin_date_raw": "BOBBIN", "bobbin_production_date_raw": "BOBBIN",
    "bobbin_production_dates_raw": "BOBBIN", "bobbin_lot_dates_raw": "BOBBIN", "bobbin_lot_id": "BOBBIN",
    # 보빈/리드핀 날짜가 한 칸에 같이 적힌 필드: 첫 날짜=보빈, 나머지=리드핀 으로 나눈다
    "bobbin_lead_pin_lots_raw": "BOBBIN_LEADPIN",
    "lead_pin_lot_raw": "LEAD_PIN", "lead_pin_inbound_lot_raw": "LEAD_PIN", "lead_pin_lot_date_raw": "LEAD_PIN",
    # 리드핀(스티칭 BS 자재) 9월 양식 변형들
    "lead_pin_receipt_date_raw": "LEAD_PIN", "lead_pin_receipt_dates_raw": "LEAD_PIN", "lead_pin_lot_dates_raw": "LEAD_PIN",
    "lead_pin_lot": "LEAD_PIN", "lead_pin_lots": "LEAD_PIN", "lead_pin_date_raw": "LEAD_PIN", "lead_pin_input_date_raw": "LEAD_PIN",
    "lead_pin_receipt_lot_date_raw": "LEAD_PIN", "lead_pin_receipt_lot_dates_raw": "LEAD_PIN", "lead_pin_inbound_lot_id": "LEAD_PIN",
    "bobbin_lot_date_raw": "BOBBIN", "bobbin_production_lot_date_raw": "BOBBIN",
    # 인서트(스티칭품)
    "insert_lot_raw": "INSERT", "lead_pin_insert_lot_raw": "INSERT", "lead_pin_insert_raw": "INSERT",
    "insert_lot": "INSERT", "insert_lot_date_raw": "INSERT", "lead_pin_insert_date_raw": "INSERT", "lead_pin_insert_lot_date_raw": "INSERT",
    "wire_lot_raw": "WIRE", "wire_lots_raw": "WIRE", "wire_lot": "WIRE", "wire_lot_dates_raw": "WIRE", "wire_lot_table_raw": "WIRE",
    "upper_case_lot_raw": "UPPER_CASE", "lower_case_lot_raw": "LOWER_CASE", "case_lot_raw": "LOWER_CASE",
    "upper_case_lot": "UPPER_CASE", "upper_case_lot_date_raw": "UPPER_CASE", "upper_case_receipt_date_raw": "UPPER_CASE",
    "lower_case_lot": "LOWER_CASE", "lower_case_lot_date_raw": "LOWER_CASE", "lower_case_receipt_date_raw": "LOWER_CASE",
}
# 자재가 속하는 공정(사용자 규칙 2026-10-29): 수지=사출(BB), 리드핀=스티칭(BS), 와이어=권선(BA), 케이스=압입(CA).
# 조립일보는 BA·CA 가 한 장이라 와이어·케이스가 양쪽 문서에 다 적히므로, 맞는 공정 실행으로 보낸다.
MATERIAL_HOME = {"RESIN": "INJ", "LEAD_PIN": "STI", "WIRE": "BA", "UPPER_CASE": "CA", "LOWER_CASE": "CA"}
# component_lots_raw / material_lot_dates_raw 같은 중첩 dict 의 키 → 종류
NESTED_KEYS = {
    "bobbin": "BOBBIN", "lead_pin": "LEAD_PIN", "leadpin": "LEAD_PIN",
    "lead_pin_insert": "INSERT", "lead_pin_insert_stitching": "INSERT", "insert": "INSERT",
    "bobbin_lead_pin": "BOBBIN_LEADPIN", "bobbin_leadpin": "BOBBIN_LEADPIN",
    "wire": "WIRE", "upper_case": "UPPER_CASE", "lower_case": "LOWER_CASE", "resin": "RESIN",
    "upper": "UPPER_CASE", "lower": "LOWER_CASE",
}
# BA 보빈 날짜로 스티칭 일보를 찾을 때 거슬러 보는 범위(일). BA 작업일 포함.
STI_MATCH_WINDOW_DAYS = 15


def uid(*parts) -> str:
    return str(uuid.uuid5(NS, "|".join(str(p) for p in parts)))


def yymmdd(d: str) -> str:
    return d[2:4] + d[5:7] + d[8:10]


# ----------------------------------------------------------------- 원본 읽기
def load_docs(path: Path) -> tuple[dict, Counter]:
    csv.field_size_limit(10 ** 8)
    docs: dict[str, dict] = {}
    stats = Counter()
    with open(path, encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            payload = json.loads(r["payload_json"] or "{}")
            did = r["document_id"]
            stats[r["action"]] += 1
            if r["action"] == "ADD":
                docs.setdefault(did, {}).update(payload)
            elif did in docs:
                docs[did].update(payload)
            else:
                stats["ENRICH_WITHOUT_ADD(제외)"] += 1
    return docs, stats


# ----------------------------------------------------------------- 값 정규화
def is_production(d) -> bool:
    """생산량 문서. 9월: production_qty 계열. 8월: page_evidence 에 숫자 생산량."""
    if d.get("metric") in QTY_METRICS:
        return True
    return d.get("metric") == "page_evidence" and isinstance(d.get("value"), (int, float)) and not isinstance(d.get("value"), bool)


def variant_of(d) -> str | None:
    v = d.get("variant")
    return v if v in VARIANTS else None


def shift_of(d) -> tuple[str, bool]:
    s = str((d.get("details") or {}).get("shift") or d.get("trace_lot_shift") or "").strip().upper()
    if s in ("N", "NIGHT", "야간"):
        return "N", True
    if s in ("D", "DAY", "주간"):
        return "D", True
    return "D", False


def status_of(d) -> str:
    vs = d.get("value_source") or ""
    if vs == "HUMAN_VERIFIED":
        return "VERIFIED"
    if vs.startswith("UNCERTAIN") or d.get("review_status") == "UNCERTAIN":
        return "NEEDS_REVIEW"
    return "UNVERIFIED"


def lot_status_of(d) -> str:
    return {"VERIFIED": "CONFIRMED"}.get(status_of(d), status_of(d))


def to_int(v):
    if v is None or isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v)
    t = re.sub(r"[,\s]|EA|ea|개|BOX|box", "", str(v))
    return int(float(t)) if re.fullmatch(r"-?\d+(\.\d+)?", t) else None


DATE_TOKEN = re.compile(r"\d{6}[DN]\d|\d{4}-\d{1,2}-\d{1,2}|\d{2}\.\d{1,2}\.\d{1,2}|\d{1,2}[./]\d{1,2}")


def lot_dates_in(raw, base: str) -> list[tuple[str, str]]:
    """원문에서 날짜 표기를 모두 찾아 [(원문조각, YYYY-MM-DD)] 로. '8.24 / 9.3', '8/10;8/14', '8.24로 보임' 모두 처리."""
    out = []
    for tok in DATE_TOKEN.findall(str(raw or "")):
        d = norm_lot_date(tok, base)
        if d:
            out.append((tok, d))
    return out


def norm_lot_date(raw, base: str) -> str | None:
    """'26.07.02' / '2/20' / '8.28' / '2026-08-10' -> 'YYYY-MM-DD'. 해석 불가면 None."""
    if raw is None:
        return None
    t = str(raw).strip()
    m = re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})", t)
    if m:
        y, mo, da = map(int, m.groups())
    elif re.fullmatch(r"\d{6}[DN]\d", t):   # 이미 LOT 코드로 적힌 값: '260827D1'
        y, mo, da = 2000 + int(t[:2]), int(t[2:4]), int(t[4:6])
    else:
        m = re.fullmatch(r"(\d{2})[./](\d{1,2})[./](\d{1,2})", t)
        if m:
            y, mo, da = 2000 + int(m.group(1)), int(m.group(2)), int(m.group(3))
        else:
            m = re.fullmatch(r"(\d{1,2})[./](\d{1,2})", t)
            if not m:
                return None
            mo, da = int(m.group(1)), int(m.group(2))
            y = int(base[:4])
            try:
                if date(y, mo, da) > date.fromisoformat(base):
                    y -= 1
            except ValueError:
                return None
    try:
        return date(y, mo, da).isoformat()
    except ValueError:
        return None


CHART_CODE = re.compile(r"\b(Z[A-L][A-Z2-6])(\?)?")

# 최종검사 운영 규칙(사용자 설명·확인 2026-10-29): 1차검사는 신입 검사자 또는 타제품 숙련 검사자(지원)가 하고, 그 뒤 iMEB3 전담 검사자
# 4명이 검사한 수량이 실제 검사 수량. 비고란의 재검·현미경검사는 불량 이벤트에 대한 재검사.
# 전담 4명은 사용자가 확인했다(이름은 가린 형태로만 둔다). 그 외는 신입/타라인 지원 구분이 원문에 없어 한 묶음으로 둔다.
DEDICATED_INSPECTORS_MASKED = {"첸*녹", "이*진", "박*식", "무*매"}
QTY_EA = re.compile(r"(\d{1,3}(?:,\d{3})+|\d{3,})\s*EA", re.I)


def chart_date(code) -> str | None:
    """CA 제품 LOT 조견표 마킹코드 → 날짜. 2026-10-29 lot_code_mapping 56건에서 읽어낸 규칙:
    'Z' + 월(A=1 … L=12) + 일(A~Z=1~26, 2~6=27~31). 예 ZGP=07-16, ZG2=07-27, ZHA=08-01, ZI3=09-28."""
    m = re.fullmatch(r"Z([A-L])([A-Z2-6])", str(code or "").strip().upper())
    if not m:
        return None
    mo = ord(m.group(1)) - 64
    c = m.group(2)
    da = ord(c) - 64 if c.isalpha() else 25 + int(c)
    try:
        return date(2026, mo, da).isoformat()
    except ValueError:
        return None


def material_mentions(details: dict) -> list[tuple[str, str, str]]:
    """details 에서 (종류, 원문, 필드명) 목록."""
    found = []
    for field, kind in MATERIAL_FIELDS.items():
        v = details.get(field)
        if v in (None, "", [], {}):
            continue
        for item in (v if isinstance(v, list) else [v]):
            if item not in (None, ""):
                found.append((kind, str(item), field))
    # 8월 양식: component_lots_raw = {"bobbin": "7.31", "lead_pin": "7.22", "lead_pin_insert": "7.31", "wire": ...}
    # 8월 말 양식: material_lot_dates_raw = {"bobbin_leadpin": "8/10; 8/14", "insert": "8/18", ...}
    for nested in ("component_lots_raw", "material_lot_dates_raw", "case_lots_raw", "case_lot_dates_raw"):
        comp = details.get(nested)
        if isinstance(comp, dict):
            for k, v in comp.items():
                kind = NESTED_KEYS.get(str(k).lower())
                if kind and v not in (None, ""):
                    found.append((kind, str(v), f"{nested}.{k}"))
    # 8월 사출 양식: resin_lots_raw = [{"shift":"day","raw_lot":"26.7.20",...}, ...]  또는 {"day": {"lot": "26.07.04", "usage": "50kg"}, "night": {...}}
    rl = details.get("resin_lots_raw")
    if isinstance(rl, list):
        for i, item in enumerate(rl):
            if isinstance(item, dict):
                v = item.get("raw_lot") or item.get("lot") or item.get("trace_lot_id")
                if v not in (None, ""):
                    found.append(("RESIN", str(v), f"resin_lots_raw[{i}].raw_lot"))
            elif item not in (None, ""):
                found.append(("RESIN", str(item), f"resin_lots_raw[{i}]"))
    elif isinstance(rl, dict):
        for k, item in rl.items():
            v = item.get("lot") or item.get("raw_lot") if isinstance(item, dict) else item
            if v not in (None, ""):
                found.append(("RESIN", str(v), f"resin_lots_raw.{k}.lot"))
    # 보빈/리드핀 혼합 표기('8/10; 8/14', '9.5 / 9.15'): 첫 날짜=보빈, 나머지=리드핀
    out = []
    for kind, raw, field in found:
        if kind != "BOBBIN_LEADPIN":
            out.append((kind, raw, field))
            continue
        toks = DATE_TOKEN.findall(raw)
        if not toks:
            out.append(("BOBBIN", raw, field))
            continue
        out.append(("BOBBIN", toks[0], f"{field}[보빈]"))
        if len(toks) > 1:
            out.append(("LEAD_PIN", " / ".join(toks[1:]), f"{field}[리드핀]"))
    return out


def defect_items(details: dict) -> list[tuple[str, int | None, str]]:
    """(불량명, 수량 or None, 원문) 목록. defects(dict) 우선, 없으면 defects_raw(dict/str)."""
    src = details.get("defects")
    if src in (None, {}, "", 0):
        src = details.get("defects_raw")
    if src in (None, {}, "", 0):   # 8월 양식: BA_defects_raw / CA_defects_raw
        src = details.get("BA_defects_raw") or details.get("CA_defects_raw")
    items = []
    if isinstance(src, dict):
        for k, v in src.items():
            items.append((str(k), to_int(v), str(v)))
    elif isinstance(src, str) and src.strip():
        for piece in re.split(r"[;,]\s*", src):
            m = re.match(r"(.+?)\s*[:=]?\s*(\d+)\s*\??\s*(UNCERTAIN)?$", piece.strip())
            if m:
                items.append((m.group(1).strip(), None if m.group(3) else int(m.group(2)), piece.strip()))
            elif piece.strip():
                items.append((piece.strip(), None, piece.strip()))
    return items


NAME_RE = re.compile(r"[가-힣]{2,4}")


def mask_name(raw) -> str | None:
    """작업자·검사자 이름 가운데를 * 로 가린다. '홍길동(초기 판독)' -> '홍*동(초기 판독)', '김세?' -> '김*?'. 비어 있으면 None."""
    if raw in (None, "", [], {}):
        return None
    if isinstance(raw, list):
        return ", ".join(x for x in (mask_name(v) for v in raw) if x)
    if isinstance(raw, dict):
        return ", ".join(f"{k}:{mask_name(v)}" for k, v in raw.items() if mask_name(v))

    def _m(m):
        n = m.group(0)
        return n[0] + "*" * (len(n) - 2) + n[-1] if len(n) > 2 else n[0] + "*"
    return NAME_RE.sub(_m, str(raw))[:60]


def src_json(d, **extra) -> str:
    s = d.get("source") or {}
    body = {"ds": DATASET, "fs": d.get("id"), "file": s.get("file") or s.get("relative_path"), "page": s.get("page"),
            "vs": d.get("value_source"), **{k: v for k, v in extra.items() if v not in (None, "", False)}}
    return json.dumps(body, ensure_ascii=False)


# ----------------------------------------------------------------- 변환
class Builder:
    def __init__(self):
        self.T: dict[str, list[dict]] = defaultdict(list)
        self.seen: set[str] = set()
        self.pending: Counter = Counter()
        self.pending_ids: dict[str, list[str]] = defaultdict(list)
        self.model_id = {}
        self.process_id = {}
        self.material_id = {}
        self.defect_id = {}
        self.lot = {}          # (model, grp, code) -> lot_id
        self.lot_has_run = set()
        self.prod_run = {}     # (model, date, shift) -> run_id
        self.proc_run = {}     # (model, grp, date, shift, seq) -> process_run_id
        self.marking = {}      # CA 마킹코드 -> lot_date
        self.run_out_lot = {}  # process_run_id -> 산출 lot_id
        self.linked = set()    # (process_run_id, lot_id) 이미 INPUT 으로 이은 쌍 (중복 방지)
        self.mat_linked = set()  # (process_run_id, 자재종류, lot_date) 이미 material_usage 로 적은 자재 LOT (중복 방지)
        self.sti_runs = defaultdict(list)    # model -> [(work_date, process_run_id)]  스티칭 실행
        self.sti_bobbin = defaultdict(set)   # 스티칭 process_run_id -> {보빈 날짜}
        self.workers = {}      # 가린 이름 -> worker_id
        self.insp_runs = {}    # inspection_run_id -> dict(model, date, type, round, lots:set, re)
        self.pending_components = []  # 1차 처리 뒤 한꺼번에 붙일 (doc, model, grp, pr, kind, raw, field, date)
        self.ba_bobbin = []    # BA 일보의 보빈 날짜 기록: (doc, model, pr, ba_date, raw, field, tok, ldate) → 스티칭 매칭용

    def add(self, table: str, row: dict) -> bool:
        pk = next(iter(row.values()))
        key = f"{table}:{pk}"
        if key in self.seen:
            return False
        self.seen.add(key)
        self.T[table].append(row)
        return True

    def hold(self, d, reason: str):
        self.pending[reason] += 1
        self.pending_ids[reason].append(d.get("id") or "?")

    # --- 기준정보
    def masters(self):
        pid = uid("product", "IMEB3")
        self.add("product", {"product_id": pid, "product_code": "IMEB3", "product_name": "iMEB3"})
        for m in VARIANTS:
            self.model_id[m] = uid("model", m)
            self.add("product_model", {"model_id": self.model_id[m], "product_id": pid, "model_code": m, "model_name": f"iMEB3 {m}"})
        for grp, (code, name) in PROCESS.items():
            self.process_id[grp] = uid("process", code)
            self.add("process", {"process_id": self.process_id[grp], "process_code": code, "process_name": name})
        for kind, (code, name, _) in MATERIAL.items():
            self.material_id[kind] = uid("material", code)
            self.add("material", {"material_id": self.material_id[kind], "material_code": code, "material_name": name,
                                  "material_category": "COMPONENT" if MATERIAL[kind][2] else "RAW_MATERIAL"})
        self.scheme_id = uid("lot_code_scheme", "IMEB3_CA_MARKING")
        self.add("lot_code_scheme", {"scheme_id": self.scheme_id, "scheme_code": "IMEB3_CA_MARKING",
                                     "scheme_name": "iMEB3 CA 제품 LOT 마킹 코드", "verification_status": "UNVERIFIED",
                                     "source_description": "Firestore trace_lot_mappings(lot_code -> product_lot_date, MATCHED) 에서 추출"})

    def defect(self, grp: str, name: str) -> str:
        key = (grp, name)
        if key not in self.defect_id:
            self.defect_id[key] = uid("defect", grp, name)
            self.add("defect_type", {"defect_type_id": self.defect_id[key], "defect_code": f"{grp}:{name}"[:100],
                                     "defect_name": name[:100], "defect_category": grp, "description": "원본 작업일보·검사일보 불량 항목명 그대로"})
        return self.defect_id[key]

    # --- LOT
    def get_lot(self, model: str, grp: str, lot_date: str, shift="D", seq=1, status="UNVERIFIED", note=None, raw=None) -> str:
        code = raw or f"{yymmdd(lot_date)}{shift}{seq}"
        key = (model, grp, code)
        if key not in self.lot:
            self.lot[key] = uid("lot", model, grp, code)
            self.add("production_lot", {"lot_id": self.lot[key], "model_id": self.model_id[model], "lot_date": lot_date,
                                        "lot_code_raw": code, "verification_status": status,
                                        "remark": json.dumps({"dataset": DATASET, "process_group": grp, "process_code": PROCESS[grp][0],
                                                              "rule": "LOT = 공정 작업일 YYMMDD + 교대(D/N) + 순번", "note": note}, ensure_ascii=False)})
        return self.lot[key]

    def find_run(self, model: str, grp: str, work_date: str, d=None, seq: int = 1) -> str | None:
        """같은 모델·공정·작업일·라인(seq)의 실행. 보조 문서의 교대 표기가 생산 문서와 달라도 찾도록 교대는 느슨하게 본다."""
        shift, _ = shift_of(d or {})
        pr = self.proc_run.get((model, grp, work_date, shift, seq))
        if pr:
            return pr
        for (m, g, dt, _s, q), v in self.proc_run.items():
            if (m, g, dt, q) == (model, grp, work_date, seq):
                return v
        return None

    def get_process_run(self, d, model: str, grp: str, lot_date: str, shift: str, seq=1, work_type="PRODUCTION") -> str:
        rk = (model, lot_date, shift)
        if rk not in self.prod_run:
            self.prod_run[rk] = uid("production_run", model, lot_date, shift)
            self.add("production_run", {"run_id": self.prod_run[rk], "model_id": self.model_id[model], "work_date": lot_date,
                                        "shift": shift, "run_sequence": 1, "run_type": "PRODUCTION",
                                        "remark": json.dumps({"dataset": DATASET, "rule": "모델·작업일·교대 단위. 원본에 RUN 번호 없음"}, ensure_ascii=False)})
        pk = (model, grp, lot_date, shift, seq)
        if pk not in self.proc_run:
            self.proc_run[pk] = uid("process_run", model, grp, lot_date, shift, seq)
            self.add("process_run", {"process_run_id": self.proc_run[pk], "run_id": self.prod_run[rk], "process_id": self.process_id[grp],
                                     "work_date": lot_date, "sequence_no": seq, "work_type": work_type, "model_id": self.model_id[model],
                                     "remark": src_json(d)})
        return self.proc_run[pk]

    def link_input(self, d, model, grp, pr, lot_id, raw, field, status="CANDIDATE", note="") -> bool:
        """공정 실행 pr 에 상위 LOT 을 INPUT 으로 연결. 같은 (실행, LOT) 쌍은 한 번만(첫 근거만) 넣는다."""
        if (pr, lot_id) in self.linked:
            return False
        self.linked.add((pr, lot_id))
        return self.add("process_run_lot", {"process_run_lot_id": uid("prl", pr, "IN", lot_id, field, raw), "process_run_id": pr,
                                            "production_lot_id": lot_id, "lot_role": "INPUT", "linkage_status": status,
                                            "evidence_note": f"{field}={raw}. {note}".strip(), "model_id": self.model_id[model]})

    def use_material(self, d, model, grp, pr, kind, raw, field, lot_date, note=None):
        mid = self.material_id[kind]
        mlot = None
        if lot_date:
            # 같은 실행에 같은 자재 LOT 이 여러 필드로 적힌 경우(resin_lot_raw '26.07.02' + resin_trace_lot_id '260702D1') 한 번만
            if (pr, kind, lot_date) in self.mat_linked:
                return
            self.mat_linked.add((pr, kind, lot_date))
            mlot = uid("material_lot", kind, lot_date)
            if self.add("material_lot", {"material_lot_id": mlot, "material_id": mid, "internal_lot_code": f"{yymmdd(lot_date)}D1",
                                         "manufactured_date": lot_date, "verification_status": "UNVERIFIED",
                                         "remark": json.dumps({"dataset": DATASET, "rule": "원문 날짜 표기를 YYYY-MM-DD 로 정규화", "first_seen_raw": raw}, ensure_ascii=False)}):
                pass
        self.add("material_usage", {"material_usage_id": uid("mu", pr, kind, field, raw), "process_run_id": pr, "material_id": mid,
                                    "material_lot_id": mlot, "recorded_lot_code_raw": str(raw)[:100], "usage_role": "INPUT",
                                    "linkage_status": "CANDIDATE", "remark": src_json(d, field=field, normalized_date=lot_date, note=note)})

    # --- 생산 문서 (사출·스티칭·BA·CA)
    def production(self, d, model: str, grp: str):
        details = d.get("details") or {}
        lot_date = d["date"]
        shift, shift_known = shift_of(d)
        # 같은 날 라인이 여러 개(문서 id 의 -L1-, -L2-)면 공정 실행을 순번으로 나눈다 (process_run_result 는 실행당 1행)
        mline = re.search(r"-L(\d)-", d.get("id") or "")
        seq = int(mline.group(1)) if mline else 1
        # 리워크 기록(예 09-30 CA '비전 가성불량 리워크 작업 115EA'): 새 LOT 을 만들지 않고 work_type=REWORK + rework_record 로 남긴다
        rework_qty = to_int(details.get("rework_quantity_ea"))
        is_rework = grp == "CA" and (rework_qty is not None or bool(details.get("rework_note_raw")))
        pr = self.get_process_run(d, model, grp, lot_date, shift, seq, "REWORK" if is_rework else "PRODUCTION")
        if is_rework:
            self.add("rework_record", {"rework_id": uid("rework", d["id"]), "model_id": self.model_id[model], "rework_type": "BA_VISION_RECOVERY" if "비전" in str(details.get("rework_note_raw")) else "OTHER",
                                       "work_date": lot_date, "recorded_qty": rework_qty if rework_qty is not None else to_int(d.get("value")),
                                       "recorded_qty_basis": "DIRECT_COUNT", "validation_status": "NEEDS_REVIEW",
                                       "raw_note": str(details.get("rework_note_raw") or "")[:500],
                                       "remark": src_json(d, note="BA 기록 없는 CA 행 = 리워크. 산출 LOT 생성 안 함(원 LOT 미기재)")})
        qty = to_int(details.get(f"{grp}_quantity_ea")) if grp in ("BA", "CA") and details.get(f"{grp}_quantity_ea") is not None else to_int(d.get("value"))
        minutes = None
        wh = details.get("work_hours_raw")
        if isinstance(wh, dict) and isinstance(wh.get(grp), (int, float)):
            minutes = int(round(float(wh[grp]) * 60))
        for k in ("production_hours", "work_time_hours", "work_hours", "hours"):
            if minutes is None and isinstance(details.get(k), (int, float)):
                minutes = int(round(float(details[k]) * 60))
        page_only = d.get("metric") == "page_evidence"
        self.add("process_run_result", {"process_run_result_id": uid("prr", pr, d["id"]), "process_run_id": pr,
                                        "gross_output_qty": qty, "work_minutes": minutes,
                                        "raw_quantity_text": str(d.get("raw_value") or d.get("value") or ""),
                                        "remark": src_json(d, shift_unknown=not shift_known, page_evidence=page_only,
                                                           operator=mask_name(details.get("operator_raw") or details.get("operator") or details.get("operators")),
                                                           machine=details.get("machine"), program=details.get("program"),
                                                           note="생산량=gross_output_qty(양품/총생산 구분 없음)")})
        if is_rework:
            for kind, raw, field in material_mentions(details):
                self.attach_component(d, model, grp, pr, kind, raw, field, lot_date)
            return pr
        out_lot = self.get_lot(model, grp, lot_date, shift, seq, "NEEDS_REVIEW" if page_only else lot_status_of(d),
                               raw=(d.get("production_lot_id") or d.get("trace_lot_id")) if seq == 1 else None)
        self.lot_has_run.add(out_lot)
        self.run_out_lot[pr] = out_lot
        if grp == "STI" and (lot_date, pr) not in self.sti_runs[model]:
            self.sti_runs[model].append((lot_date, pr))
        self.add("process_run_lot", {"process_run_lot_id": uid("prl", pr, "OUT", out_lot), "process_run_id": pr,
                                     "production_lot_id": out_lot, "lot_role": "OUTPUT", "recorded_quantity": qty, "quantity_unit": "EA",
                                     "raw_quantity_text": str(d.get("raw_value") or d.get("value") or ""), "linkage_status": "CANDIDATE",
                                     "evidence_note": "공정 LOT = 작업일 규칙으로 산출 LOT 연결", "model_id": self.model_id[model]})
        # 투입: 부품은 상위 공정 LOT(INPUT), 원자재는 material_usage. 원문에 날짜가 여러 개면 각각 연결.
        # (모든 생산 실행이 만들어진 뒤 한꺼번에 붙인다: 와이어→BA, 케이스→CA 재배정 때문)
        for kind, raw, field in material_mentions(details):
            self.pending_components.append((d, model, grp, pr, kind, raw, field, lot_date))
        # 공정 불량
        for name, n, raw in defect_items(details):
            self.add("quality_finding", {"quality_finding_id": uid("qf", d["id"], name), "process_run_id": pr,
                                         "defect_type_id": self.defect(grp, name), "finding_class": "PROCESS_DEFECT",
                                         "quantity": n, "quantity_unit": "EA", "raw_quantity_text": raw, "raw_defect_name": name[:100],
                                         "validation_status": "NEEDS_REVIEW" if n is None else status_of(d),
                                         "remark": src_json(d), "model_id": self.model_id[model]})
        return pr

    def attach_component(self, d, model, grp, pr, kind, raw, field, base_date):
        """부품·원자재 원문 한 건을 공정 실행 pr 에 붙인다.
        - 스티칭(STI) 의 보빈 날짜 → 사출 LOT INPUT (보빈 LOT = 사출 작업일). 날짜는 스티칭 매칭용으로도 기억.
        - BA 의 인서트 날짜 → 스티칭 LOT INPUT (직접 매칭).
        - BA 의 보빈 날짜 → 사출 LOT 으로 바로 잇지 않는다. 같은 보빈 날짜를 쓴 스티칭 일보를 찾는 열쇠로만 쓴다
          (match_ba_stitching). 원문 보존을 위해 material_usage(보빈, LOT 없음) 한 줄은 남긴다.
        - 그 외 원자재는 material_usage.
        """
        raw = str(raw)
        dates = lot_dates_in(raw, base_date)
        upstream = MATERIAL[kind][2]
        uncertain = bool(re.search(r"보임|판독|UNCERTAIN|\?", raw))
        home = MATERIAL_HOME.get(kind)
        moved = None
        if home and grp in ("BA", "CA") and home in ("BA", "CA") and home != grp:
            # 조립일보 한 장에 BA·CA 가 같이 있어 와이어(BA 자재)가 CA 문서에, 케이스(CA 자재)가 BA 문서에 적힌다 → 홈 공정 실행으로
            seq = int((re.search(r"-L(\d)-", d.get("id") or "") or re.match(r"(?=x)x", "") or [None, 1])[1] or 1) if re.search(r"-L(\d)-", d.get("id") or "") else 1
            target = self.find_run(model, home, base_date, d, seq)
            if target:
                moved, grp, pr = f"{PROCESS[home][1]} 자재 → 같은 조립일보의 {home} 실행에 기록", home, target
        if grp == "CA" and kind in ("BOBBIN", "INSERT"):
            # 8월 양식 CA 문서는 같은 조립일보의 BA 부품(보빈·인서트) 날짜를 중복 기재한다. CA 의 투입은 BA 산출 LOT 이므로
            # 상위 LOT 으로 잇지 않고 원문 보존(material_usage, LOT 없음)만 한다.
            self.use_material(d, model, grp, pr, kind, raw, field, None, note="CA 문서의 BA 부품 날짜 중복 기재. 사슬 연결은 BA 실행에서만")
            return
        if kind == "BOBBIN" and grp == "BA":
            if not dates:
                self.pending[f"BA 보빈 LOT 원문 해석 불가(날짜 없음: 예 '{raw[:20]}')"] += 1
                return
            for tok, ldate in dates:
                self.ba_bobbin.append((d, model, pr, base_date, raw, field, tok, ldate))
            self.use_material(d, model, grp, pr, kind, raw, field, None,
                              note="BA 보빈 날짜는 스티칭 일보 매칭 근거로만 사용(사출 LOT 직접 연결 안 함)")
            return
        if upstream:
            if not dates:
                self.pending[f"{MATERIAL[kind][1]} LOT 원문 해석 불가(날짜 없음: 예 '{raw[:20]}')"] += 1
                return
            for tok, ldate in dates:
                if kind == "BOBBIN" and grp == "STI":
                    self.sti_bobbin[pr].add(ldate)
                up_lot = self.get_lot(model, upstream, ldate, "D", 1, "NEEDS_REVIEW",
                                      note="하위 공정 기록에서 참조된 상위 LOT(상위 작업일보 미확인)")
                self.link_input(d, model, grp, pr, up_lot, raw, field,
                                note=f"{MATERIAL[kind][1]} 날짜 표기 '{tok}' → {PROCESS[upstream][1]} LOT"
                                     + (" (인서트 날짜 직접 매칭)" if kind == "INSERT" else "")
                                     + (" (원문 판독 불확실)" if uncertain else ""))
            return
        note = moved or ("스티칭(BS) 자재(리드핀)이 조립일보에 기재됨. 참고용" if kind == "LEAD_PIN" and grp in ("BA", "CA") else None)
        if dates:
            for tok, ldate in dates:
                self.use_material(d, model, grp, pr, kind, tok if len(dates) > 1 else raw, field, ldate, note=note)
        else:
            self.use_material(d, model, grp, pr, kind, raw, field, None, note=note)

    # --- BA ← 스티칭: BA 일보의 보빈 날짜 = 15일 범위(BA 작업일 포함) 안 스티칭 일보의 보빈 날짜 → 그 스티칭 LOT 을 모두 INPUT 으로
    def match_ba_stitching(self):
        matched = Counter()
        for d, model, pr, ba_date, raw, field, tok, ldate in self.ba_bobbin:
            base = date.fromisoformat(ba_date)
            hits = []
            for sdate, spr in self.sti_runs.get(model, ()):
                sd = date.fromisoformat(sdate)
                if (base - sd).days < 0 or (base - sd).days > STI_MATCH_WINDOW_DAYS:
                    continue
                if ldate in self.sti_bobbin.get(spr, ()):
                    hits.append((sdate, spr))
            if not hits:
                self.hold(d, f"BA 보빈 날짜와 같은 보빈을 쓴 스티칭 일보 없음({STI_MATCH_WINDOW_DAYS}일 범위)")
                continue
            for sdate, spr in sorted(hits):
                if self.link_input(d, model, "BA", pr, self.run_out_lot[spr], raw, f"{field}~stitching",
                                   note=f"보빈 날짜 매칭: BA 보빈 '{tok}'({ldate}) = 스티칭 {sdate} 일보 보빈 → 그 스티칭 LOT. {STI_MATCH_WINDOW_DAYS}일 범위, 후보 {len(hits)}개"):
                    matched[model] += 1
        self.stats_ba_sti = matched

    # --- BA -> CA: 같은 조립일보(같은 파일·날짜·모델)면 BA 산출 LOT 을 CA 투입으로 연결
    def ba_to_ca(self, docs):
        """같은 조립작업일보(파일·날짜·모델·라인)의 BA 실행 산출 LOT 을 CA 실행의 INPUT 으로. 라인(-L1-/-L2-)이 있으면 라인별로 짝짓는다.
        BA 와 CA 는 같은 날 같은 LOT 이므로 두 실행의 생산량 차이(불량·이월)는 process_run_result 로 비교한다."""
        def seq_of(d):
            mm = re.search(r"-L(\d)-", d.get("id") or "")
            return int(mm.group(1)) if mm else 1
        ba = {}
        for d in docs:
            if variant_of(d) and PROCESS_OF.get(d.get("process")) == "BA" and d.get("date"):
                pr = self.find_run(variant_of(d), "BA", d["date"], d, seq_of(d))
                if pr:
                    ba[(variant_of(d), d["date"], (d.get("source") or {}).get("file"), seq_of(d))] = pr
        for d in docs:
            if not (variant_of(d) and PROCESS_OF.get(d.get("process")) == "CA" and is_production(d)):
                continue
            det = d.get("details") or {}
            if to_int(det.get("rework_quantity_ea")) is not None or det.get("rework_note_raw"):
                continue   # 리워크 행: 새 LOT 이 아니므로 BA→CA 연결 대상이 아님
            model, seq = variant_of(d), seq_of(d)
            ba_pr = ba.get((model, d["date"], (d.get("source") or {}).get("file"), seq))
            if not ba_pr:
                self.hold(d, "CA 기록에 같은 조립일보의 BA 기록 없음(BA→CA 미연결)")
                continue
            pr = self.find_run(model, "CA", d["date"], d, seq)
            if not pr or ba_pr not in self.run_out_lot:
                continue
            self.link_input(d, model, "CA", pr, self.run_out_lot[ba_pr], "same_journal", "ba_output",
                            note="같은 조립작업일보(파일·날짜·모델)의 BA 산출 LOT. 날짜 일치 근거이므로 CANDIDATE")

    # --- 최종검사
    @staticmethod
    def inspection_mappings(d) -> list[dict]:
        """최종검사 문서의 LOT 표기 목록. 9월 양식 trace_lot_mappings, 8월 양식 lot_entries_raw / inspection_lots_raw."""
        details = d.get("details") or {}
        mappings = list(d.get("trace_lot_mappings") or [])
        if not mappings:
            for e in details.get("lot_entries_raw") or []:
                mappings.append({"raw_lot": f"{e.get('lot_code')}={e.get('boxes_raw')}", "lot_code": e.get("lot_code"),
                                 "product_lot_date": e.get("product_lot_date"), "normalization_status": "MATCHED" if e.get("product_lot_date") else "UNRESOLVED"})
            for raw in details.get("inspection_lots_raw") or []:
                mappings.append({"raw_lot": raw, "lot_code": str(raw)[:3], "product_lot_date": None, "normalization_status": "UNRESOLVED"})
        return mappings

    def seed_markings(self, docs):
        """원문 판독에서 날짜가 확정(MATCHED)된 마킹코드를 먼저 모두 등록한다.
        그래야 뒤에 오는 판독 불확실 문서가 조견표 규칙 추정으로 같은 코드를 먼저 만들어 버리지 않는다."""
        for d in docs:
            if PROCESS_OF.get(d.get("process")) != "FIN" or not variant_of(d):
                continue
            for m in self.inspection_mappings(d):
                code, ldate = m.get("lot_code"), m.get("product_lot_date")
                if code and ldate and m.get("normalization_status") == "MATCHED" and code not in self.marking:
                    self.marking[code] = ldate
                    self.add("lot_code_mapping", {"mapping_id": uid("lot_code_mapping", code), "scheme_id": self.scheme_id, "marking_code": code,
                                                  "lot_date": ldate, "validation_status": "UNVERIFIED", "remark": f"rule={m.get('mapping_rule')}"})

    def get_worker(self, raw) -> tuple[str | None, str | None, str | None]:
        """검사자 원문 -> (worker_id, 가린 이름, 역할 추정). 이름은 가린 형태만 저장한다. 여러 명이면 worker 는 None."""
        names = [x.strip() for x in re.split(r"[;,/]", str(raw or "")) if x.strip()]
        # '홍길동(판독)', '홍길동으로 판독 추정', '검사자 홍길동', '김세?' → 이름만
        names = [re.sub(r"\(.*?\)|\?|검사자|(으)?로\s*판독.*$|판독\s*후보|추정", "", n).strip() for n in names]
        names = [n for n in names if NAME_RE.search(n)]
        if not names:
            return None, None, None
        masked = mask_name(names[0])
        role = "전담(확인)" if masked in DEDICATED_INSPECTORS_MASKED else "신입·타라인 지원"
        if len(names) > 1:
            return None, ", ".join(mask_name(n) for n in names), "복수 검사자"
        if masked not in self.workers:
            self.workers[masked] = uid("worker", masked)
            self.add("worker", {"worker_id": self.workers[masked], "worker_code": f"INSP-{self.workers[masked][:8]}", "worker_display_name": masked,
                                "remark": json.dumps({"dataset": DATASET, "role": f"최종검사자 {role}",
                                                      "note": "이름은 가운데를 가린 표시명만 저장. 전담 4명은 사용자 확인(2026-10-29), 그 외는 신입/타라인 지원 미구분"}, ensure_ascii=False)})
        return self.workers[masked], masked, role

    @staticmethod
    def inspection_meta(d) -> dict:
        """문서에서 검사 유형·차수·방법·범위를 읽는다. 1차=훈련 검사, 2차=전담 검사(실제 검사 수량), 재검·현미경=불량 이벤트 재검사."""
        details = d.get("details") or {}
        src = d.get("source") or {}
        cls = str(details.get("inspection_class_raw") or "")
        item = str(details.get("inspection_item_raw") or "")
        # 비고·메모·파일경로·검사구분만 본다. defects_raw 는 '미성형' 같은 불량 항목명이 들어 있어 제외한다.
        text = " ".join(str(details.get(k) or "") for k in ("supplementary_notes_raw", "note_raw", "comment_raw", "reason"))
        text += " " + str(src.get("relative_path", "")) + " " + cls
        is_re = d.get("process") == "REINSPECTION" or d.get("metric") == "REINSPECTED_QTY" or "재검" in text or "recheck" in text.lower()
        in_process = "미성형 검사" in item or "미성형검사" in item          # 보빈·스티칭 미성형 검사(공정 중 검사)
        micro = bool(re.search(r"현미경|microscope", item, re.I))         # 검사 항목 자체가 현미경검사일 때만 방법을 바꾼다
        micro_note = bool(re.search(r"현미경|microscope", text, re.I))    # 비고에 현미경 재검 메모가 있음(별도 이벤트)
        itype = "IN_PROCESS" if in_process else ("REINSPECTION" if is_re else "FINAL")
        rnd = 2 if re.search(r"2차", cls) else 1 if re.search(r"1차", cls) else None
        target = None
        mt = re.search(r"(L/C\s*찍힘|Bobbin\s*파손|Lead\s*Pin\s*휨|Marking|U/C\s*찍힘|Post\s*파손|Wire\s*Damage)\s*재검", text, re.I)
        if mt:
            target = mt.group(1)
        return {"type": itype, "stage": "OTHER" if in_process else "FINAL", "method": "MICROSCOPE" if micro else "VISUAL_MANUAL",
                "scope": "TARGETED" if (is_re or micro) else "ROUTINE", "round": rnd, "class_raw": cls or None, "target_defect": target,
                "is_re": is_re, "micro_note": micro_note}

    def inspection(self, d, model: str):
        details = d.get("details") or {}
        meta = self.inspection_meta(d)
        ir = uid("inspection_run", d["id"])
        qty = to_int(d.get("value")) if d.get("unit") in (None, "EA") else None
        note_text = str(details.get("note_raw") or details.get("comment_raw") or "")
        if qty is None and note_text:   # 보조 기록(예 'L/C 찍힘 재검 16,320EA')에서 수량을 읽는다
            mq = QTY_EA.search(note_text)
            if mq:
                qty = int(mq.group(1).replace(",", ""))
        worker_id, inspector_masked, role = self.get_worker(details.get("inspector_raw") or details.get("inspector") or details.get("inspectors_raw"))
        # 차수: 원문 표기 우선, 없으면 검사자 역할로 추정(전담=2차=실제 검사 수량, 훈련·타라인=1차)
        rnd = meta["round"] or (2 if role == "전담(확인)" else 1)
        if meta["type"] == "REINSPECTION" and meta["round"] is None:
            rnd = 2
        target_id = self.defect("FIN", meta["target_defect"]) if meta["target_defect"] else None
        self.add("inspection_run", {"inspection_run_id": ir, "model_id": self.model_id[model], "inspection_date": d.get("inspection_date") or d["date"],
                                    "inspector_id": worker_id,
                                    "inspection_type": meta["type"], "inspection_stage": meta["stage"], "inspection_round_no": rnd,
                                    "inspection_method": meta["method"], "inspection_scope": meta["scope"], "target_defect_type_id": target_id,
                                    "inspected_qty_ea": qty, "raw_inspection_label": str(d.get("metric")),
                                    "validation_status": "NEEDS_REVIEW" if d.get("metric") == "page_evidence" or d.get("metric") not in FIN_QTY_METRICS else status_of(d),
                                    # 검사자 이름은 가운데를 * 로 가려서 남긴다(개인정보 보호, 사용자 지시 2026-10-29)
                                    "remark": src_json(d, inspector=inspector_masked, inspector_role=role, class_raw=meta["class_raw"],
                                                       round_basis="원문 차수 표기" if meta["round"] else "검사자 역할 추정",
                                                       hours=details.get("inspection_hours_raw") or details.get("hours") or details.get("inspection_hours"),
                                                       qty_from_note=bool(qty is not None and to_int(d.get("value")) is None),
                                                       micro_note=meta["micro_note"] or None,
                                                       duplicate_status=details.get("duplicate_status"))})
        self.insp_runs[ir] = {"model": model, "date": d.get("inspection_date") or d["date"], "type": meta["type"], "round": rnd, "lots": set(), "re": meta["is_re"]}
        # 공정 중 검사(미성형 검사): raw_lot_entries '26.8.28=9000' -> 상위 LOT(스티칭/사출) 날짜
        if meta["type"] == "IN_PROCESS":
            grp = "STI" if "스티칭" in str(details.get("inspection_item_raw") or "") else "INJ"
            for raw in details.get("raw_lot_entries") or []:
                raw = str(raw)
                mq = re.search(r"=\s*([\d,]+)", raw)
                for tok, ldate in lot_dates_in(raw.split("=")[0], d["date"]):
                    lot_id = self.get_lot(model, grp, ldate, "D", 1, "NEEDS_REVIEW", note="공정 중 검사 기록에서 참조된 LOT")
                    self.insp_runs[ir]["lots"].add(lot_id)
                    self.add("inspection_lot", {"inspection_lot_id": uid("inspection_lot", ir, raw, tok), "inspection_run_id": ir,
                                                "production_lot_id": lot_id, "lot_code_raw": raw[:100],
                                                "inspected_qty_ea": int(mq.group(1).replace(",", "")) if mq else None,
                                                "recorded_quantity_raw": raw, "lot_linkage_status": "CANDIDATE",
                                                "remark": json.dumps({"dataset": DATASET, "rule": f"{PROCESS[grp][1]} LOT = 날짜 표기 '{tok}'"}, ensure_ascii=False),
                                                "model_id": self.model_id[model]})
        for m in self.inspection_mappings(d):
            raw = str(m.get("raw_lot") or m.get("lot_code") or "")
            ldate = m.get("product_lot_date") if m.get("normalization_status") == "MATCHED" else None
            code = m.get("lot_code")
            # 코드가 'ZIC=2 BOX', 'ZID?' 처럼 원문에 섞여 있으면 조견표 코드 3자만 뗀다. 'Z?N'(글자 빠짐)은 못 뗀다.
            code_uncertain = False
            if not chart_date(code):
                mc = CHART_CODE.search(raw.upper())
                if mc:
                    code, code_uncertain = mc.group(1), bool(mc.group(2))
            how = None
            if ldate and code:
                how = f"rule={m.get('mapping_rule')}"
            elif code:
                # 원문 판독에 날짜가 없으면: 이미 아는 매핑 → 그 날짜, 아니면 조견표 규칙으로 추정 (모두 CANDIDATE)
                if code in self.marking:
                    ldate, how = self.marking[code], "known_mapping"
                elif chart_date(code):
                    ldate, how = chart_date(code), "rule=IMEB3_CHART_RULE_INFERRED(Z+월A..L+일A..Z/2..6)"
            lot_id = None
            if ldate and code:
                if code not in self.marking:
                    self.marking[code] = ldate
                    self.add("lot_code_mapping", {"mapping_id": uid("lot_code_mapping", code), "scheme_id": self.scheme_id, "marking_code": code,
                                                  "lot_date": ldate, "validation_status": "UNVERIFIED", "remark": how})
                lot_id = self.get_lot(model, "CA", ldate, "D", 1, "NEEDS_REVIEW", raw=f"{yymmdd(ldate)}D1",
                                      note="최종검사 LOT 마킹코드로 참조된 CA LOT(CA 작업일보 미확인)")
            boxes = re.search(r"=\s*(\d+)\s*(BOX|box)", raw)
            self.add("inspection_lot", {"inspection_lot_id": uid("inspection_lot", ir, raw), "inspection_run_id": ir,
                                        "production_lot_id": lot_id, "lot_code_raw": raw[:100],
                                        "recorded_box_count": int(boxes.group(1)) if boxes else None,
                                        "recorded_quantity_raw": raw, "lot_linkage_status": "CANDIDATE" if lot_id else "UNRESOLVED",
                                        # 조견표 규칙·기존 매핑으로 이은 경우에만 근거를 덧붙인다(원문 판독(MATCHED) 행의 remark 는 그대로)
                                        "remark": json.dumps({"dataset": DATASET, "marking_code": code, "normalization_status": m.get("normalization_status"),
                                                              **({"linked_by": how} if how and not how.startswith("rule=I") or how == "known_mapping" else {}),
                                                              **({"code_uncertain": True} if code_uncertain else {})}, ensure_ascii=False),
                                        "model_id": self.model_id[model]})
            if lot_id:
                self.insp_runs[ir]["lots"].add(lot_id)
        for name, n, raw in defect_items(details):
            self.add("quality_finding", {"quality_finding_id": uid("qf", d["id"], name), "inspection_run_id": ir,
                                         "defect_type_id": self.defect("FIN", name), "finding_class": "FINAL_DEFECT",
                                         "quantity": n, "quantity_unit": "EA", "raw_quantity_text": raw, "raw_defect_name": name[:100],
                                         "validation_status": "NEEDS_REVIEW" if n is None else status_of(d),
                                         "remark": src_json(d), "model_id": self.model_id[model]})

    # --- 검사 실행 간 관계(inspection_run_link): 1차(훈련)→2차(전담) 확인, 재검→직전 본검사
    def link_inspections(self):
        def add_link(prior, follow, rel, note):
            if prior == follow:
                return
            self.add("inspection_run_link", {"inspection_run_link_id": uid("irl", prior, follow, rel), "prior_inspection_run_id": prior,
                                             "followup_inspection_run_id": follow, "relation_type": rel, "linkage_status": "CANDIDATE",
                                             "evidence_note": note, "model_id": self.model_id[self.insp_runs[prior]["model"]]})
        by_lot = defaultdict(list)
        for ir, r in self.insp_runs.items():
            for lot in r["lots"]:
                by_lot[lot].append((r["date"], ir))
        n_train = n_re = 0
        for lot, runs in by_lot.items():
            runs.sort()
            for i, (dt, ir) in enumerate(runs):
                r = self.insp_runs[ir]
                if r["type"] == "FINAL" and r["round"] == 1 and not r["re"]:
                    nxt = next(((d2, j) for d2, j in runs[i + 1:] if self.insp_runs[j]["type"] == "FINAL" and self.insp_runs[j]["round"] == 2 and not self.insp_runs[j]["re"]), None)
                    if nxt:
                        add_link(ir, nxt[1], "TRAINING_CONFIRMATION", f"같은 CA LOT: 1차(신입·타라인 지원) 검사 {dt} → 2차(전담) 검사 {nxt[0]}. 실제 검사 수량은 2차")
                        n_train += 1
                if r["re"]:
                    prev = next(((d2, j) for d2, j in reversed(runs[:i]) if not self.insp_runs[j]["re"]), None)
                    if prev:
                        add_link(prev[1], ir, "RECHECK_OF_REJECTS", f"같은 LOT 본검사 {prev[0]} 뒤 재검사 {dt}(불량 이벤트)")
                        n_re += 1
        # LOT 표기가 없는 재검 메모(예 'L/C 찍힘 재검 16,320EA')는 같은 날·같은 모델의 본검사에 TARGETED_REINSPECTION 으로 건다
        by_md = defaultdict(list)
        for ir, r in self.insp_runs.items():
            if r["type"] == "FINAL" and not r["re"]:
                by_md[(r["model"], r["date"])].append(ir)
        n_t = 0
        for ir, r in self.insp_runs.items():
            if r["re"] and not r["lots"]:
                for prior in by_md.get((r["model"], r["date"]), []):
                    add_link(prior, ir, "TARGETED_REINSPECTION", "같은 날·같은 모델 본검사 뒤 불량 항목 재검 메모(LOT 미기재)")
                    n_t += 1
        self.stats_insp_link = {"TRAINING_CONFIRMATION": n_train, "RECHECK_OF_REJECTS": n_re, "TARGETED_REINSPECTION": n_t}

    # --- 조립 리워크 작업 기록 -> rework_record (BA 없이 CA 만 있는 일보도 비고가 리워크면 여기로 온다)
    def rework(self, d, model: str):
        details = d.get("details") or {}
        note = str(details.get("raw_note") or details.get("rework_note_raw") or details.get("note_raw") or "")
        hours = re.search(r"(\d+(?:\.\d+)?)\s*h", str(details.get("work_hours_raw") or ""), re.I)
        self.add("rework_record", {"rework_id": uid("rework", d["id"]), "model_id": self.model_id[model],
                                   "rework_type": "BA_VISION_RECOVERY" if re.search(r"비전|vision", note, re.I) else "OTHER",
                                   "work_date": d.get("date"), "recorded_qty": to_int(d.get("value")),
                                   "recorded_qty_basis": "DIRECT_COUNT" if to_int(d.get("value")) is not None else "UNKNOWN",
                                   "work_minutes": int(float(hours.group(1)) * 60) if hours else None,
                                   "validation_status": "NEEDS_REVIEW", "raw_note": note[:500],
                                   "remark": src_json(d, note="조립 리워크 작업 기록. 원 LOT 미기재, 새 LOT 생성 안 함")})

    # --- 조립카드 사진 -> traceability_card
    def card(self, d, model: str):
        details = d.get("details") or {}
        sr = str(details.get("serial_range_raw") or "")
        m = re.match(r"(\d+)\s*-\s*(\d+)", sr)
        self.add("traceability_card", {"traceability_card_id": uid("card", d["id"]), "model_id": self.model_id[model],
                                       "card_reference_raw": (d.get("source") or {}).get("file"), "marked_lot_code_raw": d.get("lot_id_raw"),
                                       "serial_start_raw": m.group(1) if m else sr or None, "serial_end_raw": m.group(2) if m else None,
                                       "actual_box_qty": to_int(details.get("good_qty") or d.get("value")), "card_date": d["date"],
                                       "validation_status": status_of(d),
                                       # 작업자 이름은 가운데를 * 로 가린다
                                       "raw_note": json.dumps({k: (mask_name(v) if any(w in k for w in ("operator", "inspector", "worker")) else v)
                                                               for k, v in details.items()}, ensure_ascii=False)[:1000],
                                       "remark": src_json(d)})

    # --- 타임라인 -> production_event
    def event(self, d, model: str):
        details = d.get("details") or {}
        grp = PROCESS_OF.get(details.get("process"), "INJ")
        shift, _ = shift_of(d)
        pr = self.proc_run.get((model, grp, d["date"], shift, 1))
        st = details.get("start_time")
        # 제약 ck_production_event_exactly_one_target: 공정실행 또는 작업구간 중 하나만 가리킨다
        self.add("production_event", {"event_id": uid("event", d["id"]), "process_run_id": pr,
                                      "production_run_id": None if pr else self.prod_run.get((model, d["date"], shift)),
                                      "event_type": "OTHER", "event_date": d["date"],
                                      "event_start_at": f"{d['date']}T{st}:00+09:00" if st and re.fullmatch(r"\d{1,2}:\d{2}", st) else None,
                                      "duration_minutes": to_int(d.get("value")), "event_description": str(details.get("reason") or "")[:500],
                                      "validation_status": status_of(d), "remark": src_json(d)})

    # --- 전체
    def build(self, docs: dict):
        self.masters()
        rows = [d for d in docs.values() if d.get("process")]
        for d in docs.values():
            if not d.get("process"):
                self.hold(d, "process 없음")
        # 1차: 생산 문서(산출 LOT 먼저 만들어야 BA→CA, 타임라인이 연결된다)
        #      8월 자료는 metric=page_evidence 에 생산량이 들어 있어 같이 생산 기록으로 본다(NEEDS_REVIEW).
        for d in rows:
            grp = PROCESS_OF.get(d["process"])
            model = variant_of(d)
            if grp in ("INJ", "STI", "BA", "CA") and is_production(d):
                if not model:
                    self.hold(d, f"모델 불확실({d.get('variant')}) - 생산 기록")
                elif not d.get("date"):
                    self.hold(d, "작업일 없음")
                else:
                    self.production(d, model, grp)
        # 8월 양식: BA 페이지 근거 문서(page_evidence)에 생산량이 없어도 같은 날 CA 생산 기록이 있으면 BA 실행(수량 미상)을 만든다.
        #           BA 와 CA 는 같은 조립일보·같은 LOT 이라 BA 가 비면 사슬이 끊긴다 (사용자 지시 2026-10-29).
        for d in rows:
            model = variant_of(d)
            if (PROCESS_OF.get(d["process"]) == "BA" and not is_production(d) and d.get("metric") == "page_evidence" and model and d.get("date")
                    and any(k[:3] == (model, "CA", d["date"]) for k in self.proc_run)):
                self.production(d, model, "BA")
                d["_attached"] = True
        for args in self.pending_components:
            self.attach_component(*args)
        self.pending_components = []
        self.ba_to_ca(rows)
        # 1.5차: 9월 초 양식처럼 보빈·인서트 LOT 이 별도 문서(metric=BOBBIN_LOT 등)로 쪼개진 경우를 먼저 실행에 붙인다
        #        (스티칭 매칭 전에 BA 보빈 날짜가 모두 모여 있어야 한다)
        for d in rows:
            grp = PROCESS_OF.get(d["process"])
            model = variant_of(d)
            metric = str(d.get("metric") or "")
            if grp not in ("INJ", "STI", "BA", "CA") or is_production(d) or not model or not d.get("date"):
                continue
            kind = {"WIRE_LOT": "WIRE", "BOBBIN_LOT": "BOBBIN", "LEAD_PIN_LOT": "LEAD_PIN", "UPPER_CASE_LOT": "UPPER_CASE",
                    "LOWER_CASE_LOT": "LOWER_CASE", "LEAD_PIN_INSERT": "INSERT", "INSERT_LOT": "INSERT", "RESIN_LOT": "RESIN"}.get(metric)
            if not kind or d.get("value") in (None, ""):
                continue
            pr = self.find_run(model, grp, d["date"], d)
            if not pr:
                continue   # 2차에서 '같은 날 생산 기록 없음' 으로 보류됨
            self.attach_component(d, model, grp, pr, kind, d.get("value"), metric, d["date"])
            d["_attached"] = True
        self.match_ba_stitching()
        self.seed_markings(rows)
        # 2차: 나머지
        for d in rows:
            grp = PROCESS_OF.get(d["process"])
            model = variant_of(d)
            metric = d.get("metric")
            if grp in ("INJ", "STI", "BA", "CA") and is_production(d):
                continue
            if grp == "FIN":
                if not model:
                    self.hold(d, f"모델 불확실({d.get('variant')}) - 최종검사")
                elif metric in FIN_QTY_METRICS:
                    self.inspection(d, model)
                elif self.inspection_meta(d)["is_re"] and QTY_EA.search(str((d.get("details") or {}).get("note_raw") or "")):
                    self.inspection(d, model)   # 비고란 재검 메모(수량 있음) → 재검사 실행(NEEDS_REVIEW)
                else:
                    self.hold(d, f"최종검사 보조 기록(metric={metric}) - 원본 보존만 필요")
            elif grp == "REWORK":
                self.rework(d, model) if model else self.hold(d, "모델 불확실 - 리워크 기록")
            elif grp == "CARD":
                self.card(d, model) if model else self.hold(d, "모델 불확실 - 조립카드")
            elif grp == "TIMELINE":
                self.event(d, model) if model else self.hold(d, "모델 불확실 - 타임라인")
            elif grp in ("INJ", "STI", "BA", "CA"):
                # 생산량 외 항목(*_LOT, WORK_TIME, *_NG, PROGRAM 등): 같은 공정 실행에 자재/불량으로 붙인다
                if not model or not d.get("date"):
                    self.hold(d, f"모델 불확실 - {grp} 보조 항목")
                    continue
                if d.get("_attached"):
                    continue
                pr = self.find_run(model, grp, d["date"], d)
                if not pr:
                    self.hold(d, f"{grp} 보조 항목인데 같은 날 생산 기록 없음(metric={metric})")
                    continue
                if str(metric).endswith("_NG") and to_int(d.get("value")) is not None:
                    self.add("quality_finding", {"quality_finding_id": uid("qf", d["id"], metric), "process_run_id": pr,
                                                 "defect_type_id": self.defect(grp, metric), "finding_class": "EQUIPMENT_REJECT" if "VISION" in metric else "PROCESS_DEFECT",
                                                 "quantity": to_int(d.get("value")), "quantity_unit": "EA", "raw_quantity_text": str(d.get("value")),
                                                 "raw_defect_name": metric, "validation_status": status_of(d), "remark": src_json(d), "model_id": self.model_id[model]})
                    continue
                self.hold(d, f"{grp} 보조 항목 미변환(metric={metric})")
            else:
                self.hold(d, f"공정 분류 불가(process={d['process']})")
        self.link_inspections()


# ----------------------------------------------------------------- SQL
ORDER = ["product", "product_model", "process", "material", "defect_type", "lot_code_scheme", "lot_code_mapping",
         "production_run", "process_run", "process_run_result", "production_lot", "process_run_lot",
         "material_lot", "material_usage", "worker", "inspection_run", "inspection_lot", "inspection_run_link", "quality_finding",
         "traceability_card", "production_event", "rework_record"]
PK = {"product": "product_id", "product_model": "model_id", "process": "process_id", "material": "material_id",
      "defect_type": "defect_type_id", "lot_code_scheme": "scheme_id", "lot_code_mapping": "mapping_id",
      "production_run": "run_id", "process_run": "process_run_id", "process_run_result": "process_run_result_id",
      "production_lot": "lot_id", "process_run_lot": "process_run_lot_id", "material_lot": "material_lot_id",
      "material_usage": "material_usage_id", "inspection_run": "inspection_run_id", "inspection_lot": "inspection_lot_id",
      "quality_finding": "quality_finding_id", "traceability_card": "traceability_card_id", "production_event": "event_id",
      "rework_record": "rework_id", "worker": "worker_id", "inspection_run_link": "inspection_run_link_id"}
FK = {  # (table, column) -> referenced table ; 생성된 행 안에서 참조 무결성 자체 점검용
    ("product_model", "product_id"): "product", ("production_run", "model_id"): "product_model",
    ("process_run", "run_id"): "production_run", ("process_run", "process_id"): "process", ("process_run", "model_id"): "product_model",
    ("process_run_result", "process_run_id"): "process_run", ("production_lot", "model_id"): "product_model",
    ("process_run_lot", "process_run_id"): "process_run", ("process_run_lot", "production_lot_id"): "production_lot",
    ("material_lot", "material_id"): "material", ("material_usage", "process_run_id"): "process_run",
    ("material_usage", "material_id"): "material", ("material_usage", "material_lot_id"): "material_lot",
    ("inspection_run", "model_id"): "product_model", ("inspection_lot", "inspection_run_id"): "inspection_run",
    ("inspection_lot", "production_lot_id"): "production_lot", ("quality_finding", "inspection_run_id"): "inspection_run",
    ("quality_finding", "process_run_id"): "process_run", ("quality_finding", "defect_type_id"): "defect_type",
    ("lot_code_mapping", "scheme_id"): "lot_code_scheme", ("traceability_card", "model_id"): "product_model",
    ("production_event", "process_run_id"): "process_run", ("production_event", "production_run_id"): "production_run",
    ("rework_record", "model_id"): "product_model",
    ("inspection_run", "inspector_id"): "worker", ("inspection_run", "target_defect_type_id"): "defect_type",
    ("inspection_run_link", "prior_inspection_run_id"): "inspection_run", ("inspection_run_link", "followup_inspection_run_id"): "inspection_run",
}


def lit(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


MAX_FILE_BYTES = 600_000   # SQL Editor 에 붙여넣기 좋은 크기. 넘으면 번호를 붙여 나눈다(순서대로 실행).


def write_sql(T: dict, path: Path) -> tuple[int, list[Path]]:
    header = (f"-- {DATASET}: Firestore(M1-2) -> mqi. 생성 {datetime.now():%Y-%m-%d %H:%M}. 재실행 안전(ON CONFLICT DO NOTHING).\n"
              "BEGIN ISOLATION LEVEL SERIALIZABLE;\n"
              f"SET LOCAL mqi.actor_ref = {lit(ACTOR)};\nSET LOCAL mqi.change_reason = {lit(REASON)};\n\n")
    stmts = []
    for t in ORDER:
        for r in T.get(t, []):
            cols = [c for c in r if r[c] is not None]
            # ON CONFLICT DO NOTHING (대상 없음): PK 뿐 아니라 모든 고유 제약(예: process_run_result 는 실행당 1행)에서 중복이면 건너뛴다
            stmts.append(f"INSERT INTO mqi.{t} ({', '.join(cols)}) VALUES ({', '.join(lit(r[c]) for c in cols)}) ON CONFLICT DO NOTHING;\n")
    parts, cur, size = [], [], 0
    for s in stmts:
        if cur and size + len(s.encode("utf-8")) > MAX_FILE_BYTES:
            parts.append(cur)
            cur, size = [], 0
        cur.append(s)
        size += len(s.encode("utf-8"))
    if cur:
        parts.append(cur)
    files = []
    for i, p in enumerate(parts, start=1):
        fp = path if len(parts) == 1 else path.with_name(f"{path.stem}_{i}of{len(parts)}{path.suffix}")
        fp.write_text(header.replace("-- ", f"-- [{i}/{len(parts)}] ", 1) + "".join(p) + "COMMIT;\n", encoding="utf-8")
        files.append(fp)
    return len(stmts), files


def self_check(T: dict) -> list[str]:
    ids = {t: {r[PK[t]] for r in rows} for t, rows in T.items()}
    errs = []
    for (t, col), ref in FK.items():
        for r in T.get(t, []):
            v = r.get(col)
            if v is not None and v not in ids.get(ref, set()):
                errs.append(f"{t}.{col} -> {ref} 없음: {v}")
    return errs


# ----------------------------------------------------------------- 보고서
def chain_report(b: Builder) -> list[str]:
    T = b.T
    lot_grp = {}
    for (model, grp, code), lid in b.lot.items():
        lot_grp[lid] = (model, grp, code)
    out_of = {}   # lot -> process_run (OUTPUT)
    inputs = defaultdict(set)  # process_run -> set(lot)
    for r in T["process_run_lot"]:
        if r["lot_role"] == "OUTPUT":
            out_of[r["production_lot_id"]] = r["process_run_id"]
        else:
            inputs[r["process_run_id"]].add(r["production_lot_id"])
    mat_of = defaultdict(set)
    for r in T["material_usage"]:
        mat_of[r["process_run_id"]].add(r["material_id"])
    inspected = {r["production_lot_id"] for r in T["inspection_lot"] if r["production_lot_id"]}

    def upstream(lot, grp_wanted):
        pr = out_of.get(lot)
        if not pr:
            return None
        for l in inputs.get(pr, ()):
            if lot_grp[l][1] == grp_wanted:
                return l
        return None

    lines = ["| 단계 | 건수 |", "|---|---|"]
    ca_lots = [l for l, (m, g, c) in lot_grp.items() if g == "CA"]
    ca_with_run = [l for l in ca_lots if l in out_of]
    lines.append(f"| CA 제품 LOT(전체) | {len(ca_lots)} |")
    lines.append(f"| └ CA 작업일보가 있는 LOT | {len(ca_with_run)} |")
    lines.append(f"| └ 최종검사와 연결된 CA LOT | {len([l for l in ca_lots if l in inspected])} |")
    full = 0
    steps = Counter()
    for l in ca_with_run:
        ba = upstream(l, "BA")
        sti = upstream(ba, "STI") if ba else None
        inj = upstream(sti, "INJ") if sti else None
        resin = bool(inj and b.material_id["RESIN"] in mat_of.get(out_of.get(inj), set()))
        steps["CA←BA 연결"] += bool(ba)
        steps["BA←STI 연결"] += bool(sti)
        steps["STI←INJ 연결"] += bool(inj)
        steps["INJ←수지 자재"] += resin
        steps["STI 작업일보 있음"] += bool(sti and sti in out_of)
        steps["INJ 작업일보 있음"] += bool(inj and inj in out_of)
        if ba and sti and inj and resin:
            full += 1
    for k, v in steps.items():
        lines.append(f"| {k} | {v} / {len(ca_with_run)} |")
    lines.append(f"| **수지→사출→스티칭→권선→압입 FK가 끝까지 이어진 CA LOT** | **{full}** / {len(ca_with_run)} |")
    il = getattr(b, "stats_insp_link", {})
    lines.append(f"| 검사 실행 간 관계(inspection_run_link) | {', '.join(f'{k} {v}' for k, v in il.items())} |")
    m = getattr(b, "stats_ba_sti", Counter())
    lines.append(f"| BA←스티칭 보빈 날짜 매칭으로 추가된 INPUT 연결 | {sum(m.values())} ({', '.join(f'{k} {v}' for k, v in sorted(m.items()))}) |")
    return lines


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CSV
    if not src.exists():
        sys.exit(f"CSV 없음: {src}")
    docs, stats = load_docs(src)
    b = Builder()
    b.build(docs)
    errs = self_check(b.T)
    OUT_DIR.mkdir(exist_ok=True)
    for old in OUT_DIR.glob(SQL_OUT.stem + "*.sql"):
        old.unlink()
    n, files = write_sql(b.T, SQL_OUT)

    rep = [f"# Firestore → mqi 변환 보고서 ({DATASET})", "", f"- 원본: `{src.name}` — 변경행 {sum(stats.values())}건, 문서 {len(docs)}개 ({dict(stats)})",
           f"- 생성 SQL: {', '.join('`' + f.name + '`' for f in files)} — INSERT {n}행 (파일 순서대로 실행)",
           f"- 자체 FK 점검: {'이상 없음' if not errs else f'{len(errs)}건 문제'}", ""]
    rep += ["## 테이블별 행 수", "", "| 테이블 | 행 |", "|---|---|"] + [f"| mqi.{t} | {len(b.T[t])} |" for t in ORDER if b.T[t]]
    rep += ["", "## LOT 연결 사슬 (CA 제품 LOT 기준, 모두 CANDIDATE)", ""] + chain_report(b)
    rep += ["", "## 보류 (mqi 에 넣지 않은 문서)", "", "| 사유 | 건수 | 예시 |", "|---|---|---|"]
    rep += [f"| {k} | {v} | {', '.join(b.pending_ids[k][:3])} |" for k, v in b.pending.most_common()]
    if errs:
        rep += ["", "## FK 점검 오류", ""] + [f"- {e}" for e in errs[:50]]
    REPORT_OUT.write_text("\n".join(rep) + "\n", encoding="utf-8")
    print("\n".join(rep))


if __name__ == "__main__":
    main()
