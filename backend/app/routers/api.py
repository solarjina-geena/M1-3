"""HTTP API. 읽기는 누구나. 쓰기(/api/journal*, /api/links/confirm)는
- Supabase Auth 로그인 토큰(허용 이메일 목록 통과) 또는
- ADMIN_API_TOKEN(로컬·비상용)
중 하나를 Authorization: Bearer 로 보내야 한다. 둘 다 설정돼 있지 않으면 로컬 개방."""
from __future__ import annotations

import asyncio
from typing import Any, Optional

import json
import re
import uuid

import anthropic
from fastapi import APIRouter, File, Header, HTTPException, Query, Request, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel

from ..agent.claude_agent import chat as agent_chat
from ..fishbone import to_rows
from ..auth import supabase_auth as sauth
from ..config import settings
from ..db.supabase_client import SupabaseError
from ..ingest import excel_csv
from ..ingest.image import extract_from_image
from ..ingest.journal_payload import JournalPayload
from ..repository.base import PROCESS_LABEL
from ..repository.supabase import get_repository

router = APIRouter(prefix="/api")


def _repo():
    try:
        return get_repository()
    except SupabaseError as e:
        raise HTTPException(503, str(e)) from e


def _login_required() -> bool:
    return bool(settings.admin_token or (sauth.configured() and settings.allowed_emails))


def _admin(authorization: Optional[str]) -> dict:
    """쓰기 권한 확인. 통과하면 {"via": "admin_token"|"supabase"|"open", "email": ...}."""
    if not _login_required():
        return {"via": "open", "email": None}
    token = authorization[7:].strip() if authorization and authorization.startswith("Bearer ") else ""
    if not token:
        raise HTTPException(401, "로그인이 필요합니다 (팀원 이메일 로그인 또는 관리자 토큰)")
    if settings.admin_token and token == settings.admin_token:
        return {"via": "admin_token", "email": None}
    if sauth.configured() and settings.allowed_emails:
        try:
            user = sauth.verify_user(token)
            return {"via": "supabase", "email": user["email"]}
        except sauth.AuthError as e:
            raise HTTPException(401, str(e)) from e
    raise HTTPException(401, "관리자 토큰이 올바르지 않습니다")


def _wrap(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except SupabaseError as e:
        raise HTTPException(502, str(e)) from e


# ---------------------------------------------------------------- 읽기
@router.get("/health")
def health():
    info = settings.status()
    info["processes"] = PROCESS_LABEL
    try:
        info.update(get_repository().health())
    except SupabaseError as e:
        info["db"] = f"not configured: {e}"
    info["storage"] = "supabase"
    return info


@router.get("/summary")
def summary(model: Optional[str] = None):
    return _wrap(_repo().summary, model)


@router.get("/process/{process}/series")
def process_series(process: str, model: Optional[str] = None, date_from: Optional[str] = Query(None, alias="from"), date_to: Optional[str] = Query(None, alias="to")):
    if process not in PROCESS_LABEL:
        raise HTTPException(404, f"공정 코드 아님: {process}")
    return _wrap(_repo().process_series, process, model, date_from, date_to)


@router.get("/defects")
def defects(process: Optional[str] = None, model: Optional[str] = None, date_from: Optional[str] = Query(None, alias="from"), date_to: Optional[str] = Query(None, alias="to")):
    return _wrap(_repo().defects, process, model, date_from, date_to)


@router.get("/defects/stitching-quantity-status")
def stitching_defect_quantity_status(model: Optional[str] = None, date_from: Optional[str] = Query(None, alias="from"), date_to: Optional[str] = Query(None, alias="to")):
    return _wrap(_repo().stitching_defect_quantity_status, model, date_from, date_to)


@router.get("/lots/gaps")
def lot_gaps(model: Optional[str] = None, only_gaps: bool = False):
    return _wrap(_repo().chain_gaps, model, only_gaps)


@router.get("/lots/chain")
def lot_chain(model: Optional[str] = None):
    return _wrap(_repo().chain_rows, model)


@router.get("/lot/{lot_code}")
def lot_trace(lot_code: str, model: Optional[str] = None):
    return _wrap(_repo().lot_trace, lot_code, model)


@router.get("/runs/recent")
def recent_runs(model: Optional[str] = None, limit: int = 50):
    return _wrap(_repo().recent_runs, model, limit)


# ---------------------------------------------------------------- 쓰기
@router.get("/admin/session")
def admin_session(authorization: Optional[str] = Header(None)):
    who = _admin(authorization)
    return {"ok": True, "read_only": settings.read_only, "actor": settings.actor, **who}


# ---------------------------------------------------------------- 로그인 (Supabase Auth, 팀 앱과 같은 규칙)
class LoginIn(BaseModel):
    email: str
    password: str


class RefreshIn(BaseModel):
    refresh_token: str


@router.get("/auth/config")
def auth_config():
    return {"supabase_login": sauth.configured() and bool(settings.allowed_emails), "admin_token": bool(settings.admin_token),
            "login_required": _login_required(), "read_only": settings.read_only, "team_ocr_url": settings.team_ocr_url}


@router.post("/auth/login")
def auth_login(body: LoginIn):
    try:
        return sauth.sign_in(body.email, body.password)
    except sauth.AuthError as e:
        raise HTTPException(401, str(e)) from e


@router.post("/auth/refresh")
def auth_refresh(body: RefreshIn):
    try:
        return sauth.refresh(body.refresh_token)
    except sauth.AuthError as e:
        raise HTTPException(401, str(e)) from e


@router.get("/auth/me")
def auth_me(authorization: Optional[str] = Header(None)):
    token = authorization[7:].strip() if authorization and authorization.startswith("Bearer ") else ""
    if not token:
        raise HTTPException(401, "로그인 세션이 없습니다.")
    try:
        return sauth.verify_user(token)
    except sauth.AuthError as e:
        raise HTTPException(401, str(e)) from e


@router.post("/auth/logout")
def auth_logout(authorization: Optional[str] = Header(None)):
    token = authorization[7:].strip() if authorization and authorization.startswith("Bearer ") else ""
    if token:
        sauth.sign_out(token)
    return {"ok": True}


@router.post("/journal/preview")
def journal_preview(payload: JournalPayload):
    """쓰지 않고 정규화 결과만 돌려준다(화면 미리보기)."""
    return {"payload": payload.model_dump(), "normalized": payload.normalized()}


STAGE_LABEL = {"IMEB3_INJECTION": "사출", "IMEB3_STITCHING": "스티칭", "IMEB3_WINDING": "권선(BA)", "IMEB3_CA_PRESS": "압입(CA)",
               "IMEB3_FINAL_INSPECTION": "최종검사"}
VIA_LABEL = {"form": "직접 입력", "file": "엑셀·CSV", "image": "사진 OCR", "gaps": "사슬 보완", "confirm": "연결 확인", "position": "위치도 붙여넣기"}


def _actor(who: dict) -> str:
    """CRUD 이력의 '누가': 로그인 이메일은 앞 3글자만 남겨 가린다(관리자 토큰이면 admin-token)."""
    email = who.get("email") or ""
    if email:
        local = email.split("@")[0]
        return f"web:{local[:3]}***"
    return "web:admin-token" if who.get("via") == "admin_token" else settings.actor


def _reason(stage_code: str, via: str, summary: str) -> str:
    """CRUD 이력의 '무엇을': [공정] 입력경로 · 요약 — 공정 단계별로 걸러 보기 쉽게 같은 형식을 쓴다."""
    return f"[{STAGE_LABEL.get(stage_code, stage_code or '공통')}] {VIA_LABEL.get(via, via or '입력')} · {summary}"


def _journal_meta(n: dict, who: dict, via: str) -> dict:
    n["actor"] = _actor(who)
    n["reason"] = _reason(n.get("process", ""), via, f"{n.get('model', '')} {n.get('work_date', '')} {n.get('shift', '')}".strip())
    return n


@router.post("/journal")
def journal_save(payload: JournalPayload, authorization: Optional[str] = Header(None), via: str = Query("form", max_length=20)):
    who = _admin(authorization)
    return _wrap(_repo().journal_save, _journal_meta(payload.normalized(), who, via))


class BatchIn(BaseModel):
    items: list[JournalPayload]


@router.post("/journal/batch")
def journal_batch(body: BatchIn, authorization: Optional[str] = Header(None), via: str = Query("file", max_length=20)):
    who = _admin(authorization)
    repo = _repo()
    results = []
    for i, p in enumerate(body.items):
        try:
            results.append({"index": i, "ok": True, "result": repo.journal_save(_journal_meta(p.normalized(), who, via))})
        except SupabaseError as e:
            results.append({"index": i, "ok": False, "error": str(e)})
    return {"saved": sum(1 for r in results if r["ok"]), "failed": sum(1 for r in results if not r["ok"]), "results": results}


@router.get("/journal/template.xlsx")
def journal_template():
    return Response(excel_csv.template_workbook(), media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    headers={"Content-Disposition": 'attachment; filename="journal_template.xlsx"'})


@router.post("/journal/preview-file")
async def journal_preview_file(file: UploadFile = File(...)):
    data = await file.read()
    name = file.filename or "upload"
    if name.lower().endswith((".xlsx", ".xlsm")):
        return {"file": name, "items": excel_csv.parse_excel(data, name)}
    if name.lower().endswith(".csv"):
        return {"file": name, "items": excel_csv.parse_csv(data, name)}
    raise HTTPException(400, "xlsx 또는 csv 파일만 받습니다")


async def _wait_for_disconnect(request: Request) -> None:
    while not await request.is_disconnected():
        await asyncio.sleep(0.25)


@router.post("/journal/preview-image")
async def journal_preview_image(request: Request, file: UploadFile = File(...), authorization: Optional[str] = Header(None)):
    _admin(authorization)  # Anthropic 사용량이 드는 요청이므로 로그인(또는 관리자 토큰) 없이는 받지 않는다
    data = await file.read()
    name = (file.filename or "image").lower()
    media = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp", "gif": "image/gif", "pdf": "application/pdf"}.get(name.rsplit(".", 1)[-1])
    if not media:
        raise HTTPException(400, "jpg/png/webp/gif/pdf 만 받습니다")
    ocr_task = asyncio.create_task(extract_from_image(data, media, file.filename or "image"))
    disconnect_task = asyncio.create_task(_wait_for_disconnect(request))
    try:
        done, _ = await asyncio.wait({ocr_task, disconnect_task}, return_when=asyncio.FIRST_COMPLETED)
        if ocr_task in done:
            disconnect_task.cancel()
            await asyncio.gather(disconnect_task, return_exceptions=True)
            return {"file": file.filename, **await ocr_task}
        ocr_task.cancel()
        await asyncio.gather(ocr_task, return_exceptions=True)
        return Response(status_code=499)
    except anthropic.AuthenticationError as e:
        raise HTTPException(502, "Anthropic API 키 인증에 실패했습니다.") from e
    except anthropic.RateLimitError as e:
        raise HTTPException(429, "Anthropic API 한도 또는 요청 제한에 도달했습니다.") from e
    except anthropic.APITimeoutError as e:
        raise HTTPException(504, "OCR 요청이 90초 안에 끝나지 않았습니다. 파일 크기를 줄여 다시 시도해 주세요.") from e
    except anthropic.APIConnectionError as e:
        raise HTTPException(502, "Anthropic API에 연결하지 못했습니다.") from e
    except anthropic.APIStatusError as e:
        raise HTTPException(502, f"Anthropic API 오류 (HTTP {e.status_code}).") from e
    except RuntimeError as e:
        raise HTTPException(503, str(e)) from e
    finally:
        if not disconnect_task.done():
            disconnect_task.cancel()
            await asyncio.gather(disconnect_task, return_exceptions=True)


class ConfirmIn(BaseModel):
    table: str
    id: str
    status: str = "CONFIRMED"
    reason: str = "사람 확인"


@router.post("/links/confirm")
def links_confirm(body: ConfirmIn, authorization: Optional[str] = Header(None)):
    who = _admin(authorization)
    if body.table not in ("process_run_lot", "material_usage", "inspection_lot", "production_lot"):
        raise HTTPException(400, "table 은 process_run_lot / material_usage / inspection_lot / production_lot 중 하나")
    reason = body.reason if body.reason.startswith("[") else f"[LOT 연결] 연결 확인 · {body.table} → {body.status} · {body.reason}"
    return _wrap(_repo().link_confirm, body.table, body.id, body.status, reason, _actor(who))


# ---------------------------------------------------------------- AI
class ChatIn(BaseModel):
    """두 가지 요청 모양을 받는다. (1) 표 화면: {question, history} (2) 전체흐름 대시보드(M1-2 계약): {message, conversation_id, context}"""
    question: Optional[str] = None
    message: Optional[str] = None
    history: list[dict[str, Any]] = []
    conversation_id: Optional[str] = None
    context: dict[str, Any] = {}


_conversations: dict[str, list[dict[str, Any]]] = {}   # conversation_id -> 최근 대화(서버 메모리, 재시작하면 비워짐)


@router.post("/chat")
def chat(body: ChatIn):
    q = (body.message or body.question or "").strip()
    if not q or len(q) > 4000:
        raise HTTPException(400, "질문은 1~4000자")
    cid = body.conversation_id or uuid.uuid4().hex
    history = body.history or _conversations.get(cid, [])
    out = agent_chat(_repo(), history, q)
    _conversations[cid] = (history + [{"role": "user", "content": q}, {"role": "assistant", "content": out.get("answer", "")}])[-20:]
    if len(_conversations) > 500:
        _conversations.pop(next(iter(_conversations)))
    vm = re.search(r"\b(HSV|OV|IV)\b", q.upper())
    ctx: dict[str, Any] = {"variant": vm.group(1)} if vm else {}
    # 사출조건 도구를 썼으면 같은 LOT 기준으로 사출 단계 그래프를 열도록 알려 준다.
    inj = [c for c in out.get("tool_calls", []) if c.get("tool") == "get_injection_conditions" and not c.get("error")]
    if inj:
        ctx["injection"] = {"lot": inj[-1]["input"].get("lot_code") or "", "model": inj[-1]["input"].get("model") or ""}
    return {**out, "conversation_id": cid, "storage": "supabase",
            "ai_provider": "ANTHROPIC_CLAUDE" if out.get("model") else "FALLBACK_AI_ERROR",
            "graph_context": ctx}


# ---------------------------------------------------------------- 전체흐름(피시본) 대시보드 데이터 (M1-2 화면 계약 그대로, 데이터만 mqi)
@router.get("/data")
def fishbone_data(response: Response):
    rows = _wrap(_repo().fishbone_rows)
    response.headers["X-Data-Source"] = "supabase"
    response.headers["X-Data-Source-Info"] = json.dumps({"record_count": len(rows), "schema": settings.schema}, ensure_ascii=False)
    return to_rows(rows)


@router.get("/workbook-evidence")
def workbook_evidence():
    return {"available": False, "note": "엑셀 보강 근거는 mqi 적재값에 이미 반영됨(전사본 = HUMAN_VERIFIED)"}


@router.get("/process-conditions")
def process_conditions(limit: int = Query(5000, ge=1, le=5000)):
    """사출(BB) 단계 클릭 화면의 조건 시계열. 대시보드의 다른 조회와 같이 공개 읽기(팀원 모두 열람)."""
    return _wrap(_repo().injection_condition_rows, limit)


class PositionRow(BaseModel):
    no: int
    lx: Optional[str] = None
    ly: Optional[str] = None
    rx: Optional[str] = None
    ry: Optional[str] = None


class PositionIn(BaseModel):
    model: str
    check_date: str
    rows: list[PositionRow]
    replace: bool = False
    source: dict[str, Any] = {}


@router.get("/position-checks")
def position_checks(model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$"), date_from: Optional[str] = Query(None, alias="from"),
                    date_to: Optional[str] = Query(None, alias="to")):
    """CA 초품 핀 위치도(판정은 DB 뷰가 기준값으로 계산). 대시보드 CA 화면용 공개 읽기."""
    return _wrap(_repo().position_checks, model, date_from, date_to)


@router.get("/position-spec")
def position_spec():
    """초품 위치도 판정 기준(모델별, DB 값)."""
    return _wrap(_repo().position_spec)


@router.post("/position")
def position_save(body: PositionIn, authorization: Optional[str] = Header(None)):
    """초품 위치도 1회 저장(quality_check 초품 + measurement). 같은 모델·날짜가 있으면 replace=true 일 때만 이전 기록 VOID."""
    who = _admin(authorization)
    p = body.model_dump()
    p["rows"] = [r for r in p["rows"] if any(r.get(k) for k in ("lx", "ly", "rx", "ry"))]
    p["actor"] = _actor(who)
    p["reason"] = _reason("IMEB3_CA_PRESS", "position", f"초품 위치도 {body.model} {body.check_date} 시료 {len(p['rows'])}개"
                          + (" (기존 기록 바꾸기)" if body.replace else ""))
    return _wrap(_repo().position_save, p)


@router.get("/admin/crud-history")
def crud_history(stage: Optional[str] = Query(None, max_length=40), actor: Optional[str] = Query(None, max_length=60),
                 limit: int = Query(3000, ge=1, le=20000), authorization: Optional[str] = Header(None)):
    """CRUD 이력: 팀 감사 테이블(mqi_audit.row_change)을 공정 단계로 풀어 저장 1회(트랜잭션) 단위로 묶어 보여 준다(로그인 필요)."""
    _admin(authorization)
    return _wrap(_repo().crud_history, stage or None, actor or None, limit)


@router.get("/admin/crud-history/{transaction_id}")
def crud_rows(transaction_id: int, authorization: Optional[str] = Header(None)):
    _admin(authorization)
    return _wrap(_repo().crud_rows, transaction_id)


@router.get("/process-conditions/window")
def process_condition_window(lot: Optional[str] = Query(None, max_length=40), model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$"),
                             all: bool = False):
    """사출 단계 화면의 LOT 순서 시계열. lot 을 주면 그 LOT 을 만든 사출 LOT 앞 4건 · 뒤 3건, 없으면 데이터가 있는 전체. all=true 면 전 조건 항목."""
    return _wrap(_repo().injection_window, lot or None, model, 4, 3, all)
