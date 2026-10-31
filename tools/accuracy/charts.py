"""과제보고서용 정답률 그래프(PNG). 집계 수치만 담고 개인정보·원문 수량은 넣지 않는다.
입력: outputs/accuracy/cells_*.csv(확인 전), cells_confirmed_*.csv(확인 후), review_results_*.csv
출력: docs/img/정답률_1_공정항목.png, docs/img/정답률_2_오류분석.png
"""
from __future__ import annotations
import csv, re, sys
from collections import Counter
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "img"
BLUE, ORANGE, SURF, INK, INK2, GRID = "#2a78d6", "#eb6834", "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
plt.rcParams.update({"font.family": "Malgun Gothic", "axes.unicode_minus": False, "figure.facecolor": SURF, "axes.facecolor": SURF,
                     "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK, "font.size": 10})
CORE = ("production_qty", "defect")
PROC = {"IMEB3_STITCHING": "스티칭", "IMEB3_WINDING": "권선(BA)", "IMEB3_INJECTION": "사출", "IMEB3_CA_PRESS": "압입(CA)"}
ITEM = {"production_qty": "생산수량", "defect": "불량 유형별 수량", "material": "자재 LOT 날짜", "work_hours": "작업시간"}


def rate(rs):
    c = Counter(r["verdict"] for r in rs)
    den = c["MATCH"] + c["MISMATCH"] + c["MISSING"] + c["SPURIOUS"]
    return (c["MATCH"] / den * 100 if den else 0), den


def style(ax, xmax=100):
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.xaxis.grid(True, color=GRID, linewidth=1); ax.set_axisbelow(True)
    ax.tick_params(length=0); ax.set_xlim(0, xmax); ax.invert_yaxis()


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    load = lambda pat: list(csv.DictReader(open(sorted((ROOT / "outputs" / "accuracy").glob(pat))[-1], encoding="utf-8-sig")))
    before = [r for r in load("cells_2*.csv") if r["process"] in PROC and r["item"] in CORE]
    after_all = [r for r in load("cells_confirmed_*.csv") if r["process"] in PROC]
    after = [r for r in after_all if r["item"] in CORE]
    review = load("review_results_*.csv")

    # ---- 그림 1: 공정별(확인 전/후) + 항목별(확인 후)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4.2), gridspec_kw={"width_ratios": [1.15, 1]})
    groups = [("전체", lambda r: True)] + [(ko, (lambda r, p=p: r["process"] == p)) for p, ko in PROC.items()]
    labels, pb, pa, dens = [], [], [], []
    for ko, fn in groups:
        b, _ = rate([r for r in before if fn(r)]); a, d = rate([r for r in after if fn(r)])
        labels.append(ko); pb.append(b); pa.append(a); dens.append(d)
    y = range(len(labels)); h = 0.34
    a1.barh([i - h / 2 - 0.02 for i in y], pb, height=h, color=ORANGE, label="확인 전(정답지 그대로)")
    a1.barh([i + h / 2 + 0.02 for i in y], pa, height=h, color=BLUE, label="확인 후(원본 대조 반영)")
    for i in y:
        a1.text(pb[i] + 1, i - h / 2 - 0.02, f"{pb[i]:.1f}%", va="center", fontsize=9, color=INK2)
        a1.text(pa[i] + 1, i + h / 2 + 0.02, f"{pa[i]:.1f}%", va="center", fontsize=9, color=INK, fontweight="bold")
    a1.set_yticks(list(y)); a1.set_yticklabels([f"{l}  ({d}칸)" for l, d in zip(labels, dens)])
    a1.set_title("핵심 지표 정답률 — 공정별 (생산수량·불량수량)", loc="left", fontsize=11, color=INK, pad=10)
    a1.set_xlabel("정답률 (%)"); style(a1, 108)
    a1.legend(loc="upper left", bbox_to_anchor=(0, -0.14), ncol=2, frameon=False, fontsize=9)
    a1.axhline(0.5, color=GRID, linewidth=1)

    items, vals, dens2 = [], [], []
    for it, ko in ITEM.items():
        p, d = rate([r for r in after_all if r["item"] == it]); items.append(ko); vals.append(p); dens2.append(d)
    a2.barh(range(len(items)), vals, height=0.5, color=BLUE)
    for i, v in enumerate(vals):
        a2.text(v + 1, i, f"{v:.1f}%", va="center", fontsize=9, color=INK, fontweight="bold")
    a2.set_yticks(range(len(items))); a2.set_yticklabels([f"{l}  ({d}칸)" for l, d in zip(items, dens2)])
    a2.set_title("항목별 정답률 — 확인 후", loc="left", fontsize=11, color=INK, pad=10)
    a2.set_xlabel("정답률 (%)"); style(a2, 108)
    fig.text(0.01, 0.01, "정답률 = 일치 ÷ (일치+불일치+누락+헛판독). 전사본 적재값·빈칸·판독본 없는 일보 제외. 개인 Supabase 적재값 vs 정답지 엑셀(8·9월), 2026-10-31",
             fontsize=8, color=INK2)
    fig.tight_layout(rect=(0, 0.06, 1, 1)); fig.savefig(OUT / "정답률_1_공정항목.png", dpi=160); plt.close(fig)

    # ---- 그림 2: 틀린 칸 분류 + 판독 오류 유형
    fig, (b1, b2) = plt.subplots(1, 2, figsize=(11, 3.9), gridspec_kw={"width_ratios": [1, 1.1]})
    cls = Counter(r["verdict"] for r in review)
    order = ["판독 오류", "정답지 오류", "판단 불가", "항목명 표준화"]
    desc = {"판독 오류": "AI 판독값이 틀림", "정답지 오류": "원본과 정답지가 다름 → 원본 기준 재판정", "판단 불가": "글씨 애매·빈칸을 0 으로 적재 → 제외", "항목명 표준화": "불량명 표기 차이 → 표준화 후 일치"}
    v1 = [cls[k] for k in order]
    b1.barh(range(4), v1, height=0.5, color=BLUE)
    for i, v in enumerate(v1):
        b1.text(v + 3, i, f"{v}칸  ·  {desc[order[i]]}", va="center", fontsize=8.5, color=INK2)
    b1.set_yticks(range(4)); b1.set_yticklabels(order)
    b1.set_title(f"틀린 칸 {sum(v1)}개를 원본 PDF 와 대조한 결과", loc="left", fontsize=11, color=INK, pad=10)
    b1.set_xlabel("칸 수"); style(b1, max(v1) * 1.9)

    kinds = Counter()
    for r in review:
        if r["verdict"] != "판독 오류":
            continue
        n = r["note"]
        kinds["값 없음·판독 누락" if ("누락" in n or "값 없음" in n) else "행 밀림(옆 칸 값)" if "밀림" in n else "헛판독(없는 값)" if "헛판독" in n
              else "자릿수(0 추가·앞자리 누락)" if ("0 " in n or "자릿수" in n or "앞자리" in n) else "숫자 오독(8↔6, 7↔1 등)"] += 1
    ks = [k for k, _ in kinds.most_common()]; v2 = [kinds[k] for k in ks]
    b2.barh(range(len(ks)), v2, height=0.5, color=BLUE)
    for i, v in enumerate(v2):
        b2.text(v + 1.5, i, f"{v}칸 ({v / sum(v2) * 100:.0f}%)", va="center", fontsize=9, color=INK)
    b2.set_yticks(range(len(ks))); b2.set_yticklabels(ks)
    b2.set_title(f"판독 오류 {sum(v2)}칸의 유형", loc="left", fontsize=11, color=INK, pad=10)
    b2.set_xlabel("칸 수"); style(b2, max(v2) * 1.35)
    fig.tight_layout(); fig.savefig(OUT / "정답률_2_오류분석.png", dpi=160); plt.close(fig)
    print("saved", [p.name for p in OUT.glob("정답률_*.png")])


if __name__ == "__main__":
    main()
