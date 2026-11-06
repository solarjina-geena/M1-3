"""사출조건 체크시트(엑셀) 판독 — 관리 화면 '사출조건 체크시트' 탭용.

IV·OV·HSV 체크시트는 양식이 같다(사용자 확인 2026-11-06). 칸 위치 고정표로 읽는다(tools/injection_conditions_to_mqi.py 와 같은 표).
- 값이 든 탭만 읽는다: 탭 이름 = 보빈(사출) LOT (예 20260806D1, 20260910D2, 20260916N1). 사진_…·인벤토리 탭은 건너뛴다.
- 이미지는 읽지 않는다(openpyxl read_only → 셀 값만). 무거운 파일도 메모리 부담이 작다.
- 탭마다 라벨 칸이 양식과 같은지 먼저 검사하고, 다르면 그 탭은 저장하지 않는다(잘못 읽지 않게).
- 모델은 제목 칸(A1 'I MEB3 OV' 등)에서 읽고, 사용자가 고른 모델과 다르면 막는다.
- 기준(가운데 값)·허용폭은 탭마다 같은지 확인한다. 다르면 탭별 기준을 보여 주고 저장 시 첫 탭 기준으로 하지 않고 멈춘다.
"""
from __future__ import annotations

import hashlib
import io
import re
from typing import Any

import openpyxl

TAB_RE = re.compile(r"^(20\d{2})(\d{2})(\d{2})([DN])(\d+)$")

LABELS = {
    "D8": "현재온도", "I6": "Nz", "M6": "H1", "Q6": "H2", "U6": "H3", "Y6": "H4", "AC6": "작동유",
    "C13": "쿠션mm", "I13": "보압1", "N13": "사출4", "R13": "사출3", "V13": "사출2", "Z13": "사출1",
    "AD15": "속도 %", "AD18": "압력 kgf", "AD21": "시간 sec", "AD24": "위치 mm",
    "C28": "냉각시간", "K28": "계량지연", "O28": "계량감시", "Y28": "현사출위치",
    "F34": "석백1", "J34": "계량1", "N34": "계량2", "R34": "계량3", "V34": "석백2", "AA34": "보빈무게",
    "A36": "속도 %", "A39": "압력 kgf", "A42": "위치 mm", "A45": "배압 kgf",
    "C49": "사출 sec", "G49": "계량 sec", "K49": "메인압력", "O49": "전환압력", "S49": "전환위치",
    "W49": "전환속도", "AA49": "생산공정\n시간",
    "C56": "금형 고정\n(계기판)", "G56": "금형 이동\n(계기판)", "K56": "표면 고정\n(비접촉)",
    "O56": "표면 이동\n(비접촉)", "S56": "온조기\n온도", "W56": "호퍼건조\n(눈금)",
}

# (code, name, unit, group, 기준칸|None, 허용폭칸|None, 주간칸, 야간칸) — tools/injection_conditions_to_mqi.py 와 같은 표
P: list[tuple] = []


def _grid(prefix, name_prefix, unit, group, ref_row, cols):
    for code, label, col, tol in cols:
        P.append((f"{prefix}_{code}", f"{name_prefix} {label}".strip(), unit, group,
                  f"{col}{ref_row}", f"{tol}{ref_row}" if tol else None, f"{col}{ref_row + 1}", f"{col}{ref_row + 2}"))


_grid("INJ_TEMP", "현재온도", "℃", "온도 설정", 8, [
    ("NZ", "Nz", "I", "K"), ("H1", "H1", "M", "O"), ("H2", "H2", "Q", "S"), ("H3", "H3", "U", "W"),
    ("H4", "H4", "Y", "AA"), ("OIL", "작동유", "AC", None)])
_INJ = [("HOLD1", "보압1", "I", None), ("S4", "사출4", "N", "P"), ("S3", "사출3", "R", "T"), ("S2", "사출2", "V", "X"), ("S1", "사출1", "Z", "AB")]
_grid("INJ_SPEED", "사출 속도", "%", "사출·계량", 15, _INJ)
_grid("INJ_PRESS", "사출 압력", "kgf", "사출·계량", 18, _INJ)
_grid("INJ_TIME", "사출 시간", "sec", "사출·계량", 21, _INJ)
_grid("INJ_POS", "사출 위치", "mm", "사출·계량", 24, _INJ)
P.append(("INJ_CUSHION", "쿠션", "mm", "사출·계량", "C21", None, "C22", "C23"))
_grid("INJ_ETC", "", None, "사출·계량", 30, [
    ("COOL_TIME", "냉각시간", "C", "E"), ("METER_DELAY", "계량지연", "K", None),
    ("METER_MONITOR", "계량감시", "O", None), ("CUR_INJ_POS", "현사출위치", "Y", None)])
_REC = [("SB1", "석백1", "F", "H"), ("M1", "계량1", "J", "L"), ("M2", "계량2", "N", "P"), ("M3", "계량3", "R", "T"), ("SB2", "석백2", "V", "X")]
_grid("REC_SPEED", "계량 속도", "%", "사출·계량", 36, _REC)
_grid("REC_PRESS", "계량 압력", "kgf", "사출·계량", 39, _REC)
_grid("REC_POS", "계량 위치", "mm", "사출·계량", 42, _REC)
_grid("REC_BACKPRESS", "배압", "kgf", "사출·계량", 45, _REC)
for _c, _l, _u, _s, _e in [("INJ_SEC", "사출 시간", "sec", "C", "E"), ("METER_SEC", "계량 시간", "sec", "G", "I"),
                           ("MAIN_PRESS", "메인압력", None, "K", "M"), ("SWITCH_PRESS", "전환압력", None, "O", "Q"),
                           ("SWITCH_POS", "전환위치", None, "S", "U"), ("SWITCH_SPEED", "전환속도", None, "W", "Y"),
                           ("CYCLE", "생산공정 시간", None, "AA", "AC")]:
    P.append((f"MON_{_c}_START", f"{_l} (시작)", _u, "사출·계량", None, None, f"{_s}52", f"{_s}53"))
    P.append((f"MON_{_c}_END", f"{_l} (종료)", _u, "사출·계량", None, None, f"{_e}52", f"{_e}53"))
_grid("MOLD", "", "℃", "현장 측정", 58, [
    ("TEMP_FIXED", "금형 고정(계기판)", "C", "E"), ("TEMP_MOVING", "금형 이동(계기판)", "G", "I"),
    ("SURF_FIXED", "표면 고정(비접촉)", "K", "M"), ("SURF_MOVING", "표면 이동(비접촉)", "O", "Q"), ("TCU_TEMP", "온조기 온도", "S", "U")])
P.append(("HOPPER_DRY", "호퍼건조(눈금)", None, "현장 측정", "W58", "Y58", "W59", "W60"))
P.append(("BOBBIN_WEIGHT", "보빈무게", "g", "사출·계량", None, None, "AA36", "AA38"))   # AA36 주간 실측, AA38 '야간 보빈무게: x g'

_NUM = re.compile(r"^\s*-?\d+(?:\.\d+)?\s*$")
_EMBED = re.compile(r"(-?\d+(?:\.\d+)?)\s*g\b")
_MODEL = re.compile(r"I\s*MEB\s*3\s*(IV|OV|HSV)\b", re.I)


def _num(v, embedded=False):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str) and _NUM.match(v):
        return float(v)
    if embedded and isinstance(v, str):
        m = _EMBED.search(v)
        if m:
            return float(m.group(1))
    return None


def _spec_rev(doc: str) -> str:
    """기준문서 번호(예 S30420B1). '(… 확인 필요)'처럼 번호가 없으면 빈칸."""
    tok = (doc or "").split()
    return tok[0] if tok and re.fullmatch(r"[A-Z0-9][A-Z0-9\-]{3,}", tok[0]) and "확인" not in doc else ""


def _norm(v) -> str:
    return re.sub(r"\s+", "", str(v or ""))


def _cell_map(ws, cells: set[str]) -> dict[str, Any]:
    """read_only 시트에서 필요한 칸만 모은다(행 순회 1번)."""
    want: dict[int, dict[int, str]] = {}
    for ref in cells:
        col, row = openpyxl.utils.cell.coordinate_from_string(ref)
        want.setdefault(row, {})[openpyxl.utils.cell.column_index_from_string(col)] = ref
    out: dict[str, Any] = {}
    maxr = max(want)
    for r_idx, row in enumerate(ws.iter_rows(min_row=1, max_row=maxr, max_col=31, values_only=True), start=1):
        if r_idx in want:
            for c_idx, ref in want[r_idx].items():
                out[ref] = row[c_idx - 1] if c_idx - 1 < len(row) else None
    return out


NEED_CELLS = set(LABELS) | {"A1", "Y2"} | {c for p in P for c in p[4:8] if c}


def read_workbook(data: bytes, filename: str, model: str | None) -> dict:
    sha = hashlib.sha256(data).hexdigest()
    wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    tabs, skipped = [], []
    try:
        for name in wb.sheetnames:
            m = TAB_RE.match(name.strip())
            if not m:
                skipped.append(name)
                continue
            ws = wb[name]
            cm = _cell_map(ws, NEED_CELLS)
            bad = [c for c, lab in LABELS.items() if _norm(cm.get(c)) != _norm(lab)]
            title = str(cm.get("A1") or "")
            mm = _MODEL.search(title)
            tab_model = mm.group(1).upper() if mm else None
            problem = None
            if bad:
                problem = f"양식 칸이 다름({', '.join(bad[:5])}{'…' if len(bad) > 5 else ''})"
            elif not tab_model:
                problem = "제목 칸(A1)에서 모델을 못 읽음"
            elif model and tab_model != model:
                problem = f"제목 모델 {tab_model} ≠ 고른 모델 {model}"
            y, mo, d, sh, seq = m.groups()
            date = f"{y}-{mo}-{d}"
            spec_doc = str(cm.get("Y2") or "").strip()
            specs, obs, skipped_cells = {}, [], []
            for code, pname, unit, group, ref_c, tol_c, day_c, night_c in P:
                if ref_c:
                    t = _num(cm.get(ref_c))
                    tol = _num(cm.get(tol_c)) if tol_c else None
                    if t is not None:
                        specs[code] = {"target": t, "tol": tol, "cell": ref_c, "tol_cell": tol_c if tol is not None else None}
                for row, cell in (("DAY", day_c), ("NIGHT", night_c)):
                    raw = cm.get(cell)
                    v = _num(raw, embedded=(code == "BOBBIN_WEIGHT"))
                    if v is None:
                        if raw not in (None, "") and not (code == "BOBBIN_WEIGHT" and "저울" in str(raw)):
                            skipped_cells.append({"cell": cell, "raw": str(raw)[:40]})
                        continue
                    obs.append({"code": code, "row": row, "cell": cell, "value": v, "raw": str(raw).strip()})
            lot = f"{y[2:]}{mo}{d}{sh}{seq}"
            tabs.append({"tab": name, "lot": lot, "date": date, "shift": sh, "model": tab_model, "title": title.strip()[:80],
                         "spec_doc": spec_doc, "spec_rev": _spec_rev(spec_doc), "specs": specs, "obs": obs,
                         "day_obs": sum(1 for o in obs if o["row"] == "DAY"), "night_obs": sum(1 for o in obs if o["row"] == "NIGHT"),
                         "skipped_cells": skipped_cells[:20], "problem": problem})
    finally:
        wb.close()
    ok = [t for t in tabs if not t["problem"]]
    # 기준이 탭마다 같은지
    spec_diff = []
    if ok:
        base = ok[0]
        for t in ok[1:]:
            for code in set(base["specs"]) | set(t["specs"]):
                a, b = base["specs"].get(code), t["specs"].get(code)
                if (a or {}).get("target") != (b or {}).get("target") or (a or {}).get("tol") != (b or {}).get("tol"):
                    spec_diff.append({"tab": t["tab"], "code": code, "base": a, "this": b})
        revs = {t["spec_rev"] for t in ok}
        if len(revs) > 1:
            spec_diff.append({"tab": "*", "code": "SPEC_REVISION", "base": sorted(revs)[0], "this": sorted(revs)})
    names = {p[0]: (p[1], p[2], p[3]) for p in P}
    return {"file": filename, "sha256": sha, "size": len(data), "model": model or (ok[0]["model"] if ok else None),
            "tabs": tabs, "skipped_tabs": skipped, "spec_diff": spec_diff[:30], "params": names}
