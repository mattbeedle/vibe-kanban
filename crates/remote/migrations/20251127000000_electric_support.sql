-- Bootstrap Electric replication artefacts.
--
-- Each block tolerates two environments:
--   * Self-hosted Postgres (e.g., docker-compose), where the migration runs
--     as a superuser and is responsible for creating the role/grants.
--   * Managed Postgres (e.g., PlanetScale), where role creation is forbidden
--     for the application user; the replication role is provisioned out of
--     band and the migration must succeed without it.

-- Replication role for Electric. Skipped if it already exists or if the
-- connecting role lacks CREATEROLE.
DO $$
BEGIN
    CREATE ROLE electric_sync WITH LOGIN REPLICATION;
EXCEPTION
    WHEN duplicate_object THEN NULL;
    WHEN insufficient_privilege THEN NULL;
END
$$;

-- Connect/usage grants. Skipped if the role isn't present in this DB or the
-- connecting role can't grant on it.
DO $$
BEGIN
    EXECUTE format(
        'GRANT CONNECT ON DATABASE %I TO electric_sync',
        current_database()
    );
    GRANT USAGE ON SCHEMA public TO electric_sync;
EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN insufficient_privilege THEN NULL;
END
$$;

-- Publication used by Electric. Idempotent across re-runs.
DO $$
BEGIN
    CREATE PUBLICATION electric_publication_default;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

-- Helper to mark a table for Electric sync: REPLICA IDENTITY FULL, grant
-- SELECT to the replication role (if present), and add it to the
-- publication. The GRANT is best-effort so this works on managed Postgres
-- where the role is named differently or managed externally.
CREATE OR REPLACE FUNCTION electric_sync_table(p_schema text, p_table text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    qualified text := format('%I.%I', p_schema, p_table);
BEGIN
    EXECUTE format('ALTER TABLE %s REPLICA IDENTITY FULL', qualified);

    BEGIN
        EXECUTE format('GRANT SELECT ON TABLE %s TO electric_sync', qualified);
    EXCEPTION
        WHEN undefined_object THEN NULL;
        WHEN insufficient_privilege THEN NULL;
    END;

    EXECUTE format(
        'ALTER PUBLICATION %I ADD TABLE %s',
        'electric_publication_default',
        qualified
    );
END;
$$;

SELECT electric_sync_table('public', 'shared_tasks');
