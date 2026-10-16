-- 136_project_tasks_recommendations.sql

BEGIN;

ALTER TABLE public.project_tasks
ADD COLUMN IF NOT EXISTS recommended_worker_id UUID NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'project_tasks_recommended_worker_id_fkey'
          AND conrelid = 'public.project_tasks'::regclass
    ) THEN
        ALTER TABLE public.project_tasks
        ADD CONSTRAINT project_tasks_recommended_worker_id_fkey
        FOREIGN KEY (recommended_worker_id)
        REFERENCES public.workers(id)
        ON DELETE SET NULL;
    END IF;
END
$$;

DROP FUNCTION IF EXISTS public.create_project_task(
    UUID, TEXT, TEXT, UUID, UUID, TEXT, TIMESTAMPTZ
);

CREATE OR REPLACE FUNCTION public.create_project_task(
    p_project_id UUID,
    p_title TEXT,
    p_description TEXT DEFAULT NULL,
    p_milestone_id UUID DEFAULT NULL,
    p_assigned_to_worker_id UUID DEFAULT NULL,
    p_recommended_worker_id UUID DEFAULT NULL,
    p_priority TEXT DEFAULT 'normal',
    p_due_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS public.project_tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_worker_id UUID;
    v_task public.project_tasks;
    v_title TEXT;
    v_description TEXT;
    v_priority TEXT;
BEGIN
    v_worker_id := public.current_project_task_worker_id();

    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador activo';
    END IF;

    PERFORM public.require_current_worker_permission('project_tasks.create');

    PERFORM public.enforce_security_rate_limit(
        'project_tasks:create:' || auth.uid()::TEXT,
        30,
        3600
    );

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION 'El proyecto es obligatorio';
    END IF;

    IF NOT public.project_task_project_exists(p_project_id) THEN
        RAISE EXCEPTION 'El proyecto no existe';
    END IF;

    v_title := NULLIF(BTRIM(p_title), '');

    IF v_title IS NULL THEN
        RAISE EXCEPTION 'El título es obligatorio';
    END IF;

    IF LENGTH(v_title) > 200 THEN
        RAISE EXCEPTION 'El título no puede superar 200 caracteres';
    END IF;

    v_description := NULLIF(BTRIM(p_description), '');

    IF v_description IS NOT NULL
       AND LENGTH(v_description) > 5000
    THEN
        RAISE EXCEPTION 'La descripción no puede superar 5000 caracteres';
    END IF;

    v_priority := LOWER(BTRIM(COALESCE(p_priority, 'normal')));

    IF v_priority NOT IN ('low', 'normal', 'high', 'urgent') THEN
        RAISE EXCEPTION 'Prioridad no válida';
    END IF;

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

    -- La asignación real solo puede hacerla Dirección.
    -- El Developer ya no puede asignarse ni asignar a otro worker.
    IF p_assigned_to_worker_id IS NOT NULL THEN
        IF NOT public.current_worker_is_direction() THEN
            RAISE EXCEPTION
                'Solo Dirección puede asignar directamente una tarea a un trabajador';
        END IF;

        PERFORM public.validate_project_task_assignee(
            p_assigned_to_worker_id
        );
    END IF;

    -- La recomendación es solo una sugerencia para Dirección.
    -- Debe corresponder a un worker activo.
    IF p_recommended_worker_id IS NOT NULL THEN
        PERFORM public.validate_project_task_assignee(
            p_recommended_worker_id
        );
    END IF;

    INSERT INTO public.project_tasks (
        project_id,
        milestone_id,
        title,
        description,
        created_by_worker_id,
        assigned_to_worker_id,
        recommended_worker_id,
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
        p_recommended_worker_id,
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
$$;

REVOKE ALL
ON FUNCTION public.create_project_task(
    UUID, TEXT, TEXT, UUID, UUID, UUID, TEXT, TIMESTAMPTZ
)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.create_project_task(
    UUID, TEXT, TEXT, UUID, UUID, UUID, TEXT, TIMESTAMPTZ
)
TO authenticated;



DROP POLICY IF EXISTS workers_select_direction_active
ON public.workers;

CREATE POLICY workers_select_direction_active
ON public.workers
FOR SELECT
TO authenticated
USING (
    is_active = true
    AND EXISTS (
        SELECT 1
        FROM public.worker_role_assignments wra
        JOIN public.worker_roles wr
          ON wr.id = wra.role_id
        WHERE wra.worker_auth_user_id = auth.uid()
          AND wr.code = 'direction'
          AND wr.is_active = true
    )
);
DROP POLICY IF EXISTS workers_select_direction_active
ON public.workers;


COMMIT;
