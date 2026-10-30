-- 개인 프로젝트 전용 (IMEB3 DB, ref idlckjmmoysklfssotyk). 팀 프로젝트에 적용하지 않는다.
-- 팀 기준 마이그레이션은 마지막에 anon/authenticated/service_role 의 mqi 접근을 모두 거둬 간다.
-- 개인 프로젝트에서는 백엔드(service_role 키)가 mqi 를 읽고 쓸 수 있어야 하므로 권한만 다시 준다.
-- 테이블·컬럼·제약조건·트리거는 건드리지 않는다 (AGENTS.md 스키마 동일성 원칙).

-- 1) 스키마와 테이블 접근. DELETE 는 주지 않는다: 팀 원칙대로 삭제 대신 record_state = 'VOID' 로 처리한다.
GRANT USAGE ON SCHEMA mqi, mqi_audit TO service_role;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA mqi TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA mqi_audit TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA mqi, mqi_audit TO service_role;

-- 2) 트리거 함수(write_guard, derive_*, validate_semantics, mqi_audit.capture)는 행을 쓰는 쪽이 실행 권한을 가져야 한다.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA mqi, mqi_audit TO service_role;

-- 3) 브라우저용 anon 키는 읽기만. RLS 정책이 없으므로 실제로는 아무 행도 보이지 않는다.
--    공개 조회가 필요해지면 팀의 public.mqi_demo_read 방식(team_reference 참고)을 따른다.
GRANT USAGE ON SCHEMA mqi TO anon, authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA mqi TO anon, authenticated;

-- 4) PostgREST(Data API)가 mqi 스키마를 노출하도록 설정. 대시보드 Settings > Data API > Exposed schemas 와 같은 효과.
ALTER ROLE authenticator SET pgrst.db_schemas = 'public, mqi';
NOTIFY pgrst, 'reload config';
