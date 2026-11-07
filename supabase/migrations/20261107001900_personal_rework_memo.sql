-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07 팀장: 10/28 리워크 투입이 갑자기 많은데 특이사항이 없다 — 나중에 확인 내용을 넣을 수 있게)
-- 리워크 기록에 특이사항(확인 메모)을 나중에 붙인다: rework_record.remark.memo(+ 적은 날짜). 원문(raw_note)은 그대로.
-- 메모를 적으면 '확인 필요' 상태를 '사람 확인'(VERIFIED)으로, 메모를 지우면 원래 상태(UNVERIFIED)로.
CREATE OR REPLACE FUNCTION public.m13_rework_memo(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE v_id uuid := nullif(p->>'rework_id', '')::uuid; v_memo text := nullif(btrim(coalesce(p->>'memo', '')), '');
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_rework_memo: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF v_memo IS NOT NULL AND char_length(v_memo) > 500 THEN RAISE EXCEPTION '특이사항은 500자까지'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.rework_record WHERE rework_id = v_id AND record_state = 'ACTIVE') THEN RAISE EXCEPTION '리워크 기록을 찾지 못했습니다'; END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[압입(CA)] 리워크 특이사항 · ' || coalesce(v_memo, '(지움)')), true);
  UPDATE mqi.rework_record
     SET remark = (CASE WHEN v_memo IS NULL THEN coalesce(public.m13_try_jsonb(remark), '{}'::jsonb) - 'memo' - 'memo_at'
                        ELSE coalesce(public.m13_try_jsonb(remark), '{}'::jsonb) || jsonb_build_object('memo', v_memo, 'memo_at', to_char(now() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD HH24:MI')) END)::text,
         validation_status = CASE WHEN v_memo IS NULL THEN 'UNVERIFIED' ELSE 'VERIFIED' END
   WHERE rework_id = v_id;
  RETURN jsonb_build_object('ok', true, 'rework_id', v_id, 'memo', v_memo);
END $fn$;
REVOKE ALL ON FUNCTION public.m13_rework_memo(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_rework_memo(jsonb) TO service_role;

CREATE OR REPLACE VIEW public.m13_rework_entries AS
SELECT rr.rework_id, pm.model_code, to_char(rr.work_date::timestamp with time zone, 'YYYY-MM-DD') AS work_date,
       public.m13_try_jsonb(rr.remark)->>'part' AS part, public.m13_try_jsonb(rr.remark)->>'part_ko' AS part_ko,
       rr.marked_lot_code_raw AS mark, rr.marked_lot_date, rr.serial_start_raw, rr.serial_end_raw, rr.serial_start_num, rr.serial_end_num,
       CASE WHEN rr.serial_start_num IS NOT NULL AND rr.serial_end_num IS NOT NULL THEN rr.serial_end_num - rr.serial_start_num + 1 END AS serial_count,
       rr.recorded_qty AS total_qty, rr.input_qty,
       (public.m13_try_jsonb(rr.remark)->>'true_qty')::int AS true_qty, (public.m13_try_jsonb(rr.remark)->>'false_qty')::int AS false_qty,
       (SELECT string_agg(qf.raw_defect_name || ' ' || qf.quantity, ', ' ORDER BY qf.quantity DESC) FROM mqi.process_run pr
          JOIN mqi.quality_finding qf ON qf.process_run_id = pr.process_run_id AND qf.record_state = 'ACTIVE'
         WHERE pr.record_state = 'ACTIVE' AND pr.work_type = 'REWORK' AND public.m13_try_jsonb(pr.remark)->>'rework_id' = rr.rework_id::text) AS true_types,
       (SELECT pl.lot_code_raw FROM mqi.rework_origin_link l JOIN mqi.production_lot pl ON pl.lot_id = l.original_lot_id
         WHERE l.rework_id = rr.rework_id AND l.record_state = 'ACTIVE' LIMIT 1) AS ca_lot_code,
       public.m13_try_jsonb(rr.remark)->'workers' AS workers, public.m13_try_jsonb(rr.remark)->>'check' AS check_note,
       public.m13_try_jsonb(rr.remark)#>>'{source,file}' AS file, rr.validation_status, rr.raw_note, rr.recorded_at,
       count(*) OVER (PARTITION BY rr.model_id, rr.work_date, rr.rework_type, rr.serial_start_num) AS same_count,
       rr.input_qty AS start_qty, rr.completed_qty, (public.m13_try_jsonb(rr.remark)->>'to_ca_qty')::int AS to_ca_qty,
       (public.m13_try_jsonb(rr.remark)->>'first_qty')::int AS first_qty,
       public.m13_try_jsonb(rr.remark)->>'memo' AS memo, public.m13_try_jsonb(rr.remark)->>'memo_at' AS memo_at
  FROM mqi.rework_record rr
  JOIN mqi.product_model pm ON pm.model_id = rr.model_id
 WHERE rr.record_state = 'ACTIVE';
