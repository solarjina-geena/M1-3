-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 사용자 요청: CA 공정 리워크 작업일보 OCR 입력 · 시리얼 범위 추적)
-- 리워크 작업일보 1칸(모델 × 용접부/조립부) = 리워크 1건. 팀 표 그대로:
--   rework_record      : rework_type(용접부 = BA_VISION_RECOVERY, 조립부 = CA_REMARKING), 마킹 LOT(marked_lot_code_raw·marked_lot_date),
--                        S/N 시작·끝(serial_*_raw/num), 총 수량(recorded_qty, DIRECT_COUNT), 투입 수량(input_qty = 가성 → 다시 투입)
--   rework_origin_link : 마킹 LOT(조견표 날짜 YYMMDD+D1)의 CA LOT 에 연결(DIRECT_RECORD, 양식에 적힌 마킹) — CA LOT 이 없으면 미연결(추정 안 함)
--   inspection_run     : 리워크 재검 1건(IN_PROCESS · 단계 OTHER · 범위 TARGETED, raw_inspection_label '리워크 재검 …'), 그 CA LOT 의 CA 실행이 1건이면 process_run FK
--   quality_finding    : 진성(TRUE_DEFECT, 유형별) · 가성(FALSE_REJECT, 유형별) — 불량 유형 이름은 defect_type 'RW:이름'
-- 리워크 재검의 불량은 공정 불량·최종검사 집계에 섞이지 않게 m13_defect_by_type 에서 뺀다(비전 재검과 같은 처리, 기존 9/8 공정 중 재검 3건은 그대로).

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
   AND (ir.raw_inspection_label IS NULL OR ir.raw_inspection_label::text NOT LIKE '리워크 재검%')
 GROUP BY pm.model_code, COALESCE(pc.process_code, 'IMEB3_FINAL_INSPECTION'::character varying), dt.defect_name, qf.finding_class,
          COALESCE(pr.work_date, ir.inspection_date);

CREATE OR REPLACE FUNCTION public.m13_rework_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_model uuid; v_date date := (p->>'work_date')::date; v_part text := p->>'part';
  v_rw uuid; v_ir uuid; v_lot uuid; v_pr uuid; v_code text; v_old uuid[]; v_void int := 0; e jsonb; o int := 0;
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

  -- 같은 날·모델·구분·S/N 이 이미 있으면 중복
  SELECT array_agg(rework_id) INTO v_old FROM mqi.rework_record
   WHERE record_state = 'ACTIVE' AND model_id = v_model AND work_date = v_date
     AND rework_type = CASE v_part WHEN 'WELD' THEN 'BA_VISION_RECOVERY' ELSE 'CA_REMARKING' END
     AND serial_start_num IS NOT DISTINCT FROM v_s1 AND serial_end_num IS NOT DISTINCT FROM v_s2;
  IF v_old IS NOT NULL THEN
    IF NOT coalesce((p->>'replace')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'exists', true);
    END IF;
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

  -- 마킹 LOT → CA LOT (양식에 적힌 마킹, 조견표 날짜 + D1). 없으면 미연결
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

  -- 리워크 재검(진성·가성) — 불량 이벤트를 리워크에 한정해 따로 본다
  IF jsonb_array_length(coalesce(p->'findings', '[]'::jsonb)) > 0 THEN
    v_ir := gen_random_uuid();
    INSERT INTO mqi.inspection_run (inspection_run_id, model_id, process_run_id, inspection_date, inspection_type, inspection_stage, inspection_round_no,
                                    inspection_method, inspection_scope, inspected_qty_ea, raw_inspection_label, validation_status, remark)
    VALUES (v_ir, v_model, v_pr, v_date, 'IN_PROCESS', 'OTHER', 1, 'VISUAL_MANUAL', 'TARGETED', nullif(p->>'total_qty', '')::int,
            '리워크 재검 ' || CASE v_part WHEN 'WELD' THEN '용접부' ELSE '조립부' END || ' ' || (p->>'model'), 'UNVERIFIED',
            jsonb_build_object('rework_id', v_rw, 'part', v_part, 'source', p->'source')::text);
    INSERT INTO mqi.defect_type (defect_type_id, defect_code, defect_name, defect_category, description)
    SELECT DISTINCT md5('m13:dt:RW:' || (x->>'name'))::uuid, 'RW:' || (x->>'name'), x->>'name', 'RW', '리워크 작업일보 불량 유형 이름 그대로'
      FROM jsonb_array_elements(p->'findings') x
     WHERE nullif(x->>'name', '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mqi.defect_type WHERE defect_code = 'RW:' || (x->>'name'));
    FOR e IN SELECT * FROM jsonb_array_elements(p->'findings') LOOP
      IF coalesce((e->>'qty')::int, 0) > 0 THEN
        INSERT INTO mqi.quality_finding (quality_finding_id, inspection_run_id, defect_type_id, finding_class, quantity, quantity_unit, raw_quantity_text,
                                         raw_defect_name, validation_status, remark, model_id)
        VALUES (md5(v_ir::text || ':f' || o)::uuid, v_ir, CASE WHEN nullif(e->>'name', '') IS NOT NULL THEN md5('m13:dt:RW:' || (e->>'name'))::uuid END,
                CASE WHEN e->>'class' = 'FALSE' THEN 'FALSE_REJECT' ELSE 'TRUE_DEFECT' END, (e->>'qty')::int, 'EA', e->>'qty',
                coalesce(nullif(e->>'name', ''), CASE WHEN e->>'class' = 'FALSE' THEN '가성' ELSE '진성(유형 미기재)' END), 'UNVERIFIED',
                jsonb_build_object('rework_id', v_rw)::text, v_model);
        o := o + 1;
      END IF;
    END LOOP;
  END IF;
  RETURN jsonb_build_object('ok', true, 'rework_id', v_rw, 'ca_lot', CASE WHEN v_lot IS NOT NULL THEN v_code END, 'ca_run_linked', v_pr IS NOT NULL,
                            'findings', o, 'replaced', v_void);
END $fn$;

CREATE OR REPLACE FUNCTION public.m13_rework_void(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE v_id uuid := nullif(p->>'rework_id', '')::uuid; v_ir uuid[]; n int;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_rework_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF char_length(btrim(coalesce(p->>'note', ''))) < 5 THEN RAISE EXCEPTION '삭제 사유를 5자 이상 적어 주세요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.rework_record WHERE rework_id = v_id AND record_state = 'ACTIVE') THEN RAISE EXCEPTION '삭제할 수 있는 리워크 기록이 아닙니다'; END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[압입(CA)] 리워크 삭제(VOID) · ' || (p->>'note')), true);
  SELECT array_agg(inspection_run_id) INTO v_ir FROM mqi.inspection_run
   WHERE record_state = 'ACTIVE' AND inspection_type = 'IN_PROCESS' AND public.m13_try_jsonb(remark)->>'rework_id' = v_id::text;
  UPDATE mqi.quality_finding SET record_state = 'VOID' WHERE record_state = 'ACTIVE' AND inspection_run_id = ANY (coalesce(v_ir, '{}'));
  UPDATE mqi.inspection_run SET record_state = 'VOID' WHERE inspection_run_id = ANY (coalesce(v_ir, '{}'));
  UPDATE mqi.rework_origin_link SET record_state = 'VOID' WHERE rework_id = v_id AND record_state = 'ACTIVE';
  UPDATE mqi.rework_record SET record_state = 'VOID' WHERE rework_id = v_id; GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'rework_id', v_id);
END $fn$;

-- 관리 화면 목록·대시보드: 리워크 1건 = 1행 (S/N 범위·마킹 LOT·CA LOT·진성/가성·유형)
CREATE OR REPLACE VIEW public.m13_rework_entries AS
SELECT rr.rework_id, pm.model_code, to_char(rr.work_date::timestamp with time zone, 'YYYY-MM-DD') AS work_date,
       public.m13_try_jsonb(rr.remark)->>'part' AS part, public.m13_try_jsonb(rr.remark)->>'part_ko' AS part_ko,
       rr.marked_lot_code_raw AS mark, rr.marked_lot_date, rr.serial_start_raw, rr.serial_end_raw, rr.serial_start_num, rr.serial_end_num,
       CASE WHEN rr.serial_start_num IS NOT NULL AND rr.serial_end_num IS NOT NULL THEN rr.serial_end_num - rr.serial_start_num + 1 END AS serial_count,
       rr.recorded_qty AS total_qty, rr.input_qty,
       (public.m13_try_jsonb(rr.remark)->>'true_qty')::int AS true_qty, (public.m13_try_jsonb(rr.remark)->>'false_qty')::int AS false_qty,
       (SELECT string_agg(qf.raw_defect_name || ' ' || qf.quantity, ', ' ORDER BY qf.quantity DESC) FROM mqi.inspection_run ir
          JOIN mqi.quality_finding qf ON qf.inspection_run_id = ir.inspection_run_id AND qf.record_state = 'ACTIVE' AND qf.finding_class = 'TRUE_DEFECT'
         WHERE ir.record_state = 'ACTIVE' AND public.m13_try_jsonb(ir.remark)->>'rework_id' = rr.rework_id::text) AS true_types,
       (SELECT pl.lot_code_raw FROM mqi.rework_origin_link l JOIN mqi.production_lot pl ON pl.lot_id = l.original_lot_id
         WHERE l.rework_id = rr.rework_id AND l.record_state = 'ACTIVE' LIMIT 1) AS ca_lot_code,
       public.m13_try_jsonb(rr.remark)->'workers' AS workers, public.m13_try_jsonb(rr.remark)->>'check' AS check_note,
       public.m13_try_jsonb(rr.remark)#>>'{source,file}' AS file, rr.validation_status, rr.raw_note, rr.recorded_at,
       count(*) OVER (PARTITION BY rr.model_id, rr.work_date, rr.rework_type, rr.serial_start_num) AS same_count
  FROM mqi.rework_record rr
  JOIN mqi.product_model pm ON pm.model_id = rr.model_id
 WHERE rr.record_state = 'ACTIVE';

GRANT SELECT ON public.m13_rework_entries TO service_role;
REVOKE ALL ON public.m13_rework_entries FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.m13_rework_save(jsonb), public.m13_rework_void(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_rework_save(jsonb), public.m13_rework_void(jsonb) TO service_role;
