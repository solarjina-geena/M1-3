-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블 구조는 바꾸지 않는다. public 뷰·RPC 만 만든다.
-- 최종검사 일보 비고란의 재검사(이미 검사한 LOT 에서 불량을 추가로 가려내는 작업) 입력 — 관리 화면 '최종검사 재검사' 탭.
-- 팀 표 사용(새 테이블·컬럼 없음):
--   inspection_run       inspection_type=REINSPECTION, inspection_stage=FINAL, inspection_scope=TARGETED,
--                        inspection_method=VISUAL_MANUAL(재검)/MICROSCOPE(현미경검사), inspected_qty_ea=재검 수량
--   inspection_lot       재검 대상 LOT → production_lot_id = 같은 모델의 CA 제품 LOT (FK, 사람이 고른 것만 → CONFIRMED)
--   inspection_run_link  본검사(FINAL) → 재검(REINSPECTION), relation_type=TARGETED_REINSPECTION (FK 두 개 + 모델 복합 FK)
--   quality_finding      재검에서 가려낸 불량, finding_class=FINAL_DEFECT, defect_type_id FK(최종검사 FIN 유형), inspection_lot_id FK
-- 삭제는 VOID(재검·대상 LOT·연결·불량을 한 트랜잭션으로). 사유는 '[최종검사] 재검사 …' 로 CRUD 이력에 남는다.

-- 1) 재검 대상 후보: 최종검사(FINAL)를 받은 CA 제품 LOT 과 그 본검사 ------------------------------------
CREATE OR REPLACE VIEW public.m13_reinspection_targets AS
SELECT pm.model_code, l.lot_code_raw AS ca_lot_code, to_char(l.lot_date, 'YYYY-MM-DD') AS lot_date,
       ir.inspection_run_id::text AS inspection_run_id, to_char(ir.inspection_date, 'YYYY-MM-DD') AS inspection_date,
       ir.inspection_round_no, ir.inspected_qty_ea AS run_qty_ea, il.lot_code_raw AS inspection_lot_raw,
       il.recorded_box_count, il.lot_linkage_status,
       public.m13_try_jsonb(il.remark) ->> 'marking_code' AS marking_code
FROM mqi.inspection_lot il
JOIN mqi.inspection_run ir ON ir.inspection_run_id = il.inspection_run_id AND ir.record_state = 'ACTIVE' AND ir.inspection_type = 'FINAL'
JOIN mqi.production_lot l ON l.lot_id = il.production_lot_id AND l.record_state = 'ACTIVE'
JOIN mqi.product_model pm ON pm.model_id = il.model_id
WHERE il.record_state = 'ACTIVE'
  AND EXISTS (SELECT 1 FROM mqi.process_run_lot prl JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
              JOIN mqi.process p ON p.process_id = pr.process_id AND p.process_code = 'IMEB3_CA_PRESS'
              WHERE prl.production_lot_id = l.lot_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE');

GRANT SELECT ON public.m13_reinspection_targets TO anon, authenticated, service_role;

-- 2) 재검 기록 목록 --------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.m13_reinspections AS
SELECT ir.inspection_run_id::text AS run_id, to_char(ir.inspection_date, 'YYYY-MM-DD') AS inspection_date, pm.model_code,
       ir.inspection_method, ir.inspected_qty_ea, ir.inspection_round_no, ir.validation_status,
       coalesce(public.m13_try_jsonb(ir.remark) ->> 'raw_note', ir.raw_inspection_label) AS raw_note,
       public.m13_try_jsonb(ir.remark) -> 'source' AS source, public.m13_try_jsonb(ir.remark) ->> 'ds' AS dataset,
       (SELECT jsonb_agg(jsonb_build_object('inspection_lot_id', il.inspection_lot_id, 'lot_code_raw', il.lot_code_raw, 'ca_lot_code', l.lot_code_raw,
                                            'status', il.lot_linkage_status) ORDER BY il.recorded_at)
          FROM mqi.inspection_lot il LEFT JOIN mqi.production_lot l ON l.lot_id = il.production_lot_id
         WHERE il.inspection_run_id = ir.inspection_run_id AND il.record_state = 'ACTIVE') AS lots,
       (SELECT jsonb_agg(jsonb_build_object('link_id', k.inspection_run_link_id, 'prior_run_id', k.prior_inspection_run_id,
                                            'prior_date', to_char(pr.inspection_date, 'YYYY-MM-DD'), 'prior_qty_ea', pr.inspected_qty_ea,
                                            'relation', k.relation_type, 'status', k.linkage_status))
          FROM mqi.inspection_run_link k JOIN mqi.inspection_run pr ON pr.inspection_run_id = k.prior_inspection_run_id
         WHERE k.followup_inspection_run_id = ir.inspection_run_id AND k.record_state = 'ACTIVE') AS prior_runs,
       (SELECT jsonb_agg(jsonb_build_object('defect', coalesce(qf.raw_defect_name, dt.defect_name), 'defect_code', dt.defect_code, 'qty', qf.quantity) ORDER BY qf.recorded_at)
          FROM mqi.quality_finding qf LEFT JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
         WHERE qf.inspection_run_id = ir.inspection_run_id AND qf.record_state = 'ACTIVE') AS findings,
       (SELECT sum(qf.quantity) FROM mqi.quality_finding qf WHERE qf.inspection_run_id = ir.inspection_run_id AND qf.record_state = 'ACTIVE') AS defect_qty,
       ir.recorded_at
FROM mqi.inspection_run ir
JOIN mqi.product_model pm ON pm.model_id = ir.model_id
WHERE ir.record_state = 'ACTIVE' AND ir.inspection_type = 'REINSPECTION';

GRANT SELECT ON public.m13_reinspections TO anon, authenticated, service_role;

-- 3) 재검 저장 RPC ----------------------------------------------------------------------------------
-- 재검 1건이 여러 LOT 을 대상으로 할 수 있다(예: 9/23 IV L/C 찍힘 재검 = 마킹 10개, 합계 38,400EA, 불량 173EA).
-- p = {model, inspection_date, method(VISUAL_MANUAL|MICROSCOPE), qty_ea(재검 합계), raw_note,
--      lots:[{lot_code(CA LOT), lot_code_raw(원문 마킹), box_count, qty_ea, prior_run_id | 'ALL' | 'NONE'}],
--      'ALL' = 그 LOT 을 검사한 같은 모델 최종검사 중 재검일 이전 것 전부(기록된 사실만, 추정 아님)
--      lot_code 가 비고 lot_code_raw 만 있으면 = 원문 마킹만 남긴 미연결 줄(UNRESOLVED, 그날 CA LOT 이 DB 에 없거나 판독 불확실). '확인 필요' 탭에서 나중에 연결.
-- 중복 = 같은 모델·재검일·합계 수량이고 대상 LOT(또는 원문 마킹)이 겹치는 재검. 같은 날 다른 검사자의 별개 재검(수량이 다름)은 막지 않는다.
--      findings:[{defect_code?, name_raw, qty}], source:{image_sha256, ai_read}, replace, actor, reason}
-- 불량은 대상 LOT 이 1개면 그 LOT(inspection_lot_id)에, 여러 개면 재검 건(inspection_run)에만 붙인다(원문이 LOT 별로 나누지 않음 — 나누지 않는다).
CREATE OR REPLACE FUNCTION public.m13_reinspection_save(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_model uuid; v_lot uuid; v_date date; v_prior uuid; v_run uuid; v_il uuid; v_one_il uuid; v_dt uuid; v_n int := 0; v_nl int := 0; v_links int := 0;
  v_method text := coalesce(nullif(p->>'method', ''), 'VISUAL_MANUAL');
  v_qty int := nullif(p->>'qty_ea', '')::int;
  v_old uuid[]; v_lots jsonb := coalesce(p->'lots', '[]'::jsonb); v_seen uuid[] := '{}'; v_priors uuid[] := '{}';
  l jsonb; f jsonb; o uuid; v_raws text[] := '{}';
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_reinspection_save: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[최종검사] 재검사 입력(M1-3 관리 화면)'), true);

  SELECT model_id INTO v_model FROM mqi.product_model WHERE model_code = p->>'model' AND record_state = 'ACTIVE';
  IF v_model IS NULL THEN RAISE EXCEPTION '모델을 고르세요(IV/OV/HSV): %', p->>'model'; END IF;
  v_date := nullif(p->>'inspection_date', '')::date;
  IF v_date IS NULL THEN RAISE EXCEPTION '재검일이 필요합니다'; END IF;
  IF v_method NOT IN ('VISUAL_MANUAL', 'MICROSCOPE') THEN RAISE EXCEPTION '검사 방법은 육안 재검(VISUAL_MANUAL) 또는 현미경(MICROSCOPE)'; END IF;
  IF v_qty IS NOT NULL AND v_qty < 0 THEN RAISE EXCEPTION '재검 수량은 0 이상'; END IF;
  IF jsonb_typeof(v_lots) <> 'array' OR jsonb_array_length(v_lots) = 0 THEN RAISE EXCEPTION '대상 LOT 을 1개 이상 고르세요'; END IF;
  IF jsonb_array_length(v_lots) > 30 THEN RAISE EXCEPTION '대상 LOT 은 30개까지'; END IF;

  -- 대상 LOT 검증(같은 모델 CA 제품 LOT, 본검사는 그 LOT 을 검사한 같은 모델 최종검사) — 쓰기 전에 전부 확인
  FOR l IN SELECT * FROM jsonb_array_elements(v_lots) LOOP
    v_lot := NULL;
    IF coalesce(btrim(l->>'lot_code'), '') = '' THEN
      IF coalesce(btrim(l->>'lot_code_raw'), '') = '' THEN RAISE EXCEPTION '대상 LOT 줄에 LOT 도 원문 마킹도 없습니다'; END IF;
      IF upper(btrim(l->>'lot_code_raw')) = ANY (v_raws) THEN RAISE EXCEPTION '같은 원문 마킹이 두 줄입니다: %', l->>'lot_code_raw'; END IF;
      v_raws := v_raws || upper(btrim(l->>'lot_code_raw'));
      CONTINUE;
    END IF;
    SELECT pl.lot_id INTO v_lot FROM mqi.production_lot pl
      JOIN mqi.process_run_lot prl ON prl.production_lot_id = pl.lot_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
      JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
      JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code = 'IMEB3_CA_PRESS'
     WHERE pl.lot_code_raw = upper(btrim(l->>'lot_code')) AND pl.model_id = v_model AND pl.record_state = 'ACTIVE' LIMIT 1;
    IF v_lot IS NULL THEN RAISE EXCEPTION '같은 모델(%)의 CA 제품 LOT 이 아닙니다: %', p->>'model', coalesce(l->>'lot_code', '(빈칸)'); END IF;
    IF v_lot = ANY (v_seen) THEN RAISE EXCEPTION '같은 LOT 이 두 줄입니다: %', l->>'lot_code'; END IF;
    v_seen := v_seen || v_lot;
    IF coalesce(l->>'prior_run_id', '') = '' THEN RAISE EXCEPTION 'LOT % 의 본검사를 고르거나 "본검사 기록 없음"을 고르세요', l->>'lot_code'; END IF;
    IF l->>'prior_run_id' = 'ALL' THEN
      IF NOT EXISTS (SELECT 1 FROM mqi.inspection_run ir JOIN mqi.inspection_lot il ON il.inspection_run_id = ir.inspection_run_id AND il.production_lot_id = v_lot AND il.record_state = 'ACTIVE'
                     WHERE ir.model_id = v_model AND ir.inspection_type = 'FINAL' AND ir.record_state = 'ACTIVE' AND ir.inspection_date <= v_date) THEN
        RAISE EXCEPTION 'LOT % : 재검일 이전에 이 LOT 을 검사한 최종검사가 없습니다', l->>'lot_code';
      END IF;
    ELSIF l->>'prior_run_id' <> 'NONE' THEN
      v_prior := NULL;
      SELECT ir.inspection_run_id INTO v_prior FROM mqi.inspection_run ir
        JOIN mqi.inspection_lot il ON il.inspection_run_id = ir.inspection_run_id AND il.production_lot_id = v_lot AND il.record_state = 'ACTIVE'
       WHERE ir.inspection_run_id = (l->>'prior_run_id')::uuid AND ir.model_id = v_model AND ir.inspection_type = 'FINAL' AND ir.record_state = 'ACTIVE' LIMIT 1;
      IF v_prior IS NULL THEN RAISE EXCEPTION 'LOT % : 고른 본검사가 이 LOT 을 검사한 같은 모델의 최종검사가 아닙니다', l->>'lot_code'; END IF;
      IF v_date < (SELECT inspection_date FROM mqi.inspection_run WHERE inspection_run_id = v_prior) THEN
        RAISE EXCEPTION 'LOT % : 재검일이 본검사일보다 앞섭니다', l->>'lot_code';
      END IF;
    END IF;
  END LOOP;

  -- 중복: 같은 모델·재검일에 이 LOT 중 하나라도 들어간 재검이 있으면 replace=true 일 때만 그 재검들을 VOID
  SELECT array_agg(DISTINCT ir.inspection_run_id) INTO v_old FROM mqi.inspection_run ir
    JOIN mqi.inspection_lot il ON il.inspection_run_id = ir.inspection_run_id AND il.record_state = 'ACTIVE'
                              AND (il.production_lot_id = ANY (v_seen) OR (il.production_lot_id IS NULL AND upper(il.lot_code_raw) = ANY (v_raws)))
   WHERE ir.model_id = v_model AND ir.inspection_date = v_date AND ir.inspection_type = 'REINSPECTION' AND ir.record_state = 'ACTIVE'
     AND ir.inspected_qty_ea IS NOT DISTINCT FROM v_qty;
  IF v_old IS NOT NULL THEN
    IF coalesce((p->>'replace')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION '이미 입력된 재검사가 있습니다(%, %, 같은 합계 수량·같은 LOT %건). 바꾸려면 "기존 기록 바꾸기"를 켜거나 아래 목록에서 삭제하세요', p->>'model', v_date, cardinality(v_old);
    END IF;
    FOREACH o IN ARRAY v_old LOOP PERFORM public.m13_reinspection_void_rows(o); END LOOP;
  END IF;

  INSERT INTO mqi.inspection_run (model_id, inspection_date, inspection_type, inspection_stage, inspection_round_no, inspection_method,
                                  inspection_scope, inspected_qty_ea, raw_inspection_label, validation_status, remark)
  VALUES (v_model, v_date, 'REINSPECTION', 'FINAL',
          (SELECT count(*) + 1 FROM mqi.inspection_run WHERE model_id = v_model AND inspection_date = v_date AND inspection_type = 'REINSPECTION' AND record_state = 'ACTIVE'),
          v_method, 'TARGETED', v_qty, left(coalesce(nullif(p->>'raw_note', ''), '비고 재검'), 150), 'VERIFIED',
          jsonb_build_object('raw_note', p->>'raw_note', 'entered_via', 'manage.html 최종검사 재검사',
                             'source', coalesce(p->'source', '{}'::jsonb), 'replaced', to_jsonb(v_old))::text)
  RETURNING inspection_run_id INTO v_run;

  FOR l IN SELECT * FROM jsonb_array_elements(v_lots) LOOP
    IF coalesce(btrim(l->>'lot_code'), '') = '' THEN
      INSERT INTO mqi.inspection_lot (inspection_run_id, production_lot_id, lot_code_raw, recorded_box_count, inspected_qty_ea, lot_linkage_status, remark)
      VALUES (v_run, NULL, upper(btrim(l->>'lot_code_raw')), nullif(l->>'box_count', '')::int, nullif(l->>'qty_ea', '')::int, 'UNRESOLVED',
              jsonb_build_object('marking_code', upper(btrim(l->>'lot_code_raw')), 'unresolved_reason', coalesce(nullif(l->>'note', ''), '같은 모델 CA 제품 LOT 을 DB 에서 찾지 못함'))::text)
      RETURNING inspection_lot_id INTO v_il;
      v_nl := v_nl + 1; v_one_il := v_il;
      CONTINUE;
    END IF;
    SELECT pl.lot_id INTO v_lot FROM mqi.production_lot pl
      JOIN mqi.process_run_lot prl ON prl.production_lot_id = pl.lot_id AND prl.lot_role = 'OUTPUT' AND prl.record_state = 'ACTIVE'
      JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
      JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code = 'IMEB3_CA_PRESS'
     WHERE pl.lot_code_raw = upper(btrim(l->>'lot_code')) AND pl.model_id = v_model AND pl.record_state = 'ACTIVE' LIMIT 1;
    INSERT INTO mqi.inspection_lot (inspection_run_id, production_lot_id, lot_code_raw, recorded_box_count, inspected_qty_ea, recorded_quantity_raw, lot_linkage_status, remark)
    VALUES (v_run, v_lot, coalesce(nullif(btrim(l->>'lot_code_raw'), ''), upper(btrim(l->>'lot_code'))), nullif(l->>'box_count', '')::int,
            nullif(l->>'qty_ea', '')::int, nullif(l->>'quantity_raw', ''), 'CONFIRMED',
            jsonb_build_object('linked_by', '사람 선택(재검 입력)', 'marking_code', nullif(btrim(l->>'lot_code_raw'), ''))::text)
    RETURNING inspection_lot_id INTO v_il;
    v_nl := v_nl + 1; v_one_il := v_il;
    IF l->>'prior_run_id' = 'ALL' THEN
      FOR o IN SELECT DISTINCT ir.inspection_run_id FROM mqi.inspection_run ir
                 JOIN mqi.inspection_lot il ON il.inspection_run_id = ir.inspection_run_id AND il.production_lot_id = v_lot AND il.record_state = 'ACTIVE'
                WHERE ir.model_id = v_model AND ir.inspection_type = 'FINAL' AND ir.record_state = 'ACTIVE' AND ir.inspection_date <= v_date LOOP
        IF NOT (o = ANY (v_priors)) THEN
          INSERT INTO mqi.inspection_run_link (prior_inspection_run_id, followup_inspection_run_id, relation_type, linkage_status, evidence_note, model_id)
          VALUES (o, v_run, 'TARGETED_REINSPECTION', 'CONFIRMED', '최종검사 일보 비고란 재검 — 대상 LOT 을 검사한 본검사 전부(사람 선택)', v_model);
          v_priors := v_priors || o; v_links := v_links + 1;
        END IF;
      END LOOP;
    ELSIF l->>'prior_run_id' <> 'NONE' AND NOT ((l->>'prior_run_id')::uuid = ANY (v_priors)) THEN
      INSERT INTO mqi.inspection_run_link (prior_inspection_run_id, followup_inspection_run_id, relation_type, linkage_status, evidence_note, model_id)
      VALUES ((l->>'prior_run_id')::uuid, v_run, 'TARGETED_REINSPECTION', 'CONFIRMED', '최종검사 일보 비고란 재검(사람이 본검사 선택)', v_model);
      v_priors := v_priors || (l->>'prior_run_id')::uuid; v_links := v_links + 1;
    END IF;
  END LOOP;

  FOR f IN SELECT * FROM jsonb_array_elements(coalesce(p->'findings', '[]'::jsonb)) LOOP
    IF nullif(f->>'qty', '') IS NULL AND coalesce(f->>'defect_code', f->>'name_raw', '') = '' THEN CONTINUE; END IF;
    IF (f->>'qty')::int < 0 THEN RAISE EXCEPTION '불량 수량은 0 이상'; END IF;
    v_dt := NULL;
    IF coalesce(f->>'defect_code', '') <> '' THEN
      SELECT defect_type_id INTO v_dt FROM mqi.defect_type WHERE defect_code = f->>'defect_code' AND record_state = 'ACTIVE';
      IF v_dt IS NULL THEN RAISE EXCEPTION '불량 유형 코드를 찾을 수 없음: %', f->>'defect_code'; END IF;
    END IF;
    INSERT INTO mqi.quality_finding (inspection_run_id, inspection_lot_id, defect_type_id, finding_class, quantity, quantity_unit,
                                     raw_quantity_text, raw_defect_name, validation_status, model_id, remark)
    VALUES (v_run, CASE WHEN v_nl = 1 THEN v_one_il END, v_dt, 'FINAL_DEFECT', nullif(f->>'qty', '')::int, 'EA', f->>'qty',
            coalesce(nullif(f->>'name_raw', ''), (SELECT defect_name FROM mqi.defect_type WHERE defect_type_id = v_dt)), 'VERIFIED', v_model,
            CASE WHEN v_nl > 1 THEN jsonb_build_object('scope', '재검 전체 합계(원문이 LOT 별로 나누지 않음)', 'lots', v_nl)::text END);
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('run_id', v_run, 'lots', v_nl, 'prior_links', v_links, 'findings', v_n, 'replaced', to_jsonb(v_old));
END $fn$;

-- 재검 1건과 하위 행(불량·대상 LOT·연결)을 VOID (내부용)
CREATE OR REPLACE FUNCTION public.m13_reinspection_void_rows(v_run uuid) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
AS $fn$
DECLARE n int := 0; k int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mqi.inspection_run WHERE inspection_run_id = v_run AND inspection_type = 'REINSPECTION' AND record_state = 'ACTIVE') THEN
    RAISE EXCEPTION '삭제할 수 있는 재검 기록이 아닙니다(재검사 유형·활성 기록만)';
  END IF;
  UPDATE mqi.quality_finding SET record_state = 'VOID' WHERE inspection_run_id = v_run AND record_state = 'ACTIVE'; GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  UPDATE mqi.inspection_lot SET record_state = 'VOID' WHERE inspection_run_id = v_run AND record_state = 'ACTIVE'; GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  UPDATE mqi.inspection_run_link SET record_state = 'VOID'
   WHERE (followup_inspection_run_id = v_run OR prior_inspection_run_id = v_run) AND record_state = 'ACTIVE'; GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  UPDATE mqi.inspection_run SET record_state = 'VOID' WHERE inspection_run_id = v_run; n := n + 1;
  RETURN n;
END $fn$;

REVOKE ALL ON FUNCTION public.m13_reinspection_void_rows(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- 4) 잘못 입력·중복 입력 삭제(VOID) RPC ---------------------------------------------------------------
-- p = {run_id, note(사유 5자 이상), actor, reason}
CREATE OR REPLACE FUNCTION public.m13_reinspection_void(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE v_n int;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_reinspection_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF char_length(btrim(coalesce(p->>'note', ''))) < 5 THEN RAISE EXCEPTION '삭제 사유를 5자 이상 적어 주세요(예: 같은 재검 중복 입력)'; END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[최종검사] 재검사 삭제(VOID) · ' || (p->>'note')), true);
  v_n := public.m13_reinspection_void_rows((p->>'run_id')::uuid);
  RETURN jsonb_build_object('ok', true, 'run_id', p->>'run_id', 'voided_rows', v_n);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_reinspection_save(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.m13_reinspection_void(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_reinspection_save(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.m13_reinspection_void(jsonb) TO service_role;
