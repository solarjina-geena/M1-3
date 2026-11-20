"""대시보드 AI 창. Claude 가 도구(저장소 조회 함수)를 불러 답한다. 숫자는 항상 DB 조회 결과에서만 나온다.

- 도구 이름은 팀 챗봇 규약(docs/team/chatbot.md)의 함수명을 따른다: get_production_summary, get_lot_history, get_quality_results ...
- 읽기 전용. 이 창에서는 DB 에 쓰지 않는다.
"""
from __future__ import annotations

import json
from typing import Any

import anthropic

from ..config import settings
from ..repository.base import PROCESS_LABEL, Repository

SYSTEM = """당신은 제조 품질 데이터 분석 도우미입니다. 제품은 모델명 IV/OV/HSV 로만 부르고 제품 상표명은 답변에 쓰지 않습니다. 데이터는 Supabase mqi 스키마에 있고, 도구로만 조회합니다.
규칙:
- 숫자·날짜·LOT 코드는 반드시 도구 결과에서 가져옵니다. 도구가 돌려주지 않은 수치는 말하지 않습니다.
- 데이터 상태를 함께 말합니다: 연결은 CANDIDATE(후보)인지 CONFIRMED(확인)인지, 값은 UNVERIFIED/NEEDS_REVIEW 인지.
- 빈칸은 0 이 아닙니다. 기록이 없으면 "기록 없음"이라고 합니다.
- 공정 코드 표기: IMEB3_INJECTION=사출, IMEB3_STITCHING=스티칭, IMEB3_WINDING=권선(BA), IMEB3_CA_PRESS=압입(CA), IMEB3_FINAL_INSPECTION=최종검사.
- LOT 사슬이 끊긴 이유를 물으면 get_lot_chain_gaps 의 first_gap 을 그대로 전달합니다.
- LOT 표기: DB 의 LOT 코드는 YYMMDD+교대(D/N)+순번(예 260903D1 = 2026-09-03 주간 1번). 최종검사 일보의 세 글자 마킹코드(예 ZIC)는 조견표 규칙(Z=2026년, 두 번째 글자=월 A..L, 세 번째=일 A..Z,2..6)으로 CA 제품 LOT 날짜를 뜻합니다. get_lot_history 에 마킹코드나 날짜를 그대로 넣으면 변환해서 찾습니다. 결과의 resolved.how 를 한 줄로 알려 줍니다.
- 사출조건·보빈무게·보압·쿠션·전환위치·사출 온도를 물으면 get_injection_conditions 를 씁니다. 사출기 이름은 도구 결과 equipment(설비 사용 기록)를 그대로 쓰고, 한 설비에서 모델이 시간상 겹치지 않고 이어서 생산된다고 설명합니다. SPEC 을 벗어난 값과 직전 대비 변화(조건변동)를 짚고, 보빈무게 변동과 같이 설명합니다. 체크시트에 '기록'으로만 된 항목(보압1·전환위치·쿠션)은 SPEC 이 없다고 말합니다. 사출조건은 날짜가 아니라 보빈(사출) LOT 코드(체크시트 탭 이름, 예 260827D1)로 부릅니다. 조건 우선순위는 도구 결과 factors(DB 우선순위)를 따릅니다. 조건표가 없는 사출 실행은 "조건표 없음"이라고 합니다.
- CA 초품 위치도를 물으면 get_position_checks 를 씁니다. 판정은 결과의 status 그대로(정상·경계·불량) 말하고, 불량은 모델·좌우·시료 NO·위치도 값을 짚습니다. 기록이 없으면 '입력된 초품 위치도 없음'이라고 합니다.
- 최종검사 수량은 2차(통상 본검사)만 합한 값입니다. 1차는 검사 훈련·신입·타 제품 검사자 지원·연습이라 합치지 않고, 재검은 불량 이슈로 검사 완료품을 다시 본 것이라 재검 LOT 별 수량·불량·불량률을 따로 말합니다(get_inspection_breakdown). 이슈 뒤 본검사에서 같은 불량을 얼마나 찾았는지는 issue_defects 로 나란히 말하고, 재검 LOT 이 '(LOT 기록 누락)'이면 확인 필요라고 알립니다.
- 사람 판단 기록: 확인이 필요한 항목은 get_review_queue, 지난 판단은 get_judgment_history, 비슷한 사례는 find_similar_judgments 로 찾습니다. 판단은 사람이 내리는 것이므로 "제안"으로만 말하고, 지난 판단을 근거로 들 때는 결정·날짜·LOT·근거 메모를 그대로 인용합니다. 누가 판단했는지는 말하지 않습니다.
- 답은 화면에 평문으로 보입니다. 마크다운 기호(**, #, |표)를 쓰지 말고 짧은 문장과 '- ' 목록으로 씁니다. 도구 결과의 내부 키 이름(found, first_gap 같은 영문)은 그대로 쓰지 말고 우리말로 풀어 씁니다.
- 날짜와 공정으로 아래 방향 흐름을 물으면(예: "9/10 사출 LOT 흐름", "9/3 스티칭 LOT 이 언제 쓰였나") get_lot_flow(date, process) 를 씁니다. 공정 말이 없으면 process 는 IMEB3_CA_PRESS(제품) 입니다. 답은 뿌리 LOT 마다 "스티칭 언제 → 권선(BA) 언제 → 압입(CA) 언제 → 최종검사 언제(2차 본검사 수량, 1차·재검은 따로)" 순서로 요약하고, 다음 공정 연결이 없는 LOT 은 "연결된 다음 공정 기록 없음"이라고 합니다. 연결은 DB LOT 연결(후보 CANDIDATE 포함)만이며 추정하지 않습니다. 어느 LOT 이 어느 LOT 으로 이어졌는지는 결과의 links 목록만 근거로 말합니다.
- LOT 번호로 물었는데 결과가 ambiguous(같은 번호가 여러 모델에 있음)면 candidates 의 모델마다 model 을 넣어 다시 조회하고 모델별로 나눠 답합니다. 질문에 공정이 있으면 get_lot_history 에 process 를 넣습니다(사출=IMEB3_INJECTION, 스티칭=IMEB3_STITCHING, 권선=IMEB3_WINDING, 압입·CA=IMEB3_CA_PRESS).
- 기간 질문(예: 9월, 10월 4주, 10/1~10/15): 기간을 받는 도구(get_process_series, get_quality_results, get_inspection_breakdown, get_vision_false_reject, get_position_checks)에 date_from·date_to 를 YYYY-MM-DD 로 꼭 넣습니다. 연도가 없으면 2026년입니다. 'N월'은 그 달 1일~말일, 'N월 N주'는 그 달 1일부터 7일씩 끊은 N번째 주(1주 1~7일, 2주 8~14일, 3주 15~21일, 4주 22~28일, 5주 29일~말일)입니다. get_production_summary 는 전체 기간 합계라 기간 질문에는 쓰지 않습니다. 답 첫머리에 실제로 조회한 날짜(예: 9월(9/1~9/30))를 적습니다. 대시보드 그래프 표시 구간도 이 날짜로 맞춰집니다.
- 비율·불량률·합계·차이·평균을 물으면 도구 결과의 숫자로 calculate 도구를 불러 계산합니다(머리로 계산하지 않음). 답에는 결과와 함께 계산식(분자 ÷ 분모)을 적습니다. 분모가 기록 없음이면 비율을 말하지 않고 이유를 말합니다.
- 비전 가성불량(가성 비율·가성률·진성·비전 재검)을 물으면 get_vision_false_reject 를 씁니다. 가성률 = 가성 ÷ (진성 + 가성), 대시보드 '비전 불량' 화면과 같은 정의입니다. 생산량 대비 비율을 물으면 같은 기간 권선(IMEB3_WINDING) get_process_series 생산량 합으로 calculate 합니다.
- 한국어로 간결하게 답합니다."""

TOOLS: list[dict[str, Any]] = [
    {"name": "get_production_summary", "description": "공정별 생산량·불량·작업일수 합계와 LOT 사슬 현황. model 을 주면 그 모델만.",
     "input_schema": {"type": "object", "properties": {"model": {"type": "string", "enum": ["IV", "OV", "HSV"]}}, "additionalProperties": False}},
    {"name": "get_process_series", "description": "한 공정의 일자별 생산량(또는 검사량)·불량·작업시간 시계열.",
     "input_schema": {"type": "object", "properties": {"process": {"type": "string", "enum": list(PROCESS_LABEL)}, "model": {"type": "string", "enum": ["IV", "OV", "HSV"]},
                                                       "date_from": {"type": "string"}, "date_to": {"type": "string"}},
                      "required": ["process"], "additionalProperties": False}},
    {"name": "get_inspection_breakdown", "description": "최종검사를 검사 구분(1차·2차 본검사 / 재검)으로 나눈 검사량·불량 합계와 재검 LOT 별 수량·불량. 재검은 이미 검사한 LOT 을 다시 본 중복 검사라 최종검사 검사량 합계에 넣지 않는다. LOT 기록이 누락된 재검은 '(LOT 기록 누락)'으로 나온다.",
     "input_schema": {"type": "object", "properties": {"model": {"type": "string", "enum": ["IV", "OV", "HSV"]}, "date_from": {"type": "string"}, "date_to": {"type": "string"}},
                      "additionalProperties": False}},
    {"name": "get_quality_results", "description": "불량 유형별 수량 합계. process 를 비우면 전체.",
     "input_schema": {"type": "object", "properties": {"process": {"type": "string", "enum": list(PROCESS_LABEL)}, "model": {"type": "string", "enum": ["IV", "OV", "HSV"]},
                                                       "date_from": {"type": "string"}, "date_to": {"type": "string"}}, "additionalProperties": False}},
    {"name": "get_lot_history", "description": "LOT 하나의 상위·하위 연결, 투입 자재, 최종검사 결과. lot_code 에는 LOT 코드(260903D1), 최종검사 마킹코드(ZIC), 날짜(2026-09-03, 9/3) 중 아무거나 넣어도 된다.",
     "input_schema": {"type": "object", "properties": {"lot_code": {"type": "string"}, "model": {"type": "string", "enum": ["IV", "OV", "HSV"]},
                                                       "process": {"type": "string", "enum": ["IMEB3_INJECTION", "IMEB3_STITCHING", "IMEB3_WINDING", "IMEB3_CA_PRESS"]}},
                      "required": ["lot_code"], "additionalProperties": False}},
    {"name": "get_lot_flow", "description": "날짜+공정의 LOT 들(주간·야간, 모델별)이 다음 공정(스티칭→권선 BA→압입 CA)에서 언제 쓰였고 그 CA LOT 의 최종검사가 언제였는지(아래 방향). DB LOT 연결만 따라감.",
     "input_schema": {"type": "object", "properties": {"date": {"type": "string", "description": "YYYY-MM-DD"},
                                                       "process": {"type": "string", "enum": ["IMEB3_INJECTION", "IMEB3_STITCHING", "IMEB3_WINDING", "IMEB3_CA_PRESS"]},
                                                       "model": {"type": "string", "enum": ["IV", "OV", "HSV"]}},
                      "required": ["date", "process"], "additionalProperties": False}},
    {"name": "get_injection_conditions", "description": "사출조건(사출기 DS120-1 체크시트) 시계열. lot_code 를 주면 그 LOT 을 만든 보빈(사출) LOT 의 사출 실행을 기준으로 앞 4건·뒤 3건 조건 기록, 없으면 전체 기간. 우선 인자 1순위 사출압력·보압, 2순위 전환위치·쿠션, 3순위 온도와 보빈무게 실측·SPEC 을 돌려준다. lot_code 에는 마킹코드(ZIC), LOT 코드(260827D1), 날짜를 넣을 수 있다.",
     "input_schema": {"type": "object", "properties": {"lot_code": {"type": "string"}, "model": {"type": "string", "enum": ["IV", "OV", "HSV"]}},
                      "additionalProperties": False}},
    {"name": "get_position_checks", "description": "CA 초품 핀 위치도(좌·우 핀 X/Y, 기준 대비 위치도, 판정 정상·경계·불량). 기준값·판정 규칙은 DB(POSITION-A1-3). date 는 YYYY-MM-DD, 비우면 전체.",
     "input_schema": {"type": "object", "properties": {"model": {"type": "string", "enum": ["IV", "OV", "HSV"]}, "date_from": {"type": "string"}, "date_to": {"type": "string"}},
                      "additionalProperties": False}},
    {"name": "get_review_queue", "description": "사람 확인이 필요한 항목(판독값 확인 필요, 최종검사 LOT 판독 불가, 생산 이벤트 확인; 초품 위치도는 포함하지 않음 — 산포도 데이터). lot_code 로 좁힐 수 있다.",
     "input_schema": {"type": "object", "properties": {"model": {"type": "string", "enum": ["IV", "OV", "HSV"]}, "lot_code": {"type": "string"}},
                      "additionalProperties": False}},
    {"name": "get_judgment_history", "description": "사람이 내린 판단 기록(결정·근거 메모·LOT·날짜·AI 제안과 일치 여부). lot_code 나 kind(READ_VALUE/INSPECTION_LOT/EVENT/POSITION)로 좁힌다.",
     "input_schema": {"type": "object", "properties": {"lot_code": {"type": "string"}, "kind": {"type": "string", "enum": ["READ_VALUE", "INSPECTION_LOT", "EVENT", "POSITION"]},
                                                       "model": {"type": "string", "enum": ["IV", "OV", "HSV"]}}, "additionalProperties": False}},
    {"name": "find_similar_judgments", "description": "새 항목과 비슷한 지난 판단(같은 종류, 제목·값이 비슷한 순). 제안의 근거로만 쓴다.",
     "input_schema": {"type": "object", "properties": {"kind": {"type": "string", "enum": ["READ_VALUE", "INSPECTION_LOT", "EVENT", "POSITION"]}, "text": {"type": "string"}},
                      "required": ["kind", "text"], "additionalProperties": False}},
    {"name": "get_vision_false_reject", "description": "권선(BA) 비전 불량: 작업일보 비전 1·2·3차 불량 수량(설비가 걸러낸 수량)과, 걸러낸 것을 사람이 다시 본 재검 결과(가성/진성·진성 유형). 모델·재검 차수별 합계와 가성률(가성 ÷ (진성+가성), %)을 계산해서 돌려준다.",
     "input_schema": {"type": "object", "properties": {"model": {"type": "string", "enum": ["IV", "OV", "HSV"]}, "date_from": {"type": "string"}, "date_to": {"type": "string"}},
                      "additionalProperties": False}},
    {"name": "calculate", "description": "사칙연산 계산기. 숫자와 + - * / ( ) 만 쓴 식을 계산해 돌려준다(예: '1234 / (1234 + 908) * 100'). 비율·불량률(%·PPM)·합계·차이·평균은 반드시 이 도구로 계산한다.",
     "input_schema": {"type": "object", "properties": {"expression": {"type": "string"}, "label": {"type": "string", "description": "무엇을 계산하는지(예: 9월 IV 가성률 %)"}},
                      "required": ["expression"], "additionalProperties": False}},
    {"name": "get_lot_chain_gaps", "description": "CA 제품 LOT 마다 수지→사출→스티칭→권선→압입 사슬이 어디까지 이어졌는지와 끊긴 첫 자리(first_gap).",
     "input_schema": {"type": "object", "properties": {"model": {"type": "string", "enum": ["IV", "OV", "HSV"]}, "only_gaps": {"type": "boolean"}, "limit": {"type": "integer"}},
                      "additionalProperties": False}},
]


def safe_calc(expr: str) -> float:
    """숫자와 + - * / ( ) 만 허용하는 계산(eval 을 쓰지 않음). 0 으로 나누면 오류."""
    import ast
    import operator as op
    ops = {ast.Add: op.add, ast.Sub: op.sub, ast.Mult: op.mul, ast.Div: op.truediv}
    text = str(expr).replace(",", "").replace("×", "*").replace("÷", "/").strip()
    if len(text) > 300:
        raise ValueError("식이 너무 깁니다")

    def ev(n):
        if isinstance(n, ast.Expression):
            return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)) and not isinstance(n.value, bool):
            return float(n.value)
        if isinstance(n, ast.BinOp) and type(n.op) in ops:
            a, b = ev(n.left), ev(n.right)
            if isinstance(n.op, ast.Div) and b == 0:
                raise ValueError("0 으로 나눌 수 없습니다(분모가 0)")
            return ops[type(n.op)](a, b)
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, (ast.USub, ast.UAdd)):
            v = ev(n.operand)
            return -v if isinstance(n.op, ast.USub) else v
        raise ValueError("숫자와 + - * / ( ) 만 쓸 수 있습니다")
    return ev(ast.parse(text, mode="eval"))


def vision_false_reject(repo: Repository, model: str | None, date_from: str | None, date_to: str | None) -> dict:
    """대시보드 '비전 불량' 화면과 같은 자료(repo.vision_summary)를 모델·차수별로 묶고 가성률을 계산한다."""
    v = repo.vision_summary(model, date_from, date_to)
    rej: dict = {}
    for r in v.get("rejects") or []:
        k = f"{r['model']} 비전{r['stage']}차"
        rej[k] = rej.get(k, 0) + (r.get("qty") or 0)
    grp: dict = {}
    tot = {"inspected": 0, "false": 0, "true": 0}
    types: dict = {}
    for c in v.get("checks") or []:
        g = grp.setdefault(f"{c['model']} 재검 {c['round']}차", {"inspected": 0, "false": 0, "true": 0, "days": set()})
        for k in ("inspected", "false", "true"):
            g[k] += c.get(k) or 0
            tot[k] += c.get(k) or 0
        g["days"].add(c["date"])
        for n, q in (c.get("types") or {}).items():
            types[n] = types.get(n, 0) + q
    rate = lambda f, t: round(f / (f + t) * 100, 1) if (f + t) else None
    out = {"date_from": date_from, "date_to": date_to, "model": model or "전체",
           "work_journal_vision_rejects": rej or "기록 없음",
           "recheck_by_model_round": {k: {"inspected": g["inspected"], "false_reject": g["false"], "true_defect": g["true"],
                                          "false_rate_pct": rate(g["false"], g["true"]), "days": len(g["days"])} for k, g in sorted(grp.items())} or "기록 없음",
           "recheck_total": {**tot, "false_rate_pct": rate(tot["false"], tot["true"])},
           "true_defect_types": dict(sorted(types.items(), key=lambda kv: -kv[1])[:10]),
           "definition": "가성률 = 가성 ÷ (진성 + 가성) × 100. 가성 = 비전이 불량으로 걸렀지만 사람이 다시 보니 양품"}
    return out


def run_tool(repo: Repository, name: str, args: dict) -> Any:
    if name == "get_production_summary":
        return repo.summary(args.get("model"))
    if name == "get_process_series":
        return repo.process_series(args["process"], args.get("model"), args.get("date_from"), args.get("date_to"))
    if name == "get_inspection_breakdown":
        r = repo.inspection_breakdown(args.get("model"), args.get("date_from"), args.get("date_to"))
        r.pop("daily", None)
        return r
    if name == "get_quality_results":
        return repo.defects(args.get("process"), args.get("model"), args.get("date_from"), args.get("date_to"))[:40]
    if name == "get_lot_history":
        return repo.lot_trace(args["lot_code"], args.get("model"), args.get("process"))
    if name == "get_lot_flow":
        f = repo.lot_flow(args["date"], args["process"], args.get("model"))
        out = {k: f.get(k) for k in ("found", "date", "process_code", "model", "roots", "per_root", "inspection_summary")}
        nm = {n["lot_id"]: n for n in f.get("nodes") or []}
        PK = {"IMEB3_INJECTION": "사출", "IMEB3_STITCHING": "스티칭", "IMEB3_WINDING": "권선(BA)", "IMEB3_CA_PRESS": "압입(CA)"}
        lab = lambda n: f"{n['model']} {PK.get(n['process_code'], n['process_code'])} {n['lot_code']}({n['lot_date']})"
        out["links"] = [f"{lab(nm[e['from']])} -> {lab(nm[e['to']])} [{e['status']}]" for e in f.get("edges") or [] if e["from"] in nm and e["to"] in nm]  # 연결선 그대로(이것만 근거로 말함)
        return out
    if name == "get_injection_conditions":
        w = repo.injection_window(args.get("lot_code") or None, args.get("model"))
        for r in w["records"]:  # AI 에는 값·SPEC 만 짧게
            r["values"] = {k: {"value": v["value"], "lo": v["lo"], "hi": v["hi"], "unit": v["unit"], "name": v["name"]} for k, v in r["values"].items()}
        return w
    if name == "get_position_checks":
        rows = repo.position_checks(args.get("model"), args.get("date_from"), args.get("date_to"))
        keep = ("check_date", "variant", "ca_lot_code", "side", "sample_no", "raw_x", "raw_y", "pos_xy", "status", "spec_pos", "control_pos")
        return [{k: r.get(k) for k in keep} for r in rows[:400]] or {"found": False, "note": "입력된 초품 위치도 없음"}
    if name == "get_review_queue":
        rows = repo.review_queue(args.get("model"), None, args.get("lot_code") or None)
        return [{k: r.get(k) for k in ("item_id", "kind", "stage_label", "model_code", "item_date", "lot_code", "title", "current_value")} for r in rows[:60]]             or {"found": False, "note": "확인 필요 항목 없음"}
    if name == "get_judgment_history":
        return repo.judgment_log(args.get("lot_code") or None, args.get("kind"), args.get("model"), 50) or {"found": False, "note": "판단 기록 없음"}
    if name == "find_similar_judgments":
        return similar_judgments(repo, args["kind"], args["text"])
    if name == "get_vision_false_reject":
        return vision_false_reject(repo, args.get("model"), args.get("date_from"), args.get("date_to"))
    if name == "calculate":
        v = safe_calc(args["expression"])
        return {"expression": args["expression"], "label": args.get("label"), "value": v, "rounded": round(v, 4)}
    if name == "get_lot_chain_gaps":
        rows = repo.chain_gaps(args.get("model"), bool(args.get("only_gaps")))
        return rows[: int(args.get("limit") or 30)]
    raise ValueError(f"unknown tool {name}")


def _tokens(t: str) -> set[str]:
    import re
    return {w for w in re.split(r"[^0-9A-Za-z가-힣?]+", (t or "").upper()) if w}


def similar_judgments(repo: Repository, kind: str, text: str, k: int = 5) -> list[dict]:
    """같은 종류의 지난 판단을 제목·값·메모의 낱말 겹침으로 고른다(임베딩 없이, 근거 확인이 쉬운 방식)."""
    q = _tokens(text)
    keep = ("changed_at", "decision", "decision_label", "stage_label", "model_code", "lot_code", "item_date", "title", "value", "basis", "note", "ai_agreed")
    scored = []
    for r in repo.judgment_log(None, kind, None, 500):
        t = _tokens(" ".join(str(r.get(x) or "") for x in ("title", "value", "note")))
        score = len(q & t) / (len(q | t) or 1)
        scored.append((score, {**{x: r.get(x) for x in keep}, "similarity": round(score, 2)}))
    scored.sort(key=lambda s: -s[0])
    return [r for _, r in scored[:k]]


DECISION_LABEL = {"READ_VALUE": {"VERIFIED": "확인", "CORRECTED": "정정", "REJECTED": "반려"},
                  "INSPECTION_LOT": {"CONFIRMED": "CA LOT 연결", "UNRESOLVED": "미연결 유지", "VOID": "삭제(VOID)"},
                  "EVENT": {"VERIFIED": "확인", "REJECTED": "반려", "VOID": "삭제(VOID)"},
                  "POSITION": {"VERIFIED": "확인", "CORRECTED": "정정", "NEEDS_REVIEW": "재측정 요청"}}


def suggest_judgment(repo: Repository, item: dict) -> dict:
    """판단 카드의 AI 제안. 도구 반복 없이 한 번 호출: 항목 + 비슷한 지난 판단 → 결정 하나와 이유(구조화 출력). 저장은 사람이 한다."""
    similar = similar_judgments(repo, item["kind"], f"{item.get('title')} {item.get('current_value') or ''}")
    if not settings.anthropic_key:
        return {"decision": None, "reason": "ANTHROPIC_API_KEY 가 없어 AI 제안을 만들 수 없습니다.", "similar": similar}
    allowed = DECISION_LABEL[item["kind"]]
    prompt = (f"제조 품질 기록의 사람 확인 항목입니다. 허용 결정 중 하나를 제안하세요. 추정으로 LOT 을 연결하지 마세요(판독 불가 마킹은 미연결 유지가 기본). "
              f"근거가 부족하면 그렇게 말하세요.\n허용 결정: {json.dumps(allowed, ensure_ascii=False)}\n"
              f"항목: {json.dumps({k: item.get(k) for k in ('kind', 'stage_label', 'model_code', 'item_date', 'lot_code', 'title', 'current_value', 'detail')}, ensure_ascii=False, default=str)}\n"
              f"비슷한 지난 판단: {json.dumps(similar, ensure_ascii=False, default=str)}")
    client = anthropic.Anthropic(api_key=settings.anthropic_key)
    schema = {"type": "object", "properties": {"decision": {"type": "string", "enum": list(allowed)}, "reason": {"type": "string"}},
              "required": ["decision", "reason"], "additionalProperties": False}
    try:
        resp = client.messages.create(model=settings.anthropic_model, max_tokens=1500,
                                      system="한국어로 2~3문장 이유를 씁니다. 사람 이름은 쓰지 않습니다.",
                                      messages=[{"role": "user", "content": prompt}],
                                      output_config={"format": {"type": "json_schema", "schema": schema}, "effort": "low"})
        out = json.loads("".join(b.text for b in resp.content if b.type == "text"))
    except (anthropic.APIError, ValueError) as e:
        return {"decision": None, "reason": f"AI 제안 실패: {e}", "similar": similar}
    return {"decision": out["decision"], "decision_label": allowed[out["decision"]], "reason": out["reason"], "similar": similar,
            "model": resp.model, "ai_generated": True}


def chat(repo: Repository, history: list[dict], question: str) -> dict:
    """history: [{role, content(str)}] 이전 대화. 반환: {answer, tool_calls, usage, model}"""
    if not settings.anthropic_key:
        return {"answer": "ANTHROPIC_API_KEY 가 설정되지 않아 AI 답변을 할 수 없습니다. backend/.env.personal 에 키를 넣어 주세요.", "tool_calls": [], "usage": None, "model": None}
    client = anthropic.Anthropic(api_key=settings.anthropic_key)
    messages = [{"role": m["role"], "content": m["content"]} for m in history[-8:] if m.get("role") in ("user", "assistant") and m.get("content")]
    messages.append({"role": "user", "content": question})
    tool_calls = []
    usage = {"input_tokens": 0, "output_tokens": 0}
    response = None
    for _ in range(8):
        try:
            # 거절(refusal) 시 서버가 다른 모델로 이어서 답하도록 fallbacks 를 켠다.
            response = client.beta.messages.create(
                model=settings.anthropic_model, max_tokens=8000, system=SYSTEM, tools=TOOLS, messages=messages,
                output_config={"effort": "medium"},
                betas=["server-side-fallback-2026-07-01"], fallbacks="default",
            )
        except anthropic.AuthenticationError:
            return {"answer": "Anthropic API 키가 올바르지 않습니다.", "tool_calls": tool_calls, "usage": usage, "model": settings.anthropic_model}
        except anthropic.RateLimitError:
            return {"answer": "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.", "tool_calls": tool_calls, "usage": usage, "model": settings.anthropic_model}
        except anthropic.APIStatusError as e:
            return {"answer": f"AI 호출 오류({e.status_code}): {e.message}", "tool_calls": tool_calls, "usage": usage, "model": settings.anthropic_model}
        except anthropic.APIConnectionError:
            return {"answer": "AI 서버에 연결할 수 없습니다(네트워크).", "tool_calls": tool_calls, "usage": usage, "model": settings.anthropic_model}
        usage["input_tokens"] += response.usage.input_tokens
        usage["output_tokens"] += response.usage.output_tokens
        if response.stop_reason == "refusal":
            return {"answer": "모델이 이 질문에 답하지 않았습니다(refusal).", "tool_calls": tool_calls, "usage": usage, "model": response.model}
        uses = [b for b in response.content if b.type == "tool_use"]
        if not uses:
            break
        messages.append({"role": "assistant", "content": response.content})
        results = []
        for u in uses:
            try:
                out = run_tool(repo, u.name, dict(u.input))
                tool_calls.append({"tool": u.name, "input": dict(u.input), "rows": len(out) if isinstance(out, list) else 1})
                results.append({"type": "tool_result", "tool_use_id": u.id, "content": json.dumps(out, ensure_ascii=False, default=str)[:60000]})
            except Exception as e:  # noqa: BLE001
                tool_calls.append({"tool": u.name, "input": dict(u.input), "error": str(e)})
                results.append({"type": "tool_result", "tool_use_id": u.id, "content": f"error: {e}", "is_error": True})
        messages.append({"role": "user", "content": results})
    answer = "".join(b.text for b in response.content if b.type == "text") if response else ""
    return {"answer": answer or "(답변 없음)", "tool_calls": tool_calls, "usage": usage, "model": response.model if response else None}
