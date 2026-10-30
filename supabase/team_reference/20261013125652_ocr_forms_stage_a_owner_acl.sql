-- Stage A owner-scoped ACL repair. No data changes; save remains blocked.
-- Managed postgres is not superuser and does not inherit these owners.
SET LOCAL ROLE mqi_ocr_forms_writer;
REVOKE ALL ON FUNCTION mqi_ocr_forms_private.save_raw(jsonb) FROM PUBLIC,anon,authenticated,service_role;
RESET ROLE;
SET LOCAL ROLE mqi_ocr_forms_reader;
REVOKE ALL ON FUNCTION mqi_ocr_forms_private.list_raw(),mqi_ocr_forms_private.detail_raw(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION mqi_ocr_forms_private.list_raw(),mqi_ocr_forms_private.detail_raw(uuid) TO authenticated;
RESET ROLE;
DO $stage_a_acl$
BEGIN
  IF EXISTS (SELECT 1 FROM unnest(ARRAY['anon','authenticated','service_role']) r
      CROSS JOIN unnest(ARRAY['public.mqi_ocr_forms_save(jsonb)','mqi_ocr_forms_private.save_raw(jsonb)']) f
      WHERE has_function_privilege(r,f,'EXECUTE')) THEN
    RAISE EXCEPTION 'STAGE_A_SAVE_ACL_NOT_BLOCKED';
  END IF;
  IF NOT has_function_privilege('authenticated','mqi_ocr_forms_private.list_raw()','EXECUTE')
     OR NOT has_function_privilege('authenticated','mqi_ocr_forms_private.detail_raw(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'STAGE_A_READER_ACL_MISSING';
  END IF;
END $stage_a_acl$;
NOTIFY pgrst,'reload schema';

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
