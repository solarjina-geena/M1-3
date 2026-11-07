-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 팀장 요청)
-- 보빈 초품 위치도 엑셀 새 양식(10/27~ HSV 등): X·Y 없이 캐비티별 'XY위치도'·판정만 기록.
--  1) 저장 RPC m13_bobbin_position_save: 행에 X·Y 가 없고 lpos/rpos(위치도 값)만 있으면 measurement 'PIN_POS'(보빈 핀 위치도, 기존 기준 항목 BB_PIN_POSITION) 로 저장.
--     (함수 본문은 제자리 수정 — 나머지는 20261106000700 그대로, 권한 유지)
--  2) 뷰 m13_bobbin_position_checks: 위치도 값이 직접 있으면 그 값으로 판정(정상 ≤SPEC · 경계 ≤관리기준 · 불량). 방향(dx·dy)은 없으므로 비움.
--     열 순서는 그대로, 끝에 raw_pos·pos_only 추가.
DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.m13_bobbin_position_save(jsonb)'::regprocedure);
  IF position('v_p numeric' in d) > 0 THEN RETURN; END IF;   -- 이미 적용됨
  IF position('r jsonb; v_side text; v_x numeric; v_y numeric;' in d) = 0 THEN RAISE EXCEPTION 'anchor 1 missing'; END IF;
  d := replace(d, 'r jsonb; v_side text; v_x numeric; v_y numeric;', 'r jsonb; v_side text; v_x numeric; v_y numeric; v_p numeric;');
  IF position(E'    END LOOP;\n  END LOOP;\n  RETURN' in d) = 0 THEN RAISE EXCEPTION 'anchor 2 missing'; END IF;
  d := replace(d, E'    END LOOP;\n  END LOOP;\n  RETURN', $x$      -- 새 양식: X·Y 없이 위치도 값만 (2026-11-07)
      v_p := nullif(r->>(lower(v_side) || 'pos'), '')::numeric;
      IF v_x IS NULL AND v_y IS NULL AND v_p IS NOT NULL THEN
        INSERT INTO mqi.measurement (quality_check_id, measurement_item_code, measurement_item_name, measurement_point_code, sample_index, measured_value, measurement_unit, raw_value_text, validation_status)
        VALUES (v_check, 'PIN_POS', CASE v_side WHEN 'L' THEN '보빈 좌핀 위치도' ELSE '보빈 우핀 위치도' END, v_side, (r->>'no')::int, v_p, 'mm', r->>(lower(v_side) || 'pos'), 'UNVERIFIED');
        v_rows := v_rows + 1;
      END IF;
    END LOOP;
  END LOOP;
  RETURN$x$);
  EXECUTE d;
END $do$;

CREATE OR REPLACE VIEW public.m13_bobbin_position_checks AS
 WITH spec AS (
         SELECT s.model_id,
            max(i.target_numeric) FILTER (WHERE d.parameter_code::text = 'BB_PIN_X') AS nom_x,
            max(i.target_numeric) FILTER (WHERE d.parameter_code::text = 'BB_PIN_Y') AS nom_y,
            max(i.max_numeric) FILTER (WHERE d.parameter_code::text = 'BB_PIN_POSITION') AS spec_pos,
            max(((d.description::jsonb -> 'judge') ->> 'control')::numeric) FILTER (WHERE d.parameter_code::text = 'BB_PIN_POSITION') AS control_pos,
            max(((d.description::jsonb -> 'judge') ->> 'display_range')::numeric) FILTER (WHERE d.parameter_code::text = 'BB_PIN_POSITION') AS display_range,
            max(s.spec_revision::text) AS spec_revision,
            max(s.verification_status::text) AS spec_status
           FROM mqi.process_setup_spec s
             JOIN mqi.process_setup_spec_item i ON i.spec_id = s.spec_id AND i.record_state::text = 'ACTIVE'
             JOIN mqi.parameter_definition d ON d.parameter_id = i.parameter_id AND d.record_state::text = 'ACTIVE'
          WHERE s.record_state::text = 'ACTIVE' AND s.spec_revision::text = 'BOBBIN-POSITION-A1-3'
          GROUP BY s.model_id
        ), m AS (
         SELECT me.quality_check_id,
            me.measurement_point_code AS side,
            me.sample_index AS sample_no,
            max(me.measured_value) FILTER (WHERE me.measurement_item_code::text = 'PIN_X') AS x,
            max(me.measured_value) FILTER (WHERE me.measurement_item_code::text = 'PIN_Y') AS y,
            max(me.raw_value_text) FILTER (WHERE me.measurement_item_code::text = 'PIN_X') AS raw_x,
            max(me.raw_value_text) FILTER (WHERE me.measurement_item_code::text = 'PIN_Y') AS raw_y,
            max(me.measured_value) FILTER (WHERE me.measurement_item_code::text = 'PIN_POS') AS pos_direct,
            max(me.raw_value_text) FILTER (WHERE me.measurement_item_code::text = 'PIN_POS') AS raw_pos
           FROM mqi.measurement me
          WHERE me.record_state::text = 'ACTIVE' AND me.measurement_item_code::text = ANY (ARRAY['PIN_X', 'PIN_Y', 'PIN_POS'])
          GROUP BY me.quality_check_id, me.measurement_point_code, me.sample_index
        ), runlot AS (
         SELECT prl.process_run_id,
            string_agg(DISTINCT l.lot_code_raw::text, '/') AS lot_code
           FROM mqi.process_run_lot prl
             JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
          WHERE prl.record_state::text = 'ACTIVE' AND prl.lot_role::text = 'OUTPUT'
          GROUP BY prl.process_run_id
        ), b AS (
         SELECT qc.quality_check_id, qc.check_date, qc.validation_status, qc.process_run_id,
            m13_try_jsonb(qc.remark) AS rm, qc.check_sequence, pm.model_code, runlot.lot_code AS run_lot,
            m.side, m.sample_no, m.x, m.y, m.raw_x, m.raw_y, m.pos_direct, m.raw_pos,
            sp.nom_x, sp.nom_y, sp.spec_pos, sp.control_pos, sp.display_range, sp.spec_revision, sp.spec_status,
            m.x - sp.nom_x AS dx,
            m.y - sp.nom_y AS dy
           FROM mqi.quality_check qc
             JOIN mqi.product_model pm ON pm.model_id = qc.model_id
             JOIN m ON m.quality_check_id = qc.quality_check_id
             LEFT JOIN spec sp ON sp.model_id = qc.model_id
             LEFT JOIN runlot ON runlot.process_run_id = qc.process_run_id
          WHERE qc.record_state::text = 'ACTIVE' AND qc.check_type::text = 'IN_PROCESS_SAMPLE' AND qc.sample_reference::text = '보빈 초품'
        )
 SELECT quality_check_id::text AS check_id,
    to_char(check_date::timestamp with time zone, 'YYYY-MM-DD') AS check_date,
    model_code AS variant,
    process_run_id::text AS process_run_id,
    COALESCE(run_lot, rm ->> 'lot') AS bb_lot_code,
    rm ->> 'shift' AS shift,
    rm ->> 'label' AS label,
    side, sample_no, x, y, raw_x, raw_y, nom_x, nom_y,
    round(dx, 4) AS dx,
    round(dy, 4) AS dy,
    round(2::numeric * abs(dx), 4) AS pos_x,
    round(2::numeric * abs(dy), 4) AS pos_y,
    COALESCE(round(2::numeric * sqrt(dx * dx + dy * dy), 4), round(pos_direct, 4)) AS pos_xy,
        CASE
            WHEN spec_pos IS NULL THEN NULL::text
            WHEN x IS NULL OR y IS NULL THEN
              CASE WHEN pos_direct IS NULL THEN NULL::text
                   WHEN pos_direct <= spec_pos THEN '정상'
                   WHEN pos_direct <= COALESCE(control_pos, spec_pos) THEN '경계'
                   ELSE '불량' END
            WHEN GREATEST(2::numeric * abs(dx), 2::numeric * abs(dy), 2::numeric * sqrt(dx * dx + dy * dy)) <= spec_pos THEN '정상'
            WHEN GREATEST(2::numeric * abs(dx), 2::numeric * abs(dy), 2::numeric * sqrt(dx * dx + dy * dy)) <= COALESCE(control_pos, spec_pos) THEN '경계'
            ELSE '불량'
        END AS status,
    spec_pos, control_pos, display_range, spec_revision, spec_status, validation_status,
    rm ->> 'note' AS note,
    COALESCE(check_sequence, 1) AS check_sequence,
    raw_pos,
    (x IS NULL AND y IS NULL AND pos_direct IS NOT NULL) AS pos_only
   FROM b;
