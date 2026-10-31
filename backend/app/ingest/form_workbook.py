"""회사 작업일보 양식 엑셀(전사본·판독본) → JournalPayload 목록.

템플릿(머리글 한 줄) 이 아니라 **작업일보 양식 그대로인 xlsx** 를 읽는다. tools/assembly_xls_to_docs.py,
tools/injection_xls_to_docs.py(8월 전사본 적재에 쓴 파서) 를 서버용으로 옮긴 것이다. Render 에는 backend/ 만 올라가므로
tools/ 를 import 하지 않고 여기서 직접 파싱한다. xls(xlrd) 는 받지 않고 xlsx 만 받는다.

- 조립 시트(iMEB3 1차 IV / OV HSV 2차 …): 한 장 = '작업일자' 셀부터 다음 '작업일자' 전까지. 권선(BA)·압입(CA) 를 주/야 각각 작업일보로.
- 스티칭 시트(Stitching …): 한 장 = '작업 일자' 머리 행부터. 주간(col 2)·야간(col 7).
- 사출 시트(DS120 양식, '작업일자 :' 가 A열): 한 장 35행. 주/야 각각.
- 작업자 이름은 어디에도 넣지 않는다.
"""
from __future__ import annotations

import datetime as _dt
import io
import re
from datetime import date

import openpyxl

from .journal_payload import JournalPayload

VARIANTS = ("IV", "OV", "HSV")


class _Sheet:
    def __init__(self, ws):
        self.name = ws.title
        self._rows = [list(r) for r in ws.iter_rows(values_only=True)]
        self.nrows = len(self._rows)

    def row_len(self, r):
        return len(self._rows[r]) if 0 <= r < self.nrows else 0

    def raw(self, r, c):
        return self._rows[r][c] if 0 <= r < self.nrows and 0 <= c < len(self._rows[r]) else None


def cell(sh: _Sheet, r, c) -> str:
    v = sh.raw(r, c)
    if v is None:
        return ""
    if isinstance(v, (_dt.datetime, _dt.date)):
        return f"{v.month}.{v.day}"          # 엑셀이 '8.10' 을 날짜로 바꿔 저장한 칸 → 원문 표기로
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def num(v: str):
    t = re.sub(r"[,\s]|EA|ea|개", "", v or "")
    m = re.match(r"-?\d+(\.\d+)?", t)
    return float(m.group(0)) if m else None


def _date_hint(sh: _Sheet, r0: int, r1: int) -> _dt.date | None:
    """블록 안의 첫 날짜형 셀(판독본은 '작업일자' 옆에 2026-10-01 같은 날짜 셀이 있다)."""
    for r in range(r0, min(r1, sh.nrows)):
        for c in range(sh.row_len(r)):
            v = sh.raw(r, c)
            if isinstance(v, (_dt.datetime, _dt.date)):
                return v.date() if isinstance(v, _dt.datetime) else v
    return None


def _year_hint(sh: _Sheet, r0: int, r1: int) -> int | None:
    d = _date_hint(sh, r0, r1)
    return d.year if d else None


def _fallback_date(sh: _Sheet, r0: int, r1: int, work_date: str | None) -> str | None:
    """'작업일자 :' 글자만 있고 날짜가 날짜형 셀에 따로 있으면 그 셀을 쓴다."""
    if work_date:
        return work_date
    d = _date_hint(sh, r0, r1)
    return d.isoformat() if d else None


def parse_md(raw: str, year: int) -> tuple[str | None, str | None]:
    """'8/6', '8.7', '26.9.4', '8320'(오타 → 8/20) → (YYYY-MM-DD, 비고)."""
    m = re.search(r"(\d{2})\.(\d{1,2})\.(\d{1,2})", raw)
    if m:
        return date(2000 + int(m.group(1)), int(m.group(2)), int(m.group(3))).isoformat(), None
    m = re.search(r"(\d{1,2})\s*[./]\s*(\d{1,2})", raw)
    if m:
        try:
            return date(year, int(m.group(1)), int(m.group(2))).isoformat(), None
        except ValueError:
            return None, f"작업일자 원문 '{raw}' 을 날짜로 읽지 못함"
    m = re.search(r":\s*(\d)\d?(\d{2})\s*$", raw)
    if m:
        return date(year, int(m.group(1)), int(m.group(2))).isoformat(), f"작업일자 원문 '{raw.split(':')[-1].strip()}' 오타로 보고 {m.group(1)}/{m.group(2)} 로 해석"
    return None, None


def total(txt: str) -> tuple[int | None, str | None]:
    """'주간 총생산 : 16878 미입력' → (16878, '미입력'). 숫자가 같은 칸에 없으면 None."""
    m = re.search(r":\s*([\d,]+)", txt)
    q = int(m.group(1).replace(",", "")) if m else None
    flag = re.sub(r".*?:\s*[\d,]*\s*", "", txt).strip() or None
    return q, flag


def find_row(sh, r0, r1, c, pat):
    for r in range(r0, min(r1, sh.nrows)):
        if re.search(pat, cell(sh, r, c)):
            return r
    return None


def find_cell(sh, r0, r1, pat):
    for r in range(r0, min(r1, sh.nrows)):
        for c in range(sh.row_len(r)):
            if re.search(pat, cell(sh, r, c)):
                return r, c
    return None


def _first_num_right(sh, r, c, span=12):
    """'주간 총생산 :' 글자와 숫자가 다른 칸에 있을 때 오른쪽 칸에서 숫자를 찾는다."""
    for cc in range(c, c + span):
        t = cell(sh, r, cc)
        if re.fullmatch(r"[\d,]+", t):
            return int(t.replace(",", ""))
    return None


# ----------------------------------------------------------------- 조립 시트(권선 BA / 압입 CA)
def defects_between(sh, ra, rb, c0, cday, cnight):
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


def materials(sh, r0, r1):
    hit = find_cell(sh, r0, r1, r"^BOBBIN")
    out = {}
    if not hit:
        return out
    rb, mc = hit
    bl = cell(sh, rb, mc + 9)
    toks = re.findall(r"\d{1,2}[./]\d{1,2}", bl)
    parts = toks[:2] if len(toks) >= 2 else ([p.strip() for p in bl.split("/")] if bl else [])
    out["bobbin_lot_raw"] = parts[0] if parts and parts[0] else None
    out["lead_pin_lot_raw"] = parts[1] if len(parts) > 1 and parts[1] else None
    nb = cell(sh, rb, mc + 17).strip("/ ")
    toks_n = re.findall(r"\d{1,2}[./]\d{1,2}", nb)
    out["bobbin_lot_night_raw"] = toks_n[0] if toks_n else None
    out["lead_pin_lot_night_raw"] = toks_n[1] if len(toks_n) > 1 else None
    ri = find_cell(sh, rb, rb + 6, r"Insert")
    if ri:
        out["insert_lot_raw"] = cell(sh, ri[0], mc + 9).strip("/ ") or None
        out["insert_lot_night_raw"] = cell(sh, ri[0], mc + 17).strip("/ ") or None
    rw = find_cell(sh, rb, r1, r"^WIRE$")
    wires_day, wires_night = [], []
    if rw:
        for r in range(rw[0], r1):
            tag = cell(sh, r, mc + 7)
            if tag not in ("시업", "변경"):
                if cell(sh, r, mc).startswith("UPPER"):
                    break
                continue
            for cc, bucket in ((mc + 9, wires_day), (mc + 13, wires_day), (mc + 17, wires_night), (mc + 21, wires_night)):
                v = cell(sh, r, cc).replace("\n", " ")
                m = re.match(r"(\d-\d{1,2})\s*(\S+)?", v)
                if m and m.group(2):
                    bucket.append((f"{m.group(1)}({tag})", m.group(2)))
    out["wires_day"], out["wires_night"] = wires_day, wires_night
    ru = find_cell(sh, rb, r1, r"^UPPER")
    if ru:
        out["upper_case_lot_raw"] = cell(sh, ru[0], mc + 9) or None
        out["upper_case_lot_night_raw"] = cell(sh, ru[0], mc + 17) or None
    rl = find_cell(sh, rb, r1, r"^LOWER")
    if rl:
        out["lower_case_lot_raw"] = cell(sh, rl[0], mc + 9) or None
        out["lower_case_lot_night_raw"] = cell(sh, rl[0], mc + 17) or None
    return out


def parse_assembly_block(sh, r0, r1, c0, filename: str) -> list[dict]:
    year = _year_hint(sh, max(0, r0 - 3), r1) or date.today().year
    work_date, date_note = parse_md(cell(sh, r0, c0), year)
    work_date = _fallback_date(sh, max(0, r0 - 3), min(r1, r0 + 6), work_date)
    item = cell(sh, r0 + 1, c0)
    m = re.search(r"\(\s*(IV|OV|HSV)\s*\)|\b(IV|OV|HSV)\s*$", item)
    model = (m.group(1) or m.group(2)) if m else ""
    if not model:
        model = next((v for v in VARIANTS if re.search(rf"\b{v}\b", sh.name)), "")
    cday, cnight = c0 + 9, c0 + 15
    rw = find_row(sh, r0, r1, c0, r"공정명\s*:\s*WINDING")
    rp = find_row(sh, r0, r1, c0, r"공정명\s*:\s*압입")
    if rw is None or rp is None:
        return []
    mats = materials(sh, r0, r1)
    out = []
    for grp, proc, rs, rend in (("BA", "IMEB3_WINDING", rw, rp), ("CA", "IMEB3_CA_PRESS", rp, rp + 14)):
        q_day, f_day = total(cell(sh, rs, cday))
        q_night, f_night = total(cell(sh, rs + 1, cday))
        if q_day is None:
            q_day = _first_num_right(sh, rs, cday + 1)
        if q_night is None:
            q_night = _first_num_right(sh, rs + 1, cday + 1)
        rh = find_row(sh, rs, rend + 3, c0, r"작\s*업\s*시\s*간")
        hours_d = num(cell(sh, rh, cday)) if rh is not None else None
        hours_n = num(cell(sh, rh, cnight)) if rh is not None else None
        rn = find_row(sh, rs, rend + 4, c0, r"^비고")
        note = " ".join(x for x in (cell(sh, rn, c) for c in range(c0 + 1, c0 + 20)) if x) if rn is not None else ""
        dd, dn = defects_between(sh, rs + 3, rh if rh is not None else rend, c0, cday, cnight)
        for night, q, flag, hours, dfs in ((False, q_day, f_day, hours_d, dd), (True, q_night, f_night, hours_n, dn)):
            if q is None and hours is None and not dfs:
                continue
            inputs, mats_out = [], []
            if grp == "BA":
                ins = mats.get("insert_lot_night_raw" if night else "insert_lot_raw") or mats.get("insert_lot_raw")
                bob = mats.get("bobbin_lot_night_raw" if night else "bobbin_lot_raw") or mats.get("bobbin_lot_raw")
                lead = mats.get("lead_pin_lot_night_raw" if night else "lead_pin_lot_raw") or mats.get("lead_pin_lot_raw")
                if ins:
                    inputs.append({"component": "INSERT", "process": "IMEB3_STITCHING", "raw": ins})
                if bob:
                    inputs.append({"component": "BOBBIN", "raw": bob})
                if lead:
                    mats_out.append({"material": "LEAD_PIN", "raw": lead})
                for spindle, lot in mats.get("wires_night" if night else "wires_day") or []:
                    mats_out.append({"material": "WIRE", "raw": lot, "spindle": spindle})
            else:
                up = mats.get("upper_case_lot_night_raw" if night else "upper_case_lot_raw") or mats.get("upper_case_lot_raw")
                lo = mats.get("lower_case_lot_night_raw" if night else "lower_case_lot_raw") or mats.get("lower_case_lot_raw")
                if up:
                    mats_out.append({"material": "UPPER_CASE", "raw": up})
                if lo:
                    mats_out.append({"material": "LOWER_CASE", "raw": lo})
            remarks = " · ".join(x for x in (flag, note, date_note) if x) or None
            rework = re.search(r"리워크\s*(\d+)", note or "")
            out.append({"model": model, "process": proc, "work_date": work_date, "shift": "N" if night else "D",
                        "gross_output_qty": q, "work_minutes": int(round(hours * 60)) if hours is not None else None,
                        "raw_quantity_text": cell(sh, rs + (1 if night else 0), cday) or None,
                        "remarks_raw": remarks, "rework_qty": int(rework.group(1)) if rework else None,
                        "inputs": inputs, "materials": mats_out,
                        "defects": [{"name": k, "qty": int(v) if float(v).is_integer() else None, "raw": str(v)} for k, v in dfs.items()],
                        "source": {"method": "EXCEL", "file": filename, "note": f"시트 '{sh.name}' {r0 + 1}행 · {grp} {'야간' if night else '주간'}"},
                        "_where": f"{sh.name}!{r0 + 1} {grp} {'야간' if night else '주간'}"})
    return out


# ----------------------------------------------------------------- 스티칭 시트
def parse_stitching_block(sh, r0, r1, filename: str) -> list[dict]:
    year = _year_hint(sh, r0, r1) or date.today().year
    hdr = next((cell(sh, r0, c) for c in range(sh.row_len(r0)) if "작업" in cell(sh, r0, c) and "일자" in cell(sh, r0, c)), "")
    work_date, date_note = parse_md(hdr, year)
    if not work_date:   # 날짜가 머리글 옆 칸에 있는 양식
        for c in range(sh.row_len(r0)):
            t = cell(sh, r0, c)
            if re.search(r"\d{1,2}[./]\d{1,2}", t):
                work_date, date_note = parse_md(t, year)
                if work_date:
                    break
    work_date = _fallback_date(sh, r0, min(r1, r0 + 6), work_date)
    rows = {cell(sh, r, 1): r for r in range(r0, min(r1, sh.nrows)) if cell(sh, r, 1)}
    rows.update({cell(sh, r, 0): r for r in range(r0, min(r1, sh.nrows)) if cell(sh, r, 0)})
    rtype = next((r for k, r in rows.items() if k.startswith("Type")), None)
    rqty = next((r for k, r in rows.items() if "생산량" in k), None)
    rhrs = next((r for k, r in rows.items() if k.startswith("작업시간")), None)
    rdef = next((r for k, r in rows.items() if k.startswith("불량수량")), None)
    lab_col = 2 if rdef is not None and cell(sh, rdef, 2) else 1
    out = []
    for night, c in ((False, 3 if lab_col == 2 else 2), (True, 8 if lab_col == 2 else 7)):
        q = num(cell(sh, rqty, c)) if rqty is not None else None
        hours = num(cell(sh, rhrs, c)) if rhrs is not None else None
        dfs = {}
        if rdef is not None:
            for r in range(rdef, rdef + 3):
                lab, v = cell(sh, r, lab_col), cell(sh, r, c)
                if lab and v and num(v) is not None:
                    dfs[lab] = num(v)
        if q is None and hours is None and not dfs:
            continue
        model = cell(sh, rtype, c) if rtype is not None else ""
        if model not in VARIANTS:
            model = next((v for v in VARIANTS if v in model), model)
        lp = [cell(sh, r, c) for k, r in rows.items() if k.startswith("Lead Pin 입고일자")]
        bb = [cell(sh, r, c) for k, r in rows.items() if k.startswith("Bobbin 생산일자")]
        inputs = [{"component": "BOBBIN", "process": "IMEB3_INJECTION", "raw": x} for x in bb if x]
        mats = [{"material": "LEAD_PIN", "raw": x} for x in lp if x]
        rsp = next((r for k, r in rows.items() if "특이사항" in k), None)
        rdt = next((r for k, r in rows.items() if k.startswith("비가동시간")), None)
        notes = []
        if rsp is not None:
            for r in range(rsp + 1, (rdt or r1)):
                t = " ".join(cell(sh, r, cc) for cc in range(0, 9) if cell(sh, r, cc))
                if t:
                    notes.append(t)
        out.append({"model": model, "process": "IMEB3_STITCHING", "work_date": work_date, "shift": "N" if night else "D",
                    "gross_output_qty": int(q) if q is not None else None, "work_minutes": int(round(hours * 60)) if hours is not None else None,
                    "remarks_raw": " | ".join(x for x in notes + ([date_note] if date_note else []) if x) or None,
                    "inputs": inputs, "materials": mats,
                    "defects": [{"name": k, "qty": int(v) if float(v).is_integer() else None, "raw": str(v)} for k, v in dfs.items()],
                    "source": {"method": "EXCEL", "file": filename, "note": f"시트 '{sh.name}' {r0 + 1}행 · 스티칭 {'야간' if night else '주간'}"},
                    "_where": f"{sh.name}!{r0 + 1} 스티칭 {'야간' if night else '주간'}"})
    return out


# ----------------------------------------------------------------- 사출 시트(DS120 양식)
INJ_BLOCK = 35
INJ_DEFECT_ROWS = {5: "미성형", 7: "이물", 9: "핀홀막힘"}


def parse_injection_block(sh, r0, filename: str) -> list[dict]:
    year = _year_hint(sh, r0, r0 + INJ_BLOCK) or date.today().year
    work_date, date_note = parse_md(cell(sh, r0, 0), year)
    if not work_date:
        work_date, date_note = parse_md(sh.name.replace("_", " "), year)
    work_date = _fallback_date(sh, r0, r0 + 6, work_date)
    model = cell(sh, r0 + 1, 4) or next((v for v in VARIANTS if v in sh.name.replace("_", " ")), "")
    note = " ".join(x for x in (cell(sh, r0 + 9, c) for c in range(1, 10)) if x) or None
    out = []
    for night, rr in ((False, 3), (True, 6)):
        qty = num(cell(sh, r0 + rr, 1))
        hours = num(cell(sh, r0 + rr, 3))
        if hours is not None and hours > 24:
            hours = None
        if qty is None and hours is None and not cell(sh, r0 + rr, 5):
            continue
        ct, cq = (23, 26) if night else (18, 21)
        dfs = {}
        for off, default in INJ_DEFECT_ROWS.items():
            name = cell(sh, r0 + off, ct) or default
            q = cell(sh, r0 + off, cq)
            if q and num(q) is not None:
                dfs[name.replace(" ", "")] = num(q)
        rres = r0 + (23 if night else 19)
        resin_lot, resin_use, resin_code = cell(sh, rres, 24), cell(sh, rres, 26), cell(sh, rres, 20)
        mats = [{"material": "RESIN", "raw": resin_lot, "qty": num(resin_use), "unit": "kg" if resin_use else None}] if resin_lot else []
        out.append({"model": model, "process": "IMEB3_INJECTION", "work_date": work_date, "shift": "N" if night else "D",
                    "gross_output_qty": int(qty) if qty is not None else None, "work_minutes": int(round(hours * 60)) if hours is not None else None,
                    "defect_qty": int(num(cell(sh, r0 + rr, 2))) if num(cell(sh, r0 + rr, 2)) is not None else None,
                    "raw_quantity_text": cell(sh, r0 + rr, 1) or None,
                    "remarks_raw": " · ".join(x for x in (cell(sh, r0 + rr, 5) or None, note, date_note) if x) or None,
                    "equipment_raw": " ".join(x for x in ("DS120-1", resin_code and f"수지 {resin_code}") if x),
                    "inputs": [], "materials": mats,
                    "defects": [{"name": k, "qty": int(v) if float(v).is_integer() else None, "raw": str(v)} for k, v in dfs.items()],
                    "source": {"method": "EXCEL", "file": filename, "note": f"시트 '{sh.name}' {r0 + 1}행 · 사출 {'야간' if night else '주간'}"},
                    "_where": f"{sh.name}!{r0 + 1} 사출 {'야간' if night else '주간'}"})
    return out


# ----------------------------------------------------------------- 진입점
def looks_like_form(first_row: list) -> bool:
    """머리글 한 줄 템플릿(model, process, work_date …)이 아니면 양식으로 본다."""
    hdr = {str(h).strip().lower() for h in first_row if h is not None}
    return not ({"model", "process", "work_date"} <= hdr)


def parse_form_workbook(data: bytes, filename: str) -> list[dict]:
    import openpyxl.reader.excel as ex
    ex.ExcelReader.read_custom = lambda self: None   # 일부 xlsx 의 문서 속성 오류 우회
    wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    sheets = [_Sheet(ws) for ws in wb.worksheets]
    raws: list[dict] = []
    for sh in sheets:
        name = sh.name
        if "Stitching" in name or "스티칭" in name:
            starts = [r for r in range(sh.nrows) if any("작업" in cell(sh, r, c) and "일자" in cell(sh, r, c) for c in range(sh.row_len(r)))]
            for i, r0 in enumerate(starts):
                raws.extend(parse_stitching_block(sh, r0, starts[i + 1] - 1 if i + 1 < len(starts) else sh.nrows, filename))
            continue
        asm = [(r, c) for r in range(sh.nrows) for c in (0, 1) if cell(sh, r, c).startswith("작업일자")]
        if asm and any(find_row(sh, r, sh.nrows, c, r"공정명\s*:\s*WINDING") is not None for r, c in asm[:1]):
            for i, (r0, c0) in enumerate(asm):
                r1 = asm[i + 1][0] - 1 if i + 1 < len(asm) else sh.nrows
                raws.extend(parse_assembly_block(sh, r0, r1, c0, filename))
            continue
        r = 0
        while r < sh.nrows:
            if cell(sh, r, 0).startswith("작업일자"):
                raws.extend(parse_injection_block(sh, r, filename))
                r += INJ_BLOCK
            else:
                r += 1
    items = []
    for k, raw in enumerate(raws, start=1):
        where = raw.pop("_where", str(k))
        try:
            p = JournalPayload.model_validate(raw)
            items.append({"row": where, "ok": True, "payload": p.model_dump(), "normalized": p.normalized()})
        except Exception as e:  # noqa: BLE001 - 항목 단위 오류를 화면에 보여준다
            items.append({"row": where, "ok": False, "error": " ".join(str(e).split())[:220], "raw": {k2: str(v) for k2, v in raw.items() if v not in (None, [], "")}})
    return items
