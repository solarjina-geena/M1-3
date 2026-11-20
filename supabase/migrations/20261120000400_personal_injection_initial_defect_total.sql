-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다(기존 행 값만 정정, 감사 이력 남김).
-- (2026-11-20 사용자 결정) 사출 일보의 '초기불량'은 셋업불량처럼 고정적으로 나오는 불량이라 현장에서는 불량 합계에서 빼고 적는 것이 관습이다.
-- 원칙적으로 초기불량도 불량 수량이므로 불량 합계(process_run_result.process_defect_qty)에 넣는다.
-- 정정 대상: 적힌 합계 = (불량 칸 합 − 초기불량) 으로 정확히 맞는 실행만 → 합계를 초기불량 포함 칸 합으로 바꾸고,
--           원래 적힌 값은 remark.written_defect_total 에 남긴다. 그래도 안 맞는 실행은 손대지 않는다(확인 필요 '자료 점검' 카드로 남음).
-- 앞으로 저장하는 일보는 백엔드(JournalPayload.normalized)가 같은 규칙으로 자동 반영한다.
-- 되돌리기: remark.written_defect_total 값으로 process_defect_qty 를 되돌리면 된다.

-- mqi 쓰기 보호(write_guard)가 SERIALIZABLE 트랜잭션을 요구한다.
BEGIN ISOLATION LEVEL SERIALIZABLE;
DO $$
BEGIN
  PERFORM set_config('mqi.actor_ref', 'm1-3-app', true);
  PERFORM set_config('mqi.change_reason', '[사출] 불량 합계에 초기불량 포함(사용자 결정 2026-11-20, 적힌 합계는 remark.written_defect_total)', true);
  WITH x AS (
    SELECT r.process_run_result_id, r.process_defect_qty AS t,
           coalesce(sum(qf.quantity), 0) AS s_all,
           coalesce(sum(qf.quantity) FILTER (WHERE coalesce(qf.raw_defect_name, dt.defect_name) ~ '초기\s*불량'), 0) AS s_init
      FROM mqi.process_run pr
      JOIN mqi.process_run_result r ON r.process_run_id = pr.process_run_id AND r.record_state = 'ACTIVE'
      LEFT JOIN mqi.quality_finding qf ON qf.process_run_id = pr.process_run_id AND qf.record_state = 'ACTIVE'
      LEFT JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
     WHERE pr.record_state = 'ACTIVE' AND r.process_defect_qty IS NOT NULL
     GROUP BY r.process_run_result_id, r.process_defect_qty
  )
  UPDATE mqi.process_run_result r
     SET process_defect_qty = x.s_all,
         remark = (coalesce(public.m13_try_jsonb(r.remark), '{}'::jsonb)
                   || jsonb_build_object('written_defect_total', x.t, 'initial_defect_qty', x.s_init,
                                         'defect_total_rule', '초기불량 포함(현장 관습상 일보 합계에서 빠짐) 2026-11-20'))::text
    FROM x
   WHERE x.process_run_result_id = r.process_run_result_id
     AND x.s_init > 0 AND x.t <> x.s_all AND x.t = x.s_all - x.s_init
     AND (r.remark IS NULL OR public.m13_try_jsonb(r.remark) IS NOT NULL);   -- 비고가 JSON 이 아니면(원문 글) 덮어쓰지 않도록 건너뜀
END $$;
COMMIT;
-- 적용 결과(2026-11-20): 5건 정정(10/12 OV 52→100, 10/19 OV 147→149, 10/23 HSV 145→193, 11/02 HSV 108→156, 11/05 IV 18→66), 감사 이력 5건. 10/21 HSV(적힌 233, 초기불량 빼도 223)는 그대로.
