-- Remove Electric sync for blobs and attachments (shapes are no longer used).
-- REVOKEs are wrapped to tolerate environments where the electric_sync role
-- isn't present (managed Postgres providers); the publication and replica
-- identity changes always run.

ALTER PUBLICATION electric_publication_default DROP TABLE public.blobs;
DO $$
BEGIN
    REVOKE SELECT ON TABLE public.blobs FROM electric_sync;
EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN insufficient_privilege THEN NULL;
END
$$;
ALTER TABLE public.blobs REPLICA IDENTITY DEFAULT;

ALTER PUBLICATION electric_publication_default DROP TABLE public.attachments;
DO $$
BEGIN
    REVOKE SELECT ON TABLE public.attachments FROM electric_sync;
EXCEPTION
    WHEN undefined_object THEN NULL;
    WHEN insufficient_privilege THEN NULL;
END
$$;
ALTER TABLE public.attachments REPLICA IDENTITY DEFAULT;
