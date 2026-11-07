-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07 팀장: LOT 별 리워크 진행 수량은 있어야 한다)
-- 1) m13_rework_save: 마킹 LOT(조견표 날짜 + D1)의 CA LOT 이 아직 없으면 재검과 같은 방식으로 'CA 작업일보 미확인' LOT(NEEDS_REVIEW)을 만들어 연결.
--    나중에 그날 CA 작업일보를 넣으면 같은 LOT 코드로 이어진다(m13_find_lot 이 이 LOT 을 인정). 마킹을 날짜로 못 풀면 지금처럼 미연결.
-- 2) 이미 저장된 리워크 중 마킹 날짜는 있는데 CA LOT 연결이 없는 것을 같은 규칙으로 연결(10/16 4건).
-- 3) 뷰 m13_rework_by_lot: CA LOT 별 리워크 진행 수량(용접부·조립부 리워크 투입, 진성, 시리얼 범위).
DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.m13_rework_save(jsonb)'::regprocedure);
  IF position($x$    v_lot := public.m13_find_lot(v_model, 'IMEB3_CA_PRESS', v_code);
    IF v_lot IS NOT NULL THEN$x$ in d) = 0 THEN RAISE EXCEPTION 'lot anchor missing'; END IF;
  d := replace(d, $x$    v_lot := public.m13_find_lot(v_model, 'IMEB3_CA_PRESS', v_code);
    IF v_lot IS NOT NULL THEN$x$, $x$    v_lot := public.m13_find_lot(v_model, 'IMEB3_CA_PRESS', v_code);
    IF v_lot IS NULL THEN   -- (2026-11-07) CA 일보 미입력: 재검과 같은 'CA 작업일보 미확인' LOT 을 만들어 LOT 별 리워크 수량을 남긴다
      v_lot := gen_random_uuid();
      INSERT INTO mqi.production_lot (lot_id, model_id, lot_date, lot_code_raw, verification_status, remark)
      VALUES (v_lot, v_model, (p->>'mark_date')::date, v_code, 'NEEDS_REVIEW',
              jsonb_build_object('process_code', 'IMEB3_CA_PRESS', 'note', '리워크 마킹으로 참조된 CA LOT(CA 작업일보 미확인)',
                                 'marking_code', upper(coalesce(p->>'mark', '')), 'by', 'm13_rework_save')::text);
    END IF;
    IF v_lot IS NOT NULL THEN$x$);
  EXECUTE d;
END $do$;

-- 이미 저장된 리워크 중 미연결 → 같은 규칙으로 연결
-- (mqi 쓰기는 SERIALIZABLE 트랜잭션에서만 되므로 실제로는 BEGIN ISOLATION LEVEL SERIALIZABLE; … COMMIT; 안에서 따로 실행함, 2026-11-07)
DO $do$
DECLARE r record; v_lot uuid; v_code text; v_pr uuid;
BEGIN
  PERFORM set_config('mqi.actor_ref', 'claude:migration', true);
  PERFORM set_config('mqi.change_reason', '[압입(CA)] 리워크 CA LOT 연결 보완 · CA 일보 미입력 날짜는 CA 작업일보 미확인 LOT 으로(팀장 2026-11-07)', true);
  FOR r IN SELECT rr.* FROM mqi.rework_record rr
            WHERE rr.record_state = 'ACTIVE' AND rr.marked_lot_date IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM mqi.rework_origin_link l WHERE l.rework_id = rr.rework_id AND l.record_state = 'ACTIVE') LOOP
    v_code := to_char(r.marked_lot_date, 'YYMMDD') || 'D1';
    v_lot := public.m13_find_lot(r.model_id, 'IMEB3_CA_PRESS', v_code);
    IF v_lot IS NULL THEN
      v_lot := gen_random_uuid();
      INSERT INTO mqi.production_lot (lot_id, model_id, lot_date, lot_code_raw, verification_status, remark)
      VALUES (v_lot, r.model_id, r.marked_lot_date, v_code, 'NEEDS_REVIEW',
              jsonb_build_object('process_code', 'IMEB3_CA_PRESS', 'note', '리워크 마킹으로 참조된 CA LOT(CA 작업일보 미확인)',
                                 'marking_code', r.marked_lot_code_raw, 'by', 'migration 20261107001800')::text);
    END IF;
    SELECT CASE WHEN count(*) = 1 THEN (array_agg(prl.process_run_id))[1] END INTO v_pr
      FROM mqi.process_run_lot prl JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id AND pr.record_state = 'ACTIVE'
      JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code = 'IMEB3_CA_PRESS'
     WHERE prl.production_lot_id = v_lot AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE';
    INSERT INTO mqi.rework_origin_link (rework_id, original_lot_id, original_process_run_id, linkage_status, linkage_method, evidence_note, model_id)
    VALUES (r.rework_id, v_lot, v_pr, 'CONFIRMED', 'DIRECT_RECORD', '리워크 일보 S/N 칸 마킹 ' || coalesce(r.marked_lot_code_raw, '') || ' → CA LOT ' || v_code, r.model_id);
  END LOOP;
END $do$;

CREATE OR REPLACE VIEW public.m13_rework_by_lot AS
SELECT e.model_code, e.ca_lot_code, string_agg(DISTINCT e.mark, '/') AS mark,
       min(e.work_date) AS first_rework, max(e.work_date) AS last_rework, count(*) AS reworks,
       sum(e.start_qty) FILTER (WHERE e.part = 'WELD') AS weld_rework_qty, sum(e.first_qty) FILTER (WHERE e.part = 'WELD') AS weld_first_qty,
       sum(e.true_qty) FILTER (WHERE e.part = 'WELD') AS weld_true_qty,
       sum(e.start_qty) FILTER (WHERE e.part = 'ASSEMBLY') AS assembly_rework_qty, sum(e.true_qty) FILTER (WHERE e.part = 'ASSEMBLY') AS assembly_true_qty,
       min(e.serial_start_num) AS serial_min, max(e.serial_end_num) AS serial_max,
       bool_or(pl.verification_status = 'NEEDS_REVIEW' AND public.m13_try_jsonb(pl.remark)->>'note' LIKE '%CA 작업일보 미확인%') AS ca_journal_missing
  FROM public.m13_rework_entries e
  LEFT JOIN mqi.rework_origin_link l ON l.rework_id = e.rework_id AND l.record_state = 'ACTIVE'
  LEFT JOIN mqi.production_lot pl ON pl.lot_id = l.original_lot_id
 WHERE e.ca_lot_code IS NOT NULL
 GROUP BY e.model_code, e.ca_lot_code;

GRANT SELECT ON public.m13_rework_by_lot TO service_role;
REVOKE ALL ON public.m13_rework_by_lot FROM anon, authenticated;
