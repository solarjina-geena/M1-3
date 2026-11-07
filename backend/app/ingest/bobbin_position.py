"""사출 보빈 초품 위치도 엑셀(IMEB3 Bobbin 초품 위치도) 판독 — 관리 화면 '보빈 위치도' 탭용. 2026-11-06

양식(월별 파일, 모델별 시트 IV / 0V / HSV):
- 블록이 옆으로 2개씩, 아래로 여러 개. 블록 제목 칸 'iMEB3 IV BOBBIN …', 같은 줄 오른쪽에 날짜 '26.08.27㈜' / '26.08.27(야)' / '26.08.21'
- 제목 아래 3줄: '초품 좌/우' · 'X Y 위치도 판정' · 'NO 1.98~2.22 11.88~12.12 0.35'(기준 줄)
- 그 아래 16줄: 캐비티 NO, 좌 X·Y·위치도·판정, 우 X·Y·위치도·판정
- 값 없는 양식 블록(위치도 칸이 24.36 NG)은 건너뛴다. 같은 모델에 값이 완전히 같은 블록은 '복사본'으로 표시(저장 기본 해제).
주/야: ㈜·(주 = D, (야 = N, 표시 없음 = None(DB 가 그날 사출 실행이 1건일 때만 연결).

새 양식(2026-10 말~, 팀장 확인 2026-11-07): X·Y 없이 캐비티 NO · 좌 XY위치도 · 판정 · 우 XY위치도 · 판정 4칸.
제목 왼쪽 칸(10월: '10.27' 숫자, 표시 형식 0.00) 또는 오른쪽 칸(11월: '11.02')에 연도 없는 월.일 → 같은 파일의 연도(없으면 올해).
한 파일·한 시트에 두 양식이 섞여 있어도 블록마다 머리 줄('XY위치도' 유무)로 구분한다. 위치도 값은 그대로 저장(lpos/rpos).
"""
from __future__ import annotations

import hashlib
import io
import re

import openpyxl

_TITLE = re.compile(r"iMEB3\s*(IV|OV|0V|HSV)\b", re.I)
_DATE = re.compile(r"(\d{2})\.(\d{1,2})\.(\d{1,2})")
_MD = re.compile(r"(?<![\d.])(\d{1,2})\.(\d{2})(?![\d.])")   # 연도 없는 월.일(새 양식)


def _num(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v).strip())
    except ValueError:
        return None


def _fmt(v):
    s = repr(float(v))
    return s[:-2] if s.endswith(".0") else s


def _date_text(v) -> str:
    """날짜 칸 → 글자. 숫자로 든 월.일(10.2 = 10월 20일, 표시 형식 0.00)은 소수 둘째 자리까지."""
    if isinstance(v, bool) or v is None:
        return ""
    if isinstance(v, (int, float)):
        return f"{float(v):.2f}"
    return str(v)


def _parse_date(text: str, year: int) -> str | None:
    dm = _DATE.search(text)
    if dm:
        y, mo, d = 2000 + int(dm.group(1)), int(dm.group(2)), int(dm.group(3))
    else:
        mm = _MD.search(text)
        if not mm:
            return None
        y, mo, d = year, int(mm.group(1)), int(mm.group(2))
    if not (1 <= mo <= 12 and 1 <= d <= 31):
        return None
    return f"{y}-{mo:02d}-{d:02d}"


def _blocks_from_grid(sheet: str, rows: list[list]) -> list[dict]:
    """격자(엑셀 시트 또는 붙여넣은 표)에서 제목 칸을 찾아 블록을 읽는다. 예전 양식(X·Y)과 새 양식(XY위치도만)을 블록마다 구분."""
    import datetime as _dt
    years = [2000 + int(m.group(1)) for r in rows for v in r if isinstance(v, str) for m in [_DATE.search(v)] if m]
    year = years[0] if years else _dt.date.today().year
    out = []
    for i, r in enumerate(rows):
        for j, v in enumerate(r):
            if not (isinstance(v, str) and _TITLE.search(v)):
                continue
            model = _TITLE.search(v).group(1).upper().replace("0V", "OV")
            # 날짜: 오른쪽(다음 제목 전까지) → 없으면 바로 왼쪽 칸
            right = []
            for x in r[j + 1:j + 10]:
                if isinstance(x, str) and _TITLE.search(x):
                    break
                if x is not None:
                    right.append(_date_text(x))
            cands = [t for t in right if _DATE.search(t) or _MD.search(t)] + ([_date_text(r[j - 1])] if j > 0 else [])
            dcell = next((t for t in cands if _parse_date(t, year)), "")
            date = _parse_date(dcell, year) if dcell else None
            shift = "D" if ("㈜" in dcell or "(주" in dcell) else "N" if "(야" in dcell else None
            hdr = [str(x) if x is not None else "" for x in (rows[i + 2] if i + 2 < len(rows) else [])]
            pos_cols = [k for k in range(max(0, j - 1), min(len(hdr), j + 8)) if "XY위치도" in hdr[k].replace(" ", "")]
            if len(pos_cols) >= 2:   # 새 양식: NO 칸은 첫 위치도 칸 바로 왼쪽
                pts = _points_pos(rows[i + 4:i + 20], pos_cols[0] - 1, pos_cols[0], pos_cols[1])
                spec = [str(rows[i + 3][pos_cols[0]] or "")] if i + 3 < len(rows) and pos_cols[0] < len(rows[i + 3]) else []
                layout = "위치도만"
            else:
                spec = [str(x) if x is not None else "" for x in (rows[i + 3][j + 1:j + 4] if i + 3 < len(rows) else [])]
                pts = _points(rows[i + 4:i + 20], j)
                layout = "X·Y"
            if not pts:
                continue   # 빈 양식
            cell = f"{openpyxl.utils.get_column_letter(j + 1)}{i + 1}"
            out.append({"key": f"{sheet}!{cell}", "sheet": sheet, "cell": cell, "model": model, "label": dcell.strip()[:30],
                        "date": date, "shift": shift, "spec": spec, "rows": pts, "layout": layout,
                        "problem": None if date else "제목 줄에서 날짜를 못 읽음"})
    return out


def _points_pos(rows: list[list], n: int, lc: int, rc: int) -> list[dict]:
    """새 양식 행: NO · 좌 위치도 · 판정 · 우 위치도 · 판정. 위치도 값이 둘 다 비면(빈 양식) 건너뜀."""
    pts = []
    for rr in rows:
        rr = list(rr) + [None] * 12
        no = _num(rr[n]) if n >= 0 else None
        lp, rp = _num(rr[lc]), _num(rr[rc])
        if no is None or not float(no).is_integer() or not 1 <= no <= 32 or (lp is None and rp is None):
            continue
        pts.append({"no": int(no), "lx": None, "ly": None, "rx": None, "ry": None,
                    "lpos": _fmt(lp) if lp is not None else None, "rpos": _fmt(rp) if rp is not None else None,
                    "src_l": str(rr[lc + 1] or "").strip().upper() or None, "src_r": str(rr[rc + 1] or "").strip().upper() or None})
    return pts


def _points(rows: list[list], j: int) -> list[dict]:
    pts = []
    for rr in rows:
        rr = list(rr) + [None] * 12
        no = _num(rr[j])
        lx, ly, rx, ry = (_num(rr[j + 1]), _num(rr[j + 2]), _num(rr[j + 5]), _num(rr[j + 6]))
        if no is None or not float(no).is_integer() or not 1 <= no <= 32 or (lx is None and rx is None):
            continue
        pts.append({"no": int(no), "lx": _fmt(lx) if lx is not None else None, "ly": _fmt(ly) if ly is not None else None,
                    "rx": _fmt(rx) if rx is not None else None, "ry": _fmt(ry) if ry is not None else None,
                    "src_l": str(rr[j + 4] or "").strip().upper() or None, "src_r": str(rr[j + 8] or "").strip().upper() or None})
    return pts


def _mark(blocks: list[dict]) -> None:
    seen: dict[tuple, str] = {}
    for b in blocks:
        sig = (b["model"], tuple((p["no"], p["lx"], p["ly"], p["rx"], p["ry"], p.get("lpos"), p.get("rpos")) for p in b["rows"]))
        b["copy_of"] = seen.get(sig)
        seen.setdefault(sig, b["key"])
    cnt: dict[tuple, int] = {}
    for b in blocks:
        if not b["copy_of"]:
            k = (b["model"], b["date"], b["shift"])
            cnt[k] = cnt.get(k, 0) + 1
    for b in blocks:
        b["same_day_blocks"] = cnt.get((b["model"], b["date"], b["shift"]), 0)


def read_text(text: str, model: str | None, date: str | None, shift: str | None) -> dict:
    """엑셀에서 복사해 붙여넣은 표(탭 구분). 제목 줄을 함께 복사하면 제목에서, 숫자 줄만이면 고른 모델·날짜·주야로."""
    rows = [line.split("\t") for line in text.replace("\r", "").split("\n")]
    rows = [[(c.strip() or None) for c in r] for r in rows]
    blocks = _blocks_from_grid("붙여넣기", rows)
    if not blocks:
        hdr = next((r for r in rows if sum("XY위치도" in str(c or "").replace(" ", "") for c in r) >= 2), None)
        if hdr:
            pc = [k for k, c in enumerate(hdr) if "XY위치도" in str(c or "").replace(" ", "")]
            pts = _points_pos(rows, pc[0] - 1, pc[0], pc[1])
        else:
            pts = _points(rows, 0)
        if pts:
            problem = None if (model and date) else "제목 줄이 없어 모델·측정일을 위에서 골라 주세요"
            label = f"{(date or '')[2:].replace('-', '.')}{'㈜' if shift == 'D' else '(야)' if shift == 'N' else ''}"
            blocks = [{"key": "붙여넣기!A1", "sheet": "붙여넣기", "cell": "A1", "model": model or "?", "label": label, "date": date,
                       "shift": shift or None, "spec": [], "rows": pts, "problem": problem}]
    for k, b in enumerate(blocks, 1):
        b["key"] = f"붙여넣기 {k}"
        if b["shift"] is None and shift in ("D", "N"):   # 제목에 주/야가 없으면 위에서 고른 주/야
            b["shift"] = shift; b["label"] += "㈜" if shift == "D" else "(야)"
    _mark(blocks)
    sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return {"file": "붙여넣기", "sha256": sha, "size": len(text), "blocks": blocks}


def read_workbook(data: bytes, filename: str) -> dict:
    sha = hashlib.sha256(data).hexdigest()
    wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    blocks = []
    try:
        for ws in wb.worksheets:
            rows = [list(r) for r in ws.iter_rows(min_row=1, max_row=ws.max_row or 400, max_col=40, values_only=True)]
            blocks += _blocks_from_grid(ws.title, rows)
    finally:
        wb.close()
    _mark(blocks)
    return {"file": filename, "sha256": sha, "size": len(data), "blocks": blocks}
