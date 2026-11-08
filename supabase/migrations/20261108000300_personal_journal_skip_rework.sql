-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다.
-- (2026-11-08 팀장 신고) 10/16 일보를 처음 판독했는데 '이미 저장됨' — 그날 리워크 일보(work_type REWORK, 같은 순번 1)를
-- 중복 검사·저장 함수가 '같은 일보'로 보았다. 리워크는 다시 작업하는 공정이라 생산 일보와 별개 →
-- 중복 판정과 '기존 기록 바꾸기'(VOID) 대상에서 REWORK 실행을 뺀다(생산 일보를 바꾸다 리워크를 지우지 않게).
DO $mig$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.m13_journal_save(jsonb)'::regprocedure);
  IF position('work_type IS DISTINCT FROM ''REWORK''' in d) = 0 THEN
    d := replace(d,
      'SELECT process_run_id INTO v_prun FROM mqi.process_run WHERE run_id=v_run AND process_id=v_process AND sequence_no=v_seq AND record_state=''ACTIVE'' LIMIT 1;',
      'SELECT process_run_id INTO v_prun FROM mqi.process_run WHERE run_id=v_run AND process_id=v_process AND sequence_no=v_seq AND record_state=''ACTIVE'' AND work_type IS DISTINCT FROM ''REWORK'' LIMIT 1;');
    IF position('work_type IS DISTINCT FROM ''REWORK''' in d) = 0 THEN RAISE EXCEPTION 'm13_journal_save: 바꿀 줄을 찾지 못함'; END IF;
    EXECUTE d;
  END IF;
  d := pg_get_functiondef('public.m13_journal_exists(jsonb)'::regprocedure);
  IF position('work_type IS DISTINCT FROM ''REWORK''' in d) = 0 THEN
    d := replace(d,
      'AND pr.sequence_no = k.seq AND pr.record_state=''ACTIVE''',
      'AND pr.sequence_no = k.seq AND pr.record_state=''ACTIVE'' AND pr.work_type IS DISTINCT FROM ''REWORK''');
    IF position('work_type IS DISTINCT FROM ''REWORK''' in d) = 0 THEN RAISE EXCEPTION 'm13_journal_exists: 바꿀 줄을 찾지 못함'; END IF;
    EXECUTE d;
  END IF;
END $mig$;
