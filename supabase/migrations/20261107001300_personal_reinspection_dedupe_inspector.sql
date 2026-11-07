-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 사용자: 10/9 재검이 '이미 입력된 재검사'로 저장 실패)
-- m13_reinspection_save 의 중복 판정을 제자리에서 고친다(pg_get_functiondef + replace, 나머지 본문 그대로).
-- 전: 같은 모델·재검일·합계 수량 + 대상 LOT 이 겹치면 중복 → 같은 날 같은 LOT 을 다른 검사자가(다른 쪽에서) 재검한 기록도 막힘.
-- 후: 위 조건에 더해 검사자(가린 이름)가 같고, 출처 파일·쪽이 둘 다 있으면 그것도 같을 때만 중복.
DO $do$
DECLARE d text; old_w text;
BEGIN
  d := pg_get_functiondef('public.m13_reinspection_save(jsonb)'::regprocedure);
  old_w := $x$WHERE ir.model_id = v_model AND ir.inspection_date = v_date AND ir.inspection_type = 'REINSPECTION' AND ir.record_state = 'ACTIVE'
     AND ir.inspected_qty_ea IS NOT DISTINCT FROM v_qty;$x$;
  IF position(old_w in d) = 0 THEN RAISE EXCEPTION 'dedupe anchor missing'; END IF;
  d := replace(d, old_w, $x$WHERE ir.model_id = v_model AND ir.inspection_date = v_date AND ir.inspection_type = 'REINSPECTION' AND ir.record_state = 'ACTIVE'
     AND ir.inspected_qty_ea IS NOT DISTINCT FROM v_qty
     -- (2026-11-07) 검사자가 다르면 별개 재검. 출처 파일·쪽이 둘 다 있고 다르면 별개 재검
     AND coalesce(public.m13_try_jsonb(ir.remark)#>>'{source,inspector_masked}', public.m13_try_jsonb(ir.remark)#>>'{source,inspector_raw}', '') = coalesce(p#>>'{source,inspector_masked}', p#>>'{source,inspector_raw}', '')
     AND NOT (coalesce(public.m13_try_jsonb(ir.remark)#>>'{source,page}', '') <> '' AND coalesce(p#>>'{source,page}', '') <> ''
              AND (public.m13_try_jsonb(ir.remark)#>>'{source,page}' <> p#>>'{source,page}'
                   OR coalesce(public.m13_try_jsonb(ir.remark)#>>'{source,file}', '') <> coalesce(p#>>'{source,file}', '')));$x$);
  EXECUTE d;
END $do$;
