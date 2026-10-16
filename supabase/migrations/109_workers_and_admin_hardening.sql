-- ============================================================
-- 109 — WORKERS / ADMIN HARDENING
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Comprobaciones previas
-- ------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    ) THEN
        RAISE EXCEPTION '109 failed: public.workers does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_permissions'
    ) THEN
        RAISE EXCEPTION '109 failed: public.worker_permissions does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_roles'
    ) THEN
        RAISE EXCEPTION '109 failed: public.worker_roles does not exist';
    END IF;
END $$;


-- ------------------------------------------------------------
-- 2. Permisos específicos para gestión de trabajadores
-- ------------------------------------------------------------

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
VALUES
(
    'system.workers.read',
    'system.workers',
    'read',
    'Permite consultar información de trabajadores y su gestión administrativa'
),
(
    'system.workers.manage',
    'system.workers',
    'manage',
    'Permite gestionar trabajadores y su estado'
)
ON CONFLICT (code) DO NOTHING;


-- ------------------------------------------------------------
-- 3. Direction obtiene ambos permisos
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
      'system.workers.read',
      'system.workers.manage'
  )
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- 4. Eliminar acceso global de workers a profiles
-- ------------------------------------------------------------

DROP POLICY IF EXISTS profiles_worker_select
ON public.profiles;

DROP POLICY IF EXISTS profiles_worker_update
ON public.profiles;


-- ------------------------------------------------------------
-- 5. Mantener acceso del trabajador a SU propio registro
-- ------------------------------------------------------------

DROP POLICY IF EXISTS workers_select_own
ON public.workers;

CREATE POLICY workers_select_own
ON public.workers
FOR SELECT
TO authenticated
USING (
    auth_user_id = auth.uid()
);


-- ------------------------------------------------------------
-- 6. Asegurar que no haya acceso directo de workers a las
--    tablas internas de RBAC
-- ------------------------------------------------------------

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


-- ------------------------------------------------------------
-- 7. Permitir ejecución de las funciones de RBAC
-- ------------------------------------------------------------

GRANT EXECUTE
ON FUNCTION public.get_worker_roles(uuid)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.get_all_worker_role_assignments()
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.assign_worker_role(uuid, text)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.remove_worker_role(uuid, text)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.replace_worker_roles(uuid, text[])
TO authenticated;


-- ------------------------------------------------------------
-- 8. Verificaciones
-- ------------------------------------------------------------

DO $$
BEGIN

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'profiles'
          AND policyname = 'profiles_worker_update'
    ) THEN
        RAISE EXCEPTION
            '109 failed: profiles_worker_update still exists';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'profiles'
          AND policyname = 'profiles_worker_select'
    ) THEN
        RAISE EXCEPTION
            '109 failed: profiles_worker_select still exists';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'system.workers.read'
    ) THEN
        RAISE EXCEPTION
            '109 failed: system.workers.read missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'system.workers.manage'
    ) THEN
        RAISE EXCEPTION
            '109 failed: system.workers.manage missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'direction'
          AND wp.code = 'system.workers.read'
    ) THEN
        RAISE EXCEPTION
            '109 failed: direction missing system.workers.read';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'direction'
          AND wp.code = 'system.workers.manage'
    ) THEN
        RAISE EXCEPTION
            '109 failed: direction missing system.workers.manage';
    END IF;

END $$;

COMMIT;