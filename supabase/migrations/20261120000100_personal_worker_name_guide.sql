-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다(팀 기준 스키마 그대로, 읽기용 뷰만 추가).
-- (2026-11-20 사용자 의견) 작업일보 판독에서 작업자·검사자 이름이 자주 틀린다 → 판독과 고치기 화면에 줄 '이름 길잡이' 두 가지.
-- 1) m13_worker_name_stats: 공정 묶음(사출·BS·조립·최종검사)별로 저장된 이름(가운데 글자 가린 이름)과 일한 횟수·마지막 날짜
-- 2) m13_worker_name_fixes: 사람이 고치기 화면에서 이름을 바꾼 기록(AI 가 읽은 이름 → 사람이 고친 이름, 가린 이름끼리)과 횟수
-- 실명은 DB 에 없다(가린 이름만). 백엔드(service_role)만 읽는다.

CREATE OR REPLACE VIEW public.m13_worker_name_stats AS
SELECT CASE WHEN pc.process_code IN ('IMEB3_WINDING', 'IMEB3_CA_PRESS') THEN 'ASSEMBLY'
            WHEN pc.process_code = 'IMEB3_INJECTION' THEN 'INJECTION'
            WHEN pc.process_code = 'IMEB3_STITCHING' THEN 'STITCHING' ELSE pc.process_code::text END AS grp,
       w.worker_display_name::text AS name,
       count(DISTINCT pr.process_run_id) AS runs,
       max(pr.work_date) AS last_date
  FROM mqi.worker_assignment wa
  JOIN mqi.worker w ON w.worker_id = wa.worker_id
  JOIN mqi.process_run pr ON pr.process_run_id = wa.process_run_id AND pr.record_state::text = 'ACTIVE'
  JOIN mqi.process pc ON pc.process_id = pr.process_id
 WHERE wa.record_state::text = 'ACTIVE' AND w.worker_display_name IS NOT NULL
 GROUP BY 1, 2
UNION ALL
SELECT 'FINAL', w.worker_display_name::text, count(*), max(ir.inspection_date)
  FROM mqi.inspection_run ir
  JOIN mqi.worker w ON w.worker_id = ir.inspector_id
 WHERE ir.record_state::text = 'ACTIVE' AND w.worker_display_name IS NOT NULL
 GROUP BY 2;

CREATE OR REPLACE VIEW public.m13_worker_name_fixes AS
WITH e AS (
  SELECT CASE WHEN pc.process_code IN ('IMEB3_WINDING', 'IMEB3_CA_PRESS') THEN 'ASSEMBLY'
              WHEN pc.process_code = 'IMEB3_INJECTION' THEN 'INJECTION'
              WHEN pc.process_code = 'IMEB3_STITCHING' THEN 'STITCHING' ELSE pc.process_code::text END AS grp, x
    FROM mqi.process_run pr
    JOIN mqi.process pc ON pc.process_id = pr.process_id,
         jsonb_array_elements(coalesce(public.m13_try_jsonb(pr.remark) -> 'human_edits', '[]'::jsonb)) x
   WHERE pr.record_state::text = 'ACTIVE'
  UNION ALL
  SELECT 'FINAL', x
    FROM mqi.inspection_run ir,
         jsonb_array_elements(coalesce(public.m13_try_jsonb(ir.remark) -> 'human_edits', '[]'::jsonb)) x
   WHERE ir.record_state::text = 'ACTIVE'
)
SELECT grp, x ->> 'ai' AS ai, x ->> 'value' AS value, count(*) AS n
  FROM e
 WHERE x ->> 'path' ~ '^(workers_masked\.\d+\.name|inspector_masked)$'
   AND nullif(x ->> 'ai', '') IS NOT NULL AND nullif(x ->> 'value', '') IS NOT NULL
   AND x ->> 'ai' <> x ->> 'value'
 GROUP BY 1, 2, 3;

GRANT SELECT ON public.m13_worker_name_stats, public.m13_worker_name_fixes TO service_role;
REVOKE ALL ON public.m13_worker_name_stats, public.m13_worker_name_fixes FROM anon, authenticated;
