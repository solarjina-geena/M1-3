-- 개인 프로젝트 전용 데이터 작업 (IMEB3 DB). 팀 DB 적용 금지. 테이블 구조는 바꾸지 않고 행만 넣고 고친다.
-- 사출조건 실측(parameter_observation)을 사출 실행(process_run)에 FK 로 연결하고, 보빈무게 SPEC 을 모델별 기준으로 넣는다.
-- 다시 돌려도 결과가 같다(ON CONFLICT / 조건부 UPDATE).
--
-- 1) 설비: 체크시트 A3 '동신 사출기 (호기 공란)'. 사출일보 설비란은 기록된 사출 실행 전부가 DS120-1(빈칸 제외) → 설비 코드를 DS120-1 로.
-- 2) 설비 사용(process_equipment_usage): 모든 사출 실행에 DS120-1 PRIMARY, CONFIRMED.
--    근거: 사용자(팀장) 확인 2026-11-02 'IV·OV·HSV 사출은 모두 같은 설비 DS120-1 사용, 시계열로 겹칠 수 없음' + 일보 설비란.
-- 3) 실측 → 실행 FK: 실측 remark 의 작업일자·주야(DAY/NIGHT)와 production_run.shift(D/N)가 같은 IV 사출 실행이 정확히 1건일 때만.
--    팀 트리거 validate_semantics 가 2)의 설비 사용 기록을 요구한다.
-- 4) 보빈무게 SPEC: IV 11.0~11.6 / OV 12.0~12.6 / HSV 12.1~12.7 g (M3-1 iMEB3_AI_AGENT_ASSIGNMENT_v0.50 backend 의 spec 표).
--    원 기준문서 대조 전이라 UNVERIFIED. 체크시트 기준(S30420B1)과 따로 둔다.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL mqi.actor_ref = 'm1-3-injection-conditions';
SET LOCAL mqi.change_reason = '사출조건 FK 연결 2026-11-02: 설비 DS120-1, 사출 실행별 설비 사용(CONFIRMED, 사용자 확인: 전 모델 DS120-1 단일 설비), 실측→사출 실행(작업일자+주야 유일 일치), 보빈무게 모델별 SPEC(M3-1 v0.50, UNVERIFIED)';

-- 1) 설비 코드
UPDATE mqi.equipment
SET equipment_code = 'DS120-1', equipment_name = '동신 사출기 DS120-1',
    remark = '{"ds": "INJ_COND_XLSX_V1", "note": "체크시트 A3 설비: 동신 사출기(호기 공란). 사용자 확인(2026-11-02): IV·OV·HSV 사출은 모두 DS120-1 한 대, 실행이 시간상 겹치지 않음."}'
WHERE equipment_id = '7bbce12d-5fb1-5397-a331-28083608dee5' AND equipment_code <> 'DS120-1';

-- 2) 사출 실행별 설비 사용
INSERT INTO mqi.process_equipment_usage (equipment_usage_id, process_run_id, equipment_id, equipment_role, linkage_status, remark)
SELECT md5('m13:equip-usage|' || pr.process_run_id)::uuid, pr.process_run_id, '7bbce12d-5fb1-5397-a331-28083608dee5'::uuid, 'PRIMARY', 'CONFIRMED',
       jsonb_build_object('ds', 'INJ_COND_XLSX_V1',
         'evidence', CASE WHEN m.machine = 'DS120-1' THEN '사출일보 설비란 DS120-1 기재 + 사용자 확인(전 모델 DS120-1 단일 설비)'
                          ELSE '사출일보 설비란 공란 · 사용자 확인(전 모델 DS120-1 단일 설비)' END,
         'confirmed_by', '사용자 확인 2026-11-02')::text
FROM mqi.process_run pr
JOIN mqi.process p ON p.process_id = pr.process_id AND p.process_code = 'IMEB3_INJECTION'
LEFT JOIN LATERAL (
    SELECT max(CASE WHEN prr.remark ~ '^\{' THEN prr.remark::jsonb ->> 'machine' END) AS machine
    FROM mqi.process_run_result prr WHERE prr.process_run_id = pr.process_run_id AND prr.record_state = 'ACTIVE'
) m ON true
WHERE pr.record_state = 'ACTIVE'
ON CONFLICT DO NOTHING;

-- 3) 실측 → 사출 실행 FK (작업일자 + 주야 + 모델 IV 가 유일하게 맞을 때만)
WITH cand AS (
    SELECT po.observation_id, pr.process_run_id,
           count(*) OVER (PARTITION BY po.observation_id) AS n
    FROM mqi.parameter_observation po
    CROSS JOIN LATERAL (SELECT po.remark::jsonb AS rm) j
    JOIN mqi.process_run pr ON pr.work_date = (j.rm ->> 'work_date')::date AND pr.record_state = 'ACTIVE'
    JOIN mqi.production_run pru ON pru.run_id = pr.run_id AND pru.shift = left(j.rm ->> 'shift', 1)
    JOIN mqi.process p ON p.process_id = pr.process_id AND p.process_code = 'IMEB3_INJECTION'
    JOIN mqi.product_model pm ON pm.model_id = pr.model_id AND pm.model_code = 'IV'
    WHERE po.record_state = 'ACTIVE' AND j.rm ->> 'ds' = 'INJ_COND_XLSX_V1'
)
UPDATE mqi.parameter_observation po
SET process_run_id = c.process_run_id,
    remark = ((po.remark::jsonb - 'same_shift_run_id')
              || jsonb_build_object('model', 'IV', 'run_link', '작업일자+주야(production_run.shift) 유일 일치'))::text
FROM cand c
WHERE c.observation_id = po.observation_id AND c.n = 1 AND po.process_run_id IS DISTINCT FROM c.process_run_id;

-- 연결 못 한 실측도 모델은 remark 에 남긴다(체크시트 제목 'I MEB3 IV').
UPDATE mqi.parameter_observation po
SET remark = ((po.remark::jsonb - 'same_shift_run_id') || jsonb_build_object('model', 'IV', 'run_link', '같은 작업일자·주야의 IV 사출 실행 기록 없음'))::text
WHERE po.record_state = 'ACTIVE' AND po.process_run_id IS NULL AND po.remark::jsonb ->> 'ds' = 'INJ_COND_XLSX_V1'
  AND NOT (po.remark::jsonb ? 'run_link');

-- 4) 보빈무게 모델별 SPEC
INSERT INTO mqi.process_setup_spec (spec_id, model_id, process_id, equipment_id, spec_revision, verification_status, remark)
SELECT md5('m13:bobbin-weight-spec|' || pm.model_code)::uuid, pm.model_id, p.process_id, NULL, 'BOBBIN-WT', 'UNVERIFIED',
       '{"ds": "BOBBIN_WT_SPEC_V1", "source": "M3-1 iMEB3_AI_AGENT_ASSIGNMENT_v0.50 backend spec 표(IV 11.0~11.6 / OV 12.0~12.6 / HSV 12.1~12.7 g)", "note": "원 기준문서 대조 전"}'
FROM mqi.product_model pm CROSS JOIN mqi.process p
WHERE p.process_code = 'IMEB3_INJECTION' AND pm.model_code IN ('IV', 'OV', 'HSV')
ON CONFLICT DO NOTHING;

INSERT INTO mqi.process_setup_spec_item (spec_item_id, spec_id, parameter_id, target_numeric, min_numeric, max_numeric, remark)
SELECT md5('m13:bobbin-weight-spec-item|' || v.model)::uuid, md5('m13:bobbin-weight-spec|' || v.model)::uuid, pd.parameter_id,
       NULL, v.lo, v.hi, '{"ds": "BOBBIN_WT_SPEC_V1"}'
FROM (VALUES ('IV', 11.0, 11.6), ('OV', 12.0, 12.6), ('HSV', 12.1, 12.7)) AS v(model, lo, hi)
JOIN mqi.parameter_definition pd ON pd.parameter_code = 'BOBBIN_WEIGHT'
ON CONFLICT DO NOTHING;
COMMIT;
