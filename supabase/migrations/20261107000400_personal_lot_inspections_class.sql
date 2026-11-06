-- 개인 프로젝트 전용 (IMEB3 DB). public 뷰만. (2026-11-07)
-- LOT 추적의 최종검사 행에 검사 구분을 붙인다(사용자 규칙): 1차 = 훈련·신입·지원(합산 제외) / 2차 = 본검사(LOT 검사 수량 합산) / 재검 = 불량 이슈 재선별(따로).
-- 기존 열은 그대로 두고 뒤에 추가: inspection_round_no, inspection_class, lot_qty_ea(그 LOT 몫: LOT 에 적힌 EA → BOX×480 → 실행에 LOT 이 하나면 실행 수량),
-- counted_in_lot_total(2차 본검사만 true). VOID 된 검사 실행은 뺀다.
CREATE OR REPLACE VIEW public.m13_lot_inspections AS
SELECT pm.model_code, pl.lot_code_raw AS lot_code, pl.lot_date,
       ir.inspection_date, ir.inspection_type, ir.inspected_qty_ea, il.lot_code_raw AS inspection_lot_raw,
       il.recorded_box_count, il.lot_linkage_status, il.inspection_lot_id, ir.inspection_run_id,
       ir.inspection_round_no,
       CASE WHEN ir.inspection_type = 'REINSPECTION' THEN '재검' WHEN ir.inspection_round_no = 2 THEN '2차' WHEN ir.inspection_round_no = 1 THEN '1차' ELSE '기타' END AS inspection_class,
       coalesce(il.inspected_qty_ea, il.recorded_box_count * 480,
                CASE WHEN (SELECT count(*) FROM mqi.inspection_lot x WHERE x.inspection_run_id = ir.inspection_run_id AND x.record_state = 'ACTIVE') = 1 THEN ir.inspected_qty_ea END) AS lot_qty_ea,
       (ir.inspection_type = 'FINAL' AND ir.inspection_round_no = 2) AS counted_in_lot_total
FROM mqi.inspection_lot il
JOIN mqi.inspection_run ir ON ir.inspection_run_id = il.inspection_run_id AND ir.record_state = 'ACTIVE'
JOIN mqi.production_lot pl ON pl.lot_id = il.production_lot_id
JOIN mqi.product_model pm ON pm.model_id = pl.model_id
WHERE il.record_state = 'ACTIVE';
