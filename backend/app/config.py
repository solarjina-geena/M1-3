"""환경 설정. backend/.env.<M13_ENV> 를 읽는다 (기본 personal). 팀 DB로 바꾸려면 M13_ENV=team 과 .env.team 만 추가."""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import dotenv_values

BACKEND_DIR = Path(__file__).resolve().parents[1]
ROOT = BACKEND_DIR.parent
FRONTEND_DIR = ROOT / "frontend"
TEAM_REF = "clyjvqffabxpizkhydux"


class Settings:
    def __init__(self) -> None:
        self.env_name = os.environ.get("M13_ENV", "personal")
        self.env_file = BACKEND_DIR / f".env.{self.env_name}"
        values = {**dotenv_values(self.env_file), **os.environ} if self.env_file.exists() else dict(os.environ)
        g = lambda k, d="": (values.get(k) or d).strip()
        self.supabase_ref = g("SUPABASE_PROJECT_REF")
        self.supabase_url = g("SUPABASE_URL", f"https://{self.supabase_ref}.supabase.co" if self.supabase_ref else "")
        self.service_key = g("SUPABASE_SERVICE_ROLE_KEY")
        self.anon_key = g("SUPABASE_PUBLISHABLE_KEY")
        self.schema = g("SUPABASE_SCHEMA", "mqi")
        self.anthropic_key = g("ANTHROPIC_API_KEY")
        self.anthropic_model = g("ANTHROPIC_MODEL", "claude-opus-5-5")
        self.admin_token = g("ADMIN_API_TOKEN")
        self.allowed_origins = [o.strip() for o in g("ALLOWED_ORIGINS", "http://127.0.0.1:8800,http://localhost:8800").split(",") if o.strip()]
        self.actor = g("M13_ACTOR", "m1-3-app")
        # 팀 Streamlit 앱과 같은 규칙: 허용 이메일 목록(쉼표 구분). 비어 있으면 Supabase 로그인은 아무도 통과 못 함.
        self.allowed_emails = frozenset(e.strip().casefold() for e in g("MQI_ALLOWED_EMAILS").split(",") if e.strip())
        self.public_url = g("PUBLIC_URL")  # 배포 주소(Render 등). 화면 표시용
        # 팀 OCR 검토·적재 앱(Streamlit, 이*규 작성, 팀 Supabase Auth 로그인). 관리자 입력 탭에서 연결한다.
        self.team_ocr_url = g("TEAM_OCR_APP_URL", "https://m3-1-rawdata-demo.onrender.com")
        # 팀 DB는 읽기만 (AGENTS.md). 쓰기 API 가 호출되면 거부한다.
        self.read_only = TEAM_REF in self.supabase_url or g("M13_READ_ONLY") == "1"

    @property
    def db_configured(self) -> bool:
        return bool(self.supabase_url and self.service_key)

    def status(self) -> dict:
        return {"env": self.env_name, "env_file": str(self.env_file), "env_file_exists": self.env_file.exists(),
                "project_ref": self.supabase_ref or None, "supabase_url": self.supabase_url or None,
                "service_key": "set" if self.service_key else "missing", "anthropic_key": "set" if self.anthropic_key else "missing",
                "model": self.anthropic_model, "read_only": self.read_only, "admin_token": "set" if self.admin_token else "not set (local open)",
                "auth": {"supabase_login": bool(self.supabase_url and self.anon_key and self.allowed_emails), "allowed_emails": len(self.allowed_emails),
                         "publishable_key": "set" if self.anon_key else "missing"},
                "public_url": self.public_url or None}


settings = Settings()
