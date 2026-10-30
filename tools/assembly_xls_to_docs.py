"""8월 조립작업일보 엑셀(IV 1호기 / OV·HSV 2호기 / 스티칭 시트, 전사본) → Firestore 통합 CSV 와 같은 모양의 문서(CSV).

원본: D:\\코디세이\\M3-1\\m3-1\\data\\imeb3 조립작업일보_8월_.xls
- 조립 시트: 한 장 = '작업일자' 행부터 96행(IV) / 106행(OV·HSV). 한 장에서 BA(권선)·CA(압입) 문서를 만든다(야간 총생산은 전부 비어 있어 주간만).
  모델은 ITEM 줄의 "( OV )", "( HSV )", "IV" 로 읽는다 → CSV 에서 OV/HSV 합산으로 보류된 날짜를 모델별로 풀 수 있다.
- 스티칭 시트: 한 장 = 35행, 주간(col 2)·야간(col 7) 각각 문서.
- 작업자 이름(근무현황·작업자명·검사자·확인자)은 넣지 않는다.
- 결과 CSV 는 tools/firestore_to_mqi.py 가 그대로 읽는다. BA·CA 문서는 source.file 이 같아야 같은 조립일보로 짝지어진다.

  py tools/assembly_xls_to_docs.py [엑셀경로] [--skip-csv [통합CSV]]
  --skip-csv: 통합 CSV 에 모델이 확정된 같은 (모델, 날짜, 공정) 생산 문서가 있으면 그 일보(BA·CA 함께)는 제외한다. 비교표는 출력한다.
"""
from __future__ import annotations

import csv
import json
import re
import sys
from datetime import date
from pathlib import Path

import xlrd

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_XLS = ROOT.parent / "M3-1" / "m3-1" / "data" / "imeb3 조립작업일보_8월_.xls"
DEFAULT_CSV = ROOT.parent / "M1-2" / "firestore_import" / "20260801-20260930_firestore_unified.csv"
OUT = ROOT / "outputs" / "assembly_xls_2026-08.csv"
VARIANTS = ("IV", "OV", "HSV")
BATCH = "XLS_ASSEMBLY_2026_08_V1"
NOTE = "원본 PDF 가 아니라 엑셀 전사본(imeb3 조립작업일보_8월_.xls). 작업자 이름은 넣지 않음"


def cell(sh, r, c) -> str:
    if r < 0 or r >= sh.nrows or c < 0 or c >= sh.row_len(r):
        return ""
    v = sh.cell_value(r, c)
    if sh.cell_type(r, c) == xlrd.XL_CELL_DATE:   # 엑셀이 '8.10' 을 날짜로 바꿔 저장한 칸 → 'M.D' 원문 표기로 되돌림
        try:
            dt = xlrd.xldate_as_datetime(v, sh.book.datemode)
            return f"{dt.month}.{dt.day}"
        except Exception:
            pass
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def num(v: str):
    t = re.sub(r"[,\s]|EA|ea|개", "", v or "")
    m = re.match(r"-?\d+(\.\d+)?", t)
    return float(m.group(0)) if m else None


def parse_date(raw: str) -> tuple[str | None, str | None]:
    """'8/6', '8.7', '8320'(오타 → 8/20) → (2026-08-06, 비고)."""
    m = re.search(r"(\d{1,2})\s*[./]\s*(\d{1,2})", raw)
    if m:
        return date(2026, int(m.group(1)), int(m.group(2))).isoformat(), None
    m = re.search(r":\s*(\d)\d?(\d{2})\s*$", raw)   # '8320' = '8/20' 의 '/' 가 '3' 으로 찍힌 오타
    if m:
        return date(2026, int(m.group(1)), int(m.group(2))).isoformat(), f"작업일자 원문 '{raw.split(':')[-1].strip()}' 오타로 보고 {m.group(1)}/{m.group(2)} 로 해석"
    return None, None


def total(txt: str) -> tuple[int | None, str | None]:
    """'주간 총생산 : 16878 미입력' → (16878, '미입력')."""
    m = re.search(r":\s*([\d,]+)", txt)
    q = int(m.group(1).replace(",", "")) if m else None
    flag = re.sub(r".*?:\s*[\d,]*\s*", "", txt).strip() or None
    return q, flag


# ----------------------------------------------------------------- 조립 시트
def find_row(sh, r0, r1, c, pat) -> int | None:
    for r in range(r0, min(r1, sh.nrows)):
        if re.search(pat, cell(sh, r, c)):
            return r
    return None


def find_cell(sh, r0, r1, pat) -> tuple[int, int] | None:
    for r in range(r0, min(r1, sh.nrows)):
        for c in range(sh.row_len(r)):
            if re.search(pat, cell(sh, r, c)):
                return r, c
    return None


def defects_between(sh, ra, rb, c0, cday, cnight) -> tuple[dict, dict]:
    day, night = {}, {}
    for r in range(ra, rb):
        label = cell(sh, r, c0)
        if not label or "작 업 시 간" in label or label.startswith("비고") or label.startswith("공정명"):
            continue
        d, n = cell(sh, r, cday), cell(sh, r, cnight)
        if d and num(d) is not None:
            day[label] = num(d)
        if n and num(n) is not None:
            night[label] = num(n)
    return day, night


def downtime(sh, r0, r1) -> list[dict]:
    hdr = find_cell(sh, r0, r1, r"^주/야$")
    if not hdr:
        return []
    hr, cx = hdr
    cols = [c for c in range(cx + 1, sh.row_len(hr)) if cell(sh, hr, c)]
    ctime = cols[0] if cols else cx + 3
    cwhat = next((c for c in cols if "문" in cell(sh, hr, c)), cx + 9)
    cact = next((c for c in cols if "조" in cell(sh, hr, c)), cx + 28)
    out = []
    for r in range(hr + 1, r1):
        s = cell(sh, r, cx)
        if s in ("주간", "야간"):
            t, w, a = cell(sh, r, ctime), cell(sh, r, cwhat), cell(sh, r, cact)
            if t or w or a:
                out.append({"shift": "DAY" if s == "주간" else "NIGHT", "time": t or None, "issue": w or None, "action": a or None})
    return out


def materials(sh, r0, r1) -> dict:
    hit = find_cell(sh, r0, r1, r"^BOBBIN")
    out = {}
    if not hit:
        return out
    rb, mc = hit
    bl = cell(sh, rb, mc + 9)   # '7.3/7.22' = 보빈 생산일 / 리드핀 입고일. '2/20/7/22' 처럼 '.' 대신 '/' 를 쓴 경우도 있다
    toks = re.findall(r"\d{1,2}[./]\d{1,2}", bl)
    if len(toks) >= 2:
        parts = toks[:2]
    else:
        parts = [p.strip() for p in bl.split("/")] if bl else []
    out["bobbin_lot_raw"] = parts[0] if parts and parts[0] else None
    out["lead_pin_lot_raw"] = parts[1] if len(parts) > 1 and parts[1] else None
    out["bobbin_lead_pin_cell_raw"] = bl or None
    out["bobbin_lead_pin_night_raw"] = cell(sh, rb, mc + 17).strip("/ ") or None
    ri = find_cell(sh, rb, rb + 6, r"Insert")
    if ri:
        v = cell(sh, ri[0], mc + 9).strip("/ ")
        out["insert_lot_raw"] = v or None
    rw = find_cell(sh, rb, r1, r"^WIRE$")
    wires_day, wires_night = [], []
    if rw:
        for r in range(rw[0], r1):
            tag = cell(sh, r, mc + 7)
            if tag not in ("시업", "변경"):
                continue
            for cc, bucket in ((mc + 9, wires_day), (mc + 13, wires_day), (mc + 17, wires_night), (mc + 21, wires_night)):
                v = cell(sh, r, cc).replace("\n", " ")
                m = re.match(r"(\d-\d{1,2})\s*(\S+)?", v)
                if m and m.group(2):
                    bucket.append(f"{m.group(1)}({tag}) {m.group(2)}")
            if cell(sh, r, mc).startswith("UPPER"):
                break
    out["wire_lot_table_raw"] = "; ".join(wires_day) or None
    out["wire_lot_table_night_raw"] = "; ".join(wires_night) or None
    ru = find_cell(sh, rb, r1, r"^UPPER")
    if ru:
        out["upper_case_lot_raw"] = cell(sh, ru[0], mc + 9) or None
        out["upper_case_lot_night_raw"] = cell(sh, ru[0], mc + 17) or None
    rl = find_cell(sh, rb, r1, r"^LOWER")
    if rl:
        out["lower_case_lot_raw"] = cell(sh, rl[0], mc + 9) or None
        out["lower_case_spec_raw"] = cell(sh, rl[0], mc + 4) or None
    return out


def checks(sh, r0, r1, c0) -> list[dict]:
    """저항/Tension 점검: '권선기 축' 헤더 행의 열 → 축 이름, 아래 '저항'/'Tension' 행."""
    hr = find_row(sh, r0, r1, c0, r"권선기")
    if hr is None:
        return []
    spindle = {c: cell(sh, hr, c) for c in range(c0 + 1, sh.row_len(hr)) if re.fullmatch(r"\d-\d{1,2}", cell(sh, hr, c))}
    out, cur = [], None
    for r in range(hr + 1, r1):
        lab = cell(sh, r, c0 + 2)
        t = cell(sh, r, c0)
        if lab == "저항":
            cur = {"time_raw": t or None, "resistance": {}, "tension": {}}
            out.append(cur)
            cur["resistance"] = {s: num(cell(sh, r, c)) for c, s in spindle.items() if cell(sh, r, c)}
        elif lab == "Tension" and cur is not None:
            cur["tension"] = {s: num(cell(sh, r, c)) for c, s in spindle.items() if cell(sh, r, c)}
    return [x for x in out if x["resistance"] or x["tension"]]


def parse_assembly_block(sh, r0, r1, c0, sheet) -> list[dict]:
    work_date, date_note = parse_date(cell(sh, r0, c0))
    item = cell(sh, r0 + 1, c0)
    m = re.search(r"\(\s*(IV|OV|HSV)\s*\)|\b(IV|OV|HSV)\s*$", item)
    model = (m.group(1) or m.group(2)) if m else ""
    cday, cnight = c0 + 9, c0 + 15
    rw = find_row(sh, r0, r1, c0, r"공정명\s*:\s*WINDING")
    rp = find_row(sh, r0, r1, c0, r"공정명\s*:\s*압입")
    if rw is None or rp is None:
        return []
    docs = []
    mats = materials(sh, r0, r1)
    dt = downtime(sh, r0, r1)
    chk = checks(sh, r0, r1, c0)
    for grp, proc, rs, rend in (("BA", "BA", rw, rp), ("CA", "CA", rp, rp + 14)):
        q_day, f_day = total(cell(sh, rs, cday))
        q_night, f_night = total(cell(sh, rs + 1, cday))
        rh = find_row(sh, rs, rend + 3, c0, r"작\s*업\s*시\s*간")
        hours_d = num(cell(sh, rh, cday)) if rh is not None else None
        hours_n = num(cell(sh, rh, cnight)) if rh is not None else None
        rn = find_row(sh, rs, rend + 4, c0, r"^비고")
        note = " ".join(x for x in (cell(sh, rn, c) for c in range(c0 + 1, c0 + 20)) if x) if rn is not None else ""
        dd, dn = defects_between(sh, rs + 3, rh if rh is not None else rend, c0, cday, cnight)
        for night, q, flag, hours, dfs in ((False, q_day, f_day, hours_d, dd), (True, q_night, f_night, hours_n, dn)):
            if q is None and hours is None and not dfs:
                continue
            tag = "NIGHT" if night else "DAY"
            details = {"shift": tag, "production_hours": hours, "defects": dfs, "value_status_note": flag,
                       "note_raw": note or None, "date_note": date_note, "downtime_raw": [x for x in dt if x["shift"] == tag] or None,
                       "line": sheet.strip(), "transcription_note": NOTE}
            if grp == "BA":
                details.update({k: mats.get(k) for k in ("bobbin_lot_raw", "lead_pin_lot_raw", "insert_lot_raw")})
                details["wire_lot_table_raw"] = mats.get("wire_lot_table_night_raw" if night else "wire_lot_table_raw")
                details["resistance_tension_checks_raw"] = chk or None
            else:
                details["upper_case_lot_raw"] = mats.get("upper_case_lot_night_raw" if night else "upper_case_lot_raw")
                details["lower_case_lot_raw"] = mats.get("lower_case_lot_raw")
                details["lower_case_spec_raw"] = mats.get("lower_case_spec_raw")
            did = f"XLS-{(work_date or 'nodate').replace('-', '')}-ASM-{model or 'NA'}-{grp}-{tag}"
            docs.append({"id": did, "date": work_date, "product": "iMEB3", "variant": model, "process": proc,
                         "metric": "production_qty", "value": q, "unit": "EA", "value_source": "EXCEL_TRANSCRIBED",
                         "review_status": "NEEDS_REVIEW" if flag else "UNVERIFIED",
                         "source": {"file": DEFAULT_XLS.name, "sheet": sheet, "row": r0 + 1, "document_type": "조립 작업일보(엑셀 전사본)", "page": None},
                         "ingest_batch": BATCH, "details": details})
    return docs


# ----------------------------------------------------------------- 스티칭 시트
def parse_stitching_block(sh, r0, r1) -> list[dict]:
    hdr = next((cell(sh, r0, c) for c in range(sh.row_len(r0)) if "작업" in cell(sh, r0, c) and "일자" in cell(sh, r0, c)), "")
    work_date, date_note = parse_date(hdr)
    rows = {cell(sh, r, 0): r for r in range(r0, min(r1, sh.nrows)) if cell(sh, r, 0)}
    rtype = next((r for k, r in rows.items() if k.startswith("Type")), None)
    rqty = next((r for k, r in rows.items() if "생산량" in k), None)
    rhrs = next((r for k, r in rows.items() if k.startswith("작업시간")), None)
    rdef = next((r for k, r in rows.items() if k.startswith("불량수량")), None)
    docs = []
    for night, c in ((False, 2), (True, 7)):
        q = num(cell(sh, rqty, c)) if rqty is not None else None
        hours = num(cell(sh, rhrs, c)) if rhrs is not None else None
        if q is None and hours is None:
            continue
        model = cell(sh, rtype, c) if rtype is not None else ""
        if model not in VARIANTS:
            model = next((v for v in VARIANTS if v in model), model)
        dfs = {}
        if rdef is not None:
            for r in range(rdef, rdef + 3):
                lab = cell(sh, r, 1)
                v = cell(sh, r, c)
                if lab and v and num(v) is not None:
                    dfs[lab] = num(v)
        lp = [cell(sh, r, c) for k, r in rows.items() if k.startswith("Lead Pin 입고일자")]
        bb = [cell(sh, r, c) for k, r in rows.items() if k.startswith("Bobbin 생산일자")]
        rsp = next((r for k, r in rows.items() if "특이사항" in k), None)
        rdt = next((r for k, r in rows.items() if k.startswith("비가동시간")), None)
        notes, dts = [], []
        if rsp is not None:
            for r in range(rsp + 1, (rdt or r1)):
                t = " ".join(cell(sh, r, cc) for cc in range(0, 8) if cell(sh, r, cc))
                if t:
                    notes.append(t)
        if rdt is not None:
            for r in range(rdt + 1, min(r1, rdt + 6)):
                t, w, a = cell(sh, r, 0), " ".join(cell(sh, r, cc) for cc in (2, 3, 4, 5) if cell(sh, r, cc)), cell(sh, r, 6)
                if (t or w or a) and not re.fullmatch(r"\d+(\.\d+)?", t or ""):
                    dts.append({"time": t or None, "issue": w or None, "action": a or None})
        tag = "NIGHT" if night else "DAY"
        did = f"XLS-{(work_date or 'nodate').replace('-', '')}-STI-{model or 'NA'}-{tag}"
        docs.append({"id": did, "date": work_date, "product": "iMEB3", "variant": model, "process": "STITCHING",
                     "metric": "production_qty", "value": int(q) if q is not None else None, "unit": "EA",
                     "value_source": "EXCEL_TRANSCRIBED", "review_status": "UNVERIFIED",
                     "source": {"file": DEFAULT_XLS.name, "sheet": sh.name, "row": r0 + 1, "document_type": "스티칭 작업일보(엑셀 전사본)", "page": None},
                     "ingest_batch": BATCH,
                     "details": {"shift": tag, "production_hours": hours, "defects": dfs, "date_note": date_note,
                                 "bobbin_lot_raw": " / ".join(x for x in bb if x) or None,
                                 "lead_pin_lot_raw": " / ".join(x for x in lp if x) or None,
                                 "note_raw": " | ".join(notes) or None, "downtime_raw": dts or None, "transcription_note": NOTE}})
    return docs


def parse_xls(path: Path) -> list[dict]:
    wb = xlrd.open_workbook(str(path))
    docs = []
    for sh in wb.sheets():
        if "Stitching" in sh.name or "스티칭" in sh.name:
            starts = [r for r in range(sh.nrows) if any("작업" in cell(sh, r, c) and "일자" in cell(sh, r, c) for c in range(sh.row_len(r)))]
            for i, r0 in enumerate(starts):
                docs.extend(parse_stitching_block(sh, r0, starts[i + 1] - 1 if i + 1 < len(starts) else sh.nrows))
            continue
        starts = [(r, c) for r in range(sh.nrows) for c in (0, 1) if cell(sh, r, c).startswith("작업일자")]
        for i, (r0, c0) in enumerate(starts):
            r1 = starts[i + 1][0] - 1 if i + 1 < len(starts) else sh.nrows
            docs.extend(parse_assembly_block(sh, r0, r1, c0, sh.name))
    return docs


def existing(csv_path: Path) -> dict[tuple, dict]:
    """통합 CSV 의 (모델, 날짜, 공정그룹) → 문서(모델 확정 생산 문서만)."""
    PO = {"STITCHING": "STI", "BA": "BA", "ASSEMBLY_BA": "BA", "BA_WINDING": "BA", "CA": "CA", "ASSEMBLY_CA": "CA", "CA_PRESS_FIT": "CA"}
    out = {}
    if not csv_path.exists():
        return out
    csv.field_size_limit(10 ** 8)
    merged: dict[str, dict] = {}
    with open(csv_path, encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            d = json.loads(row["payload_json"] or "{}")
            if row["action"] == "ADD":
                merged.setdefault(row["document_id"], {}).update(d)
            elif row["document_id"] in merged:
                merged[row["document_id"]].update(d)
    for k, d in merged.items():
        g = PO.get(d.get("process"))
        if g and d.get("variant") in VARIANTS and d.get("date"):
            det = d.get("details") or {}
            val = det.get(f"{g}_quantity_ea") if g in ("BA", "CA") and det.get(f"{g}_quantity_ea") is not None else d.get("value")
            out.setdefault((d["variant"], d["date"], g), {"id": k, "value": val})
    return out


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    xls = Path(args[0]) if args else DEFAULT_XLS
    skip = None
    if "--skip-csv" in sys.argv:
        i = sys.argv.index("--skip-csv")
        skip = Path(sys.argv[i + 1]) if i + 1 < len(sys.argv) and not sys.argv[i + 1].startswith("--") else DEFAULT_CSV
    docs = parse_xls(xls)
    have = existing(skip) if skip else {}
    # ITEM 칸이 "(  )" 로 비어 모델이 없는 조립 일보: 같은 날 통합 CSV 의 BA 생산량과 같으면 그 모델로 본다
    for d in docs:
        if d["variant"] or d["process"] == "STITCHING" or not d["date"]:
            continue
        ba = next((x for x in docs if x["process"] == "BA" and x["date"] == d["date"] and x["source"]["row"] == d["source"]["row"]), d)
        cand = [m for m in VARIANTS if (m, d["date"], "BA") in have and have[(m, d["date"], "BA")]["value"] == ba["value"]]
        if len(cand) == 1:
            d["variant"] = cand[0]
            d["id"] = d["id"].replace("-NA-", f"-{cand[0]}-")
            d["details"]["date_note"] = (d["details"].get("date_note") or "") + f" 모델 칸 비어 있음 → 같은 날 CSV BA 생산량 일치로 {cand[0]} 추정"
    # 조립 일보는 BA·CA 를 함께 판단: 같은 (모델, 날짜) 에 CSV 생산 문서가 있으면 둘 다 제외
    def journal_key(d):
        g = {"BA": "ASM", "CA": "ASM", "STITCHING": "STI"}[d["process"]]
        return (d["variant"], d["date"], g)
    skipped_keys = set()
    for d in docs:
        g = "STI" if d["process"] == "STITCHING" else None
        if g:
            if (d["variant"], d["date"], "STI") in have:
                skipped_keys.add(journal_key(d))
        else:
            if (d["variant"], d["date"], "BA") in have or (d["variant"], d["date"], "CA") in have:
                skipped_keys.add(journal_key(d))
    kept = [d for d in docs if journal_key(d) not in skipped_keys]
    dropped = [d for d in docs if journal_key(d) in skipped_keys]
    OUT.parent.mkdir(exist_ok=True)
    with open(OUT, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["record_date", "source_file", "source_type", "action", "collection", "document_id", "payload_json", "expected_document_json", "note"])
        w.writeheader()
        for d in kept:
            w.writerow({"record_date": d["date"], "source_file": xls.name, "source_type": "엑셀 전사본", "action": "ADD", "collection": "data",
                        "document_id": d["id"], "payload_json": json.dumps(d, ensure_ascii=False), "expected_document_json": "", "note": ""})
    print(f"엑셀 {xls.name}: 문서 {len(docs)}건 → 저장 {len(kept)}건, CSV 와 겹쳐 제외 {len(dropped)}건 → {OUT}")
    print("\n## 저장한 문서")
    print("| 모델 | 날짜 | 공정 | 교대 | 생산량 | 시간 | 불량 | 자재 원문 | 메모 |\n|---|---|---|---|---:|---:|---|---|---|")
    for d in kept:
        dt = d["details"]
        mats = ", ".join(f"{k.replace('_lot_raw', '').replace('_table', '')}={v}" for k, v in dt.items() if k.endswith("_raw") and k not in ("note_raw", "downtime_raw", "date_note") and v and not isinstance(v, (list, dict)))
        print(f"| {d['variant']} | {d['date']} | {d['process']} | {dt['shift']} | {d['value'] if d['value'] is not None else '—'} | {dt.get('production_hours') or '—'} | "
              f"{', '.join(f'{k} {v:g}' for k, v in dt['defects'].items()) or '—'} | {mats[:60]} | {(dt.get('value_status_note') or dt.get('date_note') or '')[:30]} |")
    print("\n## CSV 와 겹쳐 제외한 문서 (CSV 값 vs 엑셀 값)")
    print("| 모델 | 날짜 | 공정 | CSV 문서 | CSV 값 | 엑셀 값 | 차이 |\n|---|---|---|---|---:|---:|---:|")
    for d in dropped:
        g = "STI" if d["process"] == "STITCHING" else d["process"]
        ref = have.get((d["variant"], d["date"], g))
        if not ref or d["details"]["shift"] != "DAY":
            continue
        cv, xv = ref["value"], d["value"]
        diff = (xv - cv) if isinstance(cv, (int, float)) and isinstance(xv, (int, float)) else ""
        mark = " **확인**" if isinstance(diff, (int, float)) and abs(diff) >= 100 else ""
        print(f"| {d['variant']} | {d['date']} | {d['process']} | {ref['id']} | {cv} | {xv} | {diff}{mark} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
