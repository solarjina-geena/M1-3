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

    def injection_condition_rows(self, limit: int = 5000) -> list[dict]:
        """사출 단계 화면용 조건 시계열(뷰 m13_injection_condition_rows: 기준 SPEC_TARGET + 주야 실측 OBSERVATION)."""
        out, page, off = [], 1000, 0
        while len(out) < limit:
            rows = self.c.select("m13_injection_condition_rows", {"order": "date.asc,id.asc", "offset": str(off)}, limit=min(page, limit - len(out)))
            out.extend(rows)
            if len(rows) < page:
                break
            off += page
        # 화면은 처음 만난 순서대로 그래프를 그리므로 체크시트 칸 순서(행 → 열 → 날짜)로 정렬한다.
        def cell_key(r: dict) -> tuple:
            m = re.match(r"([A-Z]+)(\d+)$", r.get("source_cell") or "")
            col = sum((ord(c) - 64) * 26 ** k for k, c in enumerate(reversed(m.group(1)))) if m else 999
            row = int(m.group(2)) if m else 999
            return (row, col, r.get("date") or "", r.get("value_role") != "SPEC_TARGET")
        out.sort(key=cell_key)
        return out

    # ---------------------------------------------------------------- 사출조건 (설비 DS120-1, 체크시트 → parameter_observation)
    # 사출 전문가 관점 우선 인자(보빈 중량·치수에 영향이 큰 순서). 화면·AI 창이 같은 정의를 쓴다.
    INJECTION_FACTORS = [
        {"rank": 1, "key": "pressure", "title": "사출압력 · 보압",
         "why": "보압(압력·시간)이 캐비티 보압충전량을 정해 보빈 중량·치수에 가장 직접 작용",
         "series": ["INJ_PRESS_HOLD1", "INJ_PRESS_S1"]},
        {"rank": 2, "key": "switchover", "title": "전환위치(V/P) · 쿠션",
         "why": "충전→보압 전환 시점과 남은 쿠션량이 샷 충전량 편차(미성형·과충전)를 좌우",
         "series": ["MON_SWITCH_POS_START", "INJ_CUSHION"]},
        {"rank": 3, "key": "temperature", "title": "온도 (노즐·실린더·금형)",
         "why": "용융 점도와 수축률을 바꿔 중량·치수에 영향, 변화는 느리게 나타남",
         "series": ["INJ_TEMP_NZ", "INJ_TEMP_H1", "MOLD_TEMP_FIXED"]},
    ]
    INJECTION_LATER = "4순위 사출속도(충전 패턴·외관 영향, 중량 영향 작음) · 5순위 계량(설정 고정, 결과는 쿠션으로 확인)"

    def injection_runs(self) -> list[dict]:
        """사출 설비 DS120-1 의 실행 순서(뷰 m13_injection_runs). IV·OV·HSV 가 한 설비에서 겹치지 않고 이어진다."""
        return self.c.select("m13_injection_runs", {"order": "date.asc,shift_code.asc,sequence_no.asc"}, limit=5000)

    def injection_anchor(self, code: str, model: str | None = None) -> dict:
        """LOT 표기(마킹코드 ZIC / LOT 코드 260903D1 / 날짜) -> 그 LOT 을 만든 보빈(사출) LOT 과 사출 실행.
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
            inj[start["lot_code"]] = {"lot_code": start["lot_code"], "lot_date": start["lot_date"], "link": "기준 LOT 자체"}
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
                        inj.setdefault(r["input_lot_code"], {"lot_code": r["input_lot_code"], "lot_date": r["input_lot_date"],
                                                             "link": r.get("in_status") or ""})
                    else:
                        todo.append(r["input_lot_id"])
        runs = [x for x in self.injection_runs() if x["variant"] == mdl]
        out = []
        for code_, v in sorted(inj.items(), key=lambda kv: (kv[1]["lot_date"] or "", kv[0])):
            hit = [x for x in runs if code_ in (x.get("bobbin_lot_code") or "").split("/")]
            out.append({**v, "process_run_ids": [x["process_run_id"] for x in hit],
                        "has_conditions": any(x.get("has_conditions") for x in hit)})
        return {"found": True, "query": code, "lot_code": start["lot_code"], "process_code": start["process_code"], "model": mdl,
                "resolved": resolved, "injection_lots": out}

    def injection_window(self, code: str | None = None, model: str | None = None, before: int = 4, after: int = 3) -> dict:
        """사출조건 기록(체크시트 1장의 주/야 = 사출 실행 1건)을 설비 실행 순서로 줄 세우고, 기준 LOT 의 사출 실행 앞 before 건, 뒤 after 건.
        기준 LOT 이 없으면 데이터가 있는 전체 기간. 우선 인자(INJECTION_FACTORS)와 보빈무게의 실측·SPEC 만 담는다."""
        rows = [r for r in self.injection_condition_rows() if r["value_role"] == "OBSERVATION"]
        runs = {x["process_run_id"]: x for x in self.injection_runs()}
        recs: dict[str, dict] = {}
        for r in rows:
            k = r.get("process_run_id") or f"{r['source_sheet']}|{r.get('shift_code')}"
            run = runs.get(r.get("process_run_id") or "")
            rec = recs.setdefault(k, {"key": k, "date": r["date"], "shift_code": r.get("shift_code") or "", "variant": r["variant"],
                                      "process_run_id": r.get("process_run_id"), "sequence_no": (run or {}).get("sequence_no") or 1,
                                      "bobbin_lot_code": r.get("bobbin_lot_code") or (run or {}).get("bobbin_lot_code"),
                                      "quantity": (run or {}).get("quantity"), "sheet": r["source_sheet"], "has_conditions": True,
                                      "run_link": "사출 실행 FK" if r.get("process_run_id") else "사출 실행 기록 없음", "values": {}})
            rec["values"][r["parameter_code"]] = {"value": r["condition_value"], "raw": r.get("raw_cell_value"),
                                                  "lo": r.get("spec_lower"), "hi": r.get("spec_upper"), "target": r.get("spec_target"),
                                                  "unit": r.get("unit_context"), "cell": r.get("source_cell"), "name": r["series_key"],
                                                  "spec_revision": r.get("spec_revision"), "spec_status": r.get("spec_status")}
        anchor = self.injection_anchor(code, model) if code else None
        anchor_keys: list[str] = []
        if anchor and anchor.get("found"):
            for lot in anchor["injection_lots"]:
                for rid in lot["process_run_ids"]:
                    if rid not in recs and rid in runs:  # 조건표가 없는 사출 실행도 자리는 둔다
                        x = runs[rid]
                        recs[rid] = {"key": rid, "date": x["date"], "shift_code": x["shift_code"], "variant": x["variant"],
                                     "process_run_id": rid, "sequence_no": x.get("sequence_no") or 1, "bobbin_lot_code": x.get("bobbin_lot_code"),
                                     "quantity": x.get("quantity"), "sheet": None, "has_conditions": False,
                                     "run_link": "조건표 없음", "values": {}}
                    if rid in recs:
                        anchor_keys.append(rid)
        seq = sorted(recs.values(), key=lambda r: (r["date"], r["shift_code"] != "D", r["sequence_no"], r["variant"]))
        for r in seq:
            r["is_anchor"] = r["key"] in anchor_keys
        if anchor_keys:
            idx = [i for i, r in enumerate(seq) if r["is_anchor"]]
            seq = seq[max(0, idx[0] - before): idx[-1] + after + 1]
        keep = {c for f in self.INJECTION_FACTORS for c in f["series"]} | {"BOBBIN_WEIGHT"}
        for r in seq:
            r["values"] = {k: v for k, v in r["values"].items() if k in keep}
        return {"anchor": anchor, "window": {"before": before, "after": after, "applied": bool(anchor_keys)},
                "equipment": "DS120-1", "factors": self.INJECTION_FACTORS, "later_factors": self.INJECTION_LATER, "records": seq}

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
