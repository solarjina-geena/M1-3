-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블 구조는 바꾸지 않는다. public 뷰·RPC 만 만든다. (2026-11-06)
-- 관리 화면 '사출조건 체크시트' 탭: 엑셀(IV·OV·HSV 같은 양식)을 올리면 탭(= 보빈 사출 LOT)별로 저장하고 사출 실행에 FK 연결.
-- IV 적재 도구(tools/injection_conditions_to_mqi.py → _link_fk.sql → _provenance.sql)와 같은 규칙을 한 번에:
--   설비        DS120-1 한 대(사용자 확인 2026-11-02: IV·OV·HSV 사출 모두 DS120-1, 시간상 겹치지 않음) → 실행에 설비 사용이 없으면 CONFIRMED 로 추가
--   실측        parameter_observation (EQUIPMENT_PHOTO, 사진 판독값) — 항목은 parameter_definition.parameter_code 로 찾고 없으면 만든다
--   실행 FK     탭 이름 = 보빈 LOT(사용자 규칙). 주간 행 = 탭 LOT(D 탭), 야간 행 = N 탭이면 탭 LOT, D 탭이면 같은 날 N1(사람 확인 전, NEEDS_REVIEW)
--               같은 모델 사출 실행 중 OUTPUT LOT 이 그 LOT 인 실행이 정확히 1건일 때만 연결(추정 금지)
--   기준        탭 기준 줄에 값이 있으면 모델·기준문서별 process_setup_spec(UNVERIFIED). OV 처럼 기준 줄이 비면 만들지 않음(보빈 중량 SPEC 은 기존 값)
--   출처        source_ingest → bundle → asset(sha256, 원본 비보관 DEC-001) → document(탭 1장) → location(시트·셀) → extracted_field → field_review → field_provenance_link(PRIMARY)
-- 중복: 같은 모델·같은 탭이 이미 있으면 replace=true 일 때만 이전 탭의 실측·문서·위치를 VOID 하고 다시 저장.

CREATE OR REPLACE FUNCTION public.m13_injection_sheet_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_model uuid; v_mcode text := p->>'model'; v_proc uuid; v_eq uuid; v_sha text := p#>>'{file,sha256}';
  v_asset uuid; v_ingest uuid; v_bundle uuid; v_ba uuid; v_xrun uuid; v_doc uuid; v_loc uuid; v_fld uuid; v_rev uuid; v_obs uuid;
  v_param uuid; v_run uuid; v_n int; v_lot text; v_lot_review text; v_spec uuid; v_val text;
  t jsonb; o jsonb; s record; v_old record;
  out_tabs int := 0; out_obs int := 0; out_linked int := 0; out_voided int := 0; out_specs int := 0; out_usage int := 0;
  out_detail jsonb := '[]'::jsonb; v_tab_linked int; v_tab_lots text[]; v_tab_unlinked text[];
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_injection_sheet_save: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[사출] 사출조건 체크시트 입력(M1-3 관리 화면)'), true);

  SELECT model_id INTO v_model FROM mqi.product_model WHERE model_code = v_mcode AND record_state = 'ACTIVE';
  IF v_model IS NULL THEN RAISE EXCEPTION '모델을 찾을 수 없음: %', v_mcode; END IF;
  SELECT process_id INTO v_proc FROM mqi.process WHERE process_code = 'IMEB3_INJECTION' AND record_state = 'ACTIVE';
  SELECT equipment_id INTO v_eq FROM mqi.equipment WHERE equipment_code = 'DS120-1' AND record_state = 'ACTIVE';
  IF v_eq IS NULL THEN RAISE EXCEPTION '사출 설비 DS120-1 이 DB 에 없습니다'; END IF;
  IF v_sha !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION '파일 해시가 없습니다'; END IF;
  IF jsonb_array_length(coalesce(p->'tabs', '[]'::jsonb)) = 0 THEN RAISE EXCEPTION '저장할 탭이 없습니다'; END IF;

  -- 원천 파일(해시만, 원본 비보관)
  SELECT asset_id INTO v_asset FROM mqi.source_asset WHERE sha256_hash = v_sha;
  IF v_asset IS NULL THEN
    v_asset := gen_random_uuid();
    INSERT INTO mqi.source_asset (asset_id, sha256_hash, asset_type, mime_type, file_size_bytes, storage_key, remark)
    VALUES (v_asset, v_sha, 'EXCEL', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', nullif(p#>>'{file,size}', '')::bigint,
            'UNSTORED:sha256:' || v_sha,
            jsonb_build_object('ds', 'INJ_COND_UPLOAD_V1', 'storage', 'UNSTORED', 'policy', 'DEC-001 원본 영구 비보관 — 해시·크기·셀 위치만 보존',
                               'original_filename', left(p#>>'{file,name}', 200))::text);
  END IF;
  v_ingest := gen_random_uuid(); v_bundle := gen_random_uuid(); v_ba := gen_random_uuid(); v_xrun := gen_random_uuid();
  INSERT INTO mqi.source_ingest (ingest_id, source_name, ingest_method, started_at, completed_at, ingest_status, importer_ref, remark)
  VALUES (v_ingest, left(p#>>'{file,name}', 200), 'FILE_UPLOAD', clock_timestamp(), clock_timestamp(), 'COMPLETED', 'manage.html 사출조건 체크시트',
          jsonb_build_object('ds', 'INJ_COND_UPLOAD_V1', 'model', v_mcode)::text);
  INSERT INTO mqi.source_bundle (bundle_id, ingest_id, bundle_name, bundle_type, original_path, remark)
  VALUES (v_bundle, v_ingest, '관리 화면 업로드', 'OTHER', NULL, '{"ds": "INJ_COND_UPLOAD_V1"}');
  INSERT INTO mqi.source_bundle_asset (bundle_asset_id, bundle_id, asset_id, original_filename, relative_path, remark)
  VALUES (v_ba, v_bundle, v_asset, left(p#>>'{file,name}', 200), left(p#>>'{file,name}', 200), '{"ds": "INJ_COND_UPLOAD_V1"}');
  INSERT INTO mqi.extraction_run (extraction_run_id, bundle_asset_id, extraction_method, parser_version, started_at, completed_at, extraction_status, remark)
  VALUES (v_xrun, v_ba, 'EXCEL_PARSER', 'backend/app/ingest/injection_sheet.py (칸 위치 고정표)', clock_timestamp(), clock_timestamp(), 'COMPLETED', '{"ds": "INJ_COND_UPLOAD_V1"}');

  FOR t IN SELECT * FROM jsonb_array_elements(p->'tabs') LOOP
    -- 중복: 같은 모델·같은 탭 문서
    FOR v_old IN SELECT d.document_id FROM mqi.source_document d
                  WHERE d.record_state = 'ACTIVE' AND d.document_type = 'INJECTION_CONDITION' AND d.document_reference = t->>'tab'
                    AND d.document_title LIKE '사출조건 체크시트 ' || v_mcode || ' %' LOOP
      IF coalesce((p->>'replace')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION '이미 저장된 사출조건 탭입니다(% %). 다시 넣으려면 "기존 기록 바꾸기"를 켜세요', v_mcode, t->>'tab';
      END IF;
      -- 이전 탭의 실측(그 탭 시트·같은 모델) VOID
      UPDATE mqi.parameter_observation po SET record_state = 'VOID'
       WHERE po.record_state = 'ACTIVE' AND EXISTS (
         SELECT 1 FROM mqi.field_provenance_link fl
         JOIN mqi.extracted_field ef ON ef.extracted_field_id = fl.extracted_field_id
         JOIN mqi.source_location l ON l.source_location_id = ef.source_location_id
         WHERE fl.parameter_observation_id = po.observation_id AND l.sheet_name = t->>'tab'
           AND EXISTS (SELECT 1 FROM mqi.extracted_field m JOIN mqi.source_location ml ON ml.source_location_id = m.source_location_id
                        WHERE ml.bundle_asset_id = l.bundle_asset_id AND ml.sheet_name = l.sheet_name AND m.field_code = 'MODEL' AND m.extracted_value = v_mcode));
      GET DIAGNOSTICS v_n = ROW_COUNT; out_voided := out_voided + v_n;
      UPDATE mqi.extracted_field ef SET record_state = 'VOID'
       WHERE ef.record_state = 'ACTIVE' AND ef.source_location_id IN (
         SELECT l.source_location_id FROM mqi.source_location l WHERE l.sheet_name = t->>'tab' AND l.record_state = 'ACTIVE'
           AND EXISTS (SELECT 1 FROM mqi.extracted_field m JOIN mqi.source_location ml ON ml.source_location_id = m.source_location_id
                        WHERE ml.bundle_asset_id = l.bundle_asset_id AND ml.sheet_name = l.sheet_name AND m.field_code = 'MODEL' AND m.extracted_value = v_mcode));
      UPDATE mqi.source_document SET record_state = 'VOID' WHERE document_id = v_old.document_id;
    END LOOP;

    v_doc := gen_random_uuid();
    INSERT INTO mqi.source_document (document_id, document_type, document_title, document_reference, validation_status, remark)
    VALUES (v_doc, 'INJECTION_CONDITION', '사출조건 체크시트 ' || v_mcode || ' (BOBBIN) LOT ' || (t->>'lot'), t->>'tab', 'VERIFIED',
            jsonb_build_object('ds', 'INJ_COND_UPLOAD_V1', 'model', v_mcode, 'file', left(p#>>'{file,name}', 200), 'note', '설비 화면 사진 판독값(체크시트)')::text);
    INSERT INTO mqi.source_document_version (document_version_id, document_id, asset_id, version_sequence, validation_status, remark)
    VALUES (gen_random_uuid(), v_doc, v_asset, 1, 'VERIFIED', '{"ds": "INJ_COND_UPLOAD_V1"}');

    -- 시트 단위 판독값: 탭 이름 LOT(주간), 야간 LOT, 모델
    FOR s IN SELECT * FROM (VALUES
        ('BOBBIN_LOT_DAY', 'A1:AE68', 'EXCEL_RANGE', '탭 이름(LOT)', t->>'tab', CASE WHEN t->>'shift' = 'D' THEN t->>'lot' ELSE NULL END, 'VERIFIED', '사용자 규칙: 엑셀 탭 이름이 LOT'),
        ('BOBBIN_LOT_NIGHT', 'A67', 'EXCEL_CELL', '야간 행 LOT', NULL,
         CASE WHEN t->>'shift' = 'N' THEN t->>'lot' WHEN (t->>'night_obs')::int > 0 THEN to_char((t->>'date')::date, 'YYMMDD') || 'N1' END,
         CASE WHEN t->>'shift' = 'N' THEN 'VERIFIED' ELSE 'NEEDS_REVIEW' END,
         CASE WHEN t->>'shift' = 'N' THEN '야간 탭 = 탭 이름 LOT' ELSE '주간 탭의 야간 행 = 같은 날 N1 LOT 로 판단. 사람 확인 필요' END),
        ('MODEL', 'A1', 'EXCEL_CELL', '제목(모델)', t->>'title', v_mcode, 'VERIFIED', '제목 칸 모델'),
        ('SPEC_REVISION', 'Y2', 'EXCEL_CELL', '기준문서', t->>'spec_doc', nullif(t->>'spec_rev', ''), 'VERIFIED', '기준문서 칸')
      ) AS x(code, cell, ltype, label, raw, val, review, note)
      WHERE x.val IS NOT NULL LOOP
      v_loc := gen_random_uuid(); v_fld := gen_random_uuid(); v_rev := gen_random_uuid();
      INSERT INTO mqi.source_location (source_location_id, bundle_asset_id, locator_type, sheet_name, cell_reference, source_label, remark)
      VALUES (v_loc, v_ba, s.ltype, t->>'tab', s.cell, s.label, '{"ds": "INJ_COND_UPLOAD_V1"}');
      INSERT INTO mqi.extracted_field (extracted_field_id, extraction_run_id, source_location_id, field_code, raw_value, extracted_value, validation_status, extracted_at, remark)
      VALUES (v_fld, v_xrun, v_loc, s.code, left(s.raw, 500), s.val, 'UNREVIEWED', clock_timestamp(), '{"ds": "INJ_COND_UPLOAD_V1"}');
      INSERT INTO mqi.field_review (field_review_id, extracted_field_id, review_status, reviewed_value, review_reason_code, review_note, reviewer_ref, reviewed_at)
      VALUES (v_rev, v_fld, s.review, s.val, CASE WHEN s.review = 'NEEDS_REVIEW' THEN 'OTHER' END, s.note, coalesce(nullif(p->>'actor', ''), 'm1-3-app'), clock_timestamp());
      UPDATE mqi.extracted_field SET current_review_id = v_rev WHERE extracted_field_id = v_fld;
    END LOOP;

    -- 실측
    v_tab_linked := 0; v_tab_lots := '{}'; v_tab_unlinked := '{}';
    FOR o IN SELECT * FROM jsonb_array_elements(coalesce(t->'obs', '[]'::jsonb)) LOOP
      SELECT parameter_id INTO v_param FROM mqi.parameter_definition WHERE parameter_code = o->>'code' AND record_state = 'ACTIVE' LIMIT 1;
      IF v_param IS NULL THEN
        v_param := gen_random_uuid();
        INSERT INTO mqi.parameter_definition (parameter_id, process_id, parameter_code, parameter_name, value_kind, unit, position_scope, description)
        VALUES (v_param, v_proc, o->>'code', coalesce(p#>>ARRAY['params', o->>'code', '0'], o->>'code'), 'NUMBER', p#>>ARRAY['params', o->>'code', '1'], 'EQUIPMENT',
                jsonb_build_object('ds', 'INJ_COND_UPLOAD_V1', 'group', coalesce(p#>>ARRAY['params', o->>'code', '2'], '조건'))::text);
      END IF;
      -- 행 → LOT
      v_lot := CASE WHEN o->>'row' = 'DAY' THEN CASE WHEN t->>'shift' = 'D' THEN t->>'lot' ELSE to_char((t->>'date')::date, 'YYMMDD') || 'D1' END
                    ELSE CASE WHEN t->>'shift' = 'N' THEN t->>'lot' ELSE to_char((t->>'date')::date, 'YYMMDD') || 'N1' END END;
      SELECT count(*), min(pr.process_run_id::text)::uuid INTO v_n, v_run
        FROM mqi.process_run pr
        JOIN mqi.process_run_lot prl ON prl.process_run_id = pr.process_run_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
        JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id AND l.lot_code_raw = v_lot
       WHERE pr.process_id = v_proc AND pr.model_id = v_model AND pr.record_state = 'ACTIVE';
      IF v_n <> 1 THEN v_run := NULL; END IF;
      IF v_run IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mqi.process_equipment_usage WHERE process_run_id = v_run AND equipment_id = v_eq AND record_state = 'ACTIVE') THEN
        INSERT INTO mqi.process_equipment_usage (equipment_usage_id, process_run_id, equipment_id, equipment_role, linkage_status, remark)
        VALUES (gen_random_uuid(), v_run, v_eq, 'PRIMARY', 'CONFIRMED',
                jsonb_build_object('ds', 'INJ_COND_UPLOAD_V1', 'evidence', '사용자 확인(2026-11-02): 전 모델 사출 DS120-1 단일 설비')::text);
        out_usage := out_usage + 1;
      END IF;
      v_obs := gen_random_uuid();
      INSERT INTO mqi.parameter_observation (observation_id, process_run_id, equipment_id, parameter_id, value_numeric, raw_value_text, observation_method, validation_status, remark)
      VALUES (v_obs, v_run, v_eq, v_param, (o->>'value')::numeric, left(o->>'raw', 200), 'EQUIPMENT_PHOTO', 'VERIFIED',
              jsonb_build_object('ds', 'INJ_COND_UPLOAD_V1', 'model', v_mcode, 'doc', v_doc,
                                 'run_link', CASE WHEN v_run IS NOT NULL THEN 'LOT ' || v_lot || ' 사출 실행 1건 일치' ELSE 'LOT ' || v_lot || ' 사출 실행 ' || v_n || '건 → 미연결' END)::text);
      SELECT value_numeric::text INTO v_val FROM mqi.parameter_observation WHERE observation_id = v_obs;
      v_loc := gen_random_uuid(); v_fld := gen_random_uuid(); v_rev := gen_random_uuid();
      INSERT INTO mqi.source_location (source_location_id, bundle_asset_id, locator_type, sheet_name, cell_reference, source_label, remark)
      VALUES (v_loc, v_ba, 'EXCEL_CELL', t->>'tab', o->>'cell',
              CASE o->>'row' WHEN 'DAY' THEN '주간 ' ELSE '야간 ' END || coalesce(p#>>ARRAY['params', o->>'code', '0'], o->>'code'), '{"ds": "INJ_COND_UPLOAD_V1"}');
      INSERT INTO mqi.extracted_field (extracted_field_id, extraction_run_id, source_location_id, field_code, raw_value, extracted_value, validation_status, extracted_at, remark)
      VALUES (v_fld, v_xrun, v_loc, o->>'code', left(o->>'raw', 500), v_val, 'UNREVIEWED', clock_timestamp(), '{"ds": "INJ_COND_UPLOAD_V1"}');
      INSERT INTO mqi.field_review (field_review_id, extracted_field_id, review_status, reviewed_value, review_note, reviewer_ref, reviewed_at)
      VALUES (v_rev, v_fld, 'VERIFIED', v_val, '체크시트 판독값(관리 화면 입력)', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), clock_timestamp());
      UPDATE mqi.extracted_field SET current_review_id = v_rev WHERE extracted_field_id = v_fld;
      INSERT INTO mqi.field_provenance_link (provenance_link_id, extracted_field_id, field_review_id, parameter_observation_id, target_column_name, evidence_role, remark)
      VALUES (gen_random_uuid(), v_fld, v_rev, v_obs, 'value_numeric', 'PRIMARY', '{"ds": "INJ_COND_UPLOAD_V1"}');
      out_obs := out_obs + 1;
      IF v_run IS NOT NULL THEN out_linked := out_linked + 1; v_tab_linked := v_tab_linked + 1;
        IF NOT v_lot = ANY (v_tab_lots) THEN v_tab_lots := v_tab_lots || v_lot; END IF;
      ELSIF NOT v_lot = ANY (v_tab_unlinked) THEN v_tab_unlinked := v_tab_unlinked || v_lot; END IF;
    END LOOP;

    -- 기준(탭 기준 줄에 값이 있을 때만) — 모델·기준문서별 1벌
    IF jsonb_typeof(t->'specs') = 'object' AND t->'specs' <> '{}'::jsonb AND nullif(t->>'spec_rev', '') IS NOT NULL THEN
      SELECT spec_id INTO v_spec FROM mqi.process_setup_spec
       WHERE model_id = v_model AND process_id = v_proc AND spec_revision = t->>'spec_rev' AND record_state = 'ACTIVE' LIMIT 1;
      IF v_spec IS NULL THEN
        v_spec := gen_random_uuid();
        INSERT INTO mqi.process_setup_spec (spec_id, model_id, process_id, equipment_id, spec_revision, verification_status, remark)
        VALUES (v_spec, v_model, v_proc, NULL, t->>'spec_rev', 'UNVERIFIED',
                jsonb_build_object('ds', 'INJ_COND_UPLOAD_V1', 'source', '체크시트 기준 줄 (' || (t->>'spec_doc') || '), 기준문서 원본 대조 전')::text);
        INSERT INTO mqi.process_setup_spec_item (spec_item_id, spec_id, parameter_id, target_numeric, min_numeric, max_numeric, remark)
        SELECT gen_random_uuid(), v_spec, pd.parameter_id, (e.value->>'target')::numeric,
               (e.value->>'target')::numeric - nullif(e.value->>'tol', '')::numeric, (e.value->>'target')::numeric + nullif(e.value->>'tol', '')::numeric,
               jsonb_build_object('ds', 'INJ_COND_UPLOAD_V1', 'cell', e.value->>'cell', 'tol_cell', e.value->>'tol_cell', 'tolerance', e.value->'tol')::text
        FROM jsonb_each(t->'specs') e JOIN mqi.parameter_definition pd ON pd.parameter_code = e.key AND pd.record_state = 'ACTIVE';
        GET DIAGNOSTICS v_n = ROW_COUNT; out_specs := out_specs + v_n;
      END IF;
    END IF;
    out_tabs := out_tabs + 1;
    out_detail := out_detail || jsonb_build_object('tab', t->>'tab', 'document_id', v_doc, 'obs', jsonb_array_length(coalesce(t->'obs', '[]'::jsonb)),
                                                  'linked', v_tab_linked, 'linked_lots', to_jsonb(v_tab_lots), 'unlinked_lots', to_jsonb(v_tab_unlinked));
  END LOOP;
  RETURN jsonb_build_object('tabs', out_tabs, 'observations', out_obs, 'linked', out_linked, 'voided', out_voided,
                            'spec_items', out_specs, 'equipment_usage_added', out_usage, 'detail', out_detail);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_injection_sheet_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_injection_sheet_save(jsonb) TO service_role;

-- 입력된 사출조건 탭 목록(관리 화면): 문서(탭) 1건 = 1행. IV 적재 도구(INJ_COND_XLSX_V1)로 넣은 탭도 함께 보인다.
CREATE OR REPLACE VIEW public.m13_injection_sheets AS
WITH d AS (
    SELECT d.document_id, d.document_reference AS tab, d.document_title, d.recorded_at,
           coalesce(public.m13_try_jsonb(d.remark) ->> 'model', substring(d.document_title FROM '체크시트 (IV|OV|HSV) ')) AS model_code,
           public.m13_try_jsonb(d.remark) ->> 'file' AS file, public.m13_try_jsonb(d.remark) ->> 'ds' AS ds
    FROM mqi.source_document d
    WHERE d.record_state = 'ACTIVE' AND d.document_type = 'INJECTION_CONDITION'
),
o AS (   -- 실측: 업로드분은 remark.doc, 도구 적재분은 시트 이름·모델로
    SELECT d.document_id, count(po.*) AS obs, count(po.process_run_id) AS linked,
           string_agg(DISTINCT l.lot_code_raw, ', ') AS lots
    FROM d
    JOIN mqi.parameter_observation po ON po.record_state = 'ACTIVE' AND (
         public.m13_try_jsonb(po.remark) ->> 'doc' = d.document_id::text
      OR (d.ds = 'INJ_COND_XLSX_V1' AND public.m13_try_jsonb(po.remark) ->> 'doc' IS NULL AND EXISTS (
            SELECT 1 FROM mqi.field_provenance_link fl JOIN mqi.extracted_field ef ON ef.extracted_field_id = fl.extracted_field_id
            JOIN mqi.source_location sl ON sl.source_location_id = ef.source_location_id
            WHERE fl.parameter_observation_id = po.observation_id AND fl.record_state = 'ACTIVE' AND sl.sheet_name = d.tab)))
    LEFT JOIN mqi.process_run_lot prl ON prl.process_run_id = po.process_run_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
    LEFT JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
    GROUP BY d.document_id
)
SELECT d.document_id::text AS document_id, d.model_code, d.tab, d.document_title, d.file, d.ds,
       coalesce(o.obs, 0) AS observations, coalesce(o.linked, 0) AS linked, o.lots AS linked_lots, d.recorded_at
FROM d LEFT JOIN o ON o.document_id = d.document_id;

GRANT SELECT ON public.m13_injection_sheets TO anon, authenticated, service_role;

-- 잘못 넣은 탭 삭제(VOID): 관리 화면 업로드분만(도구 적재분은 막는다)
CREATE OR REPLACE FUNCTION public.m13_injection_sheet_void(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE v_doc uuid := nullif(p->>'document_id', '')::uuid; v_n int; v_e int;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_injection_sheet_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF char_length(btrim(coalesce(p->>'note', ''))) < 5 THEN RAISE EXCEPTION '삭제 사유를 5자 이상 적어 주세요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.source_document WHERE document_id = v_doc AND record_state = 'ACTIVE' AND document_type = 'INJECTION_CONDITION'
                  AND public.m13_try_jsonb(remark) ->> 'ds' = 'INJ_COND_UPLOAD_V1') THEN
    RAISE EXCEPTION '관리 화면에서 넣은 사출조건 탭만 삭제할 수 있습니다';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[사출] 사출조건 탭 삭제(VOID) · ' || (p->>'note')), true);
  UPDATE mqi.extracted_field SET record_state = 'VOID'
   WHERE record_state = 'ACTIVE' AND extracted_field_id IN (
     SELECT fl.extracted_field_id FROM mqi.field_provenance_link fl JOIN mqi.parameter_observation po ON po.observation_id = fl.parameter_observation_id
     WHERE public.m13_try_jsonb(po.remark) ->> 'doc' = v_doc::text);
  GET DIAGNOSTICS v_e = ROW_COUNT;
  UPDATE mqi.parameter_observation SET record_state = 'VOID'
   WHERE record_state = 'ACTIVE' AND public.m13_try_jsonb(remark) ->> 'doc' = v_doc::text;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE mqi.source_document SET record_state = 'VOID' WHERE document_id = v_doc;
  RETURN jsonb_build_object('ok', true, 'document_id', v_doc, 'voided_observations', v_n, 'voided_fields', v_e);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_injection_sheet_void(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_injection_sheet_void(jsonb) TO service_role;
