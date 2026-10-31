"""원본 PDF 대조 결과를 반영한 '확인 후' 정답률.

입력
- outputs/accuracy/cells_<날짜>.csv : evaluate.py 의 칸 단위 판정(확인 전)
- outputs/accuracy/review_results_<날짜>.csv : 틀린 칸을 원본 PDF 와 대조한 결과
  verdict = 판독 오류 | 정답지 오류 | 판단 불가 | 항목명 표준화, original = 원본에 적힌 값

규칙(팀 정답률_기준.md v1.0 의 '확인 후')
- 정답지 오류: 원본값을 정답으로 본다. DB 값 == 원본값이면 일치. 원본이 빈칸이면(정답지가 없는 값을 적음) 비교 제외.
- 판단 불가: 분모에서 제외.
- 판독 오류 / 항목명 표준화: 판정 그대로(표준화는 evaluate.py 재실행으로 이미 일치 처리됨).
"""
from __future__ import annotations

import csv
import re
import sys
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ("production_qty", "defect")
ITEM_KO = {"production_qty": "생산수량", "work_hours": "작업시간", "defect": "불량 유형별 수량", "material": "자재 LOT 날짜"}
PROC_KO = {"IMEB3_INJECTION": "사출", "IMEB3_STITCHING": "스티칭", "IMEB3_WINDING": "권선(BA)", "IMEB3_CA_PRESS": "압입(CA)"}
NUM = re.compile(r"-?\d[\d,]*(?:\.\d+)?")


def key(r):
    return (r["work_date"], r["model"], r["process"], r["shift"], r["item"], r["sub"] or "")


def num(s):
    m = NUM.search(str(s or "").replace(" ", ""))
    return float(m.group(0).replace(",", "")) if m else None


def rate(rs):
    c = Counter(r["verdict"] for r in rs)
    den = c["MATCH"] + c["MISMATCH"] + c["MISSING"] + c["SPURIOUS"]
    return (c["MATCH"] / den * 100 if den else None), c, den


def line(label, before, after):
    pb, cb, db = rate(before)
    pa, ca, da = rate(after)
    f = lambda p: ("%.1f%%" % p) if p is not None else "—"
    return f"| {label} | {f(pb)} | {db} | {f(pa)} | {da} | {ca['MATCH']} | {ca['MISMATCH']} | {ca['MISSING']} | {ca['SPURIOUS']} | {ca['EXCLUDED_REVIEW']} |"


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    cells_csv = sorted((ROOT / "outputs" / "accuracy").glob("cells_*.csv"))[-1]
    review_csv = sorted((ROOT / "outputs" / "accuracy").glob("review_results_*.csv"))[-1]
    cells = list(csv.DictReader(open(cells_csv, encoding="utf-8-sig")))
    review = {key(r): r for r in csv.DictReader(open(review_csv, encoding="utf-8-sig"))}

    before = [dict(r) for r in cells if r["process"] in PROC_KO]
    after, applied = [], Counter()
    notes = defaultdict(list)
    for r in before:
        a = dict(r)
        rv = review.get(key(r))
        if rv and r["verdict"] in ("MISMATCH", "MISSING", "SPURIOUS"):
            v = rv["verdict"]
            if v == "판단 불가":
                a["verdict"] = "EXCLUDED_REVIEW"
                notes[v].append((r, rv))
            elif v == "정답지 오류":
                o = num(rv["original"])
                d = num(r["db_value"])
                if o is None:
                    a["verdict"] = "EXCLUDED_REVIEW"       # 정답지가 원본에 없는 값을 적음
                elif d is not None and abs(o - d) < 1e-6:
                    a["verdict"], a["value"] = "MATCH", rv["original"]
                else:
                    a["value"] = rv["original"]           # 정답을 원본값으로 바꿔도 DB 는 틀림
                notes[v].append((r, rv))
            applied[v] += 1
        after.append(a)

    today = date.today().strftime("%Y%m%d")
    out_csv = ROOT / "outputs" / "accuracy" / f"cells_confirmed_{today}.csv"
    with open(out_csv, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(after[0].keys()))
        w.writeheader(); w.writerows(after)

    hdr = ("| 구분 | 확인 전 | 비교 칸 | **확인 후** | 비교 칸 | 일치 | 불일치 | 누락 | 헛판독 | 대조로 제외 |\n"
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    sel = lambda rs, fn: [r for r in rs if fn(r)]
    core_b, core_a = sel(before, lambda r: r["item"] in CORE), sel(after, lambda r: r["item"] in CORE)
    rc = Counter(rv["verdict"] for rv in review.values())
    md = [f"# OCR 판독 정답률 — 원본 대조 반영(확인 후) ({date.today().isoformat()})", "",
          f"확인 전 판정: `{cells_csv.relative_to(ROOT)}` / 원본 대조: `{review_csv.relative_to(ROOT)}` ({len(review)}칸).",
          "틀린 칸(불일치·누락·헛판독)을 원본 PDF 와 하나씩 대조해 분류했다: "
          + ", ".join(f"{k} {v}" for k, v in rc.most_common()) + ".", "",
          "- **판독 오류**: 정답지가 맞고 DB(AI 판독값)가 틀림 → 그대로 오답.",
          "- **정답지 오류**: 원본과 정답지가 다름 → 원본값을 정답으로 다시 판정(DB 가 원본과 같으면 일치).",
          "- **판단 불가**: 원본 글씨가 애매하거나 빈칸을 0 으로 적재한 경우 등 → 분모에서 제외.",
          "- **항목명 표준화**: 판독본이 스티칭 '전장' 칸을 terminal 로 적은 것 → 불량명 표준화 후 재평가(일치).", "",
          "## 헤드라인 (사출·스티칭·권선·압입)", "", hdr,
          line("**핵심 지표(생산수량·불량수량)**", core_b, core_a),
          line("생산 공정 전체(자재 LOT 날짜·작업시간 포함)", before, after), "",
          "## 항목 종류별", "", hdr]
    md += [line(ko, sel(before, lambda r, i=i: r["item"] == i), sel(after, lambda r, i=i: r["item"] == i)) for i, ko in ITEM_KO.items()]
    md += ["", "## 공정별 (핵심 지표)", "", hdr]
    md += [line(ko, sel(core_b, lambda r, p=p: r["process"] == p), sel(core_a, lambda r, p=p: r["process"] == p)) for p, ko in PROC_KO.items()]
    md += ["", "## 모델별 (핵심 지표)", "", hdr]
    md += [line(m, sel(core_b, lambda r, m=m: r["model"] == m), sel(core_a, lambda r, m=m: r["model"] == m)) for m in ("IV", "OV", "HSV")]
    md += ["", "## 월별 (핵심 지표)", "", hdr]
    md += [line(m, sel(core_b, lambda r, m=m: r["work_date"].startswith(m)), sel(core_a, lambda r, m=m: r["work_date"].startswith(m))) for m in ("2026-08", "2026-09")]

    # 판독 오류 유형 분포 (note 앞 어절 기준)
    kinds = Counter()
    for rv in review.values():
        if rv["verdict"] == "판독 오류":
            n = rv["note"]
            kinds["값 없음/누락" if ("누락" in n or "값 없음" in n) else "행 밀림" if "밀림" in n else "헛판독" if "헛판독" in n else "자릿수(0 추가·누락)" if ("0 " in n or "자릿수" in n or "앞자리" in n) else "숫자 오독"] += 1
    md += ["", "## 판독 오류 유형 (원본 대조 기준)", "", "| 유형 | 칸 수 |", "|---|---:|"] + [f"| {k} | {v} |" for k, v in kinds.most_common()]

    md += ["", "## 정답지 오류·판단 불가 목록", "", "| 구분 | 날짜 | 모델 | 공정 | 항목 | 정답지 | DB | 원본 | 비고 |", "|---|---|---|---|---|---|---|---|---|"]
    for v in ("정답지 오류", "판단 불가"):
        for r, rv in notes[v]:
            md.append(f"| {v} | {r['work_date']} | {r['model']} | {PROC_KO[r['process']]} | {ITEM_KO.get(r['item'], r['item'])}{('·' + r['sub']) if r['sub'] else ''} | {rv['gt']} | {rv['db'] or '빈칸'} | {rv['original']} | {rv['note']} |")
    md += ["", f"- 칸 단위 목록(확인 후): `{out_csv.relative_to(ROOT)}`"]
    out_md = ROOT / "docs" / "정답률" / f"결과_확인후_{today}.md"
    out_md.write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md[:16])); print("...", out_md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
