-- Approved Stage A read repair: replace actor only; preserve all owners and ACLs.
CREATE OR REPLACE FUNCTION mqi_ocr_forms_private.actor(p_write boolean) RETURNS uuid
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog AS $$
DECLARE
    claims jsonb:=coalesce(nullif(current_setting('request.jwt.claim',true),''),
                          nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb;
    actor uuid:=(claims->>'sub')::uuid;
BEGIN
    IF actor IS NULL OR claims->>'role' IS DISTINCT FROM 'authenticated'
       OR coalesce(claims->>'is_anonymous','false')<>'false'
       OR claims->'app_metadata'->>'mqi_ocr_viewer' IS DISTINCT FROM 'true'
       OR (p_write AND claims->'app_metadata'->>'mqi_ocr_uploader' IS DISTINCT FROM 'true') THEN
        RAISE EXCEPTION 'OCR_ACCESS_DENIED' USING ERRCODE='42501';
    END IF;
    RETURN actor;
END $$;
