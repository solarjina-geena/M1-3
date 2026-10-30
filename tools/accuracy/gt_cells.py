"""정답지(회사 전산 엑셀) → 정답률 측정용 '칸' 목록.

칸 키 = (item, work_date, model, process_code, shift, sub). DB 쪽 뷰 public.m13_accuracy_cells 와 같은 키.
- 사출/조립/스티칭 정답지는 tools/injection_xls_to_docs.py, tools/assembly_xls_to_docs.py 의 파서를 재사용한다.
- 최종검사는 박*경이 만든 'DB입력용 정형데이터' 표(날짜·검사자·ITEM·검사수량·불량수량)를 쓴다. 검사자 이름은 가린 표시명(박*식)으로만 둔다.

값 종류
- production_qty, work_hours, defect(sub=불량명), material(sub=자재코드, 값=날짜 집합), inspected_qty(sub=검사자 표시명), inspection_defect_total(sub=검사자 표시명)
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import injection_xls_to_docs as inj   # noqa: E402
import assembly_xls_to_docs as asm    # noqa: E402
from accuracy.xlsbook import open_book  # noqa: E402

GT_DIR = Path(r"D:\코디세이\파이널 프로젝트\박수경")
FILES = {
    "injection": ["imeb3사출작업일보_8월_정답지.xls", "imeb3사출작업일보_9월_정답지.xlsx"],
    "assembly": ["imeb3 조립작업일보_8월_정답지.xls", "imeb3 조립작업일보_9월_정답지.xls"],
    "inspection": ["최종검사_8월_DB입력용_정형데이터.xlsx", "최종검사_DB입력용_정형데이터.xlsx"],
}
PROC = {"INJECTION": "IMEB3_INJECTION", "STITCHING": "IMEB3_STITCHING", "BA": "IMEB3_WINDING", "CA": "IMEB3_CA_PRESS"}
MAT = {"resin_lot_raw": "IMEB3_RESIN", "bobbin_lot_raw": "IMEB3_BOBBIN", "lead_pin_lot_raw": "IMEB3_LEAD_PIN",
       "insert_lot_raw": "IMEB3_LEAD_PIN_INSERT", "wire_lot_table_raw": "IMEB3_WIRE",
       "upper_case_lot_raw": "IMEB3_UPPER_CASE", "lower_case_lot_raw": "IMEB3_LOWER_CASE"}
DATE_TOKEN = re.compile(r"(?:(\d{2})[./])?(\d{1,2})[./](\d{1,2})")


@dataclass
class Cell:
    item: str
    work_date: str
    model: str
    process: str
    shift: str          # D / N / '' (최종검사)
    sub: str
    value: object       # 숫자, 문자열, 또는 날짜 집합(frozenset)
    raw: str
    source: str         # 정답지 파일명


def norm_name(s: str) -> str:
    """불량명 비교용: 괄호 안·공백·기호 제거, 소문자."""
    s = re.sub(r"\(.*?\)", "", str(s or ""))
    return re.sub(r"[\s_\-·.()/]", "", s).lower()


# 판독본(영문 키·축약)과 정답지(한글 항목명)를 같은 표준 불량명으로. 키는 norm_name 결과.
CANON = {
    # 권선(BA)
    "weld": "용접불량", "welding": "용접불량", "weldng": "용접불량", "용접": "용접불량", "용접불량": "용접불량",
    "vision1": "비전1차", "vision1ng": "비전1차", "bavision1": "비전1차", "비전1차": "비전1차", "비젼1차": "비전1차",
    "vision2": "비전2차", "vision2ng": "비전2차", "bavision2": "비전2차", "비전2차": "비전2차", "비젼2차": "비전2차",
    "vision3": "비전3차", "vision3ng": "비전3차", "비전3차": "비전3차", "비젼3차": "비전3차",
    "setup": "setup불량", "setupng": "setup불량", "setup불량": "setup불량", "set up 불량": "setup불량",
    "wirebreak": "wire끊어짐", "wirebreakng": "wire끊어짐", "wire끊어짐": "wire끊어짐",
    # 압입(CA)
    "depth": "깊이불량", "depthdefectcandidate": "깊이불량", "깊이": "깊이불량", "깊이불량": "깊이불량",
    "resistance": "저항불량", "caresistance": "저항불량", "저항": "저항불량", "저항불량": "저항불량", "저항9후보": "저항불량",
    "voltage": "내전압불량", "dielectric": "내전압불량", "withstandvoltage": "내전압불량", "내전압": "내전압불량", "내전압불량": "내전압불량",
    "cainnerdiameter": "내경불량", "innerdiameter": "내경불량", "내경": "내경불량", "내경불량": "내경불량",
    "insulation": "절연저항불량", "절연저항": "절연저항불량", "절연저항불량": "절연저항불량",
    "marking": "마킹불량", "마킹": "마킹불량", "마킹불량": "마킹불량",
    "lowercasemix": "lowercase혼입불량", "lowercasemixcandidate": "lowercase혼입불량", "lowercase혼입불량": "lowercase혼입불량",
    "length": "길이불량", "길이불량": "길이불량",
    # 스티칭
    "location": "위치도", "position": "위치도", "위치": "위치도", "위치도": "위치도", "위치도불량": "위치도", "ov위치도": "위치도", "위치도판독값원문유지": "위치도",
    "전장": "전장", "전장불량": "전장", "electrical": "전장",
    "terminal": "기타", "단자": "기타", "기타": "기타",
    # 사출
    "미성형": "미성형", "short": "미성형", "이물": "이물", "foreign": "이물", "핀홀막힘": "핀홀막힘", "pinhole": "핀홀막힘",
}
NOISE = ("worktime", "uncertain", "blank", "공란", "미기재", "판독", "원본", "visioncounts")


def canon_defect(name: str, process: str = "") -> str | None:
    """표준 불량명. 스티칭의 'length' 는 전장(길이)이다. 잡음 이름(작업시간·불확실 표시)은 None."""
    n = norm_name(name)
    if not n or any(k in n for k in NOISE):
        return None
    if process == "IMEB3_STITCHING" and n == "length":
        return "전장"
    return CANON.get(n, n)


def date_set(raw, base_year=2026) -> frozenset:
    """'7.3/7.22', '26.07.02', '1-1(시업) 7.1; 2-1(시업) 7.1' → {ISO 날짜}. 해석 못 하면 원문 토큰."""
    out = set()
    for m in DATE_TOKEN.finditer(str(raw or "")):
        yy, mo, d = m.groups()
        try:
            out.add(date(2000 + int(yy) if yy else base_year, int(mo), int(d)).isoformat())
        except ValueError:
            out.add(m.group(0))
    return frozenset(out)


def mask_name(name: str) -> str:
    n = str(name or "").strip()
    return n[0] + "*" + n[2:] if len(n) >= 3 else (n[0] + "*" if len(n) == 2 else n)


def _production_cells(docs: list[dict], source: str) -> list[Cell]:
    cells = []
    for d in docs:
        if not d.get("date") or d.get("variant") not in ("IV", "OV", "HSV"):
            continue
        dt = d["details"]
        proc = PROC[d["process"]]
        shift = "N" if dt.get("shift") == "NIGHT" else "D"
        key = dict(work_date=d["date"], model=d["variant"], process=proc, shift=shift, source=source)
        if d.get("value") is not None:
            cells.append(Cell("production_qty", sub="", value=float(d["value"]), raw=str(d["value"]), **key))
        if dt.get("production_hours") is not None:
            cells.append(Cell("work_hours", sub="", value=round(float(dt["production_hours"]), 2), raw=str(dt["production_hours"]), **key))
        for name, q in (dt.get("defects") or {}).items():
            cn = canon_defect(name, proc)
            if isinstance(q, (int, float)) and cn:
                cells.append(Cell("defect", sub=cn, value=float(q), raw=f"{name}={q}", **key))
        for field, code in MAT.items():
            raw = dt.get(field)
            if raw:
                ds = date_set(raw)
                if ds:
                    cells.append(Cell("material", sub=code, value=ds, raw=str(raw), **key))
    return cells


def _inspection_cells(path: Path) -> list[Cell]:
    wb = open_book(path)
    sh = wb.sheets()[0]
    hdr = [str(sh.cell_value(0, c)).strip() for c in range(sh.row_len(0))]
    col = {h: i for i, h in enumerate(hdr)}
    cells = []
    for r in range(1, sh.nrows):
        g = lambda k: (str(sh.cell_value(r, col[k])).strip() if k in col and col[k] < sh.row_len(r) else "")
        raw_date, who, item = g("작업일자"), g("검사자"), g("제품명(ITEM)")
        m = re.match(r"(\d{1,2})[./](\d{1,2})", raw_date)
        mm = re.search(r"\((IV|OV|HSV)\)", item)
        if not (m and mm and who):
            continue
        wd = date(2026, int(m.group(1)), int(m.group(2))).isoformat()
        key = dict(work_date=wd, model=mm.group(1), process="IMEB3_FINAL_INSPECTION", shift="", source=path.name)
        q, bad = g("검사수량"), g("불량수량")
        if q and re.fullmatch(r"\d+(\.0)?", q):
            cells.append(Cell("inspected_qty", sub=mask_name(who), value=float(q), raw=q, **key))
        if bad and re.fullmatch(r"\d+(\.0)?", bad):
            cells.append(Cell("inspection_defect_total", sub=mask_name(who), value=float(bad), raw=bad, **key))
    return cells


def load_all(gt_dir: Path = GT_DIR) -> list[Cell]:
    cells: list[Cell] = []
    for f in FILES["injection"]:
        p = gt_dir / f
        if p.exists():
            cells += _production_cells(inj.parse_xls(p), f)
    for f in FILES["assembly"]:
        p = gt_dir / f
        if p.exists():
            cells += _production_cells(asm.parse_xls(p), f)
    for f in FILES["inspection"]:
        p = gt_dir / f
        if p.exists():
            cells += _inspection_cells(p)
    return cells


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    from collections import Counter
    cs = load_all()
    print(len(cs), "칸")
    print(Counter((c.source, c.item) for c in cs).most_common())
