-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 사용자 요청: 최종검사 불량 유형별 막대그래프 + PPM)
-- 최종검사 검사 1건(inspection_run) = 1행: 검사 구분(1차·2차·재검, m13_inspection_breakdown 과 같은 규칙), 검사수량.
-- PPM = 불량수량 / 검사수량 × 1,000,000. 분모는 검사수량이 적힌 검사만(빈칸은 0 으로 치지 않음) — 화면이 이 뷰로 계산한다.
CREATE OR REPLACE VIEW public.m13_final_inspection_runs AS
SELECT ir.inspection_run_id AS run_id,
       pm.model_code,
       to_char(ir.inspection_date::timestamp with time zone, 'YYYY-MM-DD') AS inspection_date,
       CASE WHEN ir.inspection_type::text = 'REINSPECTION' THEN '재검'
            WHEN ir.inspection_round_no = 2 THEN '2차'
            WHEN ir.inspection_round_no = 1 THEN '1차'
            ELSE '기타' END AS inspection_class,
       ir.inspected_qty_ea
  FROM mqi.inspection_run ir
  JOIN mqi.product_model pm ON pm.model_id = ir.model_id
 WHERE ir.record_state::text = 'ACTIVE'
   AND ir.inspection_type::text IN ('FINAL', 'REINSPECTION');

-- 최종검사 불량 1줄 = 1행(불량명은 DB 원문 그대로; 같은 불량의 다른 표기는 화면·API 가 표시용으로만 묶는다).
CREATE OR REPLACE VIEW public.m13_final_defect_rows AS
SELECT r.run_id, r.model_code, r.inspection_date, r.inspection_class, r.inspected_qty_ea,
       dt.defect_name, qf.quantity
  FROM public.m13_final_inspection_runs r
  JOIN mqi.quality_finding qf ON qf.inspection_run_id = r.run_id AND qf.record_state::text = 'ACTIVE'
  JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id;

GRANT SELECT ON public.m13_final_inspection_runs, public.m13_final_defect_rows TO service_role;
REVOKE ALL ON public.m13_final_inspection_runs, public.m13_final_defect_rows FROM anon, authenticated;
