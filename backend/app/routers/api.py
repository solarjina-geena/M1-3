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
from ..ingest import injection_sheet
from ..ingest import bobbin_position
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


@router.get("/defects/quantity-status")
def defect_quantity_status(process: str, model: Optional[str] = None, date_from: Optional[str] = Query(None, alias="from"), date_to: Optional[str] = Query(None, alias="to")):
    if process not in PROCESS_LABEL:
        raise HTTPException(404, "공정 코드 아님: " + process)
    return _wrap(_repo().defect_quantity_status, process, model, date_from, date_to)


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


def _mark_existing(items: list[dict]) -> list[dict]:
    """미리보기 항목마다 '이미 저장된 일보인지' 표시(저장 시 '기존 기록 바꾸기'를 켜야 덮어씀)."""
    try:
        repo = get_repository()
    except SupabaseError:
        return items
    for it in items:
        if it.get("ok") and it.get("normalized"):
            try:
                it["exists"] = repo.journal_exists(it["normalized"])
            except SupabaseError:
                it["exists"] = None
    return items


@router.post("/journal/preview")
def journal_preview(payload: JournalPayload):
    """쓰지 않고 정규화 결과만 돌려준다(화면 미리보기)."""
    return {"payload": payload.model_dump(), "normalized": payload.normalized()}


STAGE_LABEL = {"IMEB3_INJECTION": "사출", "IMEB3_STITCHING": "스티칭", "IMEB3_WINDING": "권선(BA)", "IMEB3_CA_PRESS": "압입(CA)",
               "IMEB3_FINAL_INSPECTION": "최종검사"}
VIA_LABEL = {"reinspection": "재검사 입력", "judgment": "판단 카드", "form": "직접 입력", "file": "엑셀·CSV", "image": "사진 OCR", "gaps": "사슬 보완", "confirm": "연결 확인", "position": "위치도 붙여넣기", "injection": "사출조건 체크시트", "bobbin": "보빈 위치도 엑셀"}


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
        return {"file": name, "items": _mark_existing(excel_csv.parse_excel(data, name))}
    if name.lower().endswith(".csv"):
        return {"file": name, "items": _mark_existing(excel_csv.parse_csv(data, name))}
    raise HTTPException(400, "xlsx 또는 csv 파일만 받습니다")


async def _wait_for_disconnect(request: Request) -> None:
    while not await request.is_disconnected():
        await asyncio.sleep(0.25)


# ---------------------------------------------------------------- 판독 실행 기록(결과보고서 비교표, 2026-11-07 사용자 요청)
KIND_LABEL = {"INJECTION": "사출 작업일보", "STITCHING": "BS 작업일보", "ASSEMBLY": "조립 작업일보", "FINAL_INSPECTION": "최종검사 작업일보",
              "REINSPECTION": "재검사 비고", "INJECTION_SHEET": "사출조건 체크시트", "BOBBIN_POSITION": "보빈 위치도 엑셀", "JOURNAL": "작업일보(종류 미선택)"}


def _log_call(who: dict | None, kind: str, method: str, data: bytes | None, name: str, mime: str, t0: float, ok: bool,
              usage: dict | None = None, items: int | None = None, blocks: int | None = None, error: str | None = None, text: str | None = None) -> None:
    """판독 1회를 DB(extraction_run 사슬)에 남긴다. 실패해도 판독 결과에는 영향 없음."""
    import datetime as _dt
    import hashlib as _hl
    import time as _t
    try:
        raw = data if data is not None else (text or "").encode("utf-8")
        _repo().ai_call_log({
            "kind": kind, "method": method, "model": settings.anthropic_model if method == "VISION_LLM" else None,
            "parser": "backend/app/ingest" if method != "VISION_LLM" else None,
            "started_at": _dt.datetime.fromtimestamp(t0, _dt.timezone.utc).isoformat(), "seconds": round(_t.time() - t0, 2), "ok": ok,
            "input_tokens": (usage or {}).get("input_tokens"), "output_tokens": (usage or {}).get("output_tokens"),
            "items": items, "blocks": blocks, "error": (error or "")[:300] or None,
            "file": {"name": name[:150], "sha256": _hl.sha256(raw).hexdigest(), "size": len(raw), "mime": mime},
            "actor": _actor(who) if who else None, "reason": f"[공통] 판독 실행 기록 · {KIND_LABEL.get(kind, kind)} · {name[:60]}"})
    except Exception:  # 기록 실패는 무시
        pass


@router.get("/admin/ai-calls")
def ai_calls(authorization: Optional[str] = Header(None)):
    """판독 실행 기록: 문서 종류별 횟수·평균 토큰·평균 시간·모델(보고서 비교표) + 최근 기록."""
    _admin(authorization)
    rows = _wrap(_repo().ai_calls)
    for r in rows:
        r["kind_label"] = KIND_LABEL.get(r.get("kind") or "", r.get("kind"))
    groups: dict[tuple, dict] = {}
    for r in rows:
        g = groups.setdefault((r["kind"], r["method"], r["model"]), {"kind": r["kind"], "kind_label": r["kind_label"], "method": r["method"], "model": r["model"],
                                                                   "calls": 0, "ok": 0, "in": [], "out": [], "sec": [], "items": []})
        g["calls"] += 1
        if r["status"] == "COMPLETED":
            g["ok"] += 1
            if r.get("input_tokens") is not None: g["in"].append(r["input_tokens"])
            if r.get("output_tokens") is not None: g["out"].append(r["output_tokens"])
            if r.get("seconds") is not None: g["sec"].append(float(r["seconds"]))
            if r.get("items") is not None or r.get("blocks") is not None: g["items"].append(r.get("items") if r.get("items") is not None else r.get("blocks"))
    avg = lambda xs: round(sum(xs) / len(xs), 1) if xs else None
    summary = [{k: v for k, v in g.items() if k not in ("in", "out", "sec", "items")} | {
        "avg_input_tokens": avg(g["in"]), "avg_output_tokens": avg(g["out"]), "avg_total_tokens": avg([a + b for a, b in zip(g["in"], g["out"])]),
        "sum_input_tokens": sum(g["in"]), "sum_output_tokens": sum(g["out"]),
        "avg_seconds": avg(g["sec"]), "min_seconds": min(g["sec"]) if g["sec"] else None, "max_seconds": max(g["sec"]) if g["sec"] else None,
        "avg_items": avg(g["items"])} for g in groups.values()]
    return {"summary": sorted(summary, key=lambda x: (x["method"] != "VISION_LLM", x["kind"] or "")), "rows": rows[:300], "total": len(rows)}


@router.post("/journal/preview-image")
async def journal_preview_image(request: Request, file: UploadFile = File(...), authorization: Optional[str] = Header(None),
                                kind: Optional[str] = Query(None, pattern="^(INJECTION|STITCHING|ASSEMBLY|FINAL_INSPECTION)$"),
                                page: Optional[int] = Query(None, ge=1, le=80)):
    """여러 쪽 PDF 는 한 번에 보내지 않는다(2026-11-07: 최종검사 일보 PDF 6~11쪽 → 시간·길이 제한 초과).
    page 없이 오면 쪽수만 돌려주고(Claude 호출 없음), 화면이 page=1..n 으로 한 쪽씩 다시 부른다."""
    who = _admin(authorization)  # Anthropic 사용량이 드는 요청이므로 로그인(또는 관리자 토큰) 없이는 받지 않는다
    import time as _t
    t0 = _t.time()
    data = await file.read()
    name = (file.filename or "image").lower()
    media = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp", "gif": "image/gif", "pdf": "application/pdf"}.get(name.rsplit(".", 1)[-1])
    if not media:
        raise HTTPException(400, "jpg/png/webp/gif/pdf 만 받습니다")
    label = file.filename or "image"
    if media == "application/pdf":
        import io
        from pypdf import PdfReader, PdfWriter
        try:
            reader = PdfReader(io.BytesIO(data))
            n = len(reader.pages)
        except Exception as e:
            raise HTTPException(400, f"PDF 를 열지 못했습니다: {e}")
        if n > 1 and page is None:
            return {"file": file.filename, "pdf_pages": n, "need_pages": True, "items": [], "document_type": "UNKNOWN", "uncertain_notes": [],
                    "usage": {"input_tokens": 0, "output_tokens": 0}}
        if page is not None:
            if page > n:
                raise HTTPException(400, f"PDF 는 {n}쪽입니다")
            w = PdfWriter(); w.add_page(reader.pages[page - 1]); buf = io.BytesIO(); w.write(buf); data = buf.getvalue()
            label = f"{file.filename or 'pdf'} p{page}"
    ocr_task = asyncio.create_task(extract_from_image(data, media, file.filename or "image", kind))
    disconnect_task = asyncio.create_task(_wait_for_disconnect(request))
    try:
        done, _ = await asyncio.wait({ocr_task, disconnect_task}, return_when=asyncio.FIRST_COMPLETED)
        if ocr_task in done:
            disconnect_task.cancel()
            await asyncio.gather(disconnect_task, return_exceptions=True)
            try:
                out = await ocr_task
            except Exception as e:
                await asyncio.to_thread(_log_call, who, kind or "JOURNAL", "VISION_LLM", data, label, media, t0, False, error=str(e))
                raise
            if page is not None:
                for it in out.get("items") or []:
                    if it.get("ok") and isinstance(it.get("payload"), dict):
                        it["payload"].setdefault("source", {})["page"] = page
            out["items"] = _mark_existing(out.get("items") or [])
            await asyncio.to_thread(_log_call, who, kind or "JOURNAL", "VISION_LLM", data, label, media, t0, True,
                                    usage=out.get("usage"), items=len(out.get("items") or []))
            return {"file": file.filename, "page": page, **out}
        await asyncio.to_thread(_log_call, who, kind or "JOURNAL", "VISION_LLM", data, label, media, t0, False, error="브라우저가 판독을 중단함")
        ocr_task.cancel()
        await asyncio.gather(ocr_task, return_exceptions=True)
        return Response(status_code=499)
    except anthropic.AuthenticationError as e:
        raise HTTPException(502, "Anthropic API 키 인증에 실패했습니다.") from e
    except anthropic.RateLimitError as e:
        raise HTTPException(429, "Anthropic API 한도 또는 요청 제한에 도달했습니다.") from e
    except anthropic.APITimeoutError as e:
        raise HTTPException(504, "OCR 요청이 제한 시간(150초) 안에 끝나지 않았습니다. 사진을 한 쪽씩 올리거나 크기를 줄여 다시 시도해 주세요.") from e
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
    remeasure: bool = False               # 같은 날 재측정(불량 → 수정 → 다시 측정): 이전 측정은 두고 측정 순번 +1, 특이사항 필수
    source: dict[str, Any] = {}
    note: Optional[str] = None            # 특이사항(예: 2차라인 용접툴 교체 이후 · 용접봉 6축 중 1번 측정)
    event: bool = False                   # 특이사항을 생산 이벤트로도(그날 CA 실행이 있을 때만)
    event_type: Optional[str] = None      # SETUP_CHANGE / MAINTENANCE / MATERIAL_CHANGE / OTHER


@router.get("/position-checks")
def position_checks(model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$"), date_from: Optional[str] = Query(None, alias="from"),
                    date_to: Optional[str] = Query(None, alias="to")):
    """CA 초품 핀 위치도(판정은 DB 뷰가 기준값으로 계산). 대시보드 CA 화면용 공개 읽기."""
    return _wrap(_repo().position_checks, model, date_from, date_to)


@router.get("/position-spec")
def position_spec():
    """초품 위치도 판정 기준(모델별, DB 값)."""
    return _wrap(_repo().position_spec)


@router.get("/position-entries")
def position_entries(model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$")):
    """입력된 초품 위치도 목록(날짜·모델별 1행, 판정 집계)."""
    return _wrap(_repo().position_entries, model)


class PositionVoidIn(BaseModel):
    check_id: str
    note: str


# ---------------------------------------------------------------- 사출조건 체크시트 (IV·OV·HSV 같은 양식)
# 미리보기에서 읽은 결과를 해시로 잠깐 들고 있다가 저장 때 쓴다(무거운 엑셀을 두 번 올리지 않게). 서버 1대(Render) 기준.
_INJ_CACHE: dict[str, dict] = {}
INJ_MAX_BYTES = 30 * 1024 * 1024


@router.post("/injection-sheet/preview")
async def injection_sheet_preview(file: UploadFile = File(...), model: str = Query(..., pattern="^(IV|OV|HSV)$"),
                                  authorization: Optional[str] = Header(None)):
    """체크시트 엑셀을 읽어 탭(= 보빈 LOT)별 실측 수·양식 검사·기준 차이를 돌려준다. 이미지는 읽지 않는다."""
    who = _admin(authorization)
    import time as _t
    t0 = _t.time()
    name = _fix_name(file.filename or "upload.xlsx")
    if not name.lower().endswith((".xlsx", ".xlsm")):
        raise HTTPException(400, "xlsx 파일만 받습니다(.xls 는 엑셀에서 xlsx 로 저장해 주세요)")
    data = await file.read()
    if len(data) > INJ_MAX_BYTES:
        raise HTTPException(400, f"파일이 너무 큽니다({len(data) // 1048576}MB). 30MB 이하로 — 사진 탭을 지운 사본을 쓰세요")
    try:
        res = await asyncio.to_thread(injection_sheet.read_workbook, data, name, model)
    except Exception as e:  # 엑셀이 아닌 파일 등
        raise HTTPException(400, f"엑셀을 읽지 못했습니다: {e}")
    await asyncio.to_thread(_log_call, who, "INJECTION_SHEET", "EXCEL_PARSER", data, name, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", t0, True,
                            items=sum(len(t["obs"]) for t in res["tabs"]), blocks=len(res["tabs"]))
    existing = {(s["model_code"], s["tab"]) for s in _repo().injection_sheets(model)}
    for t in res["tabs"]:
        t["exists"] = (model, t["tab"]) in existing
    if len(_INJ_CACHE) > 6:
        _INJ_CACHE.pop(next(iter(_INJ_CACHE)))
    _INJ_CACHE[res["sha256"] + ":" + model] = res
    out = {k: v for k, v in res.items() if k != "params"}
    out["tabs"] = [{k: v for k, v in t.items() if k != "obs"} | {"sample": _inj_sample(t["obs"])} for t in res["tabs"]]
    return out


def _fix_name(name: str) -> str:
    """한글 파일명이 multipart 에서 latin-1 로 풀려 깨진 경우(UTF-8 바이트) 되돌린다."""
    try:
        raw = name.encode("latin-1")
    except UnicodeEncodeError:
        return name                      # 이미 제대로 풀린 이름
    for enc in ("utf-8", "cp949"):       # 브라우저는 UTF-8, Windows 도구는 cp949 로 보낸다
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            pass
    return name


def _inj_sample(obs: list[dict]) -> list[dict]:
    """미리보기 표용 대표 항목(우선 인자): 사출1 압력·보압·전환위치·쿠션·노즐 온도·보빈무게."""
    want = ["INJ_PRESS_S1", "INJ_PRESS_HOLD1", "MON_SWITCH_POS_START", "INJ_CUSHION", "INJ_TEMP_NZ", "BOBBIN_WEIGHT"]
    return [o for c in want for o in obs if o["code"] == c]


class InjSheetIn(BaseModel):
    sha256: str
    model: str
    tabs: list[str]
    replace: bool = False


@router.post("/injection-sheet")
def injection_sheet_save(body: InjSheetIn, authorization: Optional[str] = Header(None)):
    """미리보기한 체크시트에서 고른 탭을 저장(실측·출처·사출 실행 FK). 같은 모델·탭이 있으면 replace=true 일 때만 이전 것을 VOID."""
    who = _admin(authorization)
    res = _INJ_CACHE.get(body.sha256 + ":" + body.model)
    if not res:
        raise HTTPException(409, "미리보기 결과가 없습니다(서버가 다시 시작됨). 파일을 다시 미리보기 해 주세요")
    tabs = [t for t in res["tabs"] if t["tab"] in set(body.tabs) and not t["problem"]]
    if not tabs:
        raise HTTPException(400, "저장할 탭이 없습니다(양식 문제가 있는 탭은 저장하지 않습니다)")
    payload = {"model": body.model, "replace": body.replace,
               "file": {"name": res["file"], "sha256": res["sha256"], "size": res["size"]},
               "params": {k: list(v) for k, v in res["params"].items()},
               "tabs": [{k: t[k] for k in ("tab", "lot", "date", "shift", "title", "spec_doc", "spec_rev", "specs", "obs", "night_obs")} for t in tabs],
               "actor": _actor(who),
               "reason": _reason("IMEB3_INJECTION", "injection", f"사출조건 체크시트 {body.model} {len(tabs)}장 ({', '.join(t['lot'] for t in tabs)[:120]})"
                                 + (" (기존 기록 바꾸기)" if body.replace else ""))}
    return _wrap(_repo().injection_sheet_save, payload)


@router.get("/injection-sheets")
def injection_sheets(model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$")):
    return _wrap(_repo().injection_sheets, model)


class InjVoidIn(BaseModel):
    document_id: str
    note: str


@router.post("/injection-sheet/void")
def injection_sheet_void(body: InjVoidIn, authorization: Optional[str] = Header(None)):
    who = _admin(authorization)
    note = body.note.strip()
    if not 5 <= len(note) <= 300 or _PII.search(note):
        raise HTTPException(400, "삭제 사유는 5~300자, 이메일·전화번호 형태 금지")
    return _wrap(_repo().injection_sheet_void, {"document_id": body.document_id, "note": note, "actor": _actor(who),
                                                "reason": _reason("IMEB3_INJECTION", "injection", f"사출조건 탭 삭제(VOID) · {note}")})


# ---------------------------------------------------------------- 사출 보빈 초품 위치도 (월별 엑셀, 모델별 시트)
_BB_CACHE: dict[str, dict] = {}


@router.post("/bobbin-position/preview")
async def bobbin_position_preview(file: UploadFile = File(...), authorization: Optional[str] = Header(None)):
    """보빈 초품 위치도 엑셀을 읽어 값이 든 블록(모델·날짜·주야·캐비티 16 × 좌우)을 돌려준다. 빈 양식은 건너뛰고 복사본은 표시."""
    who = _admin(authorization)
    import time as _t
    t0 = _t.time()
    name = _fix_name(file.filename or "upload.xlsx")
    if not name.lower().endswith((".xlsx", ".xlsm")):
        raise HTTPException(400, "xlsx 파일만 받습니다")
    data = await file.read()
    if len(data) > INJ_MAX_BYTES:
        raise HTTPException(400, "파일이 너무 큽니다(30MB 이하)")
    try:
        res = await asyncio.to_thread(bobbin_position.read_workbook, data, name)
    except Exception as e:
        raise HTTPException(400, f"엑셀을 읽지 못했습니다: {e}")
    await asyncio.to_thread(_log_call, who, "BOBBIN_POSITION", "EXCEL_PARSER", data, name, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", t0, True,
                            items=sum(len(b["rows"]) for b in res["blocks"]), blocks=len(res["blocks"]))
    have = {(e["model_code"], e["check_date"], e.get("shift")) for e in _repo().bobbin_position_entries()}
    for b in res["blocks"]:
        b["exists"] = (b["model"], b["date"], b["shift"]) in have
    if len(_BB_CACHE) > 6:
        _BB_CACHE.pop(next(iter(_BB_CACHE)))
    _BB_CACHE[res["sha256"]] = res
    return res


class BobbinTextIn(BaseModel):
    text: str
    model: Optional[str] = None
    date: Optional[str] = None
    shift: Optional[str] = None


@router.post("/bobbin-position/preview-text")
def bobbin_position_preview_text(body: BobbinTextIn, authorization: Optional[str] = Header(None)):
    """엑셀에서 복사해 붙여넣은 보빈 위치도 블록(제목 줄 포함이면 제목에서, 숫자 줄만이면 고른 모델·날짜·주야로)."""
    _admin(authorization)
    if len(body.text) > 400_000:
        raise HTTPException(400, "붙여넣은 내용이 너무 깁니다")
    model = body.model if body.model in ("IV", "OV", "HSV") else None
    date = body.date if body.date and re.fullmatch(r"\d{4}-\d{2}-\d{2}", body.date) else None
    res = bobbin_position.read_text(body.text, model, date, body.shift if body.shift in ("D", "N") else None)
    have = {(e["model_code"], e["check_date"], e.get("shift")) for e in _repo().bobbin_position_entries()}
    for b in res["blocks"]:
        b["exists"] = (b["model"], b["date"], b["shift"]) in have
    if len(_BB_CACHE) > 6:
        _BB_CACHE.pop(next(iter(_BB_CACHE)))
    _BB_CACHE[res["sha256"]] = res
    return res


class BobbinSaveIn(BaseModel):
    sha256: str
    keys: list[str]
    replace: bool = False
    notes: dict[str, str] = {}


@router.post("/bobbin-position")
def bobbin_position_save(body: BobbinSaveIn, authorization: Optional[str] = Header(None)):
    """미리보기한 블록 중 고른 것을 1블록 = 초품 1회로 저장(BB LOT 사출 실행에 FK). 블록마다 따로 저장해 결과를 돌려준다."""
    who = _admin(authorization)
    res = _BB_CACHE.get(body.sha256)
    if not res:
        raise HTTPException(409, "미리보기 결과가 없습니다(서버가 다시 시작됨). 파일을 다시 미리보기 해 주세요")
    pick = [b for b in res["blocks"] if b["key"] in set(body.keys) and not b["problem"]]
    if not pick:
        raise HTTPException(400, "저장할 블록이 없습니다")
    out = []
    for b in pick:
        note = (body.notes.get(b["key"]) or "").strip()[:500]
        if note and _PII.search(note):
            out.append({"key": b["key"], "ok": False, "error": "특이사항에 이메일·전화번호 형태 금지"}); continue
        p = {"model": b["model"], "check_date": b["date"], "shift": b["shift"], "label": b["label"], "replace": body.replace, "note": note or None,
             "rows": [{k: r[k] for k in ("no", "lx", "ly", "rx", "ry")} for r in b["rows"]],
             "source": {"file": res["file"], "sha256": res["sha256"], "sheet": b["sheet"], "cell": b["cell"], "entered_via": "manage.html 보빈 위치도"},
             "actor": _actor(who),
             "reason": _reason("IMEB3_INJECTION", "bobbin", f"보빈 초품 위치도 {b['model']} {b['date']} {b['shift'] or '주야 미기재'} 캐비티 {len(b['rows'])}개"
                               + (" (기존 기록 바꾸기)" if body.replace else ""))}
        try:
            r = _repo().bobbin_position_save(p)
            out.append({"key": b["key"], "ok": True, **r})
        except Exception as e:
            out.append({"key": b["key"], "ok": False, "error": str(getattr(e, "detail", None) or e)[:300]})
    return {"saved": sum(1 for o in out if o["ok"]), "results": out}


@router.get("/bobbin-position-checks")
def bobbin_position_checks(model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$"), date_from: Optional[str] = Query(None, alias="from"),
                           date_to: Optional[str] = Query(None, alias="to")):
    """사출 보빈 초품 위치도(대시보드 사출 화면용 공개 읽기). 판정은 DB 뷰가 기준값으로 계산."""
    return _wrap(_repo().bobbin_position_checks, model, date_from, date_to)


@router.get("/bobbin-position-entries")
def bobbin_position_entries(model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$")):
    return _wrap(_repo().bobbin_position_entries, model)


class BobbinVoidIn(BaseModel):
    check_id: str
    note: str


@router.post("/bobbin-position/void")
def bobbin_position_void(body: BobbinVoidIn, authorization: Optional[str] = Header(None)):
    who = _admin(authorization)
    note = body.note.strip()
    if not 5 <= len(note) <= 300 or _PII.search(note):
        raise HTTPException(400, "삭제 사유는 5~300자, 이메일·전화번호 형태 금지")
    return _wrap(_repo().bobbin_position_void, {"check_id": body.check_id, "note": note, "actor": _actor(who),
                                                "reason": _reason("IMEB3_INJECTION", "bobbin", f"보빈 초품 위치도 삭제(VOID) · {note}")})


@router.post("/position/void")
def position_void(body: PositionVoidIn, authorization: Optional[str] = Header(None)):
    """잘못 넣은 초품 위치도 1회를 삭제(VOID). 판단 카드로 이미 판단한 기록은 DB 가 거부."""
    who = _admin(authorization)
    note = body.note.strip()
    if not 5 <= len(note) <= 300 or _PII.search(note):
        raise HTTPException(400, "삭제 사유는 5~300자, 이메일·전화번호 형태 금지")
    return _wrap(_repo().position_void, {"check_id": body.check_id, "note": note, "actor": _actor(who),
                                         "reason": _reason("IMEB3_CA_PRESS", "position", f"초품 위치도 삭제(VOID) · {note}")})


@router.post("/position")
def position_save(body: PositionIn, authorization: Optional[str] = Header(None)):
    """초품 위치도 1회 저장(quality_check 초품 + measurement). 같은 모델·날짜가 있으면 replace=true 일 때만 이전 기록 VOID."""
    who = _admin(authorization)
    p = body.model_dump()
    p["rows"] = [r for r in p["rows"] if any(r.get(k) for k in ("lx", "ly", "rx", "ry"))]
    note = (body.note or "").strip()
    if len(note) > 500 or _PII.search(note):
        raise HTTPException(400, "특이사항은 500자 이내, 이메일·전화번호 형태 금지(사람 이름도 빼 주세요)")
    if body.event_type and body.event_type not in ("SETUP_CHANGE", "MAINTENANCE", "MATERIAL_CHANGE", "OTHER"):
        raise HTTPException(400, "이벤트 종류는 SETUP_CHANGE / MAINTENANCE / MATERIAL_CHANGE / OTHER")
    if body.remeasure and body.replace:
        raise HTTPException(400, "'같은 날 재측정'과 '기존 기록 바꾸기'는 함께 고를 수 없습니다")
    if body.remeasure and len(note) < 5:
        raise HTTPException(400, "같은 날 재측정은 특이사항(무엇을 수정하고 다시 쟀는지)을 5자 이상 적어 주세요")
    p["note"] = note or None
    p["actor"] = _actor(who)
    p["reason"] = _reason("IMEB3_CA_PRESS", "position", f"초품 위치도 {body.model} {body.check_date} 시료 {len(p['rows'])}개"
                          + (" (기존 기록 바꾸기)" if body.replace else "") + (" (같은 날 재측정)" if body.remeasure else "") + (f" · 특이사항: {note[:60]}" if note else ""))
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


# ---------------------------------------------------------------- 사람 판단 기록 ('확인 필요' 탭의 판단 카드)
KIND_DECISIONS = {"READ_VALUE": {"VERIFIED", "CORRECTED", "REJECTED"}, "INSPECTION_LOT": {"CONFIRMED", "UNRESOLVED", "VOID"},
                  "EVENT": {"VERIFIED", "REJECTED", "VOID"}, "POSITION": {"VERIFIED", "CORRECTED", "NEEDS_REVIEW"}}
BASIS_CODES = {"EXTRACTION_ERROR", "SOURCE_TYPO", "FORMAT_ERROR", "INCONSISTENT_SOURCE", "OTHER"}   # field_review.review_reason_code 허용값
_PII = re.compile(r"[0-9A-Za-z._%+-]+@[0-9A-Za-z.-]+\.[A-Za-z]{2,}|01[016789][- ]?\d{3,4}[- ]?\d{4}")


class ImageRef(BaseModel):
    sha256: str
    name: str = ""


class JudgmentIn(BaseModel):
    item_ids: list[str]                      # 1~20건(일괄 판단은 같은 결정·메모)
    decision: str
    note: str
    value: Optional[str] = None              # 정정값(판독값·이벤트 설명) / 위치도는 '좌우|시료|축|값'
    lot_code: Optional[str] = None           # 검사 LOT → CA LOT 연결 시 사람이 적은 LOT 코드
    basis_code: Optional[str] = None
    images: list[ImageRef] = []
    ai_suggestion: Optional[dict[str, Any]] = None


def _check_judgment(body: JudgmentIn) -> None:
    if not 1 <= len(body.item_ids) <= 20:
        raise HTTPException(400, "판단은 한 번에 1~20건")
    note = body.note.strip()
    if not 5 <= len(note) <= 500:
        raise HTTPException(400, "메모는 5~500자")
    if _PII.search(note):
        raise HTTPException(400, "메모에 이메일·전화번호 형태는 쓸 수 없습니다(실명도 적지 마세요)")
    if len(body.images) > 3 or any(not re.fullmatch(r"[0-9a-f]{64}", i.sha256) for i in body.images):
        raise HTTPException(400, "근거 이미지는 SHA-256 해시로 3개까지")
    if body.basis_code and body.basis_code not in BASIS_CODES:
        raise HTTPException(400, f"사유 코드는 {sorted(BASIS_CODES)} 중 하나")
    kinds = {i.split(":", 1)[0] for i in body.item_ids}
    if len(kinds) != 1 or not kinds <= set(KIND_DECISIONS):
        raise HTTPException(400, "일괄 판단은 같은 종류끼리만")
    if body.decision not in KIND_DECISIONS[kinds.pop()]:
        raise HTTPException(400, "이 종류에 쓸 수 없는 결정")


@router.get("/review-queue")
def review_queue(model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$"), stage: Optional[str] = Query(None, max_length=40),
                 lot: Optional[str] = Query(None, max_length=40)):
    """확인 필요 목록(공개 읽기). 판단 저장은 로그인 필요."""
    return _wrap(_repo().review_queue, model, stage, lot)


@router.get("/judgments")
def judgments(lot: Optional[str] = Query(None, max_length=40), kind: Optional[str] = Query(None, max_length=20),
              model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$"), limit: int = Query(200, ge=1, le=1000)):
    """판단 이력. 누가 판단했는지(actor)는 화면에 내보내지 않는다."""
    rows = _wrap(_repo().judgment_log, lot, kind, model, limit)
    for r in rows:
        r.pop("actor_ref", None)
    return rows


@router.post("/judgment")
def judgment_save(body: JudgmentIn, authorization: Optional[str] = Header(None)):
    who = _admin(authorization)
    _check_judgment(body)
    repo = _repo()
    results = []
    for item_id in body.item_ids:
        p = body.model_dump(exclude={"item_ids"})
        p.update(item_id=item_id, note=body.note.strip(), actor=_actor(who), images=[i.model_dump() for i in body.images])
        try:
            results.append({"item_id": item_id, "ok": True, "result": repo.judgment_save(p)})
        except SupabaseError as e:
            results.append({"item_id": item_id, "ok": False, "error": str(e)})
    return {"saved": sum(r["ok"] for r in results), "failed": sum(not r["ok"] for r in results), "results": results}


_suggest_calls: dict[str, list[float]] = {}


@router.post("/judgment/suggest")
def judgment_suggest(body: dict[str, Any], authorization: Optional[str] = Header(None)):
    """판단 카드의 'AI 제안': 같은 종류의 지난 판단을 근거로 Claude 가 결정 하나를 제안(저장은 사람이 결정). 사용자당 분당 5회."""
    import time
    from ..agent.claude_agent import suggest_judgment
    who = _admin(authorization)
    key = who.get("email") or who.get("via") or "anon"
    now = time.time()
    recent = [t for t in _suggest_calls.get(key, []) if now - t < 60]
    if len(recent) >= 5:
        raise HTTPException(429, "AI 제안은 1분에 5번까지입니다")
    _suggest_calls[key] = recent + [now]
    item_id = str(body.get("item_id") or "")
    items = [r for r in _wrap(_repo().review_queue) if r["item_id"] == item_id]
    if not items:
        raise HTTPException(404, "확인 필요 목록에 없는 항목")
    return suggest_judgment(_repo(), items[0])


# ---------------------------------------------------------------- 최종검사 재검사 (일보 비고란) 입력·삭제
class ReinspFinding(BaseModel):
    defect_code: Optional[str] = None
    name_raw: Optional[str] = None
    qty: Optional[int] = None


class ReinspLot(BaseModel):
    lot_code: str                          # CA 제품 LOT (사람이 고름)
    lot_code_raw: Optional[str] = None     # 비고 원문 마킹코드
    box_count: Optional[int] = None
    qty_ea: Optional[int] = None
    prior_run_id: str                      # 본검사 inspection_run_id 또는 'NONE'


class ReinspectionIn(BaseModel):
    model: str
    inspection_date: str
    method: str = "VISUAL_MANUAL"
    qty_ea: Optional[int] = None
    raw_note: str = ""
    lots: list[ReinspLot]
    findings: list[ReinspFinding] = []
    replace: bool = False
    source: dict[str, Any] = {}


class ReinspVoidIn(BaseModel):
    run_id: str
    note: str


@router.get("/reinspection/targets")
def reinspection_targets(model: str = Query(..., pattern="^(IV|OV|HSV)$")):
    """재검 대상 후보: 최종검사를 받은 CA 제품 LOT 과 본검사 목록."""
    return _wrap(_repo().reinspection_targets, model)


@router.get("/inspection-breakdown")
def inspection_breakdown(model: Optional[str] = None, date_from: Optional[str] = Query(None, alias="from"), date_to: Optional[str] = Query(None, alias="to")):
    """최종검사 검사 구분별(1차·2차·재검) 집계 + 재검 LOT 별 수량·불량. 재검은 본검사 합계에 넣지 않는다."""
    return _wrap(_repo().inspection_breakdown, model if model in ("IV", "OV", "HSV") else None, date_from or None, date_to or None)


@router.get("/reinspections")
def reinspections(model: Optional[str] = Query(None, pattern="^(IV|OV|HSV)$"), limit: int = Query(300, ge=1, le=2000)):
    return _wrap(_repo().reinspections, model, limit)


@router.get("/defect-types/final")
def final_defect_types():
    return _wrap(_repo().final_defect_types)


@router.post("/reinspection")
def reinspection_save(body: ReinspectionIn, authorization: Optional[str] = Header(None)):
    """재검 1건 저장: inspection_run(REINSPECTION) + inspection_lot(CA LOT FK) + inspection_run_link(본검사 FK) + quality_finding."""
    who = _admin(authorization)
    if body.model not in ("IV", "OV", "HSV"):
        raise HTTPException(400, "모델은 IV/OV/HSV")
    if len(body.raw_note) > 1000 or _PII.search(body.raw_note or ""):
        raise HTTPException(400, "비고 원문은 1000자 이내, 이메일·전화번호 형태 금지(사람 이름도 빼 주세요)")
    if len(body.findings) > 30 or any((f.qty or 0) < 0 for f in body.findings):
        raise HTTPException(400, "불량은 30줄까지, 수량은 0 이상")
    if not 1 <= len(body.lots) <= 30 or any((x.box_count or 0) < 0 or (x.qty_ea or 0) < 0 for x in body.lots):
        raise HTTPException(400, "대상 LOT 은 1~30줄, BOX·수량은 0 이상")
    p = body.model_dump()
    p["actor"] = _actor(who)
    nd = sum(f.qty or 0 for f in body.findings)
    p["reason"] = _reason("IMEB3_FINAL_INSPECTION", "reinspection",
                          f"재검사 {body.model} {body.inspection_date} LOT {', '.join(x.lot_code for x in body.lots[:5])}{' 외 ' + str(len(body.lots) - 5) if len(body.lots) > 5 else ''}"
                          f" · 불량 {nd}EA" + (" (기존 기록 바꾸기)" if body.replace else ""))
    return _wrap(_repo().reinspection_save, p)


@router.post("/reinspection/void")
def reinspection_void(body: ReinspVoidIn, authorization: Optional[str] = Header(None)):
    """잘못 입력·중복 입력한 재검을 삭제(VOID). 재검·대상 LOT·본검사 연결·불량을 함께 VOID, 행은 지우지 않는다."""
    who = _admin(authorization)
    note = body.note.strip()
    if not 5 <= len(note) <= 300 or _PII.search(note):
        raise HTTPException(400, "삭제 사유는 5~300자, 이메일·전화번호 형태 금지")
    return _wrap(_repo().reinspection_void, {"run_id": body.run_id, "note": note, "actor": _actor(who),
                                             "reason": _reason("IMEB3_FINAL_INSPECTION", "reinspection", f"재검사 삭제(VOID) · {note}")})


_read_calls: dict[str, list[float]] = {}


@router.post("/reinspection/read-image")
async def reinspection_read_image(file: UploadFile = File(...), base_date: Optional[str] = Query(None, pattern=r"^\d{4}-\d{2}-\d{2}$"),
                                  authorization: Optional[str] = Header(None)):
    """비고란 캡처(화면에서 긴 변 1,568px JPEG 로 줄인 사본)를 Claude 가 읽는다. 로그인 필요, 사용자당 분당 5회, 5MB 이하. 원본은 보관하지 않는다."""
    import time
    from ..ingest.reinspection_image import read_reinspection_note
    who = _admin(authorization)
    key = who.get("email") or who.get("via") or "anon"
    now = time.time()
    recent = [t for t in _read_calls.get(key, []) if now - t < 60]
    if len(recent) >= 5:
        raise HTTPException(429, "AI 읽기는 1분에 5번까지입니다")
    _read_calls[key] = recent + [now]
    data = await file.read()
    if len(data) > 5 * 1024 * 1024:
        raise HTTPException(400, "이미지는 5MB 이하")
    media = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp"}.get((file.filename or "x.jpg").lower().rsplit(".", 1)[-1])
    if not media:
        raise HTTPException(400, "jpg/png/webp 이미지만 받습니다")
    from ..ingest.image import file_name_date
    fdate = file_name_date(file.filename)
    t0 = now
    try:
        out = await read_reinspection_note(data, media, base_date or fdate)
        await asyncio.to_thread(_log_call, who, "REINSPECTION", "VISION_LLM", data, file.filename or "image", media, t0, True,
                                usage=out.get("usage"), items=len(out.get("entries") or []))
        return {**out, "file_date": fdate, "base_date_used": base_date or fdate}
    except anthropic.APIError as e:
        await asyncio.to_thread(_log_call, who, "REINSPECTION", "VISION_LLM", data, file.filename or "image", media, t0, False, error=str(e))
        raise HTTPException(502, f"AI 호출 오류: {e}") from e
    except (RuntimeError, ValueError) as e:
        await asyncio.to_thread(_log_call, who, "REINSPECTION", "VISION_LLM", data, file.filename or "image", media, t0, False, error=str(e))
        raise HTTPException(503, str(e)) from e
