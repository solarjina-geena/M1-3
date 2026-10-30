-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블은 건드리지 않고 public 조회 뷰만 바꾼다.
-- 2026-10-29 사슬 규칙 보완(BA 보빈 날짜 → 스티칭 일보 모두 매칭) 이후 한 BA 에 스티칭 후보가 여러 개 붙어
-- 기존 뷰가 CA LOT 당 여러 행을 내놓게 됐다. CA LOT 당 1행으로 집계하고,
-- 상위 LOT 이 "실행(작업일보) 있음 / LOT 참조만 있음(일보 미수록)" 인지 구분한다.
-- 열 이름(model_code, ca_lot, ca_date, inspections, first_inspection, ba_lot, sti_lot, inj_lot, resin_lots, first_gap, depth)은
-- 백엔드·화면이 그대로 쓰므로 유지한다. ba_lot/sti_lot/inj_lot 은 후보가 여럿이면 ', ' 로 이어 붙인다.

DROP VIEW IF EXISTS public.m13_lot_chain_gaps;

CREATE VIEW public.m13_lot_chain_gaps AS
WITH ca AS (
    SELECT c.model_code, c.lot_code AS ca_lot, c.lot_date AS ca_date, c.lot_id AS ca_lot_id
    FROM public.m13_lot_chain c WHERE c.process_code = 'IMEB3_CA_PRESS'
    GROUP BY 1,2,3,4
),
-- 상위 LOT 참조(INPUT 연결). up.input_has_run: 그 상위 LOT 에 OUTPUT 실행(작업일보)이 있는지
-- 상위 LOT 의 공정: OUTPUT 실행이 있으면 그 공정, 없으면(자리표시 LOT) 변환기가 remark 에 적은 process_code
up AS (
    SELECT c.lot_id, c.process_code, c.input_lot_id, c.input_lot_code, c.input_lot_date, c.in_status,
           (c.input_process_code IS NOT NULL) AS input_has_run,
           COALESCE(c.input_process_code,
                    CASE WHEN pl.remark ~ '^\{' THEN pl.remark::jsonb ->> 'process_code' END) AS input_grp
    FROM public.m13_lot_chain c
    JOIN mqi.production_lot pl ON pl.lot_id = c.input_lot_id
    WHERE c.input_lot_id IS NOT NULL
),
ba AS (SELECT ca.ca_lot_id, u.* FROM ca JOIN up u ON u.lot_id = ca.ca_lot_id AND u.process_code = 'IMEB3_CA_PRESS' AND u.input_grp = 'IMEB3_WINDING'),
sti AS (SELECT ba.ca_lot_id, u.* FROM ba JOIN up u ON u.lot_id = ba.input_lot_id AND u.process_code = 'IMEB3_WINDING' AND u.input_grp = 'IMEB3_STITCHING'),
inj AS (SELECT sti.ca_lot_id, u.* FROM sti JOIN up u ON u.lot_id = sti.input_lot_id AND u.process_code = 'IMEB3_STITCHING' AND u.input_grp = 'IMEB3_INJECTION'),
resin AS (
    SELECT inj.ca_lot_id, string_agg(DISTINCT mu.recorded_lot_code_raw, ', ') AS resin_lots
    FROM inj
    JOIN mqi.process_run_lot prl ON prl.production_lot_id = inj.input_lot_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
    JOIN mqi.material_usage mu ON mu.process_run_id = prl.process_run_id AND mu.record_state = 'ACTIVE'
    JOIN mqi.material m ON m.material_id = mu.material_id AND m.material_code = 'IMEB3_RESIN'
    GROUP BY 1
),
agg AS (
    SELECT ca.ca_lot_id,
           (SELECT string_agg(DISTINCT input_lot_code, ', ') FROM ba  WHERE ba.ca_lot_id  = ca.ca_lot_id) AS ba_lot,
           (SELECT count(DISTINCT input_lot_id) FROM ba  WHERE ba.ca_lot_id  = ca.ca_lot_id) AS ba_n,
           (SELECT count(DISTINCT input_lot_id) FROM ba  WHERE ba.ca_lot_id  = ca.ca_lot_id AND input_has_run) AS ba_run_n,
           (SELECT min(input_lot_date) FROM ba WHERE ba.ca_lot_id = ca.ca_lot_id) AS ba_date,
           (SELECT string_agg(DISTINCT input_lot_code, ', ') FROM sti WHERE sti.ca_lot_id = ca.ca_lot_id) AS sti_lot,
           (SELECT count(DISTINCT input_lot_id) FROM sti WHERE sti.ca_lot_id = ca.ca_lot_id) AS sti_n,
           (SELECT count(DISTINCT input_lot_id) FROM sti WHERE sti.ca_lot_id = ca.ca_lot_id AND input_has_run) AS sti_run_n,
           (SELECT string_agg(DISTINCT input_lot_code, ', ') FROM inj WHERE inj.ca_lot_id = ca.ca_lot_id) AS inj_lot,
           (SELECT count(DISTINCT input_lot_id) FROM inj WHERE inj.ca_lot_id = ca.ca_lot_id) AS inj_n,
           (SELECT count(DISTINCT input_lot_id) FROM inj WHERE inj.ca_lot_id = ca.ca_lot_id AND input_has_run) AS inj_run_n,
           (SELECT resin_lots FROM resin WHERE resin.ca_lot_id = ca.ca_lot_id) AS resin_lots
    FROM ca
),
insp AS (
    SELECT il.production_lot_id, count(*) AS inspections, min(ir.inspection_date) AS first_inspection
    FROM mqi.inspection_lot il JOIN mqi.inspection_run ir ON ir.inspection_run_id = il.inspection_run_id
    WHERE il.record_state = 'ACTIVE' GROUP BY 1
),
-- LOT 을 산출한 실행의 생산량 합(라인이 여러 개면 합산). BA 와 CA 는 같은 날 같은 LOT 이므로 두 수량 차이 = 불량·이월 추적 대상
qty AS (
    SELECT prl.production_lot_id, sum(prr.gross_output_qty) AS qty, string_agg(DISTINCT pr.work_type, ',') AS work_types
    FROM mqi.process_run_lot prl
    JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id AND pr.record_state = 'ACTIVE'
    LEFT JOIN mqi.process_run_result prr ON prr.process_run_id = prl.process_run_id AND prr.record_state = 'ACTIVE'
    WHERE prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE' GROUP BY 1
)
SELECT ca.model_code, ca.ca_lot, ca.ca_date,
       insp.inspections, insp.first_inspection,
       caq.qty AS ca_qty,
       (SELECT sum(q.qty) FROM ba JOIN qty q ON q.production_lot_id = ba.input_lot_id WHERE ba.ca_lot_id = ca.ca_lot_id) AS ba_qty,
       (SELECT sum(q.qty) FROM ba JOIN qty q ON q.production_lot_id = ba.input_lot_id WHERE ba.ca_lot_id = ca.ca_lot_id) - caq.qty AS ba_ca_gap,
       caq.work_types AS ca_work_type,
       a.ba_lot,  'CANDIDATE'::varchar AS ba_link,
       a.sti_lot, 'CANDIDATE'::varchar AS sti_link,
       a.inj_lot, 'CANDIDATE'::varchar AS inj_link,
       a.resin_lots,
       a.ba_n, a.sti_n, a.sti_run_n, a.inj_n, a.inj_run_n,
       CASE
         WHEN a.ba_n = 0  THEN '권선(BA) LOT 미연결: ' || ca.ca_date || ' 조립작업일보의 BA 기록 필요'
         WHEN a.sti_n = 0 THEN '스티칭 LOT 미연결: BA ' || a.ba_date || ' 작업일보의 인서트·보빈 날짜 필요'
         WHEN a.sti_run_n = 0 THEN '스티칭 LOT 참조만 있음(' || a.sti_lot || '): 해당 날짜 스티칭 작업일보 미수록'
         WHEN a.inj_n = 0 THEN '사출 LOT 미연결: 스티칭 ' || a.sti_lot || ' 작업일보의 보빈 날짜 필요'
         WHEN a.inj_run_n = 0 THEN '사출 LOT 참조만 있음(' || a.inj_lot || '): 해당 날짜 사출 작업일보 미수록'
         WHEN a.resin_lots IS NULL THEN '수지 LOT 미기재: 사출 ' || a.inj_lot || ' 작업일보의 수지 LOT 필요'
         ELSE '완전'
       END AS first_gap,
       (a.ba_n > 0)::int + (a.sti_n > 0)::int + (a.inj_n > 0)::int + (a.resin_lots IS NOT NULL)::int AS depth
FROM ca
JOIN agg a ON a.ca_lot_id = ca.ca_lot_id
LEFT JOIN insp ON insp.production_lot_id = ca.ca_lot_id
LEFT JOIN qty caq ON caq.production_lot_id = ca.ca_lot_id;

GRANT SELECT ON public.m13_lot_chain_gaps TO service_role, anon, authenticated;
