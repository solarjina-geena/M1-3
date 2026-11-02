-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블은 건드리지 않고 public 조회 뷰만 고치거나 만든다.
-- 20261102000100 의 m13_injection_condition_rows 를 FK 연결 기준으로 다시 정의한다(열은 끝에만 추가).
--   - 실측 모델 = 연결된 사출 실행(process_run, FK)의 모델, 없으면 remark.model
--   - SPEC 은 같은 모델의 기준만 붙인다(보빈무게 BOBBIN-WT 모델별 SPEC 포함)
--   - 보빈 LOT(process_run_lot OUTPUT) · 주야 코드 · 사출 실행 id 를 함께 돌려준다
-- 새 뷰 m13_injection_runs: 사출 설비 DS120-1 의 실행 순서(IV·OV·HSV 가 한 설비에서 겹치지 않고 이어짐). 그래프 가로축·LOT 기준점용.
-- 데이터 작업(설비 사용·FK·보빈무게 SPEC 행)은 tools/injection_conditions_link_fk.sql.

CREATE OR REPLACE VIEW public.m13_injection_condition_rows AS
WITH obs AS (
    SELECT po.observation_id, po.parameter_id, po.value_numeric, po.raw_value_text, po.validation_status, po.process_run_id,
           CASE WHEN po.remark ~ '^\{' THEN po.remark::jsonb ELSE '{}'::jsonb END AS rm
    FROM mqi.parameter_observation po
    WHERE po.record_state = 'ACTIVE' AND po.value_numeric IS NOT NULL
),
pd AS (
    SELECT d.parameter_id, d.parameter_code, d.parameter_name, d.unit, d.process_id,
           coalesce(CASE WHEN d.description ~ '^\{' THEN d.description::jsonb ->> 'group' END, '조건') AS grp
    FROM mqi.parameter_definition d
    WHERE d.record_state = 'ACTIVE'
),
spec AS (
    SELECT s.model_id, s.process_id, s.spec_revision, s.effective_from, s.effective_to, s.verification_status,
           i.parameter_id, i.target_numeric, i.min_numeric, i.max_numeric,
           CASE WHEN i.remark ~ '^\{' THEN i.remark::jsonb ->> 'cell' END AS cell
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
    SELECT obs.*, pd.parameter_code, pd.parameter_name, pd.unit, pd.grp, pd.process_id,
           (obs.rm ->> 'work_date')::date AS work_date, obs.rm ->> 'shift' AS shift,
           obs.rm ->> 'sheet' AS sheet, obs.rm ->> 'cell' AS cell,
           coalesce(rpm.model_id, mpm.model_id) AS model_id, coalesce(rpm.model_code, mpm.model_code) AS model_code,
           pru.shift AS run_shift, runlot.bobbin_lot_code
    FROM obs
    JOIN pd USING (parameter_id)
    LEFT JOIN mqi.process_run pr ON pr.process_run_id = obs.process_run_id
    LEFT JOIN mqi.production_run pru ON pru.run_id = pr.run_id
    LEFT JOIN mqi.product_model rpm ON rpm.model_id = pr.model_id
    LEFT JOIN mqi.product_model mpm ON mpm.model_code = obs.rm ->> 'model'
    LEFT JOIN runlot ON runlot.process_run_id = obs.process_run_id
),
o2 AS (
    SELECT o.*, sp.target_numeric, sp.min_numeric, sp.max_numeric, sp.spec_revision, sp.verification_status AS spec_status
    FROM o
    LEFT JOIN LATERAL (
        SELECT * FROM spec
        WHERE spec.parameter_id = o.parameter_id AND spec.model_id = o.model_id
          AND (spec.effective_from IS NULL OR o.work_date >= spec.effective_from)
          AND (spec.effective_to IS NULL OR o.work_date <= spec.effective_to)
        ORDER BY spec.effective_from DESC NULLS LAST LIMIT 1
    ) sp ON true
)
SELECT o2.observation_id::text AS id,
       to_char(o2.work_date, 'YYYY-MM-DD') AS date,
       o2.sheet AS run_id,
       coalesce(o2.model_code, 'IV') AS variant,
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
       CASE o2.shift WHEN 'DAY' THEN '주간' WHEN 'NIGHT' THEN '야간' ELSE '' END AS row_shift,
       coalesce(o2.unit, '') AS unit_context,
       ''::varchar(150) AS column_context,
       o2.parameter_code,
       o2.sheet AS source_sheet,
       o2.cell AS source_cell,
       o2.validation_status AS verification_status,
       o2.process_run_id::text AS process_run_id,
       CASE o2.shift WHEN 'DAY' THEN 'D' WHEN 'NIGHT' THEN 'N' ELSE coalesce(o2.run_shift, '') END AS shift_code,
       o2.bobbin_lot_code,
       o2.spec_revision,
       o2.spec_status
FROM o2
UNION ALL
SELECT DISTINCT ON (sp.parameter_id, d.model_id, d.work_date)
       md5('spec|' || sp.parameter_id || '|' || d.model_id || '|' || d.work_date) AS id,
       to_char(d.work_date, 'YYYY-MM-DD') AS date,
       d.sheet AS run_id,
       pm.model_code AS variant,
       'INJECTION' AS process,
       pd.grp AS condition_group,
       pd.grp || '|' || pd.parameter_name AS condition_key,
       pd.parameter_name || coalesce(' [' || pd.unit || ']', '') AS series_key,
       'SPEC_TARGET' AS value_role,
       sp.target_numeric AS condition_value,
       NULL AS raw_cell_value,
       sp.target_numeric AS spec_target,
       coalesce(sp.min_numeric, sp.target_numeric) AS spec_lower,
       coalesce(sp.max_numeric, sp.target_numeric) AS spec_upper,
       '' AS row_shift,
       coalesce(pd.unit, '') AS unit_context,
       ''::varchar(150) AS column_context,
       pd.parameter_code,
       d.sheet AS source_sheet,
       sp.cell AS source_cell,
       sp.verification_status AS verification_status,
       NULL::text AS process_run_id,
       '' AS shift_code,
       NULL::text AS bobbin_lot_code,
       sp.spec_revision,
       sp.verification_status AS spec_status
FROM spec sp
JOIN pd ON pd.parameter_id = sp.parameter_id
JOIN (SELECT DISTINCT o.parameter_id, o.model_id, o.work_date, o.sheet FROM o) d
     ON d.parameter_id = sp.parameter_id AND d.model_id = sp.model_id
    AND (sp.effective_from IS NULL OR d.work_date >= sp.effective_from)
    AND (sp.effective_to IS NULL OR d.work_date <= sp.effective_to)
JOIN mqi.product_model pm ON pm.model_id = sp.model_id
WHERE sp.target_numeric IS NOT NULL;

GRANT SELECT ON public.m13_injection_condition_rows TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.m13_injection_runs AS
SELECT pr.process_run_id::text AS process_run_id,
       to_char(pr.work_date, 'YYYY-MM-DD') AS date,
       pru.shift AS shift_code,
       pr.sequence_no,
       pm.model_code AS variant,
       e.equipment_code,
       u.linkage_status AS equipment_link_status,
       (SELECT string_agg(DISTINCT l.lot_code_raw, '/')
          FROM mqi.process_run_lot prl JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
         WHERE prl.process_run_id = pr.process_run_id AND prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT') AS bobbin_lot_code,
       (SELECT sum(prr.gross_output_qty) FROM mqi.process_run_result prr
         WHERE prr.process_run_id = pr.process_run_id AND prr.record_state = 'ACTIVE')::bigint AS quantity,
       EXISTS (SELECT 1 FROM mqi.parameter_observation po
                WHERE po.process_run_id = pr.process_run_id AND po.record_state = 'ACTIVE') AS has_conditions
FROM mqi.process_run pr
JOIN mqi.process p ON p.process_id = pr.process_id AND p.process_code = 'IMEB3_INJECTION'
JOIN mqi.production_run pru ON pru.run_id = pr.run_id
JOIN mqi.product_model pm ON pm.model_id = pr.model_id
LEFT JOIN mqi.process_equipment_usage u ON u.process_run_id = pr.process_run_id AND u.record_state = 'ACTIVE'
LEFT JOIN mqi.equipment e ON e.equipment_id = u.equipment_id
WHERE pr.record_state = 'ACTIVE';

GRANT SELECT ON public.m13_injection_runs TO anon, authenticated, service_role;
