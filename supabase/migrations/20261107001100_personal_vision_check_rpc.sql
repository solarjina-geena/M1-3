-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 사용자 요청: 비전 불량 입력란을 위치도처럼 관리 화면에)
-- 비전 가성불량 조치 엑셀 1블록(날짜·모델·1차/2차) = 비전 재검사 1건:
--   inspection_run(IN_PROCESS, VISION_1/2, inspected_qty_ea) + quality_finding(FALSE_REJECT = 양품(가성), TRUE_DEFECT = 진성 유형별 'VIS:이름')
-- 같은 날·모델·권선 일보가 정확히 1건일 때만 process_run FK(추정 안 함). 삭제는 VOID.

CREATE OR REPLACE FUNCTION public.m13_vision_check_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_model uuid; v_date date := (p->>'date')::date; v_round int := (p->>'round')::int;
  v_rid uuid := md5('m13:vision:' || coalesce(p#>>'{source,file}', '') || ':' || coalesce(p#>>'{source,cell}', '') || ':' || (p->>'round'))::uuid;
  v_pr uuid; v_dup int; v_void int := 0; e jsonb; o int := 0;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_vision_check_save: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF v_round NOT IN (1, 2, 3) THEN RAISE EXCEPTION '비전 차수는 1·2·3 만'; END IF;
  SELECT model_id INTO v_model FROM mqi.product_model WHERE model_code = p->>'model' AND record_state = 'ACTIVE' LIMIT 1;
  IF v_model IS NULL THEN RAISE EXCEPTION '모델을 찾지 못했습니다: %', p->>'model'; END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[권선] 비전 재검사 입력'), true);
  -- 같은 날·모델·차수·같은 수량(검사·진성·가성)이 이미 있으면 중복
  SELECT count(*) INTO v_dup FROM public.m13_vision_check_entries x
   WHERE x.model_code = p->>'model' AND x.check_date = to_char(v_date, 'YYYY-MM-DD') AND x.round = v_round
     AND x.inspected_qty_ea = (p->>'inspected')::int AND x.true_qty = (p->>'true')::int AND x.false_qty = (p->>'false')::int;
  IF EXISTS (SELECT 1 FROM mqi.inspection_run WHERE inspection_run_id = v_rid AND record_state = 'ACTIVE') OR v_dup > 0 THEN
    IF NOT coalesce((p->>'replace')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'exists', true, 'run_id', v_rid);
    END IF;
    UPDATE mqi.quality_finding SET record_state = 'VOID' WHERE record_state = 'ACTIVE' AND inspection_run_id IN (
      SELECT inspection_run_id FROM mqi.inspection_run WHERE record_state = 'ACTIVE' AND inspection_stage IN ('VISION_1','VISION_2','VISION_3')
         AND model_id = v_model AND inspection_date = v_date AND inspection_round_no = v_round);
    UPDATE mqi.inspection_run SET record_state = 'VOID' WHERE record_state = 'ACTIVE' AND inspection_stage IN ('VISION_1','VISION_2','VISION_3')
       AND model_id = v_model AND inspection_date = v_date AND inspection_round_no = v_round;
    GET DIAGNOSTICS v_void = ROW_COUNT;
    v_rid := md5('m13:vision:' || coalesce(p#>>'{source,file}', '') || ':' || coalesce(p#>>'{source,cell}', '') || ':' || (p->>'round') || ':' || clock_timestamp()::text)::uuid;
  END IF;
  SELECT CASE WHEN count(*) = 1 THEN (array_agg(pr.process_run_id))[1] END INTO v_pr
    FROM mqi.process_run pr JOIN mqi.process pc ON pc.process_id = pr.process_id
   WHERE pc.process_code = 'IMEB3_WINDING' AND pr.record_state = 'ACTIVE' AND pr.work_date = v_date AND pr.model_id = v_model;
  -- 진성 유형 이름은 엑셀 표기 그대로 defect_type 'VIS:이름'
  INSERT INTO mqi.defect_type (defect_type_id, defect_code, defect_name, defect_category, description)
  SELECT DISTINCT md5('m13:dt:VIS:' || (x->>1))::uuid, 'VIS:' || (x->>1), x->>1, 'VIS', '비전 가성불량 재검사 엑셀의 불량 유형 이름 그대로'
    FROM jsonb_array_elements(coalesce(p->'fs', '[]'::jsonb)) x
   WHERE x->>1 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mqi.defect_type WHERE defect_code = 'VIS:' || (x->>1));
  INSERT INTO mqi.inspection_run (inspection_run_id, model_id, process_run_id, inspection_date, inspection_type, inspection_stage, inspection_round_no,
                                  inspection_method, inspection_scope, inspected_qty_ea, raw_inspection_label, validation_status, remark)
  VALUES (v_rid, v_model, v_pr, v_date, 'IN_PROCESS', 'VISION_' || v_round, v_round, 'VISUAL_MANUAL', 'ROUTINE', (p->>'inspected')::int,
          'iMEB3 비젼 가성불량 검사 ' || v_round || '차 ' || (p->>'model'),
          CASE WHEN nullif(p->>'check', '') IS NULL THEN 'UNVERIFIED' ELSE 'NEEDS_REVIEW' END,
          jsonb_strip_nulls(jsonb_build_object('source', p#>>'{source,file}', 'sha256', p#>>'{source,sha256}', 'cell', p#>>'{source,cell}',
                            'label', v_round || '차 ' || (p->>'model'), 'sheet_true', (p->>'true')::int, 'sheet_false', (p->>'false')::int,
                            'check', nullif(p->>'check', ''), 'note', nullif(p->>'note', ''), 'entered_via', p#>>'{source,entered_via}'))::text);
  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(p->'fs', '[]'::jsonb)) LOOP
    INSERT INTO mqi.quality_finding (quality_finding_id, inspection_run_id, defect_type_id, finding_class, quantity, quantity_unit, raw_quantity_text,
                                     raw_defect_name, validation_status, remark, model_id)
    VALUES (md5(v_rid::text || ':f' || o)::uuid, v_rid, CASE WHEN e->>1 IS NOT NULL THEN md5('m13:dt:VIS:' || (e->>1))::uuid END, e->>0,
            (e->>2)::int, 'EA', e->>2, e->>3, 'UNVERIFIED', jsonb_build_object('source', p#>>'{source,file}', 'cell', p#>>'{source,cell}')::text, v_model);
    o := o + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'run_id', v_rid, 'linked_to_journal', v_pr IS NOT NULL, 'findings', o, 'replaced', v_void);
END $fn$;

CREATE OR REPLACE FUNCTION public.m13_vision_check_void(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE v_id uuid := nullif(p->>'run_id', '')::uuid; v_n int;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_vision_check_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF char_length(btrim(coalesce(p->>'note', ''))) < 5 THEN RAISE EXCEPTION '삭제 사유를 5자 이상 적어 주세요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.inspection_run WHERE inspection_run_id = v_id AND record_state = 'ACTIVE' AND inspection_stage IN ('VISION_1','VISION_2','VISION_3')) THEN
    RAISE EXCEPTION '삭제할 수 있는 비전 재검사 기록이 아닙니다';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[권선] 비전 재검사 삭제(VOID) · ' || (p->>'note')), true);
  UPDATE mqi.quality_finding SET record_state = 'VOID' WHERE inspection_run_id = v_id AND record_state = 'ACTIVE'; GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE mqi.inspection_run SET record_state = 'VOID' WHERE inspection_run_id = v_id;
  RETURN jsonb_build_object('ok', true, 'run_id', v_id, 'voided_findings', v_n);
END $fn$;

-- 관리 화면 목록: 비전 재검사 1건 = 1행
CREATE OR REPLACE VIEW public.m13_vision_check_entries AS
SELECT ir.inspection_run_id AS run_id, pm.model_code,
       to_char(ir.inspection_date::timestamp with time zone, 'YYYY-MM-DD') AS check_date,
       ir.inspection_round_no AS round, ir.inspected_qty_ea,
       coalesce(sum(qf.quantity) FILTER (WHERE qf.finding_class = 'TRUE_DEFECT'), 0)::int AS true_qty,
       coalesce(sum(qf.quantity) FILTER (WHERE qf.finding_class = 'FALSE_REJECT'), 0)::int AS false_qty,
       string_agg(coalesce(dt.defect_name, qf.raw_defect_name) || ' ' || qf.quantity, ', ' ORDER BY qf.quantity DESC) FILTER (WHERE qf.finding_class = 'TRUE_DEFECT') AS true_types,
       ir.validation_status, ir.process_run_id IS NOT NULL AS linked_to_journal,
       m13_try_jsonb(ir.remark)->>'source' AS file, m13_try_jsonb(ir.remark)->>'cell' AS cell, m13_try_jsonb(ir.remark)->>'check' AS check_note,
       ir.recorded_at,
       count(*) OVER (PARTITION BY pm.model_code, ir.inspection_date, ir.inspection_round_no, ir.inspected_qty_ea) AS same_count
  FROM mqi.inspection_run ir
  JOIN mqi.product_model pm ON pm.model_id = ir.model_id
  LEFT JOIN mqi.quality_finding qf ON qf.inspection_run_id = ir.inspection_run_id AND qf.record_state = 'ACTIVE'
  LEFT JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
 WHERE ir.record_state = 'ACTIVE' AND ir.inspection_stage IN ('VISION_1', 'VISION_2', 'VISION_3')
 GROUP BY ir.inspection_run_id, pm.model_code;

GRANT SELECT ON public.m13_vision_check_entries TO service_role;
REVOKE ALL ON public.m13_vision_check_entries FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.m13_vision_check_save(jsonb), public.m13_vision_check_void(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_vision_check_save(jsonb), public.m13_vision_check_void(jsonb) TO service_role;
