"""Supabase(mqi) 구현. 읽기는 public.m13_* 뷰와 mqi 테이블, 쓰기는 m13_* RPC."""
from __future__ import annotations

import re

from collections import defaultdict
from typing import Any

from ..config import settings
from ..db.supabase_client import SupabaseError, get_client
from .base import MODELS, PROCESS_CODES, Repository


def _date_filter(params: dict, col: str, date_from: str | None, date_to: str | None) -> None:
    conds = []
    if date_from:
        conds.append(f"{col}.gte.{date_from}")
    if date_to:
        conds.append(f"{col}.lte.{date_to}")
    if conds:
        params["and"] = "(" + ",".join(conds) + ")"


class SupabaseRepository(Repository):
    def __init__(self) -> None:
        self.c = get_client()

    # ---------------------------------------------------------------- 읽기
    def health(self) -> dict:
        info = settings.status()
        try:
            rows = self.c.select("product_model", {"select": "model_code"}, schema=settings.schema, limit=10)
            info["db"] = "ok"
            info["models"] = [r["model_code"] for r in rows]
            counts = {}
            for t in ("production_lot", "process_run", "inspection_run", "process_run_lot", "material_usage", "quality_finding"):
                counts[t] = len(self.c.select(t, {"select": "record_state", "record_state": "eq.ACTIVE"}, schema=settings.schema, limit=100000))
            info["rows"] = counts
        except SupabaseError as e:
            info["db"] = f"error: {e}"
        return info

    def summary(self, model: str | None = None) -> dict:
        params = {}
        if model:
            params["model_code"] = f"eq.{model}"
        prod = self.c.select("m13_daily_production", params, limit=100000)
        insp = self.c.select("m13_daily_inspection", params, limit=100000)
        gaps = self.c.select("m13_lot_chain_gaps", params, limit=100000)
        by_proc: dict[str, dict] = defaultdict(lambda: {"runs": 0, "qty": 0, "defects": 0, "minutes": 0, "days": set(), "models": set()})
        for r in prod:
            b = by_proc[r["process_code"]]
            b["runs"] += r["runs"] or 0
            b["qty"] += r["gross_output_qty"] or 0
            b["defects"] += r["defect_qty"] or 0
            b["minutes"] += r["work_minutes"] or 0
            b["days"].add(r["work_date"])
            b["models"].add(r["model_code"])
        fin = {"runs": sum(r["runs"] for r in insp), "qty": sum(r["inspected_qty"] or 0 for r in insp),
               "defects": sum(r["defect_qty"] or 0 for r in insp), "days": len({r["inspection_date"] for r in insp})}
        processes = []
        for code in PROCESS_CODES:
            if code == "IMEB3_FINAL_INSPECTION":
                processes.append({"process_code": code, **fin})
            else:
                b = by_proc.get(code) or {"runs": 0, "qty": 0, "defects": 0, "minutes": 0, "days": set(), "models": set()}
                processes.append({"process_code": code, "runs": b["runs"], "qty": b["qty"], "defects": b["defects"],
                                  "minutes": b["minutes"], "days": len(b["days"]), "models": sorted(b["models"])})
        depth = defaultdict(int)
        for g in gaps:
            depth[g["depth"]] += 1
        dates = sorted({r["work_date"] for r in prod} | {r["inspection_date"] for r in insp})
        return {"processes": processes, "date_range": [dates[0], dates[-1]] if dates else None,
                "chain": {"ca_lots": len(gaps), "complete": depth.get(4, 0), "by_depth": dict(depth),
                          "with_inspection": sum(1 for g in gaps if g["inspections"])},
                "models": MODELS}

    def process_series(self, process: str, model: str | None, date_from: str | None, date_to: str | None) -> list[dict]:
        params: dict[str, Any] = {}
        if model:
            params["model_code"] = f"eq.{model}"
        if process == "IMEB3_FINAL_INSPECTION":
            _date_filter(params, "inspection_date", date_from, date_to)
            rows = self.c.select("m13_daily_inspection", {**params, "order": "inspection_date"}, limit=100000)
            agg: dict[tuple, dict] = {}
            for r in rows:
                k = (r["inspection_date"], r["model_code"])
                a = agg.setdefault(k, {"date": k[0], "model": k[1], "runs": 0, "qty": 0, "defects": 0, "reinspections": 0})
                a["runs"] += r["runs"]
                a["qty"] += r["inspected_qty"] or 0
                a["defects"] += r["defect_qty"] or 0
                a["reinspections"] += r["runs"] if r["inspection_type"] == "REINSPECTION" else 0
            out = sorted(agg.values(), key=lambda a: (a["date"], a["model"]))
            for a in out:
                a["defect_rate"] = round(a["defects"] / a["qty"] * 100, 3) if a["qty"] else None
            return out
        params["process_code"] = f"eq.{process}"
        _date_filter(params, "work_date", date_from, date_to)
        rows = self.c.select("m13_daily_production", {**params, "order": "work_date"}, limit=100000)
        agg = {}
        for r in rows:
            k = (r["work_date"], r["model_code"])
            a = agg.setdefault(k, {"date": k[0], "model": k[1], "runs": 0, "qty": 0, "defects": 0, "minutes": 0, "shifts": set()})
            a["runs"] += r["runs"]
            a["qty"] += r["gross_output_qty"] or 0
            a["defects"] += r["defect_qty"] or 0
            a["minutes"] += r["work_minutes"] or 0
            a["shifts"].add(r["shift"])
        out = []
        for a in sorted(agg.values(), key=lambda a: (a["date"], a["model"])):
            a["shifts"] = sorted(a["shifts"])
            a["defect_rate"] = round(a["defects"] / a["qty"] * 100, 3) if a["qty"] else None
            a["qty_per_hour"] = round(a["qty"] / (a["minutes"] / 60), 1) if a["minutes"] else None
            out.append(a)
        return out

    def defects(self, process: str | None, model: str | None, date_from: str | None, date_to: str | None) -> list[dict]:
        params: dict[str, Any] = {}
        if model:
            params["model_code"] = f"eq.{model}"
        if process:
            params["process_code"] = f"eq.{process}"
        _date_filter(params, "the_date", date_from, date_to)
        rows = self.c.select("m13_defect_by_type", params, limit=100000)
        agg: dict[tuple, dict] = {}
        for r in rows:
            k = (r["process_code"], r["defect_name"])
            a = agg.setdefault(k, {"process_code": k[0], "defect_name": k[1], "qty": 0, "findings": 0, "models": set()})
            a["qty"] += r["qty"] or 0
            a["findings"] += r["findings"]
            a["models"].add(r["model_code"])
        out = sorted(agg.values(), key=lambda a: -a["qty"])
        for a in out:
            a["models"] = sorted(a["models"])
        return out

    def chain_gaps(self, model: str | None, only_gaps: bool = False) -> list[dict]:
        params: dict[str, Any] = {"order": "depth,ca_date"}
        if model:
            params["model_code"] = f"eq.{model}"
        if only_gaps:
            params["depth"] = "lt.4"
        return self.c.select("m13_lot_chain_gaps", params, limit=100000)

    def chain_rows(self, model: str | None) -> list[dict]:
        params: dict[str, Any] = {"order": "lot_date"}
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_lot_chain", params, limit=100000)

    def resolve_lot_code(self, code: str) -> dict:
        """사람이 쓰는 LOT 표기를 DB 의 LOT 코드(YYMMDD+교대+순번)로. 최종검사 마킹코드(ZIC) 는 조견표 매핑(lot_code_mapping)으로 CA LOT 날짜를 찾는다."""
        c = (code or "").strip().upper()
        if re.fullmatch(r"\d{6}[DN]\d", c):
            return {"lot_code": c, "how": "LOT 코드 그대로"}
        if re.fullmatch(r"[A-Z][A-Z0-9]{2}", c):
            rows = self.c.select("lot_code_mapping", {"marking_code": f"eq.{c}", "record_state": "eq.ACTIVE", "select": "lot_date,validation_status"}, schema=settings.schema, limit=5)
            if rows:
                d = rows[0]["lot_date"]
                return {"lot_code": f"{d[2:4]}{d[5:7]}{d[8:10]}D1", "how": f"최종검사 마킹코드 {c} → 조견표 매핑 CA 제품 LOT 날짜 {d} ({rows[0]['validation_status']})", "marking_code": c, "lot_date": d}
            return {"lot_code": c, "how": f"마킹코드 {c} 의 조견표 매핑 없음"}
        m = re.fullmatch(r"(?:20)?(\d{2})[-./](\d{1,2})[-./](\d{1,2})", c)
        if m:
            return {"lot_code": f"{m.group(1)}{int(m.group(2)):02d}{int(m.group(3)):02d}D1", "how": "날짜 표기 → 주간 1번 LOT 코드"}
        m = re.fullmatch(r"(\d{1,2})\s*[/.월]\s*(\d{1,2})\s*일?", c)
        if m:
            return {"lot_code": f"26{int(m.group(1)):02d}{int(m.group(2)):02d}D1", "how": "월/일 표기 → 2026년 주간 1번 LOT 코드"}
        return {"lot_code": c, "how": "형식 미상"}

    def lot_trace(self, lot_code: str, model: str | None) -> dict:
        resolved = self.resolve_lot_code(lot_code)
        lot_code = resolved["lot_code"]
        params: dict[str, Any] = {"lot_code": f"eq.{lot_code}"}
        if model:
            params["model_code"] = f"eq.{model}"
        start = self.c.select("m13_lot_chain", params, limit=1000)
        if not start:
            return {"found": False, "lot_code": lot_code, "model": model, "resolved": resolved}
        all_rows = self.chain_rows(start[0]["model_code"])
        by_lot: dict[str, list] = defaultdict(list)
        children: dict[str, list] = defaultdict(list)
        for r in all_rows:
            by_lot[r["lot_id"]].append(r)
            if r["input_lot_id"]:
                children[r["input_lot_id"]].append(r)
        nodes, edges, seen = {}, [], set()

        def node(r, key):
            nid = r["lot_id"] if key == "lot_id" else r["input_lot_id"]
            if nid and nid not in nodes:
                nodes[nid] = {"lot_id": nid, "lot_code": r["lot_code"] if key == "lot_id" else r["input_lot_code"],
                              "process_code": r["process_code"] if key == "lot_id" else r["input_process_code"],
                              "lot_date": r["lot_date"] if key == "lot_id" else r["input_lot_date"], "model": r["model_code"]}
            return nid

        def walk_up(lot_id, depth=0):
            if lot_id in seen or depth > 8:
                return
            seen.add(lot_id)
            for r in by_lot.get(lot_id, []):
                a = node(r, "lot_id")
                if r["input_lot_id"]:
                    b = node(r, "input")
                    edges.append({"from": b, "to": a, "status": r["in_status"], "evidence": r["input_evidence"], "direction": "upstream"})
                    walk_up(r["input_lot_id"], depth + 1)

        def walk_down(lot_id, depth=0):
            if depth > 8:
                return
            for r in children.get(lot_id, []):
                a = node(r, "lot_id")
                b = node(r, "input")
                e = {"from": b, "to": a, "status": r["in_status"], "evidence": r["input_evidence"], "direction": "downstream"}
                if e not in edges:
                    edges.append(e)
                if r["lot_id"] not in seen:
                    seen.add(r["lot_id"])
                    walk_down(r["lot_id"], depth + 1)

        root = start[0]["lot_id"]
        walk_up(root)
        walk_down(root)
        codes = {n["lot_code"] for n in nodes.values()}
        mats = [m for m in self.c.select("m13_lot_materials", {"model_code": f"eq.{start[0]['model_code']}"}, limit=100000) if m["lot_code"] in codes]
        insp = [i for i in self.c.select("m13_lot_inspections", {"model_code": f"eq.{start[0]['model_code']}"}, limit=100000) if i["lot_code"] in codes]
        return {"found": True, "root": root, "model": start[0]["model_code"], "resolved": resolved, "nodes": list(nodes.values()), "edges": edges,
                "materials": mats, "inspections": insp}

    def fishbone_rows(self) -> list[dict]:
        """전체흐름 그래프용 행(뷰 m13_fishbone_rows). PostgREST 는 한 번에 1000행까지만 주므로 offset 으로 끝까지 읽는다."""
        out, page, off = [], 1000, 0
        while True:
            rows = self.c.select("m13_fishbone_rows", {"order": "date.asc,id.asc", "offset": str(off)}, limit=page)
            out.extend(rows)
            if len(rows) < page:
                return out
            off += page

    def recent_runs(self, model: str | None, limit: int = 50) -> list[dict]:
        params: dict[str, Any] = {"order": "work_date.desc"}
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_daily_production", params, limit=limit)

    # ---------------------------------------------------------------- 쓰기
    def _guard(self) -> None:
        if settings.read_only:
            raise SupabaseError("이 환경은 읽기 전용입니다(팀 DB 또는 M13_READ_ONLY=1). 쓰기는 개인 프로젝트에서만 합니다.")

    def journal_save(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_journal_save", {"p": payload})

    def link_confirm(self, table: str, row_id: str, status: str, reason: str) -> dict:
        self._guard()
        return self.c.rpc("m13_link_confirm", {"p": {"table": table, "id": row_id, "status": status, "actor": settings.actor, "reason": reason}})


_repo: Repository | None = None


def get_repository() -> Repository:
    global _repo
    if _repo is None:
        _repo = SupabaseRepository()
    return _repo
