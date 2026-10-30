-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블은 건드리지 않고 public 스키마에 조회용 뷰만 만든다.
-- 팀 DB에 적용하려면 DB 담당(이*규) 승인 필요. 팀의 public.mqi_* RPC 와 이름이 겹치지 않도록 m13_ 접두사를 쓴다.

-- 1) LOT 한 줄 = 공정 산출 LOT 하나. 어느 공정 실행이 만들었고, 그 실행에 투입된 상위 LOT 들.
CREATE OR REPLACE VIEW public.m13_lot_chain AS
WITH out_lot AS (
    SELECT prl.production_lot_id AS lot_id, prl.process_run_id, pr.work_date, pr.model_id, pc.process_code,
           prl.linkage_status AS out_status
    FROM mqi.process_run_lot prl
    JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id AND pr.record_state = 'ACTIVE'
    JOIN mqi.process pc ON pc.process_id = pr.process_id
    WHERE prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
),
in_lot AS (
    SELECT prl.process_run_id, prl.production_lot_id AS input_lot_id, prl.linkage_status AS in_status, prl.evidence_note
    FROM mqi.process_run_lot prl
    WHERE prl.lot_role = 'INPUT' AND prl.record_state = 'ACTIVE'
)
SELECT pm.model_code, o.process_code, pl.lot_code_raw AS lot_code, pl.lot_date, pl.verification_status AS lot_status,
       o.out_status, o.process_run_id,
       up.process_code AS input_process_code, upl.lot_code_raw AS input_lot_code, upl.lot_date AS input_lot_date,
       i.in_status, i.evidence_note AS input_evidence,
       pl.lot_id, i.input_lot_id
FROM out_lot o
JOIN mqi.production_lot pl ON pl.lot_id = o.lot_id
JOIN mqi.product_model pm ON pm.model_id = pl.model_id
LEFT JOIN in_lot i ON i.process_run_id = o.process_run_id
LEFT JOIN mqi.production_lot upl ON upl.lot_id = i.input_lot_id
LEFT JOIN out_lot up ON up.lot_id = i.input_lot_id;

-- 2) 사슬 점검표: CA 제품 LOT 마다 CA←권선←스티칭←사출←수지 가 어디까지 이어졌는지, 끊긴 첫 자리는 어디인지.
CREATE OR REPLACE VIEW public.m13_lot_chain_gaps AS
WITH ca AS (
    SELECT c.model_code, c.lot_code AS ca_lot, c.lot_date AS ca_date, c.lot_id AS ca_lot_id, c.process_run_id AS ca_run
    FROM public.m13_lot_chain c WHERE c.process_code = 'IMEB3_CA_PRESS'
    GROUP BY 1,2,3,4,5
),
ba AS (SELECT * FROM public.m13_lot_chain WHERE process_code = 'IMEB3_CA_PRESS' AND input_process_code = 'IMEB3_WINDING'),
sti AS (SELECT * FROM public.m13_lot_chain WHERE process_code = 'IMEB3_WINDING' AND input_process_code = 'IMEB3_STITCHING'),
inj AS (SELECT * FROM public.m13_lot_chain WHERE process_code = 'IMEB3_STITCHING' AND input_process_code = 'IMEB3_INJECTION'),
resin AS (
    SELECT prl.production_lot_id AS inj_lot_id, string_agg(mu.recorded_lot_code_raw, ', ') AS resin_lots
    FROM mqi.process_run_lot prl
    JOIN mqi.material_usage mu ON mu.process_run_id = prl.process_run_id AND mu.record_state = 'ACTIVE'
    JOIN mqi.material m ON m.material_id = mu.material_id AND m.material_code = 'IMEB3_RESIN'
    WHERE prl.lot_role = 'OUTPUT' GROUP BY 1
),
insp AS (
    SELECT il.production_lot_id, count(*) AS inspections, min(ir.inspection_date) AS first_inspection
    FROM mqi.inspection_lot il JOIN mqi.inspection_run ir ON ir.inspection_run_id = il.inspection_run_id
    WHERE il.record_state = 'ACTIVE' GROUP BY 1
)
SELECT ca.model_code, ca.ca_lot, ca.ca_date,
       insp.inspections, insp.first_inspection,
       ba.input_lot_code  AS ba_lot,  ba.in_status  AS ba_link,
       sti.input_lot_code AS sti_lot, sti.in_status AS sti_link,
       inj.input_lot_code AS inj_lot, inj.in_status AS inj_link,
       resin.resin_lots,
       CASE
         WHEN ba.input_lot_id IS NULL  THEN '권선(BA) LOT 미연결: ' || ca.ca_date || ' 조립작업일보의 BA 기록 필요'
         WHEN sti.input_lot_id IS NULL THEN '스티칭 LOT 미연결: BA ' || ba.input_lot_date || ' 작업일보의 인서트 LOT 날짜 필요'
         WHEN inj.input_lot_id IS NULL THEN '사출 LOT 미연결: 스티칭 ' || sti.input_lot_date || ' 작업일보의 보빈 LOT 날짜 필요'
         WHEN resin.resin_lots IS NULL THEN '수지 LOT 미기재: 사출 ' || inj.input_lot_date || ' 작업일보의 수지 LOT 필요'
         ELSE '완전'
       END AS first_gap,
       (ba.input_lot_id IS NOT NULL)::int + (sti.input_lot_id IS NOT NULL)::int + (inj.input_lot_id IS NOT NULL)::int + (resin.resin_lots IS NOT NULL)::int AS depth
FROM ca
LEFT JOIN ba   ON ba.lot_id = ca.ca_lot_id
LEFT JOIN sti  ON sti.lot_id = ba.input_lot_id
LEFT JOIN inj  ON inj.lot_id = sti.input_lot_id
LEFT JOIN resin ON resin.inj_lot_id = inj.input_lot_id
LEFT JOIN insp ON insp.production_lot_id = ca.ca_lot_id;

GRANT SELECT ON public.m13_lot_chain, public.m13_lot_chain_gaps TO service_role, anon, authenticated;
