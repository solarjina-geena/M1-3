-- 개인 프로젝트 전용 (IMEB3 DB). public 뷰만. (2026-11-07)
-- 재검 불량 이슈와 본검사 비교(사용자 규칙): 재검은 불량 이슈로 검사 완료품을 다시 본 것이라 본검사 수량과 합치지 않고 따로 불량률을 본다.
-- 이슈가 난 뒤에는 통상 본검사(2차)에서도 같은 불량을 같이 검출하므로, 같은 불량명을 '첫 재검일 이후 2차 본검사'에서 얼마나 찾았는지 나란히 둔다.
-- 불량명은 공백·기호를 뺀 글자로 맞춘다(예 'L/C 찍힘' = 'LC찍힘'). 이름이 다르게 적히면 따로 잡힌다(추정 매칭 안 함).
CREATE OR REPLACE VIEW public.m13_reinsp_issue_defects AS
WITH f AS (
    SELECT pm.model_code, ir.inspection_date, ir.inspection_type, ir.inspection_round_no, ir.inspection_run_id, ir.inspected_qty_ea,
           coalesce(qf.raw_defect_name, dt.defect_name) AS defect_name,
           regexp_replace(lower(coalesce(qf.raw_defect_name, dt.defect_name)), '[[:space:]/·.()\-]', '', 'g') AS dkey,
           qf.quantity
    FROM mqi.quality_finding qf
    JOIN mqi.inspection_run ir ON ir.inspection_run_id = qf.inspection_run_id AND ir.record_state = 'ACTIVE'
    JOIN mqi.product_model pm ON pm.model_id = ir.model_id
    LEFT JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
    WHERE qf.record_state = 'ACTIVE' AND coalesce(qf.raw_defect_name, dt.defect_name) IS NOT NULL
),
k AS (
    SELECT model_code, dkey, min(defect_name) AS defect_name, min(inspection_date) AS issue_from,
           count(DISTINCT inspection_run_id) AS reinsp_runs, sum(quantity) AS reinsp_defects
    FROM f WHERE inspection_type = 'REINSPECTION'
    GROUP BY model_code, dkey
)
SELECT k.model_code, k.defect_name, to_char(k.issue_from, 'YYYY-MM-DD') AS issue_from, k.reinsp_runs,
       (SELECT sum(ir.inspected_qty_ea) FROM mqi.inspection_run ir JOIN mqi.product_model pm ON pm.model_id = ir.model_id
         WHERE ir.record_state = 'ACTIVE' AND ir.inspection_type = 'REINSPECTION' AND pm.model_code = k.model_code
           AND ir.inspection_run_id IN (SELECT inspection_run_id FROM f WHERE f.model_code = k.model_code AND f.dkey = k.dkey AND f.inspection_type = 'REINSPECTION')) AS reinsp_qty,
       k.reinsp_defects,
       (SELECT sum(ir.inspected_qty_ea) FROM mqi.inspection_run ir JOIN mqi.product_model pm ON pm.model_id = ir.model_id
         WHERE ir.record_state = 'ACTIVE' AND ir.inspection_type = 'FINAL' AND ir.inspection_round_no = 2 AND pm.model_code = k.model_code
           AND ir.inspection_date >= k.issue_from) AS main_qty_since,
       (SELECT coalesce(sum(quantity), 0) FROM f WHERE f.model_code = k.model_code AND f.dkey = k.dkey AND f.inspection_type = 'FINAL'
           AND f.inspection_round_no = 2 AND f.inspection_date >= k.issue_from) AS main_defects_since,
       (SELECT coalesce(sum(quantity), 0) FROM f WHERE f.model_code = k.model_code AND f.dkey = k.dkey AND f.inspection_type = 'FINAL'
           AND f.inspection_round_no = 2 AND f.inspection_date < k.issue_from) AS main_defects_before
FROM k;

GRANT SELECT ON public.m13_reinsp_issue_defects TO anon, authenticated, service_role;
