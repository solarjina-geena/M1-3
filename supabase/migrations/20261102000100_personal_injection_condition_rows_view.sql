-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블은 건드리지 않고 public 조회 뷰만 만든다.
-- 사출(BB) 단계 클릭 화면용 행: M1-2 대시보드가 Firestore process_conditions 문서로 그리던 조건 시계열을
-- mqi 작업조건 테이블(parameter_definition · process_setup_spec(_item) · parameter_observation)에서 같은 모양으로 돌려준다.
--   OBSERVATION 행  = 실측 1건 (parameter_observation)
--   SPEC_TARGET 행  = 실측이 있는 날짜마다 그 모델·공정의 기준 1건 (process_setup_spec_item, 적용기간 안의 것만)
-- 작업일자·주야·원본 셀은 parameter_observation.remark JSON(work_date, shift, sheet, cell)에서 읽는다.
-- process_run 연결은 하지 않는다(체크시트 호기 공란 → 설비 사용 기록 없음). 화면은 같은 날짜 BB 기록을 후보로만 표시한다.

CREATE OR REPLACE VIEW public.m13_injection_condition_rows AS
WITH obs AS (
    SELECT po.observation_id, po.parameter_id, po.value_numeric, po.raw_value_text, po.validation_status,
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
    WHERE s.record_state = 'ACTIVE' AND i.target_numeric IS NOT NULL
),
-- 실측 행의 모델: 체크시트는 모델별 기준(spec)에 묶여 있으므로 같은 항목의 기준 모델을 쓴다(현재 IV 1벌).
o AS (
    SELECT obs.*, pd.parameter_code, pd.parameter_name, pd.unit, pd.grp, pd.process_id,
           (obs.rm ->> 'work_date')::date AS work_date, obs.rm ->> 'shift' AS shift,
           obs.rm ->> 'sheet' AS sheet, obs.rm ->> 'cell' AS cell
    FROM obs JOIN pd USING (parameter_id)
),
o2 AS (
    SELECT o.*, pm.model_code, sp.target_numeric, sp.min_numeric, sp.max_numeric, sp.spec_revision
    FROM o
    LEFT JOIN spec sp ON sp.parameter_id = o.parameter_id
         AND (sp.effective_from IS NULL OR o.work_date >= sp.effective_from)
         AND (sp.effective_to IS NULL OR o.work_date <= sp.effective_to)
    LEFT JOIN mqi.product_model pm ON pm.model_id = sp.model_id
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
       ''::varchar(150) AS column_context,   -- 화면 제목은 condition_key 의 항목명으로 충분(중복 방지)
       o2.parameter_code,
       o2.sheet AS source_sheet,
       o2.cell AS source_cell,
       o2.validation_status AS verification_status
FROM o2
UNION ALL
SELECT DISTINCT ON (sp.parameter_id, d.work_date)
       md5('spec|' || sp.parameter_id || '|' || d.work_date) AS id,
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
       sp.verification_status AS verification_status
FROM spec sp
JOIN pd ON pd.parameter_id = sp.parameter_id
JOIN mqi.product_model pm ON pm.model_id = sp.model_id
JOIN (SELECT DISTINCT o.parameter_id, o.work_date, o.sheet FROM o) d
     ON d.parameter_id = sp.parameter_id
    AND (sp.effective_from IS NULL OR d.work_date >= sp.effective_from)
    AND (sp.effective_to IS NULL OR d.work_date <= sp.effective_to);

GRANT SELECT ON public.m13_injection_condition_rows TO anon, authenticated, service_role;
