-- ============================================================
-- MODIRA — 112_rbac_final_hardening.sql
-- ============================================================
--
-- OBJETIVO
--
-- Cierre de seguridad del sistema RBAC de trabajadores.
--
-- Esta migración NO crea nuevos módulos funcionales.
--
-- Comprueba y endurece:
--
--   1. Workers activos/inactivos
--   2. Permisos RBAC
--   3. Roles
--   4. Tablas internas RBAC
--   5. Profiles
--   6. Activity / Error Logs
--   7. Stripe Webhook Status
--   8. Storage privado
--   9. Permisos SQL de authenticated
--  10. SECURITY DEFINER
--  11. search_path seguro
--  12. Ausencia de políticas worker genéricas críticas
--
-- NO modifica la lógica de negocio existente.
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. COMPROBACIONES BASE
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- workers
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    ) THEN

        RAISE EXCEPTION
            '112 failed: public.workers does not exist';

    END IF;


    -- --------------------------------------------------------
    -- RBAC
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_roles'
    ) THEN

        RAISE EXCEPTION
            '112 failed: public.worker_roles does not exist';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_permissions'
    ) THEN

        RAISE EXCEPTION
            '112 failed: public.worker_permissions does not exist';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_role_permissions'
    ) THEN

        RAISE EXCEPTION
            '112 failed: public.worker_role_permissions does not exist';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_role_assignments'
    ) THEN

        RAISE EXCEPTION
            '112 failed: public.worker_role_assignments does not exist';

    END IF;


    -- --------------------------------------------------------
    -- Contexto RBAC
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_worker_has_permission'
    ) THEN

        RAISE EXCEPTION
            '112 failed: current_worker_has_permission() missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
    ) THEN

        RAISE EXCEPTION
            '112 failed: current_user_is_worker() missing';

    END IF;


END $$;


-- ============================================================
-- 2. ASEGURAR QUE LAS TABLAS INTERNAS RBAC NO SON DIRECTAMENTE
--    MODIFICABLES POR authenticated
-- ============================================================

REVOKE ALL
ON public.worker_roles
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON public.worker_permissions
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON public.worker_role_permissions
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON public.worker_role_assignments
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 3. ASEGURAR RLS EN TABLAS RBAC
-- ============================================================

ALTER TABLE public.worker_roles
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.worker_permissions
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.worker_role_permissions
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.worker_role_assignments
ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 4. PROTEGER WORKERS
-- ============================================================
--
-- Un worker no debe modificar directamente:
--
--   display_name
--   is_active
--   auth_user_id
--
-- La gestión debe realizarse mediante las funciones
-- administrativas correspondientes.
--
-- ============================================================

REVOKE INSERT
ON public.workers
FROM authenticated;

REVOKE UPDATE
ON public.workers
FROM authenticated;

REVOKE DELETE
ON public.workers
FROM authenticated;


-- ============================================================
-- 5. PROTEGER PROFILES
-- ============================================================
--
-- El usuario normal conserva su propio flujo.
--
-- Los workers NO reciben UPDATE directo sobre profiles.
--
-- Los cambios administrativos se realizan mediante RPC.
--
-- ============================================================

REVOKE UPDATE
ON public.profiles
FROM authenticated;


-- ============================================================
-- 6. GARANTIZAR QUE LAS FUNCIONES RBAC SON SECURITY DEFINER
-- ============================================================

DO $$
DECLARE
    v_function TEXT;
    v_count INTEGER;
BEGIN

    FOREACH v_function IN ARRAY ARRAY[
        'current_worker_has_permission',
        'current_worker_has_any_permission',
        'current_worker_has_all_permissions',
        'get_current_worker_permissions',
        'assign_worker_role',
        'remove_worker_role',
        'replace_worker_roles',
        'get_worker_roles',
        'get_all_worker_role_assignments'
    ]
    LOOP

        SELECT COUNT(*)
        INTO v_count
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = v_function
          AND p.prosecdef = TRUE;


        IF v_count = 0 THEN

            RAISE EXCEPTION
                '112 failed: RBAC function % is not SECURITY DEFINER',
                v_function;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 7. SEARCH_PATH SEGURO EN FUNCIONES RBAC
-- ============================================================

DO $$
DECLARE
    v_function TEXT;
    v_oid OID;
    v_config TEXT[];
BEGIN

    FOREACH v_function IN ARRAY ARRAY[
        'current_worker_has_permission',
        'current_worker_has_any_permission',
        'current_worker_has_all_permissions',
        'get_current_worker_permissions',
        'assign_worker_role',
        'remove_worker_role',
        'replace_worker_roles',
        'get_worker_roles',
        'get_all_worker_role_assignments'
    ]
    LOOP

        SELECT p.oid, p.proconfig
        INTO v_oid, v_config
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = v_function
        LIMIT 1;


        IF v_oid IS NULL THEN

            RAISE EXCEPTION
                '112 failed: function % not found',
                v_function;

        END IF;


        IF v_config IS NULL
           OR NOT EXISTS (
               SELECT 1
               FROM unnest(v_config) AS cfg
               WHERE cfg = 'search_path=public, pg_temp'
                  OR cfg = 'search_path=public,pg_temp'
           )
        THEN

            RAISE EXCEPTION
                '112 failed: function % does not have safe search_path',
                v_function;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 8. ASEGURAR QUE UN WORKER INACTIVO NO PUEDE USAR RBAC
-- ============================================================
--
-- No cambiamos current_user_is_worker().
--
-- Solo verificamos que su lógica siga dependiendo de workers
-- activos.
--
-- ============================================================

DO $$
DECLARE
    v_definition TEXT;
BEGIN

    SELECT pg_get_functiondef(p.oid)
    INTO v_definition
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_user_is_worker'
    LIMIT 1;


    IF v_definition IS NULL THEN

        RAISE EXCEPTION
            '112 failed: current_user_is_worker definition unavailable';

    END IF;


    IF POSITION('is_active' IN LOWER(v_definition)) = 0 THEN

        RAISE EXCEPTION
            '112 failed: current_user_is_worker does not verify worker activity';

    END IF;

END $$;


-- ============================================================
-- 9. STORAGE — TODOS LOS BUCKETS SENSIBLES DEBEN SER PRIVADOS
-- ============================================================

DO $$
DECLARE
    v_bucket TEXT;
    v_public BOOLEAN;
BEGIN

    FOREACH v_bucket IN ARRAY ARRAY[
        'invoices',
        'quotations',
        'project-documents',
        'maintenance-proposals',
        'maintenance-invoices'
    ]
    LOOP

        SELECT b.public
        INTO v_public
        FROM storage.buckets b
        WHERE b.id = v_bucket;


        IF v_public IS NULL THEN

            RAISE EXCEPTION
                '112 failed: storage bucket % does not exist',
                v_bucket;

        END IF;


        IF v_public = TRUE THEN

            RAISE EXCEPTION
                '112 failed: storage bucket % must be private',
                v_bucket;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 10. ACTIVITY LOG — SOLO LECTURA CONTROLADA
-- ============================================================

DO $$
BEGIN

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'activity_log'
          AND policyname = 'activity_log_worker_select'
    ) THEN

        RAISE EXCEPTION
            '112 failed: generic activity_log worker policy still exists';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'activity_log'
          AND policyname = 'activity_log_rbac_select'
    ) THEN

        RAISE EXCEPTION
            '112 failed: activity_log_rbac_select missing';

    END IF;

END $$;


-- ============================================================
-- 11. WEBHOOK STATUS — SOLO LECTURA RBAC
-- ============================================================

DO $$
BEGIN

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
            '112 failed: generic webhook worker policy still exists';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'stripe_webhook_events'
          AND policyname = 'stripe_webhook_events_rbac_select'
    ) THEN

        RAISE EXCEPTION
            '112 failed: stripe_webhook_events_rbac_select missing';

    END IF;

END $$;


-- ============================================================
-- 12. COMPROBAR QUE NO QUEDAN POLÍTICAS WORKER GENÉRICAS
--    EN LOS MÓDULOS RBAC PRINCIPALES
-- ============================================================
--
-- Una política que simplemente diga:
--
--     current_user_is_worker()
--
-- puede saltarse todo el RBAC porque las políticas
-- PERMISSIVE se combinan mediante OR.
--
-- Buscamos las políticas worker antiguas conocidas.
--
-- ============================================================

DO $$
DECLARE
    v_policy RECORD;
BEGIN

    FOR v_policy IN
        SELECT schemaname, tablename, policyname
        FROM pg_policies
        WHERE schemaname = 'public'
          AND policyname IN (
              -- Clients / Companies
              'clients_worker_select',
              'clients_worker_insert',
              'clients_worker_update',
              'clients_worker_delete',
              'companies_worker_select',
              'companies_worker_insert',
              'companies_worker_update',
              'companies_worker_delete',

              -- Quotations
              'quotations_worker_select',
              'quotations_worker_insert',
              'quotations_worker_update',
              'quotations_worker_delete',

              -- Invoices
              'invoices_worker_select',
              'invoices_worker_insert',
              'invoices_worker_update',
              'invoices_worker_delete',

              -- Payments
              'payments_worker_select',

              -- Projects
              'projects_worker_select',
              'projects_worker_insert',
              'projects_worker_update',
              'projects_worker_delete',

              -- Project milestones
              'project_milestones_worker_select',
              'project_milestones_worker_insert',
              'project_milestones_worker_update',
              'project_milestones_worker_delete',

              -- Project updates
              'project_updates_worker_select',
              'project_updates_worker_insert',
              'project_updates_worker_update',
              'project_updates_worker_delete',

              -- Support
              'support_tickets_worker_select',
              'support_tickets_worker_insert',
              'support_tickets_worker_update',
              'support_tickets_worker_delete',

              -- Maintenance
              'maintenance_contracts_worker_select',
              'maintenance_plans_worker_select',
              'maintenance_contract_projects_worker_select',
              'maintenance_contract_automations_worker_select',
              'maintenance_invoices_worker_select',
              'maintenance_project_change_requests_worker_select',
              'maintenance_iva_change_requests_worker_select',
              'maintenance_iva_requests_worker_select',

              -- Proposals
              'maintenance_custom_proposals_worker_select',
              'maintenance_custom_proposal_documents_worker_select',
              'maintenance_custom_proposal_events_worker_select',
              'maintenance_custom_proposal_ack_worker_select'
          )
    LOOP

        RAISE EXCEPTION
            '112 failed: legacy generic worker policy remains: %.%',
            v_policy.tablename,
            v_policy.policyname;

    END LOOP;

END $$;


-- ============================================================
-- 13. COMPROBAR PERMISOS FUNDAMENTALES DEL SISTEMA
-- ============================================================

DO $$
DECLARE
    v_code TEXT;
BEGIN

    FOREACH v_code IN ARRAY ARRAY[
        'system.error_logs.read',
        'system.webhooks.read',
        'system.workers.read',
        'system.workers.manage'
    ]
    LOOP

        IF NOT EXISTS (
            SELECT 1
            FROM public.worker_permissions
            WHERE code = v_code
        ) THEN

            RAISE EXCEPTION
                '112 failed: required system permission missing: %',
                v_code;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 14. COMPROBAR PERMISOS DE DIRECTION
-- ============================================================

DO $$
DECLARE
    v_code TEXT;
BEGIN

    FOREACH v_code IN ARRAY ARRAY[
        'system.error_logs.read',
        'system.webhooks.read',
        'system.workers.read',
        'system.workers.manage'
    ]
    LOOP

        IF NOT EXISTS (
            SELECT 1
            FROM public.worker_role_permissions wrp
            JOIN public.worker_roles wr
              ON wr.id = wrp.role_id
            JOIN public.worker_permissions wp
              ON wp.id = wrp.permission_id
            WHERE wr.code = 'direction'
              AND wp.code = v_code
        ) THEN

            RAISE EXCEPTION
                '112 failed: direction missing permission %',
                v_code;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 15. COMPROBAR PERMISOS DE DEVELOPER
-- ============================================================
--
-- Developer debe poder utilizar:
--
--   Projects
--   Project milestones
--   Project updates
--   Error Logs
--   Webhook Status
--
-- ============================================================

DO $$
DECLARE
    v_code TEXT;
BEGIN

    FOREACH v_code IN ARRAY ARRAY[
        'projects.read',
        'projects.create',
        'projects.update',
        'projects.delete',

        'project_milestones.read',
        'project_milestones.create',
        'project_milestones.update',
        'project_milestones.delete',

        'project_updates.read',
        'project_updates.create',
        'project_updates.update',
        'project_updates.delete',

        'system.error_logs.read',
        'system.webhooks.read'
    ]
    LOOP

        IF NOT EXISTS (
            SELECT 1
            FROM public.worker_role_permissions wrp
            JOIN public.worker_roles wr
              ON wr.id = wrp.role_id
            JOIN public.worker_permissions wp
              ON wp.id = wrp.permission_id
            WHERE wr.code = 'developer'
              AND wp.code = v_code
        ) THEN

            RAISE EXCEPTION
                '112 failed: developer missing permission %',
                v_code;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 16. COMPROBAR QUE LOS ROLES NO RECIBEN PERMISOS DE OTRO
--    ÁREA DE FORMA ACCIDENTAL
-- ============================================================
--
-- No hacemos una lista exhaustiva aquí porque Direction tiene
-- acceso transversal por definición.
--
-- Comprobamos especialmente las áreas internas:
--
-- Commercial / Support / Accounting NO deben recibir:
--
--   system.error_logs.read
--   system.webhooks.read
--
-- ============================================================

DO $$
DECLARE
    v_role TEXT;
BEGIN

    FOREACH v_role IN ARRAY ARRAY[
        'commercial',
        'support',
        'accounting'
    ]
    LOOP

        IF EXISTS (
            SELECT 1
            FROM public.worker_role_permissions wrp
            JOIN public.worker_roles wr
              ON wr.id = wrp.role_id
            JOIN public.worker_permissions wp
              ON wp.id = wrp.permission_id
            WHERE wr.code = v_role
              AND wp.code IN (
                  'system.error_logs.read',
                  'system.webhooks.read'
              )
        ) THEN

            RAISE EXCEPTION
                '112 failed: role % has internal infrastructure permissions',
                v_role;

        END IF;

    END LOOP;

END $$;


-- ============================================================
-- 17. PROTEGER TABLAS DE INFRAESTRUCTURA
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON public.activity_log
FROM authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.stripe_webhook_events
FROM authenticated;


-- ============================================================
-- 18. GARANTIZAR RLS EN TABLAS INTERNAS
-- ============================================================

ALTER TABLE public.activity_log
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.stripe_webhook_events
ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 19. COMPROBACIÓN DE PRIVILEGIOS DIRECTOS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- activity_log
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'INSERT'
    ) THEN

        RAISE EXCEPTION
            '112 failed: authenticated has INSERT on activity_log';

    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'UPDATE'
    ) THEN

        RAISE EXCEPTION
            '112 failed: authenticated has UPDATE on activity_log';

    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'DELETE'
    ) THEN

        RAISE EXCEPTION
            '112 failed: authenticated has DELETE on activity_log';

    END IF;


    -- --------------------------------------------------------
    -- webhook
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.stripe_webhook_events',
        'INSERT'
    ) THEN

        RAISE EXCEPTION
            '112 failed: authenticated has INSERT on stripe_webhook_events';

    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.stripe_webhook_events',
        'UPDATE'
    ) THEN

        RAISE EXCEPTION
            '112 failed: authenticated has UPDATE on stripe_webhook_events';

    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.stripe_webhook_events',
        'DELETE'
    ) THEN

        RAISE EXCEPTION
            '112 failed: authenticated has DELETE on stripe_webhook_events';

    END IF;

END $$;


-- ============================================================
-- 20. VERIFICACIÓN FINAL DE STORAGE
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM storage.buckets
    WHERE id IN (
        'invoices',
        'quotations',
        'project-documents',
        'maintenance-proposals',
        'maintenance-invoices'
    )
      AND public = TRUE;


    IF v_count <> 0 THEN

        RAISE EXCEPTION
            '112 failed: one or more sensitive storage buckets are public';

    END IF;

END $$;


-- ============================================================
-- 21. COMENTARIOS DE AUDITORÍA
-- ============================================================

COMMENT ON TABLE public.worker_roles
IS
'RBAC roles for Modira workers. Direct authenticated access is prohibited; use protected RBAC RPCs.';

COMMENT ON TABLE public.worker_permissions
IS
'RBAC permissions for Modira workers. Direct authenticated access is prohibited.';

COMMENT ON TABLE public.worker_role_permissions
IS
'RBAC role-permission mapping. Direct authenticated access is prohibited.';

COMMENT ON TABLE public.worker_role_assignments
IS
'RBAC worker-role assignments. Direct authenticated access is prohibited.';


-- ============================================================
-- 22. COMMIT
-- ============================================================

COMMIT;

