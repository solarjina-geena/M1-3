-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블은 건드리지 않고 public 조회 뷰만 고친다.
-- m13_injection_condition_rows 를 remark JSON 대신 팀 출처 사슬에서 읽도록 다시 만든다(열 이름은 유지, lot_code·priority 추가, SPEC_TARGET 행은 뺌).
--   시트·셀·주/야 = field_provenance_link(PRIMARY) → extracted_field → source_location(sheet_name, cell_reference, source_label)
--   LOT        = 사출 실행 OUTPUT LOT(process_run_lot), 실행이 없으면 같은 시트의 판독값 BOBBIN_LOT_DAY / BOBBIN_LOT_NIGHT (탭 이름 = LOT)
--   모델       = 사출 실행 모델, 없으면 같은 시트의 판독값 MODEL(제목 셀)
--   우선순위   = parameter_definition.description JSON 의 priority
-- 사출 화면은 날짜를 쓰지 않는다. date 열은 이전 호환용(사출 실행 작업일, 실행이 없으면 NULL).

DROP VIEW IF EXISTS public.m13_injection_condition_rows;
CREATE VIEW public.m13_injection_condition_rows AS
WITH prov AS (
    SELECT fl.parameter_observation_id, l.sheet_name, l.cell_reference, l.source_label, l.bundle_asset_id
    FROM mqi.field_provenance_link fl
    JOIN mqi.extracted_field ef ON ef.extracted_field_id = fl.extracted_field_id AND ef.record_state = 'ACTIVE'
    JOIN mqi.source_location l ON l.source_location_id = ef.source_location_id AND l.record_state = 'ACTIVE'
    WHERE fl.record_state = 'ACTIVE' AND fl.evidence_role = 'PRIMARY' AND fl.parameter_observation_id IS NOT NULL
),
sheetf AS (   -- 시트 단위 판독값: 탭 이름 LOT(주간)·야간 LOT·모델
    SELECT l.bundle_asset_id, l.sheet_name,
           max(ef.extracted_value) FILTER (WHERE ef.field_code = 'BOBBIN_LOT_DAY') AS lot_day,
           max(ef.extracted_value) FILTER (WHERE ef.field_code = 'BOBBIN_LOT_NIGHT') AS lot_night,
           max(ef.extracted_value) FILTER (WHERE ef.field_code = 'MODEL') AS model_code
    FROM mqi.extracted_field ef
    JOIN mqi.source_location l ON l.source_location_id = ef.source_location_id AND l.record_state = 'ACTIVE'
    WHERE ef.record_state = 'ACTIVE' AND ef.field_code IN ('BOBBIN_LOT_DAY', 'BOBBIN_LOT_NIGHT', 'MODEL')
    GROUP BY l.bundle_asset_id, l.sheet_name
),
pd AS (
    SELECT d.parameter_id, d.parameter_code, d.parameter_name, d.unit,
           CASE WHEN d.description ~ '^\{' THEN d.description::jsonb ELSE '{}'::jsonb END AS dj
    FROM mqi.parameter_definition d
    WHERE d.record_state = 'ACTIVE'
),
spec AS (
    SELECT s.model_id, s.spec_revision, s.effective_from, s.effective_to, s.verification_status,
           i.spec_item_id, i.parameter_id, i.target_numeric, i.min_numeric, i.max_numeric
    FROM mqi.process_setup_spec s
    JOIN mqi.process_setup_spec_item i ON i.spec_id = s.spec_id AND i.record_state = 'ACTIVE'
    WHERE s.record_state = 'ACTIVE' AND (i.target_numeric IS NOT NULL OR i.min_numeric IS NOT NULL OR i.max_numeric IS NOT NULL)
),
runlot AS (
    SELECT prl.process_run_id, string_agg(DISTINCT l.lot_code_raw, '/') AS bobbin_lot_code
    FROM mqi.process_run_lot prl
    JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
    WHERE prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT'
    GROUP BY prl.process_run_id
),
o AS (
    SELECT po.observation_id, po.parameter_id, po.value_numeric, po.raw_value_text, po.validation_status, po.process_run_id,
           pd.parameter_code, pd.parameter_name, pd.unit, pd.dj,
           coalesce(pd.dj ->> 'group', '조건') AS grp,
           pv.sheet_name AS sheet, pv.cell_reference AS cell,
           CASE WHEN pv.source_label LIKE '야간%' THEN 'N' WHEN pv.source_label LIKE '주간%' THEN 'D' ELSE coalesce(pru.shift, '') END AS shift_code,
           pr.work_date,
           coalesce(rpm.model_id, spm.model_id) AS model_id, coalesce(rpm.model_code, spm.model_code) AS model_code,
           runlot.bobbin_lot_code,
           coalesce(runlot.bobbin_lot_code,
                    CASE WHEN pv.source_label LIKE '야간%' THEN sf.lot_night ELSE sf.lot_day END) AS lot_code
    FROM mqi.parameter_observation po
    JOIN pd ON pd.parameter_id = po.parameter_id
    LEFT JOIN prov pv ON pv.parameter_observation_id = po.observation_id
    LEFT JOIN sheetf sf ON sf.bundle_asset_id = pv.bundle_asset_id AND sf.sheet_name = pv.sheet_name
    LEFT JOIN mqi.process_run pr ON pr.process_run_id = po.process_run_id
    LEFT JOIN mqi.production_run pru ON pru.run_id = pr.run_id
    LEFT JOIN mqi.product_model rpm ON rpm.model_id = pr.model_id
    LEFT JOIN mqi.product_model spm ON spm.model_code = sf.model_code
    LEFT JOIN runlot ON runlot.process_run_id = po.process_run_id
    WHERE po.record_state = 'ACTIVE' AND po.value_numeric IS NOT NULL
),
o2 AS (
    SELECT o.*, sp.spec_item_id, sp.target_numeric, sp.min_numeric, sp.max_numeric, sp.spec_revision, sp.verification_status AS spec_status
    FROM o
    LEFT JOIN LATERAL (
        SELECT * FROM spec
        WHERE spec.parameter_id = o.parameter_id AND spec.model_id = o.model_id
          AND (spec.effective_from IS NULL OR o.work_date IS NULL OR o.work_date >= spec.effective_from)
          AND (spec.effective_to IS NULL OR o.work_date IS NULL OR o.work_date <= spec.effective_to)
        ORDER BY spec.effective_from DESC NULLS LAST LIMIT 1
    ) sp ON true
)
SELECT o2.observation_id::text AS id,
       to_char(o2.work_date, 'YYYY-MM-DD') AS date,
       o2.sheet AS run_id,
       coalesce(o2.model_code, '') AS variant,
       'INJECTION' AS process,
       o2.grp AS condition_group,
       o2.grp || '|' || o2.parameter_name AS condition_key,
       o2.parameter_name || coalesce(' [' || o2.unit || ']', '') AS series_key,
       'OBSERVATION' AS value_role,
       o2.value_numeric AS condition_value,
       o2.raw_value_text AS raw_cell_value,
       o2.target_numeric AS spec_target,
       coalesce(o2.min_numeric, o2.target_numeric) AS spec_lower,
       coalesce(o2.max_numeric, o2.target_numeric) AS spec_upper,
       CASE o2.shift_code WHEN 'D' THEN '주간' WHEN 'N' THEN '야간' ELSE '' END AS row_shift,
       coalesce(o2.unit, '') AS unit_context,
       ''::varchar(150) AS column_context,
       o2.parameter_code,
       o2.sheet AS source_sheet,
       o2.cell AS source_cell,
       o2.validation_status AS verification_status,
       o2.process_run_id::text AS process_run_id,
       o2.shift_code,
       o2.bobbin_lot_code,
       o2.spec_revision,
       o2.spec_status,
       o2.lot_code,
       (o2.dj -> 'priority') AS priority
FROM o2;

GRANT SELECT ON public.m13_injection_condition_rows TO anon, authenticated, service_role;
