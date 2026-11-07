-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 팀장 요청: 최종검사 탭에도 저장 목록 · 삭제)
-- 1) 뷰 m13_final_entries: 최종검사 본검사(FINAL) 1건 = 1행(검사일·모델·차수·검사자(가린 이름)·검사 LOT·수량·불량·출처 파일/쪽·입력 시각, 같은 날·모델·검사자·수량 중복 수)
-- 2) RPC m13_final_void: 본검사 1건을 검사 LOT·불량·본검사↔재검 연결·출처 연결과 함께 VOID(재검사는 기존 m13_reinspection_void). 사유 5자 이상.
CREATE OR REPLACE VIEW public.m13_final_entries AS
WITH lots AS (
  SELECT inspection_run_id, string_agg(coalesce(lot_code_raw, '?'), ', ' ORDER BY lot_code_raw) AS lots, count(*) AS lot_rows
    FROM mqi.inspection_lot WHERE record_state::text = 'ACTIVE' GROUP BY inspection_run_id
), def AS (
  SELECT inspection_run_id, sum(quantity) AS defects FROM mqi.quality_finding WHERE record_state::text = 'ACTIVE' AND inspection_run_id IS NOT NULL GROUP BY inspection_run_id
), base AS (
  SELECT ir.inspection_run_id, pm.model_code, ir.inspection_date, ir.inspection_round_no, ir.inspected_qty_ea,
         w.worker_display_name AS inspector, lots.lots, coalesce(lots.lot_rows, 0) AS lot_rows, def.defects,
         m13_try_jsonb(ir.remark) AS rm, ir.recorded_at
    FROM mqi.inspection_run ir
    JOIN mqi.product_model pm ON pm.model_id = ir.model_id
    LEFT JOIN mqi.worker w ON w.worker_id = ir.inspector_id
    LEFT JOIN lots ON lots.inspection_run_id = ir.inspection_run_id
    LEFT JOIN def ON def.inspection_run_id = ir.inspection_run_id
   WHERE ir.record_state::text = 'ACTIVE' AND ir.inspection_type::text = 'FINAL'
)
SELECT inspection_run_id::text AS run_id, model_code,
       to_char(inspection_date::timestamp with time zone, 'YYYY-MM-DD') AS inspection_date,
       CASE WHEN inspection_round_no = 1 THEN '1차' ELSE '2차' END AS inspection_class,
       inspector, lots, lot_rows, inspected_qty_ea, defects,
       rm ->> 'file' AS file, rm ->> 'page' AS page,
       jsonb_array_length(coalesce(rm -> 'human_edits', '[]'::jsonb)) AS human_edits,
       recorded_at,
       count(*) OVER (PARTITION BY model_code, inspection_date, inspector, inspected_qty_ea, lots) AS same_count
  FROM base;

CREATE OR REPLACE FUNCTION public.m13_final_void(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'mqi', 'public'
SET default_transaction_isolation TO 'serializable'
AS $function$
DECLARE v_run uuid := nullif(p->>'run_id', '')::uuid; v_note text := btrim(coalesce(p->>'note', '')); n int := 0; k int;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_final_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF length(v_note) < 5 THEN RAISE EXCEPTION '삭제 사유는 5자 이상'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.inspection_run WHERE inspection_run_id = v_run AND inspection_type = 'FINAL' AND record_state = 'ACTIVE') THEN
    RAISE EXCEPTION '삭제할 수 있는 최종검사 본검사가 아닙니다(본검사·활성 기록만, 재검은 재검사 목록에서)';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[최종검사] 본검사 삭제(VOID) · ' || v_note), true);
  UPDATE mqi.quality_finding SET record_state = 'VOID' WHERE inspection_run_id = v_run AND record_state = 'ACTIVE'; GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  UPDATE mqi.inspection_lot SET record_state = 'VOID' WHERE inspection_run_id = v_run AND record_state = 'ACTIVE'; GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  UPDATE mqi.inspection_run_link SET record_state = 'VOID' WHERE (followup_inspection_run_id = v_run OR prior_inspection_run_id = v_run) AND record_state = 'ACTIVE'; GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  UPDATE mqi.field_provenance_link SET record_state = 'VOID' WHERE inspection_run_id = v_run AND record_state = 'ACTIVE'; GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  UPDATE mqi.source_run_link SET record_state = 'VOID' WHERE inspection_run_id = v_run AND record_state = 'ACTIVE'; GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  UPDATE mqi.inspection_run SET record_state = 'VOID' WHERE inspection_run_id = v_run; n := n + 1;
  RETURN jsonb_build_object('run_id', v_run, 'voided_rows', n);
END $function$;

REVOKE ALL ON FUNCTION public.m13_final_void(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_final_void(jsonb) TO service_role;
GRANT SELECT ON public.m13_final_entries TO service_role;
REVOKE ALL ON public.m13_final_entries FROM anon, authenticated;
