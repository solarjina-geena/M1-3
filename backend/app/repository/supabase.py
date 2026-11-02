"""Supabase(mqi) 구현. 읽기는 public.m13_* 뷰와 mqi 테이블, 쓰기는 m13_* RPC."""
from __future__ import annotations

import json
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

    def stitching_defect_quantity_status(self, model: str | None, date_from: str | None, date_to: str | None) -> list[dict]:
        """Count NULL quantities without turning blanks into confirmed zeroes.

        The existing aggregate view cannot distinguish NULL within a mixed group.
        Return counts only; raw records and source remarks stay on the server.
        """
        params: dict[str, Any] = {
            "select": "quality_finding_id,defect_type!inner(defect_name),process_run!fk_quality_finding_process_run_id_model_id!inner(work_date,process!inner(process_code),product_model!inner(model_code))",
            "record_state": "eq.ACTIVE", "quantity": "is.null",
            "process_run.process.process_code": "eq.IMEB3_STITCHING",
            "order": "quality_finding_id",
        }
        if model:
            params["process_run.product_model.model_code"] = f"eq.{model}"
        date_params: dict[str, Any] = {}
        _date_filter(date_params, "work_date", date_from, date_to)
        if "and" in date_params:
            params["process_run.and"] = date_params["and"]
        counts: dict[str, int] = defaultdict(int)
        offset = 0
        while True:
            rows = self.c.select("quality_finding", {**params, "offset": offset}, schema=settings.schema, limit=500)
            for row in rows:
                counts[row["defect_type"]["defect_name"]] += 1
            if len(rows) < 500:
                break
            offset += len(rows)
        return [{"defect_name": name, "null_findings": count} for name, count in sorted(counts.items())]

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

    def injection_condition_rows(self, limit: int = 5000) -> list[dict]:
        """사출 단계 화면용 조건 실측(뷰 m13_injection_condition_rows). 시트·셀·LOT 은 팀 출처 테이블에서, 우선순위는 parameter_definition JSON 에서."""
        out, page, off = [], 1000, 0
        while len(out) < limit:
            rows = self.c.select("m13_injection_condition_rows", {"order": "lot_code.asc,id.asc", "offset": str(off)}, limit=min(page, limit - len(out)))
            out.extend(rows)
            if len(rows) < page:
                break
            off += page

        # 화면은 처음 만난 순서대로 그래프를 그리므로 체크시트 칸 순서(행 → 열 → LOT)로 정렬한다.
        def cell_key(r: dict) -> tuple:
            m = re.match(r"([A-Z]+)(\d+)$", r.get("source_cell") or "")
            col = sum((ord(c) - 64) * 26 ** k for k, c in enumerate(reversed(m.group(1)))) if m else 999
            row = int(m.group(2)) if m else 999
            return (row, col, r.get("lot_code") or "")
        out.sort(key=cell_key)
        return out

    def injection_priorities(self) -> dict:
        """조건 우선순위(사출 전문가 기준)를 parameter_definition.description JSON 의 priority 에서 읽는다(코드에 고정하지 않음)."""
        defs = self.c.select("parameter_definition", {"select": "parameter_code,parameter_name,unit,description", "record_state": "eq.ACTIVE"},
                             schema=settings.schema, limit=1000)
        factors: dict[int, dict] = {}
        later: dict[int, dict] = {}
        bobbin = None
        for d in defs:
            try:
                p = (json.loads(d["description"]) if (d.get("description") or "").startswith("{") else {}).get("priority")
            except ValueError:
                p = None
            if not p:
                continue
            if p.get("role") == "bobbin_weight":
                bobbin = d["parameter_code"]
                continue
            rank = int(p.get("rank") or 0)
            target = factors if p.get("chart", True) else later
            f = target.setdefault(rank, {"rank": rank, "title": p.get("title") or "", "why": p.get("why") or "", "series": [], "axis": {}})
            f["series"].append((int(p.get("order") or 9), d["parameter_code"]))
            if p.get("axis"):
                f["axis"][d["parameter_code"]] = p["axis"]
        out = []
        for rank in sorted(factors):
            f = factors[rank]
            f["series"] = [c for _, c in sorted(f["series"])]
            out.append(f)
        later_txt = " · ".join(f"{r}순위 {later[r]['title']}({later[r]['why']})" for r in sorted(later))
        return {"factors": out, "later": later_txt, "bobbin": bobbin}

    def injection_runs(self) -> list[dict]:
        """사출 설비의 실행 목록(뷰 m13_injection_runs: 설비 사용 기록·OUTPUT LOT). 한 설비에서 모델이 겹치지 않고 이어진다."""
        return self.c.select("m13_injection_runs", {"order": "bobbin_lot_code.asc,sequence_no.asc"}, limit=5000)

    def injection_anchor(self, code: str, model: str | None = None) -> dict:
        """LOT 표기(마킹코드 ZIC / LOT 코드 260903D1) -> 그 LOT 을 만든 보빈(사출) LOT 과 사출 실행.
        LOT 사슬(m13_lot_chain)을 위로 거슬러 사출 LOT 을 모으고, 사출 실행은 process_run_lot(OUTPUT)으로 찾는다."""
        resolved = self.resolve_lot_code(code)
        lc = resolved["lot_code"]
        params: dict[str, Any] = {"lot_code": f"eq.{lc}"}
        if model:
            params["model_code"] = f"eq.{model}"
        rows = self.c.select("m13_lot_chain", params, limit=1000)
        if not rows:
            return {"found": False, "query": code, "lot_code": lc, "resolved": resolved, "injection_lots": []}
        order = {"IMEB3_CA_PRESS": 0, "IMEB3_WINDING": 1, "IMEB3_STITCHING": 2, "IMEB3_INJECTION": 3}
        if resolved.get("marking_code"):
            pref = sorted(rows, key=lambda r: order.get(r["process_code"], 9))  # 마킹코드 = CA 제품 LOT
        else:
            pref = sorted(rows, key=lambda r: (r["process_code"] != "IMEB3_INJECTION", order.get(r["process_code"], 9)))
        start = pref[0]
        mdl = start["model_code"]
        inj: dict[str, dict] = {}
        if start["process_code"] == "IMEB3_INJECTION":
            inj[start["lot_code"]] = {"lot_code": start["lot_code"], "link": "기준 LOT 자체"}
        else:
            by_lot: dict[str, list] = defaultdict(list)
            for r in self.chain_rows(mdl):
                by_lot[r["lot_id"]].append(r)
            todo, seen = [start["lot_id"]], set()
            while todo:
                lid = todo.pop()
                if lid in seen:
                    continue
                seen.add(lid)
                for r in by_lot.get(lid, []):
                    if not r.get("input_lot_id"):
                        continue
                    if r["input_process_code"] == "IMEB3_INJECTION":
                        inj.setdefault(r["input_lot_code"], {"lot_code": r["input_lot_code"], "link": r.get("in_status") or ""})
                    else:
                        todo.append(r["input_lot_id"])
        runs = [x for x in self.injection_runs() if x["variant"] == mdl]
        out = []
        for code_ in sorted(inj):
            hit = [x for x in runs if code_ in (x.get("bobbin_lot_code") or "").split("/")]
            out.append({**inj[code_], "process_run_ids": [x["process_run_id"] for x in hit],
                        "has_conditions": any(x.get("has_conditions") for x in hit)})
        return {"found": True, "query": code, "lot_code": start["lot_code"], "process_code": start["process_code"], "model": mdl,
                "resolved": {k: v for k, v in resolved.items() if k != "lot_date"}, "injection_lots": out}

    def injection_window(self, code: str | None = None, model: str | None = None, before: int = 4, after: int = 3,
                         all_params: bool = False) -> dict:
        """사출조건 기록(체크시트 탭 = 보빈 LOT, 주/야 행 = LOT D1/N1)을 LOT 순서로 줄 세우고, 기준 LOT 의 사출 LOT 앞 before 건 · 뒤 after 건.
        기준 LOT 이 없으면 데이터가 있는 전체. 날짜는 쓰지 않는다(LOT 코드가 순서). all_params=False 면 우선 인자와 보빈 중량만."""
        pri = self.injection_priorities()
        rows = self.injection_condition_rows()
        runs = {x["process_run_id"]: x for x in self.injection_runs()}
        recs: dict[str, dict] = {}
        params: dict[str, dict] = {}
        for r in rows:
            lot = r.get("lot_code") or f"{r.get('source_sheet')}|{r.get('shift_code')}"
            k = f"{lot}|{r['variant']}"
            run = runs.get(r.get("process_run_id") or "")
            rec = recs.setdefault(k, {"key": k, "lot_code": r.get("lot_code"), "shift_code": r.get("shift_code") or "", "variant": r["variant"],
                                      "process_run_id": r.get("process_run_id"), "sequence_no": (run or {}).get("sequence_no") or 1,
                                      "quantity": (run or {}).get("quantity"), "sheet": r.get("source_sheet"), "has_conditions": True,
                                      "run_link": "사출 실행 FK" if r.get("process_run_id") else "사출 실행 기록 없음", "values": {}})
            rec["values"][r["parameter_code"]] = {"value": r["condition_value"], "raw": r.get("raw_cell_value"),
                                                  "lo": r.get("spec_lower"), "hi": r.get("spec_upper"), "target": r.get("spec_target"),
                                                  "unit": r.get("unit_context"), "cell": r.get("source_cell"), "name": r["series_key"],
                                                  "spec_revision": r.get("spec_revision"), "spec_status": r.get("spec_status")}
            params.setdefault(r["parameter_code"], {"code": r["parameter_code"], "name": r["series_key"], "group": r.get("condition_group")})
        anchor = self.injection_anchor(code, model) if code else None
        anchor_keys: list[str] = []
        if anchor and anchor.get("found"):
            for lot in anchor["injection_lots"]:
                k = f"{lot['lot_code']}|{anchor['model']}"
                if k not in recs:  # 조건표가 없는 사출 LOT 도 자리는 둔다
                    rid = (lot["process_run_ids"] or [None])[0]
                    x = runs.get(rid or "", {})
                    recs[k] = {"key": k, "lot_code": lot["lot_code"], "shift_code": x.get("shift_code") or lot["lot_code"][6:7],
                               "variant": anchor["model"], "process_run_id": rid, "sequence_no": x.get("sequence_no") or 1,
                               "quantity": x.get("quantity"), "sheet": None, "has_conditions": False,
                               "run_link": "조건표 없음" if rid else "사출 실행·조건표 없음", "values": {}}
                anchor_keys.append(k)
        seq = sorted(recs.values(), key=lambda r: (r["lot_code"] or "~", r["sequence_no"], r["variant"]))
        for r in seq:
            r["is_anchor"] = r["key"] in anchor_keys
        if anchor_keys:
            idx = [i for i, r in enumerate(seq) if r["is_anchor"]]
            seq = seq[max(0, idx[0] - before): idx[-1] + after + 1]
        if not all_params:
            keep = {c for f in pri["factors"] for c in f["series"]} | ({pri["bobbin"]} if pri["bobbin"] else set())
            for r in seq:
                r["values"] = {k: v for k, v in r["values"].items() if k in keep}
        equipment = sorted({x.get("equipment_code") for x in runs.values() if x.get("equipment_code")})  # DB 설비 사용 기록에서
        return {"anchor": anchor, "window": {"before": before, "after": after, "applied": bool(anchor_keys)},
                "equipment": "/".join(equipment) or None, "factors": pri["factors"], "later_factors": pri["later"],
                "bobbin_parameter": pri["bobbin"], "parameters": list(params.values()) if all_params else None, "records": seq}

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

    # ---------------------------------------------------------------- CA 초품 핀 위치도 (quality_check 초품 + measurement)
    def position_checks(self, model: str | None = None, date_from: str | None = None, date_to: str | None = None) -> list[dict]:
        """뷰 m13_position_checks: 시료·좌우별 X/Y, 기준 대비 ΔX/ΔY, 위치도(X단독·Y단독·종합)와 판정(정상·경계·불량). 기준은 DB(POSITION-A1-3)."""
        params: dict[str, Any] = {"order": "check_date.asc,variant.asc,side.asc,sample_no.asc"}
        if model:
            params["variant"] = f"eq.{model}"
        if date_from and date_to:
            params["and"] = f"(check_date.gte.{date_from},check_date.lte.{date_to})"
        elif date_from:
            params["check_date"] = f"gte.{date_from}"
        elif date_to:
            params["check_date"] = f"lte.{date_to}"
        return self.c.select("m13_position_checks", params, limit=20000)

    def position_spec(self) -> dict:
        """초품 위치도 기준(모델별): process_setup_spec(POSITION-A1-3) + parameter_definition.description(judge). 입력 미리보기 판정용."""
        sch = settings.schema
        specs = self.c.select("process_setup_spec", {"spec_revision": "eq.POSITION-A1-3", "record_state": "eq.ACTIVE", "select": "spec_id,model_id,verification_status"}, schema=sch, limit=50)
        models = {m["model_id"]: m["model_code"] for m in self.c.select("product_model", {"select": "model_id,model_code"}, schema=sch, limit=50)}
        params = {d["parameter_id"]: d for d in self.c.select("parameter_definition", {"parameter_code": "in.(PIN_X,PIN_Y,PIN_POSITION)", "select": "parameter_id,parameter_code,description"}, schema=sch, limit=10)}
        out: dict[str, dict] = {}
        for sp in specs:
            items = self.c.select("process_setup_spec_item", {"spec_id": f"eq.{sp['spec_id']}", "record_state": "eq.ACTIVE", "select": "parameter_id,target_numeric,max_numeric"}, schema=sch, limit=20)
            m = out.setdefault(models.get(sp["model_id"], "?"), {"status": sp["verification_status"]})
            for it in items:
                d = params.get(it["parameter_id"]) or {}
                code = d.get("parameter_code")
                if code == "PIN_X":
                    m["nom_x"] = it["target_numeric"]
                elif code == "PIN_Y":
                    m["nom_y"] = it["target_numeric"]
                elif code == "PIN_POSITION":
                    m["spec"] = it["max_numeric"]
                    try:
                        j = json.loads(d.get("description") or "{}").get("judge", {})
                    except ValueError:
                        j = {}
                    m["control"] = j.get("control")
                    m["display_range"] = j.get("display_range")
        return out

    def position_save(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_position_save", {"p": payload})

    # ---------------------------------------------------------------- CRUD 이력 (팀 감사 테이블 mqi_audit.row_change → 공정 단계)
    def crud_history(self, stage: str | None = None, actor: str | None = None, limit: int = 3000) -> dict:
        """뷰 m13_crud_history 를 저장 1회(트랜잭션) 단위로 묶는다. 같은 트랜잭션 = 같은 actor·사유로 한 번에 바뀐 행들."""
        params: dict[str, Any] = {"order": "audit_id.desc",
                                  "select": "audit_id,changed_at,table_name,row_id,actor_ref,change_reason,transaction_id,action,stage_code,stage_label,model_code,changed_columns"}
        if stage:
            params["stage_code"] = f"eq.{stage}"
        if actor:
            params["actor_ref"] = f"eq.{actor}"
        rows = self.c.select("m13_crud_history", params, limit=limit)
        groups: dict[Any, dict] = {}
        for r in rows:
            g = groups.setdefault(r["transaction_id"], {"transaction_id": r["transaction_id"], "changed_at": r["changed_at"], "actor": r["actor_ref"],
                                                        "reason": r["change_reason"], "stages": {}, "tables": {}, "actions": {}, "models": set(), "rows": 0})
            g["changed_at"] = min(g["changed_at"], r["changed_at"])
            g["rows"] += 1
            for key, val in (("stages", r["stage_label"]), ("tables", r["table_name"]), ("actions", r["action"])):
                g[key][val] = g[key].get(val, 0) + 1
            if r.get("model_code"):
                g["models"].add(r["model_code"])
        out = []
        for g in groups.values():
            g["models"] = sorted(g["models"])
            out.append(g)
        out.sort(key=lambda g: g["changed_at"], reverse=True)
        stage_totals: dict[str, int] = {}
        for r in rows:
            stage_totals[r["stage_label"]] = stage_totals.get(r["stage_label"], 0) + 1
        return {"transactions": out, "stage_totals": stage_totals, "rows": len(rows), "limited": len(rows) >= limit}

    def crud_rows(self, transaction_id: int) -> list[dict]:
        return self.c.select("m13_crud_history", {"transaction_id": f"eq.{transaction_id}", "order": "audit_id.asc"}, limit=5000)

    def link_confirm(self, table: str, row_id: str, status: str, reason: str, actor: str | None = None) -> dict:
        self._guard()
        return self.c.rpc("m13_link_confirm", {"p": {"table": table, "id": row_id, "status": status, "actor": actor or settings.actor, "reason": reason}})


_repo: Repository | None = None


def get_repository() -> Repository:
    global _repo
    if _repo is None:
        _repo = SupabaseRepository()
    return _repo
