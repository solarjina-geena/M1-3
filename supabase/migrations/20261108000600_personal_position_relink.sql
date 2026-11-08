-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다.
-- (2026-11-08 팀장: CA·보빈 위치도 날짜별 요약에 'CA LOT 미연결'이 많다 — 초품은 그날 생산 LOT 을 측정한 것인데?)
-- 원인: 위치도(quality_check)는 팀 설계상 '그 초품을 만든 공정 실행(process_run)'에만 FK 가 있고,
--       저장하는 순간 그날·모델(보빈은 교대까지) 실행이 정확히 1건일 때만 연결했다.
--       10월처럼 위치도를 먼저 넣고 작업일보를 나중에 넣은 날은 다시 연결되지 않았다.
-- 조치: 연결 안 된 위치도를 그날 실행이 정확히 1건이면 연결(추정 금지 — 0건·여러 건이면 그대로). 작업일보 저장 뒤 자동으로 부른다.
CREATE OR REPLACE FUNCTION public.m13_position_relink(p jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE n_ca int := 0; n_bb int := 0;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_position_relink: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[공통] 초품 위치도 ↔ 그날 작업일보 실행 다시 연결(실행 1건일 때만)'), true);
  -- CA 초품 → 그날·모델 압입(CA) 실행(리워크 제외) 1건
  WITH c AS (
    SELECT qc.quality_check_id, (array_agg(pr.process_run_id))[1] AS pr, count(*) AS n
      FROM mqi.quality_check qc
      JOIN mqi.production_run ru ON ru.model_id = qc.model_id AND ru.work_date = qc.check_date AND ru.record_state = 'ACTIVE'
      JOIN mqi.process_run pr ON pr.run_id = ru.run_id AND pr.record_state = 'ACTIVE' AND pr.work_type IS DISTINCT FROM 'REWORK'
      JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code = 'IMEB3_CA_PRESS'
     WHERE qc.record_state = 'ACTIVE' AND qc.process_run_id IS NULL AND qc.sample_reference = '초품'
     GROUP BY qc.quality_check_id HAVING count(*) = 1)
  UPDATE mqi.quality_check q SET process_run_id = c.pr FROM c WHERE q.quality_check_id = c.quality_check_id;
  GET DIAGNOSTICS n_ca = ROW_COUNT;
  -- 보빈 초품 → 그날·모델·교대 사출 실행 1건
  WITH c AS (
    SELECT qc.quality_check_id, (array_agg(pr.process_run_id))[1] AS pr, count(*) AS n
      FROM mqi.quality_check qc
      JOIN mqi.production_run ru ON ru.model_id = qc.model_id AND ru.work_date = qc.check_date AND ru.record_state = 'ACTIVE'
                                AND ru.shift = coalesce(public.m13_try_jsonb(qc.remark)->>'shift', 'D')
      JOIN mqi.process_run pr ON pr.run_id = ru.run_id AND pr.record_state = 'ACTIVE' AND pr.work_type IS DISTINCT FROM 'REWORK'
      JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code = 'IMEB3_INJECTION'
     WHERE qc.record_state = 'ACTIVE' AND qc.process_run_id IS NULL AND qc.sample_reference = '보빈 초품'
     GROUP BY qc.quality_check_id HAVING count(*) = 1)
  UPDATE mqi.quality_check q SET process_run_id = c.pr FROM c WHERE q.quality_check_id = c.quality_check_id;
  GET DIAGNOSTICS n_bb = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'ca_linked', n_ca, 'bobbin_linked', n_bb);
END $fn$;
REVOKE ALL ON FUNCTION public.m13_position_relink(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_position_relink(jsonb) TO service_role;
