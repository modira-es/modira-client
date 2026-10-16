-- ============================================================
-- 104_budgets_rbac.sql
-- ============================================================
-- RBAC PARA PRESUPUESTOS INTERNOS (budgets)
--
-- Objetivo:
--   Sustituir el acceso genérico de workers a budgets por
--   permisos RBAC explícitos.
--
-- Roles:
--   direction:
--      budgets.read
--      budgets.create
--      budgets.update
--      budgets.delete
--
--   commercial:
--      budgets.read
--      budgets.create
--      budgets.update
--      budgets.delete
--
--   accounting:
--      budgets.read
--
--   developer:
--      sin acceso
--
--   support:
--      sin acceso
--
-- Los clientes mantienen:
--   budgets_company_access
--
-- NO modifica:
--   quotations
--   invoices
--   payments
--   proyectos
-- ============================================================


BEGIN;


-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- budgets
    -- --------------------------------------------------------

    IF to_regclass('public.budgets') IS NULL THEN
        RAISE EXCEPTION
            '104 failed: public.budgets does not exist';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        WHERE c.oid = 'public.budgets'::regclass
          AND c.relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '104 failed: RLS is not enabled on public.budgets';
    END IF;


    -- --------------------------------------------------------
    -- RBAC helper
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '104 failed: current_worker_has_permission(text) is missing';
    END IF;


    -- --------------------------------------------------------
    -- Roles
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'direction'
    ) THEN
        RAISE EXCEPTION
            '104 failed: role direction is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'commercial'
    ) THEN
        RAISE EXCEPTION
            '104 failed: role commercial is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'accounting'
    ) THEN
        RAISE EXCEPTION
            '104 failed: role accounting is missing';
    END IF;


END;
$$;


-- ============================================================
-- 2. CREAR PERMISOS budgets.*
-- ============================================================

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
VALUES
(
    'budgets.read',
    'budgets',
    'read',
    'Consultar presupuestos'
),
(
    'budgets.create',
    'budgets',
    'create',
    'Crear presupuestos'
),
(
    'budgets.update',
    'budgets',
    'update',
    'Modificar presupuestos'
),
(
    'budgets.delete',
    'budgets',
    'delete',
    'Eliminar presupuestos'
)
ON CONFLICT (resource, action)
DO UPDATE
SET
    code = EXCLUDED.code,
    description = EXCLUDED.description;


-- ============================================================
-- 3. VERIFICAR PERMISOS CREADOS
-- ============================================================

DO $$
DECLARE
    v_missing TEXT;
BEGIN

    SELECT string_agg(required_code, ', ')
    INTO v_missing
    FROM (
        VALUES
            ('budgets.read'),
            ('budgets.create'),
            ('budgets.update'),
            ('budgets.delete')
    ) AS required(required_code)
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions wp
        WHERE wp.code = required.required_code
    );


    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            '104 failed: missing budget permissions: %',
            v_missing;
    END IF;

END;
$$;


-- ============================================================
-- 4. ASIGNAR PERMISOS A DIRECTION
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    wr.id,
    wp.id
FROM public.worker_roles wr
CROSS JOIN public.worker_permissions wp
WHERE wr.code = 'direction'
  AND wp.code IN (
      'budgets.read',
      'budgets.create',
      'budgets.update',
      'budgets.delete'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 5. ASIGNAR PERMISOS A COMMERCIAL
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    wr.id,
    wp.id
FROM public.worker_roles wr
CROSS JOIN public.worker_permissions wp
WHERE wr.code = 'commercial'
  AND wp.code IN (
      'budgets.read',
      'budgets.create',
      'budgets.update',
      'budgets.delete'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 6. ASIGNAR SOLO LECTURA A ACCOUNTING
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    wr.id,
    wp.id
FROM public.worker_roles wr
CROSS JOIN public.worker_permissions wp
WHERE wr.code = 'accounting'
  AND wp.code = 'budgets.read'
ON CONFLICT DO NOTHING;


-- ============================================================
-- 7. POLÍTICA SELECT PARA WORKERS
-- ============================================================

DROP POLICY IF EXISTS budgets_rbac_select
ON public.budgets;


CREATE POLICY budgets_rbac_select
ON public.budgets
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('budgets.read')
);


-- ============================================================
-- 8. POLÍTICA INSERT PARA WORKERS
-- ============================================================

DROP POLICY IF EXISTS budgets_rbac_insert
ON public.budgets;


CREATE POLICY budgets_rbac_insert
ON public.budgets
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('budgets.create')
);


-- ============================================================
-- 9. POLÍTICA UPDATE PARA WORKERS
-- ============================================================

DROP POLICY IF EXISTS budgets_rbac_update
ON public.budgets;


CREATE POLICY budgets_rbac_update
ON public.budgets
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('budgets.update')
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('budgets.update')
);


-- ============================================================
-- 10. POLÍTICA DELETE PARA WORKERS
-- ============================================================

DROP POLICY IF EXISTS budgets_rbac_delete
ON public.budgets;


CREATE POLICY budgets_rbac_delete
ON public.budgets
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('budgets.delete')
);


-- ============================================================
-- 11. GARANTIZAR PRIVILEGIOS DE TABLA
-- ============================================================
--
-- Actualmente authenticated ya dispone de:
--   SELECT
--   INSERT
--   UPDATE
--   DELETE
--
-- Los mantenemos explícitamente para que RLS sea quien
-- determine qué worker puede realizar cada operación.
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.budgets
TO authenticated;


-- ============================================================
-- 12. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_policy_count INTEGER;
    v_assignment_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Deben existir las 4 políticas RBAC
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'budgets'
      AND policyname IN (
          'budgets_rbac_select',
          'budgets_rbac_insert',
          'budgets_rbac_update',
          'budgets_rbac_delete'
      );


    IF v_policy_count <> 4 THEN
        RAISE EXCEPTION
            '104 failed: expected 4 budgets RBAC policies, found %',
            v_policy_count;
    END IF;


    -- --------------------------------------------------------
    -- Direction: 4 permisos
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_assignment_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
        ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
        ON wp.id = wrp.permission_id
    WHERE wr.code = 'direction'
      AND wp.code IN (
          'budgets.read',
          'budgets.create',
          'budgets.update',
          'budgets.delete'
      );


    IF v_assignment_count <> 4 THEN
        RAISE EXCEPTION
            '104 failed: direction should have 4 budget permissions, found %',
            v_assignment_count;
    END IF;


    -- --------------------------------------------------------
    -- Commercial: 4 permisos
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_assignment_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
        ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
        ON wp.id = wrp.permission_id
    WHERE wr.code = 'commercial'
      AND wp.code IN (
          'budgets.read',
          'budgets.create',
          'budgets.update',
          'budgets.delete'
      );


    IF v_assignment_count <> 4 THEN
        RAISE EXCEPTION
            '104 failed: commercial should have 4 budget permissions, found %',
            v_assignment_count;
    END IF;


    -- --------------------------------------------------------
    -- Accounting: solamente read
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_assignment_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
        ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
        ON wp.id = wrp.permission_id
    WHERE wr.code = 'accounting'
      AND wp.code = 'budgets.read';


    IF v_assignment_count <> 1 THEN
        RAISE EXCEPTION
            '104 failed: accounting should have budgets.read';
    END IF;


    -- --------------------------------------------------------
    -- Accounting NO debe tener create/update/delete
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
            ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
            ON wp.id = wrp.permission_id
        WHERE wr.code = 'accounting'
          AND wp.code IN (
              'budgets.create',
              'budgets.update',
              'budgets.delete'
          )
    ) THEN

        RAISE EXCEPTION
            '104 failed: accounting has forbidden budget write permissions';

    END IF;


END;
$$;


-- ============================================================
-- 13. VERIFICACIÓN DE ACCESO DEL CLIENTE
-- ============================================================
--
-- La política original budgets_company_access debe continuar
-- existiendo para los clientes.
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'budgets'
          AND policyname = 'budgets_company_access'
    ) THEN

        RAISE EXCEPTION
            '104 failed: budgets_company_access is missing';

    END IF;

END;
$$;


-- ============================================================
-- 14. RESULTADO FINAL
-- ============================================================

SELECT
    wr.code AS role,
    wp.code AS permission
FROM public.worker_role_permissions wrp
JOIN public.worker_roles wr
    ON wr.id = wrp.role_id
JOIN public.worker_permissions wp
    ON wp.id = wrp.permission_id
WHERE wp.resource = 'budgets'
ORDER BY
    wr.code,
    wp.action;


COMMIT;
