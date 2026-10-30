"""Supabase Auth 계정 관리 (개인 프로젝트 전용). 팀 프로젝트(clyjvqffabxpizkhydux)에는 쓰지 않는다.

  py tools/auth_admin.py list
  py tools/auth_admin.py create <email> [--password <pw>]     # 비밀번호를 안 주면 생성해서 출력
  py tools/auth_admin.py reset <email> --password <pw>
  py tools/auth_admin.py delete <email>

backend/.env.personal 의 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 를 읽는다 (GoTrue admin API).
"""
from __future__ import annotations

import argparse
import secrets
import string
import sys
from pathlib import Path

import httpx
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[1]
TEAM_REF = "clyjvqffabxpizkhydux"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["list", "create", "reset", "delete"])
    ap.add_argument("email", nargs="?")
    ap.add_argument("--password")
    ap.add_argument("--env", default="personal")
    a = ap.parse_args()
    env = dotenv_values(ROOT / "backend" / f".env.{a.env}")
    url, key = (env.get("SUPABASE_URL") or "").rstrip("/"), env.get("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not url or not key:
        print("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 없음", file=sys.stderr)
        return 2
    if TEAM_REF in url:
        print("팀 프로젝트에는 계정을 만들지 않습니다 (AGENTS.md).", file=sys.stderr)
        return 2
    h = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    c = httpx.Client(base_url=f"{url}/auth/v1/admin", headers=h, timeout=20)

    def users() -> list[dict]:
        r = c.get("/users", params={"per_page": 200})
        r.raise_for_status()
        return r.json().get("users", [])

    def find(email: str) -> dict | None:
        return next((u for u in users() if (u.get("email") or "").casefold() == email.casefold()), None)

    if a.cmd == "list":
        for u in users():
            print(f"{u['email']:40} confirmed={bool(u.get('email_confirmed_at'))} last_sign_in={u.get('last_sign_in_at')}")
        return 0
    if not a.email:
        print("email 필요", file=sys.stderr)
        return 2
    if a.cmd == "create":
        if find(a.email):
            print("이미 있음:", a.email)
            return 1
        pw = a.password or "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16))
        r = c.post("/users", json={"email": a.email, "password": pw, "email_confirm": True})
        if r.status_code >= 400:
            print("실패:", r.status_code, r.text, file=sys.stderr)
            return 1
        print(f"생성됨: {a.email}\n초기 비밀번호: {pw}\n(최소 12자. 로그인 후 바꿀 수 있음)")
        return 0
    u = find(a.email)
    if not u:
        print("없음:", a.email)
        return 1
    if a.cmd == "reset":
        if not a.password or len(a.password) < 6:
            print("--password 6자 이상 필요(Supabase 기본 최소 길이)", file=sys.stderr)
            return 2
        r = c.put(f"/users/{u['id']}", json={"password": a.password})
        print("비밀번호 변경" if r.status_code < 400 else f"실패 {r.status_code} {r.text}")
        return 0 if r.status_code < 400 else 1
    r = c.delete(f"/users/{u['id']}")
    print("삭제됨" if r.status_code < 400 else f"실패 {r.status_code} {r.text}")
    return 0 if r.status_code < 400 else 1


if __name__ == "__main__":
    sys.exit(main())
