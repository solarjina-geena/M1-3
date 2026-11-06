"""사출 보빈 초품 위치도 엑셀(IMEB3 Bobbin 초품 위치도) 판독 — 관리 화면 '보빈 위치도' 탭용. 2026-11-06

양식(월별 파일, 모델별 시트 IV / 0V / HSV):
- 블록이 옆으로 2개씩, 아래로 여러 개. 블록 제목 칸 'iMEB3 IV BOBBIN …', 같은 줄 오른쪽에 날짜 '26.08.27㈜' / '26.08.27(야)' / '26.08.21'
- 제목 아래 3줄: '초품 좌/우' · 'X Y 위치도 판정' · 'NO 1.98~2.22 11.88~12.12 0.35'(기준 줄)
- 그 아래 16줄: 캐비티 NO, 좌 X·Y·위치도·판정, 우 X·Y·위치도·판정
- 값 없는 양식 블록(위치도 칸이 24.36 NG)은 건너뛴다. 같은 모델에 값이 완전히 같은 블록은 '복사본'으로 표시(저장 기본 해제).
주/야: ㈜·(주 = D, (야 = N, 표시 없음 = None(DB 가 그날 사출 실행이 1건일 때만 연결).
"""
from __future__ import annotations

import hashlib
import io
import re

import openpyxl

_TITLE = re.compile(r"iMEB3\s*(IV|OV|0V|HSV)\b", re.I)
_DATE = re.compile(r"(\d{2})\.(\d{1,2})\.(\d{1,2})")


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


def read_workbook(data: bytes, filename: str) -> dict:
    sha = hashlib.sha256(data).hexdigest()
    wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    blocks = []
    try:
        for ws in wb.worksheets:
            rows = [list(r) for r in ws.iter_rows(min_row=1, max_row=ws.max_row or 400, max_col=40, values_only=True)]
            for i, r in enumerate(rows):
                for j, v in enumerate(r):
                    if not (isinstance(v, str) and _TITLE.search(v)):
                        continue
                    model = _TITLE.search(v).group(1).upper().replace("0V", "OV")
                    dcell = next((str(x) for x in r[j + 1:j + 10] if x is not None and _DATE.search(str(x))), "")
                    dm = _DATE.search(dcell)
                    date = f"20{dm.group(1)}-{int(dm.group(2)):02d}-{int(dm.group(3)):02d}" if dm else None
                    shift = "D" if ("㈜" in dcell or "(주" in dcell) else "N" if "(야" in dcell else None
                    spec = [str(x) if x is not None else "" for x in (rows[i + 3][j + 1:j + 4] if i + 3 < len(rows) else [])]
                    pts = []
                    for k in range(i + 4, min(i + 20, len(rows))):
                        rr = rows[k] + [None] * 12
                        no = _num(rr[j])
                        lx, ly, rx, ry = (_num(rr[j + 1]), _num(rr[j + 2]), _num(rr[j + 5]), _num(rr[j + 6]))
                        if no is None or (lx is None and rx is None):
                            continue
                        pts.append({"no": int(no), "lx": _fmt(lx) if lx is not None else None, "ly": _fmt(ly) if ly is not None else None,
                                    "rx": _fmt(rx) if rx is not None else None, "ry": _fmt(ry) if ry is not None else None,
                                    "src_l": str(rr[j + 4] or "").strip().upper() or None, "src_r": str(rr[j + 8] or "").strip().upper() or None})
                    if not pts:
                        continue   # 빈 양식
                    cell = f"{openpyxl.utils.get_column_letter(j + 1)}{i + 1}"
                    problem = None if date else "제목 줄에서 날짜를 못 읽음"
                    blocks.append({"key": f"{ws.title}!{cell}", "sheet": ws.title, "cell": cell, "model": model, "label": dcell.strip()[:30],
                                   "date": date, "shift": shift, "spec": spec, "rows": pts, "problem": problem})
    finally:
        wb.close()
    # 같은 모델에 값이 똑같은 블록 = 복사본(먼저 나온 블록을 원본으로)
    seen: dict[tuple, str] = {}
    for b in blocks:
        sig = (b["model"], tuple((p["no"], p["lx"], p["ly"], p["rx"], p["ry"]) for p in b["rows"]))
        b["copy_of"] = seen.get(sig)
        seen.setdefault(sig, b["key"])
    # 같은 모델·날짜·주야가 둘 이상
    cnt: dict[tuple, int] = {}
    for b in blocks:
        if not b["copy_of"]:
            k = (b["model"], b["date"], b["shift"])
            cnt[k] = cnt.get(k, 0) + 1
    for b in blocks:
        b["same_day_blocks"] = cnt.get((b["model"], b["date"], b["shift"]), 0)
    return {"file": filename, "sha256": sha, "size": len(data), "blocks": blocks}
