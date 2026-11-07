-- 개인 프로젝트 전용 (IMEB3 DB). 테이블 구조는 바꾸지 않는다. (2026-11-07 팀장: 10/16 리워크 일보로 뜻 확정)
-- 용접부: 총불량 → 진성 / 가성, 리워크 투입 = 가성 + 초품 등(양식의 '투입수량', 예 11 + 24 = 35)
-- 조립부: 압입에서 나온 불량 유형별(수량·진성·가성), 리워크 투입 = 진성을 뺀 가성 합
-- S/N = 그 LOT 의 시리얼 범위(1:1 매칭 아님, 중간에 불량이 빠지므로 항상 넓다) → 수량과 맞추지 않는다
-- rework_record.input_qty = 리워크 투입(start_qty), completed_qty 는 양식에 없어 비운다(전에는 계산값), remark.first_qty = 초품 등 추가 수량
DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.m13_rework_save(jsonb)'::regprocedure);
  IF position($x$CASE WHEN v_part = 'WELD' THEN nullif(p->>'input_qty', '')::int
               WHEN nullif(p->>'start_qty', '') IS NOT NULL THEN greatest(0, (p->>'start_qty')::int - coalesce(nullif(p->>'true_qty', '')::int, 0)) END,$x$ in d) = 0 THEN
    RAISE EXCEPTION 'completed anchor missing';
  END IF;
  d := replace(d, $x$CASE WHEN v_part = 'WELD' THEN nullif(p->>'input_qty', '')::int
               WHEN nullif(p->>'start_qty', '') IS NOT NULL THEN greatest(0, (p->>'start_qty')::int - coalesce(nullif(p->>'true_qty', '')::int, 0)) END,$x$, 'NULL,');
  IF position($x$'to_ca_qty', CASE WHEN v_part = 'WELD' THEN nullif(p->>'input_qty', '')::int END,$x$ in d) = 0 THEN RAISE EXCEPTION 'remark anchor missing'; END IF;
  d := replace(d, $x$'to_ca_qty', CASE WHEN v_part = 'WELD' THEN nullif(p->>'input_qty', '')::int END,$x$, $x$'first_qty', nullif(p->>'first_qty', '')::int,$x$);
  EXECUTE d;
END $do$;

CREATE OR REPLACE VIEW public.m13_rework_entries AS
SELECT rr.rework_id, pm.model_code, to_char(rr.work_date::timestamp with time zone, 'YYYY-MM-DD') AS work_date,
       public.m13_try_jsonb(rr.remark)->>'part' AS part, public.m13_try_jsonb(rr.remark)->>'part_ko' AS part_ko,
       rr.marked_lot_code_raw AS mark, rr.marked_lot_date, rr.serial_start_raw, rr.serial_end_raw, rr.serial_start_num, rr.serial_end_num,
       CASE WHEN rr.serial_start_num IS NOT NULL AND rr.serial_end_num IS NOT NULL THEN rr.serial_end_num - rr.serial_start_num + 1 END AS serial_count,
       rr.recorded_qty AS total_qty, rr.input_qty,
       (public.m13_try_jsonb(rr.remark)->>'true_qty')::int AS true_qty, (public.m13_try_jsonb(rr.remark)->>'false_qty')::int AS false_qty,
       (SELECT string_agg(qf.raw_defect_name || ' ' || qf.quantity, ', ' ORDER BY qf.quantity DESC) FROM mqi.process_run pr
          JOIN mqi.quality_finding qf ON qf.process_run_id = pr.process_run_id AND qf.record_state = 'ACTIVE'
         WHERE pr.record_state = 'ACTIVE' AND pr.work_type = 'REWORK' AND public.m13_try_jsonb(pr.remark)->>'rework_id' = rr.rework_id::text) AS true_types,
       (SELECT pl.lot_code_raw FROM mqi.rework_origin_link l JOIN mqi.production_lot pl ON pl.lot_id = l.original_lot_id
         WHERE l.rework_id = rr.rework_id AND l.record_state = 'ACTIVE' LIMIT 1) AS ca_lot_code,
       public.m13_try_jsonb(rr.remark)->'workers' AS workers, public.m13_try_jsonb(rr.remark)->>'check' AS check_note,
       public.m13_try_jsonb(rr.remark)#>>'{source,file}' AS file, rr.validation_status, rr.raw_note, rr.recorded_at,
       count(*) OVER (PARTITION BY rr.model_id, rr.work_date, rr.rework_type, rr.serial_start_num) AS same_count,
       rr.input_qty AS start_qty, rr.completed_qty, (public.m13_try_jsonb(rr.remark)->>'to_ca_qty')::int AS to_ca_qty,
       (public.m13_try_jsonb(rr.remark)->>'first_qty')::int AS first_qty
  FROM mqi.rework_record rr
  JOIN mqi.product_model pm ON pm.model_id = rr.model_id
 WHERE rr.record_state = 'ACTIVE';
