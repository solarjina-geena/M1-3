-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블은 건드리지 않고 public 조회 뷰만 만든다.
-- 전체흐름(피시본) 대시보드용 행: M1-2 대시보드가 Firestore 문서(공정·모델·날짜·수량·자재 LOT 원문·검사 LOT 매핑)로
-- 그래프를 만들던 것을 mqi 에서 같은 모양으로 되돌려 준다. 한 행 = 공정 실행(주/야) 하나 또는 최종검사 실행 하나.
-- 자재 원문(materials)·상위 LOT 연결(inputs)·검사 LOT(lots)은 jsonb 배열로 붙인다. 이름은 가린 표시명만 나간다.

CREATE OR REPLACE VIEW public.m13_fishbone_rows AS
WITH run AS (
    SELECT pr.process_run_id, pr.run_id, pr.work_date, pr.work_type, pm.model_code, pc.process_code, pru.shift,
           CASE WHEN pr.remark ~ '^\{' THEN pr.remark::jsonb ELSE '{}'::jsonb END AS rm
    FROM mqi.process_run pr
    JOIN mqi.production_run pru ON pru.run_id = pr.run_id
    JOIN mqi.product_model pm ON pm.model_id = pr.model_id
    JOIN mqi.process pc ON pc.process_id = pr.process_id
    WHERE pr.record_state = 'ACTIVE' AND pc.process_code <> 'IMEB3_FINAL_INSPECTION'
),
res AS (
    SELECT process_run_id, sum(gross_output_qty)::bigint AS qty, max(work_minutes) AS minutes,
           max(CASE WHEN remark ~ '^\{' THEN remark::jsonb ->> 'operator' END) AS operator,
           max(raw_quantity_text) AS raw_quantity_text,
           max(CASE WHEN remark ~ '^\{' THEN remark::jsonb ->> 'vs' END) AS vs_result   -- 사람이 고친 값이면 HUMAN_VERIFIED
    FROM mqi.process_run_result WHERE record_state = 'ACTIVE' GROUP BY 1
),
outl AS (
    SELECT prl.process_run_id, min(pl.lot_code_raw) AS lot_code, min(pl.lot_date) AS lot_date
    FROM mqi.process_run_lot prl JOIN mqi.production_lot pl ON pl.lot_id = prl.production_lot_id
    WHERE prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE' GROUP BY 1
),
mark AS (   -- CA 제품 LOT 날짜 → 최종검사 마킹코드(조견표). CA 행의 inspector 칸에 실어 보낸다
    SELECT lot_date, min(marking_code) AS marking_code FROM mqi.lot_code_mapping WHERE record_state = 'ACTIVE' GROUP BY 1
),
inl AS (
    SELECT prl.process_run_id,
           jsonb_agg(jsonb_build_object('field', split_part(prl.evidence_note, '=', 1), 'note', prl.evidence_note,
                                        'lot_code', pl.lot_code_raw, 'lot_date', pl.lot_date,
                                        'lot_process', CASE WHEN pl.remark ~ '^\{' THEN pl.remark::jsonb ->> 'process_code' END,
                                        'status', prl.linkage_status) ORDER BY pl.lot_date) AS items
    FROM mqi.process_run_lot prl JOIN mqi.production_lot pl ON pl.lot_id = prl.production_lot_id
    WHERE prl.lot_role = 'INPUT' AND prl.record_state = 'ACTIVE' GROUP BY 1
),
mats AS (
    SELECT mu.process_run_id,
           jsonb_agg(jsonb_build_object('material', m.material_code,
                                        'field', CASE WHEN mu.remark ~ '^\{' THEN mu.remark::jsonb ->> 'field' END,
                                        'raw', mu.recorded_lot_code_raw,
                                        'lot_date', CASE WHEN mu.remark ~ '^\{' THEN mu.remark::jsonb ->> 'normalized_date' END,
                                        'vs', CASE WHEN mu.remark ~ '^\{' THEN mu.remark::jsonb ->> 'vs' END,
                                        'status', mu.linkage_status)) AS items
    FROM mqi.material_usage mu JOIN mqi.material m ON m.material_id = mu.material_id
    WHERE mu.record_state = 'ACTIVE' GROUP BY 1
),
lots AS (
    SELECT il.inspection_run_id,
           jsonb_agg(jsonb_build_object('raw', il.lot_code_raw, 'box', il.recorded_box_count, 'qty', il.inspected_qty_ea,
                                        'marking_code', CASE WHEN il.remark ~ '^\{' THEN il.remark::jsonb ->> 'marking_code' END,
                                        'normalization_status', CASE WHEN il.remark ~ '^\{' THEN il.remark::jsonb ->> 'normalization_status' END,
                                        'gt_confirmed', CASE WHEN il.remark ~ '"gt_confirmed": true' THEN true ELSE false END,
                                        'ca_lot', pl.lot_code_raw, 'lot_date', pl.lot_date, 'status', il.lot_linkage_status)) AS items
    FROM mqi.inspection_lot il LEFT JOIN mqi.production_lot pl ON pl.lot_id = il.production_lot_id
    WHERE il.record_state = 'ACTIVE' GROUP BY 1
)
SELECT 'production'::text AS kind, COALESCE(r.rm ->> 'fs', r.process_run_id::text) AS id, r.run_id::text AS run_id,
       r.process_code, r.model_code AS variant, r.work_date AS date, r.shift, r.work_type,
       res.qty AS value, res.minutes, res.operator, res.raw_quantity_text,
       COALESCE(res.vs_result, r.rm ->> 'vs') AS value_source, r.rm ->> 'file' AS file, r.rm ->> 'page' AS page,
       outl.lot_code AS out_lot, mats.items AS materials, inl.items AS inputs,
       CASE WHEN r.process_code = 'IMEB3_CA_PRESS' THEN mark.marking_code END AS inspector,
       NULL::integer AS round, NULL::text AS insp_type, NULL::jsonb AS lots, NULL::text AS hours
FROM run r
LEFT JOIN res ON res.process_run_id = r.process_run_id
LEFT JOIN outl ON outl.process_run_id = r.process_run_id
LEFT JOIN mark ON mark.lot_date = outl.lot_date
LEFT JOIN mats ON mats.process_run_id = r.process_run_id
LEFT JOIN inl ON inl.process_run_id = r.process_run_id
UNION ALL
SELECT 'inspection', COALESCE(rm ->> 'fs', ir.inspection_run_id::text), ir.inspection_run_id::text,
       'IMEB3_FINAL_INSPECTION', pm.model_code, ir.inspection_date, NULL, ir.inspection_type,
       ir.inspected_qty_ea::bigint, NULL, w.worker_display_name, ir.raw_inspection_label,
       rm ->> 'vs', rm ->> 'file', rm ->> 'page',
       NULL, NULL, NULL,
       w.worker_display_name, ir.inspection_round_no, ir.inspection_type, lots.items, rm ->> 'hours'
FROM mqi.inspection_run ir
CROSS JOIN LATERAL (SELECT CASE WHEN ir.remark ~ '^\{' THEN ir.remark::jsonb ELSE '{}'::jsonb END AS rm) j
JOIN mqi.product_model pm ON pm.model_id = ir.model_id
LEFT JOIN mqi.worker w ON w.worker_id = ir.inspector_id
LEFT JOIN lots ON lots.inspection_run_id = ir.inspection_run_id
WHERE ir.record_state = 'ACTIVE';

GRANT SELECT ON public.m13_fishbone_rows TO anon, authenticated, service_role;
