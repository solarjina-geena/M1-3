"""8월 사출작업일보 엑셀(DS120-1 양식 전사본) → Firestore 통합 CSV 와 같은 모양의 문서(CSV) 로 변환.

원본: D:\\코디세이\\M3-1\\m3-1\\data\\imeb3사출작업일보_8월_.xls (박*경 폴더에도 같은 파일)
- 시트마다 일보가 세로로 이어 붙어 있다. 한 장 = '작업일자 :' 행부터 35행.
- 한 장에서 주간·야간 문서를 각각 만든다(9월 Firestore 양식 SRC-…-DAY/-NIGHT 와 같은 식).
- 결과 CSV 는 tools/firestore_to_mqi.py 가 그대로 읽는다(열: record_date, source_file, source_type, action, collection, document_id, payload_json, note).
- 작업자 이름(근무현황)은 문서에 넣지 않는다. 결재란 이름도 넣지 않는다.

  py tools/injection_xls_to_docs.py [엑셀경로] [--skip-csv 통합CSV]   # --skip-csv 를 주면 이미 있는 (모델,날짜,교대) 는 제외
"""
from __future__ import annotations

import csv
import io
import json
import re
import sys
from datetime import date
from pathlib import Path

import xlrd

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_XLS = ROOT.parent / "M3-1" / "m3-1" / "data" / "imeb3사출작업일보_8월_.xls"
DEFAULT_CSV = ROOT.parent / "M1-2" / "firestore_import" / "20260801-20260930_firestore_unified.csv"
OUT = ROOT / "outputs" / "injection_xls_2026-08.csv"
BLOCK = 35
VARIANTS = ("IV", "OV", "HSV")

# 한 장 안의 상대 위치 (r0 = '작업일자' 행). 2026-10-30 IV/OV/HSV 시트 대조로 확정.
R_ITEM, C_MODEL, C_CAVITY = 1, 4, 8
R_DAY, R_NIGHT = 3, 6                       # col1 생산수량, col2 불량수량, col3 생산시간, col4 비가동시간, col5 비가동내역
R_NOTE = 9                                  # '비 고' 행: col1~ 자유 텍스트
DEFECT_ROWS = {5: "미성형", 7: "이물", 9: "핀홀막힘"}   # col18 주간 유형, col21 수량 / col23 야간 유형, col26 수량
R_INITIAL, R_PURGE = 12, 14                 # 초기불량수량, 퍼징중량 (같은 열 규칙)
R_RESIN_DAY, R_RESIN_NIGHT, R_RESIN_NAME = 19, 23, 29   # col20 규격코드, col24 Lot No, col26 사용량 / col18 원부자재명
R_COND0, R_COND1 = 5, 31                    # 사출조건: col10 항목, col11 규격, col12 확인방법, col13/14 주간 시작/종료, col15/16 야간 시작/종료
R_CHECK = 14                                # 초기제품 3Shot 확인 행(+2): 주간 col2~4, 야간 col6~8


def s(sh, r, c) -> str:
    if r >= sh.nrows or c >= sh.ncols:
        return ""
    v = sh.cell_value(r, c)
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def num(v: str):
    t = re.sub(r"[,\s]|EA|ea|개", "", v or "")
    return float(t) if re.fullmatch(r"-?\d+(\.\d+)?", t) else None


def parse_date(raw: str, hint: str | None) -> str | None:
    """'26.8.7' / '26.08.21' / 시트명 '26.08.10' → 2026-08-07."""
    for txt in (raw, hint or ""):
        m = re.search(r"(\d{2})\.(\d{1,2})\.(\d{1,2})", txt)
        if m:
            y, mo, d = (int(x) for x in m.groups())
            return date(2000 + y, mo, d).isoformat()
    return None


def defects(sh, r0, night: bool) -> tuple[dict, str | None, str | None]:
    ct, cq = (23, 26) if night else (18, 21)
    out = {}
    for off, default in DEFECT_ROWS.items():
        name = s(sh, r0 + off, ct) or default
        q = s(sh, r0 + off, cq)
        if q:
            out[name.replace(" ", "")] = num(q) if num(q) is not None else q
    initial = s(sh, r0 + R_INITIAL, cq) or None
    purge = s(sh, r0 + R_PURGE, cq) or None
    if purge and not re.search(r"\d", purge):
        purge = None  # 단위 'g' 만 인쇄된 빈칸
    if initial and not re.search(r"\d", initial):
        initial = None
    return out, initial, purge


def conditions(sh, r0, night: bool) -> dict:
    c_start, c_end = (15, 16) if night else (13, 14)
    out = {}
    for r in range(r0 + R_COND0, r0 + R_COND1 + 1):
        item = s(sh, r, 10)
        if not item or item in ("관리 항목",):
            continue
        st, en = s(sh, r, c_start), s(sh, r, c_end)
        if st or en:
            out[item.replace("\n", " ")] = {"spec": s(sh, r, 11), "method": s(sh, r, 12), "start": st, "end": en}
    return out


def resin(sh, r0, night: bool) -> dict:
    r = r0 + (R_RESIN_NIGHT if night else R_RESIN_DAY)
    return {"code": s(sh, r, 20), "lot": s(sh, r, 24), "usage": s(sh, r, 26), "name": s(sh, r0 + R_RESIN_NAME, 18)}


def parse_block(sh, r0: int, sheet: str) -> list[dict]:
    work_date = parse_date(s(sh, r0, 0), sheet)
    model = s(sh, r0 + R_ITEM, C_MODEL) or next((v for v in VARIANTS if v in sheet.replace("_", " ")), "")
    cavity = num(s(sh, r0 + R_ITEM, C_CAVITY))
    note = " ".join(x for x in (s(sh, r0 + R_NOTE, c) for c in range(1, 10)) if x) or None
    docs = []
    for night, rr, tag in ((False, R_DAY, "DAY"), (True, R_NIGHT, "NIGHT")):
        qty = num(s(sh, r0 + rr, 1))
        hours_raw = s(sh, r0 + rr, 3)
        hours = num(hours_raw)
        if hours is not None and hours > 24:   # 전사 오류(예 62.0) → 시간은 비우고 원문만 남긴다
            hours = None
        if qty is None and hours is None and not s(sh, r0 + rr, 5):
            continue  # 그 교대 기록 없음
        dfs, initial, purge = defects(sh, r0, night)
        rs = resin(sh, r0, night)
        chk = [s(sh, r0 + R_CHECK + 2, c) for c in ((6, 7, 8) if night else (2, 3, 4))]
        did = f"XLS-{(work_date or 'nodate').replace('-', '')}-INJ-{model or 'NA'}-{tag}"
        d = {
            "id": did, "date": work_date, "product": "iMEB3", "variant": model, "process": "INJECTION",
            "metric": "production_qty", "value": int(qty) if qty is not None else None, "unit": "EA",
            "value_source": "EXCEL_TRANSCRIBED", "review_status": "UNVERIFIED",
            "source": {"file": DEFAULT_XLS.name, "sheet": sheet, "row": r0 + 1, "document_type": "사출 작업일보(엑셀 전사본)", "page": None},
            "ingest_batch": "XLS_INJECTION_2026_08_V1",
            "production_lot_id": f"{(work_date or '')[2:].replace('-', '')}{'N' if night else 'D'}1" if work_date else None,
            "details": {
                "machine": "DS120-1", "equipment": "DS120-1", "cavity": cavity, "shift": tag,
                "production_hours": hours, "production_hours_raw": hours_raw or None, "defect_qty": num(s(sh, r0 + rr, 2)),
                "downtime_hours": num(s(sh, r0 + rr, 4)), "downtime_raw": s(sh, r0 + rr, 5) or None,
                "defects": dfs, "initial_defects_raw": initial, "purge_weight_raw": purge,
                "resin_name_raw": rs["name"] or None, "resin_code_raw": rs["code"] or None,
                "resin_lot_raw": rs["lot"] or None, "resin_usage_raw": rs["usage"] or None,
                "injection_conditions_raw": conditions(sh, r0, night),
                "initial_shot_check_raw": [c for c in chk if c] or None,
                "note_raw": note,
                "transcription_note": "원본 PDF 가 아니라 엑셀 전사본(imeb3사출작업일보_8월_.xls). 작업자 이름은 넣지 않음",
            },
        }
        docs.append(d)
    return docs


def parse_xls(path: Path) -> list[dict]:
    wb = xlrd.open_workbook(str(path))
    docs = []
    for sh in wb.sheets():
        r = 0
        while r < sh.nrows:
            if s(sh, r, 0).startswith("작업일자"):
                docs.extend(parse_block(sh, r, sh.name))
                r += BLOCK
            else:
                r += 1
    return docs


def existing_keys(csv_path: Path) -> set[tuple]:
    keys = set()
    if not csv_path.exists():
        return keys
    csv.field_size_limit(10 ** 8)
    with open(csv_path, encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row["action"] != "ADD":
                continue
            d = json.loads(row["payload_json"] or "{}")
            if d.get("process") != "INJECTION":
                continue
            sh = str((d.get("details") or {}).get("shift") or "").upper()
            sh = "NIGHT" if sh in ("N", "NIGHT") else "DAY"
            keys.add((d.get("variant"), d.get("date"), sh))
    return keys


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    xls = Path(args[0]) if args else DEFAULT_XLS
    skip = None
    if "--skip-csv" in sys.argv:
        i = sys.argv.index("--skip-csv")
        skip = Path(sys.argv[i + 1]) if i + 1 < len(sys.argv) and not sys.argv[i + 1].startswith("--") else DEFAULT_CSV
    docs = parse_xls(xls)
    have = existing_keys(skip) if skip else set()
    kept, dropped = [], []
    for d in docs:
        k = (d["variant"], d["date"], d["details"]["shift"])
        (dropped if k in have else kept).append(d)
    OUT.parent.mkdir(exist_ok=True)
    with open(OUT, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["record_date", "source_file", "source_type", "action", "collection", "document_id", "payload_json", "expected_document_json", "note"])
        w.writeheader()
        for d in kept:
            w.writerow({"record_date": d["date"], "source_file": xls.name, "source_type": "엑셀 전사본", "action": "ADD", "collection": "data",
                        "document_id": d["id"], "payload_json": json.dumps(d, ensure_ascii=False), "expected_document_json": "", "note": ""})
    print(f"엑셀 {xls.name}: 일보 문서 {len(docs)}건(주/야 분리) → 저장 {len(kept)}건, 통합 CSV 와 겹쳐 제외 {len(dropped)}건 → {OUT}")
    print("| 모델 | 날짜 | 교대 | 생산량 | 시간 | 불량 | 수지 LOT | 비고 |")
    print("|---|---|---|---:|---:|---|---|---|")
    for d in docs:
        dt = d["details"]
        flag = "" if d in kept else " (제외: CSV 에 있음)"
        print(f"| {d['variant']} | {d['date']} | {dt['shift']} | {d['value'] if d['value'] is not None else '—'} | {dt['production_hours'] or '—'} | "
              f"{', '.join(f'{k} {v}' for k, v in dt['defects'].items()) or '—'} | {dt['resin_lot_raw'] or '—'} | {(dt['downtime_raw'] or dt['note_raw'] or '')[:30]}{flag} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
