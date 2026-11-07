"""비전 가성불량 조치 엑셀(iMEB3 비젼 가성불량 검사) 읽기 — 2026-11-07 팀장 요청.

양식: 블록(가로 4칸 × 세로 24줄)이 옆·아래로 반복.
  '날짜: 10/1' | 'iMEB3 비젼 가성불량 검사'
  '구 분'      | '1차 IV' | '2차 IV'
  '검사 수량' / '불량 수량' / '양품 수량'
  '불량 유형'  | ' 불량 수량 '
  유형 이름 줄들(Bobbin 파손, Lead Pin 휨, … 권선) — 1차·2차 칸에 수량
1블록의 1차·2차 칸 = 비전 재검사 1건씩. 불량 = 진성, 양품 = 가성.
엑셀 파일(.xls/.xlsx)과 엑셀에서 복사한 붙여넣기(탭 구분) 둘 다 받는다. 날짜에 연도가 없어 연도는 따로 받는다(기본: 파일명·올해).
"""
from __future__ import annotations

import hashlib
import io
import re

_DATE = re.compile(r"(\d{1,2})\s*[./월]\s*(\d{1,2})")
_LABEL = re.compile(r"([123])\s*차\s*(IV|OV|HSV)", re.I)


def _num(v):
    if v is None or str(v).strip() == "":
        return None
    try:
        return int(round(float(str(v).replace(",", ""))))
    except ValueError:
        return None


def _cell(g, r, c):
    return str(g[r][c]).strip() if r < len(g) and c < len(g[r]) and g[r][c] is not None else ""


def _col_name(c: int) -> str:
    s = ""
    c += 1
    while c:
        c, m = divmod(c - 1, 26)
        s = chr(65 + m) + s
    return s


def blocks_from_grid(g: list[list], year: int, file: str, sheet: str = "") -> list[dict]:
    out = []
    for r in range(len(g)):
        for c in range(len(g[r])):
            v = _cell(g, r, c)
            if not v.startswith("날짜"):
                continue
            m = _DATE.search(v)
            cell = f"{sheet + '!' if sheet else ''}{_col_name(c)}{r + 1}"
            if not m:
                continue          # 빈 양식 블록('날짜: ')
            date = f"{year:04d}-{int(m.group(1)):02d}-{int(m.group(2)):02d}"
            for k in (1, 2):
                lab = _cell(g, r + 1, c + k)
                if not lab:
                    continue
                mm = _LABEL.search(lab)
                insp, bad, good = (_num(_cell(g, r + i, c + k)) for i in (2, 3, 4))
                key = f"{cell}:{k}"
                if not mm:
                    out.append({"key": key, "cell": cell, "date": date, "label": lab, "problem": f"구분 '{lab}'에서 차수·모델을 읽지 못함"}); continue
                if not insp:
                    continue      # 검사 수량 빈칸/0 = 그날 그 차수 재검사 없음
                defs = []
                for i in range(6, 6 + 20):
                    name = _cell(g, r + i, c)
                    if not name or name.startswith("날짜"):
                        break
                    q = _num(_cell(g, r + i, c + k))
                    if q:
                        defs.append([name, q])
                t, f = bad or 0, good or 0
                tsum = sum(d[1] for d in defs)
                fs = ([["FALSE_REJECT", None, f, "양품(가성)"]] if f else []) + [["TRUE_DEFECT", n, q, n] for n, q in defs] \
                    + ([["TRUE_DEFECT", None, t - tsum, "유형 미기재"]] if t > tsum else [])
                chk = None if (t == tsum and insp == t + f) else f"엑셀 합계 불일치: 검사 {insp} / 진성 {t} (유형 합 {tsum}) / 양품 {f}"
                out.append({"key": key, "cell": cell, "date": date, "round": int(mm.group(1)), "model": mm.group(2).upper(), "label": lab,
                            "inspected": insp, "true": t, "false": f, "types": defs, "fs": fs, "check": chk, "problem": None})
    return out


def _year_from_name(name: str, default: int) -> int:
    m = re.search(r"(20\d{2})", name or "")
    return int(m.group(1)) if m else default


def read_workbook(data: bytes, name: str, year: int) -> dict:
    sha = hashlib.sha256(data).hexdigest()
    year = _year_from_name(name, year)
    blocks: list[dict] = []
    if name.lower().endswith(".xls"):
        import xlrd
        wb = xlrd.open_workbook(file_contents=data)
        for sh in wb.sheets():
            g = [sh.row_values(r) for r in range(sh.nrows)]
            blocks += blocks_from_grid(g, year, name, sh.name if wb.nsheets > 1 else "")
    else:
        import openpyxl
        wb = openpyxl.load_workbook(io.BytesIO(data), data_only=True, read_only=True)
        for ws in wb.worksheets:
            g = [list(row) for row in ws.iter_rows(values_only=True)]
            blocks += blocks_from_grid(g, year, name, ws.title if len(wb.worksheets) > 1 else "")
    return {"file": name, "sha256": sha, "year": year, "blocks": blocks}


def read_text(text: str, year: int) -> dict:
    g = [line.split("\t") for line in text.replace("\r\n", "\n").split("\n")]
    sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    name = f"붙여넣기-{sha[:8]}"
    return {"file": name, "sha256": sha, "year": year, "blocks": blocks_from_grid(g, year, name)}
