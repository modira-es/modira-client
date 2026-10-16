BEGIN;

-- ============================================================
-- 134_project_tasks_security.sql
-- Seguridad, RLS y endurecimiento de privilegios
-- para Project Tasks
-- ============================================================


-- ============================================================
-- 1. HABILITAR RLS
-- ============================================================

ALTER TABLE public.project_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_task_updates ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 2. PRIVILEGIOS DIRECTOS
-- ============================================================
-- Los usuarios no deben poder modificar Project Tasks
-- directamente mediante INSERT/UPDATE/DELETE.
--
-- La lógica funcional se expondrá mediante RPC SECURITY DEFINER
-- en la migración 135.
--
-- SELECT también se controla mediante RLS.
-- ============================================================

REVOKE ALL ON TABLE public.project_tasks FROM anon;
REVOKE ALL ON TABLE public.project_tasks FROM authenticated;

REVOKE ALL ON TABLE public.project_task_updates FROM anon;
REVOKE ALL ON TABLE public.project_task_updates FROM authenticated;


-- ============================================================
-- 3. PROJECT TASKS — SELECT
-- ============================================================
-- Solo Developer y Direction pueden leer Project Tasks.
--
-- Además:
--   - el usuario debe ser un worker activo
--   - debe tener project_tasks.read
--   - el proyecto debe ser accesible para ese worker
--
-- project_tasks.read ya existe en RBAC.
-- NO se crean permisos nuevos aquí.
-- ============================================================

DROP POLICY IF EXISTS project_tasks_rbac_select
ON public.project_tasks;

CREATE POLICY project_tasks_rbac_select
ON public.project_tasks
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND public.current_worker_has_permission('project_tasks.read')
    AND EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_tasks.project_id
    )
);


-- ============================================================
-- 4. PROJECT TASKS — INSERT
-- ============================================================
-- El INSERT real se realizará mediante
-- create_project_task() en la migración 135.
--
-- No permitimos INSERT directo.
-- ============================================================

DROP POLICY IF EXISTS project_tasks_no_direct_insert
ON public.project_tasks;

CREATE POLICY project_tasks_no_direct_insert
ON public.project_tasks
FOR INSERT
TO authenticated
WITH CHECK (false);


-- ============================================================
-- 5. PROJECT TASKS — UPDATE
-- ============================================================
-- Las modificaciones se realizarán exclusivamente mediante
-- RPCs SECURITY DEFINER.
--
-- No se permite UPDATE directo desde el cliente.
-- ============================================================

DROP POLICY IF EXISTS project_tasks_no_direct_update
ON public.project_tasks;

CREATE POLICY project_tasks_no_direct_update
ON public.project_tasks
FOR UPDATE
TO authenticated
USING (false)
WITH CHECK (false);


-- ============================================================
-- 6. PROJECT TASKS — DELETE
-- ============================================================
-- Las tareas no se eliminan físicamente.
-- La cancelación lógica se realizará mediante RPC.
--
-- No se permite DELETE directo.
-- ============================================================

DROP POLICY IF EXISTS project_tasks_no_direct_delete
ON public.project_tasks;

CREATE POLICY project_tasks_no_direct_delete
ON public.project_tasks
FOR DELETE
TO authenticated
USING (false);


-- ============================================================
-- 7. PROJECT TASK UPDATES — SELECT
-- ============================================================
-- El historial solo puede ser consultado por Developer/Direction
-- mediante project_tasks.read.
--
-- El task debe pertenecer a un proyecto existente.
-- ============================================================

DROP POLICY IF EXISTS project_task_updates_rbac_select
ON public.project_task_updates;

CREATE POLICY project_task_updates_rbac_select
ON public.project_task_updates
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND public.current_worker_has_permission('project_tasks.read')
    AND EXISTS (
        SELECT 1
        FROM public.project_tasks pt
        INNER JOIN public.projects p
            ON p.id = pt.project_id
        WHERE pt.id = project_task_updates.task_id
    )
);


-- ============================================================
-- 8. PROJECT TASK UPDATES — INSERT
-- ============================================================
-- El historial es append-only y solamente será escrito
-- mediante las RPCs SECURITY DEFINER de la migración 135.
--
-- No permitimos INSERT directo.
-- ============================================================

DROP POLICY IF EXISTS project_task_updates_no_direct_insert
ON public.project_task_updates;

CREATE POLICY project_task_updates_no_direct_insert
ON public.project_task_updates
FOR INSERT
TO authenticated
WITH CHECK (false);


-- ============================================================
-- 9. PROJECT TASK UPDATES — UPDATE
-- ============================================================
-- HISTORIAL INMUTABLE.
-- No se puede modificar ningún registro existente.
-- ============================================================

DROP POLICY IF EXISTS project_task_updates_no_update
ON public.project_task_updates;

CREATE POLICY project_task_updates_no_update
ON public.project_task_updates
FOR UPDATE
TO authenticated
USING (false)
WITH CHECK (false);


-- ============================================================
-- 10. PROJECT TASK UPDATES — DELETE
-- ============================================================
-- HISTORIAL INMUTABLE.
-- No se puede eliminar ningún registro existente.
-- ============================================================

DROP POLICY IF EXISTS project_task_updates_no_delete
ON public.project_task_updates;

CREATE POLICY project_task_updates_no_delete
ON public.project_task_updates
FOR DELETE
TO authenticated
USING (false);


-- ============================================================
-- 11. BLOQUEO EXPLÍCITO DE TRUNCATE
-- ============================================================
-- authenticated/anon no reciben privilegios sobre las tablas,
-- pero revocamos explícitamente por endurecimiento.
-- ============================================================

REVOKE TRUNCATE ON TABLE public.project_tasks
FROM anon, authenticated;

REVOKE TRUNCATE ON TABLE public.project_task_updates
FROM anon, authenticated;


-- ============================================================
-- 12. VERIFICACIÓN DE RLS
-- ============================================================

DO $$
DECLARE
    v_rls_project_tasks BOOLEAN;
    v_rls_project_task_updates BOOLEAN;
BEGIN

    SELECT relrowsecurity
    INTO v_rls_project_tasks
    FROM pg_class
    WHERE oid = 'public.project_tasks'::regclass;

    SELECT relrowsecurity
    INTO v_rls_project_task_updates
    FROM pg_class
    WHERE oid = 'public.project_task_updates'::regclass;

    IF NOT COALESCE(v_rls_project_tasks, false) THEN
        RAISE EXCEPTION
            'ERROR: RLS no está habilitado en public.project_tasks';
    END IF;

    IF NOT COALESCE(v_rls_project_task_updates, false) THEN
        RAISE EXCEPTION
            'ERROR: RLS no está habilitado en public.project_task_updates';
    END IF;

END;
$$;


-- ============================================================
-- 13. VERIFICACIÓN DE POLÍTICAS
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_tasks'
      AND policyname IN (
          'project_tasks_rbac_select',
          'project_tasks_no_direct_insert',
          'project_tasks_no_direct_update',
          'project_tasks_no_direct_delete'
      );

    IF v_count <> 4 THEN
        RAISE EXCEPTION
            'ERROR: project_tasks no tiene las 4 políticas de seguridad esperadas. Encontradas: %',
            v_count;
    END IF;


    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_task_updates'
      AND policyname IN (
          'project_task_updates_rbac_select',
          'project_task_updates_no_direct_insert',
          'project_task_updates_no_update',
          'project_task_updates_no_delete'
      );

    IF v_count <> 4 THEN
        RAISE EXCEPTION
            'ERROR: project_task_updates no tiene las 4 políticas de seguridad esperadas. Encontradas: %',
            v_count;
    END IF;

END;
$$;



COMMIT;