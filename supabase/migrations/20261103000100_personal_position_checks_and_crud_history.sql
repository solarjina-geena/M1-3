-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블 구조는 바꾸지 않는다. public 뷰·RPC 만 만든다.
-- 1) m13_position_checks : CA 초품 핀 위치도(A1-3 PosiDash 규칙). 팀 표 quality_check(초품) + measurement(PIN_X/PIN_Y, 좌 L/우 R, 시료 NO)
--    기준(X·Y 기준값, SPEC ⌀, 관리기준 ⌀, 표시범위)은 process_setup_spec(POSITION-A1-3) + parameter_definition.description(judge) 에서 읽는다.
--    판정(정상 ≤SPEC · 경계 ≤관리기준 · 불량 >관리기준, X단독 2|ΔX| · Y단독 2|ΔY| · 종합 2√(ΔX²+ΔY²) 중 가장 나쁜 값)은 저장하지 않고 여기서 계산.
-- 2) m13_position_save(p) : 위치도 1회(모델·날짜·초품) 저장 RPC. 같은 날 다시 저장하면 이전 기록은 VOID(삭제하지 않음).
--    CA 실행 연결은 그날·그 모델 CA 실행이 정확히 1건일 때만(추정 금지).
-- 3) m13_crud_history : 팀 감사 테이블 mqi_audit.row_change 를 공정 단계로 풀어 쓴 CRUD 이력(생성·수정·삭제(VOID)). service_role 전용.

-- 1) 위치도 판정 뷰 ---------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.m13_position_checks AS
WITH spec AS (
    SELECT s.model_id,
           max(i.target_numeric) FILTER (WHERE d.parameter_code = 'PIN_X') AS nom_x,
           max(i.target_numeric) FILTER (WHERE d.parameter_code = 'PIN_Y') AS nom_y,
           max(i.max_numeric)    FILTER (WHERE d.parameter_code = 'PIN_POSITION') AS spec_pos,
           max(((d.description::jsonb) -> 'judge' ->> 'control')::numeric) FILTER (WHERE d.parameter_code = 'PIN_POSITION') AS control_pos,
           max(((d.description::jsonb) -> 'judge' ->> 'display_range')::numeric) FILTER (WHERE d.parameter_code = 'PIN_POSITION') AS display_range,
           max(s.spec_revision) AS spec_revision, max(s.verification_status) AS spec_status
    FROM mqi.process_setup_spec s
    JOIN mqi.process_setup_spec_item i ON i.spec_id = s.spec_id AND i.record_state = 'ACTIVE'
    JOIN mqi.parameter_definition d ON d.parameter_id = i.parameter_id AND d.record_state = 'ACTIVE'
    WHERE s.record_state = 'ACTIVE' AND s.spec_revision = 'POSITION-A1-3'
    GROUP BY s.model_id
),
m AS (
    SELECT me.quality_check_id, me.measurement_point_code AS side, me.sample_index AS sample_no,
           max(me.measured_value) FILTER (WHERE me.measurement_item_code = 'PIN_X') AS x,
           max(me.measured_value) FILTER (WHERE me.measurement_item_code = 'PIN_Y') AS y,
           max(me.raw_value_text) FILTER (WHERE me.measurement_item_code = 'PIN_X') AS raw_x,
           max(me.raw_value_text) FILTER (WHERE me.measurement_item_code = 'PIN_Y') AS raw_y
    FROM mqi.measurement me
    WHERE me.record_state = 'ACTIVE' AND me.measurement_item_code IN ('PIN_X', 'PIN_Y')
    GROUP BY me.quality_check_id, me.measurement_point_code, me.sample_index
),
runlot AS (
    SELECT prl.process_run_id, string_agg(DISTINCT l.lot_code_raw, '/') AS lot_code
    FROM mqi.process_run_lot prl JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
    WHERE prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT'
    GROUP BY prl.process_run_id
),
b AS (
    SELECT qc.quality_check_id, qc.check_date, qc.sample_reference, qc.validation_status, qc.process_run_id,
           pm.model_code, runlot.lot_code AS ca_lot_code, pru.shift AS run_shift,
           m.side, m.sample_no, m.x, m.y, m.raw_x, m.raw_y,
           sp.nom_x, sp.nom_y, sp.spec_pos, sp.control_pos, sp.display_range, sp.spec_revision, sp.spec_status,
           m.x - sp.nom_x AS dx, m.y - sp.nom_y AS dy
    FROM mqi.quality_check qc
    JOIN mqi.product_model pm ON pm.model_id = qc.model_id
    JOIN m ON m.quality_check_id = qc.quality_check_id
    LEFT JOIN spec sp ON sp.model_id = qc.model_id
    LEFT JOIN mqi.process_run pr ON pr.process_run_id = qc.process_run_id
    LEFT JOIN mqi.production_run pru ON pru.run_id = pr.run_id
    LEFT JOIN runlot ON runlot.process_run_id = qc.process_run_id
    WHERE qc.record_state = 'ACTIVE' AND qc.check_type = 'IN_PROCESS_SAMPLE' AND qc.sample_reference = '초품'
)
SELECT b.quality_check_id::text AS check_id, to_char(b.check_date, 'YYYY-MM-DD') AS check_date, b.model_code AS variant,
       b.process_run_id::text AS process_run_id, b.ca_lot_code, b.run_shift,
       b.side, b.sample_no, b.x, b.y, b.raw_x, b.raw_y, b.nom_x, b.nom_y, round(b.dx, 4) AS dx, round(b.dy, 4) AS dy,
       round(2 * abs(b.dx), 4) AS pos_x, round(2 * abs(b.dy), 4) AS pos_y, round(2 * sqrt(b.dx * b.dx + b.dy * b.dy), 4) AS pos_xy,
       CASE WHEN b.spec_pos IS NULL OR b.x IS NULL OR b.y IS NULL THEN NULL
            WHEN greatest(2 * abs(b.dx), 2 * abs(b.dy), 2 * sqrt(b.dx * b.dx + b.dy * b.dy)) <= b.spec_pos THEN '정상'
            WHEN greatest(2 * abs(b.dx), 2 * abs(b.dy), 2 * sqrt(b.dx * b.dx + b.dy * b.dy)) <= coalesce(b.control_pos, b.spec_pos) THEN '경계'
            ELSE '불량' END AS status,
       b.spec_pos, b.control_pos, b.display_range, b.spec_revision, b.spec_status, b.validation_status
FROM b;

GRANT SELECT ON public.m13_position_checks TO anon, authenticated, service_role;

-- 2) 위치도 저장 RPC --------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.m13_position_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_actor text := coalesce(nullif(p->>'actor',''), 'm1-3-app');
  v_reason text := coalesce(nullif(p->>'reason',''), '[CA] 초품 위치도 입력(M1-3 관리 화면)');
  v_model uuid; v_ca uuid; v_date date; v_run uuid; v_n int; v_old uuid; v_check uuid; v_rows int := 0;
  r jsonb; v_side text; v_no int; v_x numeric; v_y numeric;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_position_save: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE='25000';
  END IF;
  PERFORM set_config('mqi.actor_ref', v_actor, true);
  PERFORM set_config('mqi.change_reason', v_reason, true);
  SELECT model_id INTO v_model FROM mqi.product_model WHERE model_code = p->>'model' AND record_state = 'ACTIVE';
  IF v_model IS NULL THEN RAISE EXCEPTION '모델을 찾을 수 없음: %', p->>'model'; END IF;
  SELECT process_id INTO v_ca FROM mqi.process WHERE process_code = 'IMEB3_CA_PRESS';
  v_date := (p->>'check_date')::date;
  IF v_date IS NULL THEN RAISE EXCEPTION '측정일(check_date)이 필요합니다'; END IF;
  IF jsonb_array_length(coalesce(p->'rows', '[]'::jsonb)) = 0 THEN RAISE EXCEPTION '측정 행이 없습니다'; END IF;

  -- 같은 모델·날짜의 초품 기록이 있으면: replace=true 일 때만 VOID 후 다시 저장
  SELECT quality_check_id INTO v_old FROM mqi.quality_check
   WHERE model_id = v_model AND check_date = v_date AND check_type = 'IN_PROCESS_SAMPLE' AND sample_reference = '초품' AND record_state = 'ACTIVE'
   LIMIT 1;
  IF v_old IS NOT NULL THEN
    IF coalesce((p->>'replace')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION '이미 입력된 초품 위치도가 있습니다(%, %). 바꾸려면 "기존 기록 바꾸기"를 선택하세요', p->>'model', v_date;
    END IF;
    UPDATE mqi.measurement SET record_state = 'VOID' WHERE quality_check_id = v_old AND record_state = 'ACTIVE';
    UPDATE mqi.quality_check SET record_state = 'VOID' WHERE quality_check_id = v_old;
  END IF;

  -- CA 실행 연결: 그날·그 모델 CA 실행이 정확히 1건일 때만
  SELECT count(*), min(pr.process_run_id::text)::uuid INTO v_n, v_run FROM mqi.process_run pr
   WHERE pr.process_id = v_ca AND pr.model_id = v_model AND pr.work_date = v_date AND pr.record_state = 'ACTIVE';
  IF v_n <> 1 THEN v_run := NULL; END IF;

  INSERT INTO mqi.quality_check (model_id, process_run_id, check_date, check_type, sample_reference, check_sequence, validation_status, remark)
  VALUES (v_model, v_run, v_date, 'IN_PROCESS_SAMPLE', '초품', 1, coalesce(nullif(p->>'validation_status',''), 'UNVERIFIED'),
          jsonb_build_object('source', coalesce(p->'source', '{}'::jsonb), 'run_link',
                             CASE WHEN v_run IS NOT NULL THEN '그날·모델 CA 실행 1건 일치' ELSE 'CA 실행 ' || v_n || '건 → 미연결' END)::text)
  RETURNING quality_check_id INTO v_check;

  FOR r IN SELECT * FROM jsonb_array_elements(p->'rows') LOOP
    v_no := (r->>'no')::int;
    FOREACH v_side IN ARRAY ARRAY['L', 'R'] LOOP
      v_x := nullif(r->>(lower(v_side) || 'x'), '')::numeric;
      v_y := nullif(r->>(lower(v_side) || 'y'), '')::numeric;
      IF v_x IS NOT NULL THEN
        INSERT INTO mqi.measurement (quality_check_id, measurement_item_code, measurement_item_name, measurement_point_code, sample_index, measured_value, measurement_unit, raw_value_text, validation_status)
        VALUES (v_check, 'PIN_X', CASE v_side WHEN 'L' THEN '좌핀 X' ELSE '우핀 X' END, v_side, v_no, v_x, 'mm', r->>(lower(v_side) || 'x'), 'UNVERIFIED');
        v_rows := v_rows + 1;
      END IF;
      IF v_y IS NOT NULL THEN
        INSERT INTO mqi.measurement (quality_check_id, measurement_item_code, measurement_item_name, measurement_point_code, sample_index, measured_value, measurement_unit, raw_value_text, validation_status)
        VALUES (v_check, 'PIN_Y', CASE v_side WHEN 'L' THEN '좌핀 Y' ELSE '우핀 Y' END, v_side, v_no, v_y, 'mm', r->>(lower(v_side) || 'y'), 'UNVERIFIED');
        v_rows := v_rows + 1;
      END IF;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('check_id', v_check, 'measurements', v_rows, 'process_run_id', v_run, 'ca_runs_that_day', v_n, 'replaced', v_old);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_position_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_position_save(jsonb) TO service_role;

-- 3) CRUD 이력 (공정 단계별) ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.m13_crud_history AS
WITH rc AS (
    SELECT r.*, coalesce(r.new_row, '{}'::jsonb) AS nr FROM mqi_audit.row_change r
),
x AS (
    SELECT rc.audit_id, rc.changed_at, rc.table_name, rc.operation, rc.row_id, rc.actor_ref, rc.change_reason, rc.transaction_id,
           rc.old_row, rc.nr,
           coalesce(
             p_dir.process_code,                         -- process_id 를 직접 가진 행(process_run, parameter_definition, process_setup_spec)
             p_run.process_code,                         -- process_run_id 를 가진 행(실행 결과·LOT·조건 실측·초품·설비 사용·출처 연결)
             p_par.process_code,                         -- 조건 실측(실행 미연결)은 항목 정의의 공정
             p_spec.process_code,                        -- 기준 세부항목
             p_qc.process_code,                          -- 측정값 → 초품 → CA 실행
             CASE WHEN rc.table_name IN ('measurement') OR (rc.table_name = 'quality_check' AND rc.nr ->> 'sample_reference' = '초품') THEN 'IMEB3_CA_PRESS' END,
             CASE WHEN rc.table_name LIKE 'inspection%' OR rc.table_name IN ('lot_code_mapping', 'lot_code_scheme') THEN 'IMEB3_FINAL_INSPECTION' END,
             CASE WHEN nullif(rc.nr ->> 'inspection_run_id', '') IS NOT NULL THEN 'IMEB3_FINAL_INSPECTION' END,   -- 최종검사 불량 기록
             CASE upper(rc.nr ->> 'defect_category') WHEN 'BA' THEN 'IMEB3_WINDING' WHEN 'CA' THEN 'IMEB3_CA_PRESS' WHEN 'STITCHING' THEN 'IMEB3_STITCHING'
                  WHEN 'INJECTION' THEN 'IMEB3_INJECTION' WHEN 'FINAL' THEN 'IMEB3_FINAL_INSPECTION' END,                  -- 불량 유형
             CASE WHEN rc.table_name IN ('source_ingest','source_bundle','source_asset','source_bundle_asset','source_document','source_document_version',
                                         'source_page','source_location','extraction_run','extracted_field','field_review','field_provenance_link') THEN 'SOURCE' END,
             'COMMON') AS stage_code,
           coalesce(pm_dir.model_code, pm_run.model_code) AS model_code
    FROM rc
    LEFT JOIN mqi.process p_dir ON p_dir.process_id = nullif(rc.nr ->> 'process_id', '')::uuid
    LEFT JOIN mqi.process_run pr ON pr.process_run_id = nullif(rc.nr ->> 'process_run_id', '')::uuid
    LEFT JOIN mqi.process p_run ON p_run.process_id = pr.process_id
    LEFT JOIN mqi.parameter_definition pd ON rc.table_name = 'parameter_observation' AND pd.parameter_id = nullif(rc.nr ->> 'parameter_id', '')::uuid
    LEFT JOIN mqi.process p_par ON p_par.process_id = pd.process_id
    LEFT JOIN mqi.process_setup_spec ss ON rc.table_name = 'process_setup_spec_item' AND ss.spec_id = nullif(rc.nr ->> 'spec_id', '')::uuid
    LEFT JOIN mqi.process p_spec ON p_spec.process_id = ss.process_id
    LEFT JOIN mqi.quality_check qc ON rc.table_name = 'measurement' AND qc.quality_check_id = nullif(rc.nr ->> 'quality_check_id', '')::uuid
    LEFT JOIN mqi.process_run qpr ON qpr.process_run_id = qc.process_run_id
    LEFT JOIN mqi.process p_qc ON p_qc.process_id = qpr.process_id
    LEFT JOIN mqi.product_model pm_dir ON pm_dir.model_id = nullif(rc.nr ->> 'model_id', '')::uuid
    LEFT JOIN mqi.product_model pm_run ON pm_run.model_id = pr.model_id
)
SELECT x.audit_id, x.changed_at, x.table_name, x.row_id::text AS row_id, x.actor_ref, x.change_reason, x.transaction_id,
       CASE WHEN x.operation = 'INSERT' THEN '생성'
            WHEN x.old_row ->> 'record_state' = 'ACTIVE' AND x.nr ->> 'record_state' = 'VOID' THEN '삭제(VOID)'
            ELSE '수정' END AS action,
       x.stage_code,
       CASE x.stage_code WHEN 'IMEB3_INJECTION' THEN '사출' WHEN 'IMEB3_STITCHING' THEN '스티칭' WHEN 'IMEB3_WINDING' THEN '권선(BA)'
            WHEN 'IMEB3_CA_PRESS' THEN '압입(CA)' WHEN 'IMEB3_FINAL_INSPECTION' THEN '최종검사' WHEN 'SOURCE' THEN '원본·출처' ELSE '공통' END AS stage_label,
       x.model_code,
       CASE WHEN x.operation = 'UPDATE' THEN (
            SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(x.nr) k
             WHERE k NOT IN ('updated_at', 'row_version') AND (x.old_row -> k) IS DISTINCT FROM (x.nr -> k)) END AS changed_columns
FROM x;

REVOKE ALL ON public.m13_crud_history FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.m13_crud_history TO service_role;
