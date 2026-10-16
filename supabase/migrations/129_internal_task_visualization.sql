-- ============================================================
-- MIGRATION 129
-- Internal tasks visibility
-- ============================================================

BEGIN;

-- ============================================================
-- 1. PRECONDITIONS
-- ============================================================

DO $$
BEGIN
    IF to_regclass('public.internal_tasks') IS NULL THEN
        RAISE EXCEPTION
            'Migration 129 requires public.internal_tasks to exist.';
    END IF;

    IF to_regclass('public.workers') IS NULL THEN
        RAISE EXCEPTION
            'Migration 129 requires public.workers to exist.';
    END IF;

    IF to_regclass('public.worker_roles') IS NULL THEN
        RAISE EXCEPTION
            'Migration 129 requires public.worker_roles to exist.';
    END IF;
END
$$;


-- ============================================================
-- 2. VISIBILITY FOR SPECIFIC WORKERS
-- ============================================================
--
-- A row means:
--   "This worker can VIEW this task."
--
-- It does NOT grant update, assignment, review or completion
-- permissions.
--
-- The assigned worker does NOT need a row here because the
-- assigned worker will automatically have visibility through
-- the task access logic implemented later.
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.internal_task_user_access (
    task_id UUID NOT NULL,
    worker_id UUID NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT internal_task_user_access_pkey
        PRIMARY KEY (task_id, worker_id),

    CONSTRAINT internal_task_user_access_task_fkey
        FOREIGN KEY (task_id)
        REFERENCES public.internal_tasks(id)
        ON DELETE RESTRICT,

    CONSTRAINT internal_task_user_access_worker_fkey
        FOREIGN KEY (worker_id)
        REFERENCES public.workers(id)
        ON DELETE RESTRICT
);


-- ============================================================
-- 3. VISIBILITY FOR ROLES
-- ============================================================
--
-- A row means:
--   "Workers belonging to this role can VIEW this task."
--
-- Role visibility is evaluated through the existing
-- worker_role_assignments / worker_roles system.
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.internal_task_role_access (
    task_id UUID NOT NULL,
    role_id UUID NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT internal_task_role_access_pkey
        PRIMARY KEY (task_id, role_id),

    CONSTRAINT internal_task_role_access_task_fkey
        FOREIGN KEY (task_id)
        REFERENCES public.internal_tasks(id)
        ON DELETE RESTRICT,

    CONSTRAINT internal_task_role_access_role_fkey
        FOREIGN KEY (role_id)
        REFERENCES public.worker_roles(id)
        ON DELETE RESTRICT
);


-- ============================================================
-- 4. INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_internal_task_user_access_worker
    ON public.internal_task_user_access(worker_id);

CREATE INDEX IF NOT EXISTS idx_internal_task_user_access_task
    ON public.internal_task_user_access(task_id);

CREATE INDEX IF NOT EXISTS idx_internal_task_role_access_role
    ON public.internal_task_role_access(role_id);

CREATE INDEX IF NOT EXISTS idx_internal_task_role_access_task
    ON public.internal_task_role_access(task_id);


-- ============================================================
-- 5. RLS
-- ============================================================
--
-- RLS is enabled now, but policies are deliberately NOT created
-- in migration 129.
--
-- Visibility rules and secure RPCs will be implemented in the
-- permissions / RPC migration.
--
-- This prevents direct authenticated access to these tables.
--
-- ============================================================

ALTER TABLE public.internal_task_user_access ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.internal_task_role_access ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 6. DIRECT PRIVILEGES
-- ============================================================
--
-- Access will be provided through controlled SECURITY DEFINER
-- functions in a later migration.
--
-- ============================================================

REVOKE ALL ON TABLE public.internal_task_user_access
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON TABLE public.internal_task_role_access
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 7. COMMENTS
-- ============================================================

COMMENT ON TABLE public.internal_task_user_access IS
'Explicit visibility grants for individual workers on internal tasks. Visibility does not grant edit, assignment, review or completion permissions.';

COMMENT ON TABLE public.internal_task_role_access IS
'Explicit visibility grants for worker roles on internal tasks. Visibility does not grant edit, assignment, review or completion permissions.';

COMMENT ON COLUMN public.internal_task_user_access.task_id IS
'Internal task whose visibility is being granted.';

COMMENT ON COLUMN public.internal_task_user_access.worker_id IS
'Worker who receives explicit read visibility for the task.';

COMMENT ON COLUMN public.internal_task_role_access.task_id IS
'Internal task whose visibility is being granted.';

COMMENT ON COLUMN public.internal_task_role_access.role_id IS
'Existing worker role whose members receive read visibility for the task.';


-- ============================================================
-- 8. VERIFICATION
-- ============================================================

DO $$
BEGIN

    IF to_regclass('public.internal_task_user_access') IS NULL THEN
        RAISE EXCEPTION
            'Migration 129 verification failed: internal_task_user_access does not exist.';
    END IF;

    IF to_regclass('public.internal_task_role_access') IS NULL THEN
        RAISE EXCEPTION
            'Migration 129 verification failed: internal_task_role_access does not exist.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.internal_task_user_access'::regclass
          AND contype = 'p'
    ) THEN
        RAISE EXCEPTION
            'Migration 129 verification failed: user access primary key missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.internal_task_role_access'::regclass
          AND contype = 'p'
    ) THEN
        RAISE EXCEPTION
            'Migration 129 verification failed: role access primary key missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'public.internal_task_user_access'::regclass
          AND relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            'Migration 129 verification failed: RLS is not enabled on internal_task_user_access.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'public.internal_task_role_access'::regclass
          AND relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            'Migration 129 verification failed: RLS is not enabled on internal_task_role_access.';
    END IF;

END
$$;


COMMIT;