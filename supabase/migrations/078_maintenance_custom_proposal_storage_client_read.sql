BEGIN;

-- ============================================================
-- MODIRA — CUSTOM MAINTENANCE PROPOSALS
-- STORAGE — CLIENT READ ACCESS
-- ============================================================
--
-- El bucket maintenance-proposals permanece PRIVADO.
--
-- El worker puede subir/asociar los PDFs mediante el flujo
-- backend existente.
--
-- El cliente NO obtiene INSERT / UPDATE / DELETE.
--
-- Solo puede leer:
--   1. PDFs del bucket maintenance-proposals
--   2. pertenecientes a una propuesta de su empresa
--   3. estando autenticado y activo
--   4. sin ser worker
--
-- El frontend continuará utilizando createSignedUrl().
-- ============================================================


-- ============================================================
-- 1. GARANTIZAR QUE EL BUCKET SIGUE SIENDO PRIVADO
-- ============================================================

INSERT INTO storage.buckets (
    id,
    name,
    public
)
VALUES (
    'maintenance-proposals',
    'maintenance-proposals',
    FALSE
)
ON CONFLICT (id)
DO UPDATE
SET public = FALSE;


-- ============================================================
-- 2. ELIMINAR POLICY ANTERIOR SI EXISTIERA
-- ============================================================

DROP POLICY IF EXISTS
    maintenance_custom_proposal_storage_client_select
ON storage.objects;


-- ============================================================
-- 3. CLIENTE — SOLO LECTURA
-- ============================================================

CREATE POLICY
    maintenance_custom_proposal_storage_client_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'maintenance-proposals'

    AND public.current_user_is_active()

    AND NOT public.current_user_is_worker()

    AND EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposal_documents d
        INNER JOIN public.maintenance_custom_proposals p
            ON p.id = d.proposal_id
        WHERE d.document_path = storage.objects.name
          AND p.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- 4. GARANTIZAR QUE authenticated NO RECIBE ESCRITURA
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON storage.objects
FROM authenticated;


-- ============================================================
-- 5. VALIDACIONES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Debe existir el bucket.
    SELECT COUNT(*)
    INTO v_count
    FROM storage.buckets
    WHERE id = 'maintenance-proposals'
      AND public = FALSE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '078 failed: maintenance-proposals debe existir y ser privado';
    END IF;


    -- Debe existir la policy de lectura del cliente.
    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname =
          'maintenance_custom_proposal_storage_client_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '078 failed: falta la policy de lectura del cliente';
    END IF;

END $$;


COMMIT;