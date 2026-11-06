-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07, 사용자 요청: 재검도 미확인 CA LOT 을 만들어 바로 FK)
-- m13_reinspection_save 를 제자리에서 고친다(pg_get_functiondef + replace, 나머지 본문은 20261103000300 그대로):
--  1) CA LOT 찾기를 m13_find_lot(모델, IMEB3_CA_PRESS, 코드)로 — CA 실행 OUTPUT LOT 뿐 아니라 'CA 작업일보 미확인' LOT 도 인정(본검사 저장과 같은 규칙)
--  2) 대상 LOT 줄에 CA LOT 이 비었는데 lot_date(마킹코드 조견표로 정한 CA 제품 LOT 날짜)가 있으면
--     YYMMDD+D1 CA LOT 을 찾고, 없으면 production_lot(NEEDS_REVIEW, remark process_code=IMEB3_CA_PRESS '재검 LOT 마킹코드로 참조된 CA LOT(CA 작업일보 미확인)')를 만들어 FK.
--     본검사 연결은 그 LOT 을 재검일 이전에 검사한 최종검사가 있으면 '전부(ALL)', 없으면 'NONE'. 나중에 그 날 CA 일보를 넣으면 같은 LOT 코드로 이어진다.
--  lot_date 도 없으면(마킹코드를 못 읽음) 지금처럼 미연결(UNRESOLVED) — 추정하지 않는다.
DO $do$
DECLARE d text; old_sel text; n int;
BEGIN
  d := pg_get_functiondef('public.m13_reinspection_save(jsonb)'::regprocedure);
  old_sel := $x$SELECT pl.lot_id INTO v_lot FROM mqi.production_lot pl
      JOIN mqi.process_run_lot prl ON prl.production_lot_id = pl.lot_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
      JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
      JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code = 'IMEB3_CA_PRESS'
     WHERE pl.lot_code_raw = upper(btrim(l->>'lot_code')) AND pl.model_id = v_model AND pl.record_state = 'ACTIVE' LIMIT 1;$x$;
  n := (length(d) - length(replace(d, old_sel, ''))) / length(old_sel);
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 CA LOT lookups, found %', n; END IF;
  d := replace(d, old_sel, $x$v_lot := public.m13_find_lot(v_model, 'IMEB3_CA_PRESS', upper(btrim(l->>'lot_code')));$x$);
  IF position('DECLARE' in d) = 0 THEN RAISE EXCEPTION 'no DECLARE'; END IF;
  d := regexp_replace(d, 'DECLARE', $x$DECLARE
  v_fix jsonb := '[]'::jsonb; v_e jsonb; v_pl uuid; v_code text;$x$);
  IF position($x$IF jsonb_array_length(v_lots) > 30 THEN RAISE EXCEPTION '대상 LOT 은 30개까지'; END IF;$x$ in d) = 0 THEN RAISE EXCEPTION 'anchor missing'; END IF;
  d := replace(d, $x$IF jsonb_array_length(v_lots) > 30 THEN RAISE EXCEPTION '대상 LOT 은 30개까지'; END IF;$x$,
$x$IF jsonb_array_length(v_lots) > 30 THEN RAISE EXCEPTION '대상 LOT 은 30개까지'; END IF;

  -- CA LOT 이 비었는데 CA 제품 LOT 날짜(마킹코드 조견표)를 알면: 같은 코드 CA LOT 을 찾거나 'CA 작업일보 미확인' LOT 을 만들어 FK (2026-11-07)
  FOR v_e IN SELECT * FROM jsonb_array_elements(v_lots) LOOP
    IF coalesce(btrim(v_e->>'lot_code'), '') = '' AND nullif(v_e->>'lot_date', '') IS NOT NULL THEN
      v_code := to_char((v_e->>'lot_date')::date, 'YYMMDD') || 'D1';
      v_pl := public.m13_find_lot(v_model, 'IMEB3_CA_PRESS', v_code);
      IF v_pl IS NULL THEN
        v_pl := gen_random_uuid();
        INSERT INTO mqi.production_lot (lot_id, model_id, lot_date, lot_code_raw, verification_status, remark)
        VALUES (v_pl, v_model, (v_e->>'lot_date')::date, v_code, 'NEEDS_REVIEW',
                jsonb_build_object('process_code', 'IMEB3_CA_PRESS', 'note', '재검 LOT 마킹코드로 참조된 CA LOT(CA 작업일보 미확인)',
                                   'marking_code', upper(btrim(coalesce(v_e->>'lot_code_raw', ''))), 'by', 'm13_reinspection_save')::text);
      END IF;
      v_e := v_e || jsonb_build_object('lot_code', v_code, 'placeholder', true,
               'prior_run_id', CASE WHEN EXISTS (SELECT 1 FROM mqi.inspection_run ir JOIN mqi.inspection_lot il ON il.inspection_run_id = ir.inspection_run_id AND il.record_state = 'ACTIVE'
                                                  WHERE il.production_lot_id = v_pl AND ir.record_state = 'ACTIVE' AND ir.inspection_type = 'FINAL' AND ir.inspection_date <= v_date)
                                    THEN 'ALL' ELSE 'NONE' END);
    END IF;
    v_fix := v_fix || jsonb_build_array(v_e);
  END LOOP;
  v_lots := v_fix;$x$);
  EXECUTE d;
END $do$;
