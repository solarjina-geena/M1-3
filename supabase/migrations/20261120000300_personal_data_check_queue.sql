-- 개인 프로젝트 전용 (IMEB3 DB). 2026-11-20 사용자 결정(A안): 저장된 자료 전체 점검 → 대시보드 '확인 필요' 탭에 카드로.
-- 기존 mqi 테이블·컬럼·제약·FK 는 바꾸지 않는다(AGENTS.md '기존 스키마 보존 원칙'). 추가만 한다.
--   1) 새 스키마 mqi_ext + 판단 기록 표 mqi_ext.data_check (mqi.process_run · inspection_run · worker 를 FK 로 가리킴, 모두 NULL 허용)
--      변경 이력은 기존 감사 트리거(mqi_audit.capture)를 그대로 붙여 '확인·판단 이력'(m13_judgment_log)에 나오게 한다.
--   2) 뷰 m13_review_queue 에 DATA_CHECK 카드 4종 추가(기존 3종 정의는 그대로):
--      DEFECT_SUM  작업일보에 적힌 불량 합계 ≠ 불량 칸 합
--      RARE_NAME   1~2번만 나온 작업자·검사자 이름(잘못 읽혀 저장됐을 수 있음)
--      BA_CA_GAP   같은 날·모델 권선(BA)·압입(CA) 생산량 차이 30% 초과
--      NO_QTY      검사량이 빈 최종검사(PPM 분모에서 빠짐)
--      '원본과 맞음'으로 판단하면 같은 값인 동안 숨기고, 값이 바뀌면(고친 뒤에도 안 맞으면) 다시 올라온다.
--      '고칠 것'으로 판단하면 고칠 내용을 카드에 붙여 둔 채 남긴다(실제로 고쳐져 맞게 되면 저절로 사라짐).
--   3) RPC m13_data_check_save: DATA_CHECK 판단만 저장. 기존 m13_judgment_save 는 손대지 않는다.
-- 자료 자체는 이 RPC 가 고치지 않는다. 고치는 것은 지금처럼 관리 화면(다시 판독·고치기·기존 기록 바꾸기)에서.
-- 되돌리기: DROP FUNCTION public.m13_data_check_save(jsonb); 뷰는 20261106000500 파일로 다시 만들기; DROP SCHEMA mqi_ext CASCADE;

CREATE SCHEMA IF NOT EXISTS mqi_ext;
REVOKE ALL ON SCHEMA mqi_ext FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA mqi_ext TO service_role;

CREATE TABLE IF NOT EXISTS mqi_ext.data_check (
  data_check_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  check_code        text NOT NULL CHECK (check_code IN ('DEFECT_SUM', 'RARE_NAME', 'BA_CA_GAP', 'NO_QTY')),
  check_key         text NOT NULL,              -- 무엇에 대한 점검인지(예 DEFECT_SUM:<process_run_id>)
  fingerprint       text NOT NULL,              -- 판단할 때의 값(값이 바뀌면 카드가 다시 올라옴)
  decision          text NOT NULL CHECK (decision IN ('VERIFIED', 'NEEDS_FIX')),
  fix_note          text,                       -- '고칠 것'일 때 고칠 내용
  process_run_id    uuid REFERENCES mqi.process_run (process_run_id),
  inspection_run_id uuid REFERENCES mqi.inspection_run (inspection_run_id),
  worker_id         uuid REFERENCES mqi.worker (worker_id),
  remark            text,                       -- 판단 기록 JSON {"judgment": {...}} (다른 판단 카드와 같은 모양)
  recorded_at       timestamptz NOT NULL DEFAULT now(),
  record_state      text NOT NULL DEFAULT 'ACTIVE' CHECK (record_state IN ('ACTIVE', 'VOID'))
);
CREATE INDEX IF NOT EXISTS data_check_key_idx ON mqi_ext.data_check (check_key, record_state);
ALTER TABLE mqi_ext.data_check ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON mqi_ext.data_check FROM PUBLIC, anon, authenticated;
GRANT SELECT ON mqi_ext.data_check TO service_role;
DROP TRIGGER IF EXISTS z_audit ON mqi_ext.data_check;
CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi_ext.data_check FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('data_check_id');

CREATE OR REPLACE VIEW public.m13_review_queue AS
WITH out_lot AS (   -- 실행 → OUTPUT LOT 코드
    SELECT prl.process_run_id, string_agg(DISTINCT l.lot_code_raw, '/') AS lot_code
    FROM mqi.process_run_lot prl JOIN mqi.production_lot l ON l.lot_id = prl.production_lot_id
    WHERE prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT'
    GROUP BY prl.process_run_id
),
lot_stage AS (      -- LOT → 그 LOT 을 만든 공정
    SELECT DISTINCT ON (prl.production_lot_id) prl.production_lot_id, p.process_code
    FROM mqi.process_run_lot prl JOIN mqi.process_run pr ON pr.process_run_id = prl.process_run_id
    JOIN mqi.process p ON p.process_id = pr.process_id
    WHERE prl.record_state = 'ACTIVE' AND prl.lot_role = 'OUTPUT'
),
rv AS (
    SELECT 'READ_VALUE'::text AS kind, ef.extracted_field_id AS target_id, 'extracted_field'::text AS target_table,
           coalesce(ls.process_code, 'SOURCE') AS stage_code, pm.model_code, l.lot_date AS item_date,
           coalesce(l.lot_code_raw, ef.extracted_value) AS lot_code,
           coalesce(sl.source_label, ef.field_code) || ' 판독값 확인' AS title,
           ef.extracted_value AS current_value,
           jsonb_build_object('field_code', ef.field_code, 'raw_value', ef.raw_value, 'extracted_value', ef.extracted_value,
                              'sheet', sl.sheet_name, 'cell', sl.cell_reference, 'review_note', fr.review_note,
                              'linked_to', fpl.target_column_name, 'evidence_role', fpl.evidence_role) AS detail,
           ARRAY['VERIFIED', 'CORRECTED', 'REJECTED'] AS decisions, ef.recorded_at AS raised_at
    FROM mqi.extracted_field ef
    JOIN mqi.source_location sl ON sl.source_location_id = ef.source_location_id
    LEFT JOIN mqi.field_review fr ON fr.field_review_id = ef.current_review_id
    LEFT JOIN LATERAL (SELECT * FROM mqi.field_provenance_link f WHERE f.extracted_field_id = ef.extracted_field_id AND f.record_state = 'ACTIVE'
                       ORDER BY (f.evidence_role = 'PRIMARY') DESC LIMIT 1) fpl ON true
    LEFT JOIN mqi.production_lot l ON l.lot_id = fpl.target_lot_id
    LEFT JOIN mqi.product_model pm ON pm.model_id = l.model_id
    LEFT JOIN lot_stage ls ON ls.production_lot_id = l.lot_id
    WHERE ef.record_state = 'ACTIVE' AND ef.validation_status = 'NEEDS_REVIEW'
),
il AS (
    SELECT 'INSPECTION_LOT', il.inspection_lot_id, 'inspection_lot', 'IMEB3_FINAL_INSPECTION', pm.model_code, ir.inspection_date,
           NULL::text, '검사 LOT 판독 불가: ' || coalesce(il.lot_code_raw, '(빈칸)'), il.lot_code_raw,
           jsonb_build_object('lot_code_raw', il.lot_code_raw, 'box_count', il.recorded_box_count, 'quantity_raw', il.recorded_quantity_raw,
                              'inspection_label', ir.raw_inspection_label, 'round_no', ir.inspection_round_no,
                              'normalization', public.m13_try_jsonb(il.remark) ->> 'normalization_status'),
           ARRAY['CONFIRMED', 'UNRESOLVED', 'VOID'], il.recorded_at
    FROM mqi.inspection_lot il
    JOIN mqi.inspection_run ir ON ir.inspection_run_id = il.inspection_run_id
    JOIN mqi.product_model pm ON pm.model_id = il.model_id
    WHERE il.record_state = 'ACTIVE' AND il.lot_linkage_status = 'UNRESOLVED'
      AND NOT (public.m13_try_jsonb(il.remark) ? 'judgment')
),
ev AS (
    SELECT 'EVENT', e.event_id, 'production_event', coalesce(p.process_code, 'COMMON'), pm.model_code, coalesce(e.event_date, pr.work_date),
           ol.lot_code, '생산 이벤트 확인: ' || left(coalesce(e.event_description, e.event_type), 60), e.event_description,
           jsonb_build_object('event_type', e.event_type, 'description', e.event_description, 'duration_minutes', e.duration_minutes,
                              'start_at', e.event_start_at, 'source_file', public.m13_try_jsonb(e.remark) ->> 'file',
                              'source_page', public.m13_try_jsonb(e.remark) ->> 'page'),
           ARRAY['VERIFIED', 'REJECTED', 'VOID'], e.recorded_at
    FROM mqi.production_event e
    LEFT JOIN mqi.process_run pr ON pr.process_run_id = e.process_run_id
    LEFT JOIN mqi.process p ON p.process_id = pr.process_id
    LEFT JOIN mqi.product_model pm ON pm.model_id = pr.model_id
    LEFT JOIN out_lot ol ON ol.process_run_id = e.process_run_id
    WHERE e.record_state = 'ACTIVE' AND e.validation_status = 'NEEDS_REVIEW'
),
-- ── (2026-11-20) 자료 점검 ──
ds AS (   -- 적힌 불량 합계 ≠ 불량 칸 합
    SELECT 'DEFECT_SUM'::text AS code, 'DEFECT_SUM:' || pr.process_run_id AS ckey, pc.process_code AS stage, pm.model_code AS model, pr.work_date AS d,
           ol.lot_code AS lot, '불량 합계가 칸 합과 다름: 적힌 ' || r.process_defect_qty || ' · 칸 합 ' || coalesce(sum(qf.quantity), 0) AS title,
           r.process_defect_qty || '≠' || coalesce(sum(qf.quantity), 0) AS cur,
           jsonb_build_object('check', '작업일보에 적힌 불량 합계와 불량 칸 숫자의 합이 다릅니다. 원본을 보고 어느 칸이 틀렸는지 확인하세요.',
                              'written_total', r.process_defect_qty, 'cells_sum', coalesce(sum(qf.quantity), 0),
                              'defects', jsonb_agg(jsonb_build_object('name', coalesce(qf.raw_defect_name, dt.defect_name), 'qty', qf.quantity)) FILTER (WHERE qf.quality_finding_id IS NOT NULL),
                              'source_file', public.m13_try_jsonb(pr.remark) ->> 'file', 'source_page', public.m13_try_jsonb(pr.remark) ->> 'page',
                              'run_id', pr.process_run_id) AS det,
           r.process_defect_qty || '|' || coalesce(sum(qf.quantity), 0) AS fp, pr.process_run_id AS run, NULL::uuid AS irun, NULL::uuid AS wid, r.recorded_at AS at
    FROM mqi.process_run pr
    JOIN mqi.process pc ON pc.process_id = pr.process_id
    JOIN mqi.product_model pm ON pm.model_id = pr.model_id
    JOIN mqi.process_run_result r ON r.process_run_id = pr.process_run_id AND r.record_state = 'ACTIVE'
    LEFT JOIN mqi.quality_finding qf ON qf.process_run_id = pr.process_run_id AND qf.record_state = 'ACTIVE'
    LEFT JOIN mqi.defect_type dt ON dt.defect_type_id = qf.defect_type_id
    LEFT JOIN out_lot ol ON ol.process_run_id = pr.process_run_id
    WHERE pr.record_state = 'ACTIVE' AND r.process_defect_qty IS NOT NULL
    GROUP BY pr.process_run_id, pc.process_code, pm.model_code, pr.work_date, ol.lot_code, r.process_defect_qty, r.recorded_at, pr.remark
    HAVING r.process_defect_qty <> coalesce(sum(qf.quantity), 0)
),
rn AS (   -- 1~2번만 나온 이름
    SELECT 'RARE_NAME'::text, 'RARE_NAME:' || s.grp || ':' || s.name,
           CASE s.grp WHEN 'INJECTION' THEN 'IMEB3_INJECTION' WHEN 'STITCHING' THEN 'IMEB3_STITCHING' WHEN 'ASSEMBLY' THEN 'IMEB3_WINDING' ELSE 'IMEB3_FINAL_INSPECTION' END,
           NULL::varchar, s.last_date, NULL::text,
           '드물게 나온 이름 확인: ' || s.name || ' (' || s.runs || '번, ' || CASE s.grp WHEN 'INJECTION' THEN '사출' WHEN 'STITCHING' THEN '스티칭' WHEN 'ASSEMBLY' THEN '조립' ELSE '최종검사' END || ')',
           s.name,
           jsonb_build_object('check', '이 공정에서 1~2번만 나온 이름입니다. 새로 온 사람이면 맞음, 다른 사람 이름을 잘못 읽은 것이면 고칠 것으로 판단하세요.',
                              'name', s.name, 'runs', s.runs,
                              'frequent_names', (SELECT jsonb_agg(o.name || '(' || o.runs || ')' ORDER BY o.runs DESC) FROM public.m13_worker_name_stats o
                                                  WHERE o.grp = s.grp AND o.runs >= 3 AND (left(o.name, 1) = left(s.name, 1) OR right(o.name, 1) = right(s.name, 1))),
                              'where', CASE WHEN s.grp = 'FINAL' THEN
                                  (SELECT jsonb_agg(x) FROM (SELECT jsonb_build_object('date', ir.inspection_date, 'file', public.m13_try_jsonb(ir.remark) ->> 'file', 'page', public.m13_try_jsonb(ir.remark) ->> 'page') x
                                     FROM mqi.inspection_run ir JOIN mqi.worker w ON w.worker_id = ir.inspector_id
                                    WHERE ir.record_state = 'ACTIVE' AND w.worker_display_name = s.name ORDER BY ir.inspection_date LIMIT 5) z)
                                ELSE
                                  (SELECT jsonb_agg(x) FROM (SELECT DISTINCT jsonb_build_object('date', pr.work_date, 'process', pc.process_code, 'file', public.m13_try_jsonb(pr.remark) ->> 'file', 'page', public.m13_try_jsonb(pr.remark) ->> 'page') x
                                     FROM mqi.worker_assignment wa JOIN mqi.worker w ON w.worker_id = wa.worker_id
                                     JOIN mqi.process_run pr ON pr.process_run_id = wa.process_run_id AND pr.record_state = 'ACTIVE'
                                     JOIN mqi.process pc ON pc.process_id = pr.process_id
                                    WHERE wa.record_state = 'ACTIVE' AND w.worker_display_name = s.name
                                      AND CASE s.grp WHEN 'INJECTION' THEN pc.process_code = 'IMEB3_INJECTION' WHEN 'STITCHING' THEN pc.process_code = 'IMEB3_STITCHING'
                                               ELSE pc.process_code IN ('IMEB3_WINDING', 'IMEB3_CA_PRESS') END LIMIT 5) z) END),
           s.name || '|' || s.runs, NULL::uuid, NULL::uuid,
           (SELECT w.worker_id FROM mqi.worker w WHERE w.worker_display_name = s.name AND w.record_state = 'ACTIVE' ORDER BY w.recorded_at LIMIT 1),
           s.last_date::timestamptz
    FROM public.m13_worker_name_stats s
    WHERE s.runs <= 2
),
bq AS (   -- 같은 날·모델 권선·압입 생산량
    SELECT pr.work_date AS d, pm.model_code AS m, pc.process_code AS p, sum(r.gross_output_qty) AS q,
           jsonb_agg(DISTINCT jsonb_build_object('file', public.m13_try_jsonb(pr.remark) ->> 'file', 'page', public.m13_try_jsonb(pr.remark) ->> 'page')) AS src,
           max(r.recorded_at) AS at
    FROM mqi.process_run pr
    JOIN mqi.process pc ON pc.process_id = pr.process_id AND pc.process_code IN ('IMEB3_WINDING', 'IMEB3_CA_PRESS')
    JOIN mqi.product_model pm ON pm.model_id = pr.model_id
    JOIN mqi.process_run_result r ON r.process_run_id = pr.process_run_id AND r.record_state = 'ACTIVE'
    WHERE pr.record_state = 'ACTIVE'
    GROUP BY 1, 2, 3
),
bc AS (
    SELECT 'BA_CA_GAP'::text, 'BA_CA_GAP:' || a.d || ':' || a.m, 'IMEB3_CA_PRESS'::varchar, a.m::varchar, a.d, NULL::text,
           '권선·압입 생산량 차이 큼: BA ' || a.q || ' · CA ' || c.q,
           a.q || ' / ' || c.q,
           jsonb_build_object('check', '같은 날·같은 모델의 권선(BA)과 압입(CA) 생산량이 30% 넘게 다릅니다. 수량 판독 오류인지, 실제로 다른지(리워크·재고 투입 등) 원본으로 확인하세요.',
                              'ba_qty', a.q, 'ca_qty', c.q, 'diff_pct', round(abs(a.q - c.q)::numeric * 100 / greatest(a.q, c.q), 1),
                              'ba_source', a.src, 'ca_source', c.src),
           a.q || '|' || c.q, NULL::uuid, NULL::uuid, NULL::uuid, greatest(a.at, c.at)
    FROM bq a JOIN bq c ON c.d = a.d AND c.m = a.m AND c.p = 'IMEB3_CA_PRESS'
    WHERE a.p = 'IMEB3_WINDING' AND a.q > 0 AND c.q > 0 AND abs(a.q - c.q)::numeric / greatest(a.q, c.q) > 0.3
),
nq AS (   -- 검사량 빈 최종검사
    SELECT 'NO_QTY'::text, 'NO_QTY:' || ir.inspection_run_id, 'IMEB3_FINAL_INSPECTION'::varchar, pm.model_code, ir.inspection_date, NULL::text,
           '검사량 빈칸: ' || CASE ir.inspection_type WHEN 'REINSPECTION' THEN '재검' ELSE coalesce(ir.inspection_round_no::text || '차', '') END
             || coalesce(' · 검사자 ' || w.worker_display_name, ''),
           coalesce(ir.inspected_qty_ea::text, '빈칸'),
           jsonb_build_object('check', '검사량이 비어 있어 불량률(PPM) 계산에서 빠집니다. 원본에 검사량이 있으면 관리 화면에서 다시 읽어 넣고, 원본도 비어 있으면 맞음으로 판단하세요.',
                              'inspection_type', ir.inspection_type, 'round_no', ir.inspection_round_no, 'inspector', w.worker_display_name,
                              'lots', (SELECT string_agg(coalesce(l.lot_code_raw, '?'), ', ') FROM mqi.inspection_lot l WHERE l.inspection_run_id = ir.inspection_run_id AND l.record_state = 'ACTIVE'),
                              'source_file', public.m13_try_jsonb(ir.remark) ->> 'file', 'source_page', public.m13_try_jsonb(ir.remark) ->> 'page'),
           ir.inspection_run_id || '|' || coalesce(ir.inspected_qty_ea::text, ''), NULL::uuid, ir.inspection_run_id, NULL::uuid, ir.recorded_at
    FROM mqi.inspection_run ir
    JOIN mqi.product_model pm ON pm.model_id = ir.model_id
    LEFT JOIN mqi.worker w ON w.worker_id = ir.inspector_id
    WHERE ir.record_state = 'ACTIVE' AND ir.inspection_type IN ('FINAL', 'REINSPECTION') AND coalesce(ir.inspected_qty_ea, 0) <= 0
),
chk AS (SELECT * FROM ds UNION ALL SELECT * FROM rn UNION ALL SELECT * FROM bc UNION ALL SELECT * FROM nq),
dc AS (
    SELECT 'DATA_CHECK'::text, md5(c.ckey)::uuid, 'data_check'::text, c.stage::varchar, c.model::varchar(50), c.d::date, c.lot::varchar, c.title::text, c.cur::text,
           c.det || jsonb_build_object('check_code', c.code, 'check_key', c.ckey, 'fingerprint', c.fp,
                                       'process_run_id', c.run, 'inspection_run_id', c.irun, 'worker_id', c.wid,
                                       'fix_note', (SELECT j.fix_note FROM mqi_ext.data_check j WHERE j.check_key = c.ckey AND j.record_state = 'ACTIVE'
                                                     AND j.decision = 'NEEDS_FIX' ORDER BY j.recorded_at DESC LIMIT 1)),
           ARRAY['VERIFIED', 'NEEDS_FIX'], c.at
    FROM chk c
    WHERE NOT EXISTS (SELECT 1 FROM mqi_ext.data_check j WHERE j.check_key = c.ckey AND j.fingerprint = c.fp
                        AND j.decision = 'VERIFIED' AND j.record_state = 'ACTIVE')
),
q AS (SELECT * FROM rv UNION ALL SELECT * FROM il UNION ALL SELECT * FROM ev UNION ALL SELECT * FROM dc)
SELECT q.kind || ':' || q.target_id AS item_id, q.kind, q.target_table, q.target_id::text AS target_id, q.stage_code,
       CASE q.stage_code WHEN 'IMEB3_INJECTION' THEN '사출' WHEN 'IMEB3_STITCHING' THEN '스티칭' WHEN 'IMEB3_WINDING' THEN '권선(BA)'
            WHEN 'IMEB3_CA_PRESS' THEN '압입(CA)' WHEN 'IMEB3_FINAL_INSPECTION' THEN '최종검사' WHEN 'SOURCE' THEN '원본·출처' ELSE '공통' END AS stage_label,
       q.model_code, to_char(q.item_date, 'YYYY-MM-DD') AS item_date, q.lot_code, q.title, q.current_value, q.detail, q.decisions, q.raised_at
FROM q;

GRANT SELECT ON public.m13_review_queue TO anon, authenticated, service_role;

-- 판단 저장(DATA_CHECK 만). 자료는 고치지 않고 판단만 남긴다.
CREATE OR REPLACE FUNCTION public.m13_data_check_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'mqi', 'public'
AS $function$
DECLARE
  q public.m13_review_queue%ROWTYPE;
  v_dec text := upper(coalesce(p->>'decision', ''));
  v_note text := btrim(coalesce(p->>'note', ''));
  v_val text := nullif(btrim(coalesce(p->>'value', '')), '');
  v_id uuid := gen_random_uuid(); v_label text; v_j jsonb;
BEGIN
  SELECT * INTO q FROM public.m13_review_queue WHERE item_id = p->>'item_id' AND kind = 'DATA_CHECK';
  IF NOT FOUND THEN RAISE EXCEPTION '확인 필요 목록에 없는 점검 항목입니다(이미 판단했거나 값이 바뀜): %', p->>'item_id'; END IF;
  IF NOT (v_dec = ANY (q.decisions)) THEN RAISE EXCEPTION '이 항목에 쓸 수 없는 결정입니다: %', v_dec; END IF;
  IF char_length(v_note) < 5 OR char_length(v_note) > 500 THEN RAISE EXCEPTION '메모는 5~500자입니다'; END IF;
  IF v_note ~ '[0-9A-Za-z._%+-]+@[0-9A-Za-z.-]+\.[A-Za-z]{2,}' OR v_note ~ '01[016789][- ]?[0-9]{3,4}[- ]?[0-9]{4}' THEN
    RAISE EXCEPTION '메모에 이메일·전화번호 형태는 쓸 수 없습니다';
  END IF;
  IF v_dec = 'NEEDS_FIX' AND v_val IS NULL THEN RAISE EXCEPTION '고칠 것이면 고칠 내용(정정값)을 적어 주세요'; END IF;
  v_label := CASE v_dec WHEN 'VERIFIED' THEN '원본과 맞음' ELSE '고칠 것' END;
  v_j := jsonb_build_object('kind', 'DATA_CHECK', 'target_table', 'data_check', 'target_id', v_id, 'txn', txid_current()::text,
                            'decision', v_dec, 'decision_label', v_label, 'stage_label', q.stage_label, 'model', q.model_code,
                            'lot_code', q.lot_code, 'item_date', q.item_date, 'title', q.title, 'before', q.current_value, 'value', v_val,
                            'basis', nullif(p->>'basis_code', ''), 'note', v_note, 'images', coalesce(p->'images', '[]'::jsonb),
                            'check_code', q.detail->>'check_code', 'check_key', q.detail->>'check_key',
                            'at', to_char(clock_timestamp() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD HH24:MI'));
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', format('[%s] 판단:%s · %s · %s', q.stage_label, v_label, left(q.title, 80), left(v_note, 60)), true);
  INSERT INTO mqi_ext.data_check (data_check_id, check_code, check_key, fingerprint, decision, fix_note,
                                  process_run_id, inspection_run_id, worker_id, remark)
  VALUES (v_id, q.detail->>'check_code', q.detail->>'check_key', q.detail->>'fingerprint', v_dec, v_val,
          nullif(q.detail->>'process_run_id', '')::uuid, nullif(q.detail->>'inspection_run_id', '')::uuid, nullif(q.detail->>'worker_id', '')::uuid,
          jsonb_build_object('judgment', v_j)::text);
  RETURN jsonb_build_object('ok', true, 'item_id', q.item_id, 'decision', v_dec, 'decision_label', v_label, 'data_check_id', v_id);
END $function$;

REVOKE ALL ON FUNCTION public.m13_data_check_save(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_data_check_save(jsonb) TO service_role;
