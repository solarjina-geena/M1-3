-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 사용자: 작업자는 잘 안 바뀐다)
-- 공정별로 이미 일한 작업자(가린 표시명) — 작업일보 판독 때 Claude 에 힌트로 준다(흘려 쓴 이름을 기존 사람으로 맞추기).
CREATE OR REPLACE VIEW public.m13_worker_names_by_process AS
SELECT DISTINCT pc.process_code, w.worker_display_name
  FROM mqi.worker_assignment wa
  JOIN mqi.worker w ON w.worker_id = wa.worker_id
  JOIN mqi.process_run pr ON pr.process_run_id = wa.process_run_id AND pr.record_state = 'ACTIVE'
  JOIN mqi.process pc ON pc.process_id = pr.process_id
 WHERE wa.record_state = 'ACTIVE' AND w.worker_display_name IS NOT NULL;
GRANT SELECT ON public.m13_worker_names_by_process TO service_role;
REVOKE ALL ON public.m13_worker_names_by_process FROM anon, authenticated;
