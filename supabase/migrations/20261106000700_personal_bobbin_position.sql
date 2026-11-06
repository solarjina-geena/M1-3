-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블 구조는 바꾸지 않는다. 기준 행·public 뷰·RPC 만. (2026-11-06)
-- 사출 보빈 초품 위치도(캐비티 1~16 × 좌·우 X/Y) — CA 초품 위치도와 같은 방식, 연결 대상은 사출 실행(BB LOT).
--   quality_check  check_type=IN_PROCESS_SAMPLE, sample_reference='보빈 초품', process_run_id = 그 BB LOT 을 만든 사출 실행(정확히 1건일 때만)
--   measurement    measurement_item_code PIN_X / PIN_Y, measurement_point_code L / R, sample_index = 캐비티 번호
--   기준           process_setup_spec(사출, spec_revision BOBBIN-POSITION-A1-3) — 엑셀 기준 줄: X 1.98~2.22 / Y 11.88~12.12 / 위치도 0.35
--                  관리기준 0.40·표시범위는 CA 와 같게(parameter_definition.description JSON judge, 사용자 확인 전)
-- LOT: 블록 제목 날짜 + 주/야(㈜ = D, (야) = N) + 1 → 예 26.08.27(야) = 260827N1. 주/야 표시가 없으면 그날 그 모델 사출 실행이 1건일 때만 연결.

-- 기준 행(항목 정의·모델별 기준)은 데이터 작업이라 tools/bobbin_position_spec.sql 로 따로 넣는다(SERIALIZABLE + actor/reason).

CREATE OR REPLACE VIEW public.m13_bobbin_position_checks AS
WITH spec AS (
    SELECT s.model_id,
           max(i.target_numeric) FILTER (WHERE d.parameter_code = 'BB_PIN_X') AS nom_x,
           max(i.target_numeric) FILTER (WHERE d.parameter_code = 'BB_PIN_Y') AS nom_y,
           max(i.max_numeric)    FILTER (WHERE d.parameter_code = 'BB_PIN_POSITION') AS spec_pos,
           max(((d.description::jsonb) -> 'judge' ->> 'control')::numeric) FILTER (WHERE d.parameter_code = 'BB_PIN_POSITION') AS control_pos,
           max(((d.description::jsonb) -> 'judge' ->> 'display_range')::numeric) FILTER (WHERE d.parameter_code = 'BB_PIN_POSITION') AS display_range,
           max(s.spec_revision) AS spec_revision, max(s.verification_status) AS spec_status
    FROM mqi.process_setup_spec s
    JOIN mqi.process_setup_spec_item i ON i.spec_id = s.spec_id AND i.record_state = 'ACTIVE'
    JOIN mqi.parameter_definition d ON d.parameter_id = i.parameter_id AND d.record_state = 'ACTIVE'
    WHERE s.record_state = 'ACTIVE' AND s.spec_revision = 'BOBBIN-POSITION-A1-3'
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
    SELECT qc.quality_check_id, qc.check_date, qc.validation_status, qc.process_run_id, public.m13_try_jsonb(qc.remark) AS rm, qc.check_sequence,
           pm.model_code, runlot.lot_code AS run_lot,
           m.side, m.sample_no, m.x, m.y, m.raw_x, m.raw_y,
           sp.nom_x, sp.nom_y, sp.spec_pos, sp.control_pos, sp.display_range, sp.spec_revision, sp.spec_status,
           m.x - sp.nom_x AS dx, m.y - sp.nom_y AS dy
    FROM mqi.quality_check qc
    JOIN mqi.product_model pm ON pm.model_id = qc.model_id
    JOIN m ON m.quality_check_id = qc.quality_check_id
    LEFT JOIN spec sp ON sp.model_id = qc.model_id
    LEFT JOIN runlot ON runlot.process_run_id = qc.process_run_id
    WHERE qc.record_state = 'ACTIVE' AND qc.check_type = 'IN_PROCESS_SAMPLE' AND qc.sample_reference = '보빈 초품'
)
SELECT b.quality_check_id::text AS check_id, to_char(b.check_date, 'YYYY-MM-DD') AS check_date, b.model_code AS variant,
       b.process_run_id::text AS process_run_id,
       coalesce(b.run_lot, b.rm ->> 'lot') AS bb_lot_code, b.rm ->> 'shift' AS shift, b.rm ->> 'label' AS label,
       b.side, b.sample_no, b.x, b.y, b.raw_x, b.raw_y, b.nom_x, b.nom_y, round(b.dx, 4) AS dx, round(b.dy, 4) AS dy,
       round(2 * abs(b.dx), 4) AS pos_x, round(2 * abs(b.dy), 4) AS pos_y, round(2 * sqrt(b.dx * b.dx + b.dy * b.dy), 4) AS pos_xy,
       CASE WHEN b.spec_pos IS NULL OR b.x IS NULL OR b.y IS NULL THEN NULL
            WHEN greatest(2 * abs(b.dx), 2 * abs(b.dy), 2 * sqrt(b.dx * b.dx + b.dy * b.dy)) <= b.spec_pos THEN '정상'
            WHEN greatest(2 * abs(b.dx), 2 * abs(b.dy), 2 * sqrt(b.dx * b.dx + b.dy * b.dy)) <= coalesce(b.control_pos, b.spec_pos) THEN '경계'
            ELSE '불량' END AS status,
       b.spec_pos, b.control_pos, b.display_range, b.spec_revision, b.spec_status, b.validation_status,
       b.rm ->> 'note' AS note, coalesce(b.check_sequence, 1) AS check_sequence
FROM b;

GRANT SELECT ON public.m13_bobbin_position_checks TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.m13_bobbin_position_entries AS
SELECT qc.quality_check_id::text AS check_id, to_char(qc.check_date, 'YYYY-MM-DD') AS check_date, pm.model_code,
       public.m13_try_jsonb(qc.remark) ->> 'shift' AS shift, max(pc.bb_lot_code) AS bb_lot_code, qc.process_run_id IS NOT NULL AS run_linked,
       count(pc.*) AS points,
       count(*) FILTER (WHERE pc.status = '정상') AS ok_cnt,
       count(*) FILTER (WHERE pc.status = '경계') AS warn_cnt,
       count(*) FILTER (WHERE pc.status = '불량') AS ng_cnt,
       max(pc.pos_xy) AS max_pos,
       public.m13_try_jsonb(qc.remark) ->> 'label' AS label,
       public.m13_try_jsonb(qc.remark) -> 'source' ->> 'file' AS file,
       public.m13_try_jsonb(qc.remark) ->> 'note' AS note,
       qc.recorded_at
FROM mqi.quality_check qc
JOIN mqi.product_model pm ON pm.model_id = qc.model_id
LEFT JOIN public.m13_bobbin_position_checks pc ON pc.check_id = qc.quality_check_id::text
WHERE qc.record_state = 'ACTIVE' AND qc.check_type = 'IN_PROCESS_SAMPLE' AND qc.sample_reference = '보빈 초품'
GROUP BY qc.quality_check_id, qc.check_date, pm.model_code, qc.process_run_id, qc.remark, qc.recorded_at;

GRANT SELECT ON public.m13_bobbin_position_entries TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.m13_bobbin_position_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_model uuid; v_proc uuid; v_date date := nullif(p->>'check_date', '')::date; v_shift text := nullif(p->>'shift', '');
  v_lot text; v_run uuid; v_n int; v_old uuid; v_check uuid; v_rows int := 0;
  r jsonb; v_side text; v_x numeric; v_y numeric; v_note text := left(nullif(btrim(coalesce(p->>'note', '')), ''), 500);
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_bobbin_position_save: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[사출] 보빈 초품 위치도 입력(M1-3 관리 화면)'), true);
  SELECT model_id INTO v_model FROM mqi.product_model WHERE model_code = p->>'model' AND record_state = 'ACTIVE';
  IF v_model IS NULL THEN RAISE EXCEPTION '모델을 찾을 수 없음: %', p->>'model'; END IF;
  IF v_date IS NULL THEN RAISE EXCEPTION '측정일이 필요합니다'; END IF;
  IF v_shift IS NOT NULL AND v_shift NOT IN ('D', 'N') THEN RAISE EXCEPTION '주야는 D 또는 N'; END IF;
  IF jsonb_array_length(coalesce(p->'rows', '[]'::jsonb)) = 0 THEN RAISE EXCEPTION '측정 행이 없습니다'; END IF;
  SELECT process_id INTO v_proc FROM mqi.process WHERE process_code = 'IMEB3_INJECTION';

  -- 중복: 같은 모델·측정일·주야
  SELECT quality_check_id INTO v_old FROM mqi.quality_check
   WHERE model_id = v_model AND check_date = v_date AND check_type = 'IN_PROCESS_SAMPLE' AND sample_reference = '보빈 초품' AND record_state = 'ACTIVE'
     AND (public.m13_try_jsonb(remark) ->> 'shift') IS NOT DISTINCT FROM v_shift
   LIMIT 1;
  IF v_old IS NOT NULL THEN
    IF coalesce((p->>'replace')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION '이미 입력된 보빈 위치도입니다(% % %). 바꾸려면 "기존 기록 바꾸기"를 켜세요', p->>'model', v_date, coalesce(v_shift, '주야 미기재');
    END IF;
    UPDATE mqi.measurement SET record_state = 'VOID' WHERE quality_check_id = v_old AND record_state = 'ACTIVE';
    UPDATE mqi.quality_check SET record_state = 'VOID' WHERE quality_check_id = v_old;
  END IF;

  -- BB LOT → 사출 실행 (정확히 1건일 때만)
  IF v_shift IS NOT NULL THEN
    v_lot := to_char(v_date, 'YYMMDD') || v_shift || '1';
    SELECT count(*), min(pr.process_run_id::text)::uuid INTO v_n, v_run
      FROM mqi.process_run pr
      JOIN mqi.process_run_lot prl ON prl.process_run_id = pr.process_run_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
      JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id AND l.lot_code_raw = v_lot
     WHERE pr.process_id = v_proc AND pr.model_id = v_model AND pr.record_state = 'ACTIVE';
  ELSE
    SELECT count(*), min(pr.process_run_id::text)::uuid, min(l.lot_code_raw) INTO v_n, v_run, v_lot
      FROM mqi.process_run pr
      JOIN mqi.process_run_lot prl ON prl.process_run_id = pr.process_run_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
      JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
     WHERE pr.process_id = v_proc AND pr.model_id = v_model AND pr.work_date = v_date AND pr.record_state = 'ACTIVE';
    IF v_n <> 1 THEN v_lot := to_char(v_date, 'YYMMDD') || '?1'; END IF;
  END IF;
  IF v_n <> 1 THEN v_run := NULL; END IF;

  INSERT INTO mqi.quality_check (model_id, process_run_id, check_date, check_type, sample_reference, check_sequence, validation_status, remark)
  VALUES (v_model, v_run, v_date, 'IN_PROCESS_SAMPLE', '보빈 초품', 1, 'UNVERIFIED',
          jsonb_build_object('ds', 'BOBBIN_POSITION_A1_3', 'source', coalesce(p->'source', '{}'::jsonb), 'note', v_note, 'shift', v_shift,
                             'label', left(p->>'label', 60), 'lot', v_lot,
                             'run_link', CASE WHEN v_run IS NOT NULL THEN 'BB LOT ' || v_lot || ' 사출 실행 1건 일치'
                                              ELSE '사출 실행 ' || v_n || '건 → 미연결' || CASE WHEN v_shift IS NULL THEN '(제목에 주/야 없음)' ELSE '' END END)::text)
  RETURNING quality_check_id INTO v_check;

  FOR r IN SELECT * FROM jsonb_array_elements(p->'rows') LOOP
    FOREACH v_side IN ARRAY ARRAY['L', 'R'] LOOP
      v_x := nullif(r->>(lower(v_side) || 'x'), '')::numeric;
      v_y := nullif(r->>(lower(v_side) || 'y'), '')::numeric;
      IF v_x IS NOT NULL THEN
        INSERT INTO mqi.measurement (quality_check_id, measurement_item_code, measurement_item_name, measurement_point_code, sample_index, measured_value, measurement_unit, raw_value_text, validation_status)
        VALUES (v_check, 'PIN_X', CASE v_side WHEN 'L' THEN '보빈 좌핀 X' ELSE '보빈 우핀 X' END, v_side, (r->>'no')::int, v_x, 'mm', r->>(lower(v_side) || 'x'), 'UNVERIFIED');
        v_rows := v_rows + 1;
      END IF;
      IF v_y IS NOT NULL THEN
        INSERT INTO mqi.measurement (quality_check_id, measurement_item_code, measurement_item_name, measurement_point_code, sample_index, measured_value, measurement_unit, raw_value_text, validation_status)
        VALUES (v_check, 'PIN_Y', CASE v_side WHEN 'L' THEN '보빈 좌핀 Y' ELSE '보빈 우핀 Y' END, v_side, (r->>'no')::int, v_y, 'mm', r->>(lower(v_side) || 'y'), 'UNVERIFIED');
        v_rows := v_rows + 1;
      END IF;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('check_id', v_check, 'measurements', v_rows, 'process_run_id', v_run, 'bb_lot', v_lot, 'runs', v_n, 'replaced', v_old);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_bobbin_position_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_bobbin_position_save(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.m13_bobbin_position_void(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE v_id uuid := nullif(p->>'check_id', '')::uuid; v_n int;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_bobbin_position_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF char_length(btrim(coalesce(p->>'note', ''))) < 5 THEN RAISE EXCEPTION '삭제 사유를 5자 이상 적어 주세요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.quality_check WHERE quality_check_id = v_id AND record_state = 'ACTIVE' AND sample_reference = '보빈 초품') THEN
    RAISE EXCEPTION '삭제할 수 있는 보빈 위치도 기록이 아닙니다';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[사출] 보빈 초품 위치도 삭제(VOID) · ' || (p->>'note')), true);
  UPDATE mqi.measurement SET record_state = 'VOID' WHERE quality_check_id = v_id AND record_state = 'ACTIVE'; GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE mqi.quality_check SET record_state = 'VOID' WHERE quality_check_id = v_id;
  RETURN jsonb_build_object('ok', true, 'check_id', v_id, 'voided_measurements', v_n);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_bobbin_position_void(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_bobbin_position_void(jsonb) TO service_role;
