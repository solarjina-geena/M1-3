-- M3-1 team-wide PostgreSQL read-only access (51 existing business/audit tables).
-- Scope: four pre-existing named LOGIN roles, mqi 50 tables, mqi_audit 1 table.
-- Intentionally NOT a Supabase Data API grant to anon/authenticated.
-- This migration must be reviewed/merged before any remote deployment.
-- Existing base migrations, audit history, OCR writes and public DEMO RPC are unchanged.
-- DO NOT include PostgreSQL passwords, service_role, or original factory files here.

DO $preflight$
DECLARE
    table_count integer;
BEGIN
    SELECT count(*) INTO table_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('mqi', 'mqi_audit')
      AND c.relkind IN ('r', 'p');

    IF table_count <> 51 THEN
        RAISE EXCEPTION 'Expected 51 existing mqi/mqi_audit tables, found %', table_count;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('mqi', 'mqi_audit')
          AND c.relkind IN ('r', 'p')
          AND NOT c.relrowsecurity
    ) THEN
        RAISE EXCEPTION 'Every shared table must have RLS enabled';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM (VALUES
            ('mqi_team_jina'),
            ('mqi_team_ingyu'),
            ('mqi_team_chungkwan'),
            ('mqi_team_sukyung')
        ) AS expected(role_name)
        LEFT JOIN pg_roles r ON r.rolname = expected.role_name
        WHERE r.oid IS NULL OR NOT r.rolcanlogin OR NOT r.rolinherit
           OR r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolbypassrls
    ) THEN
        RAISE EXCEPTION 'One of the four named team roles is missing or unexpectedly privileged';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mqi_team_readonly') THEN
        RAISE EXCEPTION 'mqi_team_readonly already exists; review before reapplying';
    END IF;
END
$preflight$;

CREATE ROLE mqi_team_readonly
    NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS INHERIT;

GRANT USAGE ON SCHEMA mqi, mqi_audit TO mqi_team_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA mqi, mqi_audit TO mqi_team_readonly;

-- Deliberately no INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER,
-- CREATE or sequence privileges.
GRANT mqi_team_readonly TO
    mqi_team_jina, mqi_team_ingyu, mqi_team_chungkwan, mqi_team_sukyung;

-- RLS still applies to non-owner PostgreSQL team logins.
-- Only these four named roles inherit the group policy; the public/anon
-- DEMO reader and Supabase API 'authenticated' role do not.
DO $policies$
DECLARE
    t record;
BEGIN
    FOR t IN
        SELECT n.nspname AS schema_name, c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('mqi', 'mqi_audit')
          AND c.relkind IN ('r', 'p')
        ORDER BY n.nspname, c.relname
    LOOP
        EXECUTE format(
            'CREATE POLICY mqi_team_readonly_select ON %I.%I AS PERMISSIVE FOR SELECT TO mqi_team_readonly USING (true)',
            t.schema_name, t.table_name
        );
    END LOOP;
END
$policies$;

DO $postflight$
DECLARE
    readable integer;
    policy_count integer;
BEGIN
    SELECT count(*) INTO readable
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('mqi', 'mqi_audit')
      AND c.relkind IN ('r', 'p')
      AND has_table_privilege('mqi_team_readonly', c.oid, 'SELECT');

    SELECT count(*) INTO policy_count
    FROM pg_policies
    WHERE schemaname IN ('mqi', 'mqi_audit')
      AND policyname = 'mqi_team_readonly_select'
      AND cmd = 'SELECT';

    IF readable <> 51 OR policy_count <> 51 THEN
        RAISE EXCEPTION 'Read-only privilege/policy coverage mismatch: tables %, policies %', readable, policy_count;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('mqi', 'mqi_audit')
          AND c.relkind IN ('r', 'p')
          AND (
            has_table_privilege('mqi_team_readonly', c.oid, 'INSERT')
            OR has_table_privilege('mqi_team_readonly', c.oid, 'UPDATE')
            OR has_table_privilege('mqi_team_readonly', c.oid, 'DELETE')
            OR has_table_privilege('mqi_team_readonly', c.oid, 'TRUNCATE')
          )
    ) THEN
        RAISE EXCEPTION 'Team read-only role unexpectedly has write privileges';
    END IF;
END
$postflight$;

-- New tables added in later migrations require an explicit SELECT grant and
-- role-specific SELECT RLS policy after data-classification review.
-- This migration does not expose all 51 tables over Supabase Data API.
