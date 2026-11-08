-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다.
-- (2026-11-08 팀장) 리워크 일보는 10/16 부터 도입 — 그 전(예: 10/15)은 리워크를 조립 작업일보 양식에 적었다.
-- 이미 '일반 생산'으로 저장된 조립 일보(권선 BA·압입 CA)를 '하루 전체 리워크'로 바꾼다(되돌리기 가능).
--   process_run.work_type PRODUCTION → REWORK (팀 허용값) → 생산량·LOT 흐름·불량 그래프에서 자동으로 빠지고 리워크 탭에 나타남
--   rework_record 1건씩(권선 = 용접부 BA_VISION_RECOVERY, 압입 = 조립부 OTHER): 리워크 투입 = 그 일보 생산 수량, 시리얼 칸 없음(비움)
--   rework_origin_link → 그 실행의 OUTPUT LOT(같은 날 CA LOT), 원래 실행 id 를 그대로 근거로
--   그 실행에 달린 불량(quality_finding)은 그대로 두면 리워크 불량으로 보임(일반 불량 그래프에서는 빠짐)
CREATE OR REPLACE FUNCTION public.m13_journal_to_rework(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_run uuid; v_undo boolean := coalesce((p->>'undo')::boolean, false); v_note text := nullif(btrim(coalesce(p->>'note', '')), '');
  r record; v_rw uuid; v_part text; v_lot uuid; v_code text; v_def int; n int := 0; v_out jsonb := '[]'::jsonb;
  v_model uuid; v_date date; v_abs uuid[]; v_absnote text;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_journal_to_rework: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  SELECT pr.run_id INTO v_run FROM mqi.process_run pr WHERE pr.process_run_id = nullif(p->>'process_run_id', '')::uuid AND pr.record_state = 'ACTIVE';
  IF v_run IS NULL THEN RAISE EXCEPTION '작업일보 기록을 찾지 못했습니다'; END IF;
  SELECT model_id, work_date INTO v_model, v_date FROM mqi.production_run WHERE run_id = v_run;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''),
    CASE WHEN v_undo THEN '[압입(CA)] 리워크 → 일반 생산으로 되돌림' ELSE '[압입(CA)] 조립 작업일보를 리워크로 바꿈(리워크 일보 도입 전)' END
    || coalesce(' · ' || v_note, '')), true);

  -- 조립 일보 저장 때 비고의 '리워크 작업수량'으로 따로 생긴 리워크 줄(구분 없음)은 흡수: 원문을 새 기록에 옮기고 무효(되돌리면 복구)
  IF NOT v_undo THEN
    SELECT array_agg(rework_id), string_agg(raw_note, ' / ') INTO v_abs, v_absnote FROM mqi.rework_record
     WHERE record_state = 'ACTIVE' AND model_id = v_model AND work_date = v_date AND public.m13_try_jsonb(remark)->>'part' IS NULL;
    IF v_abs IS NOT NULL THEN
      UPDATE mqi.rework_record SET record_state = 'VOID' WHERE rework_id = ANY (v_abs);
      v_note := coalesce(v_note, '') || CASE WHEN v_note IS NULL THEN '' ELSE ' · ' END || '일보 원문: ' || coalesce(v_absnote, '');
    END IF;
  END IF;
  -- 같은 생산 실행(그날·모델·교대) 아래 권선·압입을 한 번에
  FOR r IN SELECT pr.process_run_id, pr.model_id, pr.work_date, pr.work_type, pc.process_code, pr.remark,
                  prr.gross_output_qty, prr.work_minutes
             FROM mqi.process_run pr JOIN mqi.process pc ON pc.process_id = pr.process_id
             LEFT JOIN mqi.process_run_result prr ON prr.process_run_id = pr.process_run_id AND prr.record_state = 'ACTIVE'
            WHERE pr.run_id = v_run AND pr.record_state = 'ACTIVE' AND pc.process_code IN ('IMEB3_WINDING', 'IMEB3_CA_PRESS')
              AND (CASE WHEN v_undo THEN pr.work_type = 'REWORK' AND public.m13_try_jsonb(pr.remark) ? 'from_journal'
                        ELSE pr.work_type IS DISTINCT FROM 'REWORK' END)
  LOOP
    v_part := CASE r.process_code WHEN 'IMEB3_WINDING' THEN 'WELD' ELSE 'ASSEMBLY' END;
    IF v_undo THEN
      v_rw := (public.m13_try_jsonb(r.remark)->>'rework_id')::uuid;
      UPDATE mqi.rework_record SET record_state = 'ACTIVE'
       WHERE record_state = 'VOID' AND rework_id::text IN (SELECT jsonb_array_elements_text(coalesce(public.m13_try_jsonb(x.remark)->'absorbed', '[]'::jsonb))
                                                            FROM mqi.rework_record x WHERE x.rework_id = v_rw);
      UPDATE mqi.rework_origin_link SET record_state = 'VOID' WHERE rework_id = v_rw AND record_state = 'ACTIVE';
      UPDATE mqi.rework_record SET record_state = 'VOID' WHERE rework_id = v_rw AND record_state = 'ACTIVE';
      UPDATE mqi.process_run
         SET work_type = coalesce(public.m13_try_jsonb(remark)->>'from_work_type', 'PRODUCTION'),
             remark = (public.m13_try_jsonb(remark) - 'rework_id' - 'part' - 'part_ko' - 'start_qty' - 'from_journal' - 'from_work_type')::text
       WHERE process_run_id = r.process_run_id;
    ELSE
      SELECT prl.production_lot_id INTO v_lot FROM mqi.process_run_lot prl
       WHERE prl.process_run_id = r.process_run_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE' LIMIT 1;
      IF v_lot IS NULL THEN   -- 권선은 OUTPUT 이 없을 수 있음 → 같은 실행의 압입 OUTPUT LOT
        SELECT prl.production_lot_id INTO v_lot FROM mqi.process_run_lot prl
          JOIN mqi.process_run pr2 ON pr2.process_run_id = prl.process_run_id AND pr2.run_id = v_run AND pr2.record_state = 'ACTIVE'
          JOIN mqi.process pc2 ON pc2.process_id = pr2.process_id AND pc2.process_code = 'IMEB3_CA_PRESS'
         WHERE prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE' LIMIT 1;
      END IF;
      SELECT lot_code_raw INTO v_code FROM mqi.production_lot WHERE lot_id = v_lot;
      SELECT coalesce(sum(quantity), 0) INTO v_def FROM mqi.quality_finding WHERE process_run_id = r.process_run_id AND record_state = 'ACTIVE';
      v_rw := gen_random_uuid();
      INSERT INTO mqi.rework_record (rework_id, model_id, rework_type, work_date, marked_lot_code_raw, marked_lot_date,
                                     recorded_qty, recorded_qty_basis, input_qty, completed_qty, work_minutes, validation_status, raw_note, remark)
      VALUES (v_rw, r.model_id, CASE v_part WHEN 'WELD' THEN 'BA_VISION_RECOVERY' ELSE 'OTHER' END, r.work_date,
              NULL, r.work_date, v_def, 'DIRECT_COUNT', r.gross_output_qty, NULL, r.work_minutes, 'UNVERIFIED',
              coalesce(v_note, '조립 작업일보에 적힌 리워크(리워크 일보 도입 전)'),
              jsonb_strip_nulls(jsonb_build_object('part', v_part,
                 'part_ko', CASE v_part WHEN 'WELD' THEN '용접부 · BA 리워크' ELSE '조립부 · CA 압입 결과' END,
                 'from_journal_run', r.process_run_id, 'absorbed', to_jsonb(v_abs), 'basis', '조립 작업일보 하루 전체 = 리워크(팀장 2026-11-08)',
                 'source', jsonb_strip_nulls(jsonb_build_object('file', public.m13_try_jsonb(r.remark)->>'file', 'page', public.m13_try_jsonb(r.remark)->'page'))))::text);
      IF v_lot IS NOT NULL THEN
        INSERT INTO mqi.rework_origin_link (rework_id, original_lot_id, original_process_run_id, linkage_status, linkage_method, evidence_note, model_id)
        VALUES (v_rw, v_lot, r.process_run_id, 'CONFIRMED', 'DIRECT_RECORD', '조립 작업일보(리워크 작업) 그날 LOT ' || coalesce(v_code, ''), r.model_id);
      END IF;
      UPDATE mqi.process_run
         SET work_type = 'REWORK',
             remark = (coalesce(public.m13_try_jsonb(remark), jsonb_build_object('orig_remark', remark)) || jsonb_build_object(
                        'rework_id', v_rw, 'part', v_part,
                        'part_ko', CASE v_part WHEN 'WELD' THEN '용접부 · BA 리워크' ELSE '조립부 · CA 압입 결과' END,
                        'start_qty', r.gross_output_qty, 'from_journal', true, 'from_work_type', coalesce(r.work_type, 'PRODUCTION')))::text
       WHERE process_run_id = r.process_run_id;
    END IF;
    n := n + 1;
    v_out := v_out || jsonb_build_object('process', r.process_code, 'qty', r.gross_output_qty, 'rework_id', v_rw);
  END LOOP;
  IF n = 0 THEN RAISE EXCEPTION '%', CASE WHEN v_undo THEN '되돌릴 리워크(조립 일보에서 바꾼 것)가 없습니다' ELSE '바꿀 권선·압입 기록이 없습니다(이미 리워크이거나 조립 일보가 아님)' END; END IF;
  RETURN jsonb_build_object('ok', true, 'undo', v_undo, 'changed', n, 'items', v_out);
END $fn$;
REVOKE ALL ON FUNCTION public.m13_journal_to_rework(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_journal_to_rework(jsonb) TO service_role;

-- 리워크 목록에서 '조립 일보로 되돌리기' 단추를 보이게: 조립 일보에서 바꾼 리워크의 원래 실행 id
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
       public.m13_try_jsonb(rr.remark)->>'memo' AS memo, public.m13_try_jsonb(rr.remark)->>'memo_at' AS memo_at,
       public.m13_try_jsonb(rr.remark)->>'from_journal_run' AS from_journal_run
  FROM mqi.rework_record rr
  JOIN mqi.product_model pm ON pm.model_id = rr.model_id
 WHERE rr.record_state = 'ACTIVE';
