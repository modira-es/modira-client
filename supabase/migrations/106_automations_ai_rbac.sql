BEGIN;

-- ============================================================
-- MODIRA — 106_automations_ai_rbac.sql
--
-- RBAC para:
--   1. automations
--   2. automation_runs
--   3. acceso operativo al panel de Modira AI
--
-- Direction:
--   - CRUD completo de automatizaciones
--   - ejecución de automatizaciones
--   - acceso al panel operativo de AI
--
-- Developer:
--   - CRUD completo de automatizaciones
--   - ejecución de automatizaciones
--   - acceso al panel operativo de AI
--
-- Commercial / Support / Accounting:
--   - sin permisos de automatizaciones / AI
--
-- IMPORTANTE:
--   Las tablas internas de AI siguen sin acceso directo.
--   Las RPC de 048 continúan siendo la vía de lectura del
--   Employee Area y serán endurecidas definitivamente en 108.
-- ============================================================


-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
BEGIN

    IF to_regclass('public.automations') IS NULL THEN
        RAISE EXCEPTION
            '106 failed: public.automations is missing';
    END IF;

    IF to_regclass('public.automation_runs') IS NULL THEN
        RAISE EXCEPTION
            '106 failed: public.automation_runs is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'automations'
          AND c.relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '106 failed: RLS is not enabled on public.automations';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'automation_runs'
          AND c.relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '106 failed: RLS is not enabled on public.automation_runs';
    END IF;

    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '106 failed: current_worker_has_permission(text) is missing';
    END IF;

END $$;


-- ============================================================
-- 2. PERMISOS
-- ============================================================
--
-- Se crean aquí por seguridad si una versión anterior del
-- catálogo no los hubiera incluido todavía.
--
-- No se modifica ningún permiso existente.
-- ============================================================

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
VALUES
(
    'automations.read',
    'automations',
    'read',
    'Consultar automatizaciones internas'
),
(
    'automations.create',
    'automations',
    'create',
    'Crear automatizaciones internas'
),
(
    'automations.update',
    'automations',
    'update',
    'Modificar automatizaciones internas'
),
(
    'automations.delete',
    'automations',
    'delete',
    'Eliminar automatizaciones internas'
),
(
    'automations.execute',
    'automations',
    'execute',
    'Ejecutar automatizaciones internas'
),
(
    'ai.read',
    'ai',
    'read',
    'Consultar información operativa de Modira AI'
),
(
    'ai.manage',
    'ai',
    'manage',
    'Gestionar información operativa de Modira AI'
)
ON CONFLICT (code)
DO NOTHING;


-- ============================================================
-- 3. ASIGNACIÓN DE PERMISOS A ROLES
-- ============================================================
--
-- Direction:
--   Todo.
--
-- Developer:
--   Automatizaciones + ejecución + AI.
--
-- El resto NO recibe estos permisos.
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
WHERE wr.code IN ('direction', 'developer')
  AND wp.code IN (
      'automations.read',
      'automations.create',
      'automations.update',
      'automations.delete',
      'automations.execute',
      'ai.read',
      'ai.manage'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 4. AUTOMATIONS — ELIMINAR ACCESO GENÉRICO DE WORKER
-- ============================================================
--
-- IMPORTANTE:
-- Las policies permisivas se combinan con OR.
-- Por eso no basta con crear una nueva policy RBAC.
--
-- Hay que eliminar la antigua:
--   automations_worker_select
--
-- Las policies de cliente permanecen.
-- ============================================================

DROP POLICY IF EXISTS automations_worker_select
ON public.automations;


-- ============================================================
-- 5. AUTOMATIONS — RBAC SELECT
-- ============================================================

DROP POLICY IF EXISTS automations_rbac_select
ON public.automations;

CREATE POLICY automations_rbac_select
ON public.automations
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'automations.read'
    )
);


-- ============================================================
-- 6. AUTOMATIONS — RBAC INSERT
-- ============================================================

DROP POLICY IF EXISTS automations_rbac_insert
ON public.automations;

CREATE POLICY automations_rbac_insert
ON public.automations
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'automations.create'
    )
);


-- ============================================================
-- 7. AUTOMATIONS — RBAC UPDATE
-- ============================================================

DROP POLICY IF EXISTS automations_rbac_update
ON public.automations;

CREATE POLICY automations_rbac_update
ON public.automations
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'automations.update'
    )
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'automations.update'
    )
);


-- ============================================================
-- 8. AUTOMATIONS — RBAC DELETE
-- ============================================================

DROP POLICY IF EXISTS automations_rbac_delete
ON public.automations;

CREATE POLICY automations_rbac_delete
ON public.automations
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'automations.delete'
    )
);


-- ============================================================
-- 9. PRIVILEGIOS DE TABLA — AUTOMATIONS
-- ============================================================
--
-- RLS decide qué puede hacer cada worker.
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.automations
TO authenticated;


-- ============================================================
-- 10. AUTOMATION RUNS
-- ============================================================
--
-- La creación de ejecuciones continúa realizándose mediante
-- create_automation_run().
--
-- No se concede INSERT directo aquí.
--
-- Para lectura interna:
--   Direction + Developer
--
-- El resto no recibe acceso worker.
-- ============================================================

DROP POLICY IF EXISTS automation_runs_worker_select
ON public.automation_runs;

DROP POLICY IF EXISTS automation_runs_rbac_select
ON public.automation_runs;

CREATE POLICY automation_runs_rbac_select
ON public.automation_runs
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'automations.read'
    )
);


-- ============================================================
-- 11. AUTOMATION RUNS — PRIVILEGIOS
-- ============================================================
--
-- Se mantiene la arquitectura existente:
--
--   SELECT → Employee Area mediante RLS
--   INSERT → create_automation_run()
--   backend → operaciones internas
--
-- No se concede INSERT/UPDATE/DELETE directo al frontend.
-- ============================================================

GRANT SELECT
ON public.automation_runs
TO authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.automation_runs
FROM authenticated;


-- ============================================================
-- 12. VERIFICACIÓN DE POLICIES DE AUTOMATIONS
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'automations'
          AND policyname = 'automations_rbac_select'
    ) THEN
        RAISE EXCEPTION
            '106 failed: automations_rbac_select is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'automations'
          AND policyname = 'automations_rbac_insert'
    ) THEN
        RAISE EXCEPTION
            '106 failed: automations_rbac_insert is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'automations'
          AND policyname = 'automations_rbac_update'
    ) THEN
        RAISE EXCEPTION
            '106 failed: automations_rbac_update is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'automations'
          AND policyname = 'automations_rbac_delete'
    ) THEN
        RAISE EXCEPTION
            '106 failed: automations_rbac_delete is missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'automations'
          AND policyname = 'automations_worker_select'
    ) THEN
        RAISE EXCEPTION
            '106 failed: legacy automations_worker_select still exists';
    END IF;

END $$;


-- ============================================================
-- 13. VERIFICACIÓN DE AUTOMATION RUNS
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'automation_runs'
          AND policyname = 'automation_runs_rbac_select'
    ) THEN
        RAISE EXCEPTION
            '106 failed: automation_runs_rbac_select is missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'automation_runs'
          AND policyname = 'automation_runs_worker_select'
    ) THEN
        RAISE EXCEPTION
            '106 failed: legacy automation_runs_worker_select still exists';
    END IF;

END $$;


-- ============================================================
-- 14. VERIFICACIÓN DE ROLES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Direction: 7 permisos
    SELECT count(*)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'direction'
      AND wp.code IN (
          'automations.read',
          'automations.create',
          'automations.update',
          'automations.delete',
          'automations.execute',
          'ai.read',
          'ai.manage'
      );

    IF v_count <> 7 THEN
        RAISE EXCEPTION
            '106 failed: Direction does not have all automation/AI permissions';
    END IF;


    -- Developer: 7 permisos
    SELECT count(*)
    INTO v_count
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'developer'
      AND wp.code IN (
          'automations.read',
          'automations.create',
          'automations.update',
          'automations.delete',
          'automations.execute',
          'ai.read',
          'ai.manage'
      );

    IF v_count <> 7 THEN
        RAISE EXCEPTION
            '106 failed: Developer does not have all automation/AI permissions';
    END IF;


    -- Commercial NO recibe acceso
    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'commercial'
          AND wp.code IN (
              'automations.read',
              'automations.create',
              'automations.update',
              'automations.delete',
              'automations.execute',
              'ai.read',
              'ai.manage'
          )
    ) THEN
        RAISE EXCEPTION
            '106 failed: Commercial has automation/AI permissions';
    END IF;


    -- Support NO recibe acceso
    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'support'
          AND wp.code IN (
              'automations.read',
              'automations.create',
              'automations.update',
              'automations.delete',
              'automations.execute',
              'ai.read',
              'ai.manage'
          )
    ) THEN
        RAISE EXCEPTION
            '106 failed: Support has automation/AI permissions';
    END IF;


    -- Accounting NO recibe acceso
    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
          ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
          ON wp.id = wrp.permission_id
        WHERE wr.code = 'accounting'
          AND wp.code IN (
              'automations.read',
              'automations.create',
              'automations.update',
              'automations.delete',
              'automations.execute',
              'ai.read',
              'ai.manage'
          )
    ) THEN
        RAISE EXCEPTION
            '106 failed: Accounting has automation/AI permissions';
    END IF;

END $$;


-- ============================================================
-- 15. RESUMEN FINAL
-- ============================================================

DO $$
BEGIN

    RAISE NOTICE
        '106 OK: automations and automation_runs RBAC configured';

    RAISE NOTICE
        '106 OK: Direction and Developer receive automation/AI permissions';

    RAISE NOTICE
        '106 OK: Commercial, Support and Accounting receive no automation/AI permissions';

    RAISE NOTICE
        '106 OK: AI infrastructure remains accessible only through controlled RPCs';

END $$;


COMMIT;