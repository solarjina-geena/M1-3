"""HTTP API. 읽기는 누구나. 쓰기(/api/journal*, /api/links/confirm)는
- Supabase Auth 로그인 토큰(허용 이메일 목록 통과) 또는
- ADMIN_API_TOKEN(로컬·비상용)
중 하나를 Authorization: Bearer 로 보내야 한다. 둘 다 설정돼 있지 않으면 로컬 개방."""
from __future__ import annotations

from typing import Any, Optional

import json
import re
import uuid

from fastapi import APIRouter, File, Header, HTTPException, Query, UploadFile
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


@router.post("/journal")
def journal_save(payload: JournalPayload, authorization: Optional[str] = Header(None)):
    _admin(authorization)
    return _wrap(_repo().journal_save, payload.normalized())


class BatchIn(BaseModel):
    items: list[JournalPayload]


@router.post("/journal/batch")
def journal_batch(body: BatchIn, authorization: Optional[str] = Header(None)):
    _admin(authorization)
    repo = _repo()
    results = []
    for i, p in enumerate(body.items):
        try:
            results.append({"index": i, "ok": True, "result": repo.journal_save(p.normalized())})
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


@router.post("/journal/preview-image")
async def journal_preview_image(file: UploadFile = File(...)):
    data = await file.read()
    name = (file.filename or "image").lower()
    media = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp", "gif": "image/gif", "pdf": "application/pdf"}.get(name.rsplit(".", 1)[-1])
    if not media:
        raise HTTPException(400, "jpg/png/webp/gif/pdf 만 받습니다")
    try:
        return {"file": file.filename, **extract_from_image(data, media, file.filename or "image")}
    except RuntimeError as e:
        raise HTTPException(503, str(e)) from e


class ConfirmIn(BaseModel):
    table: str
    id: str
    status: str = "CONFIRMED"
    reason: str = "사람 확인"


@router.post("/links/confirm")
def links_confirm(body: ConfirmIn, authorization: Optional[str] = Header(None)):
    _admin(authorization)
    if body.table not in ("process_run_lot", "material_usage", "inspection_lot", "production_lot"):
        raise HTTPException(400, "table 은 process_run_lot / material_usage / inspection_lot / production_lot 중 하나")
    return _wrap(_repo().link_confirm, body.table, body.id, body.status, body.reason)


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
    vm = re.search(r"(HSV|OV|IV)", q.upper())
    return {**out, "conversation_id": cid, "storage": "supabase",
            "ai_provider": "ANTHROPIC_CLAUDE" if out.get("model") else "FALLBACK_AI_ERROR",
            "graph_context": {"variant": vm.group(1)} if vm else {}}


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
def process_conditions(limit: int = 5000):
    return []   # 사출조건(parameter_observation) 적재 전. 적재되면 여기서 뷰로 돌려준다
