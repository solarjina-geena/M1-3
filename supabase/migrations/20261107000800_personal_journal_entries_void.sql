-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 팀장 요청: 작업일보 탭에 저장 목록 · 수정 · 중복 삭제)
-- 1) 뷰 m13_journal_entries: 저장된 작업일보 실행 1건 = 1행(공정·모델·작업일·출력 LOT·수량·불량·출처 파일/쪽·입력 시각, 같은 날·모델·공정·LOT 중복 수)
-- 2) RPC m13_journal_void: 잘못 저장한 실행 1건을 하위 기록(LOT 연결·결과·불량·소재·작업자·출처 연결 등)과 함께 VOID,
--    그 실행이 만든 출력 LOT 은 다른 곳에서 안 쓰면 같이 VOID. 행은 지우지 않는다. 사유 5자 이상(CRUD 이력).
CREATE OR REPLACE VIEW public.m13_journal_entries AS
WITH outl AS (
  SELECT prl.process_run_id, string_agg(DISTINCT l.lot_code_raw::text, '/') AS lot_code
    FROM mqi.process_run_lot prl JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
   WHERE prl.lot_role::text = 'OUTPUT' AND prl.record_state::text = 'ACTIVE'
   GROUP BY prl.process_run_id
), res AS (
  SELECT process_run_id, max(gross_output_qty) AS qty, max(work_minutes) AS minutes
    FROM mqi.process_run_result WHERE record_state::text = 'ACTIVE' GROUP BY process_run_id
), def AS (
  SELECT process_run_id, sum(quantity) AS defects, count(*) AS defect_rows
    FROM mqi.quality_finding WHERE record_state::text = 'ACTIVE' AND process_run_id IS NOT NULL GROUP BY process_run_id
), base AS (
  SELECT pr.process_run_id, pm.model_code, pc.process_code, pr.work_date, pr.sequence_no, outl.lot_code,
         res.qty, res.minutes, def.defects, coalesce(def.defect_rows, 0) AS defect_rows,
         m13_try_jsonb(pr.remark) AS rm, pr.recorded_at
    FROM mqi.process_run pr
    JOIN mqi.product_model pm ON pm.model_id = pr.model_id
    JOIN mqi.process pc ON pc.process_id = pr.process_id
    LEFT JOIN outl ON outl.process_run_id = pr.process_run_id
    LEFT JOIN res ON res.process_run_id = pr.process_run_id
    LEFT JOIN def ON def.process_run_id = pr.process_run_id
   WHERE pr.record_state::text = 'ACTIVE'
)
SELECT process_run_id::text AS run_id, model_code, process_code,
       to_char(work_date::timestamp with time zone, 'YYYY-MM-DD') AS work_date,
       CASE WHEN lot_code ~ 'N\d+$' THEN 'N' WHEN lot_code ~ 'D\d+$' THEN 'D' ELSE NULL END AS shift,
       sequence_no, lot_code, qty, minutes, defects, defect_rows,
       rm ->> 'file' AS file, rm ->> 'page' AS page, rm ->> 'method' AS method,
       jsonb_array_length(coalesce(rm -> 'human_edits', '[]'::jsonb)) AS human_edits,
       recorded_at,
       count(*) OVER (PARTITION BY model_code, process_code, work_date, lot_code) AS same_count
  FROM base;

CREATE OR REPLACE FUNCTION public.m13_journal_void(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'mqi', 'public'
SET default_transaction_isolation TO 'serializable'
AS $function$
DECLARE v_run uuid := nullif(p->>'run_id', '')::uuid; v_note text := btrim(coalesce(p->>'note', '')); t text; n int; out jsonb := '{}'::jsonb; v_lots uuid[];
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_journal_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF v_run IS NULL THEN RAISE EXCEPTION '삭제할 작업일보가 없습니다'; END IF;
  IF length(v_note) < 5 THEN RAISE EXCEPTION '삭제 사유는 5자 이상'; END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[작업일보] 삭제(VOID) · ' || v_note), true);
  IF NOT EXISTS (SELECT 1 FROM mqi.process_run WHERE process_run_id = v_run AND record_state = 'ACTIVE') THEN
    RAISE EXCEPTION '이미 삭제되었거나 없는 작업일보입니다';
  END IF;
  SELECT array_agg(DISTINCT production_lot_id) INTO v_lots FROM mqi.process_run_lot
   WHERE process_run_id = v_run AND lot_role = 'OUTPUT' AND record_state = 'ACTIVE';
  FOREACH t IN ARRAY ARRAY['field_provenance_link','material_usage','parameter_observation','process_equipment_usage','process_run_lot',
                           'process_run_result','production_event','quality_finding','source_run_link','worker_assignment','quality_check'] LOOP
    EXECUTE format('UPDATE mqi.%I SET record_state = ''VOID'' WHERE process_run_id = $1 AND record_state = ''ACTIVE''', t) USING v_run;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN out := out || jsonb_build_object(t, n); END IF;
  END LOOP;
  UPDATE mqi.production_lot SET record_state = 'VOID'
   WHERE lot_id = ANY (coalesce(v_lots, '{}')) AND record_state = 'ACTIVE'
     AND NOT EXISTS (SELECT 1 FROM mqi.process_run_lot x WHERE x.production_lot_id = production_lot.lot_id AND x.record_state = 'ACTIVE')
     AND NOT EXISTS (SELECT 1 FROM mqi.inspection_lot il WHERE il.production_lot_id = production_lot.lot_id AND il.record_state = 'ACTIVE');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n > 0 THEN out := out || jsonb_build_object('production_lot', n); END IF;
  UPDATE mqi.process_run SET record_state = 'VOID' WHERE process_run_id = v_run;
  RETURN jsonb_build_object('run_id', v_run, 'voided', out);
END $function$;

REVOKE ALL ON FUNCTION public.m13_journal_void(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_journal_void(jsonb) TO service_role;
GRANT SELECT ON public.m13_journal_entries TO service_role;
REVOKE ALL ON public.m13_journal_entries FROM anon, authenticated;
