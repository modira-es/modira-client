-- ============================================================
-- MIGRATION 131
-- INTERNAL TASKS — SECURITY, RPCs, RLS, AUDIT & RATE LIMITING
-- ============================================================

BEGIN;


-- ============================================================
-- 1. PRECONDITIONS
-- ============================================================

DO $$
BEGIN

    IF to_regclass('public.internal_tasks') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: internal_tasks does not exist';
    END IF;


    IF to_regclass('public.internal_task_updates') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: internal_task_updates does not exist';
    END IF;


    IF to_regclass('public.internal_task_user_access') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: internal_task_user_access does not exist';
    END IF;


    IF to_regclass('public.internal_task_role_access') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: internal_task_role_access does not exist';
    END IF;


    IF to_regclass('public.workers') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: workers does not exist';
    END IF;


    IF to_regclass('public.worker_roles') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: worker_roles does not exist';
    END IF;


    IF to_regclass('public.worker_role_assignments') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: worker_role_assignments does not exist';
    END IF;


    IF to_regclass('public.worker_permissions') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: worker_permissions does not exist';
    END IF;


    IF to_regclass('public.worker_role_permissions') IS NULL THEN
        RAISE EXCEPTION
            '131 stopped: worker_role_permissions does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'require_current_worker_permission'
          AND p.pronargs = 1
          AND p.proargtypes[0] = 'text'::regtype::oid
    ) THEN
        RAISE EXCEPTION
            '131 stopped: require_current_worker_permission(text) does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'enforce_security_rate_limit'
          AND p.pronargs = 3
          AND p.proargtypes[0] = 'text'::regtype::oid
          AND p.proargtypes[1] = 'integer'::regtype::oid
          AND p.proargtypes[2] = 'integer'::regtype::oid
    ) THEN
        RAISE EXCEPTION
            '131 stopped: enforce_security_rate_limit(text, integer, integer) does not exist';
    END IF;

END;
$$;


-- ============================================================
-- 2. INVARIANTS ADDED TO THE TASK MODEL
-- ============================================================

ALTER TABLE public.internal_tasks
    DROP CONSTRAINT IF EXISTS internal_tasks_pending_review_progress_check;

ALTER TABLE public.internal_tasks
    ADD CONSTRAINT internal_tasks_pending_review_progress_check
    CHECK (
        status <> 'pending_review'
        OR progress = 100
    );


ALTER TABLE public.internal_tasks
    DROP CONSTRAINT IF EXISTS internal_tasks_completed_timestamp_check;

ALTER TABLE public.internal_tasks
    ADD CONSTRAINT internal_tasks_completed_timestamp_check
    CHECK (
        status <> 'completed'
        OR completed_at IS NOT NULL
    );


ALTER TABLE public.internal_tasks
    DROP CONSTRAINT IF EXISTS internal_tasks_cancelled_timestamp_check;

ALTER TABLE public.internal_tasks
    ADD CONSTRAINT internal_tasks_cancelled_timestamp_check
    CHECK (
        status <> 'cancelled'
        OR cancelled_at IS NOT NULL
    );


-- ============================================================
-- 3. HELPER — CURRENT WORKER ID
-- ============================================================

CREATE OR REPLACE FUNCTION public.internal_task_current_worker_id()
RETURNS UUID
LANGUAGE plpgsql
STABLE
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
ON FUNCTION public.internal_task_current_worker_id()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 4. HELPER — DIRECTION
-- ============================================================

CREATE OR REPLACE FUNCTION public.internal_task_current_worker_is_direction()
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RETURN FALSE;
    END IF;


    RETURN EXISTS (
        SELECT 1
        FROM public.worker_role_assignments wra
        JOIN public.worker_roles wr
          ON wr.id = wra.role_id
        WHERE wra.worker_auth_user_id = auth.uid()
          AND wr.code = 'direction'
          AND wr.is_active = TRUE
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.internal_task_current_worker_is_direction()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 5. HELPER — DEVELOPER
-- ============================================================

CREATE OR REPLACE FUNCTION public.internal_task_current_worker_is_developer()
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RETURN FALSE;
    END IF;


    RETURN EXISTS (
        SELECT 1
        FROM public.worker_role_assignments wra
        JOIN public.worker_roles wr
          ON wr.id = wra.role_id
        WHERE wra.worker_auth_user_id = auth.uid()
          AND wr.code = 'developer'
          AND wr.is_active = TRUE
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.internal_task_current_worker_is_developer()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 6. HELPER — TASK VISIBILITY
-- ============================================================

CREATE OR REPLACE FUNCTION public.internal_task_can_current_worker_view(
    p_task_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
BEGIN

    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RETURN FALSE;
    END IF;


    v_worker_id := public.internal_task_current_worker_id();


    IF v_worker_id IS NULL THEN
        RETURN FALSE;
    END IF;


    IF public.internal_task_current_worker_is_direction() THEN
        RETURN TRUE;
    END IF;


    IF EXISTS (
        SELECT 1
        FROM public.internal_tasks t
        WHERE t.id = p_task_id
          AND t.assigned_to_worker_id = v_worker_id
    ) THEN
        RETURN TRUE;
    END IF;


    IF EXISTS (
        SELECT 1
        FROM public.internal_task_user_access a
        WHERE a.task_id = p_task_id
          AND a.worker_id = v_worker_id
    ) THEN
        RETURN TRUE;
    END IF;


    IF EXISTS (
        SELECT 1
        FROM public.internal_task_role_access tra
        JOIN public.worker_role_assignments wra
          ON wra.role_id = tra.role_id
        JOIN public.worker_roles wr
          ON wr.id = tra.role_id
        WHERE tra.task_id = p_task_id
          AND wra.worker_auth_user_id = auth.uid()
          AND wr.is_active = TRUE
    ) THEN
        RETURN TRUE;
    END IF;


    RETURN FALSE;

END;
$function$;


REVOKE ALL
ON FUNCTION public.internal_task_can_current_worker_view(UUID)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 7. HELPER — AUDIT / HISTORY
-- ============================================================

CREATE OR REPLACE FUNCTION public.internal_task_record_update(
    p_task_id UUID,
    p_actor_worker_id UUID,
    p_action TEXT,
    p_old_status TEXT DEFAULT NULL,
    p_old_progress INTEGER DEFAULT NULL,
    p_new_status TEXT DEFAULT NULL,
    p_new_progress INTEGER DEFAULT NULL,
    p_comment TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    INSERT INTO public.internal_task_updates (
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
        p_actor_worker_id,
        p_action,
        p_old_status,
        p_old_progress,
        p_new_status,
        p_new_progress,
        p_comment
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.internal_task_record_update(
    UUID,
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
-- 8. RPC — CREATE TASK
-- ============================================================
--
-- Direction:
--   puede crear y asignar a cualquier worker activo.
--   puede definir visibilidad desde la creación.
--
-- Developer:
--   puede crear y asignar nuevas tareas.
--   no puede gestionar visibilidad.
--
-- Otros workers:
--   pueden crear tareas para sí mismos o sin responsable.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_internal_task(
    p_title TEXT,
    p_description TEXT DEFAULT NULL,
    p_assigned_to_worker_id UUID DEFAULT NULL,
    p_priority TEXT DEFAULT 'normal',
    p_due_at TIMESTAMPTZ DEFAULT NULL,
    p_viewer_worker_ids UUID[] DEFAULT NULL,
    p_viewer_role_ids UUID[] DEFAULT NULL
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
    v_task public.internal_tasks;
    v_viewer_worker_id UUID;
    v_viewer_role_id UUID;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.create'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:create:' || auth.uid()::TEXT,
        30,
        3600
    );


    v_worker_id := public.internal_task_current_worker_id();


    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'No se pudo determinar el trabajador actual';
    END IF;


    IF NULLIF(BTRIM(p_title), '') IS NULL THEN
        RAISE EXCEPTION
            'El título es obligatorio';
    END IF;


    IF LENGTH(BTRIM(p_title)) > 200 THEN
        RAISE EXCEPTION
            'El título no puede superar 200 caracteres';
    END IF;


    IF p_description IS NOT NULL
       AND LENGTH(p_description) > 5000
    THEN
        RAISE EXCEPTION
            'La descripción no puede superar 5000 caracteres';
    END IF;


    IF p_priority IS NULL
       OR p_priority NOT IN (
           'low',
           'normal',
           'high',
           'urgent'
       )
    THEN
        RAISE EXCEPTION
            'Prioridad no válida';
    END IF;


    IF p_assigned_to_worker_id IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM public.workers w
            WHERE w.id = p_assigned_to_worker_id
              AND w.is_active = TRUE
        ) THEN
            RAISE EXCEPTION
                'El trabajador asignado no existe o no está activo';
        END IF;


        IF NOT public.internal_task_current_worker_is_direction()
           AND NOT public.internal_task_current_worker_is_developer()
           AND p_assigned_to_worker_id IS DISTINCT FROM v_worker_id
        THEN
            RAISE EXCEPTION
                'No puedes asignar una nueva tarea a otro trabajador';
        END IF;

    END IF;


    IF NOT public.internal_task_current_worker_is_direction()
       AND (
            COALESCE(array_length(p_viewer_worker_ids, 1), 0) > 0
            OR COALESCE(array_length(p_viewer_role_ids, 1), 0) > 0
       )
    THEN
        RAISE EXCEPTION
            'Solo Dirección puede definir la visibilidad de una tarea';
    END IF;


    INSERT INTO public.internal_tasks (
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
        BTRIM(p_title),
        NULLIF(BTRIM(p_description), ''),
        v_worker_id,
        p_assigned_to_worker_id,
        'to_do',
        0,
        p_priority,
        p_due_at
    )
    RETURNING *
    INTO v_task;


    PERFORM public.internal_task_record_update(
        v_task.id,
        v_worker_id,
        'created',
        NULL,
        NULL,
        v_task.status,
        v_task.progress,
        NULL
    );


    IF public.internal_task_current_worker_is_direction() THEN

        IF p_viewer_worker_ids IS NOT NULL THEN

            FOREACH v_viewer_worker_id IN
                ARRAY p_viewer_worker_ids
            LOOP

                IF NOT EXISTS (
                    SELECT 1
                    FROM public.workers w
                    WHERE w.id = v_viewer_worker_id
                      AND w.is_active = TRUE
                ) THEN
                    RAISE EXCEPTION
                        'Uno de los trabajadores de visibilidad no existe o no está activo';
                END IF;


                INSERT INTO public.internal_task_user_access (
                    task_id,
                    worker_id
                )
                VALUES (
                    v_task.id,
                    v_viewer_worker_id
                )
                ON CONFLICT DO NOTHING;

            END LOOP;

        END IF;


        IF p_viewer_role_ids IS NOT NULL THEN

            FOREACH v_viewer_role_id IN
                ARRAY p_viewer_role_ids
            LOOP

                IF NOT EXISTS (
                    SELECT 1
                    FROM public.worker_roles wr
                    WHERE wr.id = v_viewer_role_id
                      AND wr.is_active = TRUE
                ) THEN
                    RAISE EXCEPTION
                        'Uno de los roles de visibilidad no existe o no está activo';
                END IF;


                INSERT INTO public.internal_task_role_access (
                    task_id,
                    role_id
                )
                VALUES (
                    v_task.id,
                    v_viewer_role_id
                )
                ON CONFLICT DO NOTHING;

            END LOOP;

        END IF;

    END IF;


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 9. RPC — LIST TASKS
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_internal_tasks(
    p_status TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS SETOF public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.read'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:read:' || auth.uid()::TEXT,
        300,
        600
    );


    IF p_limit IS NULL
       OR p_limit < 1
       OR p_limit > 100
    THEN
        RAISE EXCEPTION
            'El límite debe estar entre 1 y 100';
    END IF;


    IF p_offset IS NULL
       OR p_offset < 0
    THEN
        RAISE EXCEPTION
            'El offset no puede ser negativo';
    END IF;


    IF p_status IS NOT NULL
       AND p_status NOT IN (
           'to_do',
           'in_progress',
           'pending_review',
           'completed',
           'cancelled'
       )
    THEN
        RAISE EXCEPTION
            'Estado no válido';
    END IF;


    v_worker_id := public.internal_task_current_worker_id();


    RETURN QUERY
    SELECT t.*
    FROM public.internal_tasks t
    WHERE (
        public.internal_task_current_worker_is_direction()
        OR t.assigned_to_worker_id = v_worker_id
        OR EXISTS (
            SELECT 1
            FROM public.internal_task_user_access a
            WHERE a.task_id = t.id
              AND a.worker_id = v_worker_id
        )
        OR EXISTS (
            SELECT 1
            FROM public.internal_task_role_access tra
            JOIN public.worker_role_assignments wra
              ON wra.role_id = tra.role_id
            JOIN public.worker_roles wr
              ON wr.id = tra.role_id
            WHERE tra.task_id = t.id
              AND wra.worker_auth_user_id = auth.uid()
              AND wr.is_active = TRUE
        )
    )
    AND (
        p_status IS NULL
        OR t.status = p_status
    )
    ORDER BY
        CASE t.priority
            WHEN 'urgent' THEN 1
            WHEN 'high' THEN 2
            WHEN 'normal' THEN 3
            WHEN 'low' THEN 4
            ELSE 5
        END,
        t.due_at NULLS LAST,
        t.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;

END;
$function$;


-- ============================================================
-- 10. RPC — GET TASK
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_internal_task(
    p_task_id UUID
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.internal_tasks;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.read'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:get:' || auth.uid()::TEXT,
        300,
        600
    );


    IF NOT public.internal_task_can_current_worker_view(p_task_id) THEN
        RAISE EXCEPTION
            'No tienes acceso a esta tarea';
    END IF;


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 11. RPC — UPDATE TASK METADATA
-- ============================================================
--
-- p_changes admite:
--
-- {
--   "title": "...",
--   "description": "...",
--   "priority": "high",
--   "due_at": "...",
--   "assigned_to_worker_id": "..."
-- }
--
-- Direction:
--   todo.
--
-- Developer:
--   puede editar datos operativos.
--   NO puede reasignar una tarea existente.
--
-- Otros workers:
--   no pueden editar metadata.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_internal_task(
    p_task_id UUID,
    p_changes JSONB,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.internal_tasks;
    v_old_status TEXT;
    v_old_progress INTEGER;
    v_worker_id UUID;
    v_new_assigned UUID;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.update'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:update:' || auth.uid()::TEXT,
        120,
        600
    );


    IF p_changes IS NULL
       OR jsonb_typeof(p_changes) <> 'object'
    THEN
        RAISE EXCEPTION
            'Los cambios deben ser un objeto JSON';
    END IF;


    IF NOT public.internal_task_can_current_worker_view(p_task_id) THEN
        RAISE EXCEPTION
            'No tienes acceso a esta tarea';
    END IF;


    v_worker_id := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    v_old_status := v_task.status;
    v_old_progress := v_task.progress;


    IF NOT public.internal_task_current_worker_is_direction()
       AND NOT public.internal_task_current_worker_is_developer()
    THEN
        RAISE EXCEPTION
            'Este trabajador solo puede modificar el progreso mediante su operación específica';
    END IF;


    IF p_changes ? 'title' THEN

        IF NULLIF(BTRIM(p_changes ->> 'title'), '') IS NULL THEN
            RAISE EXCEPTION
                'El título no puede estar vacío';
        END IF;

        IF LENGTH(p_changes ->> 'title') > 200 THEN
            RAISE EXCEPTION
                'El título no puede superar 200 caracteres';
        END IF;

    END IF;


    IF p_changes ? 'description'
       AND p_changes ->> 'description' IS NOT NULL
       AND LENGTH(p_changes ->> 'description') > 5000
    THEN
        RAISE EXCEPTION
            'La descripción no puede superar 5000 caracteres';
    END IF;


    IF p_changes ? 'priority'
       AND p_changes ->> 'priority' NOT IN (
           'low',
           'normal',
           'high',
           'urgent'
       )
    THEN
        RAISE EXCEPTION
            'Prioridad no válida';
    END IF;


    IF p_changes ? 'assigned_to_worker_id' THEN

        IF NOT public.internal_task_current_worker_is_direction() THEN
            RAISE EXCEPTION
                'Solo Dirección puede reasignar una tarea existente';
        END IF;


        IF p_changes ->> 'assigned_to_worker_id' IS NULL THEN
            v_new_assigned := NULL;
        ELSE
            v_new_assigned :=
                (p_changes ->> 'assigned_to_worker_id')::UUID;

            IF NOT EXISTS (
                SELECT 1
                FROM public.workers w
                WHERE w.id = v_new_assigned
                  AND w.is_active = TRUE
            ) THEN
                RAISE EXCEPTION
                    'El trabajador asignado no existe o no está activo';
            END IF;

        END IF;

    END IF;


    UPDATE public.internal_tasks
    SET
        title = CASE
            WHEN p_changes ? 'title'
            THEN BTRIM(p_changes ->> 'title')
            ELSE title
        END,

        description = CASE
            WHEN p_changes ? 'description'
            THEN NULLIF(BTRIM(p_changes ->> 'description'), '')
            ELSE description
        END,

        priority = CASE
            WHEN p_changes ? 'priority'
            THEN p_changes ->> 'priority'
            ELSE priority
        END,

        due_at = CASE
            WHEN p_changes ? 'due_at'
            THEN NULLIF(p_changes ->> 'due_at', '')::TIMESTAMPTZ
            ELSE due_at
        END,

        assigned_to_worker_id = CASE
            WHEN p_changes ? 'assigned_to_worker_id'
            THEN v_new_assigned
            ELSE assigned_to_worker_id
        END,

        updated_at = CURRENT_TIMESTAMP

    WHERE id = p_task_id

    RETURNING *
    INTO v_task;


    PERFORM public.internal_task_record_update(
        p_task_id,
        v_worker_id,
        CASE
            WHEN p_changes ? 'assigned_to_worker_id'
            THEN 'reassigned'
            ELSE 'updated'
        END,
        v_old_status,
        v_old_progress,
        v_task.status,
        v_task.progress,
        p_comment
    );


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 12. RPC — START TASK
-- ============================================================

CREATE OR REPLACE FUNCTION public.start_internal_task(
    p_task_id UUID
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.internal_tasks;
    v_worker_id UUID;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.update'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:start:' || auth.uid()::TEXT,
        60,
        3600
    );


    v_worker_id := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    IF v_task.assigned_to_worker_id IS DISTINCT FROM v_worker_id THEN
        RAISE EXCEPTION
            'Solo el trabajador responsable puede iniciar esta tarea';
    END IF;


    IF v_task.status <> 'to_do' THEN
        RAISE EXCEPTION
            'La tarea no está en estado to_do';
    END IF;


    UPDATE public.internal_tasks
    SET
        status = 'in_progress',
        started_at = COALESCE(started_at, CURRENT_TIMESTAMP),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id
    RETURNING *
    INTO v_task;


    PERFORM public.internal_task_record_update(
        p_task_id,
        v_worker_id,
        'started',
        'to_do',
        v_task.progress,
        'in_progress',
        v_task.progress,
        NULL
    );


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 13. RPC — UPDATE PROGRESS
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_internal_task_progress(
    p_task_id UUID,
    p_progress INTEGER,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.internal_tasks;
    v_worker_id UUID;
    v_old_progress INTEGER;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.update'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:progress:' || auth.uid()::TEXT,
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


    v_worker_id := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    IF v_task.assigned_to_worker_id IS DISTINCT FROM v_worker_id THEN
        RAISE EXCEPTION
            'Solo el trabajador responsable puede actualizar el progreso';
    END IF;


    IF v_task.status NOT IN (
        'to_do',
        'in_progress'
    ) THEN
        RAISE EXCEPTION
            'No puedes modificar el progreso en el estado actual de la tarea';
    END IF;


    v_old_progress := v_task.progress;


    UPDATE public.internal_tasks
    SET
        progress = p_progress,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id
    RETURNING *
    INTO v_task;


    PERFORM public.internal_task_record_update(
        p_task_id,
        v_worker_id,
        'progress_updated',
        v_task.status,
        v_old_progress,
        v_task.status,
        v_task.progress,
        p_comment
    );


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 14. RPC — SUBMIT FOR REVIEW
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_internal_task_for_review(
    p_task_id UUID,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.internal_tasks;
    v_worker_id UUID;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.update'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:submit_review:' || auth.uid()::TEXT,
        30,
        3600
    );


    v_worker_id := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    IF v_task.assigned_to_worker_id IS DISTINCT FROM v_worker_id THEN
        RAISE EXCEPTION
            'Solo el trabajador responsable puede enviar la tarea a revisión';
    END IF;


    IF v_task.status <> 'in_progress' THEN
        RAISE EXCEPTION
            'Solo una tarea en progreso puede enviarse a revisión';
    END IF;


    IF v_task.progress <> 100 THEN
        RAISE EXCEPTION
            'Una tarea debe estar al 100%% antes de enviarse a revisión';
    END IF;


    UPDATE public.internal_tasks
    SET
        status = 'pending_review',
        progress = 100,
        submitted_for_review_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id
    RETURNING *
    INTO v_task;


    PERFORM public.internal_task_record_update(
        p_task_id,
        v_worker_id,
        'submitted_for_review',
        'in_progress',
        100,
        'pending_review',
        100,
        p_comment
    );


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 15. RPC — REVIEW TASK
-- ============================================================
--
-- p_decision:
--
--   approved
--   returned
--
-- approved:
--   pending_review -> completed
--
-- returned:
--   pending_review -> in_progress
--
-- Solo Direction.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.review_internal_task(
    p_task_id UUID,
    p_decision TEXT,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.internal_tasks;
    v_worker_id UUID;
    v_old_status TEXT;
    v_old_progress INTEGER;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.review'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:review:' || auth.uid()::TEXT,
        60,
        3600
    );


    IF NOT public.internal_task_current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede revisar tareas';
    END IF;


    IF p_decision NOT IN (
        'approved',
        'returned'
    ) THEN
        RAISE EXCEPTION
            'La decisión debe ser approved o returned';
    END IF;


    v_worker_id := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    IF v_task.status <> 'pending_review' THEN
        RAISE EXCEPTION
            'Solo se pueden revisar tareas pendientes de revisión';
    END IF;


    v_old_status := v_task.status;
    v_old_progress := v_task.progress;


    IF p_decision = 'approved' THEN

        UPDATE public.internal_tasks
        SET
            status = 'completed',
            progress = 100,
            completed_at = CURRENT_TIMESTAMP,
            completed_by_worker_id = v_worker_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id
        RETURNING *
        INTO v_task;


        PERFORM public.internal_task_record_update(
            p_task_id,
            v_worker_id,
            'review_approved',
            v_old_status,
            v_old_progress,
            'completed',
            100,
            p_comment
        );

    ELSE

        UPDATE public.internal_tasks
        SET
            status = 'in_progress',
            completed_at = NULL,
            completed_by_worker_id = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id
        RETURNING *
        INTO v_task;


        PERFORM public.internal_task_record_update(
            p_task_id,
            v_worker_id,
            'review_returned',
            v_old_status,
            v_old_progress,
            'in_progress',
            v_task.progress,
            p_comment
        );

    END IF;


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 16. RPC — DIRECTION STATE CONTROL
-- ============================================================
--
-- Dirección puede intervenir directamente:
--
--   to_do
--   in_progress
--   pending_review
--   completed
--   cancelled
--
-- Permite también reabrir tareas completadas.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.direction_set_internal_task_state(
    p_task_id UUID,
    p_status TEXT,
    p_progress INTEGER,
    p_comment TEXT DEFAULT NULL
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.internal_tasks;
    v_worker_id UUID;
    v_old_status TEXT;
    v_old_progress INTEGER;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.update'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:direction_state:' || auth.uid()::TEXT,
        120,
        3600
    );


    IF NOT public.internal_task_current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede cambiar manualmente el estado de una tarea';
    END IF;


    IF p_status NOT IN (
        'to_do',
        'in_progress',
        'pending_review',
        'completed',
        'cancelled'
    ) THEN
        RAISE EXCEPTION
            'Estado no válido';
    END IF;


    IF p_progress IS NULL
       OR p_progress < 0
       OR p_progress > 100
    THEN
        RAISE EXCEPTION
            'El progreso debe estar entre 0 y 100';
    END IF;


    IF p_status = 'pending_review'
       AND p_progress <> 100
    THEN
        RAISE EXCEPTION
            'Una tarea pendiente de revisión debe estar al 100%%';
    END IF;


    IF p_status = 'completed'
       AND p_progress <> 100
    THEN
        RAISE EXCEPTION
            'Una tarea completada debe estar al 100%%';
    END IF;


    v_worker_id := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    v_old_status := v_task.status;
    v_old_progress := v_task.progress;


    UPDATE public.internal_tasks
    SET
        status = p_status,
        progress = p_progress,

        started_at = CASE
            WHEN p_status = 'in_progress'
            THEN COALESCE(started_at, CURRENT_TIMESTAMP)
            ELSE started_at
        END,

        submitted_for_review_at = CASE
            WHEN p_status = 'pending_review'
            THEN COALESCE(submitted_for_review_at, CURRENT_TIMESTAMP)
            WHEN p_status IN ('to_do', 'in_progress')
            THEN NULL
            ELSE submitted_for_review_at
        END,

        completed_at = CASE
            WHEN p_status = 'completed'
            THEN COALESCE(completed_at, CURRENT_TIMESTAMP)
            WHEN p_status <> 'completed'
            THEN NULL
            ELSE completed_at
        END,

        completed_by_worker_id = CASE
            WHEN p_status = 'completed'
            THEN v_worker_id
            WHEN p_status <> 'completed'
            THEN NULL
            ELSE completed_by_worker_id
        END,

        cancelled_at = CASE
            WHEN p_status = 'cancelled'
            THEN COALESCE(cancelled_at, CURRENT_TIMESTAMP)
            WHEN p_status <> 'cancelled'
            THEN NULL
            ELSE cancelled_at
        END,

        cancelled_by_worker_id = CASE
            WHEN p_status = 'cancelled'
            THEN v_worker_id
            WHEN p_status <> 'cancelled'
            THEN NULL
            ELSE cancelled_by_worker_id
        END,

        updated_at = CURRENT_TIMESTAMP

    WHERE id = p_task_id

    RETURNING *
    INTO v_task;


    PERFORM public.internal_task_record_update(
        p_task_id,
        v_worker_id,
        'direction_state_change',
        v_old_status,
        v_old_progress,
        v_task.status,
        v_task.progress,
        p_comment
    );


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 17. RPC — CANCEL / DELETE TASK
-- ============================================================
--
-- NO se elimina físicamente.
--
-- Se marca como cancelled para preservar permanentemente
-- el historial.
--
-- Solo Direction.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_internal_task(
    p_task_id UUID,
    p_reason TEXT DEFAULT NULL
)
RETURNS public.internal_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_task public.internal_tasks;
    v_worker_id UUID;
    v_old_status TEXT;
    v_old_progress INTEGER;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.delete'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:delete:' || auth.uid()::TEXT,
        30,
        3600
    );


    IF NOT public.internal_task_current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede anular una tarea';
    END IF;


    IF NULLIF(BTRIM(p_reason), '') IS NULL THEN
        RAISE EXCEPTION
            'Debes indicar el motivo de la anulación';
    END IF;


    v_worker_id := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    IF v_task.status = 'cancelled' THEN
        RAISE EXCEPTION
            'La tarea ya está anulada';
    END IF;


    v_old_status := v_task.status;
    v_old_progress := v_task.progress;


    UPDATE public.internal_tasks
    SET
        status = 'cancelled',
        cancelled_at = CURRENT_TIMESTAMP,
        cancelled_by_worker_id = v_worker_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id
    RETURNING *
    INTO v_task;


    PERFORM public.internal_task_record_update(
        p_task_id,
        v_worker_id,
        'cancelled',
        v_old_status,
        v_old_progress,
        'cancelled',
        v_task.progress,
        BTRIM(p_reason)
    );


    RETURN v_task;

END;
$function$;


-- ============================================================
-- 18. RPC — ADD COMMENT / UPDATE
-- ============================================================

CREATE OR REPLACE FUNCTION public.add_internal_task_comment(
    p_task_id UUID,
    p_comment TEXT
)
RETURNS public.internal_task_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
    v_task public.internal_tasks;
    v_update public.internal_task_updates;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.update'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:comment:' || auth.uid()::TEXT,
        120,
        600
    );


    IF NULLIF(BTRIM(p_comment), '') IS NULL THEN
        RAISE EXCEPTION
            'El comentario no puede estar vacío';
    END IF;


    IF LENGTH(p_comment) > 5000 THEN
        RAISE EXCEPTION
            'El comentario no puede superar 5000 caracteres';
    END IF;


    IF NOT public.internal_task_can_current_worker_view(p_task_id) THEN
        RAISE EXCEPTION
            'No tienes acceso a esta tarea';
    END IF;


    v_worker_id := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    INSERT INTO public.internal_task_updates (
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
        'comment',
        v_task.status,
        v_task.progress,
        v_task.status,
        v_task.progress,
        BTRIM(p_comment)
    )
    RETURNING *
    INTO v_update;


    RETURN v_update;

END;
$function$;


-- ============================================================
-- 19. RPC — GET TASK HISTORY
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_internal_task_history(
    p_task_id UUID,
    p_limit INTEGER DEFAULT 100,
    p_offset INTEGER DEFAULT 0
)
RETURNS SETOF public.internal_task_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.read'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:history:' || auth.uid()::TEXT,
        300,
        600
    );


    IF p_limit IS NULL
       OR p_limit < 1
       OR p_limit > 200
    THEN
        RAISE EXCEPTION
            'El límite debe estar entre 1 y 200';
    END IF;


    IF p_offset IS NULL
       OR p_offset < 0
    THEN
        RAISE EXCEPTION
            'El offset no puede ser negativo';
    END IF;


    IF NOT public.internal_task_can_current_worker_view(p_task_id) THEN
        RAISE EXCEPTION
            'No tienes acceso al historial de esta tarea';
    END IF;


    RETURN QUERY
    SELECT u.*
    FROM public.internal_task_updates u
    WHERE u.task_id = p_task_id
    ORDER BY u.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;

END;
$function$;


-- ============================================================
-- 20. RPC — GET VISIBILITY
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_internal_task_visibility(
    p_task_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_result JSONB;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.read'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:visibility_read:' || auth.uid()::TEXT,
        300,
        600
    );


    IF NOT public.internal_task_can_current_worker_view(p_task_id) THEN
        RAISE EXCEPTION
            'No tienes acceso a esta tarea';
    END IF;


    SELECT jsonb_build_object(
        'workers',
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'worker_id', a.worker_id,
                        'display_name', w.display_name,
                        'created_at', a.created_at
                    )
                    ORDER BY w.display_name
                )
                FROM public.internal_task_user_access a
                JOIN public.workers w
                  ON w.id = a.worker_id
                WHERE a.task_id = p_task_id
            ),
            '[]'::JSONB
        ),

        'roles',
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'role_id', a.role_id,
                        'code', wr.code,
                        'name', wr.name,
                        'created_at', a.created_at
                    )
                    ORDER BY wr.name
                )
                FROM public.internal_task_role_access a
                JOIN public.worker_roles wr
                  ON wr.id = a.role_id
                WHERE a.task_id = p_task_id
            ),
            '[]'::JSONB
        )
    )
    INTO v_result;


    RETURN v_result;

END;
$function$;


-- ============================================================
-- 21. RPC — SET VISIBILITY
-- ============================================================
--
-- Dirección sustituye la configuración existente por la nueva.
--
-- p_worker_ids:
--   trabajadores concretos.
--
-- p_role_ids:
--   roles concretos.
--
-- El responsable NO necesita aparecer aquí.
-- Siempre conserva acceso.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_internal_task_visibility(
    p_task_id UUID,
    p_worker_ids UUID[] DEFAULT NULL,
    p_role_ids UUID[] DEFAULT NULL,
    p_comment TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_worker_id UUID;
    v_role_id UUID;
    v_actor UUID;
    v_task public.internal_tasks;
    v_result JSONB;
BEGIN

    PERFORM public.require_current_worker_permission(
        'internal_tasks.manage_visibility'
    );


    PERFORM public.enforce_security_rate_limit(
        'internal_tasks:visibility_write:' || auth.uid()::TEXT,
        60,
        3600
    );


    IF NOT public.internal_task_current_worker_is_direction() THEN
        RAISE EXCEPTION
            'Solo Dirección puede gestionar la visibilidad';
    END IF;


    v_actor := public.internal_task_current_worker_id();


    SELECT *
    INTO v_task
    FROM public.internal_tasks
    WHERE id = p_task_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La tarea no existe';
    END IF;


    DELETE FROM public.internal_task_user_access
    WHERE task_id = p_task_id;


    DELETE FROM public.internal_task_role_access
    WHERE task_id = p_task_id;


    IF p_worker_ids IS NOT NULL THEN

        FOREACH v_worker_id IN ARRAY p_worker_ids
        LOOP

            IF NOT EXISTS (
                SELECT 1
                FROM public.workers w
                WHERE w.id = v_worker_id
                  AND w.is_active = TRUE
            ) THEN
                RAISE EXCEPTION
                    'Uno de los trabajadores seleccionados no existe o no está activo';
            END IF;


            INSERT INTO public.internal_task_user_access (
                task_id,
                worker_id
            )
            VALUES (
                p_task_id,
                v_worker_id
            )
            ON CONFLICT DO NOTHING;

        END LOOP;

    END IF;


    IF p_role_ids IS NOT NULL THEN

        FOREACH v_role_id IN ARRAY p_role_ids
        LOOP

            IF NOT EXISTS (
                SELECT 1
                FROM public.worker_roles wr
                WHERE wr.id = v_role_id
                  AND wr.is_active = TRUE
            ) THEN
                RAISE EXCEPTION
                    'Uno de los roles seleccionados no existe o no está activo';
            END IF;


            INSERT INTO public.internal_task_role_access (
                task_id,
                role_id
            )
            VALUES (
                p_task_id,
                v_role_id
            )
            ON CONFLICT DO NOTHING;

        END LOOP;

    END IF;


    PERFORM public.internal_task_record_update(
        p_task_id,
        v_actor,
        'visibility_changed',
        v_task.status,
        v_task.progress,
        v_task.status,
        v_task.progress,
        COALESCE(
            BTRIM(p_comment),
            'Visibilidad de la tarea actualizada'
        )
    );


    SELECT jsonb_build_object(
        'workers',
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'worker_id', a.worker_id,
                        'display_name', w.display_name
                    )
                    ORDER BY w.display_name
                )
                FROM public.internal_task_user_access a
                JOIN public.workers w
                  ON w.id = a.worker_id
                WHERE a.task_id = p_task_id
            ),
            '[]'::JSONB
        ),

        'roles',
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'role_id', a.role_id,
                        'code', wr.code,
                        'name', wr.name
                    )
                    ORDER BY wr.name
                )
                FROM public.internal_task_role_access a
                JOIN public.worker_roles wr
                  ON wr.id = a.role_id
                WHERE a.task_id = p_task_id
            ),
            '[]'::JSONB
        )
    )
    INTO v_result;


    RETURN v_result;

END;
$function$;


-- ============================================================
-- 22. RLS
-- ============================================================

ALTER TABLE public.internal_tasks ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.internal_task_updates ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.internal_task_user_access ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.internal_task_role_access ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 23. RLS — TASKS SELECT
-- ============================================================

DROP POLICY IF EXISTS internal_tasks_worker_select
ON public.internal_tasks;

CREATE POLICY internal_tasks_worker_select
ON public.internal_tasks
FOR SELECT
TO authenticated
USING (
    public.internal_task_can_current_worker_view(id)
);


-- ============================================================
-- 24. RLS — HISTORY SELECT
-- ============================================================

DROP POLICY IF EXISTS internal_task_updates_worker_select
ON public.internal_task_updates;

CREATE POLICY internal_task_updates_worker_select
ON public.internal_task_updates
FOR SELECT
TO authenticated
USING (
    public.internal_task_can_current_worker_view(task_id)
);


-- ============================================================
-- 25. RLS — USER VISIBILITY SELECT
-- ============================================================

DROP POLICY IF EXISTS internal_task_user_access_worker_select
ON public.internal_task_user_access;

CREATE POLICY internal_task_user_access_worker_select
ON public.internal_task_user_access
FOR SELECT
TO authenticated
USING (
    public.internal_task_can_current_worker_view(task_id)
);


-- ============================================================
-- 26. RLS — ROLE VISIBILITY SELECT
-- ============================================================

DROP POLICY IF EXISTS internal_task_role_access_worker_select
ON public.internal_task_role_access;

CREATE POLICY internal_task_role_access_worker_select
ON public.internal_task_role_access
FOR SELECT
TO authenticated
USING (
    public.internal_task_can_current_worker_view(task_id)
);


-- ============================================================
-- 27. DIRECT WRITE PROTECTION
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON public.internal_tasks
FROM PUBLIC, anon, authenticated;


REVOKE INSERT, UPDATE, DELETE
ON public.internal_task_updates
FROM PUBLIC, anon, authenticated;


REVOKE INSERT, UPDATE, DELETE
ON public.internal_task_user_access
FROM PUBLIC, anon, authenticated;


REVOKE INSERT, UPDATE, DELETE
ON public.internal_task_role_access
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 28. DIRECT SELECT PROTECTION
-- ============================================================
--
-- Las lecturas del Employee Area pasan por las RPC.
-- Esto permite que todas las lecturas nuevas tengan rate limit.
--
-- ============================================================

REVOKE SELECT
ON public.internal_tasks
FROM PUBLIC, anon, authenticated;


REVOKE SELECT
ON public.internal_task_updates
FROM PUBLIC, anon, authenticated;


REVOKE SELECT
ON public.internal_task_user_access
FROM PUBLIC, anon, authenticated;


REVOKE SELECT
ON public.internal_task_role_access
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 29. RPC EXECUTE PRIVILEGES
-- ============================================================

REVOKE ALL
ON FUNCTION public.create_internal_task(
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TIMESTAMPTZ,
    UUID[],
    UUID[]
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_internal_task(
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TIMESTAMPTZ,
    UUID[],
    UUID[]
)
TO authenticated;


REVOKE ALL
ON FUNCTION public.get_internal_tasks(
    TEXT,
    INTEGER,
    INTEGER
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_internal_tasks(
    TEXT,
    INTEGER,
    INTEGER
)
TO authenticated;


REVOKE ALL
ON FUNCTION public.get_internal_task(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_internal_task(UUID)
TO authenticated;


REVOKE ALL
ON FUNCTION public.update_internal_task(UUID, JSONB, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_internal_task(UUID, JSONB, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.start_internal_task(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.start_internal_task(UUID)
TO authenticated;


REVOKE ALL
ON FUNCTION public.update_internal_task_progress(UUID, INTEGER, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_internal_task_progress(UUID, INTEGER, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.submit_internal_task_for_review(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.submit_internal_task_for_review(UUID, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.review_internal_task(UUID, TEXT, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.review_internal_task(UUID, TEXT, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.direction_set_internal_task_state(UUID, TEXT, INTEGER, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.direction_set_internal_task_state(UUID, TEXT, INTEGER, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.delete_internal_task(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_internal_task(UUID, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.add_internal_task_comment(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.add_internal_task_comment(UUID, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.get_internal_task_history(UUID, INTEGER, INTEGER)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_internal_task_history(UUID, INTEGER, INTEGER)
TO authenticated;


REVOKE ALL
ON FUNCTION public.get_internal_task_visibility(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_internal_task_visibility(UUID)
TO authenticated;


REVOKE ALL
ON FUNCTION public.set_internal_task_visibility(UUID, UUID[], UUID[], TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.set_internal_task_visibility(UUID, UUID[], UUID[], TEXT)
TO authenticated;


-- ============================================================
-- 30. SECURITY DEFINER SEARCH PATH
-- ============================================================

ALTER FUNCTION public.internal_task_current_worker_id()
SET search_path = public, pg_temp;

ALTER FUNCTION public.internal_task_current_worker_is_direction()
SET search_path = public, pg_temp;

ALTER FUNCTION public.internal_task_current_worker_is_developer()
SET search_path = public, pg_temp;

ALTER FUNCTION public.internal_task_can_current_worker_view(UUID)
SET search_path = public, pg_temp;

ALTER FUNCTION public.internal_task_record_update(
    UUID,
    UUID,
    TEXT,
    TEXT,
    INTEGER,
    TEXT,
    INTEGER,
    TEXT
)
SET search_path = public, pg_temp;

ALTER FUNCTION public.create_internal_task(
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TIMESTAMPTZ,
    UUID[],
    UUID[]
)
SET search_path = public, pg_temp;

ALTER FUNCTION public.get_internal_tasks(
    TEXT,
    INTEGER,
    INTEGER
)
SET search_path = public, pg_temp;

ALTER FUNCTION public.get_internal_task(UUID)
SET search_path = public, pg_temp;

ALTER FUNCTION public.update_internal_task(UUID, JSONB, TEXT)
SET search_path = public, pg_temp;

ALTER FUNCTION public.start_internal_task(UUID)
SET search_path = public, pg_temp;

ALTER FUNCTION public.update_internal_task_progress(UUID, INTEGER, TEXT)
SET search_path = public, pg_temp;

ALTER FUNCTION public.submit_internal_task_for_review(UUID, TEXT)
SET search_path = public, pg_temp;

ALTER FUNCTION public.review_internal_task(UUID, TEXT, TEXT)
SET search_path = public, pg_temp;

ALTER FUNCTION public.direction_set_internal_task_state(UUID, TEXT, INTEGER, TEXT)
SET search_path = public, pg_temp;

ALTER FUNCTION public.delete_internal_task(UUID, TEXT)
SET search_path = public, pg_temp;

ALTER FUNCTION public.add_internal_task_comment(UUID, TEXT)
SET search_path = public, pg_temp;

ALTER FUNCTION public.get_internal_task_history(UUID, INTEGER, INTEGER)
SET search_path = public, pg_temp;

ALTER FUNCTION public.get_internal_task_visibility(UUID)
SET search_path = public, pg_temp;

ALTER FUNCTION public.set_internal_task_visibility(UUID, UUID[], UUID[], TEXT)
SET search_path = public, pg_temp;


-- ============================================================
-- 31. COMMENTS
-- ============================================================

COMMENT ON FUNCTION public.create_internal_task(
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TIMESTAMPTZ,
    UUID[],
    UUID[]
)
IS
'Creates an internal task through the controlled worker RBAC flow. Applies task creation rate limiting and optional Direction-only visibility configuration.';


COMMENT ON FUNCTION public.get_internal_tasks(
    TEXT,
    INTEGER,
    INTEGER
)
IS
'Returns internal tasks visible to the current active worker. Reads are rate limited.';


COMMENT ON FUNCTION public.review_internal_task(UUID, TEXT, TEXT)
IS
'Direction-only task review. Approves pending review to completed or returns it to in_progress.';


COMMENT ON FUNCTION public.delete_internal_task(UUID, TEXT)
IS
'Direction-only logical task deletion. The task is cancelled instead of physically deleted so the complete audit history remains available.';


COMMENT ON TABLE public.internal_task_updates
IS
'Immutable internal task audit/history. Frontend users cannot insert, update or delete records directly.';


-- ============================================================
-- 32. FINAL SECURITY VERIFICATION
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Tables
    -- --------------------------------------------------------

    IF to_regclass('public.internal_tasks') IS NULL THEN
        RAISE EXCEPTION
            '131 verification failed: internal_tasks missing';
    END IF;


    IF to_regclass('public.internal_task_updates') IS NULL THEN
        RAISE EXCEPTION
            '131 verification failed: internal_task_updates missing';
    END IF;


    IF to_regclass('public.internal_task_user_access') IS NULL THEN
        RAISE EXCEPTION
            '131 verification failed: internal_task_user_access missing';
    END IF;


    IF to_regclass('public.internal_task_role_access') IS NULL THEN
        RAISE EXCEPTION
            '131 verification failed: internal_task_role_access missing';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_class
    WHERE oid IN (
        'public.internal_tasks'::regclass,
        'public.internal_task_updates'::regclass,
        'public.internal_task_user_access'::regclass,
        'public.internal_task_role_access'::regclass
    )
    AND relrowsecurity = TRUE;


    IF v_count <> 4 THEN
        RAISE EXCEPTION
            '131 verification failed: all four task tables must have RLS enabled';
    END IF;


    -- --------------------------------------------------------
    -- Permissions
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM public.worker_permissions
    WHERE code IN (
        'internal_tasks.create',
        'internal_tasks.read',
        'internal_tasks.update',
        'internal_tasks.assign',
        'internal_tasks.review',
        'internal_tasks.complete',
        'internal_tasks.delete',
        'internal_tasks.manage_visibility'
    );


    IF v_count <> 8 THEN
        RAISE EXCEPTION
            '131 verification failed: expected 8 internal task permissions, found %',
            v_count;
    END IF;


    -- --------------------------------------------------------
    -- Required RPCs
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'create_internal_task',
          'get_internal_tasks',
          'get_internal_task',
          'update_internal_task',
          'start_internal_task',
          'update_internal_task_progress',
          'submit_internal_task_for_review',
          'review_internal_task',
          'direction_set_internal_task_state',
          'delete_internal_task',
          'add_internal_task_comment',
          'get_internal_task_history',
          'get_internal_task_visibility',
          'set_internal_task_visibility'
      )
      AND p.prosecdef = TRUE;


    IF v_count <> 14 THEN
        RAISE EXCEPTION
            '131 verification failed: expected 14 SECURITY DEFINER task RPCs, found %',
            v_count;
    END IF;


    -- --------------------------------------------------------
    -- Required helper functions
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'internal_task_current_worker_id',
          'internal_task_current_worker_is_direction',
          'internal_task_current_worker_is_developer',
          'internal_task_can_current_worker_view',
          'internal_task_record_update'
      )
      AND p.prosecdef = TRUE;


    IF v_count <> 5 THEN
        RAISE EXCEPTION
            '131 verification failed: required SECURITY DEFINER helpers missing';
    END IF;


    -- --------------------------------------------------------
    -- Direct INSERT / UPDATE / DELETE protection
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.internal_tasks',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '131 verification failed: authenticated still has INSERT on internal_tasks';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.internal_tasks',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '131 verification failed: authenticated still has UPDATE on internal_tasks';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.internal_tasks',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '131 verification failed: authenticated still has DELETE on internal_tasks';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.internal_task_updates',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '131 verification failed: authenticated still has INSERT on internal_task_updates';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.internal_task_updates',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '131 verification failed: authenticated still has UPDATE on internal_task_updates';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.internal_task_updates',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '131 verification failed: authenticated still has DELETE on internal_task_updates';
    END IF;


    -- --------------------------------------------------------
    -- Pending review invariant
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.internal_tasks'::regclass
          AND conname = 'internal_tasks_pending_review_progress_check'
    ) THEN
        RAISE EXCEPTION
            '131 verification failed: pending review progress constraint missing';
    END IF;


    -- --------------------------------------------------------
    -- Audit history must not cascade-delete
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM pg_constraint c
        WHERE c.conrelid = 'public.internal_task_updates'::regclass
          AND c.conname = 'internal_task_updates_task_fkey'
          AND pg_get_constraintdef(c.oid) ILIKE '%ON DELETE CASCADE%'
    ) THEN
        RAISE EXCEPTION
            '131 verification failed: task history cannot use ON DELETE CASCADE';
    END IF;


END;
$$;


COMMIT;