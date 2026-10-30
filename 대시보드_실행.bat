@echo off
chcp 65001 >nul
cd /d "%~dp0backend"
if not exist ".env.personal" (
  echo [안내] backend\.env.personal 이 없습니다. .env.example 을 복사해 키를 채워 주세요.
)
py -m pip install -q -r requirements.txt
start "" http://127.0.0.1:8800
py -m uvicorn app.main:app --host 127.0.0.1 --port 8800 --reload
