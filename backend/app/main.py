"""M1-3 백엔드: FastAPI. /api/* 는 routers/api.py, 나머지는 frontend/ 정적 파일."""
from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .config import FRONTEND_DIR, settings
from .routers.api import router

app = FastAPI(title="M1-3 iMEB3 mqi 대시보드 API", version="0.1.0")
app.add_middleware(CORSMiddleware, allow_origins=settings.allowed_origins or ["*"], allow_methods=["*"], allow_headers=["*"])
app.include_router(router)
app.mount("/", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="frontend")
