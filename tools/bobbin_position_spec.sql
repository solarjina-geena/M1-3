-- 개인 프로젝트 전용 데이터 작업 (IMEB3 DB). 팀 DB 적용 금지. 테이블 구조는 바꾸지 않는다. 다시 돌려도 같다.
-- 사출 보빈 초품 위치도 기준: 엑셀 기준 줄 X 1.98~2.22 / Y 11.88~12.12 / 위치도 0.35 (IV·OV·HSV 동일), 관리기준 0.40 = CA 와 동일(팀장 확인 2026-11-06).
BEGIN ISOLATION LEVEL SERIALIZABLE;
SET LOCAL mqi.actor_ref = 'm1-3-bobbin-position-spec';
SET LOCAL mqi.change_reason = '[사출] 보빈 초품 위치도 기준 등록: X 2.1(1.98~2.22) / Y 12.0(11.88~12.12), SPEC ⌀0.35 — 엑셀 기준 줄, 관리기준 0.40 은 CA 와 같게';

INSERT INTO mqi.parameter_definition (parameter_id, process_id, parameter_code, parameter_name, value_kind, unit, position_scope, description)
SELECT md5('m13:bobbin-position:param|' || v.code)::uuid, p.process_id, v.code, v.name, 'NUMBER', 'mm', 'BOTH', v.descr
FROM mqi.process p CROSS JOIN (VALUES
  ('BB_PIN_X', '보빈 핀 X 좌표', '{"ds": "BOBBIN_POSITION_A1_3", "group": "보빈 초품 위치도", "point": "L/R"}'),
  ('BB_PIN_Y', '보빈 핀 Y 좌표', '{"ds": "BOBBIN_POSITION_A1_3", "group": "보빈 초품 위치도", "point": "L/R"}'),
  ('BB_PIN_POSITION', '보빈 핀 위치도', '{"ds": "BOBBIN_POSITION_A1_3", "group": "보빈 초품 위치도", "judge": {"spec": 0.35, "control": 0.40, "display_range": 0.35, "rule": "X단독 2|ΔX| · Y단독 2|ΔY| · 종합 2√(ΔX²+ΔY²) 중 가장 나쁜 값", "note": "관리기준 0.40 = CA 와 동일(팀장 확인 2026-11-06)"}}')
) AS v(code, name, descr)
WHERE p.process_code = 'IMEB3_INJECTION'
ON CONFLICT DO NOTHING;

INSERT INTO mqi.process_setup_spec (spec_id, model_id, process_id, spec_revision, verification_status, remark)
SELECT md5('m13:bobbin-position:spec|' || pm.model_code)::uuid, pm.model_id, p.process_id, 'BOBBIN-POSITION-A1-3', 'CONFIRMED',
       '{"ds": "BOBBIN_POSITION_A1_3", "source": "IMEB3 Bobbin 초품 위치도 엑셀 기준 줄(X 1.98~2.22, Y 11.88~12.12, 위치도 0.35)"}'
FROM mqi.product_model pm CROSS JOIN mqi.process p
WHERE p.process_code = 'IMEB3_INJECTION' AND pm.model_code IN ('IV', 'OV', 'HSV')
ON CONFLICT DO NOTHING;

INSERT INTO mqi.process_setup_spec_item (spec_item_id, spec_id, parameter_id, target_numeric, min_numeric, max_numeric, remark)
SELECT md5('m13:bobbin-position:item|' || pm.model_code || '|' || v.code)::uuid, md5('m13:bobbin-position:spec|' || pm.model_code)::uuid,
       md5('m13:bobbin-position:param|' || v.code)::uuid, v.t, v.lo, v.hi, '{"ds": "BOBBIN_POSITION_A1_3"}'
FROM mqi.product_model pm CROSS JOIN (VALUES
  ('BB_PIN_X', 2.1, 1.98, 2.22),
  ('BB_PIN_Y', 12.0, 11.88, 12.12),
  ('BB_PIN_POSITION', NULL::numeric, NULL::numeric, 0.35)
) AS v(code, t, lo, hi)
WHERE pm.model_code IN ('IV', 'OV', 'HSV')
ON CONFLICT DO NOTHING;

COMMIT;
