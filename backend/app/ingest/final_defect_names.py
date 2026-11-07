"""최종검사 불량명 표시용 묶음 (2026-11-07, 불량 유형별 막대그래프·PPM).

DB(defect_type)는 원문 표기를 그대로 둔다(팀 스키마·원문 보존). 같은 불량의 다른 표기
('marking'·'Marking 불량'·'Marking불량', 'bobbin_break'·'Bobbin파손' 등)만 화면·API 에서 하나로 묶는다.
기준 이름 = 최종검사일보 양식의 '불량 유형' 줄. 뜻이 분명하지 않은 영문 코드(lower_case_press, misinsert 등)는
추정하지 않고 원문 이름 그대로 둔다.
"""
from __future__ import annotations

import re

STANDARD = [
    "Bobbin 파손", "Bobbin 미성형", "Bobbin 이물", "보빈 안흔들림", "Post 파손", "Post 미성형",
    "Wire 이탈", "Wire 늘어짐", "Wire Damage", "여선불량", "탈피불량",
    "Lead Pin 휨", "Lead Pin 찍힘", "Lead Pin 도금", "Pin 도금", "Pin 찍힘",
    "U/C 찍힘", "U/C 도금", "L/C 찍힘", "L/C 도금",
    "용접버", "용접불량", "Marking 불량", "내경파손", "미압입",
]

# iMEB3 에 없는 불량(팀장 확인 2026-11-07) — 보이면 같은 장의 다른 제품 칸을 읽은 것. 화면 집계에서 빼고 개수만 알린다.
NOT_IMEB3 = {"탈피불량", "납조불량"}

# 표시 순서(팀장 2026-11-07): 비슷한 불량끼리 붙여 보이게 묶음 순서 → 묶음 안에서는 수량 많은 순. Marking 은 리워크 가능이라 맨 끝.
GROUPS = [
    ("와이어·핀·용접", ["Wire Damage", "Lead Pin 찍힘", "Lead Pin 휨", "용접버", "Wire 이탈", "Wire 늘어짐", "여선불량", "용접불량", "Lead Pin 도금"]),
    ("보빈·Post·압입", ["Bobbin 파손", "Post 파손", "미압입", "내경파손"]),
    # 사출 보빈 불량이 걸러지지 않고 최종검사까지 흘러온 것(팀장 2026-11-07)
    ("보빈 불량 유출(사출)", ["Bobbin 미성형", "Post 미성형", "미성형", "Bobbin 이물", "P/O 이물", "보빈 안흔들림", "Bobbin 가스", "Post 가스"]),
    ("Case(U/C·L/C)", ["U/C 찍힘", "U/C 도금", "L/C 찍힘", "L/C 도금"]),
]
LAST = ["Marking 불량"]


def group_of(name: str) -> tuple[int, str]:
    """(묶음 순서, 묶음 이름). 목록에 없는 원문 이름은 '기타'(Case 다음), Marking 은 맨 끝."""
    if name in LAST:
        return (9, "리워크 가능")
    for i, (g, names) in enumerate(GROUPS):
        if name in names:
            return (i, g)
    return (len(GROUPS), "기타")

# 원문 표기(정규화 키) → 기준 이름. 뜻이 같은 것이 분명한 것만.
_ALIAS = {
    "bobbinbreak": "Bobbin 파손", "bobbin파손": "Bobbin 파손", "보빈파손": "Bobbin 파손",
    "bobbinunformed": "Bobbin 미성형", "보빈미성형": "Bobbin 미성형",
    "bobbin이물": "Bobbin 이물", "보빈이물": "Bobbin 이물", "bobbinforeignmatter": "Bobbin 이물",
    "보빈안흔들림": "보빈 안흔들림", "안흔들림": "보빈 안흔들림",
    "postbreak": "Post 파손", "post파손": "Post 파손",
    "postunformed": "Post 미성형", "postimmature": "Post 미성형", "포스트미성형": "Post 미성형", "p/o미성형": "Post 미성형", "post미성형": "Post 미성형",
    "wire이탈": "Wire 이탈", "와이어이탈": "Wire 이탈",
    "wirestretch": "Wire 늘어짐", "wire늘어짐": "Wire 늘어짐", "와이어늘어짐": "Wire 늘어짐",
    "wiredamage": "Wire Damage",
    "여선": "여선불량", "yeseon": "여선불량",
    "탈피": "탈피불량",
    "leadpin휨": "Lead Pin 휨", "leadpinbent": "Lead Pin 휨", "leadpinbend": "Lead Pin 휨",
    "leadpin찍힘": "Lead Pin 찍힘", "leadpin도금": "Lead Pin 도금", "pin도금": "Lead Pin 도금", "pin찍힘": "Lead Pin 찍힘",
    "핀찍힘": "Lead Pin 찍힘", "핀휨": "Lead Pin 휨", "핀도금": "Lead Pin 도금",   # 핀 = 리드핀(재검 비고 표기, 팀장 2026-11-07)
    "leadpindent": "Lead Pin 찍힘", "pinnick": "Lead Pin 찍힘", "리드도금": "Lead Pin 도금",   # 핀 = 리드핀(같은 부품)
    "u/c찍힘": "U/C 찍힘", "uc찍힘": "U/C 찍힘", "uppercasenick": "U/C 찍힘", "uppercasedent": "U/C 찍힘",
    "lowercasenick": "L/C 찍힘", "lowercasedent": "L/C 찍힘", "lowercasedentmark": "L/C 찍힘", "u/c도금": "U/C 도금", "upper_case_plating": "U/C 도금", "uppercaseplating": "U/C 도금",
    "l/c찍힘": "L/C 찍힘", "lc찍힘": "L/C 찍힘", "l/c도금": "L/C 도금", "lowercaseplating": "L/C 도금",
    "용접찍힘버": "용접버", "용접버": "용접버", "용접": "용접불량",   # 용접찍힘버 = 용접버(같은 불량, 팀장 2026-11-07)
    "marking": "Marking 불량",
    "내경파손": "내경파손", "innerborebreak": "내경파손",
    "미압입": "미압입", "notinserted": "미압입", "missingpress": "미압입", "비압입": "미압입",
    "납조": "납조불량", "탈피": "탈피불량",
    "bobbingas": "Bobbin 가스", "보빈가스": "Bobbin 가스", "bobbin가스": "Bobbin 가스", "unformed": "미성형",
    "lowercasepress": "미압입",      # lower case press = 미압입(팀장 2026-11-07)
    "misinsert": "Lead Pin 휨",        # misinsert = 핀 휨(팀장 2026-11-07)
}


def _key(name: str) -> str:
    k = re.sub(r"[\s_]+", "", str(name or "").strip().lower())
    k = k.replace("lead pin", "leadpin")
    if k.endswith("불량") and k not in ("불량",):
        k = k[:-2]
    return k


def standard_name(name: str | None) -> str:
    """표시용 이름. 묶을 근거가 없으면 원문 그대로."""
    if not name:
        return "(이름 없음)"
    k = _key(name)
    if k in _ALIAS:
        return _ALIAS[k]
    for s in STANDARD:
        if _key(s) == k:
            return s
    return str(name).strip()
