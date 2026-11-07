-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07 팀장: "리워크랑 재검이랑 다르다")
-- 리워크는 다시 보는 검사가 아니라 다시 작업하는 공정 → 팀 설계의 process_run.work_type = 'REWORK' 로 저장한다(20261107001400 의 '리워크 재검' 검사 기록 방식을 대체).
--   rework_record(1건) ── remark.rework_id ── process_run(CA 공정, work_type REWORK, 그날 그 모델 production_run 아래 다음 순번)
--   진성 불량 = 그 리워크 실행의 PROCESS_DEFECT(유형별, defect_type 'RW:이름') · 가성 = 불량이 아니라 다시 투입한 수량 → rework_record 에 숫자로
--   마킹 LOT → CA LOT = rework_origin_link(DIRECT_RECORD) — CA 생산 실행의 LOT 수(OUTPUT) 계산을 흐리지 않게 process_run_lot 은 만들지 않는다
-- 리워크 실행은 생산 집계에 섞이지 않게 m13_daily_production · m13_journal_entries · m13_defect_by_type 에서 뺀다(리워크는 m13_rework_entries 로 따로 본다).
DO $do$
DECLARE d text; v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['public.m13_daily_production', 'public.m13_journal_entries'] LOOP
    d := pg_get_viewdef(v::regclass);
    IF position($x$WHERE ((pr.record_state)::text = 'ACTIVE'::text)$x$ in d) = 0 THEN RAISE EXCEPTION '% anchor missing', v; END IF;
    d := replace(d, $x$WHERE ((pr.record_state)::text = 'ACTIVE'::text)$x$,
                 $x$WHERE ((pr.record_state)::text = 'ACTIVE'::text) AND (pr.work_type IS DISTINCT FROM 'REWORK')$x$);
    EXECUTE 'CREATE OR REPLACE VIEW ' || v || ' AS ' || d;
  END LOOP;
END $do$;

CREATE OR REPLACE VIEW public.m13_defect_by_type AS
SELECT pm.model_code,
       COALESCE(pc.process_code, 'IMEB3_FINAL_INSPECTION'::character varying) AS process_code,
       dt.defect_name,
       qf.finding_class,
       COALESCE(pr.work_date, ir.inspection_date) AS the_date,
       sum(qf.quantity) AS qty,
       count(*) AS findings
  FROM mqi.quality_finding qf
  JOIN mqi.product_model pm ON pm.model_id = qf.model_id
  JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
  LEFT JOIN mqi.process_run pr ON pr.process_run_id = qf.process_run_id
  LEFT JOIN mqi.process pc ON pc.process_id = pr.process_id
  LEFT JOIN mqi.inspection_run ir ON ir.inspection_run_id = qf.inspection_run_id
 WHERE qf.record_state::text = 'ACTIVE'
   AND (ir.inspection_stage IS NULL OR ir.inspection_stage::text NOT LIKE 'VISION%')
   AND (pr.work_type IS NULL OR pr.work_type::text <> 'REWORK')
 GROUP BY pm.model_code, COALESCE(pc.process_code, 'IMEB3_FINAL_INSPECTION'::character varying), dt.defect_name, qf.finding_class,
          COALESCE(pr.work_date, ir.inspection_date);

CREATE OR REPLACE FUNCTION public.m13_rework_void(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE v_id uuid := nullif(p->>'rework_id', '')::uuid; v_pr uuid[];
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_rework_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF char_length(btrim(coalesce(p->>'note', ''))) < 5 THEN RAISE EXCEPTION '삭제 사유를 5자 이상 적어 주세요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.rework_record WHERE rework_id = v_id AND record_state = 'ACTIVE') THEN RAISE EXCEPTION '삭제할 수 있는 리워크 기록이 아닙니다'; END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[압입(CA)] 리워크 삭제(VOID) · ' || (p->>'note')), true);
  SELECT array_agg(process_run_id) INTO v_pr FROM mqi.process_run
   WHERE record_state = 'ACTIVE' AND work_type = 'REWORK' AND public.m13_try_jsonb(remark)->>'rework_id' = v_id::text;
  UPDATE mqi.quality_finding SET record_state = 'VOID' WHERE record_state = 'ACTIVE' AND process_run_id = ANY (coalesce(v_pr, '{}'));
  UPDATE mqi.process_run SET record_state = 'VOID' WHERE process_run_id = ANY (coalesce(v_pr, '{}'));
  UPDATE mqi.rework_origin_link SET record_state = 'VOID' WHERE rework_id = v_id AND record_state = 'ACTIVE';
  UPDATE mqi.rework_record SET record_state = 'VOID' WHERE rework_id = v_id;
  RETURN jsonb_build_object('ok', true, 'rework_id', v_id);
END $fn$;

CREATE OR REPLACE FUNCTION public.m13_rework_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_model uuid; v_date date := (p->>'work_date')::date; v_part text := p->>'part';
  v_rw uuid; v_run uuid; v_rpr uuid; v_proc uuid; v_seq int; v_lot uuid; v_pr uuid; v_code text; v_old uuid[]; v_void int := 0; e jsonb; o int := 0;
  v_s1 bigint := nullif(regexp_replace(coalesce(p->>'serial_start', ''), '\D', '', 'g'), '')::bigint;
  v_s2 bigint := nullif(regexp_replace(coalesce(p->>'serial_end', ''), '\D', '', 'g'), '')::bigint;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_rework_save: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF v_part NOT IN ('WELD', 'ASSEMBLY') THEN RAISE EXCEPTION '리워크 구분은 용접부(WELD) 또는 조립부(ASSEMBLY)'; END IF;
  IF v_date IS NULL THEN RAISE EXCEPTION '리워크 날짜가 필요합니다'; END IF;
  SELECT model_id INTO v_model FROM mqi.product_model WHERE model_code = p->>'model' AND record_state = 'ACTIVE' LIMIT 1;
  IF v_model IS NULL THEN RAISE EXCEPTION '모델을 찾지 못했습니다: %', p->>'model'; END IF;
  IF v_s1 IS NOT NULL AND v_s2 IS NOT NULL AND v_s2 < v_s1 THEN RAISE EXCEPTION 'S/N 끝(%)이 시작(%)보다 작습니다', v_s2, v_s1; END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[압입(CA)] 리워크 작업일보 입력'), true);

  SELECT array_agg(rework_id) INTO v_old FROM mqi.rework_record
   WHERE record_state = 'ACTIVE' AND model_id = v_model AND work_date = v_date
     AND rework_type = CASE v_part WHEN 'WELD' THEN 'BA_VISION_RECOVERY' ELSE 'CA_REMARKING' END
     AND serial_start_num IS NOT DISTINCT FROM v_s1 AND serial_end_num IS NOT DISTINCT FROM v_s2;
  IF v_old IS NOT NULL THEN
    IF NOT coalesce((p->>'replace')::boolean, false) THEN RETURN jsonb_build_object('ok', false, 'exists', true); END IF;
    PERFORM public.m13_rework_void(jsonb_build_object('rework_id', x, 'note', '같은 리워크 다시 저장(기존 기록 바꾸기)', 'actor', p->>'actor')) FROM unnest(v_old) x;
    v_void := cardinality(v_old);
  END IF;

  v_rw := gen_random_uuid();
  INSERT INTO mqi.rework_record (rework_id, model_id, rework_type, work_date, marked_lot_code_raw, marked_lot_date, serial_start_raw, serial_end_raw,
                                 serial_start_num, serial_end_num, recorded_qty, recorded_qty_basis, input_qty, completed_qty, work_minutes,
                                 validation_status, raw_note, remark)
  VALUES (v_rw, v_model, CASE v_part WHEN 'WELD' THEN 'BA_VISION_RECOVERY' ELSE 'CA_REMARKING' END, v_date,
          nullif(upper(btrim(coalesce(p->>'mark', ''))), ''), nullif(p->>'mark_date', '')::date,
          nullif(btrim(coalesce(p->>'serial_start', '')), ''), nullif(btrim(coalesce(p->>'serial_end', '')), ''), v_s1, v_s2,
          nullif(p->>'total_qty', '')::int, CASE WHEN nullif(p->>'total_qty', '') IS NULL THEN 'UNKNOWN' ELSE 'DIRECT_COUNT' END,
          nullif(p->>'input_qty', '')::int, NULL, nullif(p->>'work_minutes', '')::int,
          CASE WHEN nullif(p->>'check', '') IS NULL THEN 'UNVERIFIED' ELSE 'NEEDS_REVIEW' END,
          nullif(p->>'raw_note', ''),
          jsonb_strip_nulls(jsonb_build_object('part', v_part, 'part_ko', CASE v_part WHEN 'WELD' THEN '용접부 리워크' ELSE '조립부 리워크' END,
                            'true_qty', nullif(p->>'true_qty', '')::int, 'false_qty', nullif(p->>'false_qty', '')::int,
                            'rows', p->'rows', 'workers', p->'workers_masked', 'check', nullif(p->>'check', ''), 'source', p->'source'))::text);

  -- 마킹 LOT → CA LOT (양식에 적힌 마킹, 조견표 날짜 + D1). 없으면 미연결(추정 안 함)
  IF nullif(p->>'mark_date', '') IS NOT NULL THEN
    v_code := to_char((p->>'mark_date')::date, 'YYMMDD') || 'D1';
    v_lot := public.m13_find_lot(v_model, 'IMEB3_CA_PRESS', v_code);
    IF v_lot IS NOT NULL THEN
      SELECT CASE WHEN count(*) = 1 THEN (array_agg(prl.process_run_id))[1] END INTO v_pr
        FROM mqi.process_run_lot prl JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id AND pr.record_state = 'ACTIVE'
        JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code = 'IMEB3_CA_PRESS'
       WHERE prl.production_lot_id = v_lot AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE';
      INSERT INTO mqi.rework_origin_link (rework_id, original_lot_id, original_process_run_id, linkage_status, linkage_method, evidence_note, model_id)
      VALUES (v_rw, v_lot, v_pr, 'CONFIRMED', 'DIRECT_RECORD', '리워크 일보 S/N 칸 마킹 ' || upper(coalesce(p->>'mark', '')) || ' → CA LOT ' || v_code, v_model);
    END IF;
  END IF;

  -- 리워크 작업 실행(CA 공정, REWORK): 그날 그 모델 생산 실행 아래 다음 순번. 생산 실행이 없으면 하나 만든다
  SELECT process_id INTO v_proc FROM mqi.process WHERE process_code = 'IMEB3_CA_PRESS';
  SELECT run_id INTO v_run FROM mqi.production_run WHERE model_id = v_model AND work_date = v_date AND record_state = 'ACTIVE'
   ORDER BY (shift = 'D') DESC, run_sequence LIMIT 1;
  IF v_run IS NULL THEN
    v_run := gen_random_uuid();
    INSERT INTO mqi.production_run (run_id, model_id, work_date, shift, run_sequence, run_type, remark)
    VALUES (v_run, v_model, v_date, 'D', 1, 'PRODUCTION', jsonb_build_object('note', '리워크 작업일보로 만든 생산 실행(그날 생산 일보 미입력)', 'rework_id', v_rw)::text);
  END IF;
  SELECT coalesce(max(sequence_no), 0) + 1 INTO v_seq FROM mqi.process_run WHERE run_id = v_run AND process_id = v_proc;
  v_rpr := gen_random_uuid();
  INSERT INTO mqi.process_run (process_run_id, run_id, process_id, work_date, sequence_no, work_type, remark, model_id)
  VALUES (v_rpr, v_run, v_proc, v_date, v_seq, 'REWORK',
          jsonb_build_object('rework_id', v_rw, 'part', v_part, 'part_ko', CASE v_part WHEN 'WELD' THEN '용접부 리워크' ELSE '조립부 리워크' END,
                             'source', p->'source')::text, v_model);

  -- 진성 불량 = 리워크 실행의 공정 불량(유형별). 가성은 불량이 아니라 다시 투입한 수량이라 rework_record 숫자로만
  INSERT INTO mqi.defect_type (defect_type_id, defect_code, defect_name, defect_category, description)
  SELECT DISTINCT md5('m13:dt:RW:' || (x->>'name'))::uuid, 'RW:' || (x->>'name'), x->>'name', 'RW', '리워크 작업일보 불량 유형 이름 그대로'
    FROM jsonb_array_elements(coalesce(p->'findings', '[]'::jsonb)) x
   WHERE x->>'class' <> 'FALSE' AND nullif(x->>'name', '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mqi.defect_type WHERE defect_code = 'RW:' || (x->>'name'));
  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(p->'findings', '[]'::jsonb)) LOOP
    IF e->>'class' <> 'FALSE' AND coalesce((e->>'qty')::int, 0) > 0 THEN
      INSERT INTO mqi.quality_finding (quality_finding_id, process_run_id, defect_type_id, finding_class, quantity, quantity_unit, raw_quantity_text,
                                       raw_defect_name, validation_status, remark, model_id)
      VALUES (md5(v_rpr::text || ':f' || o)::uuid, v_rpr, CASE WHEN nullif(e->>'name', '') IS NOT NULL THEN md5('m13:dt:RW:' || (e->>'name'))::uuid END,
              'PROCESS_DEFECT', (e->>'qty')::int, 'EA', e->>'qty', coalesce(nullif(e->>'name', ''), '진성(유형 미기재)'), 'UNVERIFIED',
              jsonb_build_object('rework_id', v_rw)::text, v_model);
      o := o + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'rework_id', v_rw, 'rework_run_id', v_rpr, 'ca_lot', CASE WHEN v_lot IS NOT NULL THEN v_code END,
                            'ca_run_linked', v_pr IS NOT NULL, 'defects', o, 'replaced', v_void);
END $fn$;

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
       count(*) OVER (PARTITION BY rr.model_id, rr.work_date, rr.rework_type, rr.serial_start_num) AS same_count
  FROM mqi.rework_record rr
  JOIN mqi.product_model pm ON pm.model_id = rr.model_id
 WHERE rr.record_state = 'ACTIVE';
