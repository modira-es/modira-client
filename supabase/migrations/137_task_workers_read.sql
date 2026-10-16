-- ============================================================
-- 137_task_workers_read_permission.sql
-- Permite a todos los trabajadores activos consultar
-- únicamente las opciones de trabajadores necesarias
-- para asignación/recomendación de tareas.
--
-- NO modifica la RLS de public.workers.
-- NO modifica get_worker_roles().
-- NO modifica system.workers.read.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. Crear permiso task_workers.read
-- ============================================================

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
VALUES (
    'task_workers.read',
    'task_workers',
    'read',
    'Consultar trabajadores activos para asignación y recomendación de tareas.'
)
ON CONFLICT (code) DO NOTHING;


-- ============================================================
-- 2. Asignar el permiso a los cinco roles
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
WHERE wr.code IN (
    'direction',
    'developer',
    'commercial',
    'accounting',
    'support'
)
AND wr.is_active = TRUE
AND wp.code = 'task_workers.read'
ON CONFLICT (role_id, permission_id) DO NOTHING;


-- ============================================================
-- 3. RPC segura para obtener trabajadores disponibles
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_task_worker_options()
RETURNS TABLE (
    id UUID,
    display_name TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    -- Debe existir una sesión autenticada
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.';
    END IF;

    -- Debe ser un trabajador activo de Modira
    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'El usuario actual no corresponde a un trabajador activo de Modira.';
    END IF;

    -- Debe tener explícitamente task_workers.read
    IF NOT public.current_worker_has_permission('task_workers.read') THEN
        RAISE EXCEPTION 'No tienes permiso para consultar trabajadores.';
    END IF;

    RETURN QUERY
    SELECT
        w.id,
        w.display_name
    FROM public.workers w
    WHERE w.is_active = TRUE
    ORDER BY w.display_name;

END;
$function$;


-- ============================================================
-- 4. Seguridad de ejecución de la RPC
-- ============================================================

REVOKE EXECUTE
ON FUNCTION public.get_task_worker_options()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.get_task_worker_options()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.get_task_worker_options()
FROM authenticated;

GRANT EXECUTE
ON FUNCTION public.get_task_worker_options()
TO authenticated;


COMMIT;