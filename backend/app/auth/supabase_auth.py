"""Supabase Auth(GoTrue) 로그인 게이트.

팀 저장소 M3-1 `apps/rawdata_workspace/auth.py`(이*규) 의 방식을 FastAPI 에 맞게 옮긴 것.
- 브라우저용 publishable(anon) 키만 쓴다. service_role 키는 인증에 쓰지 않는다.
- MQI_ALLOWED_EMAILS 에 적힌 이메일만 통과한다. 비어 있으면 아무도 통과하지 못한다.
- 토큰은 서버(GoTrue /user)에서 검증한다. JWT 본문을 믿지 않는다.
- 대상 Supabase 프로젝트는 SUPABASE_URL 과 같다. 팀 DB 로 바꾸면 팀 Auth 계정(4명)으로 그대로 로그인된다.
"""
from __future__ import annotations

import time
from typing import Any

import httpx

from ..config import settings


class AuthError(Exception):
    """사용자에게 그대로 보여도 되는 인증 오류."""


_ALLOWED_PATHS = {"token?grant_type=password", "token?grant_type=refresh_token", "user", "logout?scope=local"}
_http = httpx.Client(timeout=15)
_cache: dict[str, tuple[float, dict[str, Any]]] = {}  # access_token -> (expires, user) 짧은 캐시
_CACHE_TTL = 60.0


def configured() -> bool:
    return bool(settings.supabase_url and settings.anon_key)


def allowed_user(user: dict[str, Any]) -> bool:
    emails = settings.allowed_emails
    email = user.get("email")
    return bool(emails and user.get("id") and isinstance(email, str) and email.strip().casefold() in emails
                and not user.get("is_anonymous", False) and not user.get("banned_until") and not user.get("deleted_at"))


def _request(method: str, path: str, *, payload: dict[str, Any] | None = None, access_token: str | None = None) -> dict[str, Any]:
    if path not in _ALLOWED_PATHS:
        raise AuthError("지원하지 않는 인증 요청입니다.")
    if not configured():
        raise AuthError("SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY 가 설정되지 않아 로그인할 수 없습니다.")
    headers = {"apikey": settings.anon_key, "Accept": "application/json"}
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    try:
        r = _http.request(method, f"{settings.supabase_url.rstrip('/')}/auth/v1/{path}", headers=headers, json=payload)
    except (httpx.HTTPError, OSError) as e:
        raise AuthError("Supabase 인증 서버에 연결할 수 없습니다.") from e
    if r.status_code >= 400:
        raise AuthError("인증 요청이 거부되었습니다. 이메일·비밀번호 또는 인증 설정을 확인하세요.")
    if not r.content:
        return {}
    try:
        body = r.json()
    except ValueError as e:
        raise AuthError("인증 서버 응답 형식이 올바르지 않습니다.") from e
    if not isinstance(body, dict):
        raise AuthError("인증 서버 응답 형식이 올바르지 않습니다.")
    return body


def _session(result: dict[str, Any]) -> dict[str, Any]:
    access, refresh = result.get("access_token"), result.get("refresh_token")
    if not isinstance(access, str) or not access or not isinstance(refresh, str) or not refresh:
        raise AuthError("유효한 로그인 세션을 받지 못했습니다.")
    try:
        expires_at = int(result.get("expires_at") or time.time() + int(result.get("expires_in") or 3600))
    except (TypeError, ValueError) as e:
        raise AuthError("로그인 세션 만료 정보를 확인할 수 없습니다.") from e
    return {"access_token": access, "refresh_token": refresh, "expires_at": expires_at}


def verify_user(access_token: str) -> dict[str, Any]:
    """토큰을 GoTrue 에서 검증하고 허용 목록을 확인한다. 통과하면 user dict."""
    hit = _cache.get(access_token)
    if hit and hit[0] > time.time():
        return hit[1]
    user = _request("GET", "user", access_token=access_token)
    if not user.get("id") or not user.get("email"):
        raise AuthError("인증된 사용자 정보를 확인할 수 없습니다.")
    if not allowed_user(user):
        raise AuthError("허용된 팀원 계정이 아닙니다. MQI_ALLOWED_EMAILS 를 확인하세요.")
    slim = {"id": user["id"], "email": user["email"]}
    _cache[access_token] = (time.time() + _CACHE_TTL, slim)
    if len(_cache) > 200:
        for k in [k for k, v in _cache.items() if v[0] <= time.time()]:
            _cache.pop(k, None)
    return slim


def sign_in(email: str, password: str) -> dict[str, Any]:
    email = (email or "").strip().casefold()
    if not email or not password:
        raise AuthError("이메일과 비밀번호를 입력하세요.")
    if email not in settings.allowed_emails:
        raise AuthError("허용된 팀원 계정이 아닙니다.")
    result = _request("POST", "token?grant_type=password", payload={"email": email, "password": password})
    session = _session(result)
    user = verify_user(session["access_token"])
    return {**session, "user": user}


def refresh(refresh_token: str) -> dict[str, Any]:
    if not refresh_token:
        raise AuthError("로그인 세션이 없습니다.")
    result = _request("POST", "token?grant_type=refresh_token", payload={"refresh_token": refresh_token})
    session = _session(result)
    user = verify_user(session["access_token"])
    return {**session, "user": user}


def sign_out(access_token: str) -> None:
    _cache.pop(access_token, None)
    try:
        _request("POST", "logout?scope=local", access_token=access_token)
    except AuthError:
        pass  # 서버 세션 폐기 실패해도 브라우저 쪽은 지운다
