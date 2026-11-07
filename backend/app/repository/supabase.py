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

    def vision_summary(self, model: str | None, date_from: str | None, date_to: str | None) -> dict:
        """권선 비전 불량(2026-11-07): 작업일보 비전 1·2·3차 불량(설비가 걸러낸 수량) + 재검사 엑셀(사람이 다시 본 결과: 가성/진성·유형)."""
        p1: dict[str, Any] = {}
        p2: dict[str, Any] = {}
        if model:
            p1["model_code"] = p2["model_code"] = f"eq.{model}"
        _date_filter(p1, "work_date", date_from, date_to)
        _date_filter(p2, "check_date", date_from, date_to)
        rejects = self.c.select("m13_vision_reject_daily", p1, limit=100000)
        rows = self.c.select("m13_vision_check_rows", p2, limit=100000)
        runs: dict[str, dict] = {}
        for r in rows:
            a = runs.setdefault(r["run_id"], {"model": r["model_code"], "date": r["check_date"], "round": r["round"],
                                               "inspected": r.get("inspected_qty_ea") or 0, "false": 0, "true": 0, "types": {},
                                               "needs_review": r.get("validation_status") == "NEEDS_REVIEW", "linked": bool(r.get("linked_to_journal"))})
            q = r.get("quantity") or 0
            if r.get("finding_class") == "FALSE_REJECT":
                a["false"] += q
            elif r.get("finding_class") == "TRUE_DEFECT":
                a["true"] += q
                n = r.get("defect_name") or "유형 미기재"
                a["types"][n] = a["types"].get(n, 0) + q
        return {"rejects": [{"model": r["model_code"], "date": r["work_date"], "stage": r["stage"], "qty": r["qty"] or 0} for r in rejects],
                "checks": sorted(runs.values(), key=lambda a: (a["date"], a["model"], a["round"]))}

    def final_defects(self, model: str | None, date_from: str | None, date_to: str | None) -> dict:
        """최종검사 불량 유형별 수량·PPM (2026-11-07). 검사 구분(1차·2차·재검)별로 따로 — 화면 기본은 2차(본검사).
        PPM = 불량수량 / 검사수량 × 1e6. 분모·분자 모두 검사수량이 적힌 검사만(빈칸을 0 으로 치지 않음).
        불량명은 표시용으로만 묶는다(app.ingest.final_defect_names). 수량이 빈 불량 줄은 개수만 센다."""
        from ..ingest.final_defect_names import standard_name
        params: dict[str, Any] = {}
        if model:
            params["model_code"] = f"eq.{model}"
        _date_filter(params, "inspection_date", date_from, date_to)
        runs = self.c.select("m13_final_inspection_runs", dict(params), limit=100000)
        rows = self.c.select("m13_final_defect_rows", dict(params), limit=100000)
        insp: dict[str, dict[str, dict]] = {}
        for r in runs:
            a = insp.setdefault(r["model_code"], {}).setdefault(r["inspection_class"], {"runs": 0, "runs_no_qty": 0, "qty": 0})
            a["runs"] += 1
            q = r.get("inspected_qty_ea") or 0
            if q > 0:
                a["qty"] += q
            else:
                a["runs_no_qty"] += 1
        defs: dict[str, dict] = {}
        null_q = 0
        excluded = 0     # 검사수량이 없는 검사에 붙은 불량(막대 수량에는 넣고 PPM 분자에서는 뺀다)
        for r in rows:
            if r.get("quantity") is None:
                null_q += 1
                continue
            name = standard_name(r.get("defect_name"))
            d = defs.setdefault(name, {"name": name, "originals": set(), "by": {}})
            d["originals"].add(r.get("defect_name"))
            b = d["by"].setdefault(r["model_code"], {}).setdefault(r["inspection_class"], {"qty": 0, "qty_ppm": 0})
            b["qty"] += r["quantity"]
            if (r.get("inspected_qty_ea") or 0) > 0:
                b["qty_ppm"] += r["quantity"]
            else:
                excluded += r["quantity"]
        for d in defs.values():
            d["originals"] = sorted(x for x in d["originals"] if x)
            for m, by in d["by"].items():
                for c, b in by.items():
                    den = insp.get(m, {}).get(c, {}).get("qty") or 0
                    b["ppm"] = round(b["qty_ppm"] * 1e6 / den) if den else None
        return {"inspected": insp, "defects": sorted(defs.values(), key=lambda d: -sum(b.get("2차", {}).get("qty", 0) for b in d["by"].values())),
                "null_qty_findings": null_q, "qty_without_inspected": excluded, "from": date_from, "to": date_to, "model": model}

    def inspection_breakdown(self, model: str | None, date_from: str | None, date_to: str | None) -> dict:
        """최종검사 검사 구분별(1차·2차·재검) 집계와 재검 LOT 별 행. 재검은 중복 검사라 본검사 합계와 따로."""
        params: dict[str, Any] = {"order": "inspection_date"}
        if model:
            params["model_code"] = f"eq.{model}"
        _date_filter(params, "inspection_date", date_from, date_to)
        rows = self.c.select("m13_inspection_breakdown", params, limit=100000)
        rp: dict[str, Any] = {"order": "reinspection_date"}
        if model:
            rp["model_code"] = f"eq.{model}"
        _date_filter(rp, "reinspection_date", date_from, date_to)
        lots = self.c.select("m13_reinspection_lot_rows", rp, limit=100000)
        by: dict[tuple, dict] = {}
        for r in rows:
            b = by.setdefault((r["model_code"], r["inspection_class"]), {"model": r["model_code"], "class": r["inspection_class"],
                                                                          "runs": 0, "qty": 0, "defects": 0, "lots": 0, "unresolved_lots": 0, "days": set()})
            b["runs"] += r["runs"] or 0; b["qty"] += r["inspected_qty"] or 0; b["defects"] += r["defect_qty"] or 0
            b["lots"] += r["lots"] or 0; b["unresolved_lots"] += r["unresolved_lots"] or 0; b["days"].add(r["inspection_date"])
        order = {"1차": 1, "2차": 2, "재검": 3, "기타": 4}
        classes = []
        for b in sorted(by.values(), key=lambda b: (b["model"], order.get(b["class"], 9))):
            b["days"] = len(b["days"])
            b["defect_rate"] = round(b["defects"] / b["qty"] * 100, 3) if b["qty"] else None
            b["counted_in_final_total"] = b["class"] == "2차"
            classes.append(b)
        for l in lots:   # 재검 LOT 별 불량률: LOT 에 붙은 불량 / LOT 수량. LOT 이 하나뿐인 재검은 재검 전체 불량을 그 LOT 의 불량으로 본다
            dq = l.get("lot_defect_qty") or (l.get("run_defect_qty") if (l.get("lots_in_run") or 0) == 1 else 0) or 0
            split = bool(l.get("lot_defect_qty")) or (l.get("lots_in_run") or 0) == 1   # 여러 LOT 재검인데 불량을 LOT 에 나누지 않았으면 LOT 불량률은 정하지 않음
            l["lot_defect_rate"] = round(dq / l["lot_qty"] * 100, 3) if l.get("lot_qty") and split else None
            l["run_defect_rate"] = round((l.get("run_defect_qty") or 0) / l["run_qty"] * 100, 3) if l.get("run_qty") and (l.get("lots_in_run") or 0) > 1 else None
        ip: dict[str, Any] = {"order": "model_code,issue_from"}
        if model:
            ip["model_code"] = f"eq.{model}"
        issues = self.c.select("m13_reinsp_issue_defects", ip, limit=1000)
        for i in issues:
            i["reinsp_rate"] = round(i["reinsp_defects"] / i["reinsp_qty"] * 100, 3) if i.get("reinsp_qty") else None
            i["main_rate_since"] = round(i["main_defects_since"] / i["main_qty_since"] * 100, 3) if i.get("main_qty_since") else None
        return {"classes": classes, "reinspection_lots": lots, "issue_defects": issues, "daily": rows,
                "rule": "LOT 검사 수량 = 2차(통상 본검사)만. 1차 = 검사 훈련·신입·타 제품 검사자 지원·연습(합산 제외, 따로 표시). "
                        "재검 = 불량 이슈로 검사 완료품을 다시 본 것 — 재검 LOT 별 수량·불량·불량률 따로(본검사 수량과 합치지 않음). "
                        "이슈 뒤에는 본검사에서도 같은 불량을 검출하므로 '재검 불량 이슈' 표에서 나란히 비교."}

    def summary(self, model: str | None = None) -> dict:
        params = {}
        if model:
            params["model_code"] = f"eq.{model}"
        prod = self.c.select("m13_daily_production", params, limit=100000)
        insp = self.c.select("m13_inspection_breakdown", params, limit=100000)
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
        # 최종검사 검사량·불량 = 2차(통상 본검사)만. 1차(훈련·신입·지원)와 재검(불량 이슈 재선별)은 따로(사용자 규칙 2026-11-07)
        main = [r for r in insp if r["inspection_class"] == "2차"]
        r1 = [r for r in insp if r["inspection_class"] == "1차"]
        re_ = [r for r in insp if r["inspection_class"] == "재검"]
        part = lambda rs, note: {"runs": sum(r["runs"] for r in rs), "qty": sum(r["inspected_qty"] or 0 for r in rs),
                                 "defects": sum(r["defect_qty"] or 0 for r in rs), "days": len({r["inspection_date"] for r in rs}), "note": note}
        fin = {"runs": sum(r["runs"] for r in main), "qty": sum(r["inspected_qty"] or 0 for r in main),
               "defects": sum(r["defect_qty"] or 0 for r in main), "days": len({r["inspection_date"] for r in main}),
               "first_round": part(r1, "1차 = 검사 훈련·신입·타 제품 검사자 지원·연습 — 검사량에 합치지 않음"),
               "reinspection": part(re_, "재검 = 불량 이슈로 검사 완료품 재선별 — 검사량에 합치지 않고 따로 불량률")}
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
            rows = self.c.select("m13_inspection_breakdown", {**params, "order": "inspection_date"}, limit=100000)
            agg: dict[tuple, dict] = {}
            for r in rows:
                k = (r["inspection_date"], r["model_code"])
                a = agg.setdefault(k, {"date": k[0], "model": k[1], "runs": 0, "qty": 0, "defects": 0,
                                       "reinspections": 0, "reinspection_qty": 0, "reinspection_defects": 0, "first_round_qty": 0, "first_round_defects": 0})
                if r["inspection_class"] == "1차":   # 훈련·신입·지원 → 검사량에 합치지 않음
                    a["first_round_qty"] += r["inspected_qty"] or 0
                    a["first_round_defects"] += r["defect_qty"] or 0
                    continue
                if r["inspection_type"] == "REINSPECTION":   # 불량 이슈 재선별 → 본검사 합계와 따로
                    a["reinspections"] += r["runs"]
                    a["reinspection_qty"] += r["inspected_qty"] or 0
                    a["reinspection_defects"] += r["defect_qty"] or 0
                    continue
                a["runs"] += r["runs"]
                a["qty"] += r["inspected_qty"] or 0
                a["defects"] += r["defect_qty"] or 0
            out = sorted(agg.values(), key=lambda a: (a["date"], a["model"]))
            for a in out:
                a["defect_rate"] = round(a["defects"] / a["qty"] * 100, 3) if a["qty"] else None
                a["reinspection_defect_rate"] = round(a["reinspection_defects"] / a["reinspection_qty"] * 100, 3) if a["reinspection_qty"] else None
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
        return self.defect_quantity_status("IMEB3_STITCHING", model, date_from, date_to)

    def defect_quantity_status(self, process: str, model: str | None, date_from: str | None, date_to: str | None) -> list[dict]:
        """Count NULL quantities without turning blanks into confirmed zeroes.

        The existing aggregate view cannot distinguish NULL within a mixed group.
        Return counts only; raw records and source remarks stay on the server.
        """
        final = process == "IMEB3_FINAL_INSPECTION"
        target = "inspection_run" if final else "process_run"
        date_col = "inspection_date" if final else "work_date"
        relation = "fk_quality_finding_inspection_run_id_model_id" if final else "fk_quality_finding_process_run_id_model_id"
        fields = f"{date_col},product_model!inner(model_code)" + ("" if final else ",process!inner(process_code)")
        params: dict[str, Any] = {
            "select": f"quality_finding_id,defect_type!inner(defect_name),{target}!{relation}!inner({fields})",
            "record_state": "eq.ACTIVE", "quantity": "is.null",
            "order": "quality_finding_id",
        }
        if not final:
            params["process_run.process.process_code"] = f"eq.{process}"
        if model:
            params[f"{target}.product_model.model_code"] = f"eq.{model}"
        date_params: dict[str, Any] = {}
        _date_filter(date_params, date_col, date_from, date_to)
        if "and" in date_params:
            params[f"{target}.and"] = date_params["and"]
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

    def lot_flow(self, date: str, process: str, model: str | None) -> dict:
        """날짜 + 공정 → 그날 그 공정의 LOT 들(주간·야간, 모델별)에서 아래 공정으로: 다음 공정에서 언제 쓰였고(스티칭→BA→CA) 최종검사는 언제였는지.
        DB LOT 연결(m13_lot_chain 의 투입 LOT FK)만 따라간다(추정 없음). 최종검사는 CA LOT 에 연결된 검사(m13_lot_inspections). 2026-11-07"""
        params: dict[str, Any] = {"process_code": f"eq.{process}", "lot_date": f"eq.{date}"}
        if model:
            params["model_code"] = f"eq.{model}"
        start = self.c.select("m13_lot_chain", params, limit=1000)
        roots: dict[str, dict] = {}
        for r in start:
            roots.setdefault(r["lot_id"], {"lot_id": r["lot_id"], "lot_code": r["lot_code"], "process_code": r["process_code"], "lot_date": r["lot_date"], "model": r["model_code"]})
        if not roots:
            return {"found": False, "date": date, "process_code": process, "model": model}
        nodes: dict[str, dict] = {}
        edges: list[dict] = []
        insp: list[dict] = []
        per_root = []
        for m in sorted({x["model"] for x in roots.values()}, key=lambda v: {"IV": 0, "OV": 1, "HSV": 2}.get(v, 9)):
            rows = self.chain_rows(m)
            children: dict[str, list] = defaultdict(list)
            parents: dict[str, list] = defaultdict(list)
            for r in rows:
                if r["input_lot_id"]:
                    children[r["input_lot_id"]].append(r)
                    parents[r["lot_id"]].append(r)
            ca_codes: set[str] = set()
            for root in [x for x in roots.values() if x["model"] == m]:
                nodes[root["lot_id"]] = dict(root, root=True)
                seen = {root["lot_id"]}
                stack = [(root["lot_id"], 0)]
                reach = defaultdict(set)
                while stack:
                    lid, depth = stack.pop()
                    if depth > 8:
                        continue
                    for r in children.get(lid, []):
                        nid = r["lot_id"]
                        nodes.setdefault(nid, {"lot_id": nid, "lot_code": r["lot_code"], "process_code": r["process_code"], "lot_date": r["lot_date"], "model": m})
                        e = {"from": lid, "to": nid, "status": r["in_status"], "evidence": r["input_evidence"]}
                        if e not in edges:
                            edges.append(e)
                        reach[r["process_code"]].add((r["lot_code"], r["lot_date"]))
                        if r["process_code"] == "IMEB3_CA_PRESS":
                            ca_codes.add(r["lot_code"])
                        if nid not in seen:
                            seen.add(nid)
                            stack.append((nid, depth + 1))
                # 위(앞 공정) 방향도: CA 로 물으면 권선·스티칭·사출까지 거꾸로 (2026-11-07 팀장)
                stack = [(root["lot_id"], 0)]
                seen_up = {root["lot_id"]}
                while stack:
                    lid, depth = stack.pop()
                    if depth > 8:
                        continue
                    for r in parents.get(lid, []):
                        pid = r["input_lot_id"]
                        nodes.setdefault(pid, {"lot_id": pid, "lot_code": r["input_lot_code"], "process_code": r["input_process_code"], "lot_date": r["input_lot_date"], "model": m})
                        e = {"from": pid, "to": lid, "status": r["in_status"], "evidence": r["input_evidence"]}
                        if e not in edges:
                            edges.append(e)
                        reach[r["input_process_code"]].add((r["input_lot_code"], r["input_lot_date"]))
                        if pid not in seen_up:
                            seen_up.add(pid)
                            stack.append((pid, depth + 1))
                if root["process_code"] == "IMEB3_CA_PRESS":
                    ca_codes.add(root["lot_code"])
                per_root.append({"model": m, "lot_code": root["lot_code"], "lot_date": root["lot_date"],
                                 **{k: sorted(v, key=lambda t: (t[1] or '', t[0])) for k, v in reach.items()}})
            if ca_codes:
                for i in self.c.select("m13_lot_inspections", {"model_code": f"eq.{m}"}, limit=100000):
                    if i["lot_code"] in ca_codes:
                        insp.append(i)
        # 요약(대화창·표): 뿌리 LOT 마다 다음 공정 LOT·날짜, CA LOT 마다 검사 날짜·구분·수량
        summ_insp: dict[tuple, dict] = {}
        for i in insp:
            k = (i["model_code"], i["lot_code"], i["inspection_date"], i["inspection_class"])
            a = summ_insp.setdefault(k, {"model": k[0], "ca_lot": k[1], "inspection_date": k[2], "class": k[3], "rows": 0, "qty_ea": 0})
            a["rows"] += 1
            a["qty_ea"] += i.get("lot_qty_ea") or 0
        return {"found": True, "date": date, "process_code": process, "model": model, "roots": list(roots.values()), "per_root": per_root,
                "nodes": list(nodes.values()), "edges": edges, "inspections": insp,
                "inspection_summary": sorted(summ_insp.values(), key=lambda a: (a["model"], a["ca_lot"], a["inspection_date"]))}

    def lot_trace(self, lot_code: str, model: str | None, process: str | None = None) -> dict:
        resolved = self.resolve_lot_code(lot_code)
        lot_code = resolved["lot_code"]
        params: dict[str, Any] = {"lot_code": f"eq.{lot_code}"}
        if model:
            params["model_code"] = f"eq.{model}"
        # 질문에 공정이 있으면 그 공정의 LOT 으로 찾는다(2026-11-07 팀장). 마킹코드(ZIC 등)는 CA 제품 표시라 공정 조건을 쓰지 않는다.
        if process and not resolved.get("marking_code"):
            params["process_code"] = f"eq.{process}"
        start = self.c.select("m13_lot_chain", params, limit=1000)
        if not start:
            return {"found": False, "lot_code": lot_code, "model": model, "process_code": process, "resolved": resolved}
        # 같은 LOT 번호(날짜+주야)가 공정·모델마다 있다(예 260915D1 = 8개). CA(제품) LOT 을 먼저 고른다(2026-11-07 팀장 결정).
        # 모델을 말하지 않았는데 고를 공정의 LOT 이 여러 모델에 있으면 마음대로 고르지 않고 후보만 돌려준다(화면이 모델을 고르게 함).
        order = {"IMEB3_CA_PRESS": 0, "IMEB3_WINDING": 1, "IMEB3_STITCHING": 2, "IMEB3_INJECTION": 3}
        start.sort(key=lambda r: (order.get(r.get("process_code"), 9), {"IV": 0, "OV": 1, "HSV": 2}.get(r.get("model_code"), 9)))
        best = order.get(start[0].get("process_code"), 9)
        top_models = sorted({r["model_code"] for r in start if order.get(r.get("process_code"), 9) == best}, key=lambda m: {"IV": 0, "OV": 1, "HSV": 2}.get(m, 9))
        if not model and len(top_models) > 1:
            return {"found": False, "ambiguous": True, "lot_code": lot_code, "model": None, "resolved": resolved,
                    "process_code": start[0].get("process_code"), "candidates": top_models}
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

    def journal_exists(self, payload: dict[str, Any]) -> dict:
        """같은 일보(모델·작업일·교대·공정·순번, 최종검사는 검사자·검사량까지)가 이미 저장돼 있는지(읽기 전용)."""
        return self.c.rpc("m13_journal_exists", {"p": payload}) or {"exists": False}

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

    def position_entries(self, model: str | None = None) -> list[dict]:
        """뷰 m13_position_entries: 초품 위치도 1회 = 1행(판정 집계·CA 연결·입력 시각)."""
        params: dict[str, Any] = {"order": "check_date.desc,model_code.asc"}
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_position_entries", params, limit=2000)

    def position_void(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_position_void", {"p": payload})

    # ---------------------------------------------------------------- 판독 실행 기록(결과보고서 비교표)
    def ai_call_log(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_ai_call_log", {"p": payload})

    def ai_calls(self, limit: int = 2000) -> list[dict]:
        return self.c.select("m13_ai_calls", {"order": "started_at.desc"}, limit=limit)

    # ---------------------------------------------------------------- 사출 보빈 초품 위치도
    def bobbin_position_checks(self, model: str | None = None, date_from: str | None = None, date_to: str | None = None) -> list[dict]:
        """뷰 m13_bobbin_position_checks: 캐비티·좌우별 X/Y, 위치도·판정(DB 기준 BOBBIN-POSITION-A1-3), BB LOT."""
        params: dict[str, Any] = {"order": "check_date.asc,variant.asc,side.asc,sample_no.asc"}
        if model:
            params["variant"] = f"eq.{model}"
        _date_filter(params, "check_date", date_from, date_to)
        return self.c.select("m13_bobbin_position_checks", params, limit=20000)

    # ---------------------------------------------------------------- 권선 비전 재검사(가성불량 조치 엑셀) 2026-11-07
    def vision_check_entries(self) -> list[dict]:
        return self.c.select("m13_vision_check_entries", {"order": "recorded_at.desc"}, limit=5000)

    def vision_check_save(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_vision_check_save", {"p": payload})

    def vision_check_void(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_vision_check_void", {"p": payload})

    def bobbin_position_entries(self, model: str | None = None) -> list[dict]:
        params: dict[str, Any] = {"order": "recorded_at.desc"}
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_bobbin_position_entries", params, limit=2000)

    def bobbin_position_save(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_bobbin_position_save", {"p": payload})

    def bobbin_position_void(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_bobbin_position_void", {"p": payload})

    # ---------------------------------------------------------------- 사출조건 체크시트 (관리 화면 업로드)
    def injection_sheets(self, model: str | None = None) -> list[dict]:
        """뷰 m13_injection_sheets: 저장된 체크시트 탭(= 보빈 LOT) 1장 = 1행, 실측 수·실행 FK 연결 수."""
        params: dict[str, Any] = {"order": "model_code.asc,tab.asc"}
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_injection_sheets", params, limit=2000)

    def injection_sheet_save(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_injection_sheet_save", {"p": payload})

    def injection_sheet_void(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_injection_sheet_void", {"p": payload})

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


    # ---------------------------------------------------------------- 사람 판단 기록 (확인 필요 목록 · 판단 이력 · 저장 RPC)
    def review_queue(self, model: str | None = None, stage: str | None = None, lot: str | None = None) -> list[dict]:
        """뷰 m13_review_queue: 판독값 확인 필요 · 검사 LOT 미해결 · 생산 이벤트 확인 · 초품 위치도 경계/불량."""
        params: dict[str, Any] = {"order": "stage_code.asc,item_date.asc.nullslast,item_id.asc"}
        if model:
            params["model_code"] = f"eq.{model}"
        if stage:
            params["stage_code"] = f"eq.{stage}"
        if lot:
            params["lot_code"] = f"ilike.*{lot}*"
        return self.c.select("m13_review_queue", params, limit=2000)

    def judgment_log(self, lot: str | None = None, kind: str | None = None, model: str | None = None, limit: int = 200) -> list[dict]:
        """뷰 m13_judgment_log: 팀 감사 테이블에서 뽑은 판단 1건 = 1행(최근 순)."""
        params: dict[str, Any] = {"order": "audit_id.desc",
                                  "select": "audit_id,changed_at,actor_ref,kind,decision,decision_label,stage_label,model_code,lot_code,item_date,title,value,basis,note,images,ai_decision,ai_agreed"}
        if lot:
            params["lot_code"] = f"ilike.*{lot}*"
        if kind:
            params["kind"] = f"eq.{kind}"
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_judgment_log", params, limit=limit)

    def judgment_save(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_judgment_save", {"p": payload})


    # ---------------------------------------------------------------- 최종검사 재검사 (비고란 재검 · inspection_run REINSPECTION)
    def reinspection_targets(self, model: str) -> list[dict]:
        """뷰 m13_reinspection_targets: 최종검사(FINAL)를 받은 CA 제품 LOT 과 그 본검사(재검 대상 후보)."""
        return self.c.select("m13_reinspection_targets", {"model_code": f"eq.{model}", "order": "lot_date.desc,inspection_date.asc"}, limit=5000)

    def reinspections(self, model: str | None = None, limit: int = 300) -> list[dict]:
        params: dict[str, Any] = {"order": "inspection_date.desc,recorded_at.desc"}
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_reinspections", params, limit=limit)

    def final_defect_types(self) -> list[dict]:
        return self.c.select("defect_type", {"defect_category": "eq.FIN", "record_state": "eq.ACTIVE", "is_active": "eq.true",
                                             "select": "defect_code,defect_name", "order": "defect_name.asc"}, schema=settings.schema, limit=1000)

    def reinspection_save(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_reinspection_save", {"p": payload})

    def journal_entries(self, process: str | None, model: str | None) -> list[dict]:
        """저장된 작업일보(공정 실행) 목록 — 관리 화면 작업일보 탭 아래 목록(2026-11-07)."""
        params: dict[str, Any] = {"order": "recorded_at.desc"}
        if process:
            params["process_code"] = f"in.({process})"
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_journal_entries", params, limit=3000)

    def final_entries(self, model: str | None) -> list[dict]:
        params: dict[str, Any] = {"order": "recorded_at.desc"}
        if model:
            params["model_code"] = f"eq.{model}"
        return self.c.select("m13_final_entries", params, limit=3000)

    def final_void(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_final_void", {"p": payload})

    def journal_void(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_journal_void", {"p": payload})

    def reinspection_void(self, payload: dict[str, Any]) -> dict:
        self._guard()
        payload.setdefault("actor", settings.actor)
        return self.c.rpc("m13_reinspection_void", {"p": payload})


_repo: Repository | None = None


def get_repository() -> Repository:
    global _repo
    if _repo is None:
        _repo = SupabaseRepository()
    return _repo
