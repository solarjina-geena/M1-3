"""M1-3 백엔드: FastAPI. /api/* 는 routers/api.py, 나머지는 frontend/ 정적 파일.

배포 주의: Render 는 render.yaml 의 rootDir(backend)·buildFilter 경로가 바뀐 커밋만 자동 배포한다.
"""
from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .config import FRONTEND_DIR, settings
from .routers.api import router

app = FastAPI(title="M1-3 iMEB3 mqi 대시보드 API", version="0.1.0")
app.add_middleware(CORSMiddleware, allow_origins=settings.allowed_origins or ["*"], allow_methods=["*"], allow_headers=["*"])
app.include_router(router)


@app.middleware("http")
async def no_cache_html(request, call_next):
    """화면 파일(html)은 브라우저가 예전 것을 캐시로 보여 주지 않게 매번 서버에 확인하게 한다."""
    response = await call_next(request)
    path = request.url.path
    if path == "/" or path.endswith(".html"):
        response.headers["Cache-Control"] = "no-cache, must-revalidate"
    return response

app.mount("/", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="frontend")
