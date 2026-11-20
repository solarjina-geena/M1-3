-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다(읽기용 뷰만 추가).
-- (2026-11-20 사용자 의견) 불량 수량 판독이 자주 틀린다 → 사람이 고치기 화면에서 바꾼 불량 수량 기록(AI 값 → 사람 값)을 모아
-- 판독 요청에 '이 현장 글씨에서 자주 헷갈린 숫자'로 알려 준다. 백엔드(service_role)만 읽는다.
CREATE OR REPLACE VIEW public.m13_defect_qty_fixes AS
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
 WHERE x ->> 'path' ~ '^defects\.\d+\.qty$'
   AND coalesce(x ->> 'ai', '') IS DISTINCT FROM coalesce(x ->> 'value', '')
 GROUP BY 1, 2, 3;

GRANT SELECT ON public.m13_defect_qty_fixes TO service_role;
REVOKE ALL ON public.m13_defect_qty_fixes FROM anon, authenticated;
