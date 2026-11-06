-- 개인 프로젝트 전용 (IMEB3 DB). mqi 테이블 구조는 바꾸지 않는다. public 뷰·RPC 만. (2026-11-07)
-- 관리 화면 판독 실행 기록(결과보고서 비교표용, 사용자 요청): 작업일보(사출·BS·조립·최종검사)·재검사 비고 = Claude(VISION_LLM),
-- 사출조건 체크시트·보빈 위치도 엑셀 = 칸 위치 판독(EXCEL_PARSER, 토큰 0). 1회 판독 = 팀 출처 사슬 1벌:
--   source_asset(파일 sha256, 원본 비보관) ← source_bundle_asset ← source_bundle ← source_ingest
--   extraction_run(method, model_name, prompt_version = 문서 종류, started_at/completed_at, COMPLETED/FAILED, remark = 토큰·항목 수)
-- 뷰 m13_ai_calls: 1행 = 판독 1회(초·토큰), 관리 화면 'AI 판독 기록' 탭과 보고서 표가 읽는다.

CREATE OR REPLACE FUNCTION public.m13_ai_call_log(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, mqi, public
SET default_transaction_isolation = 'serializable'
AS $fn$
DECLARE
  v_sha text := p#>>'{file,sha256}'; v_asset uuid; v_ingest uuid := gen_random_uuid(); v_bundle uuid := gen_random_uuid();
  v_ba uuid := gen_random_uuid(); v_run uuid := gen_random_uuid(); v_name text := left(coalesce(p#>>'{file,name}', 'upload'), 150);
  v_mime text := coalesce(p#>>'{file,mime}', ''); v_start timestamptz := coalesce(nullif(p->>'started_at', '')::timestamptz, clock_timestamp());
  v_end timestamptz; v_ok boolean := coalesce((p->>'ok')::boolean, true);
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'm13_ai_call_log: SERIALIZABLE 트랜잭션이 필요합니다' USING ERRCODE = '25000';
  END IF;
  IF v_sha IS NULL OR v_sha !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION '파일 해시가 없습니다'; END IF;
  v_end := v_start + make_interval(secs => greatest(coalesce((p->>'seconds')::numeric, 0), 0));
  PERFORM set_config('mqi.actor_ref', coalesce(nullif(p->>'actor', ''), 'm1-3-app'), true);
  PERFORM set_config('mqi.change_reason', coalesce(nullif(p->>'reason', ''), '[공통] 판독 실행 기록(' || coalesce(p->>'kind', '?') || ')'), true);

  SELECT asset_id INTO v_asset FROM mqi.source_asset WHERE sha256_hash = v_sha;
  IF v_asset IS NULL THEN
    v_asset := gen_random_uuid();
    INSERT INTO mqi.source_asset (asset_id, sha256_hash, asset_type, mime_type, file_size_bytes, storage_key, remark)
    VALUES (v_asset, v_sha,
            CASE WHEN v_mime LIKE 'image/%' THEN 'IMAGE' WHEN v_mime = 'application/pdf' THEN 'PDF' WHEN v_mime LIKE '%sheet%' OR v_name ~* '\.xls' THEN 'EXCEL' ELSE 'OTHER' END,
            nullif(v_mime, ''), nullif(p#>>'{file,size}', '')::bigint, 'UNSTORED:sha256:' || v_sha,
            jsonb_build_object('ds', 'AI_CALL_LOG_V1', 'storage', 'UNSTORED', 'policy', 'DEC-001 원본 영구 비보관', 'original_filename', v_name)::text);
  END IF;
  INSERT INTO mqi.source_ingest (ingest_id, source_name, ingest_method, started_at, completed_at, ingest_status, importer_ref, remark)
  VALUES (v_ingest, v_name, 'FILE_UPLOAD', v_start, v_end, CASE WHEN v_ok THEN 'COMPLETED' ELSE 'FAILED' END, 'manage.html 판독',
          jsonb_build_object('ds', 'AI_CALL_LOG_V1', 'kind', p->>'kind')::text);
  INSERT INTO mqi.source_bundle (bundle_id, ingest_id, bundle_name, bundle_type, remark)
  VALUES (v_bundle, v_ingest, '관리 화면 판독', 'OTHER', '{"ds": "AI_CALL_LOG_V1"}');
  INSERT INTO mqi.source_bundle_asset (bundle_asset_id, bundle_id, asset_id, original_filename, relative_path, remark)
  VALUES (v_ba, v_bundle, v_asset, v_name, v_name, '{"ds": "AI_CALL_LOG_V1"}');
  INSERT INTO mqi.extraction_run (extraction_run_id, bundle_asset_id, extraction_method, model_name, prompt_version, parser_version, started_at, completed_at, extraction_status, remark)
  VALUES (v_run, v_ba, CASE WHEN p->>'method' IN ('OCR', 'VISION_LLM', 'DOCUMENT_PARSER', 'EXCEL_PARSER', 'MANUAL') THEN p->>'method' ELSE 'VISION_LLM' END,
          left(p->>'model', 150), left(p->>'kind', 100), left(p->>'parser', 100), v_start, v_end, CASE WHEN v_ok THEN 'COMPLETED' ELSE 'FAILED' END,
          jsonb_strip_nulls(jsonb_build_object('ds', 'AI_CALL_LOG_V1', 'kind', p->>'kind',
            'input_tokens', nullif(p->>'input_tokens', '')::int, 'output_tokens', nullif(p->>'output_tokens', '')::int,
            'seconds', nullif(p->>'seconds', '')::numeric, 'items', nullif(p->>'items', '')::int, 'blocks', nullif(p->>'blocks', '')::int,
            'error', left(p->>'error', 300), 'size', nullif(p#>>'{file,size}', '')::bigint))::text);
  RETURN jsonb_build_object('extraction_run_id', v_run);
END $fn$;

REVOKE ALL ON FUNCTION public.m13_ai_call_log(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_ai_call_log(jsonb) TO service_role;

CREATE OR REPLACE VIEW public.m13_ai_calls AS
SELECT er.extraction_run_id::text AS run_id, er.started_at, er.completed_at,
       er.prompt_version AS kind, er.extraction_method AS method, er.model_name AS model, er.extraction_status AS status,
       (public.m13_try_jsonb(er.remark) ->> 'input_tokens')::int AS input_tokens,
       (public.m13_try_jsonb(er.remark) ->> 'output_tokens')::int AS output_tokens,
       coalesce((public.m13_try_jsonb(er.remark) ->> 'seconds')::numeric, extract(epoch FROM er.completed_at - er.started_at)) AS seconds,
       (public.m13_try_jsonb(er.remark) ->> 'items')::int AS items,
       (public.m13_try_jsonb(er.remark) ->> 'blocks')::int AS blocks,
       public.m13_try_jsonb(er.remark) ->> 'error' AS error,
       (public.m13_try_jsonb(er.remark) ->> 'size')::bigint AS file_size,
       ba.original_filename AS file
FROM mqi.extraction_run er
JOIN mqi.source_bundle_asset ba ON ba.bundle_asset_id = er.bundle_asset_id
WHERE er.record_state = 'ACTIVE' AND public.m13_try_jsonb(er.remark) ->> 'ds' = 'AI_CALL_LOG_V1';

GRANT SELECT ON public.m13_ai_calls TO service_role;
