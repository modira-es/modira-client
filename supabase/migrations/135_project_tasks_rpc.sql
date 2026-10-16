BEGIN;

-- ============================================================
-- 135 — PROJECT TASKS RPC
-- ============================================================
--
-- Capa funcional de Project Tasks.
--
-- Permisos RBAC EXISTENTES:
--   project_tasks.create
--   project_tasks.read
--   project_tasks.update
--   project_tasks.delete
--
-- Roles:
--   developer
--   direction
--
-- Dirección se determina mediante:
--   workers.auth_user_id
--   get_worker_roles(...)
--
-- No se crean permisos nuevos.
-- No se utiliza public.permissions.
-- No se utiliza ningún permiso inventado.
--
-- Todas las operaciones de escritura:
--   - SECURITY DEFINER
--   - worker activo
--   - RBAC
--   - rate limit
--   - validación de entradas
--   - validación de proyecto
--   - bloqueo FOR UPDATE cuando corresponde
--
-- ============================================================


-- ============================================================
-- 1. HELPER — COMPROBAR DIRECCIÓN
-- ============================================================
--
-- No añadimos un permiso nuevo para Dirección.
-- Se consulta el rol real asignado al worker.
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_worker_is_direction()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_user_id UUID;
    v_is_direction BOOLEAN;
BEGIN

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN FALSE;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.get_worker_roles(v_user_id) r
        WHERE r.role_code = 'direction'
          AND r.is_active = TRUE
    )
    INTO v_is_direction;

    RETURN COALESCE(v_is_direction, FALSE);

END;
$function$;


REVOKE ALL
ON FUNCTION public.current_worker_is_direction()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.current_worker_is_direction()
TO authenticated;


-- ============================================================
-- 2. HELPER — OBTENER WORKER ACTUAL
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_project_task_worker_id()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
BEGIN

    IF auth.uid() IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT w.id
    INTO v_worker_id
    FROM public.workers w
    WHERE w.auth_user_id = auth.uid()
      AND w.is_active = TRUE
    LIMIT 1;

    RETURN v_worker_id;

END;
$function$;


REVOKE ALL
ON FUNCTION public.current_project_task_worker_id()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.current_project_task_worker_id()
TO authenticated;


-- ============================================================
-- 3. HELPER — VALIDAR WORKER ASIGNADO
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_project_task_assignee(
    p_worker_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    IF p_worker_id IS NULL THEN
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.workers w
        WHERE w.id = p_worker_id
          AND w.is_active = TRUE
    ) THEN
        RAISE EXCEPTION
            'El trabajador asignado no existe o no está activo';
    END IF;

END;
$function$;


REVOKE ALL
ON FUNCTION public.validate_project_task_assignee(UUID)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 4. HELPER — VALIDAR ACCESO AL PROYECTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.project_task_project_exists(
    p_project_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    IF p_project_id IS NULL THEN
        RETURN FALSE;
    END IF;

    RETURN EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = p_project_id
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.project_task_project_exists(UUID)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 5. HELPER — REGISTRAR HISTORIAL
-- ============================================================
--
-- Función interna.
-- No se concede EXECUTE a usuarios.
--
-- La tabla de historial queda como registro append-only.
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_project_task_update(
    p_task_id UUID,
    p_action TEXT,
    p_old_status TEXT DEFAULT NULL,
    p_old_progress INTEGER DEFAULT NULL,
    p_new_status TEXT DEFAULT NULL,
    p_new_progress INTEGER DEFAULT NULL,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.project_task_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
    v_update public.project_task_updates;
    v_comment TEXT;
BEGIN

    v_worker_id := public.current_project_task_worker_id();

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'Se requiere un trabajador activo';
    END IF;

    IF p_task_id IS NULL THEN
        RAISE EXCEPTION
            'La tarea es obligatoria';
    END IF;

    IF p_action IS NULL
       OR BTRIM(p_action) = ''
    THEN
        RAISE EXCEPTION
            'La acción es obligatoria';
    END IF;

    IF LENGTH(BTRIM(p_action)) > 100 THEN
        RAISE EXCEPTION
            'La acción no puede superar 100 caracteres';
    END IF;

    v_comment := NULLIF(BTRIM(p_comment), '');

    IF v_comment IS NOT NULL
       AND LENGTH(v_comment) > 5000
    THEN
        RAISE EXCEPTION
            'El comentario no puede superar 5000 caracteres';
    END IF;

    INSERT INTO public.project_task_updates (
        task_id,
        actor_worker_id,
        action,
        old_status,
        old_progress,
        new_status,
        new_progress,
        comment
    )
    VALUES (
        p_task_id,
        v_worker_id,
        BTRIM(p_action),
        p_old_status,
        p_old_progress,
        p_new_status,
        p_new_progress,
        v_comment
    )
    RETURNING *
    INTO v_update;

    RETURN v_update;

END;
$function$;


REVOKE ALL
ON FUNCTION public.record_project_task_update(
    UUID,
    TEXT,
    TEXT,
    INTEGER,
    TEXT,
    INTEGER,
    TEXT
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 6. RPC — CREAR PROJECT TASK
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_project_task(
    p_project_id UUID,
    p_title TEXT,
    p_description TEXT DEFAULT NULL,
    p_milestone_id UUID DEFAULT NULL,
    p_assigned_to_worker_id UUID DEFAULT NULL,
    p_priority TEXT DEFAULT 'normal',
    p_due_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
    v_task public.project_tasks;
    v_title TEXT;
    v_description TEXT;
    v_priority TEXT;
BEGIN

    v_worker_id := public.current_project_task_worker_id();

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.create'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:create:' || auth.uid()::TEXT,
        30,
        3600
    );

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto es obligatorio';
    END IF;

    IF NOT public.project_task_project_exists(p_project_id) THEN
        RAISE EXCEPTION
            'El proyecto no existe';
    END IF;

    v_title := NULLIF(BTRIM(p_title), '');

    IF v_title IS NULL THEN
        RAISE EXCEPTION
            'El título es obligatorio';
    END IF;

    IF LENGTH(v_title) > 200 THEN
        RAISE EXCEPTION
            'El título no puede superar 200 caracteres';
    END IF;

    v_description := NULLIF(BTRIM(p_description), '');

    IF v_description IS NOT NULL
       AND LENGTH(v_description) > 5000
    THEN
        RAISE EXCEPTION
            'La descripción no puede superar 5000 caracteres';
    END IF;

    v_priority := LOWER(BTRIM(COALESCE(p_priority, 'normal')));

    IF v_priority NOT IN (
        'low',
        'normal',
        'high',
        'urgent'
    ) THEN
        RAISE EXCEPTION
            'Prioridad no válida';
    END IF;

    -- --------------------------------------------------------
    -- VALIDAR MILESTONE
    -- --------------------------------------------------------

    IF p_milestone_id IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM public.project_milestones pm
            WHERE pm.id = p_milestone_id
              AND pm.project_id = p_project_id
        ) THEN
            RAISE EXCEPTION
                'El hito no existe o no pertenece al proyecto';
        END IF;

    END IF;

    -- --------------------------------------------------------
    -- VALIDAR ASIGNACIÓN
    -- --------------------------------------------------------
    --
    -- Developer:
    --   puede crear para sí mismo o dejar sin asignar.
    --
    -- Dirección:
    --   puede asignar a cualquier worker activo.
    -- --------------------------------------------------------

    IF p_assigned_to_worker_id IS NOT NULL THEN

        PERFORM public.validate_project_task_assignee(
            p_assigned_to_worker_id
        );

        IF p_assigned_to_worker_id <> v_worker_id
           AND NOT public.current_worker_is_direction()
        THEN
            RAISE EXCEPTION
                'Solo Dirección puede asignar una tarea a otro trabajador';
        END IF;

    END IF;

    INSERT INTO public.project_tasks (
        project_id,
        milestone_id,
        title,
        description,
        created_by_worker_id,
        assigned_to_worker_id,
        status,
        progress,
        priority,
        due_at
    )
    VALUES (
        p_project_id,
        p_milestone_id,
        v_title,
        v_description,
        v_worker_id,
        p_assigned_to_worker_id,
        'to_do',
        0,
        v_priority,
        p_due_at
    )
    RETURNING *
    INTO v_task;

    PERFORM public.record_project_task_update(
        v_task.id,
        'created',
        NULL,
        NULL,
        v_task.status,
        v_task.progress,
        NULL
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.create_project_task(
    UUID,
    TEXT,
    TEXT,
    UUID,
    UUID,
    TEXT,
    TIMESTAMPTZ
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_project_task(
    UUID,
    TEXT,
    TEXT,
    UUID,
    UUID,
    TEXT,
    TIMESTAMPTZ
)
TO authenticated;


-- ============================================================
-- 7. RPC — LISTAR PROJECT TASKS
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
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.read'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:read:' || auth.uid()::TEXT,
        120,
        600
    );

    v_limit := LEAST(
        GREATEST(COALESCE(p_limit, 100), 1),
        200
    );

    IF p_project_id IS NOT NULL
       AND NOT public.project_task_project_exists(p_project_id)
    THEN
        RAISE EXCEPTION
            'El proyecto no existe';
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
    UUID,
    UUID,
    TEXT,
    TEXT,
    UUID,
    INTEGER
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_project_tasks(
    UUID,
    UUID,
    TEXT,
    TEXT,
    UUID,
    INTEGER
)
TO authenticated;


-- ============================================================
-- 8. RPC — OBTENER UNA PROJECT TASK
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
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.read'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:get:' || auth.uid()::TEXT,
        180,
        600
    );

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
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
-- 9. RPC — ACTUALIZAR DATOS DE LA TAREA
-- ============================================================
--
-- No permite modificar:
--   project_id
--   milestone_id
--   created_by_worker_id
--   assigned_to_worker_id
--   status
--   progress
--
-- Esos cambios tienen RPC específicas.
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_project_task(
    p_task_id UUID,
    p_title TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_milestone_id UUID DEFAULT NULL,
    p_priority TEXT DEFAULT NULL,
    p_due_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.project_tasks;
    v_old_task public.project_tasks;
    v_title TEXT;
    v_description TEXT;
    v_priority TEXT;
BEGIN

    IF public.current_project_task_worker_id() IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.update'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:update:' || auth.uid()::TEXT,
        120,
        600
    );

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    v_old_task := v_task;

    -- --------------------------------------------------------
    -- TÍTULO
    -- --------------------------------------------------------

    IF p_title IS NOT NULL THEN

        v_title := NULLIF(BTRIM(p_title), '');

        IF v_title IS NULL THEN
            RAISE EXCEPTION
                'El título no puede estar vacío';
        END IF;

        IF LENGTH(v_title) > 200 THEN
            RAISE EXCEPTION
                'El título no puede superar 200 caracteres';
        END IF;

    ELSE
        v_title := v_task.title;
    END IF;

    -- --------------------------------------------------------
    -- DESCRIPCIÓN
    -- --------------------------------------------------------

    IF p_description IS NOT NULL THEN

        v_description := NULLIF(BTRIM(p_description), '');

        IF v_description IS NOT NULL
           AND LENGTH(v_description) > 5000
        THEN
            RAISE EXCEPTION
                'La descripción no puede superar 5000 caracteres';
        END IF;

    ELSE
        v_description := v_task.description;
    END IF;

    -- --------------------------------------------------------
    -- PRIORIDAD
    -- --------------------------------------------------------

    IF p_priority IS NOT NULL THEN

        v_priority := LOWER(BTRIM(p_priority));

        IF v_priority NOT IN (
            'low',
            'normal',
            'high',
            'urgent'
        ) THEN
            RAISE EXCEPTION
                'Prioridad no válida';
        END IF;

    ELSE
        v_priority := v_task.priority;
    END IF;

    -- --------------------------------------------------------
    -- MILESTONE
    -- --------------------------------------------------------

    IF p_milestone_id IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM public.project_milestones pm
            WHERE pm.id = p_milestone_id
              AND pm.project_id = v_task.project_id
        ) THEN
            RAISE EXCEPTION
                'El hito no existe o no pertenece al proyecto';
        END IF;

    END IF;

    UPDATE public.project_tasks
    SET
        title = v_title,
        description = v_description,
        milestone_id = p_milestone_id,
        priority = v_priority,
        due_at = p_due_at
    WHERE id = v_task.id
    RETURNING *
    INTO v_task;

    PERFORM public.record_project_task_update(
        v_task.id,
        'updated',
        v_old_task.status,
        v_old_task.progress,
        v_task.status,
        v_task.progress,
        NULL
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.update_project_task(
    UUID,
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TIMESTAMPTZ
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_project_task(
    UUID,
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TIMESTAMPTZ
)
TO authenticated;


-- ============================================================
-- 10. RPC — REASIGNAR TAREA
-- ============================================================
--
-- Exclusivamente Dirección.
-- ============================================================

CREATE OR REPLACE FUNCTION public.reassign_project_task(
    p_task_id UUID,
    p_assigned_to_worker_id UUID
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.project_tasks;
    v_old_worker_id UUID;
BEGIN

    IF public.current_project_task_worker_id() IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.update'
    );

    IF NOT public.current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede reasignar tareas';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:reassign:' || auth.uid()::TEXT,
        120,
        3600
    );

    PERFORM public.validate_project_task_assignee(
        p_assigned_to_worker_id
    );

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    v_old_worker_id := v_task.assigned_to_worker_id;

    UPDATE public.project_tasks
    SET
        assigned_to_worker_id = p_assigned_to_worker_id
    WHERE id = v_task.id
    RETURNING *
    INTO v_task;

    PERFORM public.record_project_task_update(
        v_task.id,
        'reassigned',
        v_task.status,
        v_task.progress,
        v_task.status,
        v_task.progress,
        NULL
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.reassign_project_task(UUID, UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.reassign_project_task(UUID, UUID)
TO authenticated;


-- ============================================================
-- 11. RPC — INICIAR TAREA
-- ============================================================

CREATE OR REPLACE FUNCTION public.start_project_task(
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

    v_worker_id := public.current_project_task_worker_id();

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.update'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:start:' || auth.uid()::TEXT,
        60,
        3600
    );

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    IF v_task.assigned_to_worker_id IS DISTINCT FROM v_worker_id THEN
        RAISE EXCEPTION
            'Solo el trabajador asignado puede iniciar la tarea';
    END IF;

    IF v_task.status <> 'to_do' THEN
        RAISE EXCEPTION
            'La tarea no está pendiente de inicio';
    END IF;

    UPDATE public.project_tasks
    SET
        status = 'in_progress',
        started_at = COALESCE(started_at, CURRENT_TIMESTAMP)
    WHERE id = v_task.id
    RETURNING *
    INTO v_task;

    PERFORM public.record_project_task_update(
        v_task.id,
        'started',
        'to_do',
        v_task.progress,
        v_task.status,
        v_task.progress,
        NULL
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.start_project_task(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.start_project_task(UUID)
TO authenticated;


-- ============================================================
-- 12. RPC — ACTUALIZAR PROGRESO
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_project_task_progress(
    p_task_id UUID,
    p_progress INTEGER
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.project_tasks;
    v_worker_id UUID;
    v_old_progress INTEGER;
BEGIN

    v_worker_id := public.current_project_task_worker_id();

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.update'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:progress:' || auth.uid()::TEXT,
        120,
        600
    );

    IF p_progress IS NULL
       OR p_progress < 0
       OR p_progress > 100
    THEN
        RAISE EXCEPTION
            'El progreso debe estar entre 0 y 100';
    END IF;

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    IF v_task.assigned_to_worker_id IS DISTINCT FROM v_worker_id THEN
        RAISE EXCEPTION
            'Solo el trabajador asignado puede actualizar el progreso';
    END IF;

    IF v_task.status <> 'in_progress' THEN
        RAISE EXCEPTION
            'Solo se puede actualizar el progreso de una tarea en curso';
    END IF;

    v_old_progress := v_task.progress;

    UPDATE public.project_tasks
    SET
        progress = p_progress
    WHERE id = v_task.id
    RETURNING *
    INTO v_task;

    PERFORM public.record_project_task_update(
        v_task.id,
        'progress_updated',
        v_task.status,
        v_old_progress,
        v_task.status,
        v_task.progress,
        NULL
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.update_project_task_progress(UUID, INTEGER)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_project_task_progress(UUID, INTEGER)
TO authenticated;


-- ============================================================
-- 13. RPC — ENVIAR A REVISIÓN
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_project_task_for_review(
    p_task_id UUID,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.project_tasks;
    v_worker_id UUID;
    v_comment TEXT;
BEGIN

    v_worker_id := public.current_project_task_worker_id();

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.update'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:submit_review:' || auth.uid()::TEXT,
        30,
        3600
    );

    v_comment := NULLIF(BTRIM(p_comment), '');

    IF v_comment IS NOT NULL
       AND LENGTH(v_comment) > 5000
    THEN
        RAISE EXCEPTION
            'El comentario no puede superar 5000 caracteres';
    END IF;

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    IF v_task.assigned_to_worker_id IS DISTINCT FROM v_worker_id THEN
        RAISE EXCEPTION
            'Solo el trabajador asignado puede enviar la tarea a revisión';
    END IF;

    IF v_task.status <> 'in_progress' THEN
        RAISE EXCEPTION
            'La tarea debe estar en curso para enviarla a revisión';
    END IF;

    IF v_task.progress <> 100 THEN
        RAISE EXCEPTION
            'La tarea debe tener un progreso del 100%% antes de enviarla a revisión';
    END IF;

    UPDATE public.project_tasks
    SET
        status = 'pending_review',
        progress = 100,
        submitted_for_review_at = CURRENT_TIMESTAMP
    WHERE id = v_task.id
    RETURNING *
    INTO v_task;

    PERFORM public.record_project_task_update(
        v_task.id,
        'submitted_for_review',
        'in_progress',
        100,
        v_task.status,
        v_task.progress,
        v_comment
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.submit_project_task_for_review(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.submit_project_task_for_review(UUID, TEXT)
TO authenticated;


-- ============================================================
-- 14. RPC — REVISIÓN DE DIRECCIÓN
-- ============================================================
--
-- p_approved = TRUE:
--     pending_review -> completed
--
-- p_approved = FALSE:
--     pending_review -> in_progress
--
-- En ambos casos el progreso se mantiene en 100.
-- ============================================================

CREATE OR REPLACE FUNCTION public.review_project_task(
    p_task_id UUID,
    p_approved BOOLEAN,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.project_tasks;
    v_comment TEXT;
    v_old_status TEXT;
    v_old_progress INTEGER;
BEGIN

    IF public.current_project_task_worker_id() IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.update'
    );

    IF NOT public.current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede revisar tareas';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:review:' || auth.uid()::TEXT,
        60,
        3600
    );

    IF p_approved IS NULL THEN
        RAISE EXCEPTION
            'Debe indicarse si la tarea ha sido aprobada';
    END IF;

    v_comment := NULLIF(BTRIM(p_comment), '');

    IF v_comment IS NOT NULL
       AND LENGTH(v_comment) > 5000
    THEN
        RAISE EXCEPTION
            'El comentario no puede superar 5000 caracteres';
    END IF;

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    IF v_task.status <> 'pending_review' THEN
        RAISE EXCEPTION
            'La tarea no está pendiente de revisión';
    END IF;

    v_old_status := v_task.status;
    v_old_progress := v_task.progress;

    IF p_approved THEN

        UPDATE public.project_tasks
        SET
            status = 'completed',
            progress = 100,
            completed_at = CURRENT_TIMESTAMP,
            completed_by_worker_id =
                public.current_project_task_worker_id()
        WHERE id = v_task.id;

    ELSE

        UPDATE public.project_tasks
        SET
            status = 'in_progress',
            progress = 100,
            submitted_for_review_at = NULL
        WHERE id = v_task.id;

    END IF;

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id;

    PERFORM public.record_project_task_update(
        v_task.id,
        CASE
            WHEN p_approved
                THEN 'review_approved'
            ELSE 'review_returned'
        END,
        v_old_status,
        v_old_progress,
        v_task.status,
        v_task.progress,
        v_comment
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.review_project_task(UUID, BOOLEAN, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.review_project_task(UUID, BOOLEAN, TEXT)
TO authenticated;


-- ============================================================
-- 15. RPC — INTERVENCIÓN DE DIRECCIÓN
-- ============================================================
--
-- Dirección puede:
--   to_do
--   in_progress
--   cancelled
--
-- No puede utilizar esta vía para marcar una tarea como completed.
-- La finalización requiere review_project_task().
-- ============================================================

CREATE OR REPLACE FUNCTION public.direction_set_project_task_state(
    p_task_id UUID,
    p_status TEXT,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.project_tasks;
    v_old_status TEXT;
    v_old_progress INTEGER;
    v_comment TEXT;
BEGIN

    IF public.current_project_task_worker_id() IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.update'
    );

    IF NOT public.current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede intervenir directamente sobre el estado';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:direction_state:' || auth.uid()::TEXT,
        120,
        3600
    );

    IF p_status IS NULL THEN
        RAISE EXCEPTION
            'El estado es obligatorio';
    END IF;

    IF LOWER(BTRIM(p_status)) NOT IN (
        'to_do',
        'in_progress',
        'cancelled'
    ) THEN
        RAISE EXCEPTION
            'Estado no permitido para intervención de Dirección';
    END IF;

    v_comment := NULLIF(BTRIM(p_comment), '');

    IF v_comment IS NOT NULL
       AND LENGTH(v_comment) > 5000
    THEN
        RAISE EXCEPTION
            'El comentario no puede superar 5000 caracteres';
    END IF;

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    v_old_status := v_task.status;
    v_old_progress := v_task.progress;

    UPDATE public.project_tasks
    SET
        status = LOWER(BTRIM(p_status)),
        cancelled_at = CASE
            WHEN LOWER(BTRIM(p_status)) = 'cancelled'
                THEN CURRENT_TIMESTAMP
            ELSE NULL
        END,
        cancelled_by_worker_id = CASE
            WHEN LOWER(BTRIM(p_status)) = 'cancelled'
                THEN public.current_project_task_worker_id()
            ELSE NULL
        END
    WHERE id = v_task.id
    RETURNING *
    INTO v_task;

    PERFORM public.record_project_task_update(
        v_task.id,
        CASE
            WHEN v_task.status = 'cancelled'
                THEN 'cancelled'
            ELSE 'direction_state_change'
        END,
        v_old_status,
        v_old_progress,
        v_task.status,
        v_task.progress,
        v_comment
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.direction_set_project_task_state(UUID, TEXT, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.direction_set_project_task_state(UUID, TEXT, TEXT)
TO authenticated;


-- ============================================================
-- 16. RPC — CANCELACIÓN LÓGICA
-- ============================================================
--
-- Se conserva el permiso project_tasks.delete.
-- La eliminación física NO existe.
--
-- Solo Dirección puede cancelar mediante esta operación.
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_project_task(
    p_task_id UUID,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.project_tasks;
    v_old_status TEXT;
    v_old_progress INTEGER;
    v_comment TEXT;
BEGIN

    IF public.current_project_task_worker_id() IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.delete'
    );

    IF NOT public.current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede cancelar una tarea';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:delete:' || auth.uid()::TEXT,
        30,
        3600
    );

    v_comment := NULLIF(BTRIM(p_comment), '');

    IF v_comment IS NOT NULL
       AND LENGTH(v_comment) > 5000
    THEN
        RAISE EXCEPTION
            'El comentario no puede superar 5000 caracteres';
    END IF;

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    IF v_task.status = 'completed' THEN
        RAISE EXCEPTION
            'Una tarea completada no puede cancelarse';
    END IF;

    IF v_task.status = 'cancelled' THEN
        RAISE EXCEPTION
            'La tarea ya está cancelada';
    END IF;

    v_old_status := v_task.status;
    v_old_progress := v_task.progress;

    UPDATE public.project_tasks
    SET
        status = 'cancelled',
        cancelled_at = CURRENT_TIMESTAMP,
        cancelled_by_worker_id =
            public.current_project_task_worker_id()
    WHERE id = v_task.id
    RETURNING *
    INTO v_task;

    PERFORM public.record_project_task_update(
        v_task.id,
        'cancelled',
        v_old_status,
        v_old_progress,
        v_task.status,
        v_task.progress,
        v_comment
    );

    RETURN v_task;

END;
$function$;


REVOKE ALL
ON FUNCTION public.delete_project_task(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_project_task(UUID, TEXT)
TO authenticated;


-- ============================================================
-- 17. RPC — AÑADIR COMENTARIO
-- ============================================================

CREATE OR REPLACE FUNCTION public.add_project_task_comment(
    p_task_id UUID,
    p_comment TEXT
)
RETURNS public.project_task_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
    v_task public.project_tasks;
    v_comment TEXT;
    v_update public.project_task_updates;
BEGIN

    v_worker_id := public.current_project_task_worker_id();

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.update'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:comment:' || auth.uid()::TEXT,
        120,
        600
    );

    v_comment := NULLIF(BTRIM(p_comment), '');

    IF v_comment IS NULL THEN
        RAISE EXCEPTION
            'El comentario es obligatorio';
    END IF;

    IF LENGTH(v_comment) > 5000 THEN
        RAISE EXCEPTION
            'El comentario no puede superar 5000 caracteres';
    END IF;

    SELECT *
    INTO v_task
    FROM public.project_tasks
    WHERE id = p_task_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    INSERT INTO public.project_task_updates (
        task_id,
        actor_worker_id,
        action,
        old_status,
        old_progress,
        new_status,
        new_progress,
        comment
    )
    VALUES (
        v_task.id,
        v_worker_id,
        'comment',
        v_task.status,
        v_task.progress,
        v_task.status,
        v_task.progress,
        v_comment
    )
    RETURNING *
    INTO v_update;

    RETURN v_update;

END;
$function$;


REVOKE ALL
ON FUNCTION public.add_project_task_comment(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.add_project_task_comment(UUID, TEXT)
TO authenticated;


-- ============================================================
-- 18. RPC — HISTORIAL DE UNA TAREA
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_project_task_history(
    p_task_id UUID,
    p_limit INTEGER DEFAULT 100
)
RETURNS SETOF public.project_task_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_limit INTEGER;
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión';
    END IF;

    PERFORM public.require_current_worker_permission(
        'project_tasks.read'
    );

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:history:' || auth.uid()::TEXT,
        120,
        600
    );

    IF NOT EXISTS (
        SELECT 1
        FROM public.project_tasks
        WHERE id = p_task_id
    ) THEN
        RAISE EXCEPTION
            'Tarea no encontrada';
    END IF;

    v_limit := LEAST(
        GREATEST(COALESCE(p_limit, 100), 1),
        200
    );

    RETURN QUERY
    SELECT ptu.*
    FROM public.project_task_updates ptu
    WHERE ptu.task_id = p_task_id
    ORDER BY ptu.created_at DESC
    LIMIT v_limit;

END;
$function$;


REVOKE ALL
ON FUNCTION public.get_project_task_history(UUID, INTEGER)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_project_task_history(UUID, INTEGER)
TO authenticated;


-- ============================================================
-- 19. PROTECCIÓN ADICIONAL DEL HISTORIAL
-- ============================================================
--
-- No permitimos modificaciones ni borrados directos.
-- La creación directa también queda cerrada.
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON public.project_task_updates
FROM PUBLIC, anon, authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.project_tasks
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 20. PRIVILEGIOS DE LECTURA
-- ============================================================
--
-- El acceso funcional se realiza mediante RPC.
-- No se concede SELECT directo sobre las tablas.
-- ============================================================

REVOKE SELECT
ON public.project_tasks
FROM PUBLIC, anon, authenticated;

REVOKE SELECT
ON public.project_task_updates
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 21. PROTECCIÓN — PROJECT TASKS
-- ============================================================
--
-- Aunque alguien consiga permisos de tabla por una configuración
-- externa, la lógica de negocio continúa protegida por constraints
-- y por las RPC.
--
-- Las columnas sensibles nunca son modificables mediante
-- update_project_task().
-- ============================================================


-- ============================================================
-- 22. VERIFICACIÓN FINAL
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- TABLAS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name IN (
          'project_tasks',
          'project_task_updates'
      );

    IF v_count <> 2 THEN
        RAISE EXCEPTION
            '135 failed: faltan tablas de Project Tasks';
    END IF;


    -- --------------------------------------------------------
    -- RPC PRINCIPALES
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'create_project_task'
    ) THEN
        RAISE EXCEPTION
            '135 failed: create_project_task no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_project_tasks'
    ) THEN
        RAISE EXCEPTION
            '135 failed: get_project_tasks no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'update_project_task'
    ) THEN
        RAISE EXCEPTION
            '135 failed: update_project_task no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'review_project_task'
    ) THEN
        RAISE EXCEPTION
            '135 failed: review_project_task no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_worker_is_direction'
    ) THEN
        RAISE EXCEPTION
            '135 failed: current_worker_is_direction no existe';
    END IF;




    -- --------------------------------------------------------
    -- VERIFICAR QUE LOS PERMISOS REQUERIDOS SON RESOLUBLES
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
            '135 failed: current_worker_has_permission no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'enforce_security_rate_limit'
    ) THEN
        RAISE EXCEPTION
            '135 failed: enforce_security_rate_limit no existe';
    END IF;


    -- --------------------------------------------------------
    -- HISTORIAL
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t
          ON t.oid = c.conrelid
        JOIN pg_namespace n
          ON n.oid = t.relnamespace
        WHERE n.nspname = 'public'
          AND t.relname = 'project_task_updates'
          AND c.contype = 'f'
    ) THEN
        RAISE EXCEPTION
            '135 failed: project_task_updates no tiene FK';
    END IF;



END;
$$;

DROP FUNCTION IF EXISTS public.update_project_by_worker(uuid, text, text);
COMMIT;