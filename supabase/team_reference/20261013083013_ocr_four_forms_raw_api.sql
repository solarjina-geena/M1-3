-- Stage A: read RPCs enabled; both save entry points remain blocked until INSERT approval.
-- Existing 50 tables and data preserved. Application status is recorded in docs/ocr.
-- PostgREST reads public function default_transaction_isolation (v11.1+).
CREATE SCHEMA mqi_ocr_forms_private;
REVOKE ALL ON SCHEMA mqi_ocr_forms_private FROM PUBLIC,anon,authenticated,service_role;
CREATE ROLE mqi_ocr_forms_writer NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE mqi_ocr_forms_reader NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT USAGE ON SCHEMA mqi,auth,mqi_ocr_forms_private TO mqi_ocr_forms_writer,mqi_ocr_forms_reader;
GRANT EXECUTE ON FUNCTION auth.uid(),auth.jwt() TO mqi_ocr_forms_writer,mqi_ocr_forms_reader;
GRANT USAGE ON SCHEMA mqi_ocr_forms_private TO authenticated;

CREATE FUNCTION mqi_ocr_forms_private.actor(p_write boolean) RETURNS uuid LANGUAGE plpgsql
SECURITY INVOKER SET search_path=pg_catalog AS $$
DECLARE actor uuid:=auth.uid(); claims jsonb:=auth.jwt();
BEGIN
    IF actor IS NULL OR claims->>'role' IS DISTINCT FROM 'authenticated'
       OR coalesce(claims->>'is_anonymous','false')<>'false'
       OR claims->'app_metadata'->>'mqi_ocr_viewer' IS DISTINCT FROM 'true'
       OR (p_write AND claims->'app_metadata'->>'mqi_ocr_uploader' IS DISTINCT FROM 'true') THEN
        RAISE EXCEPTION 'OCR_ACCESS_DENIED' USING ERRCODE='42501';
    END IF;
    RETURN actor;
END $$;
REVOKE ALL ON FUNCTION mqi_ocr_forms_private.actor(boolean) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION mqi_ocr_forms_private.actor(boolean) TO mqi_ocr_forms_writer,mqi_ocr_forms_reader;

DO $policies$
DECLARE tab text;
BEGIN
    FOREACH tab IN ARRAY ARRAY['source_ingest','source_bundle','source_asset','source_bundle_asset',
      'source_document','source_document_version','source_page','source_location','extraction_run','extracted_field'] LOOP
        EXECUTE format('GRANT SELECT,INSERT ON mqi.%I TO mqi_ocr_forms_writer',tab);
        EXECUTE format('GRANT SELECT ON mqi.%I TO mqi_ocr_forms_reader',tab);
        EXECUTE format('CREATE POLICY ocr_forms_writer_read ON mqi.%I FOR SELECT TO mqi_ocr_forms_writer USING (record_state=''ACTIVE'')',tab);
        EXECUTE format('CREATE POLICY ocr_forms_candidate_insert ON mqi.%I FOR INSERT TO mqi_ocr_forms_writer WITH CHECK (record_state=''ACTIVE'' AND current_setting(''mqi.actor_ref'',true)=auth.uid()::text)',tab);
        EXECUTE format('CREATE POLICY ocr_forms_reader_read ON mqi.%I FOR SELECT TO mqi_ocr_forms_reader USING (record_state=''ACTIVE'')',tab);
    END LOOP;
END $policies$;

CREATE FUNCTION mqi_ocr_forms_private.save_raw(p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; request uuid; file jsonb; page jsonb; item jsonb;
    fingerprint text; existing mqi.source_ingest; asset mqi.source_asset; page_id uuid;
    bundle_id uuid; occurrence uuid; doc uuid; ver uuid; run uuid; location uuid;
    form text; v_page_number integer; total integer:=0; n integer; stamp timestamptz:=clock_timestamp();
    result jsonb; failure_state text;
BEGIN
    actor:=mqi_ocr_forms_private.actor(true);
    IF current_setting('transaction_isolation')<>'serializable' THEN
        RAISE EXCEPTION 'OCR_SERIALIZABLE_REQUIRED' USING ERRCODE='25000'; END IF;
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>1000000
       OR p_payload->>'contract_version' IS DISTINCT FROM 'ocr-forms-raw-1'
       OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('contract_version','request_id','file','form_type','pages')) THEN
        RAISE EXCEPTION 'OCR_PAYLOAD_INVALID' USING ERRCODE='23514'; END IF;
    request:=(p_payload->>'request_id')::uuid;file:=p_payload->'file';form:=p_payload->>'form_type';
    IF request IS NULL OR form NOT IN ('STITCHING','INJECTION','ASSEMBLY','FINAL_INSPECTION') OR form IS NULL
       OR jsonb_typeof(file) IS DISTINCT FROM 'object'
       OR coalesce(file->>'sha256','') !~ '^[0-9a-f]{64}$'
       OR jsonb_typeof(file->'filename') IS DISTINCT FROM 'string' OR length(file->>'filename') NOT BETWEEN 1 AND 255
       OR jsonb_typeof(file->'size_bytes') IS DISTINCT FROM 'number' OR (file->>'size_bytes')::numeric NOT BETWEEN 1 AND 20971520
       OR (file->>'size_bytes')::numeric<>trunc((file->>'size_bytes')::numeric)
       OR jsonb_typeof(file->'page_count') IS DISTINCT FROM 'number' OR (file->>'page_count')::numeric NOT BETWEEN 1 AND 300
       OR (file->>'page_count')::numeric<>trunc((file->>'page_count')::numeric)
       OR EXISTS(SELECT 1 FROM jsonb_object_keys(file) k WHERE k NOT IN ('sha256','filename','size_bytes','page_count'))
       OR jsonb_typeof(p_payload->'pages') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'OCR_SOURCE_INVALID' USING ERRCODE='23514'; END IF;
    IF jsonb_array_length(p_payload->'pages') NOT BETWEEN 1 AND 10 THEN
        RAISE EXCEPTION 'OCR_PAGES_INVALID' USING ERRCODE='23514'; END IF;
    FOR page IN SELECT value FROM jsonb_array_elements(p_payload->'pages') LOOP
        IF jsonb_typeof(page) IS DISTINCT FROM 'object' OR jsonb_typeof(page->'page_number') IS DISTINCT FROM 'number'
           OR (page->>'page_number')::numeric NOT BETWEEN 1 AND (file->>'page_count')::integer
           OR (page->>'page_number')::numeric<>trunc((page->>'page_number')::numeric)
           OR jsonb_typeof(page->'pipeline_version') IS DISTINCT FROM 'string' OR length(page->>'pipeline_version') NOT BETWEEN 1 AND 100
           OR jsonb_typeof(page->'metadata') IS DISTINCT FROM 'object'
           OR jsonb_typeof(page->'metadata'->'form_type_reported') IS DISTINCT FROM 'string'
           OR page->'metadata'->>'form_type_reported' NOT IN (form,'UNKNOWN')
           OR jsonb_typeof(page->'metadata'->'uncertain') IS DISTINCT FROM 'boolean'
           OR (page->'metadata'->>'form_type_reported'='UNKNOWN' AND page->'metadata'->>'uncertain'<>'true')
           OR jsonb_typeof(page->'metadata'->'form_evidence') IS DISTINCT FROM 'string' OR length(page->'metadata'->>'form_evidence')>400
           OR EXISTS(SELECT 1 FROM jsonb_object_keys(page->'metadata') k WHERE k NOT IN ('form_type_reported','form_evidence','uncertain','form_version','coverage','issues',
                'region_version','regions','duplicate_candidates','boundary_review_required'))
           OR (page->'metadata' ? 'region_version' AND (jsonb_typeof(page->'metadata'->'region_version') IS DISTINCT FROM 'string'
                OR length(page->'metadata'->>'region_version') NOT BETWEEN 1 AND 100))
           OR (page->'metadata' ? 'regions' AND jsonb_typeof(page->'metadata'->'regions') IS DISTINCT FROM 'array')
           OR (page->'metadata' ? 'duplicate_candidates' AND jsonb_typeof(page->'metadata'->'duplicate_candidates') IS DISTINCT FROM 'array')
           OR (page->'metadata' ? 'boundary_review_required' AND jsonb_typeof(page->'metadata'->'boundary_review_required') IS DISTINCT FROM 'boolean')
           OR EXISTS(SELECT 1 FROM jsonb_object_keys(page) k WHERE k NOT IN ('page_number','pipeline_version','fields','metadata'))
           OR jsonb_typeof(page->'fields') IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'OCR_PAGE_INVALID' USING ERRCODE='23514'; END IF;
        IF jsonb_array_length(page->'fields') NOT BETWEEN 1 AND 1200 THEN
            RAISE EXCEPTION 'OCR_FIELDS_INVALID' USING ERRCODE='23514'; END IF;
        total:=total+jsonb_array_length(page->'fields');
        FOR item IN SELECT value FROM jsonb_array_elements(page->'fields') LOOP
            IF jsonb_typeof(item) IS DISTINCT FROM 'object'
               OR jsonb_typeof(item->'field_key') IS DISTINCT FROM 'string' OR length(item->>'field_key') NOT BETWEEN 1 AND 100
               OR jsonb_typeof(item->'field_label_raw') IS DISTINCT FROM 'string' OR length(item->>'field_label_raw')>500
               OR (item->>'cell_state'='RECORDED' AND coalesce(btrim(item->>'field_label_raw'),'')='')
               OR jsonb_typeof(item->'section') IS DISTINCT FROM 'string' OR length(item->>'section') NOT BETWEEN 1 AND 100
               OR NOT (item ? 'value_raw') OR jsonb_typeof(item->'value_raw') NOT IN ('null','string')
               OR length(item->>'value_raw')>2000 OR length(item->>'unit')>100
               OR coalesce(jsonb_typeof(item->'unit'),'null') NOT IN ('null','string')
               OR coalesce(jsonb_typeof(item->'source_region'),'null') NOT IN ('null','object')
               OR item->>'cell_state' NOT IN ('RECORDED','BLANK','UNREADABLE','UNCERTAIN','MISSING_SUSPECTED') OR item->>'cell_state' IS NULL
               OR item->>'shift' NOT IN ('DAY','NIGHT','UNKNOWN') OR item->>'shift' IS NULL
               OR (item->>'cell_state'='RECORDED' AND coalesce(btrim(item->>'value_raw'),'')='')
               OR (item->>'cell_state'='BLANK' AND coalesce(item->>'value_raw','')<>'')
               OR EXISTS(SELECT 1 FROM jsonb_object_keys(item) k WHERE k NOT IN ('field_key','field_label_raw','value_raw','unit','section','shift','cell_state','row_index','column_index','sequence','source_region','extra_field','origin','value_kind','review_status','review_reason','structure_review_codes')) THEN
                RAISE EXCEPTION 'OCR_FIELD_INVALID' USING ERRCODE='23514'; END IF;
            FOR n IN 1..3 LOOP
                IF coalesce(jsonb_typeof(item->(ARRAY['row_index','column_index','sequence'])[n]),'null')<>'null'
                   AND (jsonb_typeof(item->(ARRAY['row_index','column_index','sequence'])[n])<>'number'
                        OR (item->>(ARRAY['row_index','column_index','sequence'])[n])::numeric NOT BETWEEN 1 AND 10000
                        OR (item->>(ARRAY['row_index','column_index','sequence'])[n])::numeric<>trunc((item->>(ARRAY['row_index','column_index','sequence'])[n])::numeric)) THEN
                    RAISE EXCEPTION 'OCR_POSITION_INVALID' USING ERRCODE='23514'; END IF;
            END LOOP;
            IF jsonb_typeof(item->'source_region')='object' AND EXISTS(
                SELECT 1 FROM jsonb_object_keys(item->'source_region') k
                WHERE k NOT IN ('coordinate_system','bounds','status','location_status','width','height',
                               'region_id','input_crop_bounds','row_column_scope')
            ) THEN RAISE EXCEPTION 'OCR_REGION_METADATA_INVALID' USING ERRCODE='23514'; END IF;
            IF (item->'source_region' ? 'region_id' AND (jsonb_typeof(item->'source_region'->'region_id') IS DISTINCT FROM 'string'
                    OR length(item->'source_region'->>'region_id') NOT BETWEEN 1 AND 100))
               OR (item->'source_region' ? 'input_crop_bounds' AND jsonb_typeof(item->'source_region'->'input_crop_bounds') IS DISTINCT FROM 'array')
               OR (item->'source_region' ? 'row_column_scope' AND item->'source_region'->>'row_column_scope' IS DISTINCT FROM 'VISIBLE_CROP_TABLE') THEN
                RAISE EXCEPTION 'OCR_REGION_METADATA_INVALID' USING ERRCODE='23514'; END IF;
        END LOOP;
    END LOOP;
    IF total>1200 OR (SELECT count(DISTINCT value->>'page_number') FROM jsonb_array_elements(p_payload->'pages'))<>jsonb_array_length(p_payload->'pages') THEN
        RAISE EXCEPTION 'OCR_SCOPE_INVALID' USING ERRCODE='23514'; END IF;
    fingerprint:=encode(sha256(convert_to((p_payload-'request_id')::text,'UTF8')),'hex');
    PERFORM set_config('mqi.actor_ref',actor::text,true),set_config('mqi.change_reason','OCR_FORMS_UNREVIEWED_RAW_SAVE',true),set_config('mqi.request_id',request::text,true);
    PERFORM pg_advisory_xact_lock(hashtextextended('OCR_FORMS:'||actor::text,0));
    SELECT * INTO existing FROM mqi.source_ingest WHERE ingest_id=request;
    IF FOUND AND (existing.source_name IS DISTINCT FROM 'OCR_FORMS_MVP_V1' OR existing.importer_ref IS DISTINCT FROM actor::text
                  OR (CASE WHEN existing.source_name='OCR_FORMS_MVP_V1' THEN existing.remark::jsonb->>'payload_digest' END) IS DISTINCT FROM fingerprint) THEN
        RAISE EXCEPTION 'OCR_REQUEST_COLLISION' USING ERRCODE='23514'; END IF;
    IF NOT FOUND THEN
        SELECT * INTO existing FROM mqi.source_ingest WHERE source_name='OCR_FORMS_MVP_V1'
            AND importer_ref=actor::text AND (CASE WHEN source_name='OCR_FORMS_MVP_V1' THEN remark::jsonb->>'payload_digest' END)=fingerprint LIMIT 1;
    END IF;
    IF existing.ingest_id IS NOT NULL THEN
        RETURN jsonb_build_object('request_id',existing.ingest_id,'form_type',form,'file_sha256',file->>'sha256',
            'field_count',total,'validation_status','UNREVIEWED','source_retention','UNSTORED','reused',true);
    END IF;
    INSERT INTO mqi.source_ingest(ingest_id,source_name,ingest_method,started_at,completed_at,ingest_status,importer_ref,remark)
    VALUES(request,'OCR_FORMS_MVP_V1','MANUAL_IMPORT',stamp,stamp,'COMPLETED',actor::text,
           jsonb_build_object('payload_digest',fingerprint,'form_type',form,'filename',file->>'filename','file_sha256',file->>'sha256','field_count',total,'page_count',jsonb_array_length(p_payload->'pages'))::text);
    INSERT INTO mqi.source_bundle(ingest_id,bundle_name,bundle_type) VALUES(request,'OCR_FORMS_MVP_V1','OTHER') RETURNING source_bundle.bundle_id INTO bundle_id;
    SELECT * INTO asset FROM mqi.source_asset WHERE sha256_hash=file->>'sha256';
    IF asset.asset_id IS NOT NULL THEN
        IF asset.asset_type<>'PDF' OR asset.file_size_bytes<>(file->>'size_bytes')::bigint OR asset.record_state<>'ACTIVE'
           OR asset.storage_key IS DISTINCT FROM 'UNSTORED:sha256:'||(file->>'sha256') THEN
            RAISE EXCEPTION 'OCR_EXISTING_SOURCE_MISMATCH' USING ERRCODE='23514'; END IF;
    ELSE
        INSERT INTO mqi.source_asset(sha256_hash,asset_type,mime_type,file_size_bytes,storage_key)
        VALUES(file->>'sha256','PDF','application/pdf',(file->>'size_bytes')::bigint,'UNSTORED:sha256:'||(file->>'sha256')) RETURNING * INTO asset;
    END IF;
    INSERT INTO mqi.source_bundle_asset(bundle_id,asset_id,original_filename,relative_path,raw_metadata)
    VALUES(bundle_id,asset.asset_id,file->>'filename','upload-1',jsonb_build_object('marker','OCR_FORMS_MVP_V1','file',file,'source_retention','UNSTORED')) RETURNING bundle_asset_id INTO occurrence;
    INSERT INTO mqi.source_document(document_type,validation_status,remark)
    VALUES(CASE WHEN form='FINAL_INSPECTION' THEN 'INSPECTION_JOURNAL' ELSE 'PRODUCTION_JOURNAL' END,'NEEDS_REVIEW',
           jsonb_build_object('marker','OCR_FORMS_MVP_V1','form_type',form)::text) RETURNING document_id INTO doc;
    INSERT INTO mqi.source_document_version(document_id,asset_id,version_sequence,validation_status)
    VALUES(doc,asset.asset_id,1,'NEEDS_REVIEW') RETURNING document_version_id INTO ver;
    FOR page IN SELECT value FROM jsonb_array_elements(p_payload->'pages') LOOP
        v_page_number:=(page->>'page_number')::integer;
        SELECT source_page_id INTO page_id FROM mqi.source_page p WHERE p.asset_id=asset.asset_id AND p.page_number=v_page_number;
        IF page_id IS NULL THEN INSERT INTO mqi.source_page(asset_id,page_number) VALUES(asset.asset_id,v_page_number) RETURNING source_page_id INTO page_id; END IF;
        INSERT INTO mqi.extraction_run(bundle_asset_id,extraction_method,parser_version,started_at,completed_at,extraction_status,remark)
        VALUES(occurrence,'DOCUMENT_PARSER',page->>'pipeline_version',stamp,stamp,'COMPLETED',
               jsonb_build_object('marker','OCR_FORMS_MVP_V1','document_version_id',ver,'form_type',form,'page_number',v_page_number,'metadata',page->'metadata')::text) RETURNING extraction_run_id INTO run;
        FOR item IN SELECT value FROM jsonb_array_elements(page->'fields') LOOP
            INSERT INTO mqi.source_location(bundle_asset_id,asset_id,source_page_id,locator_type,remark)
            VALUES(occurrence,asset.asset_id,page_id,'PDF_PAGE',jsonb_build_object('section',item->'section','source_region',item->'source_region')::text) RETURNING source_location_id INTO location;
            INSERT INTO mqi.extracted_field(extraction_run_id,source_location_id,field_code,raw_value,extracted_value,validation_status,extracted_at,bundle_asset_id,current_review_id,remark)
            VALUES(run,location,item->>'field_key',item->>'value_raw',NULL,'UNREVIEWED',stamp,occurrence,NULL,jsonb_build_object('marker','OCR_FORMS_MVP_V1','record',item)::text);
        END LOOP;
    END LOOP;
    RETURN jsonb_build_object('request_id',request,'form_type',form,'file_sha256',file->>'sha256','field_count',total,
        'validation_status','UNREVIEWED','source_retention','UNSTORED','reused',false);
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS failure_state=RETURNED_SQLSTATE;
    RAISE EXCEPTION 'OCR_RAW_SAVE_REJECTED' USING ERRCODE=failure_state;
END $$;

CREATE FUNCTION mqi_ocr_forms_private.list_raw() RETURNS jsonb LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
    PERFORM mqi_ocr_forms_private.actor(false);
    RETURN coalesce((SELECT jsonb_agg(row) FROM (SELECT i.ingest_id AS request_id,i.recorded_at AS saved_at,
       i.remark::jsonb->>'filename' AS filename,i.remark::jsonb->>'form_type' AS form_type,
       (i.remark::jsonb->>'field_count')::integer AS field_count,'UNSTORED' AS source_retention
       FROM mqi.source_ingest i WHERE i.source_name='OCR_FORMS_MVP_V1' ORDER BY i.recorded_at DESC LIMIT 100) row),'[]'::jsonb);
END $$;

CREATE FUNCTION mqi_ocr_forms_private.detail_raw(p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE
SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
    PERFORM mqi_ocr_forms_private.actor(false);
    IF NOT EXISTS(SELECT 1 FROM mqi.source_ingest WHERE ingest_id=p_request_id AND source_name='OCR_FORMS_MVP_V1') THEN
        RAISE EXCEPTION 'OCR_REQUEST_NOT_FOUND' USING ERRCODE='42501'; END IF;
    RETURN coalesce((SELECT jsonb_agg(row ORDER BY row.page_number,row.extracted_field_id) FROM (
       SELECT f.extracted_field_id,f.extraction_run_id,p.page_number,f.field_code,f.raw_value,
              f.validation_status,'UNSTORED'::text AS source_retention,f.remark::jsonb->'record' AS record
       FROM mqi.source_bundle b JOIN mqi.source_bundle_asset ba ON ba.bundle_id=b.bundle_id
       JOIN mqi.extraction_run r ON r.bundle_asset_id=ba.bundle_asset_id
       JOIN mqi.extracted_field f ON f.extraction_run_id=r.extraction_run_id
       JOIN mqi.source_location l ON l.source_location_id=f.source_location_id
       JOIN mqi.source_page p ON p.source_page_id=l.source_page_id
       WHERE b.ingest_id=p_request_id) row),'[]'::jsonb);
END $$;

-- Temporary schema CREATE only to transfer function ownership, then revoke.
GRANT CREATE ON SCHEMA mqi_ocr_forms_private TO mqi_ocr_forms_writer,mqi_ocr_forms_reader;
-- Managed postgres is not a superuser: allow explicit ownership transfer only.
-- Never grant membership to application/authenticator roles.
GRANT mqi_ocr_forms_writer,mqi_ocr_forms_reader TO postgres WITH SET TRUE;
GRANT mqi_ocr_forms_writer,mqi_ocr_forms_reader TO postgres WITH INHERIT FALSE;
ALTER FUNCTION mqi_ocr_forms_private.save_raw(jsonb) OWNER TO mqi_ocr_forms_writer;
ALTER FUNCTION mqi_ocr_forms_private.list_raw() OWNER TO mqi_ocr_forms_reader;
ALTER FUNCTION mqi_ocr_forms_private.detail_raw(uuid) OWNER TO mqi_ocr_forms_reader;
REVOKE CREATE ON SCHEMA mqi_ocr_forms_private FROM mqi_ocr_forms_writer,mqi_ocr_forms_reader;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA mqi_ocr_forms_private FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION mqi_ocr_forms_private.actor(boolean) TO mqi_ocr_forms_writer,mqi_ocr_forms_reader;
-- Stage A deliberately leaves save_raw without authenticated EXECUTE.
GRANT EXECUTE ON FUNCTION mqi_ocr_forms_private.list_raw(),mqi_ocr_forms_private.detail_raw(uuid) TO authenticated;

CREATE FUNCTION public.mqi_ocr_forms_save(p_payload jsonb) RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path=pg_catalog SET default_transaction_isolation='serializable'
AS 'SELECT mqi_ocr_forms_private.save_raw(p_payload)';
CREATE FUNCTION public.mqi_ocr_forms_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
SET search_path=pg_catalog AS 'SELECT mqi_ocr_forms_private.list_raw()';
CREATE FUNCTION public.mqi_ocr_forms_detail(p_request_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER
SET search_path=pg_catalog AS 'SELECT mqi_ocr_forms_private.detail_raw(p_request_id)';
REVOKE ALL ON FUNCTION public.mqi_ocr_forms_save(jsonb),public.mqi_ocr_forms_list(),public.mqi_ocr_forms_detail(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.mqi_ocr_forms_list(),public.mqi_ocr_forms_detail(uuid) TO authenticated;
-- No application-role membership, authenticated DML grants, new tables, or review/business writes.
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
