-- ============================================================
-- MODIRA — 110_error_logs_rbac.sql
-- ============================================================
--
-- OBJETIVO
--
-- Integrar el acceso a los registros de actividad/error dentro
-- del sistema RBAC de workers.
--
-- Direction:
--   - Leer Error Logs
--
-- Developer:
--   - Leer Error Logs
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
-- activity_log ya existe y es el sistema de historial/actividad
-- de Modira.
--
-- Esta migración NO crea otra tabla de logs.
-- Solo sustituye el acceso genérico de workers por RBAC.
--
-- No se conceden INSERT / UPDATE / DELETE directos a workers.
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. COMPROBACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- activity_log
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'activity_log'
    ) THEN

        RAISE EXCEPTION
            '110 failed: public.activity_log does not exist';

    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'activity_log'
          AND c.relrowsecurity = TRUE
    ) THEN

        RAISE EXCEPTION
            '110 failed: RLS is not enabled on public.activity_log';

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
            '110 failed: public.worker_permissions does not exist';

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
            '110 failed: current_worker_has_permission() does not exist';

    END IF;


END $$;


-- ============================================================
-- 2. PERMISO RBAC
-- ============================================================
--
-- Se utiliza un permiso exclusivamente de lectura.
--
-- No se crea un permiso de escritura porque activity_log es
-- un historial interno y los workers no deben poder modificar
-- ni borrar registros manualmente.
--
-- ============================================================

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
SELECT
    'system.error_logs.read',
    'system.error_logs',
    'read',
    'Permite consultar los registros internos de actividad y errores de Modira'
WHERE NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'system.error_logs.read'
);


-- ============================================================
-- 3. EVITAR COLISIÓN DE RESOURCE/ACTION
-- ============================================================

DO $$
DECLARE
    v_existing_code TEXT;
BEGIN

    SELECT code
    INTO v_existing_code
    FROM public.worker_permissions
    WHERE resource = 'system.error_logs'
      AND action = 'read'
      AND code <> 'system.error_logs.read'
    LIMIT 1;


    IF v_existing_code IS NOT NULL THEN

        RAISE EXCEPTION
            '110 failed: system.error_logs/read already exists with code %',
            v_existing_code;

    END IF;

END $$;


-- ============================================================
-- 4. ASIGNACIÓN A ROLES
-- ============================================================
--
-- Direction → lectura
-- Developer → lectura
--
-- El resto no recibe este permiso.
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
  AND p.code = 'system.error_logs.read'
ON CONFLICT DO NOTHING;


-- ============================================================
-- 5. ELIMINAR ACCESO GENÉRICO DE WORKERS
-- ============================================================
--
-- La política antigua permitía:
--
--     current_user_is_worker()
--
-- Eso significa que cualquier worker podía consultar
-- activity_log independientemente de su rol.
--
-- Se elimina porque ahora el acceso debe depender de RBAC.
--
-- ============================================================

DROP POLICY IF EXISTS activity_log_worker_select
ON public.activity_log;


-- Por seguridad, también eliminamos posibles variantes
-- antiguas de la misma política si existieran.

DROP POLICY IF EXISTS activity_log_workers_select
ON public.activity_log;

DROP POLICY IF EXISTS activity_log_rbac_select
ON public.activity_log;


-- ============================================================
-- 6. NUEVA POLÍTICA RBAC
-- ============================================================

CREATE POLICY activity_log_rbac_select
ON public.activity_log
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'system.error_logs.read'
    )
);


-- ============================================================
-- 7. NO DAR ESCRITURA DIRECTA A WORKERS
-- ============================================================
--
-- activity_log es un historial.
--
-- Los registros deben generarse mediante las funciones internas
-- de Modira, triggers o backend.
--
-- El frontend de trabajadores solo obtiene SELECT.
--
-- ============================================================

REVOKE INSERT
ON public.activity_log
FROM authenticated;

REVOKE UPDATE
ON public.activity_log
FROM authenticated;

REVOKE DELETE
ON public.activity_log
FROM authenticated;


-- ============================================================
-- 8. GARANTIZAR SELECT PARA AUTHENTICATED
-- ============================================================
--
-- La autorización real se realiza mediante RLS.
--
-- Esto no concede acceso por sí solo porque activity_log
-- continúa protegido mediante las policies.
--
-- ============================================================

GRANT SELECT
ON public.activity_log
TO authenticated;


-- ============================================================
-- 9. VERIFICACIONES DE POLÍTICAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- La política antigua no debe existir
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'activity_log'
          AND policyname = 'activity_log_worker_select'
    ) THEN

        RAISE EXCEPTION
            '110 failed: activity_log_worker_select still exists';

    END IF;


    -- --------------------------------------------------------
    -- La nueva política debe existir
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'activity_log'
          AND policyname = 'activity_log_rbac_select'
    ) THEN

        RAISE EXCEPTION
            '110 failed: activity_log_rbac_select was not created';

    END IF;


    -- --------------------------------------------------------
    -- Permiso
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'system.error_logs.read'
    ) THEN

        RAISE EXCEPTION
            '110 failed: system.error_logs.read permission missing';

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
          AND wp.code = 'system.error_logs.read'
    ) THEN

        RAISE EXCEPTION
            '110 failed: direction missing system.error_logs.read';

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
          AND wp.code = 'system.error_logs.read'
    ) THEN

        RAISE EXCEPTION
            '110 failed: developer missing system.error_logs.read';

    END IF;


    -- --------------------------------------------------------
    -- Commercial NO debe tener permiso
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'commercial'
          AND wp.code = 'system.error_logs.read'
    ) THEN

        RAISE EXCEPTION
            '110 failed: commercial must not have system.error_logs.read';

    END IF;


    -- --------------------------------------------------------
    -- Support NO debe tener permiso
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'support'
          AND wp.code = 'system.error_logs.read'
    ) THEN

        RAISE EXCEPTION
            '110 failed: support must not have system.error_logs.read';

    END IF;


    -- --------------------------------------------------------
    -- Accounting NO debe tener permiso
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'accounting'
          AND wp.code = 'system.error_logs.read'
    ) THEN

        RAISE EXCEPTION
            '110 failed: accounting must not have system.error_logs.read';

    END IF;

END $$;


-- ============================================================
-- 10. VERIFICAR QUE NO HAYA ESCRITURA DIRECTA
-- ============================================================

DO $$
BEGIN

    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'INSERT'
    ) THEN

        RAISE EXCEPTION
            '110 failed: authenticated still has INSERT on activity_log';

    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'UPDATE'
    ) THEN

        RAISE EXCEPTION
            '110 failed: authenticated still has UPDATE on activity_log';

    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'DELETE'
    ) THEN

        RAISE EXCEPTION
            '110 failed: authenticated still has DELETE on activity_log';

    END IF;

END $$;


-- ============================================================
-- 11. COMENTARIO
-- ============================================================

COMMENT ON POLICY activity_log_rbac_select
ON public.activity_log
IS
'RBAC: solo workers activos con system.error_logs.read pueden consultar los registros internos de actividad/error.';


COMMIT;

