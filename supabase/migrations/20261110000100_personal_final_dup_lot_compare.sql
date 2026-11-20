-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다(팀 기준 스키마 그대로, 함수만 고침).
-- (2026-11-10 사용자 신고) 같은 검사자·같은 수량의 최종검사가 실제로는 다른 검사인데도 저장이 안 되던 문제
-- 원인: 최종검사 중복 판정이 모델·검사일·구분·검사자·차수·검사량만 봐서, 같은 검사자가 같은 날 같은 수량(예 10 BOX = 4,800 EA)을
--       서로 다른 LOT 으로 두 번 검사하면 두 번째를 '이미 저장된 일보'로 막았다(기존 기록 바꾸기를 켜면 첫 번째가 VOID 되는 위험도).
-- 고침: 위 조건에 더해 'LOT 날짜·BOX 수 묶음'도 같아야 같은 일보로 본다.
--       한쪽이라도 LOT 날짜가 하나도 없으면(못 읽음·빈칸) 예전처럼 LOT 은 비교하지 않는다(같은 쪽 이중 저장 막기 유지 — 11/8 수정과 같은 방향).
-- 저장 함수(m13_journal_save)와 미리보기 '이미 저장됨' 표시(m13_journal_exists) 둘 다 같은 규칙.

-- 이미 저장된 최종검사 1건의 'LOT 날짜|BOX' 목록(정렬, 중복 제거)
CREATE OR REPLACE FUNCTION public.m13_final_lot_key_old(p_run uuid) RETURNS text[]
LANGUAGE sql STABLE SET search_path = pg_catalog, mqi, public AS $$
  SELECT coalesce(array_agg(DISTINCT k ORDER BY k), '{}'::text[]) FROM (
    SELECT pl.lot_date::text || '|' || coalesce(il.recorded_box_count::text, '') AS k
      FROM mqi.inspection_lot il JOIN mqi.production_lot pl ON pl.lot_id = il.production_lot_id
     WHERE il.inspection_run_id = p_run AND il.record_state = 'ACTIVE' AND pl.lot_date IS NOT NULL) s
$$;

-- 지금 저장하려는 일보(payload)의 같은 목록
CREATE OR REPLACE FUNCTION public.m13_final_lot_key_new(p jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
  SELECT coalesce(array_agg(DISTINCT k ORDER BY k), '{}'::text[]) FROM (
    SELECT (nullif(r->>'lot_date','')::date)::text || '|' || coalesce((nullif(r->>'boxes','')::int)::text, '') AS k
      FROM jsonb_array_elements(coalesce(p->'lots', '[]'::jsonb)) r
     WHERE nullif(r->>'lot_date','') IS NOT NULL) s
$$;
REVOKE ALL ON FUNCTION public.m13_final_lot_key_old(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.m13_final_lot_key_new(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_final_lot_key_old(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.m13_final_lot_key_new(jsonb) TO service_role;

DO $mig$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.m13_journal_save(jsonb)'::regprocedure);
  IF position('m13_final_lot_key_old' in d) = 0 THEN
    d := replace(d,
      'AND ir.inspected_qty_ea IS NOT DISTINCT FROM coalesce(nullif(p->>''inspected_qty'','''')::int, v_qty)',
      'AND ir.inspected_qty_ea IS NOT DISTINCT FROM coalesce(nullif(p->>''inspected_qty'','''')::int, v_qty)
       AND (cardinality(public.m13_final_lot_key_new(p)) = 0 OR cardinality(public.m13_final_lot_key_old(ir.inspection_run_id)) = 0
            OR public.m13_final_lot_key_old(ir.inspection_run_id) = public.m13_final_lot_key_new(p))');
    IF position('m13_final_lot_key_old' in d) = 0 THEN RAISE EXCEPTION 'm13_journal_save: 바꿀 줄을 찾지 못함'; END IF;
    EXECUTE d;
  END IF;
  d := pg_get_functiondef('public.m13_journal_exists(jsonb)'::regprocedure);
  IF position('m13_final_lot_key_old' in d) = 0 THEN
    d := replace(d,
      'AND ir.inspected_qty_ea IS NOT DISTINCT FROM coalesce(nullif(p->>''inspected_qty'','''')::int, nullif(p->>''gross_output_qty'','''')::int)',
      'AND ir.inspected_qty_ea IS NOT DISTINCT FROM coalesce(nullif(p->>''inspected_qty'','''')::int, nullif(p->>''gross_output_qty'','''')::int)
      AND (cardinality(public.m13_final_lot_key_new(p)) = 0 OR cardinality(public.m13_final_lot_key_old(ir.inspection_run_id)) = 0
           OR public.m13_final_lot_key_old(ir.inspection_run_id) = public.m13_final_lot_key_new(p))');
    IF position('m13_final_lot_key_old' in d) = 0 THEN RAISE EXCEPTION 'm13_journal_exists: 바꿀 줄을 찾지 못함'; END IF;
    EXECUTE d;
  END IF;
END $mig$;
