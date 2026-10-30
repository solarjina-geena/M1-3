"""xls(xlrd)·xlsx(openpyxl) 를 같은 모양으로 여는 어댑터. 정답지 파서(tools/injection_xls_to_docs.py 등)가 두 형식을 같이 읽게 한다."""
from __future__ import annotations

import datetime as _dt
from pathlib import Path

import xlrd


class _Sheet:
    def __init__(self, ws):
        self.name = ws.title
        self._rows = [list(r) for r in ws.iter_rows(values_only=True)]
        self.nrows = len(self._rows)
        self.ncols = max((len(r) for r in self._rows), default=0)

    def row_len(self, r):
        return len(self._rows[r]) if r < self.nrows else 0

    def cell_value(self, r, c):
        v = self._rows[r][c] if r < self.nrows and c < len(self._rows[r]) else None
        if v is None:
            return ""
        if isinstance(v, (_dt.datetime, _dt.date)):
            return v
        return v

    def cell_type(self, r, c):
        v = self._rows[r][c] if r < self.nrows and c < len(self._rows[r]) else None
        return xlrd.XL_CELL_DATE if isinstance(v, (_dt.datetime, _dt.date)) else (xlrd.XL_CELL_EMPTY if v in (None, "") else xlrd.XL_CELL_TEXT)


class _Book:
    datemode = 0

    def __init__(self, path: Path):
        import openpyxl
        import openpyxl.reader.excel as ex
        ex.ExcelReader.read_custom = lambda self: None   # 일부 정답지 xlsx 의 문서 속성 오류 우회
        wb = openpyxl.load_workbook(str(path), data_only=True, read_only=True)
        self._sheets = [_Sheet(ws) for ws in wb.worksheets]
        for s in self._sheets:
            s.book = self

    def sheets(self):
        return self._sheets

    def sheet_names(self):
        return [s.name for s in self._sheets]

    def sheet_by_name(self, n):
        return next(s for s in self._sheets if s.name == n)

    def sheet_by_index(self, i):
        return self._sheets[i]


def open_book(path):
    p = Path(path)
    if p.suffix.lower() == ".xlsx":
        return _Book(p)
    return xlrd.open_workbook(str(p))


def date_cell_text(sh, r, c) -> str | None:
    """날짜형 칸을 'M.D' 원문 표기로. xlrd·openpyxl 모두 지원."""
    v = sh.cell_value(r, c)
    if isinstance(v, (_dt.datetime, _dt.date)):
        return f"{v.month}.{v.day}"
    if sh.cell_type(r, c) == xlrd.XL_CELL_DATE:
        d = xlrd.xldate_as_datetime(v, sh.book.datemode)
        return f"{d.month}.{d.day}"
    return None
