BEGIN;

-- ============================================================
-- MODIRA — 047_quotations_storage_rls_fix.sql
--
-- OBJETIVO
-- ============================================================
-- Corrige exclusivamente el flujo de PDFs de presupuestos
-- después del endurecimiento 045/046.
--
-- El error "new row violates row-level security policy" se
-- producía al insertar el objeto en storage.objects porque la
-- policy intentaba consultar public.quotations directamente.
--
-- Esa comprobación no debe depender de la RLS de quotations.
-- La validación se encapsula en una función SECURITY DEFINER,
-- igual que el resto del modelo seguro de Modira.
--
-- FLUJO RESULTANTE:
--
-- Worker activo
--     ↓
-- Storage INSERT/UPDATE
--     ↓
-- worker_can_write_quotation_storage_path()
--     ↓
-- valida presupuesto + empresa + numero + ruta PDF
--     ↓
-- attach_quotation_document()
--     ↓
-- quotations.document_path
--
-- NO se devuelve ningún INSERT/UPDATE/DELETE directo sobre
-- public.quotations.
-- ============================================================

-- ============================================================
-- 1. FUNCIÓN SEGURA PARA VALIDAR RUTAS DE STORAGE
-- ============================================================

CREATE OR REPLACE FUNCTION public.worker_can_write_quotation_storage_path(
    p_storage_path TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
    v_allowed BOOLEAN := FALSE;
BEGIN
    -- Debe existir una sesión autenticada y ser worker activo.
    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RETURN FALSE;
    END IF;

    IF p_storage_path IS NULL THEN
        RETURN FALSE;
    END IF;

    -- La ruta debe ser exactamente:
    -- <company_uuid>/<numero_presupuesto>.pdf
    -- No permitimos subdirectorios ni extensiones distintas.
    IF p_storage_path !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[^/]+\.pdf$' THEN
        RETURN FALSE;
    END IF;

    -- La ruta solo es válida si corresponde exactamente a un
    -- presupuesto existente. Al ejecutarse como SECURITY DEFINER,
    -- esta comprobación no queda bloqueada por la RLS de quotations.
    SELECT EXISTS (
        SELECT 1
        FROM public.quotations q
        WHERE (
            q.company_id::TEXT
            || '/'
            || q.numero_presupuesto
            || '.pdf'
        ) = p_storage_path
    )
    INTO v_allowed;

    RETURN COALESCE(v_allowed, FALSE);
END;
$function$;

REVOKE ALL ON FUNCTION public.worker_can_write_quotation_storage_path(TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.worker_can_write_quotation_storage_path(TEXT)
TO authenticated;

ALTER FUNCTION public.worker_can_write_quotation_storage_path(TEXT)
SET search_path = pg_catalog, public, pg_temp;

-- ============================================================
-- 2. STORAGE — WORKER SELECT
-- ============================================================

DROP POLICY IF EXISTS quotation_documents_worker_select
ON storage.objects;

CREATE POLICY quotation_documents_worker_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'quotations'
    AND public.worker_can_write_quotation_storage_path(name)
);

-- ============================================================
-- 3. STORAGE — WORKER INSERT
-- ============================================================

DROP POLICY IF EXISTS quotation_documents_worker_insert
ON storage.objects;

CREATE POLICY quotation_documents_worker_insert
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'quotations'
    AND public.worker_can_write_quotation_storage_path(name)
);

-- ============================================================
-- 4. STORAGE — WORKER UPDATE
-- ============================================================

DROP POLICY IF EXISTS quotation_documents_worker_update
ON storage.objects;

CREATE POLICY quotation_documents_worker_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (
    bucket_id = 'quotations'
    AND public.worker_can_write_quotation_storage_path(name)
)
WITH CHECK (
    bucket_id = 'quotations'
    AND public.worker_can_write_quotation_storage_path(name)
);

-- ============================================================
-- 5. STORAGE — WORKER DELETE
-- ============================================================

DROP POLICY IF EXISTS quotation_documents_worker_delete
ON storage.objects;

CREATE POLICY quotation_documents_worker_delete
ON storage.objects
FOR DELETE
TO authenticated
USING (
    bucket_id = 'quotations'
    AND public.worker_can_write_quotation_storage_path(name)
);

-- ============================================================
-- 6. GARANTÍA: NO REABRIR ESCRITURA DIRECTA EN QUOTATIONS
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON public.quotations
FROM anon, authenticated;

GRANT SELECT
ON public.quotations
TO authenticated;

-- ============================================================
-- 7. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
    v_policy_count INTEGER;
BEGIN
    -- La función debe existir.
    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'worker_can_write_quotation_storage_path'
      AND pg_get_function_identity_arguments(p.oid) = 'p_storage_path text';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '047 failed: worker_can_write_quotation_storage_path() is missing';
    END IF;

    -- Deben existir las cuatro policies del worker.
    SELECT COUNT(*)
    INTO v_policy_count
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname IN (
          'quotation_documents_worker_select',
          'quotation_documents_worker_insert',
          'quotation_documents_worker_update',
          'quotation_documents_worker_delete'
      );

    IF v_policy_count <> 4 THEN
        RAISE EXCEPTION
            '047 failed: quotation Storage worker policies are incomplete';
    END IF;

    -- authenticated NO debe recuperar escritura directa sobre quotations.
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.table_privileges
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND grantee = 'authenticated'
      AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE');

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '047 failed: authenticated has direct write privilege on quotations';
    END IF;
END $$;

COMMIT;
