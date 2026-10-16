BEGIN;

-- ============================================================
-- MODIRA — 138_project_tasks_visibility.sql
-- ============================================================
-- OBJETIVO
--   Añadir control backend de visibilidad para Project Tasks.
--
-- REGLAS:
--   Dirección:
--     - puede ver todas las tareas;
--     - puede configurar quién puede ver cada tarea.
--
--   Otros workers con project_tasks.read (actualmente Developer):
--     - pueden ver las tareas que han creado;
--     - pueden ver las tareas asignadas a ellos;
--     - pueden ver las tareas compartidas explícitamente con ellos;
--     - pueden ver las tareas compartidas con cualquiera de sus roles.
--
-- IMPORTANTE:
--   La visibilidad se aplica en get_project_tasks() y get_project_task().
--   No depende del frontend.
--
--   Esta migración NO crea permisos nuevos.
--   La gestión de visibilidad queda reservada a Dirección mediante
--   current_worker_is_direction().
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    IF to_regclass('public.project_tasks') IS NULL THEN
        RAISE EXCEPTION
            '138 stopped: public.project_tasks does not exist';
    END IF;

    IF to_regclass('public.workers') IS NULL THEN
        RAISE EXCEPTION
            '138 stopped: public.workers does not exist';
    END IF;

    IF to_regclass('public.worker_roles') IS NULL THEN
        RAISE EXCEPTION
            '138 stopped: public.worker_roles does not exist';
    END IF;

    IF to_regclass('public.worker_role_assignments') IS NULL THEN
        RAISE EXCEPTION
            '138 stopped: public.worker_role_assignments does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'project_tasks'
          AND column_name = 'created_by_worker_id'
    ) THEN
        RAISE EXCEPTION
            '138 stopped: project_tasks.created_by_worker_id does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'project_tasks'
          AND column_name = 'assigned_to_worker_id'
    ) THEN
        RAISE EXCEPTION
            '138 stopped: project_tasks.assigned_to_worker_id does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_project_task_worker_id'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '138 stopped: current_project_task_worker_id() does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_worker_is_direction'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '138 stopped: current_worker_is_direction() does not exist';
    END IF;

END;
$$;


-- ============================================================
-- 2. TABLA DE VISIBILIDAD
-- ============================================================
-- Una fila puede compartir una tarea:
--   - con un worker concreto; o
--   - con un rol completo.
--
-- Nunca se permite que ambos estén vacíos.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.project_task_visibility (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    task_id UUID NOT NULL
        REFERENCES public.project_tasks(id)
        ON DELETE CASCADE,

    worker_id UUID NULL
        REFERENCES public.workers(id)
        ON DELETE CASCADE,

    role_id UUID NULL
        REFERENCES public.worker_roles(id)
        ON DELETE CASCADE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT project_task_visibility_target_check
        CHECK (
            worker_id IS NOT NULL
            OR role_id IS NOT NULL
        ),

    CONSTRAINT project_task_visibility_unique_worker
        UNIQUE (task_id, worker_id),

    CONSTRAINT project_task_visibility_unique_role
        UNIQUE (task_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_project_task_visibility_task
ON public.project_task_visibility(task_id);

CREATE INDEX IF NOT EXISTS idx_project_task_visibility_worker
ON public.project_task_visibility(worker_id)
WHERE worker_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_project_task_visibility_role
ON public.project_task_visibility(role_id)
WHERE role_id IS NOT NULL;


-- ============================================================
-- 3. SEGURIDAD DE LA TABLA
-- ============================================================
-- El frontend NO accede directamente.
-- Toda la lectura/escritura pasa por RPC SECURITY DEFINER.
-- ============================================================

ALTER TABLE public.project_task_visibility ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS project_task_visibility_no_direct_access
ON public.project_task_visibility;

REVOKE ALL
ON public.project_task_visibility
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 4. RPC — OBTENER VISIBILIDAD DE UNA TAREA
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_project_task_visibility(
    p_task_id UUID
)
RETURNS TABLE (
    worker_id UUID,
    worker_name TEXT,
    role_id UUID,
    role_code TEXT,
    role_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.read'
    );

    IF p_task_id IS NULL THEN
        RAISE EXCEPTION 'La tarea es obligatoria';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.project_tasks pt
        WHERE pt.id = p_task_id
          AND (
              public.current_worker_is_direction()
              OR pt.created_by_worker_id = public.current_project_task_worker_id()
              OR pt.assigned_to_worker_id = public.current_project_task_worker_id()
              OR EXISTS (
                  SELECT 1
                  FROM public.project_task_visibility v
                  WHERE v.task_id = pt.id
                    AND (
                        v.worker_id = public.current_project_task_worker_id()
                        OR EXISTS (
                            SELECT 1
                            FROM public.worker_role_assignments wra
                            WHERE wra.worker_auth_user_id = auth.uid()
                              AND wra.role_id = v.role_id
                        )
                    )
              )
          )
    ) THEN
        RAISE EXCEPTION 'No tienes acceso a esta tarea';
    END IF;

    RETURN QUERY
    SELECT
        v.worker_id,
        w.display_name,
        v.role_id,
        wr.code,
        wr.name
    FROM public.project_task_visibility v
    LEFT JOIN public.workers w
        ON w.id = v.worker_id
    LEFT JOIN public.worker_roles wr
        ON wr.id = v.role_id
    WHERE v.task_id = p_task_id
    ORDER BY
        CASE WHEN v.worker_id IS NOT NULL THEN 1 ELSE 2 END,
        COALESCE(w.display_name, wr.name);

END;
$function$;

REVOKE ALL
ON FUNCTION public.get_project_task_visibility(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_project_task_visibility(UUID)
TO authenticated;


-- ============================================================
-- 5. RPC — DIRECCIÓN CONFIGURA LA VISIBILIDAD
-- ============================================================
-- Reemplaza completamente la configuración anterior de la tarea.
--
-- p_worker_ids:
--   workers concretos.
--
-- p_role_ids:
--   roles completos.
--
-- Ambos pueden utilizarse simultáneamente.
-- Un array NULL se interpreta como vacío.
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_project_task_visibility(
    p_task_id UUID,
    p_worker_ids UUID[] DEFAULT ARRAY[]::UUID[],
    p_role_ids UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_count INTEGER := 0;
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión';
    END IF;

    IF NOT public.current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede configurar la visibilidad de las tareas';
    END IF;

    IF p_task_id IS NULL THEN
        RAISE EXCEPTION 'La tarea es obligatoria';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.project_tasks
        WHERE id = p_task_id
    ) THEN
        RAISE EXCEPTION 'Tarea no encontrada';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:visibility:' || auth.uid()::TEXT,
        60,
        600
    );

    -- Validar workers antes de modificar nada.
    IF EXISTS (
        SELECT 1
        FROM unnest(COALESCE(p_worker_ids, ARRAY[]::UUID[])) AS x(id)
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.workers w
            WHERE w.id = x.id
              AND w.is_active = TRUE
        )
    ) THEN
        RAISE EXCEPTION
            'La visibilidad contiene un trabajador inexistente o inactivo';
    END IF;

    -- Validar roles antes de modificar nada.
    IF EXISTS (
        SELECT 1
        FROM unnest(COALESCE(p_role_ids, ARRAY[]::UUID[])) AS x(id)
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.worker_roles wr
            WHERE wr.id = x.id
              AND wr.is_active = TRUE
        )
    ) THEN
        RAISE EXCEPTION
            'La visibilidad contiene un rol inexistente o inactivo';
    END IF;

    -- Reemplazo atómico de la configuración.
    DELETE FROM public.project_task_visibility
    WHERE task_id = p_task_id;

    INSERT INTO public.project_task_visibility (
        task_id,
        worker_id
    )
    SELECT
        p_task_id,
        x.id
    FROM (
        SELECT DISTINCT id
        FROM unnest(COALESCE(p_worker_ids, ARRAY[]::UUID[])) AS u(id)
    ) x;

    INSERT INTO public.project_task_visibility (
        task_id,
        role_id
    )
    SELECT
        p_task_id,
        x.id
    FROM (
        SELECT DISTINCT id
        FROM unnest(COALESCE(p_role_ids, ARRAY[]::UUID[])) AS u(id)
    ) x;

    SELECT COUNT(*)
    INTO v_count
    FROM public.project_task_visibility
    WHERE task_id = p_task_id;

    RETURN v_count;

END;
$function$;

REVOKE ALL
ON FUNCTION public.set_project_task_visibility(UUID, UUID[], UUID[])
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.set_project_task_visibility(UUID, UUID[], UUID[])
TO authenticated;


-- ============================================================
-- 6. REDEFINIR get_project_tasks()
-- ============================================================
-- IMPORTANTE:
-- Dirección mantiene acceso global.
--
-- Los demás workers solo reciben:
--   - tareas creadas por ellos;
--   - tareas asignadas a ellos;
--   - tareas compartidas individualmente;
--   - tareas compartidas con cualquiera de sus roles.
--
-- Los filtros originales se conservan.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_project_tasks(
    p_project_id UUID DEFAULT NULL,
    p_milestone_id UUID DEFAULT NULL,
    p_status TEXT DEFAULT NULL,
    p_priority TEXT DEFAULT NULL,
    p_assigned_to_worker_id UUID DEFAULT NULL,
    p_limit INTEGER DEFAULT 100
)
RETURNS SETOF public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_limit INTEGER;
    v_worker_id UUID;
    v_is_direction BOOLEAN;
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.read'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:read:' || auth.uid()::TEXT,
        120,
        600
    );

    v_worker_id := public.current_project_task_worker_id();
    v_is_direction := public.current_worker_is_direction();

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'No se ha podido identificar al trabajador actual';
    END IF;

    v_limit := LEAST(
        GREATEST(COALESCE(p_limit, 100), 1),
        200
    );

    IF p_project_id IS NOT NULL
       AND NOT public.project_task_project_exists(p_project_id)
    THEN
        RAISE EXCEPTION 'El proyecto no existe';
    END IF;

    RETURN QUERY
    SELECT pt.*
    FROM public.project_tasks pt
    WHERE (p_project_id IS NULL OR pt.project_id = p_project_id)
      AND (
          p_milestone_id IS NULL
          OR pt.milestone_id = p_milestone_id
      )
      AND (
          p_status IS NULL
          OR pt.status = LOWER(BTRIM(p_status))
      )
      AND (
          p_priority IS NULL
          OR pt.priority = LOWER(BTRIM(p_priority))
      )
      AND (
          p_assigned_to_worker_id IS NULL
          OR pt.assigned_to_worker_id = p_assigned_to_worker_id
      )
      AND (
          v_is_direction
          OR pt.created_by_worker_id = v_worker_id
          OR pt.assigned_to_worker_id = v_worker_id
          OR EXISTS (
              SELECT 1
              FROM public.project_task_visibility v
              WHERE v.task_id = pt.id
                AND (
                    v.worker_id = v_worker_id
                    OR EXISTS (
                        SELECT 1
                        FROM public.worker_role_assignments wra
                        WHERE wra.worker_auth_user_id = auth.uid()
                          AND wra.role_id = v.role_id
                    )
                )
          )
      )
    ORDER BY
        CASE pt.priority
            WHEN 'urgent' THEN 1
            WHEN 'high' THEN 2
            WHEN 'normal' THEN 3
            WHEN 'low' THEN 4
            ELSE 5
        END,
        pt.due_at NULLS LAST,
        pt.created_at DESC
    LIMIT v_limit;

END;
$function$;

REVOKE ALL
ON FUNCTION public.get_project_tasks(
    UUID, UUID, TEXT, TEXT, UUID, INTEGER
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_project_tasks(
    UUID, UUID, TEXT, TEXT, UUID, INTEGER
)
TO authenticated;


-- ============================================================
-- 7. REDEFINIR get_project_task()
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_project_task(
    p_task_id UUID
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.project_tasks;
    v_worker_id UUID;
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.read'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:get:' || auth.uid()::TEXT,
        180,
        600
    );

    v_worker_id := public.current_project_task_worker_id();

    SELECT pt.*
    INTO v_task
    FROM public.project_tasks pt
    WHERE pt.id = p_task_id
      AND (
          public.current_worker_is_direction()
          OR pt.created_by_worker_id = v_worker_id
          OR pt.assigned_to_worker_id = v_worker_id
          OR EXISTS (
              SELECT 1
              FROM public.project_task_visibility v
              WHERE v.task_id = pt.id
                AND (
                    v.worker_id = v_worker_id
                    OR EXISTS (
                        SELECT 1
                        FROM public.worker_role_assignments wra
                        WHERE wra.worker_auth_user_id = auth.uid()
                          AND wra.role_id = v.role_id
                    )
                )
          )
      );

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tarea no encontrada o no tienes acceso a ella';
    END IF;

    RETURN v_task;

END;
$function$;

REVOKE ALL
ON FUNCTION public.get_project_task(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_project_task(UUID)
TO authenticated;


-- ============================================================
-- 8. VERIFICACIONES FINALES
-- ============================================================

DO $$
BEGIN

    IF to_regclass('public.project_task_visibility') IS NULL THEN
        RAISE EXCEPTION
            '138 failed: project_task_visibility was not created';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_project_tasks'
          AND p.pronargs = 6
    ) THEN
        RAISE EXCEPTION
            '138 failed: get_project_tasks(uuid,uuid,text,text,uuid,integer) missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_project_task'
          AND p.pronargs = 1
    ) THEN
        RAISE EXCEPTION
            '138 failed: get_project_task(uuid) missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_project_task_visibility'
          AND p.pronargs = 3
    ) THEN
        RAISE EXCEPTION
            '138 failed: set_project_task_visibility(uuid,uuid[],uuid[]) missing';
    END IF;

END;
$$;

COMMIT;
