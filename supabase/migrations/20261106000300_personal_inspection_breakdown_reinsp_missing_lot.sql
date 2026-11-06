-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-06)
-- m13_journal_save v5 = v4 + 최종검사·재검에 LOT 기록이 없으면 '(LOT 기록 누락)' 검사 LOT 줄을 UNRESOLVED 로 남김(확인 필요 → CA LOT FK).
-- 집계 뷰: m13_inspection_breakdown(검사 구분별), m13_reinspection_lot_rows(재검 LOT 별). 재검은 중복 검사라 본검사 합계에 넣지 않는다.
CREATE OR REPLACE FUNCTION public.m13_journal_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_worker uuid;
  v_actor text := coalesce(nullif(p->>'actor',''), 'm1-3-app');
  v_reason text := coalesce(nullif(p->>'reason',''), '작업일보 입력(M1-3)');
  v_src text := coalesce(p->'source', '{}'::jsonb)::text;
  v_model uuid; v_process uuid; v_pcode text; v_grp text;
  v_run uuid; v_prun uuid; v_res uuid; v_lot uuid; v_ir uuid; v_up uuid; v_mat uuid; v_mlot uuid; v_dt uuid; v_scheme uuid;
  v_date date; v_shift text; v_seq int; v_code text; v_qty int; v_minutes int;
  r jsonb; v_ldate date; v_lcode text; v_name text; v_n int; v_w uuid; v_sti record; out_workers int := 0; out_ba_sti int := 0; v_old uuid; v_replace boolean := coalesce((p->>'replace')::boolean, false); out_voided int := 0; v_k int;
  out_inputs int := 0; out_materials int := 0; out_defects int := 0; out_lots int := 0; out_new_lots int := 0;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_journal_save: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE='25000';
  END IF;
  PERFORM set_config('mqi.actor_ref', v_actor, true);
  PERFORM set_config('mqi.change_reason', v_reason, true);

  SELECT pm.model_id INTO v_model FROM mqi.product_model pm JOIN mqi.product pr ON pr.product_id = pm.product_id
   WHERE pm.model_code = p->>'model' AND pr.product_code = 'IMEB3' AND pm.record_state='ACTIVE';
  IF v_model IS NULL THEN RAISE EXCEPTION '모델을 찾을 수 없음: %', p->>'model'; END IF;
  v_pcode := p->>'process';
  SELECT process_id INTO v_process FROM mqi.process WHERE process_code = v_pcode AND record_state='ACTIVE';
  IF v_process IS NULL THEN RAISE EXCEPTION '공정을 찾을 수 없음: %', v_pcode; END IF;
  v_grp := CASE v_pcode WHEN 'IMEB3_INJECTION' THEN 'INJ' WHEN 'IMEB3_STITCHING' THEN 'STI' WHEN 'IMEB3_WINDING' THEN 'BA'
                        WHEN 'IMEB3_CA_PRESS' THEN 'CA' WHEN 'IMEB3_FINAL_INSPECTION' THEN 'FIN' ELSE v_pcode END;
  v_date := (p->>'work_date')::date;
  v_shift := coalesce(nullif(p->>'shift',''), 'D');
  v_seq := coalesce((p->>'sequence')::int, 1);
  v_qty := nullif(p->>'gross_output_qty','')::int;
  v_minutes := nullif(p->>'work_minutes','')::int;

  -- ============ 최종검사 ============
  IF v_pcode = 'IMEB3_FINAL_INSPECTION' THEN
    v_ir := gen_random_uuid();
    -- 검사자: 가린 이름(inspector_masked)으로 worker 를 찾고 없으면 만든다. 1차=신입·타라인 지원, 2차=전담(실제 검사 수량).
    IF nullif(p->>'inspector_masked','') IS NOT NULL THEN
      SELECT worker_id INTO v_worker FROM mqi.worker WHERE worker_display_name = p->>'inspector_masked' AND worker_code LIKE 'INSP-%' AND record_state='ACTIVE' LIMIT 1;
      IF v_worker IS NULL THEN
        v_worker := gen_random_uuid();
        INSERT INTO mqi.worker (worker_id, worker_code, worker_display_name, remark)
        VALUES (v_worker, 'INSP-'||left(replace(v_worker::text,'-',''),8), p->>'inspector_masked',
                json_build_object('role', '최종검사자 (역할 미확인)', 'by', 'm13_journal_save')::text);
      END IF;
    END IF;
    -- 중복: 같은 모델·검사일·검사 구분·검사자·차수·검사량의 최종검사가 이미 있으면 replace=true 일 때만 이전 기록을 VOID
    SELECT ir.inspection_run_id INTO v_old FROM mqi.inspection_run ir
     WHERE ir.model_id = v_model AND ir.inspection_date = v_date AND ir.record_state = 'ACTIVE'
       AND ir.inspection_type = coalesce(nullif(p->>'inspection_type',''),'FINAL')
       AND ir.inspector_id IS NOT DISTINCT FROM v_worker
       AND ir.inspection_round_no IS NOT DISTINCT FROM coalesce(nullif(p->>'inspection_round','')::int, CASE WHEN p->>'inspection_type' = 'REINSPECTION' THEN 2 ELSE 1 END)
       AND ir.inspected_qty_ea IS NOT DISTINCT FROM coalesce(nullif(p->>'inspected_qty','')::int, v_qty)
     LIMIT 1;
    IF v_old IS NOT NULL THEN
      IF NOT v_replace THEN
        RAISE EXCEPTION '이미 저장된 최종검사 일보입니다(%, %, 검사량 %). 바꾸려면 "기존 기록 바꾸기"를 켜세요', p->>'model', v_date, coalesce(p->>'inspected_qty', v_qty::text);
      END IF;
      IF EXISTS (SELECT 1 FROM mqi.inspection_run_link k JOIN mqi.inspection_run f ON f.inspection_run_id = k.followup_inspection_run_id
                  WHERE k.prior_inspection_run_id = v_old AND k.record_state = 'ACTIVE' AND f.inspection_type = 'REINSPECTION' AND f.record_state = 'ACTIVE') THEN
        RAISE EXCEPTION '재검 기록이 이 최종검사를 본검사로 연결하고 있어 바꿀 수 없습니다. 재검 탭에서 그 재검을 먼저 정리하세요';
      END IF;
      UPDATE mqi.quality_finding SET record_state='VOID' WHERE inspection_run_id = v_old AND record_state='ACTIVE'; GET DIAGNOSTICS v_k = ROW_COUNT; out_voided := out_voided + v_k;
      UPDATE mqi.inspection_lot SET record_state='VOID' WHERE inspection_run_id = v_old AND record_state='ACTIVE'; GET DIAGNOSTICS v_k = ROW_COUNT; out_voided := out_voided + v_k;
      UPDATE mqi.inspection_run_link SET record_state='VOID' WHERE (prior_inspection_run_id = v_old OR followup_inspection_run_id = v_old) AND record_state='ACTIVE'; GET DIAGNOSTICS v_k = ROW_COUNT; out_voided := out_voided + v_k;
      UPDATE mqi.inspection_run SET record_state='VOID' WHERE inspection_run_id = v_old; out_voided := out_voided + 1;
    END IF;
    INSERT INTO mqi.inspection_run (inspection_run_id, model_id, inspection_date, inspector_id, inspection_type, inspection_stage, inspection_round_no,
                                    inspection_method, inspection_scope, inspected_qty_ea, raw_inspection_label, validation_status, remark)
    VALUES (v_ir, v_model, v_date, v_worker,
            coalesce(nullif(p->>'inspection_type',''),'FINAL'),
            CASE WHEN p->>'inspection_type' = 'IN_PROCESS' THEN 'OTHER' ELSE 'FINAL' END,
            coalesce(nullif(p->>'inspection_round','')::int, CASE WHEN p->>'inspection_type' = 'REINSPECTION' THEN 2 ELSE 1 END),
            coalesce(nullif(p->>'inspection_method',''), 'VISUAL_MANUAL'),
            CASE WHEN p->>'inspection_type' IN ('REINSPECTION') OR p->>'inspection_method' = 'MICROSCOPE' THEN 'TARGETED' ELSE 'ROUTINE' END,
            coalesce(nullif(p->>'inspected_qty','')::int, v_qty), coalesce(p->>'label','manual'), 'UNVERIFIED',
            (v_src::jsonb || jsonb_strip_nulls(jsonb_build_object('inspector', p->>'inspector_masked', 'remarks_raw', p->>'remarks_raw',
                                                                   'round_basis', CASE WHEN nullif(p->>'inspection_round','') IS NULL THEN '미기재(기본 1차)' ELSE '입력' END)))::text);
    SELECT scheme_id INTO v_scheme FROM mqi.lot_code_scheme WHERE scheme_code='IMEB3_CA_MARKING' AND record_state='ACTIVE';
    IF v_scheme IS NULL THEN
      v_scheme := gen_random_uuid();
      INSERT INTO mqi.lot_code_scheme (scheme_id, scheme_code, scheme_name, verification_status) VALUES (v_scheme,'IMEB3_CA_MARKING','iMEB3 CA 제품 LOT 마킹 코드','UNVERIFIED');
    END IF;
    FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'lots','[]'::jsonb)) LOOP
      v_ldate := nullif(r->>'lot_date','')::date;
      v_lcode := nullif(r->>'marking_code','');
      v_lot := NULL;
      IF v_ldate IS NOT NULL THEN
        IF v_lcode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mqi.lot_code_mapping WHERE scheme_id=v_scheme AND marking_code=v_lcode AND record_state='ACTIVE') THEN
          INSERT INTO mqi.lot_code_mapping (scheme_id, marking_code, lot_date, validation_status, remark) VALUES (v_scheme, v_lcode, v_ldate, 'UNVERIFIED', 'm13_journal_save');
        END IF;
        v_code := to_char(v_ldate,'YYMMDD')||'D1';
        v_lot := public.m13_find_lot(v_model, 'IMEB3_CA_PRESS', v_code);
        IF v_lot IS NULL THEN
          v_lot := gen_random_uuid(); out_new_lots := out_new_lots + 1;
          INSERT INTO mqi.production_lot (lot_id, model_id, lot_date, lot_code_raw, verification_status, remark)
          VALUES (v_lot, v_model, v_ldate, v_code, 'NEEDS_REVIEW',
                  json_build_object('process_code','IMEB3_CA_PRESS','note','최종검사 LOT 마킹코드로 참조된 CA LOT(CA 작업일보 미확인)','by','m13_journal_save')::text);
        END IF;
      END IF;
      INSERT INTO mqi.inspection_lot (inspection_run_id, production_lot_id, lot_code_raw, recorded_box_count, recorded_quantity_raw, lot_linkage_status, remark, model_id)
      VALUES (v_ir, v_lot, left(coalesce(r->>'raw', v_lcode, ''),100), nullif(r->>'boxes','')::int, r->>'raw',
              CASE WHEN v_lot IS NULL THEN 'UNRESOLVED' ELSE 'CANDIDATE' END, json_build_object('marking_code', v_lcode)::text, v_model);
      out_lots := out_lots + 1;
    END LOOP;
    IF out_lots = 0 THEN
      INSERT INTO mqi.inspection_lot (inspection_run_id, production_lot_id, lot_code_raw, recorded_box_count, recorded_quantity_raw, lot_linkage_status, remark, model_id)
      VALUES (v_ir, NULL, '(LOT 기록 누락)', NULL, NULL, 'UNRESOLVED',
              json_build_object('missing_lot', true, 'note', '일보에 LOT 기록 없음 — 확인 필요 탭에서 CA LOT 을 넣으면 FK 연결',
                                'inspection_type', coalesce(nullif(p->>'inspection_type',''),'FINAL'))::text, v_model);
      out_lots := 1; v_k := -1;
    END IF;
    FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'defects','[]'::jsonb)) LOOP
      v_name := left(r->>'name',100);
      SELECT defect_type_id INTO v_dt FROM mqi.defect_type WHERE defect_code = left('FIN:'||v_name,100) AND record_state='ACTIVE';
      IF v_dt IS NULL THEN
        v_dt := gen_random_uuid();
        INSERT INTO mqi.defect_type (defect_type_id, defect_code, defect_name, defect_category) VALUES (v_dt, left('FIN:'||v_name,100), v_name, 'FIN');
      END IF;
      INSERT INTO mqi.quality_finding (inspection_run_id, defect_type_id, finding_class, quantity, quantity_unit, raw_quantity_text, raw_defect_name, validation_status, remark, model_id)
      VALUES (v_ir, v_dt, 'FINAL_DEFECT', nullif(r->>'qty','')::int, 'EA', coalesce(r->>'raw', r->>'qty'), v_name,
              CASE WHEN nullif(r->>'qty','') IS NULL THEN 'NEEDS_REVIEW' ELSE 'UNVERIFIED' END, v_src, v_model);
      out_defects := out_defects + 1;
    END LOOP;
    RETURN jsonb_build_object('inspection_run_id', v_ir, 'inspection_lots', out_lots, 'defects', out_defects, 'new_lots', out_new_lots, 'replaced', v_old, 'voided_rows', out_voided,
                              'missing_lot', coalesce(v_k = -1, false));
  END IF;

  -- ============ 생산 공정 (사출·스티칭·권선·압입) ============
  SELECT run_id INTO v_run FROM mqi.production_run WHERE model_id=v_model AND work_date=v_date AND shift=v_shift AND run_sequence=1 AND record_state='ACTIVE' LIMIT 1;
  IF v_run IS NULL THEN
    v_run := gen_random_uuid();
    INSERT INTO mqi.production_run (run_id, model_id, work_date, shift, run_sequence, run_type, remark)
    VALUES (v_run, v_model, v_date, v_shift, 1, 'PRODUCTION', json_build_object('by','m13_journal_save')::text);
  END IF;
  SELECT process_run_id INTO v_prun FROM mqi.process_run WHERE run_id=v_run AND process_id=v_process AND sequence_no=v_seq AND record_state='ACTIVE' LIMIT 1;
  IF v_prun IS NOT NULL THEN
    -- 중복: 같은 모델·작업일·교대·공정·순번의 일보가 이미 있다. replace=true 일 때만 그 실행의 원자재·불량·작업자 행을 VOID 하고 다시 넣는다.
    -- 투입 LOT 연결(INPUT)은 같은 LOT 이면 다시 만들지 않으므로 그대로 둔다(사람이 CONFIRMED 한 연결 보존).
    IF NOT v_replace THEN
      RAISE EXCEPTION '이미 저장된 일보입니다(% % % % 순번 %). 바꾸려면 "기존 기록 바꾸기"를 켜세요', p->>'model', v_date, v_shift, v_pcode, v_seq;
    END IF;
    v_old := v_prun;
    UPDATE mqi.material_usage SET record_state='VOID' WHERE process_run_id = v_prun AND record_state='ACTIVE'; GET DIAGNOSTICS v_k = ROW_COUNT; out_voided := out_voided + v_k;
    UPDATE mqi.quality_finding SET record_state='VOID' WHERE process_run_id = v_prun AND record_state='ACTIVE'; GET DIAGNOSTICS v_k = ROW_COUNT; out_voided := out_voided + v_k;
    UPDATE mqi.worker_assignment SET record_state='VOID' WHERE process_run_id = v_prun AND record_state='ACTIVE'; GET DIAGNOSTICS v_k = ROW_COUNT; out_voided := out_voided + v_k;
  END IF;
  IF v_prun IS NULL THEN
    v_prun := gen_random_uuid();
    INSERT INTO mqi.process_run (process_run_id, run_id, process_id, work_date, sequence_no, work_type, model_id, remark)
    VALUES (v_prun, v_run, v_process, v_date, v_seq, 'PRODUCTION', v_model, v_src);
  END IF;
  SELECT process_run_result_id INTO v_res FROM mqi.process_run_result WHERE process_run_id=v_prun AND record_state='ACTIVE' LIMIT 1;
  IF v_res IS NULL THEN
    INSERT INTO mqi.process_run_result (process_run_id, gross_output_qty, recorded_good_qty, process_defect_qty, work_minutes, raw_quantity_text, remark)
    VALUES (v_prun, v_qty, nullif(p->>'good_qty','')::int, nullif(p->>'defect_qty','')::int, v_minutes, coalesce(p->>'raw_quantity_text', v_qty::text), v_src);
  ELSIF v_qty IS NOT NULL OR v_minutes IS NOT NULL THEN
    UPDATE mqi.process_run_result SET gross_output_qty = coalesce(v_qty, gross_output_qty), work_minutes = coalesce(v_minutes, work_minutes),
           raw_quantity_text = coalesce(p->>'raw_quantity_text', raw_quantity_text), remark = v_src
     WHERE process_run_result_id = v_res;
  END IF;
  -- 작업자(가린 이름) → worker + worker_assignment(이 생산 실행)
  FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'workers_masked','[]'::jsonb)) LOOP
    v_name := left(nullif(btrim(r->>'name'),''),100);
    IF v_name IS NULL OR v_name !~ '\*' THEN CONTINUE; END IF;   -- 가리지 않은 이름은 받지 않는다
    SELECT worker_id INTO v_w FROM mqi.worker WHERE worker_display_name = v_name AND worker_code LIKE 'WRK-%' AND record_state='ACTIVE' LIMIT 1;
    IF v_w IS NULL THEN
      v_w := gen_random_uuid();
      INSERT INTO mqi.worker (worker_id, worker_code, worker_display_name, remark)
      VALUES (v_w, 'WRK-'||left(replace(v_w::text,'-',''),8), v_name, json_build_object('role','생산 작업자 (역할 미확인)','by','m13_journal_save')::text);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM mqi.worker_assignment WHERE worker_id=v_w AND process_run_id=v_prun AND record_state='ACTIVE') THEN
      INSERT INTO mqi.worker_assignment (worker_id, process_run_id, worker_role, linkage_status, remark)
      VALUES (v_w, v_prun, CASE WHEN r->>'role' IN ('OPERATOR','SETUP','SUPERVISOR','OTHER') THEN r->>'role' ELSE 'OPERATOR' END, 'CANDIDATE',
              json_build_object('shift', v_shift, 'by', 'm13_journal_save')::text);
      out_workers := out_workers + 1;
    END IF;
  END LOOP;
  -- 비고에 리워크 수량이 있으면 rework_record 에도 남긴다(BA 없이 CA 만 있는 일보 = 리워크, 사용자 규칙)
  IF nullif(p->>'rework_qty','') IS NOT NULL OR nullif(p->>'rework_note','') IS NOT NULL THEN
    INSERT INTO mqi.rework_record (model_id, rework_type, work_date, recorded_qty, recorded_qty_basis, validation_status, raw_note, remark)
    VALUES (v_model, CASE WHEN coalesce(p->>'rework_note','') ~* '비전|vision' THEN 'BA_VISION_RECOVERY' ELSE 'OTHER' END, v_date,
            nullif(p->>'rework_qty','')::int, CASE WHEN nullif(p->>'rework_qty','') IS NULL THEN 'UNKNOWN' ELSE 'DIRECT_COUNT' END,
            'NEEDS_REVIEW', left(coalesce(p->>'rework_note',''),500), v_src);
  END IF;
  -- 산출 LOT
  v_code := coalesce(nullif(p->>'output_lot_code',''), to_char(v_date,'YYMMDD')||v_shift||v_seq);
  v_lot := public.m13_find_lot(v_model, v_pcode, v_code);
  IF v_lot IS NULL THEN
    v_lot := gen_random_uuid(); out_new_lots := out_new_lots + 1;
    INSERT INTO mqi.production_lot (lot_id, model_id, lot_date, lot_code_raw, verification_status, remark)
    VALUES (v_lot, v_model, v_date, v_code, 'UNVERIFIED', json_build_object('process_code', v_pcode, 'rule','LOT = 공정 작업일 YYMMDD + 교대 + 순번','by','m13_journal_save')::text);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.process_run_lot WHERE process_run_id=v_prun AND production_lot_id=v_lot AND lot_role='OUTPUT' AND record_state='ACTIVE') THEN
    INSERT INTO mqi.process_run_lot (process_run_id, production_lot_id, lot_role, recorded_quantity, quantity_unit, raw_quantity_text, linkage_status, evidence_note, model_id)
    VALUES (v_prun, v_lot, 'OUTPUT', v_qty, 'EA', v_qty::text, 'CANDIDATE', '공정 LOT = 작업일 규칙(m13_journal_save)', v_model);
  END IF;
  -- 투입 LOT (상위 공정 산출물) → process_run_lot INPUT  ★사슬
  FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'inputs','[]'::jsonb)) LOOP
    v_ldate := nullif(r->>'lot_date','')::date;
    v_lcode := coalesce(nullif(r->>'lot_code',''), CASE WHEN v_ldate IS NULL THEN NULL ELSE to_char(v_ldate,'YYMMDD')||'D1' END);
    IF v_lcode IS NULL THEN CONTINUE; END IF;
    v_up := public.m13_find_lot(v_model, r->>'process', v_lcode);
    IF v_up IS NULL THEN
      IF v_ldate IS NULL THEN CONTINUE; END IF;
      v_up := gen_random_uuid(); out_new_lots := out_new_lots + 1;
      INSERT INTO mqi.production_lot (lot_id, model_id, lot_date, lot_code_raw, verification_status, remark)
      VALUES (v_up, v_model, v_ldate, v_lcode, 'NEEDS_REVIEW',
              json_build_object('process_code', r->>'process', 'note','하위 공정 기록에서 참조된 상위 LOT(상위 작업일보 미확인)','by','m13_journal_save')::text);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM mqi.process_run_lot WHERE process_run_id=v_prun AND production_lot_id=v_up AND lot_role='INPUT' AND record_state='ACTIVE') THEN
      INSERT INTO mqi.process_run_lot (process_run_id, production_lot_id, lot_role, linkage_status, evidence_note, model_id)
      VALUES (v_prun, v_up, 'INPUT', coalesce(nullif(r->>'status',''),'CANDIDATE'), left(coalesce(r->>'note','')||' raw='||coalesce(r->>'raw',''), 500), v_model);
      out_inputs := out_inputs + 1;
    END IF;
  END LOOP;
  -- BA 보빈 날짜 → 15일 안 같은 보빈 날짜를 쓴 스티칭 LOT 전부 (변환기 match_ba_stitching 과 같은 규칙)  ★사슬
  IF v_pcode = 'IMEB3_WINDING' THEN
    FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'ba_bobbin_dates','[]'::jsonb)) LOOP
      v_ldate := nullif(r #>> '{}','')::date;
      IF v_ldate IS NULL THEN CONTINUE; END IF;
      FOR v_sti IN
        SELECT DISTINCT spr.work_date AS sdate, ol.production_lot_id AS out_lot
          FROM mqi.process_run spr
          JOIN mqi.process sp ON sp.process_id = spr.process_id AND sp.process_code = 'IMEB3_STITCHING'
          JOIN mqi.process_run_lot il ON il.process_run_id = spr.process_run_id AND il.lot_role = 'INPUT' AND il.record_state = 'ACTIVE'
          JOIN mqi.production_lot bl ON bl.lot_id = il.production_lot_id AND bl.lot_date = v_ldate
          JOIN mqi.process_run_lot ol ON ol.process_run_id = spr.process_run_id AND ol.lot_role = 'OUTPUT' AND ol.record_state = 'ACTIVE'
         WHERE spr.model_id = v_model AND spr.record_state = 'ACTIVE' AND spr.work_date BETWEEN v_date - 15 AND v_date
      LOOP
        IF NOT EXISTS (SELECT 1 FROM mqi.process_run_lot WHERE process_run_id=v_prun AND production_lot_id=v_sti.out_lot AND lot_role='INPUT' AND record_state='ACTIVE') THEN
          INSERT INTO mqi.process_run_lot (process_run_id, production_lot_id, lot_role, linkage_status, evidence_note, model_id)
          VALUES (v_prun, v_sti.out_lot, 'INPUT', 'CANDIDATE',
                  left(format('보빈 날짜 매칭: BA 보빈 %s = 스티칭 %s 일보 보빈 → 그 스티칭 LOT. 15일 범위(m13_journal_save)', v_ldate, v_sti.sdate), 500), v_model);
          out_ba_sti := out_ba_sti + 1;
        END IF;
      END LOOP;
    END LOOP;
  END IF;
  -- 원자재 → material_usage  ★사슬
  FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'materials','[]'::jsonb)) LOOP
    SELECT material_id INTO v_mat FROM mqi.material WHERE material_code = r->>'material' AND record_state='ACTIVE';
    IF v_mat IS NULL THEN
      v_mat := gen_random_uuid();
      INSERT INTO mqi.material (material_id, material_code, material_name, material_category) VALUES (v_mat, r->>'material', coalesce(r->>'material_name', r->>'material'), 'RAW_MATERIAL');
    END IF;
    v_ldate := nullif(r->>'lot_date','')::date; v_mlot := NULL;
    IF v_ldate IS NOT NULL THEN
      SELECT material_lot_id INTO v_mlot FROM mqi.material_lot WHERE material_id=v_mat AND internal_lot_code = to_char(v_ldate,'YYMMDD')||'D1' AND record_state='ACTIVE' LIMIT 1;
      IF v_mlot IS NULL THEN
        v_mlot := gen_random_uuid();
        INSERT INTO mqi.material_lot (material_lot_id, material_id, internal_lot_code, manufactured_date, verification_status, remark)
        VALUES (v_mlot, v_mat, to_char(v_ldate,'YYMMDD')||'D1', v_ldate, 'UNVERIFIED', json_build_object('first_seen_raw', r->>'raw','by','m13_journal_save')::text);
      END IF;
    END IF;
    INSERT INTO mqi.material_usage (process_run_id, material_id, material_lot_id, recorded_lot_code_raw, used_quantity, quantity_unit, usage_role, linkage_status, remark)
    VALUES (v_prun, v_mat, v_mlot, left(coalesce(r->>'raw',''),100), nullif(r->>'qty','')::numeric, r->>'unit', 'INPUT', 'CANDIDATE',
            (v_src::jsonb || jsonb_strip_nulls(jsonb_build_object('spindle', r->>'spindle', 'note', r->>'note')))::text);
    out_materials := out_materials + 1;
  END LOOP;
  -- 공정 불량
  FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'defects','[]'::jsonb)) LOOP
    v_name := left(r->>'name',100);
    SELECT defect_type_id INTO v_dt FROM mqi.defect_type WHERE defect_code = left(v_grp||':'||v_name,100) AND record_state='ACTIVE';
    IF v_dt IS NULL THEN
      v_dt := gen_random_uuid();
      INSERT INTO mqi.defect_type (defect_type_id, defect_code, defect_name, defect_category) VALUES (v_dt, left(v_grp||':'||v_name,100), v_name, v_grp);
    END IF;
    INSERT INTO mqi.quality_finding (process_run_id, defect_type_id, finding_class, quantity, quantity_unit, raw_quantity_text, raw_defect_name, validation_status, remark, model_id)
    VALUES (v_prun, v_dt, 'PROCESS_DEFECT', nullif(r->>'qty','')::int, 'EA', coalesce(r->>'raw', r->>'qty'), v_name,
            CASE WHEN nullif(r->>'qty','') IS NULL THEN 'NEEDS_REVIEW' ELSE 'UNVERIFIED' END, v_src, v_model);
    out_defects := out_defects + 1;
  END LOOP;
  RETURN jsonb_build_object('process_run_id', v_prun, 'production_run_id', v_run, 'output_lot_id', v_lot, 'output_lot_code', v_code,
                            'inputs', out_inputs, 'materials', out_materials, 'defects', out_defects, 'new_lots', out_new_lots,
                            'workers', out_workers, 'ba_stitching_links', out_ba_sti, 'replaced', v_old, 'voided_rows', out_voided);
END
$fn$;


REVOKE ALL ON FUNCTION public.m13_journal_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_journal_save(jsonb) TO service_role;

-- 최종검사 검사 구분별 집계: 모델·검사일 × (본검사 1차 / 본검사 2차 / 재검). 재검은 이미 검사한 LOT 을 다시 본 중복 검사라 본검사와 따로.
CREATE OR REPLACE VIEW public.m13_inspection_breakdown AS
SELECT pm.model_code, to_char(ir.inspection_date, 'YYYY-MM-DD') AS inspection_date, ir.inspection_type,
       CASE WHEN ir.inspection_type = 'REINSPECTION' THEN '재검' WHEN ir.inspection_round_no = 2 THEN '2차' WHEN ir.inspection_round_no = 1 THEN '1차' ELSE '기타' END AS inspection_class,
       ir.inspection_round_no, ir.inspection_method,
       count(*) AS runs, sum(ir.inspected_qty_ea) AS inspected_qty,
       sum((SELECT coalesce(sum(qf.quantity), 0) FROM mqi.quality_finding qf WHERE qf.inspection_run_id = ir.inspection_run_id AND qf.record_state = 'ACTIVE')) AS defect_qty,
       sum((SELECT count(*) FROM mqi.inspection_lot il WHERE il.inspection_run_id = ir.inspection_run_id AND il.record_state = 'ACTIVE')) AS lots,
       sum((SELECT count(*) FROM mqi.inspection_lot il WHERE il.inspection_run_id = ir.inspection_run_id AND il.record_state = 'ACTIVE' AND il.lot_linkage_status = 'UNRESOLVED')) AS unresolved_lots
FROM mqi.inspection_run ir
JOIN mqi.product_model pm ON pm.model_id = ir.model_id
WHERE ir.record_state = 'ACTIVE'
GROUP BY pm.model_code, ir.inspection_date, ir.inspection_type, ir.inspection_round_no, ir.inspection_method;

GRANT SELECT ON public.m13_inspection_breakdown TO anon, authenticated, service_role;

-- 재검 LOT 별: 재검 1건의 대상 LOT 마다 1행. LOT 수량 = LOT 에 적힌 EA, 없으면 BOX×480, LOT 이 하나뿐이면 재검 수량.
-- 불량은 LOT 에 붙은 것(lot_defect_qty)과 LOT 을 나누지 않은 재검 합계(run_defect_qty, 재검에 LOT 이 여러 개일 때)를 나눠 둔다(나누지 않음).
CREATE OR REPLACE VIEW public.m13_reinspection_lot_rows AS
SELECT pm.model_code, to_char(ir.inspection_date, 'YYYY-MM-DD') AS reinspection_date, ir.inspection_run_id::text AS run_id,
       il.inspection_lot_id::text AS inspection_lot_id, il.lot_code_raw, l.lot_code_raw AS ca_lot_code, il.lot_linkage_status,
       public.m13_try_jsonb(il.remark) ? 'missing_lot' AS missing_lot,
       ir.inspection_method, ir.inspected_qty_ea AS run_qty,
       (SELECT count(*) FROM mqi.inspection_lot x WHERE x.inspection_run_id = ir.inspection_run_id AND x.record_state = 'ACTIVE') AS lots_in_run,
       coalesce(il.inspected_qty_ea, il.recorded_box_count * 480,
                CASE WHEN (SELECT count(*) FROM mqi.inspection_lot x WHERE x.inspection_run_id = ir.inspection_run_id AND x.record_state = 'ACTIVE') = 1 THEN ir.inspected_qty_ea END) AS lot_qty,
       (SELECT coalesce(sum(qf.quantity), 0) FROM mqi.quality_finding qf WHERE qf.inspection_lot_id = il.inspection_lot_id AND qf.record_state = 'ACTIVE') AS lot_defect_qty,
       (SELECT coalesce(sum(qf.quantity), 0) FROM mqi.quality_finding qf WHERE qf.inspection_run_id = ir.inspection_run_id AND qf.inspection_lot_id IS NULL AND qf.record_state = 'ACTIVE') AS run_defect_qty,
       (SELECT string_agg(DISTINCT coalesce(qf.raw_defect_name, dt.defect_name), ', ') FROM mqi.quality_finding qf LEFT JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
         WHERE qf.inspection_run_id = ir.inspection_run_id AND qf.record_state = 'ACTIVE') AS defect_names
FROM mqi.inspection_run ir
JOIN mqi.product_model pm ON pm.model_id = ir.model_id
JOIN mqi.inspection_lot il ON il.inspection_run_id = ir.inspection_run_id AND il.record_state = 'ACTIVE'
LEFT JOIN mqi.production_lot l ON l.lot_id = il.production_lot_id
WHERE ir.record_state = 'ACTIVE' AND ir.inspection_type = 'REINSPECTION';

GRANT SELECT ON public.m13_reinspection_lot_rows TO anon, authenticated, service_role;
