"""사출조건 체크시트(사출조건표.xlsx) → mqi 작업조건 테이블 delta SQL.

원본: D:\\코디세이\\M1-2\\firestore_import\\사출조건표.xlsx  (M1-2 feature/crud-import-review 에서 쓰던 파일)
- 날짜 탭(예: 20260923D1)만 읽는다. 탭 9장 모두 같은 양식(IV BOBBIN, 품번 1-23111356-2, Cavity 16).
- M1-2 의 범용 판독기 대신 칸 위치 고정표(LAYOUT)로 읽는다. 탭마다 라벨 칸이 기준 탭과 같은지 먼저 검사하고,
  다르면 멈춘다(양식이 바뀐 탭을 잘못 읽지 않기 위해).
- 팀 테이블 그대로 사용:
    equipment               동신 사출기 1건 (체크시트에 호기 공란 → 호기 미기재로 둔다)
    parameter_definition    조건 항목
    process_setup_spec(_item)  기준값·허용폭 (IV / 사출, 기준문서 번호 = spec_revision)
    parameter_observation   주간·야간 실측값 (원본 셀 위치·작업일자·주야는 remark JSON)
- process_run_id 는 비워 둔다. 팀 트리거(validate_semantics)가 '설비 사용 기록(process_equipment_usage)이 있을 때만
  연결'을 요구하는데, 체크시트에 호기가 공란이라 사용 기록을 만들면 추정이 된다.
  참고용으로 같은 날짜·주야 꼬리표(DAY/NIGHT, D/N, D1/N1) IV 사출 기록이 정확히 1건이면 remark.same_shift_run_id 에만 적는다.
- 보빈무게: 체크시트 '기준' 줄 AA36 에 적힌 값은 날마다 다른 실측값이라 주간 실측으로, AA38 '야간 보빈무게: x g' 는
  야간 실측으로 넣는다(원문은 raw_value_text).

  py tools/injection_conditions_to_mqi.py [엑셀경로] --runs runs.json
  runs.json = [{"process_run_id":..., "work_date":"2026-08-11", "fs":"SRC-...-D1-..."}] (IV 사출 process_run 목록)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import uuid
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_XLSX = ROOT.parent / "M1-2" / "firestore_import" / "사출조건표.xlsx"
OUT_DIR = ROOT / "outputs"
NS = uuid.uuid5(uuid.NAMESPACE_URL, "m13:injection-conditions:v1")
DS = "INJ_COND_XLSX_V1"
REF_TAB = "20260923D1"

INJECTION_PROCESS_ID = "41292f90-847b-56b1-b067-c2d98063d312"
IV_MODEL_ID = "2301ac32-5b2b-5bc4-aded-c4fde4a8a60e"

# 라벨 칸(양식 확인용)
LABELS = {
    "D8": "현재온도", "I6": "Nz", "M6": "H1", "Q6": "H2", "U6": "H3", "Y6": "H4", "AC6": "작동유",
    "C13": "쿠션mm", "I13": "보압1", "N13": "사출4", "R13": "사출3", "V13": "사출2", "Z13": "사출1",
    "AD15": "속도 %", "AD18": "압력 kgf", "AD21": "시간 sec", "AD24": "위치 mm",
    "C28": "냉각시간", "K28": "계량지연", "O28": "계량감시", "Y28": "현사출위치",
    "F34": "석백1", "J34": "계량1", "N34": "계량2", "R34": "계량3", "V34": "석백2", "AA34": "보빈무게",
    "A36": "속도 %", "A39": "압력 kgf", "A42": "위치 mm", "A45": "배압 kgf",
    "C49": "사출 sec", "G49": "계량 sec", "K49": "메인압력", "O49": "전환압력", "S49": "전환위치",
    "W49": "전환속도", "AA49": "생산공정\n시간",
    "C56": "금형 고정\n(계기판)", "G56": "금형 이동\n(계기판)", "K56": "표면 고정\n(비접촉)",
    "O56": "표면 이동\n(비접촉)", "S56": "온조기\n온도", "W56": "호퍼건조\n(눈금)",
}

# (code, name, unit, group, 기준칸|None, 허용폭칸|None, 주간칸, 야간칸)
P = []


def grid(prefix, name_prefix, unit, group, ref_row, cols):
    for code, label, col, tol in cols:
        P.append((f"{prefix}_{code}", f"{name_prefix} {label}".strip(), unit, group,
                  f"{col}{ref_row}", f"{tol}{ref_row}" if tol else None,
                  f"{col}{ref_row + 1}", f"{col}{ref_row + 2}"))


grid("INJ_TEMP", "현재온도", "℃", "온도 설정", 8, [
    ("NZ", "Nz", "I", "K"), ("H1", "H1", "M", "O"), ("H2", "H2", "Q", "S"), ("H3", "H3", "U", "W"),
    ("H4", "H4", "Y", "AA"), ("OIL", "작동유", "AC", None)])
INJ_COLS = [("HOLD1", "보압1", "I", None), ("S4", "사출4", "N", "P"), ("S3", "사출3", "R", "T"),
            ("S2", "사출2", "V", "X"), ("S1", "사출1", "Z", "AB")]
grid("INJ_SPEED", "사출 속도", "%", "사출·계량", 15, INJ_COLS)
grid("INJ_PRESS", "사출 압력", "kgf", "사출·계량", 18, INJ_COLS)
grid("INJ_TIME", "사출 시간", "sec", "사출·계량", 21, INJ_COLS)
grid("INJ_POS", "사출 위치", "mm", "사출·계량", 24, INJ_COLS)
P.append(("INJ_CUSHION", "쿠션", "mm", "사출·계량", "C21", None, "C22", "C23"))
grid("INJ_ETC", "", None, "사출·계량", 30, [
    ("COOL_TIME", "냉각시간", "C", "E"), ("METER_DELAY", "계량지연", "K", None),
    ("METER_MONITOR", "계량감시", "O", None), ("CUR_INJ_POS", "현사출위치", "Y", None)])
REC_COLS = [("SB1", "석백1", "F", "H"), ("M1", "계량1", "J", "L"), ("M2", "계량2", "N", "P"),
            ("M3", "계량3", "R", "T"), ("SB2", "석백2", "V", "X")]
grid("REC_SPEED", "계량 속도", "%", "사출·계량", 36, REC_COLS)
grid("REC_PRESS", "계량 압력", "kgf", "사출·계량", 39, REC_COLS)
grid("REC_POS", "계량 위치", "mm", "사출·계량", 42, REC_COLS)
grid("REC_BACKPRESS", "배압", "kgf", "사출·계량", 45, REC_COLS)
for code, label, unit, start, end in [("INJ_SEC", "사출 시간", "sec", "C", "E"), ("METER_SEC", "계량 시간", "sec", "G", "I"),
                                      ("MAIN_PRESS", "메인압력", None, "K", "M"), ("SWITCH_PRESS", "전환압력", None, "O", "Q"),
                                      ("SWITCH_POS", "전환위치", None, "S", "U"), ("SWITCH_SPEED", "전환속도", None, "W", "Y"),
                                      ("CYCLE", "생산공정 시간", None, "AA", "AC")]:
    P.append((f"MON_{code}_START", f"{label} (시작)", unit, "사출·계량", None, None, f"{start}52", f"{start}53"))
    P.append((f"MON_{code}_END", f"{label} (종료)", unit, "사출·계량", None, None, f"{end}52", f"{end}53"))
grid("MOLD", "", "℃", "현장 측정", 58, [
    ("TEMP_FIXED", "금형 고정(계기판)", "C", "E"), ("TEMP_MOVING", "금형 이동(계기판)", "G", "I"),
    ("SURF_FIXED", "표면 고정(비접촉)", "K", "M"), ("SURF_MOVING", "표면 이동(비접촉)", "O", "Q"),
    ("TCU_TEMP", "온조기 온도", "S", "U")])
P.append(("HOPPER_DRY", "호퍼건조(눈금)", None, "현장 측정", "W58", "Y58", "W59", "W60"))
# 보빈무게: AA36 = 주간 실측(기준 줄에 기재), AA38 = 야간 실측 문장
P.append(("BOBBIN_WEIGHT", "보빈무게", "g", "사출·계량", None, None, "AA36", "AA38"))

NUM = re.compile(r"^\s*-?\d+(?:\.\d+)?\s*$")
EMBED = re.compile(r"(-?\d+(?:\.\d+)?)\s*g\b")


def num(v, allow_embedded=False):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str) and NUM.match(v):
        return float(v)
    if allow_embedded and isinstance(v, str):
        m = EMBED.search(v)
        if m:
            return float(m.group(1))
    return None


def uid(*parts):
    return str(uuid.uuid5(NS, "|".join(parts)))


def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, (int, float)):
        return repr(float(v)).rstrip("0").rstrip(".") if isinstance(v, float) else str(v)
    return "'" + str(v).replace("'", "''") + "'"


def fmt(x):
    s = repr(float(x))
    return s[:-2] if s.endswith(".0") else s


def shift_of(fs):
    s = (fs or "").upper()
    if re.search(r"(-|_)(DAY|D1|D)(-|$)", s):
        return "DAY"
    if re.search(r"(-|_)(NIGHT|N1|N)(-|$)", s):
        return "NIGHT"
    return None


SET_LOCAL = ("SET LOCAL mqi.actor_ref = 'm1-3-injection-conditions';\n"
             "SET LOCAL mqi.change_reason = '사출조건 체크시트(사출조건표.xlsx, IV BOBBIN 날짜 탭 9장) 적재 2026-11-02: 설비·조건항목·기준(S30420B1)·주야 실측. process_run_id 는 미연결(호기 공란, 설비 사용 기록 없음), 같은 날짜·주야 기록은 remark 참고값';")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xlsx", nargs="?", default=str(DEFAULT_XLSX))
    ap.add_argument("--runs", required=True)
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")

    runs = json.loads(Path(a.runs).read_text(encoding="utf-8"))
    run_index = {}
    for r in runs:
        run_index.setdefault((r["work_date"], shift_of(r.get("fs"))), []).append(r["process_run_id"])

    wb = openpyxl.load_workbook(a.xlsx, data_only=True)
    tabs = [n for n in wb.sheetnames if re.fullmatch(r"20\d{6}[DN]\d+", n)]
    ref = wb[REF_TAB]
    for cell, label in LABELS.items():
        if str(ref[cell].value).strip() != label:
            sys.exit(f"기준 탭 {REF_TAB} {cell} 라벨 불일치: {ref[cell].value!r} != {label!r}")

    spec_values = {}
    obs = []
    link_report = {}
    for tab in tabs:
        ws = wb[tab]
        bad = [c for c, lab in LABELS.items() if str(ws[c].value).strip() != lab]
        if bad:
            sys.exit(f"{tab}: 양식 라벨이 기준 탭과 다름 {bad}")
        title = str(ws["A1"].value or "")
        if not re.search(r"I\s*MEB3\s*IV", title):
            sys.exit(f"{tab}: IV 체크시트가 아님 {title!r}")
        work_date = f"{tab[0:4]}-{tab[4:6]}-{tab[6:8]}"
        spec_doc = str(ws["Y2"].value or "").strip()
        for code, name, unit, group, ref_cell, tol_cell, day_cell, night_cell in P:
            if ref_cell:
                t = num(ws[ref_cell].value)
                tol = num(ws[tol_cell].value) if tol_cell else None
                if t is not None:
                    spec_values.setdefault(code, set()).add((t, tol, spec_doc))
            for sh, cell in (("DAY", day_cell), ("NIGHT", night_cell)):
                raw = ws[cell].value
                v = num(raw, allow_embedded=(code == "BOBBIN_WEIGHT"))
                if v is None:
                    if raw not in (None, "") and not (code == "BOBBIN_WEIGHT" and "저울" in str(raw)):
                        print(f"  숫자 아님 건너뜀 {tab}!{cell} = {raw!r}")
                    continue
                cands = run_index.get((work_date, sh), [])
                run_id = cands[0] if len(cands) == 1 else None
                link_report[(work_date, sh)] = run_id or f"미연결({len(cands)}건)"
                obs.append(dict(code=code, tab=tab, cell=cell, date=work_date, shift=sh, value=v,
                                raw=str(raw), run_id=run_id))

    # 기준이 탭마다 같은지 확인 → 같으면 기준 1벌
    changed = {k: v for k, v in spec_values.items() if len(v) > 1}
    if changed:
        sys.exit(f"기준값이 탭마다 다름(개정 분리 필요): {changed}")
    spec_docs = {d for v in spec_values.values() for (_, _, d) in v}
    if len(spec_docs) != 1:
        sys.exit(f"기준문서 번호가 여러 개: {spec_docs}")
    spec_doc = spec_docs.pop()
    spec_rev = spec_doc.split()[0]

    eq_id = uid("equipment", "IMEB3-INJ-DONGSHIN")
    spec_id = uid("spec", "IV", "INJECTION", spec_rev)
    used = {o["code"] for o in obs} | set(spec_values)
    params = [p for p in P if p[0] in used]

    L = ["-- 사출조건 체크시트 적재 (개인 프로젝트 IMEB3 DB 전용 데이터, 팀 DB 적용 금지)",
         f"-- 원본: 사출조건표.xlsx 날짜 탭 {len(tabs)}장, 생성: tools/injection_conditions_to_mqi.py",
         "BEGIN ISOLATION LEVEL SERIALIZABLE;", SET_LOCAL,
         "INSERT INTO mqi.equipment (equipment_id, equipment_code, equipment_name, equipment_type, remark) VALUES "
         f"({q(eq_id)}, 'IMEB3-INJ-DONGSHIN', '동신 사출기 (호기 미기재)', 'INJECTION_MACHINE', "
         + q(json.dumps({"ds": DS, "note": "사출조건 체크시트 A3 '설비: 동신 사출기 (      호기)' 호기 공란. 같은 날 IV 사출일보의 설비 기록(DS120-1)과 같은 설비인지는 미확인"}, ensure_ascii=False))
         + ") ON CONFLICT DO NOTHING;"]
    vals = []
    for code, name, unit, group, *_ in params:
        vals.append(f"({q(uid('param', code))}, {q(INJECTION_PROCESS_ID)}, {q(code)}, {q(name)}, 'NUMBER', {q(unit)}, 'EQUIPMENT', "
                    + q(json.dumps({"ds": DS, "group": group}, ensure_ascii=False)) + ")")
    L.append("INSERT INTO mqi.parameter_definition (parameter_id, process_id, parameter_code, parameter_name, value_kind, unit, position_scope, description) VALUES\n"
             + ",\n".join(vals) + "\nON CONFLICT DO NOTHING;")
    L.append("INSERT INTO mqi.process_setup_spec (spec_id, model_id, process_id, equipment_id, spec_revision, verification_status, remark) VALUES "
             f"({q(spec_id)}, {q(IV_MODEL_ID)}, {q(INJECTION_PROCESS_ID)}, NULL, {q(spec_rev)}, 'UNVERIFIED', "
             + q(json.dumps({"ds": DS, "source": f"체크시트 기준 줄 ({spec_doc}), 기준문서 원본 대조 전", "tabs": tabs}, ensure_ascii=False))
             + ") ON CONFLICT DO NOTHING;")
    vals = []
    for code, name, unit, group, ref_cell, tol_cell, *_ in params:
        if code not in spec_values:
            continue
        (t, tol, _), = spec_values[code]
        lo, hi = (t - tol, t + tol) if tol is not None else (None, None)
        vals.append(f"({q(uid('spec_item', spec_id, code))}, {q(spec_id)}, {q(uid('param', code))}, {fmt(t)}, "
                    f"{fmt(lo) if lo is not None else 'NULL'}, {fmt(hi) if hi is not None else 'NULL'}, "
                    + q(json.dumps({"ds": DS, "cell": ref_cell, "tol_cell": tol_cell if tol is not None else None, "tolerance": tol}, ensure_ascii=False)) + ")")
    L.append("INSERT INTO mqi.process_setup_spec_item (spec_item_id, spec_id, parameter_id, target_numeric, min_numeric, max_numeric, remark) VALUES\n"
             + ",\n".join(vals) + "\nON CONFLICT DO NOTHING;")
    L.append("COMMIT;")
    parts = [L]
    # 실측: 탭별 {칸: 값} JSON + 칸→(항목, 주야) 대응표 + (날짜, 주야)→process_run 표만 보내고 SQL 에서 펼친다.
    # observation_id = md5('m13:inj-cond:obs|탭|칸')::uuid (다시 돌려도 같은 id → ON CONFLICT 로 중복 없음)
    cellmap = []
    for code, name, unit, group, ref_cell, tol_cell, day_cell, night_cell in params:
        cellmap += [f"({q(day_cell)},{q(code)},'DAY')", f"({q(night_cell)},{q(code)},'NIGHT')"]
    by_tab, raw_by_tab = {}, {}
    for o in obs:
        by_tab.setdefault(o["tab"], {})[o["cell"]] = int(o["value"]) if float(o["value"]).is_integer() else o["value"]
        if o["raw"] != fmt(o["value"]):
            raw_by_tab.setdefault(o["tab"], {})[o["cell"]] = o["raw"]
    tabrows = [f"({q(t)},{q(json.dumps(v, ensure_ascii=False, separators=(',', ':')))},"
               f"{q(json.dumps(raw_by_tab.get(t, {}), ensure_ascii=False, separators=(',', ':')))})" for t, v in by_tab.items()]
    runrows = [f"({q(d)},{q(s)},{q(r)})" for (d, s), r in sorted(link_report.items()) if r and not r.startswith("미연결")]
    parts.append(["BEGIN ISOLATION LEVEL SERIALIZABLE;", SET_LOCAL,
        "WITH m(cell, code, sh) AS (VALUES " + ",".join(cellmap) + "),\n"
        "d(tab, j, raw) AS (VALUES\n" + ",\n".join(tabrows) + "),\n"
        "r(dt, sh, run) AS (VALUES " + ",".join(runrows) + "),\n"
        "v AS (SELECT d.tab, e.key AS cell, (e.value #>> '{}')::numeric AS val, coalesce(d.raw::jsonb ->> e.key, e.value #>> '{}') AS raw,\n"
        "        m.code, m.sh, to_char(to_date(left(d.tab, 8), 'YYYYMMDD'), 'YYYY-MM-DD') AS dt\n"
        "      FROM d CROSS JOIN LATERAL jsonb_each(d.j::jsonb) e JOIN m ON m.cell = e.key)\n"
        "INSERT INTO mqi.parameter_observation (observation_id, process_run_id, equipment_id, parameter_id, value_numeric, raw_value_text, observation_method, validation_status, remark)\n"
        f"SELECT md5('m13:inj-cond:obs|' || v.tab || '|' || v.cell)::uuid, NULL::uuid, {q(eq_id)}::uuid, pd.parameter_id, v.val, v.raw, 'EQUIPMENT_PHOTO', 'VERIFIED',\n"
        f"  jsonb_build_object('ds', {q(DS)}, 'file', '사출조건표.xlsx', 'sheet', v.tab, 'cell', v.cell, 'work_date', v.dt, 'shift', v.sh, 'same_shift_run_id', r.run,\n"
        "    'vs', 'HUMAN_TRANSCRIBED', 'note', '설비 화면 사진 판독(사진_인벤토리 판독 완료)')::text\n"
        "FROM v LEFT JOIN r ON r.dt = v.dt AND r.sh = v.sh\n"
        f"JOIN mqi.parameter_definition pd ON pd.parameter_code = v.code AND pd.description LIKE '%{DS}%'\n"
        "ON CONFLICT DO NOTHING;", "COMMIT;"])

    OUT_DIR.mkdir(exist_ok=True)
    for old in OUT_DIR.glob("injection_conditions_20261102*.sql"):
        old.unlink()
    for n, part in enumerate(parts, 1):
        out = OUT_DIR / f"injection_conditions_20261102_{n}of{len(parts)}.sql"
        out.write_text("\n".join(part) + "\n", encoding="utf-8")
    print(f"탭 {len(tabs)} · 항목 {len(params)} · 기준 {sum(1 for p in params if p[0] in spec_values)} · 실측 {len(obs)}")
    print("process_run 연결:", {f"{d} {s}": v for (d, s), v in sorted(link_report.items())})
    print("→", out)


if __name__ == "__main__":
    main()
