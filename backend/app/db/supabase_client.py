"""Supabase PostgREST 얇은 클라이언트 (httpx). supabase-py 없이 REST 와 RPC 만 쓴다.

- mqi 테이블 조회: Accept-Profile: mqi 헤더
- public 뷰·RPC: 헤더 없음
- 쓰기는 RPC(m13_journal_save 등)로만 한다. RPC 함수에 default_transaction_isolation=serializable 이 걸려 있어
  PostgREST 가 SERIALIZABLE 트랜잭션으로 실행한다 (mqi.write_guard 요구사항).
"""
from __future__ import annotations

from typing import Any

import httpx

from ..config import settings


class SupabaseError(RuntimeError):
    pass


class SupabaseClient:
    def __init__(self) -> None:
        if not settings.db_configured:
            raise SupabaseError("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 가 backend/.env.personal 에 없습니다.")
        self.base = settings.supabase_url.rstrip("/") + "/rest/v1"
        self.headers = {"apikey": settings.service_key, "Authorization": f"Bearer {settings.service_key}"}
        self.http = httpx.Client(timeout=60)

    def _raise(self, r: httpx.Response) -> None:
        if r.status_code >= 400:
            try:
                body = r.json()
                msg = body.get("message") or body.get("hint") or body
            except Exception:
                msg = r.text
            raise SupabaseError(f"Supabase {r.status_code}: {msg}")

    def select(self, table: str, params: dict[str, Any] | None = None, schema: str | None = None, limit: int | None = None) -> list[dict]:
        headers = dict(self.headers)
        if schema:
            headers["Accept-Profile"] = schema
        q = {"select": "*", **(params or {})}
        if limit:
            q["limit"] = str(limit)
        r = self.http.get(f"{self.base}/{table}", headers=headers, params=q)
        self._raise(r)
        return r.json()

    def rpc(self, fn: str, payload: dict[str, Any]) -> Any:
        r = self.http.post(f"{self.base}/rpc/{fn}", headers={**self.headers, "Content-Type": "application/json"}, json=payload)
        self._raise(r)
        return r.json() if r.content else None


_client: SupabaseClient | None = None


def get_client() -> SupabaseClient:
    global _client
    if _client is None:
        _client = SupabaseClient()
    return _client
