"""OCR 판독 정답률 계산 (팀 기준서 정답률_기준.md v1.0 그대로).

정답지 칸(gt_cells.py) 과 DB 칸(public.m13_accuracy_cells, 개인 Supabase) 을 같은 키로 맞춰 판정한다.
  정답률 = 일치 ÷ (일치 + 불일치 + 누락 + 헛판독)      ← 빈칸 일치·비교 불가 제외
판정
  MATCH 일치 / MISMATCH 불일치 / MISSING 누락(정답 있음·DB 없음) / SPURIOUS 헛판독(정답 없음·DB 있음)
  NO_JOURNAL 비교 범위 밖: 그 (날짜·모델·공정·교대) 일보가 DB 에 아예 없음(판독본 미수록)
  EXCLUDED  정답지 전사본으로 적재된 값(vs=EXCEL_TRANSCRIBED) — 정답지와 같은 값이라 뺀다
결과
  outputs/accuracy/cells_<날짜>.csv  (칸 단위 전부)
  docs/정답률/결과_<날짜>.md          (헤드라인 + 항목·공정·모델별 + 작업일보별 드릴다운)

  py tools/accuracy/evaluate.py [--env personal]
"""
from __future__ import annotations

import csv
import sys
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "backend"))
from accuracy.gt_cells import Cell, canon_defect, date_set, load_all  # noqa: E402

PROC_KO = {"IMEB3_INJECTION": "사출", "IMEB3_STITCHING": "스티칭", "IMEB3_WINDING": "권선(BA)", "IMEB3_CA_PRESS": "압입(CA)", "IMEB3_FINAL_INSPECTION": "최종검사"}
ITEM_KO = {"production_qty": "생산수량", "work_hours": "작업시간", "defect": "불량수량(유형별)", "material": "자재 LOT 날짜",
           "inspected_qty": "검사수량", "inspection_defect_total": "검사 불량수량"}
CORE = ("production_qty", "defect")   # 팀 기준서 7: 핵심 지표 = 생산수량·불량수량 (최종검사는 별도 참고표)


def fetch_db(env: str) -> list[dict]:
    import os
    os.environ["M13_ENV"] = env
    from app.db.supabase_client import get_client
    c = get_client()
    rows, page, off = [], 1000, 0   # PostgREST 는 한 번에 최대 1000행(프로젝트 기본) → 페이지로 나눠 받는다
    while True:
        chunk = c.select("m13_accuracy_cells", {"select": "*", "order": "item,work_date,ref_id", "offset": str(off)}, limit=page)
        rows += chunk
        if len(chunk) < page:
            break
        off += page
    return rows


def db_index(rows: list[dict]):
    """DB 칸 → {키: [값...]}. 검사 불량은 검사자별 합계로."""
    idx: dict[tuple, list] = defaultdict(list)
    journals: set[tuple] = set()
    insp_def: Counter = Counter()
    for r in rows:
        shift = (r.get("shift") or "")[:1] if r["process_code"] != "IMEB3_FINAL_INSPECTION" else ""
        jkey = (r["work_date"], r["model_code"], r["process_code"], shift)
        journals.add(jkey)
        item, sub = r["item"], r.get("sub") or ""
        if item == "defect":
            sub = canon_defect(sub, r["process_code"])
            if not sub:
                continue
        if item == "material_link":
            # 상위 LOT 연결로 들어간 부품 날짜(인서트→스티칭 LOT, 스티칭 보빈→사출 LOT)를 자재 칸으로 되돌린다
            field = sub.split("=")[0].split("~")[0].lower()
            if "insert" in field:
                code = "IMEB3_LEAD_PIN_INSERT"
            elif "bobbin" in field and r["process_code"] == "IMEB3_STITCHING":
                code = "IMEB3_BOBBIN"
            else:
                continue
            idx[jkey + ("material", code)].append({"value": frozenset([r["value_text"]]), "raw": r["value_text"], "vs": r.get("vs"), "ref": r.get("ref_id")})
            continue
        if item == "inspection_defect":
            who = sub.split("|")[0]
            insp_def[(jkey, who, r.get("vs"))] += float(r["value_num"] or 0)
            continue
        val = r["value_num"]
        if item == "material":
            val = date_set(r.get("value_text"))
        elif val is not None:
            val = float(val)
        idx[jkey + (item, sub)].append({"value": val, "raw": r.get("value_text"), "vs": r.get("vs"), "ref": r.get("ref_id")})
    for (jkey, who, vs), total in insp_def.items():
        idx[jkey + ("inspection_defect_total", who)].append({"value": total, "raw": str(total), "vs": vs, "ref": None})
    # 자재: 같은 칸의 날짜를 한 집합으로 (와이어는 축별로 여러 행)
    for key, vals in idx.items():
        if key[4] == "material" and len(vals) > 1:
            merged = frozenset().union(*[v["value"] for v in vals if isinstance(v["value"], frozenset)])
            vs = "EXCEL_TRANSCRIBED" if all(v["vs"] == "EXCEL_TRANSCRIBED" for v in vals) else next((v["vs"] for v in vals if v["vs"] != "EXCEL_TRANSCRIBED"), None)
            idx[key] = [{"value": merged, "raw": "/".join(sorted(merged)), "vs": vs, "ref": None}]
    return idx, journals


def judge(gt: Cell, db: list[dict]) -> tuple[str, str]:
    if not db:
        return "MISSING", ""
    # 같은 칸에 DB 값이 여러 개면(라인 중복 등) 하나라도 맞으면 일치
    for d in db:
        if d["vs"] == "EXCEL_TRANSCRIBED":
            return "EXCLUDED", str(d["raw"])
    for d in db:
        v = d["value"]
        if isinstance(gt.value, frozenset):
            if isinstance(v, frozenset) and v == gt.value:
                return "MATCH", "/".join(sorted(v))
        elif v is not None and abs(float(v) - float(gt.value)) < 1e-6:
            return "MATCH", str(v)
    d = db[0]
    return "MISMATCH", ("/".join(sorted(d["value"])) if isinstance(d["value"], frozenset) else str(d["value"]))


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    env = sys.argv[sys.argv.index("--env") + 1] if "--env" in sys.argv else "personal"
    gt = load_all()
    rows = fetch_db(env)
    idx, journals = db_index(rows)
    today = date.today().strftime("%Y%m%d")
    out_csv = ROOT / "outputs" / "accuracy" / f"cells_{today}.csv"
    out_md = ROOT / "docs" / "정답률" / f"결과_{today}.md"
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)

    records = []
    used: set[tuple] = set()
    for c in gt:
        jkey = (c.work_date, c.model, c.process, c.shift)
        key = jkey + (c.item, c.sub)
        if jkey not in journals:
            verdict, dbv = "NO_JOURNAL", ""
        else:
            verdict, dbv = judge(c, idx.get(key, []))
        used.add(key)
        records.append({**c.__dict__, "value": "/".join(sorted(c.value)) if isinstance(c.value, frozenset) else c.value, "db_value": dbv, "verdict": verdict})
    # 헛판독: 정답지 일보는 있는데 정답지에 없는 칸을 DB 가 가진 경우 (불량 유형·자재만 대상. 생산량은 정답지에 늘 있음)
    gt_journals = {(c.work_date, c.model, c.process, c.shift) for c in gt}
    for key, vals in idx.items():
        jkey, item, sub = key[:4], key[4], key[5]
        if key in used or jkey not in gt_journals or item not in ("defect", "material", "inspection_defect_total"):
            continue
        # 헛판독은 정답지에 그 항목 칸이 하나라도 있는 일보에서만 센다(정답지가 그 항목을 아예 안 적는 경우는 비교 불가)
        if not any(c.item == item and (c.work_date, c.model, c.process, c.shift) == jkey for c in gt):
            continue
        if all(v["vs"] == "EXCEL_TRANSCRIBED" for v in vals):
            continue
        if item == "inspected_qty" and sub == "":
            continue  # 검사자 미기재 실행
        v = vals[0]["value"]
        records.append({"item": item, "work_date": jkey[0], "model": jkey[1], "process": jkey[2], "shift": jkey[3], "sub": sub,
                        "value": "", "raw": "", "source": "", "db_value": "/".join(sorted(v)) if isinstance(v, frozenset) else v, "verdict": "SPURIOUS"})

    with open(out_csv, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["verdict", "item", "work_date", "model", "process", "shift", "sub", "value", "db_value", "raw", "source"])
        w.writeheader()
        for r in records:
            w.writerow({k: r.get(k, "") for k in w.fieldnames})

    # ---- 집계
    def rate(rs):
        c = Counter(r["verdict"] for r in rs)
        den = c["MATCH"] + c["MISMATCH"] + c["MISSING"] + c["SPURIOUS"]
        return (c["MATCH"] / den * 100 if den else None), c, den

    def line(label, rs):
        p, c, den = rate(rs)
        return f"| {label} | {('%.1f%%' % p) if p is not None else '—'} | {den} | {c['MATCH']} | {c['MISMATCH']} | {c['MISSING']} | {c['SPURIOUS']} | {c['NO_JOURNAL']} | {c['EXCLUDED']} |"

    hdr = "| 구분 | 정답률 | 비교 칸 | 일치 | 불일치 | 누락 | 헛판독 | 판독본 없음 | 전사본 제외 |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|"
    core = [r for r in records if r["item"] in CORE]
    prod = [r for r in records if r["process"] != "IMEB3_FINAL_INSPECTION"]
    insp = [r for r in records if r["process"] == "IMEB3_FINAL_INSPECTION"]
    md = [f"# OCR 판독 정답률 — DB(개인 Supabase) vs 정답지 ({date.today().isoformat()})", "",
          "기준: 팀 `정답률_기준.md` v1.0. 정답률 = 일치 ÷ (일치+불일치+누락+헛판독). 빈칸·전사본 적재값·판독본 없는 일보는 분모에서 제외.",
          f"정답지: {', '.join(sorted({r['source'] for r in records if r['source']}))}", "",
          "## 헤드라인 (사출·스티칭·권선·압입)", "", hdr, line("**핵심 지표(생산수량·불량수량)**", core), line("생산 공정 전체(자재 LOT 날짜·작업시간 포함)", prod), "",
          "## 항목 종류별", "", hdr] + [line(ITEM_KO.get(i, i), [r for r in records if r["item"] == i]) for i in ITEM_KO if i not in ("inspected_qty", "inspection_defect_total")] + ["",
          "## 공정별 (핵심 지표)", "", hdr] + [line(PROC_KO[p], [r for r in core if r["process"] == p]) for p in PROC_KO if p != "IMEB3_FINAL_INSPECTION"] + ["",
          "## 최종검사 (참고: 검사자별 불량수량 합계, 정답지 정형데이터 기준)", "",
          "정답지에 검사수량 칸이 비어 있어 검사수량은 비교 불가. 검사자 표시명이 다르게 가려진 경우(예: 이름 오타)도 불일치로 잡히므로 확인 전 수치.", "",
          hdr, line("검사 불량수량(검사자별 합계)", [r for r in insp if r["item"] == "inspection_defect_total"]), "",
          "## 모델별 (핵심 지표)", "", hdr] + [line(m, [r for r in core if r["model"] == m]) for m in ("IV", "OV", "HSV")] + ["",
          "## 월별 (핵심 지표)", "", hdr] + [line(m, [r for r in core if r["work_date"].startswith(m)]) for m in ("2026-08", "2026-09")] + ["",
          "## 작업일보별 (핵심 지표, 비교 칸 있는 것만, 정답률 낮은 순 상위 30)", "",
          "| 날짜 | 모델 | 공정 | 교대 | 정답률 | 비교 칸 | 틀린 칸(항목: DB값 / 정답) |", "|---|---|---|---|---:|---:|---|"]
    byj = defaultdict(list)
    for r in core:
        byj[(r["work_date"], r["model"], r["process"], r["shift"])].append(r)
    jrows = []
    for k, rs in byj.items():
        p, c, den = rate(rs)
        if p is None:
            continue
        wrong = [f"{ITEM_KO.get(r['item'], r['item'])}{('·' + r['sub']) if r['sub'] else ''}: {r['db_value'] or '빈칸'} / {r['value'] or '빈칸'}" for r in rs if r["verdict"] in ("MISMATCH", "MISSING", "SPURIOUS")]
        jrows.append((p, den, k, wrong))
    for p, den, k, wrong in sorted(jrows, key=lambda x: (x[0], -x[1]))[:30]:
        md.append(f"| {k[0]} | {k[1]} | {PROC_KO.get(k[2], k[2])} | {k[3] or '-'} | {p:.0f}% | {den} | {'; '.join(wrong)[:160]} |")
    nj = Counter(r["verdict"] for r in records)
    md += ["", "## 비교 범위", "", f"- 정답지 칸 {len(gt)}개 중 DB 에 같은 일보가 있는 칸 {len(gt) - nj['NO_JOURNAL']}개, 일보 자체가 DB 에 없는 칸 {nj['NO_JOURNAL']}개(판독본 미수록·보류).",
           f"- 전사본으로 적재돼 제외한 칸 {nj['EXCLUDED']}개. 헛판독 후보 {nj['SPURIOUS']}개.",
           f"- 칸 단위 전체 목록: `{out_csv.relative_to(ROOT)}`"]
    out_md.write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md[:12]))
    print("...", out_md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
