-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블 구조는 바꾸지 않는다. public 뷰·RPC 만 만든다. (2026-11-06)
-- 관리 화면 'CA 초품 위치도' 탭의 '입력된 위치도 목록'과 잘못 넣은 날 삭제(VOID).
-- 1) m13_position_entries : 초품 위치도 1회(quality_check 초품) = 1행. 판정 집계는 m13_position_checks(DB 기준값으로 계산)에서.
-- 2) m13_position_void(p) : 그 초품 기록과 측정값을 VOID(행은 지우지 않음, CRUD 이력 [압입(CA)]).
--    판단 카드로 이미 판단한 기록(확인·불량 등록·재측정 요청)은 삭제하지 않는다 — 판단 이력이 끊기지 않게.

CREATE OR REPLACE VIEW public.m13_position_entries AS
SELECT qc.quality_check_id::text AS check_id, to_char(qc.check_date, 'YYYY-MM-DD') AS check_date, pm.model_code,
       qc.validation_status, qc.process_run_id IS NOT NULL AS run_linked,
       count(pc.*) AS points,
       count(*) FILTER (WHERE pc.status = '정상') AS ok_cnt,
       count(*) FILTER (WHERE pc.status = '경계') AS warn_cnt,
       count(*) FILTER (WHERE pc.status = '불량') AS ng_cnt,
       max(pc.pos_xy) AS max_pos,
       max(pc.ca_lot_code) AS ca_lot_code,
       public.m13_try_jsonb(qc.remark) -> 'source' ->> 'layout' AS layout,
       public.m13_try_jsonb(qc.remark) ? 'judgment' AS judged,
       qc.recorded_at
FROM mqi.quality_check qc
JOIN mqi.product_model pm ON pm.model_id = qc.model_id
LEFT JOIN public.m13_position_checks pc ON pc.check_id = qc.quality_check_id::text
WHERE qc.record_state = 'ACTIVE' AND qc.check_type = 'IN_PROCESS_SAMPLE' AND qc.sample_reference = '초품'
GROUP BY qc.quality_check_id, qc.check_date, pm.model_code, qc.validation_status, qc.process_run_id, qc.remark, qc.recorded_at;

GRANT SELECT ON public.m13_position_entries TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.m13_position_void(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE v_id uuid := nullif(p->>'check_id','')::uuid; v_n int;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_position_void: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF char_length(btrim(coalesce(p->>'note', ''))) < 5 THEN RAISE EXCEPTION '삭제 사유를 5자 이상 적어 주세요(예: 날짜 잘못 입력)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mqi.quality_check WHERE quality_check_id = v_id AND record_state = 'ACTIVE' AND check_type = 'IN_PROCESS_SAMPLE' AND sample_reference = '초품') THEN
    RAISE EXCEPTION '삭제할 수 있는 초품 위치도 기록이 아닙니다';
  END IF;
  IF EXISTS (SELECT 1 FROM mqi.quality_check WHERE quality_check_id = v_id AND (validation_status <> 'UNVERIFIED' OR public.m13_try_jsonb(remark) ? 'judgment')) THEN
    RAISE EXCEPTION '이미 판단 카드로 판단한 기록이라 삭제할 수 없습니다(판단 이력 보존). 같은 날을 다시 넣으려면 "기존 기록 바꾸기"를 쓰세요';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor',''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason',''), '[압입(CA)] 초품 위치도 삭제(VOID) · ' || (p->>'note')), true);
  UPDATE mqi.measurement SET record_state = 'VOID' WHERE quality_check_id = v_id AND record_state = 'ACTIVE'; GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE mqi.quality_check SET record_state = 'VOID' WHERE quality_check_id = v_id;
  RETURN jsonb_build_object('ok', true, 'check_id', v_id, 'voided_measurements', v_n);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_position_void(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_position_void(jsonb) TO service_role;
