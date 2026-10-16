-- ============================================================
-- MIGRATION 133
-- PROJECT TASKS CORE
-- ============================================================
--
-- Objetivo:
--   Crear el núcleo de Tareas de Proyecto de Modira.
--
-- Incluye:
--   - project_tasks
--   - project_task_updates
--   - integridad proyecto -> tarea
--   - integridad proyecto -> hito -> tarea
--   - constraints de estado, prioridad y progreso
--   - límites básicos de longitud
--   - índices
--   - updated_at
--   - protección de la relación proyecto/hito
--
-- NO incluye todavía:
--   - RLS
--   - políticas
--   - RPCs
--   - RBAC
--   - rate limiting
--
-- Eso se implementará en las migraciones 134 y 135.
-- ============================================================


BEGIN;


-- ============================================================
-- 1. PROJECT TASKS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.project_tasks (
    id UUID
        PRIMARY KEY
        DEFAULT gen_random_uuid(),

    -- --------------------------------------------------------
    -- PROJECT
    -- --------------------------------------------------------

    project_id UUID
        NOT NULL,

    -- --------------------------------------------------------
    -- OPTIONAL MILESTONE
    -- --------------------------------------------------------

    milestone_id UUID
        NULL,

    -- --------------------------------------------------------
    -- CONTENT
    -- --------------------------------------------------------

    title TEXT
        NOT NULL,

    description TEXT
        NULL,

    -- --------------------------------------------------------
    -- OWNERSHIP / ASSIGNMENT
    -- --------------------------------------------------------

    created_by_worker_id UUID
        NOT NULL,

    assigned_to_worker_id UUID
        NULL,

    -- --------------------------------------------------------
    -- WORKFLOW
    -- --------------------------------------------------------

    status TEXT
        NOT NULL
        DEFAULT 'to_do',

    progress INTEGER
        NOT NULL
        DEFAULT 0,

    priority TEXT
        NOT NULL
        DEFAULT 'normal',

    -- --------------------------------------------------------
    -- DATES
    -- --------------------------------------------------------

    due_at TIMESTAMPTZ
        NULL,

    started_at TIMESTAMPTZ
        NULL,

    submitted_for_review_at TIMESTAMPTZ
        NULL,

    completed_at TIMESTAMPTZ
        NULL,

    cancelled_at TIMESTAMPTZ
        NULL,

    -- --------------------------------------------------------
    -- AUDIT ACTORS
    -- --------------------------------------------------------

    completed_by_worker_id UUID
        NULL,

    cancelled_by_worker_id UUID
        NULL,

    -- --------------------------------------------------------
    -- TIMESTAMPS
    -- --------------------------------------------------------

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT CURRENT_TIMESTAMP,


    -- ========================================================
    -- CONTENT CONSTRAINTS
    -- ========================================================

    CONSTRAINT project_tasks_title_not_blank
        CHECK (NULLIF(BTRIM(title), '') IS NOT NULL),

    CONSTRAINT project_tasks_title_max_length
        CHECK (CHAR_LENGTH(title) <= 200),

    CONSTRAINT project_tasks_description_max_length
        CHECK (
            description IS NULL
            OR CHAR_LENGTH(description) <= 5000
        ),


    -- ========================================================
    -- STATUS
    -- ========================================================

    CONSTRAINT project_tasks_status_check
        CHECK (
            status IN (
                'to_do',
                'in_progress',
                'pending_review',
                'completed',
                'cancelled'
            )
        ),


    -- ========================================================
    -- PROGRESS
    -- ========================================================

    CONSTRAINT project_tasks_progress_check
        CHECK (
            progress >= 0
            AND progress <= 100
        ),

    CONSTRAINT project_tasks_pending_review_progress_check
        CHECK (
            status <> 'pending_review'
            OR progress = 100
        ),

    CONSTRAINT project_tasks_completed_progress_check
        CHECK (
            status <> 'completed'
            OR progress = 100
        ),


    -- ========================================================
    -- PRIORITY
    -- ========================================================

    CONSTRAINT project_tasks_priority_check
        CHECK (
            priority IN (
                'low',
                'normal',
                'high',
                'urgent'
            )
        )
);


-- ============================================================
-- 2. FOREIGN KEYS — PROJECT TASKS
-- ============================================================

ALTER TABLE public.project_tasks
    ADD CONSTRAINT project_tasks_project_id_fkey
    FOREIGN KEY (project_id)
    REFERENCES public.projects(id)
    ON DELETE RESTRICT;


ALTER TABLE public.project_tasks
    ADD CONSTRAINT project_tasks_milestone_id_fkey
    FOREIGN KEY (milestone_id)
    REFERENCES public.project_milestones(id)
    ON DELETE SET NULL;


ALTER TABLE public.project_tasks
    ADD CONSTRAINT project_tasks_created_by_worker_id_fkey
    FOREIGN KEY (created_by_worker_id)
    REFERENCES public.workers(id)
    ON DELETE RESTRICT;


ALTER TABLE public.project_tasks
    ADD CONSTRAINT project_tasks_assigned_to_worker_id_fkey
    FOREIGN KEY (assigned_to_worker_id)
    REFERENCES public.workers(id)
    ON DELETE RESTRICT;


ALTER TABLE public.project_tasks
    ADD CONSTRAINT project_tasks_completed_by_worker_id_fkey
    FOREIGN KEY (completed_by_worker_id)
    REFERENCES public.workers(id)
    ON DELETE RESTRICT;


ALTER TABLE public.project_tasks
    ADD CONSTRAINT project_tasks_cancelled_by_worker_id_fkey
    FOREIGN KEY (cancelled_by_worker_id)
    REFERENCES public.workers(id)
    ON DELETE RESTRICT;


-- ============================================================
-- 3. PROJECT TASK UPDATES / IMMUTABLE HISTORY
-- ============================================================

CREATE TABLE IF NOT EXISTS public.project_task_updates (
    id UUID
        PRIMARY KEY
        DEFAULT gen_random_uuid(),

    task_id UUID
        NOT NULL,

    actor_worker_id UUID
        NOT NULL,

    action TEXT
        NOT NULL,

    old_status TEXT
        NULL,

    old_progress INTEGER
        NULL,

    new_status TEXT
        NULL,

    new_progress INTEGER
        NULL,

    comment TEXT
        NULL,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT CURRENT_TIMESTAMP,


    -- ========================================================
    -- ACTION
    -- ========================================================

    CONSTRAINT project_task_updates_action_check
        CHECK (
            action IN (
                'created',
                'started',
                'updated',
                'reassigned',
                'progress_updated',
                'submitted_for_review',
                'review_approved',
                'review_returned',
                'direction_state_change',
                'comment',
                'cancelled'
            )
        ),


    -- ========================================================
    -- STATUS VALUES
    -- ========================================================

    CONSTRAINT project_task_updates_old_status_check
        CHECK (
            old_status IS NULL
            OR old_status IN (
                'to_do',
                'in_progress',
                'pending_review',
                'completed',
                'cancelled'
            )
        ),

    CONSTRAINT project_task_updates_new_status_check
        CHECK (
            new_status IS NULL
            OR new_status IN (
                'to_do',
                'in_progress',
                'pending_review',
                'completed',
                'cancelled'
            )
        ),


    -- ========================================================
    -- PROGRESS VALUES
    -- ========================================================

    CONSTRAINT project_task_updates_old_progress_check
        CHECK (
            old_progress IS NULL
            OR (
                old_progress >= 0
                AND old_progress <= 100
            )
        ),

    CONSTRAINT project_task_updates_new_progress_check
        CHECK (
            new_progress IS NULL
            OR (
                new_progress >= 0
                AND new_progress <= 100
            )
        ),


    -- ========================================================
    -- COMMENT SIZE
    -- ========================================================

    CONSTRAINT project_task_updates_comment_max_length
        CHECK (
            comment IS NULL
            OR CHAR_LENGTH(comment) <= 5000
        )
);


-- ============================================================
-- 4. HISTORY FOREIGN KEYS
-- ============================================================
--
-- ON DELETE RESTRICT:
--   El historial no debe desaparecer accidentalmente.
--
-- Las tareas se cancelarán lógicamente mediante RPC.
-- ============================================================

ALTER TABLE public.project_task_updates
    ADD CONSTRAINT project_task_updates_task_id_fkey
    FOREIGN KEY (task_id)
    REFERENCES public.project_tasks(id)
    ON DELETE RESTRICT;


ALTER TABLE public.project_task_updates
    ADD CONSTRAINT project_task_updates_actor_worker_id_fkey
    FOREIGN KEY (actor_worker_id)
    REFERENCES public.workers(id)
    ON DELETE RESTRICT;


-- ============================================================
-- 5. INDEXES — PROJECT TASKS
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_project_tasks_project_id
    ON public.project_tasks(project_id);


CREATE INDEX IF NOT EXISTS idx_project_tasks_milestone_id
    ON public.project_tasks(milestone_id);


CREATE INDEX IF NOT EXISTS idx_project_tasks_created_by_worker_id
    ON public.project_tasks(created_by_worker_id);


CREATE INDEX IF NOT EXISTS idx_project_tasks_assigned_to_worker_id
    ON public.project_tasks(assigned_to_worker_id);


CREATE INDEX IF NOT EXISTS idx_project_tasks_status
    ON public.project_tasks(status);


CREATE INDEX IF NOT EXISTS idx_project_tasks_priority
    ON public.project_tasks(priority);


CREATE INDEX IF NOT EXISTS idx_project_tasks_due_at
    ON public.project_tasks(due_at);


CREATE INDEX IF NOT EXISTS idx_project_tasks_project_status
    ON public.project_tasks(project_id, status);


CREATE INDEX IF NOT EXISTS idx_project_tasks_project_milestone
    ON public.project_tasks(project_id, milestone_id);


-- ============================================================
-- 6. INDEXES — HISTORY
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_project_task_updates_task_id
    ON public.project_task_updates(task_id);


CREATE INDEX IF NOT EXISTS idx_project_task_updates_actor_worker_id
    ON public.project_task_updates(actor_worker_id);


CREATE INDEX IF NOT EXISTS idx_project_task_updates_task_created_at
    ON public.project_task_updates(task_id, created_at);


-- ============================================================
-- 7. UPDATED_AT TRIGGER FUNCTION
-- ============================================================
--
-- Usamos una función específica para no depender de que exista
-- otro trigger genérico con un comportamiento diferente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_project_task_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS project_tasks_updated_at_trigger
    ON public.project_tasks;


CREATE TRIGGER project_tasks_updated_at_trigger
BEFORE UPDATE ON public.project_tasks
FOR EACH ROW
EXECUTE FUNCTION public.update_project_task_updated_at();


-- ============================================================
-- 8. VALIDATE PROJECT / MILESTONE INTEGRITY
-- ============================================================
--
-- Regla fundamental:
--
--   project_tasks.project_id
--          must equal
--   project_milestones.project_id
--
-- cuando milestone_id no sea NULL.
--
-- Esto se comprueba en la BD, independientemente de las RPC.
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_project_task_milestone()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_milestone_project_id UUID;
BEGIN

    -- --------------------------------------------------------
    -- No hay hito: tarea general del proyecto.
    -- --------------------------------------------------------

    IF NEW.milestone_id IS NULL THEN
        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- Obtener proyecto del hito.
    -- --------------------------------------------------------

    SELECT pm.project_id
    INTO v_milestone_project_id
    FROM public.project_milestones pm
    WHERE pm.id = NEW.milestone_id;


    -- --------------------------------------------------------
    -- El hito indicado debe existir.
    -- --------------------------------------------------------

    IF v_milestone_project_id IS NULL THEN
        RAISE EXCEPTION
            'El hito indicado no existe';
    END IF;


    -- --------------------------------------------------------
    -- El hito debe pertenecer al mismo proyecto.
    -- --------------------------------------------------------

    IF v_milestone_project_id IS DISTINCT FROM NEW.project_id THEN
        RAISE EXCEPTION
            'El hito indicado no pertenece al proyecto de la tarea';
    END IF;


    RETURN NEW;

END;
$function$;


DROP TRIGGER IF EXISTS project_tasks_validate_milestone_trigger
    ON public.project_tasks;


CREATE TRIGGER project_tasks_validate_milestone_trigger
BEFORE INSERT OR UPDATE OF project_id, milestone_id
ON public.project_tasks
FOR EACH ROW
EXECUTE FUNCTION public.validate_project_task_milestone();


-- ============================================================
-- 9. VERIFICATION
-- ============================================================

DO $verification$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- project_tasks
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'project_tasks';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'VERIFICATION FAILED: public.project_tasks no existe';
    END IF;


    -- --------------------------------------------------------
    -- project_task_updates
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'project_task_updates';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'VERIFICATION FAILED: public.project_task_updates no existe';
    END IF;


    -- --------------------------------------------------------
    -- project_tasks.project_id
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.project_tasks'::regclass
          AND conname = 'project_tasks_project_id_fkey'
    ) THEN
        RAISE EXCEPTION
            'VERIFICATION FAILED: FK project_tasks -> projects no existe';
    END IF;


    -- --------------------------------------------------------
    -- project_tasks.milestone_id
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.project_tasks'::regclass
          AND conname = 'project_tasks_milestone_id_fkey'
    ) THEN
        RAISE EXCEPTION
            'VERIFICATION FAILED: FK project_tasks -> project_milestones no existe';
    END IF;


    -- --------------------------------------------------------
    -- history -> task
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.project_task_updates'::regclass
          AND conname = 'project_task_updates_task_id_fkey'
    ) THEN
        RAISE EXCEPTION
            'VERIFICATION FAILED: FK history -> project_tasks no existe';
    END IF;


    -- --------------------------------------------------------
    -- milestone integrity trigger
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.project_tasks'::regclass
          AND tgname = 'project_tasks_validate_milestone_trigger'
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION
            'VERIFICATION FAILED: trigger de integridad proyecto/hito no existe';
    END IF;


    -- --------------------------------------------------------
    -- updated_at trigger
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.project_tasks'::regclass
          AND tgname = 'project_tasks_updated_at_trigger'
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION
            'VERIFICATION FAILED: trigger updated_at no existe';
    END IF;


    RAISE NOTICE
        'MIGRATION 133 OK: project_tasks core creado correctamente';

END;
$verification$;


COMMIT;