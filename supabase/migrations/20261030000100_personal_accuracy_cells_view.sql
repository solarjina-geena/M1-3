-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블은 건드리지 않고 public 조회 뷰만 만든다.
-- OCR 정답률 측정용 "칸" 뷰: DB 에 들어간 값을 정답지(회사 전산 엑셀)와 같은 맞춤 키(날짜·모델·공정·주야·항목)로 펼친다.
-- 팀 기준서(정답률_기준.md v1.0): 칸 = 1문항, 키 = 날짜+모델+공정+항목+주야(+위치). vs = 값 출처(SOURCE_READ 등 PDF 판독 / EXCEL_TRANSCRIBED 전사본).

CREATE OR REPLACE VIEW public.m13_accuracy_cells AS
WITH run AS (
    SELECT pr.process_run_id, pr.work_date, pm.model_code, pc.process_code, pru.shift,
           CASE WHEN pr.remark ~ '^\{' THEN pr.remark::jsonb ->> 'vs' END AS vs,
           CASE WHEN pr.remark ~ '^\{' THEN pr.remark::jsonb ->> 'fs' END AS source_doc
    FROM mqi.process_run pr
    JOIN mqi.production_run pru ON pru.run_id = pr.run_id
    JOIN mqi.product_model pm ON pm.model_id = pr.model_id
    JOIN mqi.process pc ON pc.process_id = pr.process_id
    WHERE pr.record_state = 'ACTIVE'
)
-- 1) 생산량 / 작업시간
SELECT 'production_qty' AS item, r.work_date, r.model_code, r.process_code, r.shift, NULL::text AS sub,
       -- 사람이 원본 대조로 고친 행(remark corrected_by)은 AI 판독값(corrected_from 원문)을 그대로 비교한다. 정답률은 AI 판독 기준이기 때문
       CASE WHEN prr.remark ~ '"corrected_by"' THEN NULL::numeric ELSE prr.gross_output_qty::numeric END AS value_num,
       CASE WHEN prr.remark ~ '"corrected_by"' THEN prr.remark::jsonb ->> 'corrected_from' ELSE prr.raw_quantity_text END AS value_text,
       r.vs, r.source_doc, r.process_run_id AS ref_id
FROM run r JOIN mqi.process_run_result prr ON prr.process_run_id = r.process_run_id AND prr.record_state = 'ACTIVE'
UNION ALL
SELECT 'work_hours', r.work_date, r.model_code, r.process_code, r.shift, NULL,
       round(prr.work_minutes::numeric / 60, 2), NULL, r.vs, r.source_doc, r.process_run_id
FROM run r JOIN mqi.process_run_result prr ON prr.process_run_id = r.process_run_id AND prr.record_state = 'ACTIVE'
WHERE prr.work_minutes IS NOT NULL
UNION ALL
-- 2) 공정 불량 (유형별)
SELECT 'defect', r.work_date, r.model_code, r.process_code, r.shift, qf.raw_defect_name,
       qf.quantity::numeric, qf.raw_quantity_text, r.vs, r.source_doc, qf.quality_finding_id
FROM run r JOIN mqi.quality_finding qf ON qf.process_run_id = r.process_run_id AND qf.record_state = 'ACTIVE'
UNION ALL
-- 3) 자재·부품 LOT 원문 (수지·보빈·리드핀·인서트·와이어·케이스). 값은 원문 날짜 표기
SELECT 'material', r.work_date, r.model_code, r.process_code, r.shift, m.material_code,
       NULL, mu.recorded_lot_code_raw, r.vs, r.source_doc, mu.material_usage_id
FROM run r JOIN mqi.material_usage mu ON mu.process_run_id = r.process_run_id AND mu.record_state = 'ACTIVE'
JOIN mqi.material m ON m.material_id = mu.material_id
UNION ALL
-- 4) 최종검사: 검사자(가린 이름)별 검사수량. 정형데이터 정답지(날짜·검사자·ITEM·검사수량·불량수량)와 맞춘다
SELECT 'inspected_qty', ir.inspection_date, pm.model_code, 'IMEB3_FINAL_INSPECTION', NULL, w.worker_display_name,
       ir.inspected_qty_ea::numeric, ir.raw_inspection_label,
       CASE WHEN ir.remark ~ '^\{' THEN ir.remark::jsonb ->> 'vs' END,
       CASE WHEN ir.remark ~ '^\{' THEN ir.remark::jsonb ->> 'fs' END, ir.inspection_run_id
FROM mqi.inspection_run ir
JOIN mqi.product_model pm ON pm.model_id = ir.model_id
LEFT JOIN mqi.worker w ON w.worker_id = ir.inspector_id
WHERE ir.record_state = 'ACTIVE'
UNION ALL
-- 5) 최종검사 불량 (검사 실행별 유형별)
SELECT 'inspection_defect', ir.inspection_date, pm.model_code, 'IMEB3_FINAL_INSPECTION', NULL,
       COALESCE(w.worker_display_name, '') || '|' || COALESCE(qf.raw_defect_name, ''),
       qf.quantity::numeric, qf.raw_quantity_text,
       CASE WHEN ir.remark ~ '^\{' THEN ir.remark::jsonb ->> 'vs' END,
       CASE WHEN ir.remark ~ '^\{' THEN ir.remark::jsonb ->> 'fs' END, qf.quality_finding_id
FROM mqi.quality_finding qf
JOIN mqi.inspection_run ir ON ir.inspection_run_id = qf.inspection_run_id AND ir.record_state = 'ACTIVE'
JOIN mqi.product_model pm ON pm.model_id = ir.model_id
LEFT JOIN mqi.worker w ON w.worker_id = ir.inspector_id
WHERE qf.record_state = 'ACTIVE';

GRANT SELECT ON public.m13_accuracy_cells TO anon, authenticated, service_role;
