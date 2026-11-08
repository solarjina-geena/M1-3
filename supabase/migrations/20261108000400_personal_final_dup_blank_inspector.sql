-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다.
-- (2026-11-08 팀장 신고) 10/1·10/2 최종검사가 두 번씩 들어감 — 같은 쪽을 먼저 '직접 입력'(검사자 빈칸)으로, 이어서 사진 OCR(검사자 있음)로 저장.
-- 중복 판정이 검사자까지 '똑같아야' 같은 일보로 봤기 때문(빈칸 ≠ 이*진). → 한쪽 검사자가 빈칸이면 날짜·모델·구분·회차·검사량이 같을 때 같은 일보로 본다.
DO $mig$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.m13_journal_save(jsonb)'::regprocedure);
  IF position('ir.inspector_id IS NULL OR v_worker IS NULL' in d) = 0 THEN
    d := replace(d, 'AND ir.inspector_id IS NOT DISTINCT FROM v_worker',
                    'AND (ir.inspector_id IS NOT DISTINCT FROM v_worker OR ir.inspector_id IS NULL OR v_worker IS NULL)');
    IF position('ir.inspector_id IS NULL OR v_worker IS NULL' in d) = 0 THEN RAISE EXCEPTION 'm13_journal_save: 바꿀 줄을 찾지 못함'; END IF;
    EXECUTE d;
  END IF;
  d := pg_get_functiondef('public.m13_journal_exists(jsonb)'::regprocedure);
  IF position('ir.inspector_id IS NULL OR nullif' in d) = 0 THEN
    d := replace(d, 'AND w.worker_display_name IS NOT DISTINCT FROM nullif(p->>''inspector_masked'','''')',
                    'AND (w.worker_display_name IS NOT DISTINCT FROM nullif(p->>''inspector_masked'','''') OR ir.inspector_id IS NULL OR nullif(p->>''inspector_masked'','''') IS NULL)');
    IF position('ir.inspector_id IS NULL OR nullif' in d) = 0 THEN RAISE EXCEPTION 'm13_journal_exists: 바꿀 줄을 찾지 못함'; END IF;
    EXECUTE d;
  END IF;
END $mig$;
