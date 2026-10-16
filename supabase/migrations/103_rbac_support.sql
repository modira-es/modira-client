BEGIN;

-- ============================================================
-- 103 — RBAC SUPPORT / SUPPORT TICKETS
-- ============================================================


-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
BEGIN

    -- Tabla
    IF to_regclass('public.support_tickets') IS NULL THEN
        RAISE EXCEPTION
            '103 failed: missing table public.support_tickets';
    END IF;


    -- RLS
    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        WHERE c.oid = 'public.support_tickets'::regclass
          AND c.relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '103 failed: RLS is not enabled on public.support_tickets';
    END IF;


    -- RBAC
    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '103 failed: current_worker_has_permission(text) is missing';
    END IF;


    -- Permisos
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                ('support.read'),
                ('support.create'),
                ('support.update'),
                ('support.delete')
        ) AS required(code)
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.worker_permissions p
            WHERE p.code = required.code
        )
    ) THEN
        RAISE EXCEPTION
            '103 failed: one or more support permissions are missing';
    END IF;

END $$;


-- ============================================================
-- 2. ASIGNACIÓN DE PERMISOS
-- ============================================================


-- ------------------------------------------------------------
-- DIRECTION — CRUD completo
-- ------------------------------------------------------------

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
CROSS JOIN public.worker_permissions p
WHERE r.code = 'direction'
  AND p.code IN (
      'support.read',
      'support.create',
      'support.update',
      'support.delete'
  )
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- SUPPORT — CRUD completo
-- ------------------------------------------------------------

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
CROSS JOIN public.worker_permissions p
WHERE r.code = 'support'
  AND p.code IN (
      'support.read',
      'support.create',
      'support.update',
      'support.delete'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 3. SELECT
-- ============================================================

-- Elimina el acceso genérico:
-- current_user_is_worker()
--
-- Los clientes mantienen su policy independiente.

DROP POLICY IF EXISTS support_tickets_worker_select
ON public.support_tickets;


CREATE POLICY support_tickets_rbac_select
ON public.support_tickets
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'support.read'
    )
);


-- ============================================================
-- 4. INSERT
-- ============================================================

CREATE POLICY support_tickets_rbac_insert
ON public.support_tickets
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'support.create'
    )
);


-- ============================================================
-- 5. UPDATE
-- ============================================================

DROP POLICY IF EXISTS support_tickets_worker_update
ON public.support_tickets;


CREATE POLICY support_tickets_rbac_update
ON public.support_tickets
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'support.update'
    )
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'support.update'
    )
);


-- ============================================================
-- 6. DELETE
-- ============================================================

CREATE POLICY support_tickets_rbac_delete
ON public.support_tickets
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'support.delete'
    )
);


-- ============================================================
-- 7. PRIVILEGIOS DE TABLA
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.support_tickets
TO authenticated;


-- ============================================================
-- 8. VERIFICACIONES
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- Policies RBAC
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'support_tickets'
          AND policyname = 'support_tickets_rbac_select'
    ) THEN
        RAISE EXCEPTION
            '103 failed: support_tickets_rbac_select missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'support_tickets'
          AND policyname = 'support_tickets_rbac_insert'
    ) THEN
        RAISE EXCEPTION
            '103 failed: support_tickets_rbac_insert missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'support_tickets'
          AND policyname = 'support_tickets_rbac_update'
    ) THEN
        RAISE EXCEPTION
            '103 failed: support_tickets_rbac_update missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'support_tickets'
          AND policyname = 'support_tickets_rbac_delete'
    ) THEN
        RAISE EXCEPTION
            '103 failed: support_tickets_rbac_delete missing';
    END IF;


    -- --------------------------------------------------------
    -- Las policies genéricas de worker deben haber desaparecido
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'support_tickets'
          AND policyname IN (
              'support_tickets_worker_select',
              'support_tickets_worker_update'
          )
    ) THEN
        RAISE EXCEPTION
            '103 failed: old generic worker policies still exist';
    END IF;


    -- --------------------------------------------------------
    -- Direction
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'direction'
          AND p.code = 'support.delete'
    ) THEN
        RAISE EXCEPTION
            '103 failed: direction support permissions missing';
    END IF;


    -- --------------------------------------------------------
    -- Support
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'support'
          AND p.code = 'support.delete'
    ) THEN
        RAISE EXCEPTION
            '103 failed: support role permissions missing';
    END IF;

END $$;


COMMIT;