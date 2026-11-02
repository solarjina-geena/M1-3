-- 개인 프로젝트 전용 데이터 작업 (IMEB3 DB). 팀 DB 적용 금지. 테이블 구조는 바꾸지 않는다.
-- CA 초품 핀 위치도 기준(팀장 결정 2026-11-02, A1-3 PosiDash 규칙): IV·OV·HSV 동일
--   기준 X 2.1 mm / Y 12.0 mm, SPEC 위치도 ⌀0.35, 관리기준 ⌀0.40, 그래프 표시범위 고정 ±0.35 mm(위치도 0.7)
-- 항목 정의(PIN_X·PIN_Y·PIN_POSITION, 공정 = 압입 CA) + 모델별 기준(spec_revision POSITION-A1-3, CONFIRMED).
-- 관리기준·표시범위는 parameter_definition.description JSON judge 에 둔다(뷰 m13_position_checks 가 읽음). 다시 돌려도 같다.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL mqi.actor_ref = 'm1-3-position-spec';
SET LOCAL mqi.change_reason = '[CA] 초품 핀 위치도 기준 등록: X 2.1 / Y 12.0, SPEC ⌀0.35, 관리기준 ⌀0.40 (팀장 결정 2026-11-02, A1-3 규칙)';

INSERT INTO mqi.parameter_definition (parameter_id, process_id, parameter_code, parameter_name, value_kind, unit, position_scope, description)
SELECT md5('m13:position:param|' || v.code)::uuid, p.process_id, v.code, v.name, 'NUMBER', 'mm', 'BOTH', v.descr
FROM mqi.process p CROSS JOIN (VALUES
  ('PIN_X', '핀 X 좌표', '{"ds": "POSITION_A1_3", "group": "초품 위치도", "point": "L/R"}'),
  ('PIN_Y', '핀 Y 좌표', '{"ds": "POSITION_A1_3", "group": "초품 위치도", "point": "L/R"}'),
  ('PIN_POSITION', '핀 위치도', '{"ds": "POSITION_A1_3", "group": "초품 위치도", "judge": {"spec": 0.35, "control": 0.40, "display_range": 0.35, "rule": "X단독 2|ΔX| · Y단독 2|ΔY| · 종합 2√(ΔX²+ΔY²) 중 가장 나쁜 값"}}')
) AS v(code, name, descr)
WHERE p.process_code = 'IMEB3_CA_PRESS'
ON CONFLICT DO NOTHING;

INSERT INTO mqi.process_setup_spec (spec_id, model_id, process_id, spec_revision, verification_status, remark)
SELECT md5('m13:position:spec|' || pm.model_code)::uuid, pm.model_id, p.process_id, 'POSITION-A1-3', 'CONFIRMED',
       '{"ds": "POSITION_A1_3", "source": "A1-3 PosiDash 판정 규칙", "confirmed_by": "팀장 결정 2026-11-02"}'
FROM mqi.product_model pm CROSS JOIN mqi.process p
WHERE p.process_code = 'IMEB3_CA_PRESS' AND pm.model_code IN ('IV', 'OV', 'HSV')
ON CONFLICT DO NOTHING;

INSERT INTO mqi.process_setup_spec_item (spec_item_id, spec_id, parameter_id, target_numeric, min_numeric, max_numeric, remark)
SELECT md5('m13:position:item|' || pm.model_code || '|' || v.code)::uuid, md5('m13:position:spec|' || pm.model_code)::uuid,
       md5('m13:position:param|' || v.code)::uuid, v.t, v.lo, v.hi, '{"ds": "POSITION_A1_3"}'
FROM mqi.product_model pm CROSS JOIN (VALUES
  ('PIN_X', 2.1, NULL::numeric, NULL::numeric),
  ('PIN_Y', 12.0, NULL, NULL),
  ('PIN_POSITION', NULL, NULL, 0.35)
) AS v(code, t, lo, hi)
WHERE pm.model_code IN ('IV', 'OV', 'HSV')
ON CONFLICT DO NOTHING;
COMMIT;
