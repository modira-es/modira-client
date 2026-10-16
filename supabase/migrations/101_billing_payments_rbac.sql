-- ============================================================
-- MODIRA — 101 BILLING / PAYMENTS RBAC
-- ============================================================
--
-- OBJETIVO
--
-- Aplicar RBAC al módulo de facturación y pagos.
--
-- ROLES:
--
-- Direction:
--   invoices.read
--   invoices.create
--   invoices.update
--   invoices.delete
--   payments.read
--
-- Accounting:
--   invoices.read
--   invoices.create
--   invoices.update
--   invoices.delete
--   payments.read
--
-- Commercial:
--   invoices.read
--   payments.read
--
-- Developer:
--   sin acceso
--
-- Support:
--   sin acceso
--
-- IMPORTANTE:
--
-- payments NO recibe INSERT / UPDATE / DELETE para
-- authenticated.
--
-- Los pagos Stripe continúan siendo escritos exclusivamente
-- por backend / service_role mediante
-- register_stripe_invoice_payment().
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
DECLARE
    v_missing TEXT[];
BEGIN

    -- --------------------------------------------------------
    -- invoices
    -- --------------------------------------------------------

    IF to_regclass('public.invoices') IS NULL THEN
        RAISE EXCEPTION
            '101 failed: public.invoices does not exist';
    END IF;


    -- --------------------------------------------------------
    -- payments
    -- --------------------------------------------------------

    IF to_regclass('public.payments') IS NULL THEN
        RAISE EXCEPTION
            '101 failed: public.payments does not exist';
    END IF;


    -- --------------------------------------------------------
    -- RLS invoices
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'invoices'
          AND c.relrowsecurity = true
    ) THEN
        RAISE EXCEPTION
            '101 failed: RLS is not enabled on public.invoices';
    END IF;


    -- --------------------------------------------------------
    -- RLS payments
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'payments'
          AND c.relrowsecurity = true
    ) THEN
        RAISE EXCEPTION
            '101 failed: RLS is not enabled on public.payments';
    END IF;


    -- --------------------------------------------------------
    -- RBAC function
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '101 failed: public.current_worker_has_permission(text) is missing';
    END IF;


    -- --------------------------------------------------------
    -- Invoice permissions
    -- --------------------------------------------------------

    SELECT ARRAY_AGG(x.permission_code)
    INTO v_missing
    FROM (
        VALUES
            ('invoices.read'),
            ('invoices.create'),
            ('invoices.update'),
            ('invoices.delete'),
            ('payments.read')
    ) AS x(permission_code)
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions wp
        WHERE wp.code = x.permission_code
    );


    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            '101 failed: missing billing/payment permissions: %',
            array_to_string(v_missing, ', ');
    END IF;

END $$;


-- ============================================================
-- 2. INVOICES
-- ============================================================
--
-- Eliminamos las políticas worker antiguas porque las policies
-- PERMISSIVE se combinan mediante OR.
--
-- Si dejásemos invoices_worker_select, por ejemplo, cualquier
-- worker podría seguir leyendo facturas independientemente
-- de su rol.
-- ============================================================


DROP POLICY IF EXISTS invoices_worker_select
ON public.invoices;

DROP POLICY IF EXISTS invoices_worker_insert
ON public.invoices;

DROP POLICY IF EXISTS invoices_worker_update
ON public.invoices;

DROP POLICY IF EXISTS invoices_worker_delete
ON public.invoices;


-- ============================================================
-- 3. INVOICES — SELECT
-- ============================================================

DROP POLICY IF EXISTS invoices_rbac_select
ON public.invoices;

CREATE POLICY invoices_rbac_select
ON public.invoices
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('invoices.read')
);


-- ============================================================
-- 4. INVOICES — INSERT
-- ============================================================

DROP POLICY IF EXISTS invoices_rbac_insert
ON public.invoices;

CREATE POLICY invoices_rbac_insert
ON public.invoices
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('invoices.create')
);


-- ============================================================
-- 5. INVOICES — UPDATE
-- ============================================================

DROP POLICY IF EXISTS invoices_rbac_update
ON public.invoices;

CREATE POLICY invoices_rbac_update
ON public.invoices
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('invoices.update')
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('invoices.update')
);


-- ============================================================
-- 6. INVOICES — DELETE
-- ============================================================

DROP POLICY IF EXISTS invoices_rbac_delete
ON public.invoices;

CREATE POLICY invoices_rbac_delete
ON public.invoices
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('invoices.delete')
);


-- ============================================================
-- 7. INVOICES — PRIVILEGES
-- ============================================================
--
-- RLS decide qué filas puede utilizar cada worker.
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.invoices
TO authenticated;


-- ============================================================
-- 8. PAYMENTS
-- ============================================================
--
-- payments tiene una arquitectura diferente:
--
-- CLIENTE:
--   SELECT únicamente sus pagos.
--
-- WORKER:
--   SELECT únicamente con payments.read.
--
-- ESCRITURA:
--   exclusivamente backend / service_role.
--
-- No se crean policies INSERT / UPDATE / DELETE para
-- authenticated.
-- ============================================================


-- Eliminar cualquier policy worker antigua de lectura.

DROP POLICY IF EXISTS payments_worker_select
ON public.payments;


-- Eliminar cualquier policy RBAC anterior.

DROP POLICY IF EXISTS payments_rbac_select
ON public.payments;


-- ============================================================
-- 9. PAYMENTS — WORKER SELECT
-- ============================================================

CREATE POLICY payments_rbac_select
ON public.payments
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('payments.read')
);


-- ============================================================
-- 10. PAYMENTS — CLIENT SELECT
-- ============================================================
--
-- El cliente sigue pudiendo consultar únicamente sus pagos.
--
-- No es worker.
-- Su company_id debe coincidir con la empresa del usuario.
--
-- Si ya existe payments_client_select, se reemplaza para
-- garantizar que la policy final mantiene current_user_is_active.
-- ============================================================


DROP POLICY IF EXISTS payments_client_select
ON public.payments;


CREATE POLICY payments_client_select
ON public.payments
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


-- ============================================================
-- 11. PAYMENTS — PRIVILEGIOS
-- ============================================================
--
-- authenticated solamente necesita SELECT.
--
-- No se concede:
--
--   INSERT
--   UPDATE
--   DELETE
--
-- La escritura permanece en service_role.
-- ============================================================


REVOKE INSERT, UPDATE, DELETE
ON public.payments
FROM authenticated;


GRANT SELECT
ON public.payments
TO authenticated;


-- ============================================================
-- 12. GARANTIZAR QUE SERVICE_ROLE PUEDE ESCRIBIR PAYMENTS
-- ============================================================
--
-- La integración Stripe utiliza service_role.
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.payments
TO service_role;


-- ============================================================
-- 13. VERIFICACIONES DE POLICIES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- invoices: deben existir las 4 policies RBAC
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'invoices'
      AND policyname IN (
          'invoices_rbac_select',
          'invoices_rbac_insert',
          'invoices_rbac_update',
          'invoices_rbac_delete'
      );

    IF v_count <> 4 THEN
        RAISE EXCEPTION
            '101 failed: expected 4 invoices RBAC policies, found %',
            v_count;
    END IF;


    -- --------------------------------------------------------
    -- payments: debe existir RBAC SELECT
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'payments'
      AND policyname = 'payments_rbac_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '101 failed: payments_rbac_select was not created';
    END IF;


    -- --------------------------------------------------------
    -- payments: cliente mantiene SELECT
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'payments'
      AND policyname = 'payments_client_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '101 failed: payments_client_select was not created';
    END IF;


    -- --------------------------------------------------------
    -- No policies worker antiguas
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('invoices', 'payments')
      AND policyname IN (
          'invoices_worker_select',
          'invoices_worker_insert',
          'invoices_worker_update',
          'invoices_worker_delete',
          'payments_worker_select'
      );

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '101 failed: old worker policies still exist';
    END IF;

END $$;


-- ============================================================
-- 14. VERIFICAR ROLES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- ========================================================
    -- DIRECTION
    -- ========================================================

    SELECT COUNT(DISTINCT wrp.permission_id)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'direction'
      AND wp.code IN (
          'invoices.read',
          'invoices.create',
          'invoices.update',
          'invoices.delete',
          'payments.read'
      );

    IF v_count <> 5 THEN
        RAISE EXCEPTION
            '101 failed: direction does not have all billing/payment permissions';
    END IF;


    -- ========================================================
    -- ACCOUNTING
    -- ========================================================

    SELECT COUNT(DISTINCT wrp.permission_id)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'accounting'
      AND wp.code IN (
          'invoices.read',
          'invoices.create',
          'invoices.update',
          'invoices.delete',
          'payments.read'
      );

    IF v_count <> 5 THEN
        RAISE EXCEPTION
            '101 failed: accounting does not have all billing/payment permissions';
    END IF;


    -- ========================================================
    -- COMMERCIAL
    -- ========================================================

    SELECT COUNT(DISTINCT wrp.permission_id)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'commercial'
      AND wp.code IN (
          'invoices.read',
          'payments.read'
      );

    IF v_count <> 2 THEN
        RAISE EXCEPTION
            '101 failed: commercial does not have billing read permissions';
    END IF;


    -- ========================================================
    -- DEVELOPER
    -- ========================================================

    SELECT COUNT(*)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'developer'
      AND wp.code IN (
          'invoices.read',
          'invoices.create',
          'invoices.update',
          'invoices.delete',
          'payments.read'
      );

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '101 failed: developer unexpectedly has billing/payment permissions';
    END IF;


    -- ========================================================
    -- SUPPORT
    -- ========================================================

    SELECT COUNT(*)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'support'
      AND wp.code IN (
          'invoices.read',
          'invoices.create',
          'invoices.update',
          'invoices.delete',
          'payments.read'
      );

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '101 failed: support unexpectedly has billing/payment permissions';
    END IF;

END $$;


-- ============================================================
-- 15. VERIFICAR PRIVILEGIOS DE PAYMENTS
-- ============================================================

DO $$
DECLARE
    v_insert BOOLEAN;
    v_update BOOLEAN;
    v_delete BOOLEAN;
BEGIN

    SELECT
        has_table_privilege(
            'authenticated',
            'public.payments',
            'INSERT'
        ),
        has_table_privilege(
            'authenticated',
            'public.payments',
            'UPDATE'
        ),
        has_table_privilege(
            'authenticated',
            'public.payments',
            'DELETE'
        )
    INTO
        v_insert,
        v_update,
        v_delete;


    IF v_insert OR v_update OR v_delete THEN
        RAISE EXCEPTION
            '101 failed: authenticated still has direct write privileges on payments';
    END IF;

END $$;


-- ============================================================
-- 16. VERIFICAR PRIVILEGIOS DE INVOICES
-- ============================================================

DO $$
BEGIN

    IF NOT has_table_privilege(
        'authenticated',
        'public.invoices',
        'SELECT'
    ) THEN
        RAISE EXCEPTION
            '101 failed: authenticated lacks SELECT on invoices';
    END IF;


    IF NOT has_table_privilege(
        'authenticated',
        'public.invoices',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '101 failed: authenticated lacks INSERT on invoices';
    END IF;


    IF NOT has_table_privilege(
        'authenticated',
        'public.invoices',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '101 failed: authenticated lacks UPDATE on invoices';
    END IF;


    IF NOT has_table_privilege(
        'authenticated',
        'public.invoices',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '101 failed: authenticated lacks DELETE on invoices';
    END IF;

END $$;



COMMIT;