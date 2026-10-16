-- ============================================================
-- MODIRA — 132_direction_worker_profiles.sql
-- ============================================================
--
-- Objetivo:
--   Proyección de lectura exclusiva para Dirección que permite:
--   1. listar perfiles de trabajadores con sus roles;
--   2. calcular tareas asignadas y completadas;
--   3. consultar las tareas de un trabajador.
--
-- No concede SELECT directo sobre workers ni sobre internal_tasks.
-- El frontend utiliza únicamente estas RPC SECURITY DEFINER.
--
-- Permiso utilizado:
--   system.workers.read
--
-- Dirección dispone de este permiso en el catálogo RBAC actual.
-- ============================================================

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.workers') IS NULL THEN
        RAISE EXCEPTION '132 stopped: public.workers does not exist';
    END IF;

    IF to_regclass('public.profiles') IS NULL THEN
        RAISE EXCEPTION '132 stopped: public.profiles does not exist';
    END IF;

    IF to_regclass('public.worker_roles') IS NULL THEN
        RAISE EXCEPTION '132 stopped: public.worker_roles does not exist';
    END IF;

    IF to_regclass('public.worker_role_assignments') IS NULL THEN
        RAISE EXCEPTION '132 stopped: public.worker_role_assignments does not exist';
    END IF;

    IF to_regclass('public.internal_tasks') IS NULL THEN
        RAISE EXCEPTION '132 stopped: public.internal_tasks does not exist';
    END IF;
END;
$$;

-- ============================================================
-- 1. LISTADO DE PERFILES
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_direction_worker_profiles()
RETURNS TABLE (
    worker_id UUID,
    auth_user_id UUID,
    name TEXT,
    email TEXT,
    status TEXT,
    is_active BOOLEAN,
    roles JSONB,
    assigned_tasks_count BIGINT,
    completed_tasks_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_worker_has_permission('system.workers.read') THEN
        RAISE EXCEPTION 'Acceso denegado: se requiere system.workers.read';
    END IF;

    RETURN QUERY
    SELECT
        w.id,
        w.auth_user_id,
        COALESCE(NULLIF(BTRIM(p.nombre), ''), 'Sin nombre')::TEXT,
        p.email::TEXT,
        p.status::TEXT,
        w.is_active,
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'code', wr.code,
                    'name', wr.name
                )
                ORDER BY wr.name
            )
            FROM public.worker_role_assignments wra
            JOIN public.worker_roles wr
              ON wr.id = wra.role_id
            WHERE wra.worker_id = w.id
              AND wr.is_active = TRUE
        ), '[]'::JSONB),
        COALESCE((
            SELECT COUNT(*)
            FROM public.internal_tasks t
            WHERE t.assigned_to_worker_id = w.id
              AND COALESCE(t.status, '') <> 'cancelled'
        ), 0)::BIGINT,
        COALESCE((
            SELECT COUNT(*)
            FROM public.internal_tasks t
            WHERE t.assigned_to_worker_id = w.id
              AND t.status = 'completed'
        ), 0)::BIGINT
    FROM public.workers w
    JOIN public.profiles p
      ON p.id = w.auth_user_id
    WHERE w.is_active = TRUE
    ORDER BY COALESCE(NULLIF(BTRIM(p.nombre), ''), 'Sin nombre');
END;
$function$;

REVOKE ALL ON FUNCTION public.get_direction_worker_profiles() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_direction_worker_profiles() TO authenticated;

-- ============================================================
-- 2. TAREAS DE UN TRABAJADOR
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_direction_worker_tasks(
    p_worker_id UUID,
    p_filter TEXT DEFAULT 'assigned'
)
RETURNS TABLE (
    id UUID,
    title TEXT,
    description TEXT,
    status TEXT,
    priority TEXT,
    due_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_filter TEXT := LOWER(BTRIM(COALESCE(p_filter, 'assigned')));
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_worker_has_permission('system.workers.read') THEN
        RAISE EXCEPTION 'Acceso denegado: se requiere system.workers.read';
    END IF;

    IF p_worker_id IS NULL THEN
        RAISE EXCEPTION 'worker_id es obligatorio';
    END IF;

    IF v_filter NOT IN ('assigned', 'completed') THEN
        RAISE EXCEPTION 'Filtro de tareas no válido';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.workers w
        WHERE w.id = p_worker_id
          AND w.is_active = TRUE
    ) THEN
        RAISE EXCEPTION 'Trabajador no encontrado o inactivo';
    END IF;

    RETURN QUERY
    SELECT
        t.id,
        t.title::TEXT,
        t.description::TEXT,
        t.status::TEXT,
        t.priority::TEXT,
        t.due_at,
        t.created_at,
        t.updated_at
    FROM public.internal_tasks t
    WHERE t.assigned_to_worker_id = p_worker_id
      AND (
          (v_filter = 'assigned' AND COALESCE(t.status, '') <> 'cancelled')
          OR
          (v_filter = 'completed' AND t.status = 'completed')
      )
    ORDER BY
        CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END,
        t.due_at NULLS LAST,
        t.created_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_direction_worker_tasks(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_direction_worker_tasks(UUID, TEXT) TO authenticated;
DROP FUNCTION IF EXISTS public.get_direction_worker_profiles();
DROP FUNCTION IF EXISTS public.get_direction_worker_tasks(UUID, TEXT);
COMMIT;
