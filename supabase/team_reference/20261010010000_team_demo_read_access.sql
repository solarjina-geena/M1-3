-- Team-only live DEMO queries. No table grants, no RLS changes, no data writes.
-- Passwords and LOGIN enablement are provisioned separately; never stored in migrations.
CREATE ROLE mqi_demo_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE mqi_team_jina NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3;
CREATE ROLE mqi_team_ingyu NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3;
CREATE ROLE mqi_team_chungkwan NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3;
CREATE ROLE mqi_team_sukyung NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3;
GRANT mqi_demo_reader TO mqi_team_jina, mqi_team_ingyu, mqi_team_chungkwan, mqi_team_sukyung;
GRANT CONNECT ON DATABASE postgres TO mqi_demo_reader;
CREATE SCHEMA mqi_demo_api AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA mqi_demo_api FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA mqi_demo_api TO mqi_demo_reader;

CREATE FUNCTION mqi_demo_api.read_demo(
    p_query text, p_model text DEFAULT NULL, p_lot text DEFAULT NULL,
    p_process text DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $body$
DECLARE result jsonb;
BEGIN
    IF p_model IS NOT NULL AND p_model NOT IN ('IV','OV','HSV') THEN
        RAISE EXCEPTION 'Unsupported model' USING ERRCODE='22023';
    END IF;
    IF p_lot IS NOT NULL AND p_lot !~ '^DEMO-V1-[0-9]{8}-(IV|OV|HSV)-[DN]$' THEN
        RAISE EXCEPTION 'Unsupported DEMO LOT' USING ERRCODE='22023';
    END IF;
    IF p_process IS NOT NULL AND p_process NOT IN ('DEMO_INJECTION','DEMO_STITCHING','DEMO_WINDING','DEMO_CA_PRESS','DEMO_FINAL_INSPECTION') THEN
        RAISE EXCEPTION 'Unsupported process' USING ERRCODE='22023';
    END IF;
    IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN
        RAISE EXCEPTION 'Invalid date range' USING ERRCODE='22023';
    END IF;
    CASE p_query
    WHEN '01_overview' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT count(DISTINCT lot_id)::int lots,count(*)::int process_runs,count(DISTINCT lot_date)::int days,count(DISTINCT model_code)::int models FROM demo
LIMIT 2001
) q;
    WHEN '02_models' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT model_code,count(DISTINCT lot_id)::int lots FROM demo GROUP BY model_code ORDER BY model_code
LIMIT 2001
) q;
    WHEN '03_processes' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT process_code,count(*)::int runs,sum(recorded_good_qty)::bigint good_qty,sum(process_defect_qty)::bigint defect_qty FROM demo GROUP BY process_code ORDER BY process_code
LIMIT 2001
) q;
    WHEN '04_daily_production' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT lot_date,model_code,process_code,sum(recorded_good_qty)::bigint good_qty,sum(process_defect_qty)::bigint defect_qty FROM demo GROUP BY lot_date,model_code,process_code ORDER BY lot_date,model_code,process_code
LIMIT 2001
) q;
    WHEN '05_shift_comparison' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT model_code,shift,process_code,sum(recorded_good_qty)::bigint good_qty,sum(process_defect_qty)::bigint defect_qty FROM demo GROUP BY model_code,shift,process_code ORDER BY model_code,shift,process_code
LIMIT 2001
) q;
    WHEN '06_final_quality' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT model_code,count(*)::int lots,sum(gross_output_qty)::bigint inspected_qty,sum(process_defect_qty)::bigint defect_qty,round(100.0*sum(process_defect_qty)/nullif(sum(gross_output_qty),0),3) defect_rate_pct FROM demo WHERE process_code='DEMO_FINAL_INSPECTION' GROUP BY model_code ORDER BY model_code
LIMIT 2001
) q;
    WHEN '08_scenarios' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT scenario,classification,process_code,count(*)::int runs,sum(process_defect_qty)::bigint defect_qty FROM demo GROUP BY scenario,classification,process_code ORDER BY scenario,process_code
LIMIT 2001
) q;
    WHEN '09_observations' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT d.lot_code_raw,d.model_code,d.lot_date,d.shift,d.process_code,d.scenario,p.parameter_code,p.unit,o.value_numeric,o.validation_status FROM demo d JOIN mqi.parameter_observation o USING(process_run_id) JOIN mqi.parameter_definition p USING(parameter_id) ORDER BY d.lot_date,d.model_code,d.shift,d.sequence_no,p.parameter_code
LIMIT 2001
) q;
    WHEN '11_measurements' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT d.lot_code_raw,d.model_code,d.process_code,d.scenario,q.check_type,q.remark::jsonb->>'scope' sample_scope,m.measurement_item_code,m.measured_value,m.measurement_unit,m.validation_status FROM demo d JOIN mqi.quality_check q USING(process_run_id) JOIN mqi.measurement m USING(quality_check_id) ORDER BY d.lot_code_raw,d.sequence_no
LIMIT 2001
) q;
    WHEN '12_inspection_details' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT d.lot_code_raw,d.model_code,d.scenario,i.inspection_date,i.inspection_type,i.inspected_qty_ea,f.quantity defect_qty,f.validation_status FROM demo d JOIN mqi.inspection_run i USING(process_run_id) JOIN mqi.inspection_lot il USING(inspection_run_id) JOIN mqi.quality_finding f ON f.inspection_lot_id=il.inspection_lot_id ORDER BY d.lot_code_raw
LIMIT 2001
) q;
    WHEN '13_all_lot_processes' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT * FROM demo ORDER BY lot_code_raw,sequence_no
LIMIT 2001
) q;
    WHEN '14_first_signal' THEN
        SELECT coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) INTO result FROM (
WITH demo AS (
 SELECT l.lot_id,l.lot_code_raw,m.model_code,l.lot_date,
        l.remark::jsonb->>'scenario' scenario,l.remark::jsonb->>'classification' classification,
        r.shift,p.process_code,pr.sequence_no,pr.process_run_id,
        x.recorded_good_qty,x.process_defect_qty,x.gross_output_qty,x.work_minutes
 FROM mqi.product product JOIN mqi.product_model m USING(product_id)
 JOIN mqi.production_lot l USING(model_id)
 JOIN mqi.process_run_lot pl ON pl.production_lot_id=l.lot_id AND pl.lot_role='OUTPUT'
 JOIN mqi.process_run pr USING(process_run_id)
 JOIN mqi.production_run r USING(run_id)
 JOIN mqi.process p USING(process_id)
 JOIN mqi.process_run_result x USING(process_run_id)
 WHERE product.product_code='DEMO_MQI_20261010_V1'
 AND (p_model IS NULL OR m.model_code=p_model)
 AND (p_lot IS NULL OR l.lot_code_raw=p_lot)
 AND (p_process IS NULL OR p.process_code=p_process)
 AND (p_from IS NULL OR l.lot_date>=p_from)
 AND (p_to IS NULL OR l.lot_date<=p_to)
) SELECT d.lot_code_raw,d.model_code,d.scenario,d.process_code,e.event_type,e.event_description FROM demo d JOIN mqi.production_event e USING(process_run_id) ORDER BY d.lot_code_raw
LIMIT 2001
) q;
    ELSE RAISE EXCEPTION 'Unsupported query' USING ERRCODE='22023';
    END CASE;
    IF jsonb_array_length(result)>2000 THEN
        RAISE EXCEPTION 'Result too large; narrow model, LOT, process or dates' USING ERRCODE='22023';
    END IF;
    RETURN result;
END
$body$;
ALTER FUNCTION mqi_demo_api.read_demo(text,text,text,text,date,date) OWNER TO postgres;
REVOKE ALL ON FUNCTION mqi_demo_api.read_demo(text,text,text,text,date,date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION mqi_demo_api.read_demo(text,text,text,text,date,date) TO mqi_demo_reader;
COMMENT ON FUNCTION mqi_demo_api.read_demo(text,text,text,text,date,date) IS
'Authenticated team-only C_SYNTHETIC queries; fixed dataset; no arbitrary SQL or audit/source data. Owner bypasses RLS only inside reviewed fixed SELECT bodies.';
ALTER ROLE mqi_team_jina SET statement_timeout='10s';
ALTER ROLE mqi_team_jina SET idle_in_transaction_session_timeout='15s';
ALTER ROLE mqi_team_jina SET default_transaction_read_only=on;
ALTER ROLE mqi_team_ingyu SET statement_timeout='10s';
ALTER ROLE mqi_team_ingyu SET idle_in_transaction_session_timeout='15s';
ALTER ROLE mqi_team_ingyu SET default_transaction_read_only=on;
ALTER ROLE mqi_team_chungkwan SET statement_timeout='10s';
ALTER ROLE mqi_team_chungkwan SET idle_in_transaction_session_timeout='15s';
ALTER ROLE mqi_team_chungkwan SET default_transaction_read_only=on;
ALTER ROLE mqi_team_sukyung SET statement_timeout='10s';
ALTER ROLE mqi_team_sukyung SET idle_in_transaction_session_timeout='15s';
ALTER ROLE mqi_team_sukyung SET default_transaction_read_only=on;

-- MQI FUNCTION ACL: keep this block last in every migration.
-- Schema-scoped default REVOKE cannot undo PostgreSQL's global PUBLIC EXECUTE.
-- Apply explicit ACLs before this migration transaction commits; no global defaults changed.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA mqi, mqi_audit FROM PUBLIC;
DO $mqi_function_acl$
DECLARE app_role text;
BEGIN
    FOREACH app_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = app_role) THEN
            EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA mqi, mqi_audit FROM %I', app_role);
        END IF;
    END LOOP;
END
$mqi_function_acl$;
