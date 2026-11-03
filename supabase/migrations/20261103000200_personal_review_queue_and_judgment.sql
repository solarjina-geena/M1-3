-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블 구조는 바꾸지 않는다. public 함수·뷰·RPC 만 만든다.
-- 사람 판단 기록 (대시보드 '확인 필요' 탭의 판단 카드). 첫 버전 범위(2026-11-03 사용자 결정 '좁게 시작'):
--   READ_VALUE      판독값 확인 필요   extracted_field.validation_status = NEEDS_REVIEW      → 확인 / 정정 / 반려
--   INSPECTION_LOT  검사 LOT 미해결    inspection_lot.lot_linkage_status = UNRESOLVED         → CA LOT 연결 / 미연결 유지 / 삭제(VOID)
--   EVENT           생산 이벤트 확인   production_event.validation_status = NEEDS_REVIEW      → 확인(설명 정정 가능) / 반려 / 삭제(VOID)
--   POSITION        초품 위치도 경계·불량 (아직 판단 전)                                        → 확인 / 정정 / 재측정 요청
-- LOT 연결 후보(CANDIDATE) 1,500여 건은 목록에 올리지 않는다(추적 LOT 화면에서 기존 연결 확인으로 처리).
--
-- 저장 규칙
--   - 판단 근거·AI 제안은 대상 행 remark JSON 의 {judgment:{...}, ai_suggestion:{...}} 에 넣고(원래 remark 키는 보존),
--     사유는 '[공정] 판단:<결정> · <대상> · <근거>' 로 남겨 mqi_audit.row_change 가 이력이 된다(번복도 새 감사 행).
--   - 판독값은 field_review 새 행(append-only) + extracted_field.current_review_id 교체. 원문 칸(raw_value·extracted_value)은 그대로.
--   - 삭제는 VOID. 결정 코드는 팀 표 허용값(VERIFIED/CORRECTED/REJECTED/NEEDS_REVIEW, CONFIRMED, PROCESS_DEFECT, OTHER)만 쓴다.
--   - 이미지 근거는 브라우저에서 계산한 SHA-256 해시만 받는다(원본·사본 보관 안 함, DEC-001). 1건당 3개.

-- 0) remark 텍스트를 안전하게 JSON 으로 -------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.m13_try_jsonb(t text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $fn$
BEGIN
  IF t IS NULL OR btrim(t) = '' THEN RETURN '{}'::jsonb; END IF;
  BEGIN
    IF jsonb_typeof(t::jsonb) = 'object' THEN RETURN t::jsonb; END IF;
    RETURN jsonb_build_object('original_remark', t::jsonb);
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('original_remark', t);
  END;
END $fn$;

-- 1) 확인 필요 목록 ---------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.m13_review_queue AS
WITH out_lot AS (   -- 실행 → OUTPUT LOT 코드
    SELECT prl.process_run_id, string_agg(DISTINCT l.lot_code_raw, '/') AS lot_code
    FROM mqi.process_run_lot prl JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
    WHERE prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT'
    GROUP BY prl.process_run_id
),
lot_stage AS (      -- LOT → 그 LOT 을 만든 공정
    SELECT DISTINCT ON (prl.production_lot_id) prl.production_lot_id, p.process_code
    FROM mqi.process_run_lot prl JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
    JOIN mqi.process p ON p.process_id = pr.process_id
    WHERE prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT'
),
rv AS (
    SELECT 'READ_VALUE'::text AS kind, ef.extracted_field_id AS target_id, 'extracted_field'::text AS target_table,
           coalesce(ls.process_code, 'SOURCE') AS stage_code, pm.model_code, l.lot_date AS item_date,
           coalesce(l.lot_code_raw, ef.extracted_value) AS lot_code,
           coalesce(sl.source_label, ef.field_code) || ' 판독값 확인' AS title,
           ef.extracted_value AS current_value,
           jsonb_build_object('field_code', ef.field_code, 'raw_value', ef.raw_value, 'extracted_value', ef.extracted_value,
                              'sheet', sl.sheet_name, 'cell', sl.cell_reference, 'review_note', fr.review_note,
                              'linked_to', fpl.target_column_name, 'evidence_role', fpl.evidence_role) AS detail,
           ARRAY['VERIFIED', 'CORRECTED', 'REJECTED'] AS decisions, ef.recorded_at AS raised_at
    FROM mqi.extracted_field ef
    JOIN mqi.source_location sl ON sl.source_location_id = ef.source_location_id
    LEFT JOIN mqi.field_review fr ON fr.field_review_id = ef.current_review_id
    LEFT JOIN LATERAL (SELECT * FROM mqi.field_provenance_link f WHERE f.extracted_field_id = ef.extracted_field_id AND f.record_state = 'ACTIVE'
                       ORDER BY (f.evidence_role = 'PRIMARY') DESC LIMIT 1) fpl ON true
    LEFT JOIN mqi.production_lot l ON l.lot_id = fpl.target_lot_id
    LEFT JOIN mqi.product_model pm ON pm.model_id = l.model_id
    LEFT JOIN lot_stage ls ON ls.production_lot_id = l.lot_id
    WHERE ef.record_state = 'ACTIVE' AND ef.validation_status = 'NEEDS_REVIEW'
),
il AS (
    SELECT 'INSPECTION_LOT', il.inspection_lot_id, 'inspection_lot', 'IMEB3_FINAL_INSPECTION', pm.model_code, ir.inspection_date,
           NULL::text, '검사 LOT 판독 불가: ' || coalesce(il.lot_code_raw, '(빈칸)'), il.lot_code_raw,
           jsonb_build_object('lot_code_raw', il.lot_code_raw, 'box_count', il.recorded_box_count, 'quantity_raw', il.recorded_quantity_raw,
                              'inspection_label', ir.raw_inspection_label, 'round_no', ir.inspection_round_no,
                              'normalization', public.m13_try_jsonb(il.remark) ->> 'normalization_status'),
           ARRAY['CONFIRMED', 'UNRESOLVED', 'VOID'], il.recorded_at
    FROM mqi.inspection_lot il
    JOIN mqi.inspection_run ir ON ir.inspection_run_id = il.inspection_run_id
    JOIN mqi.product_model pm ON pm.model_id = il.model_id
    WHERE il.record_state = 'ACTIVE' AND il.lot_linkage_status = 'UNRESOLVED'
      AND NOT (public.m13_try_jsonb(il.remark) ? 'judgment')
),
ev AS (
    SELECT 'EVENT', e.event_id, 'production_event', coalesce(p.process_code, 'COMMON'), pm.model_code, coalesce(e.event_date, pr.work_date),
           ol.lot_code, '생산 이벤트 확인: ' || left(coalesce(e.event_description, e.event_type), 60), e.event_description,
           jsonb_build_object('event_type', e.event_type, 'description', e.event_description, 'duration_minutes', e.duration_minutes,
                              'start_at', e.event_start_at, 'source_file', public.m13_try_jsonb(e.remark) ->> 'file',
                              'source_page', public.m13_try_jsonb(e.remark) ->> 'page'),
           ARRAY['VERIFIED', 'REJECTED', 'VOID'], e.recorded_at
    FROM mqi.production_event e
    LEFT JOIN mqi.process_run pr ON pr.process_run_id = e.process_run_id
    LEFT JOIN mqi.process p ON p.process_id = pr.process_id
    LEFT JOIN mqi.product_model pm ON pm.model_id = pr.model_id
    LEFT JOIN out_lot ol ON ol.process_run_id = e.process_run_id
    WHERE e.record_state = 'ACTIVE' AND e.validation_status = 'NEEDS_REVIEW'
),
pos AS (
    SELECT 'POSITION', qc.quality_check_id, 'quality_check', 'IMEB3_CA_PRESS', pc.variant, qc.check_date,
           max(pc.ca_lot_code), '초품 위치도 ' || string_agg(DISTINCT pc.status, '·') || ' 확인',
           max(pc.pos_xy)::text,
           jsonb_build_object('points', jsonb_agg(jsonb_build_object('side', pc.side, 'no', pc.sample_no, 'x', pc.x, 'y', pc.y,
                                                                     'pos_xy', pc.pos_xy, 'status', pc.status) ORDER BY pc.side, pc.sample_no)
                                        FILTER (WHERE pc.status IN ('경계', '불량')),
                              'spec_pos', max(pc.spec_pos), 'control_pos', max(pc.control_pos), 'run_linked', qc.process_run_id IS NOT NULL),
           ARRAY['VERIFIED', 'CORRECTED', 'NEEDS_REVIEW'], qc.recorded_at
    FROM mqi.quality_check qc
    JOIN public.m13_position_checks pc ON pc.check_id = qc.quality_check_id::text
    WHERE qc.record_state = 'ACTIVE' AND qc.validation_status = 'UNVERIFIED'
    GROUP BY qc.quality_check_id, pc.variant, qc.check_date, qc.process_run_id, qc.recorded_at
    HAVING bool_or(pc.status IN ('경계', '불량'))
),
q AS (SELECT * FROM rv UNION ALL SELECT * FROM il UNION ALL SELECT * FROM ev UNION ALL SELECT * FROM pos)
SELECT q.kind || ':' || q.target_id AS item_id, q.kind, q.target_table, q.target_id::text AS target_id, q.stage_code,
       CASE q.stage_code WHEN 'IMEB3_INJECTION' THEN '사출' WHEN 'IMEB3_STITCHING' THEN '스티칭' WHEN 'IMEB3_WINDING' THEN '권선(BA)'
            WHEN 'IMEB3_CA_PRESS' THEN '압입(CA)' WHEN 'IMEB3_FINAL_INSPECTION' THEN '최종검사' WHEN 'SOURCE' THEN '원본·출처' ELSE '공통' END AS stage_label,
       q.model_code, to_char(q.item_date, 'YYYY-MM-DD') AS item_date, q.lot_code, q.title, q.current_value, q.detail, q.decisions, q.raised_at
FROM q;

GRANT SELECT ON public.m13_review_queue TO anon, authenticated, service_role;

-- 2) 판단 이력 (팀 감사 테이블에서) -----------------------------------------------------------------
CREATE OR REPLACE VIEW public.m13_judgment_log AS
SELECT r.audit_id, r.changed_at, r.transaction_id, r.actor_ref, r.change_reason, r.table_name, r.row_id::text AS row_id,
       j.judgment ->> 'kind' AS kind, j.judgment ->> 'decision' AS decision, j.judgment ->> 'decision_label' AS decision_label,
       j.judgment ->> 'stage_label' AS stage_label, j.judgment ->> 'model' AS model_code, j.judgment ->> 'lot_code' AS lot_code,
       j.judgment ->> 'item_date' AS item_date, j.judgment ->> 'title' AS title, j.judgment ->> 'value' AS value,
       j.judgment ->> 'basis' AS basis, j.judgment ->> 'note' AS note, j.judgment -> 'images' AS images,
       j.ai -> 'decision' #>> '{}' AS ai_decision, (j.ai ->> 'agreed')::boolean AS ai_agreed
FROM mqi_audit.row_change r
CROSS JOIN LATERAL (SELECT public.m13_try_jsonb(r.new_row ->> 'remark') -> 'judgment' AS judgment,
                           public.m13_try_jsonb(r.new_row ->> 'remark') -> 'ai_suggestion' AS ai) j
WHERE r.change_reason LIKE '[%] 판단:%'
  AND j.judgment IS NOT NULL
  AND j.judgment ->> 'target_table' = r.table_name AND j.judgment ->> 'target_id' = r.row_id::text
  AND j.judgment ->> 'txn' = r.transaction_id::text;      -- 이 판단을 저장한 그 트랜잭션의 행만(이후 다른 수정의 복사 방지)

REVOKE ALL ON public.m13_judgment_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.m13_judgment_log TO service_role;

-- 3) 판단 저장 RPC ----------------------------------------------------------------------------------
-- p = {item_id, decision, value?, lot_code?, basis_code?, note, images:[{sha256,name}], ai_suggestion?{decision,reason}, actor, reason}
CREATE OR REPLACE FUNCTION public.m13_judgment_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  q public.m13_review_queue%ROWTYPE;
  v_dec text := upper(coalesce(p->>'decision', ''));
  v_note text := btrim(coalesce(p->>'note', ''));
  v_val text := nullif(btrim(coalesce(p->>'value', '')), '');
  v_label text; v_j jsonb; v_ai jsonb; v_rem jsonb; v_id uuid; v_review uuid; v_lot uuid; v_model uuid; v_run uuid;
  v_out jsonb := '{}'::jsonb; v_images jsonb := coalesce(p->'images', '[]'::jsonb); v_txn text := txid_current()::text;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_judgment_save: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  SELECT * INTO q FROM public.m13_review_queue WHERE item_id = p->>'item_id';
  IF NOT FOUND THEN RAISE EXCEPTION '확인 필요 목록에 없는 항목입니다(이미 판단했거나 상태가 바뀜): %', p->>'item_id'; END IF;
  IF NOT (v_dec = ANY (q.decisions)) THEN RAISE EXCEPTION '이 항목에 쓸 수 없는 결정입니다: % (허용 %)', v_dec, q.decisions; END IF;
  IF char_length(v_note) < 5 OR char_length(v_note) > 500 THEN RAISE EXCEPTION '메모는 5~500자입니다'; END IF;
  IF v_note ~ '[0-9A-Za-z._%+-]+@[0-9A-Za-z.-]+\.[A-Za-z]{2,}' OR v_note ~ '01[016789][- ]?[0-9]{3,4}[- ]?[0-9]{4}' THEN
    RAISE EXCEPTION '메모에 이메일·전화번호 형태는 쓸 수 없습니다';
  END IF;
  IF jsonb_typeof(v_images) <> 'array' OR jsonb_array_length(v_images) > 3 THEN RAISE EXCEPTION '근거 이미지는 3개까지입니다'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_images) e WHERE coalesce(e->>'sha256', '') !~ '^[0-9a-f]{64}$') THEN
    RAISE EXCEPTION '근거 이미지는 SHA-256 해시만 받습니다';
  END IF;
  IF v_dec = 'CORRECTED' AND v_val IS NULL THEN RAISE EXCEPTION '정정값이 필요합니다'; END IF;
  IF v_dec IN ('CORRECTED', 'REJECTED') AND coalesce(p->>'basis_code', '') = '' THEN RAISE EXCEPTION '정정·반려는 사유 코드가 필요합니다'; END IF;

  v_label := CASE q.kind || ':' || v_dec
    WHEN 'READ_VALUE:VERIFIED' THEN '확인' WHEN 'READ_VALUE:CORRECTED' THEN '정정' WHEN 'READ_VALUE:REJECTED' THEN '반려'
    WHEN 'INSPECTION_LOT:CONFIRMED' THEN 'CA LOT 연결' WHEN 'INSPECTION_LOT:UNRESOLVED' THEN '미연결 유지' WHEN 'INSPECTION_LOT:VOID' THEN '삭제(VOID)'
    WHEN 'EVENT:VERIFIED' THEN '확인' WHEN 'EVENT:REJECTED' THEN '반려' WHEN 'EVENT:VOID' THEN '삭제(VOID)'
    WHEN 'POSITION:VERIFIED' THEN '확인' WHEN 'POSITION:CORRECTED' THEN '정정' WHEN 'POSITION:NEEDS_REVIEW' THEN '재측정 요청' END;

  v_j := jsonb_build_object('kind', q.kind, 'target_table', q.target_table, 'target_id', q.target_id, 'txn', v_txn,
                            'decision', v_dec, 'decision_label', v_label, 'stage_label', q.stage_label, 'model', q.model_code,
                            'lot_code', coalesce(nullif(p->>'lot_code', ''), q.lot_code), 'item_date', q.item_date, 'title', q.title,
                            'before', q.current_value, 'value', v_val, 'basis', p->>'basis_code', 'note', v_note, 'images', v_images,
                            'at', to_char(clock_timestamp() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD HH24:MI'));
  v_ai := CASE WHEN jsonb_typeof(p->'ai_suggestion') = 'object' AND coalesce(p->'ai_suggestion'->>'decision', '') <> ''
               THEN (p->'ai_suggestion') || jsonb_build_object('agreed', upper(p->'ai_suggestion'->>'decision') = v_dec) END;

  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason',
    format('[%s] 판단:%s · %s · %s', q.stage_label, v_label, left(q.title, 80), coalesce(nullif(p->>'basis_code', ''), left(v_note, 60))), true);
  v_id := q.target_id::uuid;

  IF q.kind = 'READ_VALUE' THEN
    INSERT INTO mqi.field_review (extracted_field_id, review_status, reviewed_value, review_reason_code, review_note, reviewer_ref, reviewed_at)
    SELECT v_id, v_dec, CASE v_dec WHEN 'CORRECTED' THEN v_val WHEN 'VERIFIED' THEN ef.extracted_value END,
           CASE WHEN v_dec IN ('CORRECTED', 'REJECTED') THEN p->>'basis_code' END, v_note, p->>'actor', clock_timestamp()
    FROM mqi.extracted_field ef WHERE ef.extracted_field_id = v_id
    RETURNING field_review_id INTO v_review;
    UPDATE mqi.extracted_field SET current_review_id = v_review,
           remark = (public.m13_try_jsonb(remark) || jsonb_build_object('judgment', v_j) || coalesce(jsonb_build_object('ai_suggestion', v_ai), '{}'::jsonb))::text
     WHERE extracted_field_id = v_id;
    v_out := jsonb_build_object('field_review_id', v_review,
      'note', CASE WHEN v_dec = 'CORRECTED' THEN '정정값은 검토 기록에 남김. 연결된 LOT 코드 자체는 바꾸지 않음(사슬 영향 확인 후 관리 화면에서)' END);

  ELSIF q.kind = 'INSPECTION_LOT' THEN
    v_rem := public.m13_try_jsonb((SELECT remark FROM mqi.inspection_lot WHERE inspection_lot_id = v_id))
             || jsonb_build_object('judgment', v_j) || coalesce(jsonb_build_object('ai_suggestion', v_ai), '{}'::jsonb);
    IF v_dec = 'CONFIRMED' THEN
      -- 사람이 적은 LOT 코드가 같은 모델 CA 실행의 OUTPUT LOT 일 때만 연결(추정 금지)
      SELECT l.lot_id INTO v_lot FROM mqi.production_lot l
        JOIN mqi.process_run_lot prl ON prl.production_lot_id = l.lot_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
        JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
        JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code = 'IMEB3_CA_PRESS'
        JOIN mqi.inspection_lot il ON il.inspection_lot_id = v_id AND il.model_id = l.model_id
       WHERE l.lot_code_raw = upper(btrim(p->>'lot_code')) AND l.record_state = 'ACTIVE'
       LIMIT 1;
      IF v_lot IS NULL THEN RAISE EXCEPTION '같은 모델의 CA 제품 LOT 코드가 아닙니다: %', p->>'lot_code'; END IF;
      UPDATE mqi.inspection_lot SET production_lot_id = v_lot, lot_linkage_status = 'CONFIRMED', remark = v_rem::text WHERE inspection_lot_id = v_id;
      v_out := jsonb_build_object('production_lot_id', v_lot);
    ELSIF v_dec = 'UNRESOLVED' THEN
      UPDATE mqi.inspection_lot SET remark = v_rem::text WHERE inspection_lot_id = v_id;
    ELSE
      UPDATE mqi.inspection_lot SET record_state = 'VOID', remark = v_rem::text WHERE inspection_lot_id = v_id;
    END IF;

  ELSIF q.kind = 'EVENT' THEN
    v_rem := public.m13_try_jsonb((SELECT remark FROM mqi.production_event WHERE event_id = v_id))
             || jsonb_build_object('judgment', v_j) || coalesce(jsonb_build_object('ai_suggestion', v_ai), '{}'::jsonb);
    UPDATE mqi.production_event
       SET validation_status = CASE WHEN v_dec = 'VOID' THEN validation_status ELSE v_dec END,
           record_state = CASE WHEN v_dec = 'VOID' THEN 'VOID' ELSE record_state END,
           event_description = CASE WHEN v_dec = 'VERIFIED' AND v_val IS NOT NULL THEN v_val ELSE event_description END,
           remark = v_rem::text
     WHERE event_id = v_id;

  ELSIF q.kind = 'POSITION' THEN
    SELECT model_id, process_run_id INTO v_model, v_run FROM mqi.quality_check WHERE quality_check_id = v_id;
    v_rem := public.m13_try_jsonb((SELECT remark FROM mqi.quality_check WHERE quality_check_id = v_id))
             || jsonb_build_object('judgment', v_j) || coalesce(jsonb_build_object('ai_suggestion', v_ai), '{}'::jsonb);
    IF v_dec = 'CORRECTED' THEN
      -- value = 'L|1|X|2.105' (좌우|시료|축|값). 원문 칸(raw_value_text)은 그대로 두고 측정값만 정정
      UPDATE mqi.measurement SET measured_value = split_part(v_val, '|', 4)::numeric,
             remark = (public.m13_try_jsonb(remark) || jsonb_build_object('corrected_by_judgment', v_txn))::text
       WHERE quality_check_id = v_id AND record_state = 'ACTIVE'
         AND measurement_point_code = upper(split_part(v_val, '|', 1)) AND sample_index = split_part(v_val, '|', 2)::int
         AND measurement_item_code = 'PIN_' || upper(split_part(v_val, '|', 3));
      IF NOT FOUND THEN RAISE EXCEPTION '정정할 측정값을 찾지 못했습니다(형식 좌우|시료|축|값, 예 L|1|X|2.105)'; END IF;
      UPDATE mqi.quality_check SET remark = v_rem::text WHERE quality_check_id = v_id;   -- 정정 후에도 목록에 남아 다시 판정
    ELSIF v_dec = 'VERIFIED' THEN
      UPDATE mqi.measurement SET validation_status = 'VERIFIED' WHERE quality_check_id = v_id AND record_state = 'ACTIVE';
      UPDATE mqi.quality_check SET validation_status = 'VERIFIED', remark = v_rem::text WHERE quality_check_id = v_id;
      IF v_run IS NOT NULL AND EXISTS (SELECT 1 FROM public.m13_position_checks WHERE check_id = v_id::text AND status = '불량') THEN
        INSERT INTO mqi.quality_finding (process_run_id, model_id, finding_class, raw_defect_name, validation_status, remark)
        VALUES (v_run, v_model, 'PROCESS_DEFECT', '초품 위치도 불량', 'VERIFIED',
                jsonb_build_object('from_quality_check', v_id, 'judgment_txn', v_txn)::text)
        RETURNING quality_finding_id INTO v_review;
        v_out := jsonb_build_object('quality_finding_id', v_review);
      END IF;
    ELSE  -- 재측정 요청
      UPDATE mqi.quality_check SET validation_status = 'NEEDS_REVIEW', remark = v_rem::text WHERE quality_check_id = v_id;
      IF v_run IS NOT NULL THEN
        INSERT INTO mqi.production_event (process_run_id, event_type, event_date, event_description, validation_status, remark)
        VALUES (v_run, 'OTHER', current_date, '초품 위치도 재측정 요청(같은 날 2차 초품)', 'UNVERIFIED',
                jsonb_build_object('from_quality_check', v_id, 'judgment_txn', v_txn)::text)
        RETURNING event_id INTO v_review;
        v_out := jsonb_build_object('event_id', v_review);
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'item_id', q.item_id, 'decision', v_dec, 'decision_label', v_label, 'lot_code', v_j->>'lot_code') || v_out;
END $fn$;

REVOKE ALL ON FUNCTION public.m13_judgment_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_judgment_save(jsonb) TO service_role;
