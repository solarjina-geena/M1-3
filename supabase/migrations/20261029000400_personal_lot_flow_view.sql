-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블은 건드리지 않고 public 조회 뷰만 만든다.
-- LOT 흐름표: LOT 하나가 (1) 언제 어느 공정에서 얼마나 만들어졌고 (2) 어느 하위 공정이 어느 기간에 썼으며 어떤 하위 LOT 이 됐는지
-- (3) 최종검사는 어느 기간에 몇 번(1차 훈련 / 2차 전담 / 재검) 받았는지 한 줄로 본다. (사용자 요청 2026-10-29)
-- 수량 비교: produced_qty(이 LOT 산출) ↔ used_runs 의 하위 산출(downstream_qty) ↔ 검사 박스 수(480EA/BOX).

DROP VIEW IF EXISTS public.m13_lot_flow;

CREATE VIEW public.m13_lot_flow AS
WITH outp AS (   -- LOT 을 산출한 실행
    SELECT prl.production_lot_id AS lot_id, pc.process_code, pr.work_date, pr.work_type,
           sum(prr.gross_output_qty) AS qty
    FROM mqi.process_run_lot prl
    JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id AND pr.record_state = 'ACTIVE'
    JOIN mqi.process pc ON pc.process_id = pr.process_id
    LEFT JOIN mqi.process_run_result prr ON prr.process_run_id = pr.process_run_id AND prr.record_state = 'ACTIVE'
    WHERE prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
    GROUP BY 1, 2, 3, 4
),
cons AS (   -- LOT 을 투입한 하위 실행과 그 산출 LOT
    SELECT i.production_lot_id AS lot_id, pc.process_code AS used_by_process, pr.work_date,
           o.production_lot_id AS down_lot_id, dl.lot_code_raw AS down_lot_code, prr.gross_output_qty AS down_qty
    FROM mqi.process_run_lot i
    JOIN mqi.process_run pr ON pr.process_run_id = i.process_run_id AND pr.record_state = 'ACTIVE'
    JOIN mqi.process pc ON pc.process_id = pr.process_id
    LEFT JOIN mqi.process_run_lot o ON o.process_run_id = i.process_run_id AND o.lot_role = 'OUTPUT' AND o.record_state = 'ACTIVE'
    LEFT JOIN mqi.production_lot dl ON dl.lot_id = o.production_lot_id
    LEFT JOIN mqi.process_run_result prr ON prr.process_run_id = pr.process_run_id AND prr.record_state = 'ACTIVE'
    WHERE i.lot_role = 'INPUT' AND i.record_state = 'ACTIVE'
),
insp AS (   -- LOT 을 검사한 실행. 1차=훈련·타라인, 2차=전담(실제 검사 수량), 재검=불량 이벤트
    SELECT il.production_lot_id AS lot_id, ir.inspection_run_id, ir.inspection_date, ir.inspection_type, ir.inspection_round_no,
           ir.inspection_method, ir.inspected_qty_ea AS run_qty, il.recorded_box_count, il.inspected_qty_ea AS lot_qty
    FROM mqi.inspection_lot il
    JOIN mqi.inspection_run ir ON ir.inspection_run_id = il.inspection_run_id AND ir.record_state = 'ACTIVE'
    WHERE il.record_state = 'ACTIVE' AND il.production_lot_id IS NOT NULL
)
SELECT pm.model_code,
       COALESCE(o.process_code, CASE WHEN pl.remark ~ '^\{' THEN pl.remark::jsonb ->> 'process_code' END) AS process_code,
       pl.lot_code_raw AS lot_code, pl.lot_date, pl.verification_status AS lot_status,
       o.work_date AS produced_on, o.qty AS produced_qty, o.work_type,
       (o.lot_id IS NOT NULL) AS has_journal,
       c.used_by_process, c.used_from, c.used_to, c.used_runs, c.downstream_lots, c.downstream_qty,
       i.insp_first, i.insp_last, i.insp_runs,
       i.r1_runs, i.r1_boxes, i.r2_runs, i.r2_boxes, i.reinsp_runs, i.micro_runs,
       i.r2_boxes * 480 AS r2_box_qty_est
FROM mqi.production_lot pl
JOIN mqi.product_model pm ON pm.model_id = pl.model_id
LEFT JOIN outp o ON o.lot_id = pl.lot_id
LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT used_by_process, ',') AS used_by_process, min(work_date) AS used_from, max(work_date) AS used_to,
           count(DISTINCT work_date) AS used_runs, string_agg(DISTINCT down_lot_code, ', ') AS downstream_lots, sum(down_qty) AS downstream_qty
    FROM cons WHERE cons.lot_id = pl.lot_id
) c ON true
LEFT JOIN LATERAL (
    SELECT min(inspection_date) AS insp_first, max(inspection_date) AS insp_last, count(DISTINCT inspection_run_id) AS insp_runs,
           count(DISTINCT inspection_run_id) FILTER (WHERE inspection_type = 'FINAL' AND inspection_round_no = 1) AS r1_runs,
           sum(recorded_box_count) FILTER (WHERE inspection_type = 'FINAL' AND inspection_round_no = 1) AS r1_boxes,
           count(DISTINCT inspection_run_id) FILTER (WHERE inspection_type = 'FINAL' AND inspection_round_no = 2) AS r2_runs,
           sum(recorded_box_count) FILTER (WHERE inspection_type = 'FINAL' AND inspection_round_no = 2) AS r2_boxes,
           count(DISTINCT inspection_run_id) FILTER (WHERE inspection_type = 'REINSPECTION') AS reinsp_runs,
           count(DISTINCT inspection_run_id) FILTER (WHERE inspection_method = 'MICROSCOPE') AS micro_runs
    FROM insp WHERE insp.lot_id = pl.lot_id
) i ON true
WHERE pl.record_state = 'ACTIVE';

GRANT SELECT ON public.m13_lot_flow TO service_role, anon, authenticated;
