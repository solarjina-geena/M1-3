-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-06)
-- 초품 위치도는 '확인 필요'에서 뺀다(사용자 결정): 경계·불량 값도 산포도 데이터로 보고, 불량이면 수정 후 같은 날 재측정으로 진행.
-- 위치도 판정은 대시보드 CA 위치도 화면과 m13_position_checks 에서 본다. 판단 RPC 의 POSITION 분기는 그대로 둔다(지난 판단 이력 보존).

CREATE OR REPLACE VIEW public.m13_review_queue AS
WITH out_lot AS (   -- 실행 → OUTPUT LOT 코드
    SELECT prl.process_run_id, string_agg(DISTINCT l.lot_code_raw, '/') AS lot_code
    FROM mqi.process_run_lot prl JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
    WHERE prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT'
    GROUP BY prl.process_run_id
),
lot_stage AS (      -- LOT → 그 LOT 을 만든 공정
    SELECT DISTINCT ON (prl.production_lot_id) prl.production_lot_id, p.process_code
    FROM mqi.process_run_lot prl JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
    JOIN mqi.process p ON p.process_id = pr.process_id
    WHERE prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT'
),
rv AS (
    SELECT 'READ_VALUE'::text AS kind, ef.extracted_field_id AS target_id, 'extracted_field'::text AS target_table,
           coalesce(ls.process_code, 'SOURCE') AS stage_code, pm.model_code, l.lot_date AS item_date,
           coalesce(l.lot_code_raw, ef.extracted_value) AS lot_code,
           coalesce(sl.source_label, ef.field_code) || ' 판독값 확인' AS title,
           ef.extracted_value AS current_value,
           jsonb_build_object('field_code', ef.field_code, 'raw_value', ef.raw_value, 'extracted_value', ef.extracted_value,
                              'sheet', sl.sheet_name, 'cell', sl.cell_reference, 'review_note', fr.review_note,
                              'linked_to', fpl.target_column_name, 'evidence_role', fpl.evidence_role) AS detail,
           ARRAY['VERIFIED', 'CORRECTED', 'REJECTED'] AS decisions, ef.recorded_at AS raised_at
    FROM mqi.extracted_field ef
    JOIN mqi.source_location sl ON sl.source_location_id = ef.source_location_id
    LEFT JOIN mqi.field_review fr ON fr.field_review_id = ef.current_review_id
    LEFT JOIN LATERAL (SELECT * FROM mqi.field_provenance_link f WHERE f.extracted_field_id = ef.extracted_field_id AND f.record_state = 'ACTIVE'
                       ORDER BY (f.evidence_role = 'PRIMARY') DESC LIMIT 1) fpl ON true
    LEFT JOIN mqi.production_lot l ON l.lot_id = fpl.target_lot_id
    LEFT JOIN mqi.product_model pm ON pm.model_id = l.model_id
    LEFT JOIN lot_stage ls ON ls.production_lot_id = l.lot_id
    WHERE ef.record_state = 'ACTIVE' AND ef.validation_status = 'NEEDS_REVIEW'
),
il AS (
    SELECT 'INSPECTION_LOT', il.inspection_lot_id, 'inspection_lot', 'IMEB3_FINAL_INSPECTION', pm.model_code, ir.inspection_date,
           NULL::text, '검사 LOT 판독 불가: ' || coalesce(il.lot_code_raw, '(빈칸)'), il.lot_code_raw,
           jsonb_build_object('lot_code_raw', il.lot_code_raw, 'box_count', il.recorded_box_count, 'quantity_raw', il.recorded_quantity_raw,
                              'inspection_label', ir.raw_inspection_label, 'round_no', ir.inspection_round_no,
                              'normalization', public.m13_try_jsonb(il.remark) ->> 'normalization_status'),
           ARRAY['CONFIRMED', 'UNRESOLVED', 'VOID'], il.recorded_at
    FROM mqi.inspection_lot il
    JOIN mqi.inspection_run ir ON ir.inspection_run_id = il.inspection_run_id
    JOIN mqi.product_model pm ON pm.model_id = il.model_id
    WHERE il.record_state = 'ACTIVE' AND il.lot_linkage_status = 'UNRESOLVED'
      AND NOT (public.m13_try_jsonb(il.remark) ? 'judgment')
),
ev AS (
    SELECT 'EVENT', e.event_id, 'production_event', coalesce(p.process_code, 'COMMON'), pm.model_code, coalesce(e.event_date, pr.work_date),
           ol.lot_code, '생산 이벤트 확인: ' || left(coalesce(e.event_description, e.event_type), 60), e.event_description,
           jsonb_build_object('event_type', e.event_type, 'description', e.event_description, 'duration_minutes', e.duration_minutes,
                              'start_at', e.event_start_at, 'source_file', public.m13_try_jsonb(e.remark) ->> 'file',
                              'source_page', public.m13_try_jsonb(e.remark) ->> 'page'),
           ARRAY['VERIFIED', 'REJECTED', 'VOID'], e.recorded_at
    FROM mqi.production_event e
    LEFT JOIN mqi.process_run pr ON pr.process_run_id = e.process_run_id
    LEFT JOIN mqi.process p ON p.process_id = pr.process_id
    LEFT JOIN mqi.product_model pm ON pm.model_id = pr.model_id
    LEFT JOIN out_lot ol ON ol.process_run_id = e.process_run_id
    WHERE e.record_state = 'ACTIVE' AND e.validation_status = 'NEEDS_REVIEW'
),
q AS (SELECT * FROM rv UNION ALL SELECT * FROM il UNION ALL SELECT * FROM ev)
SELECT q.kind || ':' || q.target_id AS item_id, q.kind, q.target_table, q.target_id::text AS target_id, q.stage_code,
       CASE q.stage_code WHEN 'IMEB3_INJECTION' THEN '사출' WHEN 'IMEB3_STITCHING' THEN '스티칭' WHEN 'IMEB3_WINDING' THEN '권선(BA)'
            WHEN 'IMEB3_CA_PRESS' THEN '압입(CA)' WHEN 'IMEB3_FINAL_INSPECTION' THEN '최종검사' WHEN 'SOURCE' THEN '원본·출처' ELSE '공통' END AS stage_label,
       q.model_code, to_char(q.item_date, 'YYYY-MM-DD') AS item_date, q.lot_code, q.title, q.current_value, q.detail, q.decisions, q.raised_at
FROM q;

GRANT SELECT ON public.m13_review_queue TO anon, authenticated, service_role;
