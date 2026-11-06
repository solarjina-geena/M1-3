-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블 구조는 바꾸지 않는다. (2026-11-06)
-- 초품 위치도 같은 날 재측정: 불량이 나면 수정하고 같은 날 다시 측정하는 경우(사용자 보고).
-- quality_check.check_sequence(팀 스키마 기존 열) = 그날 몇 번째 측정(1 = 첫 측정, 2·3… = 재측정). 재측정은 특이사항 필수.
-- 이전 측정은 지우지 않는다(수정 전·후 비교). '기존 기록 바꾸기'는 가장 늦은 측정 1건만 바꾼다.
-- 뷰 m13_position_checks·m13_position_entries 맨 끝에 check_sequence 열.

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
    SELECT qc.quality_check_id, qc.check_date, qc.sample_reference, qc.validation_status, qc.process_run_id, qc.remark AS qc_remark, qc.check_sequence,
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
       b.spec_pos, b.control_pos, b.display_range, b.spec_revision, b.spec_status, b.validation_status,
       public.m13_try_jsonb(b.qc_remark) ->> 'note' AS note,
       coalesce(b.check_sequence, 1) AS check_sequence
FROM b;

GRANT SELECT ON public.m13_position_checks TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.m13_position_entries AS
SELECT qc.quality_check_id::text AS check_id, to_char(qc.check_date, 'YYYY-MM-DD') AS check_date, pm.model_code,
       qc.validation_status, qc.process_run_id IS NOT NULL AS run_linked,
       count(pc.*) AS points,
       count(*) FILTER (WHERE pc.status = '정상') AS ok_cnt,
       count(*) FILTER (WHERE pc.status = '경계') AS warn_cnt,
       count(*) FILTER (WHERE pc.status = '불량') AS ng_cnt,
       max(pc.pos_xy) AS max_pos,
       max(pc.ca_lot_code) AS ca_lot_code,
       public.m13_try_jsonb(qc.remark) -> 'source' ->> 'layout' AS layout,
       public.m13_try_jsonb(qc.remark) ? 'judgment' AS judged,
       qc.recorded_at,
       public.m13_try_jsonb(qc.remark) ->> 'note' AS note,
       public.m13_try_jsonb(qc.remark) ->> 'event_id' AS event_id,
       coalesce(qc.check_sequence, 1) AS check_sequence
FROM mqi.quality_check qc
JOIN mqi.product_model pm ON pm.model_id = qc.model_id
LEFT JOIN public.m13_position_checks pc ON pc.check_id = qc.quality_check_id::text
WHERE qc.record_state = 'ACTIVE' AND qc.check_type = 'IN_PROCESS_SAMPLE' AND qc.sample_reference = '초품'
GROUP BY qc.quality_check_id, qc.check_date, pm.model_code, qc.validation_status, qc.process_run_id, qc.remark, qc.recorded_at, qc.check_sequence;

GRANT SELECT ON public.m13_position_entries TO anon, authenticated, service_role;

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
  v_note text := left(nullif(btrim(coalesce(p->>'note','')),''), 500);
  v_etype text := coalesce(nullif(p->>'event_type',''), 'SETUP_CHANGE'); v_event uuid; v_event_note text;
  v_remeasure boolean := coalesce((p->>'remeasure')::boolean, false); v_seq int := 1; v_prev_seq int;
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

  -- 같은 모델·날짜의 초품 기록(가장 늦은 측정 순번)
  SELECT quality_check_id, coalesce(check_sequence, 1) INTO v_old, v_prev_seq FROM mqi.quality_check
   WHERE model_id = v_model AND check_date = v_date AND check_type = 'IN_PROCESS_SAMPLE' AND sample_reference = '초품' AND record_state = 'ACTIVE'
   ORDER BY coalesce(check_sequence, 1) DESC, recorded_at DESC LIMIT 1;
  IF v_remeasure THEN
    -- 같은 날 재측정(불량 → 수정 → 다시 측정): 이전 측정은 그대로 두고 측정 순번을 하나 올려 새로 저장. 특이사항(수정 내용) 필수.
    IF v_note IS NULL OR char_length(v_note) < 5 THEN
      RAISE EXCEPTION '같은 날 재측정은 특이사항(무엇을 수정하고 다시 쟀는지)을 5자 이상 적어 주세요';
    END IF;
    IF v_old IS NULL THEN
      RAISE EXCEPTION '재측정할 첫 측정이 없습니다(%, %). 첫 측정은 재측정을 끄고 저장하세요', p->>'model', v_date;
    END IF;
    v_seq := v_prev_seq + 1; v_old := NULL;
  ELSIF v_old IS NOT NULL THEN
    IF coalesce((p->>'replace')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION '이미 입력된 초품 위치도가 있습니다(%, %, %차 측정). 같은 날 다시 쟀으면 "같은 날 재측정", 잘못 넣었으면 "기존 기록 바꾸기"를 선택하세요', p->>'model', v_date, v_prev_seq;
    END IF;
    -- 바꾸기: 가장 늦은 측정 순번 1건만 VOID 하고 같은 순번으로 다시 저장
    v_seq := v_prev_seq;
    UPDATE mqi.measurement SET record_state = 'VOID' WHERE quality_check_id = v_old AND record_state = 'ACTIVE';
    UPDATE mqi.production_event SET record_state = 'VOID'
     WHERE record_state = 'ACTIVE' AND public.m13_try_jsonb(remark) ->> 'from_quality_check' = v_old::text;
    UPDATE mqi.quality_check SET record_state = 'VOID' WHERE quality_check_id = v_old;
  END IF;

  -- CA 실행 연결: 그날·그 모델 CA 실행이 정확히 1건일 때만
  SELECT count(*), min(pr.process_run_id::text)::uuid INTO v_n, v_run FROM mqi.process_run pr
   WHERE pr.process_id = v_ca AND pr.model_id = v_model AND pr.work_date = v_date AND pr.record_state = 'ACTIVE';
  IF v_n <> 1 THEN v_run := NULL; END IF;

  INSERT INTO mqi.quality_check (model_id, process_run_id, check_date, check_type, sample_reference, check_sequence, validation_status, remark)
  VALUES (v_model, v_run, v_date, 'IN_PROCESS_SAMPLE', '초품', v_seq, coalesce(nullif(p->>'validation_status',''), 'UNVERIFIED'),
          jsonb_build_object('source', coalesce(p->'source', '{}'::jsonb), 'note', v_note, 'remeasure', CASE WHEN v_remeasure THEN true END, 'run_link',
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
  -- 특이사항을 생산 이벤트로도(선택): 그날 CA 실행이 연결된 경우에만(production_event 는 실행 FK 가 필수) → LOT 추적에서 보인다
  IF v_note IS NOT NULL AND coalesce((p->>'event')::boolean, false) THEN
    IF v_etype NOT IN ('STOP','RESTART','SETUP_CHANGE','MAINTENANCE','MATERIAL_CHANGE','OTHER') THEN v_etype := 'OTHER'; END IF;
    IF v_run IS NOT NULL THEN
      INSERT INTO mqi.production_event (process_run_id, event_type, event_date, event_description, validation_status, remark)
      VALUES (v_run, v_etype, v_date, v_note, 'UNVERIFIED',
              jsonb_build_object('from_quality_check', v_check, 'by', 'm13_position_save', 'source', '초품 위치도 특이사항')::text)
      RETURNING event_id INTO v_event;
      UPDATE mqi.quality_check SET remark = (public.m13_try_jsonb(remark) || jsonb_build_object('event_id', v_event))::text WHERE quality_check_id = v_check;
    ELSE
      v_event_note := '그날 CA 실행 기록이 없어 생산 이벤트는 만들지 않음(특이사항 메모만 저장)';
    END IF;
  END IF;
  RETURN jsonb_build_object('check_id', v_check, 'measurements', v_rows, 'process_run_id', v_run, 'ca_runs_that_day', v_n, 'replaced', v_old,
                            'note', v_note, 'event_id', v_event, 'event_note', v_event_note, 'check_sequence', v_seq);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_position_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_position_save(jsonb) TO service_role;
