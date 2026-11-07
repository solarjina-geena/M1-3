-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 사용자 요청: 권선 비전 불량 1·2·3차 + 가성/진성 재검사)
-- 비전 재검사 엑셀(iMEB3 비젼 가성불량 조치 내역)은 팀 표 그대로 저장한다:
--   inspection_run  : inspection_type = IN_PROCESS, inspection_stage = VISION_1 / VISION_2, inspected_qty_ea = 다시 본 수량
--   quality_finding : FALSE_REJECT(가성 = 양품) · TRUE_DEFECT(진성, 불량 유형별 defect_type 'VIS:이름')
-- 작업일보의 비전 1·2·3차 불량(설비가 걸러낸 수량)은 권선 process_run 의 PROCESS_DEFECT(불량명 '비전1차'·'vision1' 등) 그대로.

-- 1) 공정별 불량 유형 집계에서 비전 재검사 결과는 뺀다(아니면 최종검사로 셈해짐). 열은 그대로.
CREATE OR REPLACE VIEW public.m13_defect_by_type AS
SELECT pm.model_code,
       COALESCE(pc.process_code, 'IMEB3_FINAL_INSPECTION'::character varying) AS process_code,
       dt.defect_name,
       qf.finding_class,
       COALESCE(pr.work_date, ir.inspection_date) AS the_date,
       sum(qf.quantity) AS qty,
       count(*) AS findings
  FROM mqi.quality_finding qf
  JOIN mqi.product_model pm ON pm.model_id = qf.model_id
  JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
  LEFT JOIN mqi.process_run pr ON pr.process_run_id = qf.process_run_id
  LEFT JOIN mqi.process pc ON pc.process_id = pr.process_id
  LEFT JOIN mqi.inspection_run ir ON ir.inspection_run_id = qf.inspection_run_id
 WHERE qf.record_state::text = 'ACTIVE'
   AND (ir.inspection_stage IS NULL OR ir.inspection_stage::text NOT LIKE 'VISION%')
 GROUP BY pm.model_code, COALESCE(pc.process_code, 'IMEB3_FINAL_INSPECTION'::character varying), dt.defect_name, qf.finding_class,
          COALESCE(pr.work_date, ir.inspection_date);

-- 2) 작업일보 비전 1·2·3차 불량 — 날짜·모델·차수별 합계. 불량명 표기가 여러 가지라 '비전/vision + 숫자'로 차수를 읽는다.
CREATE OR REPLACE VIEW public.m13_vision_reject_daily AS
SELECT pm.model_code,
       to_char(pr.work_date::timestamp with time zone, 'YYYY-MM-DD') AS work_date,
       substring(lower(dt.defect_name::text) FROM '(?:비전|vision)\s*([123])')::int AS stage,
       sum(qf.quantity) AS qty,
       count(*) AS findings
  FROM mqi.quality_finding qf
  JOIN mqi.process_run pr ON pr.process_run_id = qf.process_run_id AND pr.record_state::text = 'ACTIVE'
  JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code::text = 'IMEB3_WINDING'
  JOIN mqi.product_model pm ON pm.model_id = pr.model_id
  JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
 WHERE qf.record_state::text = 'ACTIVE'
   AND qf.finding_class::text = 'PROCESS_DEFECT'
   AND substring(lower(dt.defect_name::text) FROM '(?:비전|vision)\s*([123])') IS NOT NULL
 GROUP BY 1, 2, 3;

-- 3) 비전 재검사(사람이 다시 본 결과) — 검사 1건 × 결과 1줄. 가성 = FALSE_REJECT, 진성 = TRUE_DEFECT(유형별).
CREATE OR REPLACE VIEW public.m13_vision_check_rows AS
SELECT ir.inspection_run_id AS run_id,
       pm.model_code,
       to_char(ir.inspection_date::timestamp with time zone, 'YYYY-MM-DD') AS check_date,
       ir.inspection_round_no AS round,
       ir.inspected_qty_ea,
       ir.validation_status,
       ir.process_run_id IS NOT NULL AS linked_to_journal,
       qf.finding_class,
       COALESCE(dt.defect_name, qf.raw_defect_name) AS defect_name,
       qf.quantity
  FROM mqi.inspection_run ir
  JOIN mqi.product_model pm ON pm.model_id = ir.model_id
  LEFT JOIN mqi.quality_finding qf ON qf.inspection_run_id = ir.inspection_run_id AND qf.record_state::text = 'ACTIVE'
  LEFT JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
 WHERE ir.record_state::text = 'ACTIVE'
   AND ir.inspection_stage::text IN ('VISION_1', 'VISION_2', 'VISION_3');

GRANT SELECT ON public.m13_vision_reject_daily, public.m13_vision_check_rows TO service_role;
REVOKE ALL ON public.m13_vision_reject_daily, public.m13_vision_check_rows FROM anon, authenticated;
