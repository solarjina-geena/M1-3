-- 개인 프로젝트 전용 (IMEB3 DB). 팀 mqi 스키마는 건드리지 않는다. (2026-11-08 팀장: 구글폼 대신 대시보드 안 사용자 테스트 설문)
-- 설문 응답은 제조 기록이 아니라 서비스 평가라 mqi 밖(public)에 둔다. 이름·이메일·IP 는 저장하지 않는다.
CREATE TABLE IF NOT EXISTS public.m13_survey_response (
  response_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  survey_code  text NOT NULL DEFAULT 'USER_TEST_20261108',
  tester_group text NOT NULL CHECK (tester_group IN ('팀원', '사내')),
  answers      jsonb NOT NULL,
  record_state text NOT NULL DEFAULT 'ACTIVE' CHECK (record_state IN ('ACTIVE', 'VOID'))
);
ALTER TABLE public.m13_survey_response ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.m13_survey_response FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.m13_survey_response TO service_role;

CREATE OR REPLACE FUNCTION public.m13_survey_submit(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $fn$
DECLARE v_id uuid; v_group text := p->>'tester_group'; v_ans jsonb := p->'answers';
BEGIN
  IF v_group NOT IN ('팀원', '사내') THEN RAISE EXCEPTION '테스트 구분(팀원/사내)을 골라 주세요'; END IF;
  IF v_ans IS NULL OR jsonb_typeof(v_ans) <> 'object' THEN RAISE EXCEPTION '응답이 비어 있습니다'; END IF;
  IF octet_length(v_ans::text) > 20000 THEN RAISE EXCEPTION '응답이 너무 깁니다'; END IF;
  INSERT INTO public.m13_survey_response (tester_group, answers, survey_code)
  VALUES (v_group, v_ans, coalesce(nullif(p->>'survey_code', ''), 'USER_TEST_20261108'))
  RETURNING response_id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'response_id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION public.m13_survey_submit(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m13_survey_submit(jsonb) TO service_role;

CREATE OR REPLACE VIEW public.m13_survey_rows AS
SELECT response_id, to_char(submitted_at AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD HH24:MI') AS submitted_at_kst,
       survey_code, tester_group, answers
  FROM public.m13_survey_response
 WHERE record_state = 'ACTIVE';
REVOKE ALL ON public.m13_survey_rows FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.m13_survey_rows TO service_role;
