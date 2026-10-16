-- ============================================================
-- MODIRA — 107_storage_rbac_hardening.sql
-- ============================================================
--
-- OBJETIVO
-- Aplicar RBAC al acceso de WORKERS sobre Storage sin romper
-- las políticas existentes de validación de rutas/documentos.
--
-- IMPORTANTE:
-- - NO elimina las políticas actuales de Storage.
-- - NO modifica la lógica client_select.
-- - NO concede permisos de Storage por sí sola.
-- - Añade políticas RESTRICTIVE que actúan como segunda barrera.
--
-- Un worker necesitará:
--
-- quotations:
--   read   -> quotations.read
--   insert -> quotations.create
--   update -> quotations.update
--   delete -> quotations.delete
--
-- invoices:
--   read   -> invoices.read
--   insert -> invoices.create
--   update -> invoices.update
--   delete -> invoices.delete
--
-- project-documents:
--   read   -> projects.read
--   insert -> projects.create
--   update -> projects.update
--   delete -> projects.delete
--
-- maintenance-proposals:
--   read   -> maintenance_proposals.read
--   insert -> maintenance_proposals.create
--   update -> maintenance_proposals.update
--   delete -> maintenance_proposals.delete
--
-- maintenance-invoices:
--   read   -> maintenance.read
--   insert -> maintenance.create
--   update -> maintenance.update
--   delete -> maintenance.delete
--
-- ============================================================

BEGIN;


-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
BEGIN

    -- RBAC principal
    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '107 failed: current_worker_has_permission(text) no existe';
    END IF;


    -- Buckets obligatorios
    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'quotations'
    ) THEN
        RAISE EXCEPTION
            '107 failed: bucket quotations no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'invoices'
    ) THEN
        RAISE EXCEPTION
            '107 failed: bucket invoices no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'project-documents'
    ) THEN
        RAISE EXCEPTION
            '107 failed: bucket project-documents no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'maintenance-proposals'
    ) THEN
        RAISE EXCEPTION
            '107 failed: bucket maintenance-proposals no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'maintenance-invoices'
    ) THEN
        RAISE EXCEPTION
            '107 failed: bucket maintenance-invoices no existe';
    END IF;


    -- ========================================================
    -- Permisos quotations
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'quotations.read'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'quotations.create'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'quotations.update'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'quotations.delete'
    ) THEN
        RAISE EXCEPTION
            '107 failed: faltan permisos quotations.*';
    END IF;


    -- ========================================================
    -- Permisos invoices
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'invoices.read'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'invoices.create'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'invoices.update'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'invoices.delete'
    ) THEN
        RAISE EXCEPTION
            '107 failed: faltan permisos invoices.*';
    END IF;


    -- ========================================================
    -- Permisos projects
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'projects.read'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'projects.create'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'projects.update'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'projects.delete'
    ) THEN
        RAISE EXCEPTION
            '107 failed: faltan permisos projects.*';
    END IF;


    -- ========================================================
    -- Permisos maintenance
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance.read'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance.create'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance.update'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance.delete'
    ) THEN
        RAISE EXCEPTION
            '107 failed: faltan permisos maintenance.*';
    END IF;


    -- ========================================================
    -- Permisos maintenance proposals
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance_proposals.read'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance_proposals.create'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance_proposals.update'
    )
    OR NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance_proposals.delete'
    ) THEN
        RAISE EXCEPTION
            '107 failed: faltan permisos maintenance_proposals.*';
    END IF;

END $$;


-- ============================================================
-- 2. ASEGURAR QUE LOS BUCKETS SIGUEN SIENDO PRIVADOS
-- ============================================================

UPDATE storage.buckets
SET public = FALSE
WHERE id IN (
    'quotations',
    'invoices',
    'project-documents',
    'maintenance-proposals',
    'maintenance-invoices'
);


-- ============================================================
-- 3. QUOTATIONS
-- ============================================================

DROP POLICY IF EXISTS quotations_storage_rbac_select
ON storage.objects;

CREATE POLICY quotations_storage_rbac_select
ON storage.objects
AS RESTRICTIVE
FOR SELECT
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('quotations.read')
);


DROP POLICY IF EXISTS quotations_storage_rbac_insert
ON storage.objects;

CREATE POLICY quotations_storage_rbac_insert
ON storage.objects
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('quotations.create')
);


DROP POLICY IF EXISTS quotations_storage_rbac_update
ON storage.objects;

CREATE POLICY quotations_storage_rbac_update
ON storage.objects
AS RESTRICTIVE
FOR UPDATE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('quotations.update')
)
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('quotations.update')
);


DROP POLICY IF EXISTS quotations_storage_rbac_delete
ON storage.objects;

CREATE POLICY quotations_storage_rbac_delete
ON storage.objects
AS RESTRICTIVE
FOR DELETE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('quotations.delete')
);


-- ============================================================
-- 4. INVOICES
-- ============================================================

DROP POLICY IF EXISTS invoices_storage_rbac_select
ON storage.objects;

CREATE POLICY invoices_storage_rbac_select
ON storage.objects
AS RESTRICTIVE
FOR SELECT
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('invoices.read')
);


DROP POLICY IF EXISTS invoices_storage_rbac_insert
ON storage.objects;

CREATE POLICY invoices_storage_rbac_insert
ON storage.objects
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('invoices.create')
);


DROP POLICY IF EXISTS invoices_storage_rbac_update
ON storage.objects;

CREATE POLICY invoices_storage_rbac_update
ON storage.objects
AS RESTRICTIVE
FOR UPDATE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('invoices.update')
)
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('invoices.update')
);


DROP POLICY IF EXISTS invoices_storage_rbac_delete
ON storage.objects;

CREATE POLICY invoices_storage_rbac_delete
ON storage.objects
AS RESTRICTIVE
FOR DELETE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('invoices.delete')
);


-- ============================================================
-- 5. PROJECT DOCUMENTS
-- ============================================================

DROP POLICY IF EXISTS project_documents_storage_rbac_select
ON storage.objects;

CREATE POLICY project_documents_storage_rbac_select
ON storage.objects
AS RESTRICTIVE
FOR SELECT
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('projects.read')
);


DROP POLICY IF EXISTS project_documents_storage_rbac_insert
ON storage.objects;

CREATE POLICY project_documents_storage_rbac_insert
ON storage.objects
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('projects.create')
);


DROP POLICY IF EXISTS project_documents_storage_rbac_update
ON storage.objects;

CREATE POLICY project_documents_storage_rbac_update
ON storage.objects
AS RESTRICTIVE
FOR UPDATE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('projects.update')
)
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('projects.update')
);


DROP POLICY IF EXISTS project_documents_storage_rbac_delete
ON storage.objects;

CREATE POLICY project_documents_storage_rbac_delete
ON storage.objects
AS RESTRICTIVE
FOR DELETE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission('projects.delete')
);


-- ============================================================
-- 6. MAINTENANCE PROPOSALS
-- ============================================================

DROP POLICY IF EXISTS maintenance_proposals_storage_rbac_select
ON storage.objects;

CREATE POLICY maintenance_proposals_storage_rbac_select
ON storage.objects
AS RESTRICTIVE
FOR SELECT
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance_proposals.read'
    )
);


DROP POLICY IF EXISTS maintenance_proposals_storage_rbac_insert
ON storage.objects;

CREATE POLICY maintenance_proposals_storage_rbac_insert
ON storage.objects
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance_proposals.create'
    )
);


DROP POLICY IF EXISTS maintenance_proposals_storage_rbac_update
ON storage.objects;

CREATE POLICY maintenance_proposals_storage_rbac_update
ON storage.objects
AS RESTRICTIVE
FOR UPDATE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance_proposals.update'
    )
)
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance_proposals.update'
    )
);


DROP POLICY IF EXISTS maintenance_proposals_storage_rbac_delete
ON storage.objects;

CREATE POLICY maintenance_proposals_storage_rbac_delete
ON storage.objects
AS RESTRICTIVE
FOR DELETE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance_proposals.delete'
    )
);


-- ============================================================
-- 7. MAINTENANCE INVOICES
-- ============================================================

DROP POLICY IF EXISTS maintenance_invoices_storage_rbac_select
ON storage.objects;

CREATE POLICY maintenance_invoices_storage_rbac_select
ON storage.objects
AS RESTRICTIVE
FOR SELECT
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance.read'
    )
);


DROP POLICY IF EXISTS maintenance_invoices_storage_rbac_insert
ON storage.objects;

CREATE POLICY maintenance_invoices_storage_rbac_insert
ON storage.objects
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance.create'
    )
);


DROP POLICY IF EXISTS maintenance_invoices_storage_rbac_update
ON storage.objects;

CREATE POLICY maintenance_invoices_storage_rbac_update
ON storage.objects
AS RESTRICTIVE
FOR UPDATE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance.update'
    )
)
WITH CHECK (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance.update'
    )
);


DROP POLICY IF EXISTS maintenance_invoices_storage_rbac_delete
ON storage.objects;

CREATE POLICY maintenance_invoices_storage_rbac_delete
ON storage.objects
AS RESTRICTIVE
FOR DELETE
TO authenticated
USING (
    NOT public.current_user_is_worker()
    OR public.current_worker_has_permission(
        'maintenance.delete'
    )
);


-- ============================================================
-- 8. VALIDACIÓN FINAL
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Deben existir 20 políticas RBAC:
    -- 5 buckets × 4 operaciones
    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname IN (
          'quotations_storage_rbac_select',
          'quotations_storage_rbac_insert',
          'quotations_storage_rbac_update',
          'quotations_storage_rbac_delete',

          'invoices_storage_rbac_select',
          'invoices_storage_rbac_insert',
          'invoices_storage_rbac_update',
          'invoices_storage_rbac_delete',

          'project_documents_storage_rbac_select',
          'project_documents_storage_rbac_insert',
          'project_documents_storage_rbac_update',
          'project_documents_storage_rbac_delete',

          'maintenance_proposals_storage_rbac_select',
          'maintenance_proposals_storage_rbac_insert',
          'maintenance_proposals_storage_rbac_update',
          'maintenance_proposals_storage_rbac_delete',

          'maintenance_invoices_storage_rbac_select',
          'maintenance_invoices_storage_rbac_insert',
          'maintenance_invoices_storage_rbac_update',
          'maintenance_invoices_storage_rbac_delete'
      );

    IF v_count <> 20 THEN
        RAISE EXCEPTION
            '107 failed: se esperaban 20 políticas Storage RBAC y existen %',
            v_count;
    END IF;


    -- Todos los buckets deben seguir privados
    IF EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id IN (
            'quotations',
            'invoices',
            'project-documents',
            'maintenance-proposals',
            'maintenance-invoices'
        )
        AND public = TRUE
    ) THEN
        RAISE EXCEPTION
            '107 failed: existe un bucket protegido que ha quedado público';
    END IF;

END $$;


COMMIT;