-- ============================================================
-- MODIRA — 111_webhook_status_rbac.sql
-- ============================================================
--
-- OBJETIVO
--
-- Integrar stripe_webhook_events dentro del sistema RBAC.
--
-- Direction:
--   - Leer Webhook Status
--
-- Developer:
--   - Leer Webhook Status
--
-- Commercial:
--   - Sin acceso
--
-- Support:
--   - Sin acceso
--
-- Accounting:
--   - Sin acceso
--
-- IMPORTANTE:
--
-- stripe_webhook_events es una tabla interna de infraestructura.
--
-- Los webhooks son procesados por backend / service_role.
-- Los workers únicamente tendrán acceso de lectura al estado.
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. COMPROBACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- Tabla
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'stripe_webhook_events'
    ) THEN

        RAISE EXCEPTION
            '111 failed: public.stripe_webhook_events does not exist';

    END IF;


    -- --------------------------------------------------------
    -- Columnas fundamentales del estado
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'stripe_webhook_events'
          AND column_name = 'status'
    ) THEN

        RAISE EXCEPTION
            '111 failed: stripe_webhook_events.status is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'stripe_webhook_events'
          AND column_name = 'attempt_count'
    ) THEN

        RAISE EXCEPTION
            '111 failed: stripe_webhook_events.attempt_count is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'stripe_webhook_events'
          AND column_name = 'last_error'
    ) THEN

        RAISE EXCEPTION
            '111 failed: stripe_webhook_events.last_error is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'stripe_webhook_events'
          AND column_name = 'processed_at'
    ) THEN

        RAISE EXCEPTION
            '111 failed: stripe_webhook_events.processed_at is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'stripe_webhook_events'
          AND column_name = 'processing_started_at'
    ) THEN

        RAISE EXCEPTION
            '111 failed: stripe_webhook_events.processing_started_at is missing';

    END IF;


    -- --------------------------------------------------------
    -- RBAC
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_permissions'
    ) THEN

        RAISE EXCEPTION
            '111 failed: public.worker_permissions does not exist';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_worker_has_permission'
    ) THEN

        RAISE EXCEPTION
            '111 failed: current_worker_has_permission() does not exist';

    END IF;

END $$;


-- ============================================================
-- 2. ASEGURAR RLS
-- ============================================================
--
-- stripe_webhook_events es una tabla interna.
--
-- RLS debe estar habilitado para evitar que el acceso SQL
-- concedido a authenticated implique acceso automático a los
-- registros.
--
-- service_role seguirá pudiendo operar sobre la tabla.
--
-- ============================================================

ALTER TABLE public.stripe_webhook_events
ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 3. PERMISO RBAC
-- ============================================================
--
-- Solo lectura.
--
-- No creamos permisos create/update/delete para workers.
--
-- ============================================================

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
SELECT
    'system.webhooks.read',
    'system.webhooks',
    'read',
    'Permite consultar el estado interno de los webhooks de Stripe'
WHERE NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'system.webhooks.read'
);


-- ============================================================
-- 4. EVITAR COLISIÓN DE RESOURCE/ACTION
-- ============================================================

DO $$
DECLARE
    v_existing_code TEXT;
BEGIN

    SELECT code
    INTO v_existing_code
    FROM public.worker_permissions
    WHERE resource = 'system.webhooks'
      AND action = 'read'
      AND code <> 'system.webhooks.read'
    LIMIT 1;


    IF v_existing_code IS NOT NULL THEN

        RAISE EXCEPTION
            '111 failed: system.webhooks/read already exists with code %',
            v_existing_code;

    END IF;

END $$;


-- ============================================================
-- 5. ASIGNAR PERMISO A LOS ROLES CORRESPONDIENTES
-- ============================================================
--
-- Direction → Webhook Status
-- Developer → Webhook Status
--
-- El resto no recibe acceso.
--
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
CROSS JOIN public.worker_permissions p
WHERE r.code IN (
    'direction',
    'developer'
)
  AND p.code = 'system.webhooks.read'
ON CONFLICT DO NOTHING;


-- ============================================================
-- 6. ELIMINAR POLÍTICAS ANTIGUAS DE ACCESO DE WORKERS
-- ============================================================
--
-- Si existiese alguna política antigua que concediese acceso
-- a cualquier worker, se elimina para evitar el problema de
-- las políticas PERMISSIVE que se combinan mediante OR.
--
-- ============================================================

DROP POLICY IF EXISTS stripe_webhook_events_worker_select
ON public.stripe_webhook_events;

DROP POLICY IF EXISTS stripe_webhook_events_workers_select
ON public.stripe_webhook_events;

DROP POLICY IF EXISTS stripe_webhook_events_rbac_select
ON public.stripe_webhook_events;

DROP POLICY IF EXISTS stripe_webhook_events_no_client_access
ON public.stripe_webhook_events;


-- ============================================================
-- 7. NUEVA POLÍTICA RBAC DE LECTURA
-- ============================================================

CREATE POLICY stripe_webhook_events_rbac_select
ON public.stripe_webhook_events
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'system.webhooks.read'
    )
);


-- ============================================================
-- 8. PRIVILEGIOS DE AUTHENTICATED
-- ============================================================
--
-- authenticated puede ejecutar SELECT.
--
-- Pero NO puede modificar la infraestructura de webhooks.
--
-- ============================================================

REVOKE INSERT
ON public.stripe_webhook_events
FROM authenticated;

REVOKE UPDATE
ON public.stripe_webhook_events
FROM authenticated;

REVOKE DELETE
ON public.stripe_webhook_events
FROM authenticated;


GRANT SELECT
ON public.stripe_webhook_events
TO authenticated;


-- ============================================================
-- 9. GARANTIZAR ACCESO COMPLETO AL BACKEND
-- ============================================================
--
-- Stripe/webhooks se procesan mediante backend/service_role.
--
-- Esta parte es deliberadamente independiente del RBAC de
-- workers.
--
-- ============================================================

GRANT SELECT, INSERT, UPDATE
ON public.stripe_webhook_events
TO service_role;


-- ============================================================
-- 10. VERIFICACIÓN DE LA POLICY
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- La policy RBAC debe existir
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'stripe_webhook_events'
          AND policyname = 'stripe_webhook_events_rbac_select'
    ) THEN

        RAISE EXCEPTION
            '111 failed: stripe_webhook_events_rbac_select was not created';

    END IF;


    -- --------------------------------------------------------
    -- Las policies antiguas de worker no deben existir
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'stripe_webhook_events'
          AND policyname IN (
              'stripe_webhook_events_worker_select',
              'stripe_webhook_events_workers_select'
          )
    ) THEN

        RAISE EXCEPTION
            '111 failed: old worker SELECT policy still exists';

    END IF;


    -- --------------------------------------------------------
    -- Permiso RBAC
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'system.webhooks.read'
    ) THEN

        RAISE EXCEPTION
            '111 failed: system.webhooks.read permission missing';

    END IF;


    -- --------------------------------------------------------
    -- Direction
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'direction'
          AND wp.code = 'system.webhooks.read'
    ) THEN

        RAISE EXCEPTION
            '111 failed: direction missing system.webhooks.read';

    END IF;


    -- --------------------------------------------------------
    -- Developer
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'developer'
          AND wp.code = 'system.webhooks.read'
    ) THEN

        RAISE EXCEPTION
            '111 failed: developer missing system.webhooks.read';

    END IF;


    -- --------------------------------------------------------
    -- Commercial
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'commercial'
          AND wp.code = 'system.webhooks.read'
    ) THEN

        RAISE EXCEPTION
            '111 failed: commercial must not have system.webhooks.read';

    END IF;


    -- --------------------------------------------------------
    -- Support
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'support'
          AND wp.code = 'system.webhooks.read'
    ) THEN

        RAISE EXCEPTION
            '111 failed: support must not have system.webhooks.read';

    END IF;


    -- --------------------------------------------------------
    -- Accounting
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'accounting'
          AND wp.code = 'system.webhooks.read'
    ) THEN

        RAISE EXCEPTION
            '111 failed: accounting must not have system.webhooks.read';

    END IF;

END $$;


-- ============================================================
-- 11. VERIFICAR QUE AUTHENTICATED NO PUEDE ESCRIBIR
-- ============================================================

DO $$
BEGIN

    IF has_table_privilege(
        'authenticated',
        'public.stripe_webhook_events',
        'INSERT'
    ) THEN

        RAISE EXCEPTION
            '111 failed: authenticated still has INSERT';

    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.stripe_webhook_events',
        'UPDATE'
    ) THEN

        RAISE EXCEPTION
            '111 failed: authenticated still has UPDATE';

    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.stripe_webhook_events',
        'DELETE'
    ) THEN

        RAISE EXCEPTION
            '111 failed: authenticated still has DELETE';

    END IF;


    -- --------------------------------------------------------
    -- SELECT sí debe existir
    -- --------------------------------------------------------

    IF NOT has_table_privilege(
        'authenticated',
        'public.stripe_webhook_events',
        'SELECT'
    ) THEN

        RAISE EXCEPTION
            '111 failed: authenticated must have SELECT';

    END IF;

END $$;


-- ============================================================
-- 12. VERIFICAR SERVICE_ROLE
-- ============================================================

DO $$
BEGIN

    IF NOT has_table_privilege(
        'service_role',
        'public.stripe_webhook_events',
        'INSERT'
    ) THEN

        RAISE EXCEPTION
            '111 failed: service_role lost INSERT';

    END IF;


    IF NOT has_table_privilege(
        'service_role',
        'public.stripe_webhook_events',
        'UPDATE'
    ) THEN

        RAISE EXCEPTION
            '111 failed: service_role lost UPDATE';

    END IF;


    IF NOT has_table_privilege(
        'service_role',
        'public.stripe_webhook_events',
        'SELECT'
    ) THEN

        RAISE EXCEPTION
            '111 failed: service_role lost SELECT';

    END IF;

END $$;


-- ============================================================
-- 13. COMENTARIO
-- ============================================================

COMMENT ON POLICY stripe_webhook_events_rbac_select
ON public.stripe_webhook_events
IS
'RBAC: solo workers activos con system.webhooks.read pueden consultar el estado interno de los webhooks de Stripe.';


COMMIT;

