-- ============================================================
-- 100_quotations_rbac.sql
-- RBAC para lectura de presupuestos
-- Los INSERT/UPDATE/DELETE siguen gestionándose mediante RPCs.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
DECLARE
    v_missing TEXT[];
BEGIN

    -- Tabla quotations
    IF to_regclass('public.quotations') IS NULL THEN
        RAISE EXCEPTION
            '100 failed: public.quotations does not exist';
    END IF;

    -- RLS
    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'quotations'
          AND c.relrowsecurity = true
    ) THEN
        RAISE EXCEPTION
            '100 failed: RLS is not enabled on public.quotations';
    END IF;

    -- Función RBAC
    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '100 failed: public.current_worker_has_permission(text) is missing';
    END IF;

    -- Permisos necesarios
    SELECT ARRAY_AGG(x.permission_code)
    INTO v_missing
    FROM (
        VALUES
            ('quotations.read'),
            ('quotations.create'),
            ('quotations.update'),
            ('quotations.delete'),
            ('quotations.send')
    ) AS x(permission_code)
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions wp
        WHERE wp.code = x.permission_code
    );

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            '100 failed: missing quotation permissions: %',
            array_to_string(v_missing, ', ');
    END IF;

END $$;


-- ============================================================
-- 2. ELIMINAR POLÍTICAS ANTIGUAS DE WORKERS
-- ============================================================

DROP POLICY IF EXISTS quotations_worker_select
ON public.quotations;

DROP POLICY IF EXISTS quotations_worker_insert
ON public.quotations;

DROP POLICY IF EXISTS quotations_worker_update
ON public.quotations;

DROP POLICY IF EXISTS quotations_worker_delete
ON public.quotations;


-- ============================================================
-- 3. POLÍTICA RBAC DE LECTURA
--
-- Solo workers activos con quotations.read.
--
-- Las operaciones de escritura NO se habilitan aquí porque
-- quotations utiliza RPCs SECURITY DEFINER.
-- ============================================================

DROP POLICY IF EXISTS quotations_rbac_select
ON public.quotations;

CREATE POLICY quotations_rbac_select
ON public.quotations
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('quotations.read')
);


-- ============================================================
-- 4. ASEGURAR PRIVILEGIO DE LECTURA
-- ============================================================

GRANT SELECT
ON public.quotations
TO authenticated;


-- ============================================================
-- 5. VERIFICACIONES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Debe existir exactamente una política RBAC de SELECT
    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'quotations'
      AND policyname = 'quotations_rbac_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '100 failed: quotations_rbac_select was not created correctly';
    END IF;


    -- No deben quedar las políticas antiguas de worker
    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'quotations'
      AND policyname IN (
          'quotations_worker_select',
          'quotations_worker_insert',
          'quotations_worker_update',
          'quotations_worker_delete'
      );

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '100 failed: old quotation worker policies still exist';
    END IF;


    -- La política RBAC debe utilizar quotations.read
    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'quotations'
          AND policyname = 'quotations_rbac_select'
          AND qual::text LIKE '%quotations.read%'
    ) THEN
        RAISE EXCEPTION
            '100 failed: quotations_rbac_select does not enforce quotations.read';
    END IF;

END $$;


-- ============================================================
-- 6. VERIFICACIÓN DE ROLES DE QUOTATIONS
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Direction debe tener los 5 permisos
    SELECT COUNT(DISTINCT wrp.permission_id)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'direction'
      AND wp.code IN (
          'quotations.read',
          'quotations.create',
          'quotations.update',
          'quotations.delete',
          'quotations.send'
      );

    IF v_count <> 5 THEN
        RAISE EXCEPTION
            '100 failed: direction does not have all quotation permissions';
    END IF;


    -- Commercial debe tener los 5 permisos
    SELECT COUNT(DISTINCT wrp.permission_id)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'commercial'
      AND wp.code IN (
          'quotations.read',
          'quotations.create',
          'quotations.update',
          'quotations.delete',
          'quotations.send'
      );

    IF v_count <> 5 THEN
        RAISE EXCEPTION
            '100 failed: commercial does not have all quotation permissions';
    END IF;

END $$;
INSERT INTO public.worker_permissions
    (code, resource, action, description)
VALUES
    (
        'invoices.read',
        'invoices',
        'read',
        'Consultar facturas'
    ),
    (
        'invoices.create',
        'invoices',
        'create',
        'Crear facturas'
    ),
    (
        'invoices.update',
        'invoices',
        'update',
        'Modificar facturas'
    ),
    (
        'invoices.delete',
        'invoices',
        'delete',
        'Eliminar facturas'
    ),
    (
        'payments.read',
        'payments',
        'read',
        'Consultar pagos'
    )
ON CONFLICT (code) DO NOTHING;
INSERT INTO public.worker_role_permissions
    (role_id, permission_id)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
CROSS JOIN public.worker_permissions p
WHERE
    (
        r.code IN ('direction', 'accounting')
        AND p.code IN (
            'invoices.read',
            'invoices.create',
            'invoices.update',
            'invoices.delete',
            'payments.read'
        )
    )
    OR
    (
        r.code = 'commercial'
        AND p.code IN (
            'invoices.read',
            'payments.read'
        )
    )
ON CONFLICT DO NOTHING;
COMMIT;