-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다.
-- (2026-11-08 팀장 확인: 최종검사 불량 유형 그래프에 10월 재검 불량(핀찍힘 등)이 안 보임)
-- 재검사 저장(m13_reinspection_save)은 불량 유형 코드(defect_type_id) 없이 원문 이름(raw_defect_name)만 남긴다.
-- 이 뷰가 defect_type 과 INNER JOIN 이라 그 불량이 통째로 빠졌다 → LEFT JOIN, 이름은 유형 이름이 없으면 원문 이름.
CREATE OR REPLACE VIEW public.m13_final_defect_rows AS
SELECT r.run_id,
       r.model_code,
       r.inspection_date,
       r.inspection_class,
       r.inspected_qty_ea,
       left(coalesce(dt.defect_name, qf.raw_defect_name), 150)::varchar(150) AS defect_name,
       qf.quantity
  FROM public.m13_final_inspection_runs r
  JOIN mqi.quality_finding qf ON qf.inspection_run_id = r.run_id AND qf.record_state::text = 'ACTIVE'::text
  LEFT JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id;
