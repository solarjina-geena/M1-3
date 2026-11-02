-- 개인 프로젝트 전용 데이터 작업 (IMEB3 DB). 팀 DB 적용 금지. 테이블 구조는 바꾸지 않고 팀 출처 테이블에 행을 넣는다.
-- 순서: tools/injection_conditions_to_mqi.py → tools/injection_conditions_link_fk.sql → 이 파일.
-- 사출조건 체크시트(엑셀)의 시트·셀 위치를 parameter_observation.remark JSON 에서 팀 출처 사슬로 옮긴다.
--   source_ingest → source_bundle → source_asset → source_bundle_asset
--   source_document(탭 = 사출 LOT 1장) → source_document_version
--   source_location(EXCEL_CELL: 시트 이름 + 셀, source_label = 주간/야간·기준·허용폭·제목·LOT)
--   extraction_run(EXCEL_PARSER) → extracted_field → field_review → field_provenance_link
--   source_run_link(시트 → 사출 실행)
-- 규칙(사용자 지시 2026-11-02): "엑셀 data 의 탭 이름이 LOT" → 탭 20260810D1 = 보빈(사출) LOT 260810D1. 사출 화면은 날짜 대신 LOT 으로 표시.
--   야간 행은 같은 날 N1 LOT(시트 하단 '사진 원본 참조 …N' 근거) → 사람 확인 전이라 NEEDS_REVIEW, CROSS_CHECK.
--   PRIMARY 연결은 팀 트리거 규칙대로 field_review(VERIFIED) 값 = 대상 칸 값일 때만. 허용폭 셀은 min/max 와 값이 달라 CROSS_CHECK.
-- 원본 파일: sha256 ce7c6e07…3f55, 7,518,349 bytes (M1-2/firestore_import/사출조건표.xlsx).
-- 다시 돌려도 결과가 같다(md5 결정적 id + ON CONFLICT). 마지막에 실측·기준 remark 의 시트/셀/날짜/주야를 지운다.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL mqi.actor_ref = 'm1-3-injection-conditions';
SET LOCAL mqi.change_reason = '사출조건 체크시트 출처를 팀 출처 테이블로 이전(시트·셀 = source_location, 탭 이름 = 사출 LOT), 보빈무게 SPEC 확정, 조건 우선순위를 parameter_definition JSON 으로 (2026-11-02)';

-- 0) 작업 대상: 아직 remark 에 시트/셀이 남은 실측
CREATE TEMP TABLE t_obs ON COMMIT DROP AS
SELECT po.observation_id, po.parameter_id, po.process_run_id, po.value_numeric, po.raw_value_text,
       po.remark::jsonb ->> 'sheet' AS sheet, po.remark::jsonb ->> 'cell' AS cell,
       po.remark::jsonb ->> 'shift' AS shift, coalesce(po.remark::jsonb ->> 'model', 'IV') AS model,
       pd.parameter_code, pd.parameter_name
FROM mqi.parameter_observation po
JOIN mqi.parameter_definition pd ON pd.parameter_id = po.parameter_id
WHERE po.record_state = 'ACTIVE' AND po.remark ~ '^\{' AND po.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1'
  AND po.remark::jsonb ? 'sheet';

CREATE TEMP TABLE t_sheet ON COMMIT DROP AS
SELECT sheet, max(model) AS model,
       substr(sheet, 3, 6) || 'D1' AS lot_day, substr(sheet, 3, 6) || 'N1' AS lot_night,
       bool_or(shift = 'NIGHT') AS has_night
FROM t_obs GROUP BY sheet;

-- 1) 원천 파일
INSERT INTO mqi.source_ingest (ingest_id, source_name, ingest_method, started_at, completed_at, ingest_status, importer_ref, remark)
VALUES (md5('m13:inj-cond:ingest')::uuid, '사출조건표.xlsx', 'BATCH_IMPORT', clock_timestamp(), clock_timestamp(), 'COMPLETED',
        'tools/injection_conditions_to_mqi.py', '{"ds": "INJ_COND_XLSX_V1"}')
ON CONFLICT DO NOTHING;
INSERT INTO mqi.source_bundle (bundle_id, ingest_id, bundle_name, bundle_type, original_path, remark)
VALUES (md5('m13:inj-cond:bundle')::uuid, md5('m13:inj-cond:ingest')::uuid, 'M1-2 firestore_import', 'FOLDER', 'M1-2/firestore_import', '{"ds": "INJ_COND_XLSX_V1"}')
ON CONFLICT DO NOTHING;
INSERT INTO mqi.source_asset (asset_id, sha256_hash, asset_type, mime_type, file_size_bytes, storage_key, remark)
VALUES (md5('m13:inj-cond:asset')::uuid, 'ce7c6e077e48e870ea69918fda346c27339ea8ddb638f0a1137f2da163f53f55', 'EXCEL',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 7518349, 'local/M1-2/firestore_import/사출조건표.xlsx',
        '{"ds": "INJ_COND_XLSX_V1", "note": "비공개 원본, 로컬 보관"}')
ON CONFLICT DO NOTHING;
INSERT INTO mqi.source_bundle_asset (bundle_asset_id, bundle_id, asset_id, original_filename, relative_path, remark)
VALUES (md5('m13:inj-cond:bundle-asset')::uuid, md5('m13:inj-cond:bundle')::uuid, md5('m13:inj-cond:asset')::uuid,
        '사출조건표.xlsx', '사출조건표.xlsx', '{"ds": "INJ_COND_XLSX_V1"}')
ON CONFLICT DO NOTHING;

-- 2) 문서: 탭 1장 = 사출조건 체크시트 1건(탭 이름 = LOT)
INSERT INTO mqi.source_document (document_id, document_type, document_title, document_reference, validation_status, remark)
SELECT md5('m13:inj-cond:doc|' || sheet)::uuid, 'INJECTION_CONDITION', '사출조건 체크시트 ' || model || ' (BOBBIN) LOT ' || lot_day, sheet, 'VERIFIED',
       '{"ds": "INJ_COND_XLSX_V1", "note": "설비 화면 사진 판독, 사진_인벤토리 판독 완료(재검증)"}'
FROM t_sheet ON CONFLICT DO NOTHING;
INSERT INTO mqi.source_document_version (document_version_id, document_id, asset_id, version_sequence, validation_status, remark)
SELECT md5('m13:inj-cond:docver|' || sheet)::uuid, md5('m13:inj-cond:doc|' || sheet)::uuid, md5('m13:inj-cond:asset')::uuid, 1, 'VERIFIED',
       '{"ds": "INJ_COND_XLSX_V1"}'
FROM t_sheet ON CONFLICT DO NOTHING;

INSERT INTO mqi.extraction_run (extraction_run_id, bundle_asset_id, extraction_method, parser_version, started_at, completed_at, extraction_status, remark)
VALUES (md5('m13:inj-cond:xrun')::uuid, md5('m13:inj-cond:bundle-asset')::uuid, 'EXCEL_PARSER', 'tools/injection_conditions_to_mqi.py (칸 위치 고정표)',
        clock_timestamp(), clock_timestamp(), 'COMPLETED', '{"ds": "INJ_COND_XLSX_V1"}')
ON CONFLICT DO NOTHING;

-- 3) 위치·판독값 목록 (k = 결정적 키)
CREATE TEMP TABLE t_fld ON COMMIT DROP AS
-- 실측 셀
SELECT 'obs|' || o.sheet || '|' || o.cell AS k, o.sheet, o.cell, 'EXCEL_CELL' AS loc_type,
       CASE o.shift WHEN 'DAY' THEN '주간 ' WHEN 'NIGHT' THEN '야간 ' ELSE '' END || o.parameter_name AS label,
       o.parameter_code AS field_code, o.raw_value_text AS raw, o.value_numeric::text AS val, 'VERIFIED' AS review,
       '설비 화면 사진 판독·재검증(사진_인벤토리)' AS note
FROM t_obs o
UNION ALL
-- 기준·허용폭 셀 (9개 탭이 같은 값 → 첫 탭을 근거로)
SELECT 'spec|' || f.sheet || '|' || (i.remark::jsonb ->> 'cell'), f.sheet, i.remark::jsonb ->> 'cell', 'EXCEL_CELL',
       '기준 ' || pd.parameter_name, pd.parameter_code, i.target_numeric::text, i.target_numeric::text, 'VERIFIED',
       '체크시트 기준 줄(적재 도구가 9개 탭 동일 확인)'
FROM mqi.process_setup_spec_item i
JOIN mqi.parameter_definition pd ON pd.parameter_id = i.parameter_id
CROSS JOIN (SELECT min(sheet) AS sheet FROM t_sheet) f
WHERE i.remark ~ '^\{' AND i.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1' AND i.remark::jsonb ? 'cell'
UNION ALL
SELECT 'tol|' || f.sheet || '|' || (i.remark::jsonb ->> 'tol_cell'), f.sheet, i.remark::jsonb ->> 'tol_cell', 'EXCEL_CELL',
       '허용폭 ' || pd.parameter_name, pd.parameter_code || '_TOL', i.remark::jsonb ->> 'tolerance', i.remark::jsonb ->> 'tolerance', 'VERIFIED',
       '허용폭(±) → 기준 ± 허용폭 = 하한·상한'
FROM mqi.process_setup_spec_item i
JOIN mqi.parameter_definition pd ON pd.parameter_id = i.parameter_id
CROSS JOIN (SELECT min(sheet) AS sheet FROM t_sheet) f
WHERE i.remark ~ '^\{' AND i.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1' AND i.remark::jsonb ->> 'tol_cell' IS NOT NULL
UNION ALL
-- 탭 이름 = 보빈(사출) LOT (주간 행)
SELECT 'lot-day|' || sheet, sheet, 'A1:AE68', 'EXCEL_RANGE', '탭 이름(LOT)', 'BOBBIN_LOT_DAY', sheet, lot_day, 'VERIFIED',
       '사용자 지시: 엑셀 탭 이름이 LOT'
FROM t_sheet
UNION ALL
-- 야간 행의 LOT (N1) — 사람 확인 전
SELECT 'lot-night|' || sheet, sheet, 'A67', 'EXCEL_CELL', '야간 행 LOT(사진 원본 참조 N)', 'BOBBIN_LOT_NIGHT', NULL, lot_night, 'NEEDS_REVIEW',
       '야간 행 = 같은 날 N1 LOT 로 판단(시트 하단 사진 원본 참조 …N). 사람 확인 필요'
FROM t_sheet WHERE has_night
UNION ALL
-- 제목 셀 = 모델
SELECT 'model|' || sheet, sheet, 'A1', 'EXCEL_CELL', '제목(모델)', 'MODEL', NULL, model, 'VERIFIED', '제목 사출조건 체크시트 I MEB3 ' || model
FROM t_sheet
UNION ALL
-- 기준문서 번호
SELECT 'specdoc|' || f.sheet, f.sheet, 'Y2', 'EXCEL_CELL', '기준문서', 'SPEC_REVISION', s.spec_revision, s.spec_revision, 'VERIFIED', '기준문서 번호'
FROM mqi.process_setup_spec s CROSS JOIN (SELECT min(sheet) AS sheet FROM t_sheet) f
WHERE s.remark ~ '^\{' AND s.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1';

INSERT INTO mqi.source_location (source_location_id, bundle_asset_id, locator_type, sheet_name, cell_reference, source_label, remark)
SELECT md5('m13:inj-cond:loc|' || k)::uuid, md5('m13:inj-cond:bundle-asset')::uuid, loc_type, sheet, cell, label, '{"ds": "INJ_COND_XLSX_V1"}'
FROM t_fld ON CONFLICT DO NOTHING;

INSERT INTO mqi.extracted_field (extracted_field_id, extraction_run_id, source_location_id, field_code, raw_value, extracted_value, validation_status, extracted_at, remark)
SELECT md5('m13:inj-cond:fld|' || k)::uuid, md5('m13:inj-cond:xrun')::uuid, md5('m13:inj-cond:loc|' || k)::uuid, field_code, raw, val,
       'UNREVIEWED', clock_timestamp(), '{"ds": "INJ_COND_XLSX_V1"}'
FROM t_fld ON CONFLICT DO NOTHING;

INSERT INTO mqi.field_review (field_review_id, extracted_field_id, review_status, reviewed_value, review_reason_code, review_note, reviewer_ref, reviewed_at)
SELECT md5('m13:inj-cond:rev|' || k)::uuid, md5('m13:inj-cond:fld|' || k)::uuid, review, val, CASE WHEN review = 'NEEDS_REVIEW' THEN 'OTHER' END, note,
       CASE WHEN review = 'VERIFIED' THEN '팀장(사진 원본 재검증·탭 이름 LOT 지시)' ELSE 'm1-3-injection-conditions' END, clock_timestamp()
FROM t_fld ON CONFLICT DO NOTHING;

UPDATE mqi.extracted_field ef SET current_review_id = md5('m13:inj-cond:rev|' || f.k)::uuid
FROM t_fld f WHERE ef.extracted_field_id = md5('m13:inj-cond:fld|' || f.k)::uuid AND ef.current_review_id IS NULL;

-- 4) 출처 연결
-- 실측값 ← 셀 (PRIMARY)
INSERT INTO mqi.field_provenance_link (provenance_link_id, extracted_field_id, field_review_id, parameter_observation_id, target_column_name, evidence_role, remark)
SELECT md5('m13:inj-cond:prov|obs|' || o.observation_id)::uuid, md5('m13:inj-cond:fld|obs|' || o.sheet || '|' || o.cell)::uuid,
       md5('m13:inj-cond:rev|obs|' || o.sheet || '|' || o.cell)::uuid, o.observation_id, 'value_numeric', 'PRIMARY', '{"ds": "INJ_COND_XLSX_V1"}'
FROM t_obs o ON CONFLICT DO NOTHING;
-- 기준값 ← 기준 셀 (PRIMARY), 하한·상한 ← 허용폭 셀 (CROSS_CHECK)
INSERT INTO mqi.field_provenance_link (provenance_link_id, extracted_field_id, field_review_id, spec_item_id, target_column_name, evidence_role, remark)
SELECT md5('m13:inj-cond:prov|spec|' || i.spec_item_id)::uuid, md5('m13:inj-cond:fld|spec|' || f.sheet || '|' || (i.remark::jsonb ->> 'cell'))::uuid,
       md5('m13:inj-cond:rev|spec|' || f.sheet || '|' || (i.remark::jsonb ->> 'cell'))::uuid, i.spec_item_id, 'target_numeric', 'PRIMARY', '{"ds": "INJ_COND_XLSX_V1"}'
FROM mqi.process_setup_spec_item i CROSS JOIN (SELECT min(sheet) AS sheet FROM t_sheet) f
WHERE i.remark ~ '^\{' AND i.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1' AND i.remark::jsonb ? 'cell'
ON CONFLICT DO NOTHING;
INSERT INTO mqi.field_provenance_link (provenance_link_id, extracted_field_id, spec_item_id, target_column_name, evidence_role, remark)
SELECT md5('m13:inj-cond:prov|tol|' || c.col || '|' || i.spec_item_id)::uuid, md5('m13:inj-cond:fld|tol|' || f.sheet || '|' || (i.remark::jsonb ->> 'tol_cell'))::uuid,
       i.spec_item_id, c.col, 'CROSS_CHECK', '{"ds": "INJ_COND_XLSX_V1", "rule": "기준 ± 허용폭"}'
FROM mqi.process_setup_spec_item i CROSS JOIN (SELECT min(sheet) AS sheet FROM t_sheet) f
CROSS JOIN (VALUES ('min_numeric'), ('max_numeric')) c(col)
WHERE i.remark ~ '^\{' AND i.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1' AND i.remark::jsonb ->> 'tol_cell' IS NOT NULL
ON CONFLICT DO NOTHING;
-- 기준문서 번호 ← Y2 (PRIMARY)
INSERT INTO mqi.field_provenance_link (provenance_link_id, extracted_field_id, field_review_id, target_spec_id, target_column_name, evidence_role, remark)
SELECT md5('m13:inj-cond:prov|specdoc|' || s.spec_id)::uuid, md5('m13:inj-cond:fld|specdoc|' || f.sheet)::uuid, md5('m13:inj-cond:rev|specdoc|' || f.sheet)::uuid,
       s.spec_id, 'spec_revision', 'PRIMARY', '{"ds": "INJ_COND_XLSX_V1"}'
FROM mqi.process_setup_spec s CROSS JOIN (SELECT min(sheet) AS sheet FROM t_sheet) f
WHERE s.remark ~ '^\{' AND s.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1'
ON CONFLICT DO NOTHING;
-- 모델 ← 제목 셀 (PRIMARY)
INSERT INTO mqi.field_provenance_link (provenance_link_id, extracted_field_id, field_review_id, target_model_id, target_column_name, evidence_role, remark)
SELECT md5('m13:inj-cond:prov|model|' || t.sheet)::uuid, md5('m13:inj-cond:fld|model|' || t.sheet)::uuid, md5('m13:inj-cond:rev|model|' || t.sheet)::uuid,
       pm.model_id, 'model_code', 'PRIMARY', '{"ds": "INJ_COND_XLSX_V1"}'
FROM t_sheet t JOIN mqi.product_model pm ON pm.model_code = t.model
ON CONFLICT DO NOTHING;
-- 보빈(사출) LOT ← 탭 이름 (주간 PRIMARY) / 야간 행 (CROSS_CHECK). 사출 실행의 OUTPUT LOT 이 DB 에 있을 때만.
INSERT INTO mqi.field_provenance_link (provenance_link_id, extracted_field_id, field_review_id, target_lot_id, target_column_name, evidence_role, remark)
SELECT md5('m13:inj-cond:prov|lot|' || x.kind || '|' || x.sheet || '|' || l.lot_id)::uuid, md5('m13:inj-cond:fld|' || x.kind || '|' || x.sheet)::uuid,
       CASE WHEN x.kind = 'lot-day' THEN md5('m13:inj-cond:rev|lot-day|' || x.sheet)::uuid END,
       l.lot_id, 'lot_code_raw', CASE WHEN x.kind = 'lot-day' THEN 'PRIMARY' ELSE 'CROSS_CHECK' END, '{"ds": "INJ_COND_XLSX_V1"}'
FROM (SELECT sheet, model, 'lot-day' AS kind, lot_day AS lot FROM t_sheet
      UNION ALL SELECT sheet, model, 'lot-night', lot_night FROM t_sheet WHERE has_night) x
JOIN mqi.product_model pm ON pm.model_code = x.model
JOIN mqi.production_lot l ON l.lot_code_raw = x.lot AND l.model_id = pm.model_id AND l.record_state = 'ACTIVE'
WHERE EXISTS (SELECT 1 FROM mqi.process_run_lot prl JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
              JOIN mqi.process p ON p.process_id = pr.process_id AND p.process_code = 'IMEB3_INJECTION'
              WHERE prl.production_lot_id = l.lot_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE')
ON CONFLICT DO NOTHING;

-- 5) 시트 → 사출 실행 (탭 LOT = 실행 OUTPUT LOT: 주간 CONFIRMED, 야간 N1 CANDIDATE)
INSERT INTO mqi.source_run_link (source_run_link_id, bundle_asset_id, process_run_id, linkage_status, evidence_note, remark)
SELECT md5('m13:inj-cond:srl|' || x.sheet || '|' || pr.process_run_id)::uuid, md5('m13:inj-cond:bundle-asset')::uuid, pr.process_run_id,
       CASE WHEN x.kind = 'D' THEN 'CONFIRMED' ELSE 'CANDIDATE' END,
       '시트 ' || x.sheet || ' → 보빈 LOT ' || x.lot || CASE WHEN x.kind = 'D' THEN ' (탭 이름)' ELSE ' (야간 행, 사람 확인 전)' END,
       '{"ds": "INJ_COND_XLSX_V1"}'
FROM (SELECT sheet, model, 'D' AS kind, lot_day AS lot FROM t_sheet UNION ALL SELECT sheet, model, 'N', lot_night FROM t_sheet WHERE has_night) x
JOIN mqi.product_model pm ON pm.model_code = x.model
JOIN mqi.production_lot l ON l.lot_code_raw = x.lot AND l.model_id = pm.model_id AND l.record_state = 'ACTIVE'
JOIN mqi.process_run_lot prl ON prl.production_lot_id = l.lot_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id AND pr.record_state = 'ACTIVE'
JOIN mqi.process p ON p.process_id = pr.process_id AND p.process_code = 'IMEB3_INJECTION'
ON CONFLICT DO NOTHING;

-- 6) remark 정리: 시트·셀·날짜·주야·모델은 출처 테이블과 사출 실행 FK 로 옮겼으므로 지운다
UPDATE mqi.parameter_observation po SET remark = '{"ds": "INJ_COND_XLSX_V1"}'
FROM t_obs o
WHERE po.observation_id = o.observation_id
  AND EXISTS (SELECT 1 FROM mqi.field_provenance_link fl WHERE fl.parameter_observation_id = po.observation_id AND fl.record_state = 'ACTIVE');
UPDATE mqi.process_setup_spec_item i SET remark = '{"ds": "INJ_COND_XLSX_V1"}'
WHERE i.remark ~ '^\{' AND i.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1'
  AND EXISTS (SELECT 1 FROM mqi.field_provenance_link fl WHERE fl.spec_item_id = i.spec_item_id AND fl.record_state = 'ACTIVE');

-- 7) 보빈무게 SPEC 확정 (팀장 확인 2026-11-02)
UPDATE mqi.process_setup_spec SET verification_status = 'CONFIRMED',
       remark = '{"ds": "BOBBIN_WT_SPEC_V1", "source": "IV 11.0~11.6 / OV 12.0~12.6 / HSV 12.1~12.7 g", "confirmed_by": "팀장 확인 2026-11-02"}'
WHERE spec_revision = 'BOBBIN-WT' AND verification_status <> 'CONFIRMED';

-- 8) 조건 우선순위(사출 전문가 기준, 보빈 중량 영향 순)를 parameter_definition.description JSON 으로
UPDATE mqi.parameter_definition d
SET description = (CASE WHEN d.description ~ '^\{' THEN d.description::jsonb ELSE '{}'::jsonb END || jsonb_build_object('priority', v.p::jsonb))::text
FROM (VALUES
  ('INJ_PRESS_HOLD1',      '{"rank": 1, "order": 1, "title": "사출압력 · 보압", "why": "보압(압력·시간)이 캐비티 보압충전량을 정해 보빈 중량·치수에 가장 직접 작용", "chart": true}'),
  ('INJ_PRESS_S1',         '{"rank": 1, "order": 2, "title": "사출압력 · 보압", "why": "보압(압력·시간)이 캐비티 보압충전량을 정해 보빈 중량·치수에 가장 직접 작용", "chart": true}'),
  ('MON_SWITCH_POS_START', '{"rank": 2, "order": 1, "title": "전환위치(V/P) · 쿠션", "why": "충전→보압 전환 시점과 남은 쿠션량이 샷 충전량 편차(미성형·과충전)를 좌우", "chart": true}'),
  ('INJ_CUSHION',          '{"rank": 2, "order": 2, "title": "전환위치(V/P) · 쿠션", "why": "충전→보압 전환 시점과 남은 쿠션량이 샷 충전량 편차(미성형·과충전)를 좌우", "chart": true}'),
  ('INJ_TEMP_NZ',          '{"rank": 3, "order": 1, "title": "온도 (노즐·실린더·금형)", "why": "용융 점도와 수축률을 바꿔 중량·치수에 영향, 변화는 느리게 나타남", "chart": true}'),
  ('INJ_TEMP_H1',          '{"rank": 3, "order": 2, "title": "온도 (노즐·실린더·금형)", "why": "용융 점도와 수축률을 바꿔 중량·치수에 영향, 변화는 느리게 나타남", "chart": true}'),
  ('MOLD_TEMP_FIXED',      '{"rank": 3, "order": 3, "title": "온도 (노즐·실린더·금형)", "why": "용융 점도와 수축률을 바꿔 중량·치수에 영향, 변화는 느리게 나타남", "chart": true, "axis": "right"}'),
  ('INJ_SPEED_S1',         '{"rank": 4, "order": 1, "title": "사출속도", "why": "충전 패턴·외관 영향, 중량 영향 작음", "chart": false}'),
  ('REC_POS_M3',           '{"rank": 5, "order": 1, "title": "계량", "why": "설정 고정, 결과는 쿠션으로 확인", "chart": false}'),
  ('BOBBIN_WEIGHT',        '{"rank": 0, "order": 1, "title": "보빈 중량", "why": "모델별 SPEC 상자 + 실측 DOT", "chart": true, "role": "bobbin_weight"}')
) AS v(code, p)
WHERE d.parameter_code = v.code AND (d.description IS NULL OR NOT (d.description::jsonb ? 'priority'));
COMMIT;
