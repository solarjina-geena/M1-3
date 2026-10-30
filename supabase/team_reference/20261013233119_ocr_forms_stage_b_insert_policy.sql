-- Approved Stage B; CLI-created file. No data DML. Preservation failure rolls back.
DO $stage_b_guard$
DECLARE
    mode text:='policy';
    catalog jsonb; data_snapshot jsonb; before_catalog jsonb; before_data jsonb;
    tab record; n bigint; h text;
BEGIN

    SELECT jsonb_build_object(
      'policies',(SELECT jsonb_agg(jsonb_build_array(polrelid,polname,polcmd,polpermissive,polroles,polqual,
         CASE WHEN mode='policy' AND polname='ocr_forms_candidate_insert' AND polnamespace='mqi'::regnamespace THEN NULL ELSE polwithcheck END) ORDER BY polrelid,polname)
         FROM (SELECT p.*,c.relnamespace polnamespace FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid) p),
      'functions',(SELECT md5(string_agg(jsonb_build_array(p.oid,p.proowner,pg_get_functiondef(p.oid),
         CASE WHEN mode='acl' AND p.oid IN ('public.mqi_ocr_forms_save(jsonb)'::regprocedure,'mqi_ocr_forms_private.save_raw(jsonb)'::regprocedure)
           THEN NULL ELSE p.proacl::text END)::text,'' ORDER BY p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname IN ('mqi','mqi_audit','mqi_ocr_forms_private','mqi_ocr_private') OR (n.nspname='public' AND p.proname LIKE 'mqi_%')),
      'roles',(SELECT md5(string_agg(to_jsonb(r)::text,'' ORDER BY r.oid)) FROM pg_roles r),
      'memberships',(SELECT md5(string_agg(to_jsonb(m)::text,'' ORDER BY roleid,member,grantor)) FROM pg_auth_members m),
      'schema_acls',(SELECT md5(string_agg(row(oid,nspname,nspowner,nspacl)::text,'' ORDER BY oid)) FROM pg_namespace),
      'columns',(SELECT md5(string_agg(to_jsonb(a)::text,'' ORDER BY a.attrelid,a.attnum)) FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('mqi','mqi_audit')),
      'constraints',(SELECT md5(string_agg(to_jsonb(c)::text,'' ORDER BY c.oid)) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname IN ('mqi','mqi_audit')),
      'auth_users',(SELECT md5(string_agg(md5(to_jsonb(u)::text),'' ORDER BY id)) FROM auth.users u)
    ) INTO catalog;
    data_snapshot:='{}'::jsonb;
    FOR tab IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('mqi','mqi_audit') ORDER BY schemaname,tablename LOOP
      EXECUTE format('SELECT count(*),md5(coalesce(string_agg(md5(to_jsonb(x)::text),'''' ORDER BY md5(to_jsonb(x)::text)),'''')) FROM %I.%I x',tab.schemaname,tab.tablename) INTO n,h;
      data_snapshot:=data_snapshot||jsonb_build_object(tab.schemaname||'.'||tab.tablename,jsonb_build_object('count',n,'fingerprint',h));
    END LOOP;
    before_catalog:=catalog; before_data:=data_snapshot;

    IF EXISTS(SELECT 1 FROM unnest(ARRAY['authenticated','anon','service_role']) r CROSS JOIN
        unnest(ARRAY['public.mqi_ocr_forms_save(jsonb)','mqi_ocr_forms_private.save_raw(jsonb)']) f WHERE has_function_privilege(r,f,'EXECUTE')) THEN
      RAISE EXCEPTION 'STAGE_B_SAVE_MUST_START_BLOCKED';
    END IF;
    EXECUTE $approved_change$
-- REVIEW ONLY. Not applied remotely. Execute inside an approved transaction.
-- Change only the ten INSERT WITH CHECK predicates; retain roles and all ACLs.
DO $repair$
DECLARE
    tab text;
    policy_row record;
    expected_predicate text := $expected$
        record_state::text = 'ACTIVE'::text AND
        current_setting('mqi.actor_ref'::text, true) = auth.uid()::text
    $expected$;
BEGIN
    FOREACH tab IN ARRAY ARRAY['source_ingest','source_bundle','source_asset',
        'source_bundle_asset','source_document','source_document_version',
        'source_page','source_location','extraction_run','extracted_field'] LOOP
        SELECT p.polcmd,p.polpermissive,p.polroles,
               pg_get_expr(p.polwithcheck,p.polrelid) AS predicate
          INTO STRICT policy_row FROM pg_policy p
          WHERE p.polrelid=format('mqi.%I',tab)::regclass
            AND p.polname='ocr_forms_candidate_insert';
        IF policy_row.polcmd <> 'a' OR NOT policy_row.polpermissive
           OR policy_row.polroles <> ARRAY['mqi_ocr_forms_writer'::regrole::oid]
           OR regexp_replace(policy_row.predicate,'[[:space:]()]','','g') IS DISTINCT FROM
              regexp_replace(expected_predicate,'[[:space:]()]','','g') THEN
            RAISE EXCEPTION 'OCR_POLICY_PRECONDITION_FAILED' USING ERRCODE='42501';
        END IF;
        EXECUTE format('ALTER POLICY ocr_forms_candidate_insert ON mqi.%I
            WITH CHECK (record_state=''ACTIVE'' AND
              current_setting(''mqi.actor_ref'',true)=mqi_ocr_forms_private.actor(true)::text)',tab);
    END LOOP;
END $repair$;

$approved_change$;

    SELECT jsonb_build_object(
      'policies',(SELECT jsonb_agg(jsonb_build_array(polrelid,polname,polcmd,polpermissive,polroles,polqual,
         CASE WHEN mode='policy' AND polname='ocr_forms_candidate_insert' AND polnamespace='mqi'::regnamespace THEN NULL ELSE polwithcheck END) ORDER BY polrelid,polname)
         FROM (SELECT p.*,c.relnamespace polnamespace FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid) p),
      'functions',(SELECT md5(string_agg(jsonb_build_array(p.oid,p.proowner,pg_get_functiondef(p.oid),
         CASE WHEN mode='acl' AND p.oid IN ('public.mqi_ocr_forms_save(jsonb)'::regprocedure,'mqi_ocr_forms_private.save_raw(jsonb)'::regprocedure)
           THEN NULL ELSE p.proacl::text END)::text,'' ORDER BY p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname IN ('mqi','mqi_audit','mqi_ocr_forms_private','mqi_ocr_private') OR (n.nspname='public' AND p.proname LIKE 'mqi_%')),
      'roles',(SELECT md5(string_agg(to_jsonb(r)::text,'' ORDER BY r.oid)) FROM pg_roles r),
      'memberships',(SELECT md5(string_agg(to_jsonb(m)::text,'' ORDER BY roleid,member,grantor)) FROM pg_auth_members m),
      'schema_acls',(SELECT md5(string_agg(row(oid,nspname,nspowner,nspacl)::text,'' ORDER BY oid)) FROM pg_namespace),
      'columns',(SELECT md5(string_agg(to_jsonb(a)::text,'' ORDER BY a.attrelid,a.attnum)) FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('mqi','mqi_audit')),
      'constraints',(SELECT md5(string_agg(to_jsonb(c)::text,'' ORDER BY c.oid)) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname IN ('mqi','mqi_audit')),
      'auth_users',(SELECT md5(string_agg(md5(to_jsonb(u)::text),'' ORDER BY id)) FROM auth.users u)
    ) INTO catalog;
    data_snapshot:='{}'::jsonb;
    FOR tab IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('mqi','mqi_audit') ORDER BY schemaname,tablename LOOP
      EXECUTE format('SELECT count(*),md5(coalesce(string_agg(md5(to_jsonb(x)::text),'''' ORDER BY md5(to_jsonb(x)::text)),'''')) FROM %I.%I x',tab.schemaname,tab.tablename) INTO n,h;
      data_snapshot:=data_snapshot||jsonb_build_object(tab.schemaname||'.'||tab.tablename,jsonb_build_object('count',n,'fingerprint',h));
    END LOOP;
    IF catalog IS DISTINCT FROM before_catalog OR data_snapshot IS DISTINCT FROM before_data THEN
      RAISE EXCEPTION 'STAGE_B_PRESERVATION_CHECK_FAILED';
    END IF;

    IF (SELECT count(*) FROM pg_policies WHERE schemaname='mqi' AND policyname='ocr_forms_candidate_insert'
      AND regexp_replace(with_check,'[[:space:]()]','','g')=regexp_replace(
         'record_state::text=''ACTIVE''::text AND current_setting(''mqi.actor_ref''::text,true)=mqi_ocr_forms_private.actor(true)::text','[[:space:]()]','','g'))<>10 THEN
      RAISE EXCEPTION 'STAGE_B_POLICY_POSTCHECK_FAILED';
    END IF;

    IF EXISTS(SELECT 1 FROM unnest(ARRAY['authenticated','anon','service_role']) r CROSS JOIN
        unnest(ARRAY['public.mqi_ocr_forms_save(jsonb)','mqi_ocr_forms_private.save_raw(jsonb)']) f WHERE has_function_privilege(r,f,'EXECUTE')) THEN
      RAISE EXCEPTION 'STAGE_B_SAVE_MUST_START_BLOCKED';
    END IF;
END $stage_b_guard$;
NOTIFY pgrst,'reload schema';
