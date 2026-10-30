"""개인 Supabase 프로젝트(IMEB3 DB)에 마이그레이션 SQL 파일을 적용한다.

사용법:
    py tools/apply_migration.py supabase/migrations/20261009000100_full_50_tables.sql
    py tools/apply_migration.py --check          # 적용 없이 접속과 mqi 테이블 수만 확인

접속 정보는 backend/.env.personal 의 SUPABASE_DB_URL 을 쓴다.
팀 프로젝트(clyjvqffabxpizkhydux)로는 절대 실행되지 않도록 막아 둔다 (AGENTS.md).
"""
import sys
from pathlib import Path

import psycopg
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[1]
ENV = ROOT / "backend" / ".env.personal"
TEAM_REF = "clyjvqffabxpizkhydux"
PERSONAL_REF = "idlckjmmoysklfssotyk"


def db_url() -> str:
    if not ENV.exists():
        sys.exit(f"{ENV} 가 없습니다. backend/.env.example 을 복사해 만들고 SUPABASE_DB_URL 을 채우세요.")
    url = (dotenv_values(ENV).get("SUPABASE_DB_URL") or "").strip()
    if not url or "<" in url:
        sys.exit("SUPABASE_DB_URL 이 비어 있거나 <...> 자리표시가 남아 있습니다.")
    if TEAM_REF in url:
        sys.exit("팀 프로젝트 접속 문자열입니다. 개인 프로젝트에만 적용할 수 있습니다.")
    if PERSONAL_REF not in url:
        sys.exit(f"개인 프로젝트 ref({PERSONAL_REF})가 접속 문자열에 없습니다. Connect > Session pooler 문자열인지 확인하세요.")
    return url


def table_count(cur) -> int:
    cur.execute("select count(*) from information_schema.tables where table_schema='mqi' and table_type='BASE TABLE'")
    return cur.fetchone()[0]


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    url = db_url()
    with psycopg.connect(url, connect_timeout=15) as conn:
        with conn.cursor() as cur:
            cur.execute("select current_user, version()")
            user, version = cur.fetchone()
            print(f"접속: {user} / {version.split(',')[0]}")
            print(f"mqi 테이블 수(적용 전): {table_count(cur)}")
            if sys.argv[1] == "--check":
                return
            sql_path = Path(sys.argv[1])
            sql = sql_path.read_text(encoding="utf-8")
            print(f"적용: {sql_path} ({len(sql):,} bytes)")
            cur.execute(sql)
            print(f"mqi 테이블 수(적용 후): {table_count(cur)}")
        conn.commit()
        print("commit 완료")


if __name__ == "__main__":
    main()
