-- ============================================================
-- MODIRA — 128_internal_tasks_core.sql
-- ============================================================
--
-- OBJETIVO
--   Crear la infraestructura base del sistema de tareas internas.
--
-- INCLUYE
--   1. public.internal_tasks
--   2. public.internal_task_updates
--   3. Relaciones con public.workers
--   4. Estados y progreso
--   5. Prioridades
--   6. Fechas del ciclo de vida
--   7. Historial/auditoría
--   8. Índices
--   9. RLS con acceso cerrado por defecto
--
-- NO INCLUYE TODAVÍA
--   - permisos RBAC
--   - asignación de permisos a roles
--   - RPCs de negocio
--   - visibilidad por usuarios
--   - visibilidad por roles
--   - políticas RLS de lectura/escritura para workers
--
-- Esas partes se implementarán en las migraciones posteriores.
--
-- ============================================================

BEGIN;


-- ============================================================
-- 1. PRECONDICIONES
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    ) THEN

        RAISE EXCEPTION
            '128 stopped: public.workers does not exist';

    END IF;

END
$$;


-- ============================================================
-- 2. TABLA PRINCIPAL — internal_tasks
-- ============================================================
--
-- Una tarea representa trabajo interno de MODIRA.
--
-- El responsable de la tarea se identifica mediante workers.id.
--
-- La identidad Auth del trabajador NO se duplica aquí:
-- workers.auth_user_id ya proporciona esa relación.
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.internal_tasks (

    id UUID
        PRIMARY KEY
        DEFAULT gen_random_uuid(),


    -- ========================================================
    -- CONTENIDO
    -- ========================================================

    title TEXT
        NOT NULL,

    description TEXT
        NULL,


    -- ========================================================
    -- AUTORÍA
    -- ========================================================

    created_by_worker_id UUID
        NOT NULL
        REFERENCES public.workers(id)
        ON DELETE RESTRICT,


    -- ========================================================
    -- RESPONSABLE
    -- ========================================================
    --
    -- NULL permite que exista una tarea todavía sin asignar.
    --
    -- Por defecto, una tarea no asignada estará en TO DO.
    --
    -- ========================================================

    assigned_to_worker_id UUID
        NULL
        REFERENCES public.workers(id)
        ON DELETE RESTRICT,


    -- ========================================================
    -- ESTADO
    -- ========================================================
    --
    -- Valores permitidos:
    --
    --   to_do
    --   in_progress
    --   pending_review
    --   completed
    --   cancelled
    --
    -- ========================================================

    status TEXT
        NOT NULL
        DEFAULT 'to_do',

    CONSTRAINT internal_tasks_status_check
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
    -- PROGRESO
    -- ========================================================

    progress INTEGER
        NOT NULL
        DEFAULT 0,

    CONSTRAINT internal_tasks_progress_check
        CHECK (
            progress BETWEEN 0 AND 100
        ),


    -- ========================================================
    -- PRIORIDAD
    -- ========================================================

    priority TEXT
        NOT NULL
        DEFAULT 'normal',

    CONSTRAINT internal_tasks_priority_check
        CHECK (
            priority IN (
                'low',
                'normal',
                'high',
                'urgent'
            )
        ),


    -- ========================================================
    -- FECHA LÍMITE
    -- ========================================================

    due_at TIMESTAMPTZ
        NULL,


    -- ========================================================
    -- CICLO DE VIDA
    -- ========================================================

    started_at TIMESTAMPTZ
        NULL,

    submitted_for_review_at TIMESTAMPTZ
        NULL,

    completed_at TIMESTAMPTZ
        NULL,

    cancelled_at TIMESTAMPTZ
        NULL,


    -- ========================================================
    -- ACTORES DEL CICLO DE VIDA
    -- ========================================================

    completed_by_worker_id UUID
        NULL
        REFERENCES public.workers(id)
        ON DELETE RESTRICT,

    cancelled_by_worker_id UUID
        NULL
        REFERENCES public.workers(id)
        ON DELETE RESTRICT,


    -- ========================================================
    -- TIMESTAMPS
    -- ========================================================

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT CURRENT_TIMESTAMP,


    -- ========================================================
    -- REGLAS DE CONSISTENCIA
    -- ========================================================

    CONSTRAINT internal_tasks_completed_progress_check
        CHECK (
            status <> 'completed'
            OR progress = 100
        ),

    CONSTRAINT internal_tasks_completed_timestamp_check
        CHECK (
            status <> 'completed'
            OR completed_at IS NOT NULL
        ),

    CONSTRAINT internal_tasks_cancelled_timestamp_check
        CHECK (
            status <> 'cancelled'
            OR cancelled_at IS NOT NULL
        )

);


-- ============================================================
-- 3. HISTORIAL — internal_task_updates
-- ============================================================
--
-- Esta tabla constituye la auditoría de las tareas.
--
-- Cada operación relevante realizada sobre una tarea deberá
-- generar posteriormente un registro aquí mediante las RPCs.
--
-- IMPORTANTE:
--
-- No se permite al frontend modificar ni borrar directamente
-- este historial.
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.internal_task_updates (

    id UUID
        PRIMARY KEY
        DEFAULT gen_random_uuid(),


    -- ========================================================
    -- TAREA
    -- ========================================================

    task_id UUID
        NOT NULL
        REFERENCES public.internal_tasks(id)
        ON DELETE CASCADE,


    -- ========================================================
    -- ACTOR
    -- ========================================================
    --
    -- El trabajador que realizó la acción.
    --
    -- ========================================================

    actor_worker_id UUID
        NOT NULL
        REFERENCES public.workers(id)
        ON DELETE RESTRICT,


    -- ========================================================
    -- ACCIÓN
    -- ========================================================
    --
    -- Ejemplos que utilizaremos en las RPCs:
    --
    --   created
    --   assigned
    --   reassigned
    --   visibility_changed
    --   started
    --   progress_updated
    --   commented
    --   submitted_for_review
    --   reviewed
    --   returned_to_progress
    --   completed
    --   cancelled
    --   reopened
    --   updated
    --
    -- No se utiliza un CHECK cerrado aquí deliberadamente.
    -- Las RPCs posteriores controlarán las acciones válidas.
    --
    -- Esto permite ampliar el historial sin tener que modificar
    -- esta tabla cada vez que aparezca un nuevo tipo de evento.
    --
    -- ========================================================

    action TEXT
        NOT NULL,


    -- ========================================================
    -- SNAPSHOT DEL ESTADO ANTERIOR
    -- ========================================================

    old_status TEXT
        NULL,

    old_progress INTEGER
        NULL,


    -- ========================================================
    -- SNAPSHOT DEL NUEVO ESTADO
    -- ========================================================

    new_status TEXT
        NULL,

    new_progress INTEGER
        NULL,


    -- ========================================================
    -- COMENTARIO / MOTIVO
    -- ========================================================

    comment TEXT
        NULL,


    -- ========================================================
    -- TIMESTAMP
    -- ========================================================

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT CURRENT_TIMESTAMP,


    -- ========================================================
    -- VALIDACIONES DEL HISTORIAL
    -- ========================================================

    CONSTRAINT internal_task_updates_old_progress_check
        CHECK (
            old_progress IS NULL
            OR old_progress BETWEEN 0 AND 100
        ),

    CONSTRAINT internal_task_updates_new_progress_check
        CHECK (
            new_progress IS NULL
            OR new_progress BETWEEN 0 AND 100
        )

);


-- ============================================================
-- 4. FUNCIÓN updated_at
-- ============================================================
--
-- Se utiliza una función específica para esta infraestructura
-- para no depender de que exista una función genérica con un
-- nombre concreto en migraciones anteriores.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_internal_task_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN

    NEW.updated_at := CURRENT_TIMESTAMP;

    RETURN NEW;

END;
$function$;


-- ============================================================
-- 5. TRIGGER updated_at
-- ============================================================

DROP TRIGGER IF EXISTS internal_tasks_set_updated_at
ON public.internal_tasks;

CREATE TRIGGER internal_tasks_set_updated_at
BEFORE UPDATE
ON public.internal_tasks
FOR EACH ROW
EXECUTE FUNCTION public.update_internal_task_updated_at();


-- ============================================================
-- 6. ÍNDICES — internal_tasks
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_internal_tasks_created_by_worker
ON public.internal_tasks (
    created_by_worker_id
);


CREATE INDEX IF NOT EXISTS
    idx_internal_tasks_assigned_to_worker
ON public.internal_tasks (
    assigned_to_worker_id
);


CREATE INDEX IF NOT EXISTS
    idx_internal_tasks_status
ON public.internal_tasks (
    status
);


CREATE INDEX IF NOT EXISTS
    idx_internal_tasks_priority
ON public.internal_tasks (
    priority
);


CREATE INDEX IF NOT EXISTS
    idx_internal_tasks_due_at
ON public.internal_tasks (
    due_at
);


CREATE INDEX IF NOT EXISTS
    idx_internal_tasks_assigned_status
ON public.internal_tasks (
    assigned_to_worker_id,
    status
);


CREATE INDEX IF NOT EXISTS
    idx_internal_tasks_created_at
ON public.internal_tasks (
    created_at DESC
);


-- ============================================================
-- 7. ÍNDICES — internal_task_updates
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_internal_task_updates_task
ON public.internal_task_updates (
    task_id
);


CREATE INDEX IF NOT EXISTS
    idx_internal_task_updates_task_created_at
ON public.internal_task_updates (
    task_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_internal_task_updates_actor
ON public.internal_task_updates (
    actor_worker_id
);


CREATE INDEX IF NOT EXISTS
    idx_internal_task_updates_created_at
ON public.internal_task_updates (
    created_at DESC
);


-- ============================================================
-- 8. RLS — internal_tasks
-- ============================================================
--
-- Se activa RLS desde la primera migración.
--
-- Todavía NO se crean políticas.
--
-- Por tanto:
--
--   authenticated -> sin acceso directo
--   anon          -> sin acceso
--
-- Las siguientes migraciones abrirán únicamente los accesos
-- necesarios mediante las políticas/RPCs correspondientes.
--
-- Esto evita crear accidentalmente una ventana de acceso entre
-- migraciones.
--
-- ============================================================

ALTER TABLE public.internal_tasks
ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 9. RLS — internal_task_updates
-- ============================================================

ALTER TABLE public.internal_task_updates
ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 10. PRIVILEGIOS DIRECTOS
-- ============================================================
--
-- La escritura se realizará mediante RPCs SECURITY DEFINER
-- en las migraciones posteriores.
--
-- No se concede DML directo al frontend.
--
-- ============================================================

REVOKE ALL
ON TABLE public.internal_tasks
FROM PUBLIC;

REVOKE ALL
ON TABLE public.internal_tasks
FROM anon;

REVOKE ALL
ON TABLE public.internal_tasks
FROM authenticated;


REVOKE ALL
ON TABLE public.internal_task_updates
FROM PUBLIC;

REVOKE ALL
ON TABLE public.internal_task_updates
FROM anon;

REVOKE ALL
ON TABLE public.internal_task_updates
FROM authenticated;


-- ============================================================
-- 11. PRIVILEGIOS SOBRE LA FUNCIÓN DE TIMESTAMP
-- ============================================================
--
-- No debe utilizarse desde el frontend.
--
-- ============================================================

REVOKE ALL
ON FUNCTION public.update_internal_task_updated_at()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.update_internal_task_updated_at()
FROM anon;

REVOKE ALL
ON FUNCTION public.update_internal_task_updated_at()
FROM authenticated;


-- ============================================================
-- 12. DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.internal_tasks IS
'Internal MODIRA tasks. Business access is controlled by later RBAC/RLS/RPC migrations.';

COMMENT ON TABLE public.internal_task_updates IS
'Immutable-style audit history for internal tasks. Entries are created by trusted backend RPCs.';


COMMENT ON COLUMN public.internal_tasks.assigned_to_worker_id IS
'Worker responsible for executing the task. NULL means the task has not yet been assigned.';


COMMENT ON COLUMN public.internal_tasks.progress IS
'Task completion percentage from 0 to 100.';


COMMENT ON COLUMN public.internal_tasks.status IS
'Task lifecycle: to_do, in_progress, pending_review, completed or cancelled.';


COMMENT ON COLUMN public.internal_task_updates.action IS
'Action/event performed against the task. The authoritative transition rules are enforced by later RPCs.';


-- ============================================================
-- 13. VERIFICACIONES
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'internal_tasks'
    ) THEN

        RAISE EXCEPTION
            '128 verification failed: public.internal_tasks was not created';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'internal_task_updates'
    ) THEN

        RAISE EXCEPTION
            '128 verification failed: public.internal_task_updates was not created';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.internal_tasks'::regclass
          AND conname = 'internal_tasks_status_check'
    ) THEN

        RAISE EXCEPTION
            '128 verification failed: status constraint is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.internal_tasks'::regclass
          AND conname = 'internal_tasks_progress_check'
    ) THEN

        RAISE EXCEPTION
            '128 verification failed: progress constraint is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.internal_tasks'::regclass
          AND tgname = 'internal_tasks_set_updated_at'
          AND NOT tgisinternal
    ) THEN

        RAISE EXCEPTION
            '128 verification failed: updated_at trigger is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'public.internal_tasks'::regclass
          AND relrowsecurity = TRUE
    ) THEN

        RAISE EXCEPTION
            '128 verification failed: RLS is not enabled on internal_tasks';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'public.internal_task_updates'::regclass
          AND relrowsecurity = TRUE
    ) THEN

        RAISE EXCEPTION
            '128 verification failed: RLS is not enabled on internal_task_updates';

    END IF;

END
$$;


-- ============================================================
-- FIN
-- ============================================================

COMMIT;