BEGIN;

-- ============================================================
-- 102 — RBAC PROJECTS / MILESTONES / UPDATES
-- ============================================================


-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
DECLARE
    v_table TEXT;
BEGIN

    -- --------------------------------------------------------
    -- Tablas obligatorias
    -- --------------------------------------------------------

    FOREACH v_table IN ARRAY ARRAY[
        'projects',
        'project_milestones',
        'project_updates'
    ]
    LOOP
        IF to_regclass('public.' || v_table) IS NULL THEN
            RAISE EXCEPTION
                '102 failed: missing table public.%',
                v_table;
        END IF;
    END LOOP;


    -- --------------------------------------------------------
    -- RLS obligatorio
    -- --------------------------------------------------------

    FOREACH v_table IN ARRAY ARRAY[
        'projects',
        'project_milestones',
        'project_updates'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_class c
            WHERE c.oid = ('public.' || v_table)::regclass
              AND c.relrowsecurity = TRUE
        ) THEN
            RAISE EXCEPTION
                '102 failed: RLS is not enabled on public.%',
                v_table;
        END IF;
    END LOOP;


    -- --------------------------------------------------------
    -- Función RBAC
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '102 failed: current_worker_has_permission(text) is missing';
    END IF;


    -- --------------------------------------------------------
    -- Permisos obligatorios
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                ('projects.read'),
                ('projects.create'),
                ('projects.update'),
                ('projects.delete'),

                ('project_milestones.read'),
                ('project_milestones.create'),
                ('project_milestones.update'),
                ('project_milestones.delete'),

                ('project_updates.read'),
                ('project_updates.create'),
                ('project_updates.update'),
                ('project_updates.delete')
        ) AS required(code)
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.worker_permissions p
            WHERE p.code = required.code
        )
    ) THEN
        RAISE EXCEPTION
            '102 failed: one or more project permissions are missing';
    END IF;

END $$;


-- ============================================================
-- 2. ASIGNACIÓN DE PERMISOS
-- ============================================================


-- ------------------------------------------------------------
-- DIRECTION
-- CRUD completo de Projects / Milestones / Updates
-- ------------------------------------------------------------

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
CROSS JOIN public.worker_permissions p
WHERE r.code = 'direction'
  AND p.code IN (
      'projects.read',
      'projects.create',
      'projects.update',
      'projects.delete',

      'project_milestones.read',
      'project_milestones.create',
      'project_milestones.update',
      'project_milestones.delete',

      'project_updates.read',
      'project_updates.create',
      'project_updates.update',
      'project_updates.delete'
  )
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- DEVELOPER
-- CRUD completo de Projects / Milestones / Updates
-- ------------------------------------------------------------

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
CROSS JOIN public.worker_permissions p
WHERE r.code = 'developer'
  AND p.code IN (
      'projects.read',
      'projects.create',
      'projects.update',
      'projects.delete',

      'project_milestones.read',
      'project_milestones.create',
      'project_milestones.update',
      'project_milestones.delete',

      'project_updates.read',
      'project_updates.create',
      'project_updates.update',
      'project_updates.delete'
  )
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- SUPPORT
-- Solo lectura de Projects
-- ------------------------------------------------------------

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
CROSS JOIN public.worker_permissions p
WHERE r.code = 'support'
  AND p.code = 'projects.read'
ON CONFLICT DO NOTHING;


-- ============================================================
-- 3. PROJECTS — SELECT
-- ============================================================

-- La policy actual permite:
-- current_user_is_worker()
-- sin comprobar RBAC.
--
-- Se sustituye por una policy que conserva el acceso del cliente
-- y exige projects.read para workers.

DROP POLICY IF EXISTS projects_company_select
ON public.projects;


CREATE POLICY projects_company_select
ON public.projects
FOR SELECT
TO authenticated
USING (

    -- CLIENTE
    (
        public.current_user_is_active()
        AND NOT public.current_user_is_worker()
        AND company_id IS NOT NULL
        AND company_id = public.current_user_company_id()
    )

    OR

    -- WORKER RBAC
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission(
            'projects.read'
        )
    )
);


-- ============================================================
-- 4. PROJECTS — INSERT
-- ============================================================

DROP POLICY IF EXISTS projects_rbac_insert
ON public.projects;


CREATE POLICY projects_rbac_insert
ON public.projects
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'projects.create'
    )
);


-- ============================================================
-- 5. PROJECTS — UPDATE
-- ============================================================

DROP POLICY IF EXISTS projects_rbac_update
ON public.projects;


CREATE POLICY projects_rbac_update
ON public.projects
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'projects.update'
    )
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'projects.update'
    )
);


-- ============================================================
-- 6. PROJECTS — DELETE
-- ============================================================

DROP POLICY IF EXISTS projects_rbac_delete
ON public.projects;


CREATE POLICY projects_rbac_delete
ON public.projects
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'projects.delete'
    )
);


-- ============================================================
-- 7. PROJECT MILESTONES — SELECT
-- ============================================================

-- Las dos policies originales permitían acceso a cualquier worker.

DROP POLICY IF EXISTS project_milestones_company_select
ON public.project_milestones;

DROP POLICY IF EXISTS project_milestones_select
ON public.project_milestones;


-- CLIENTES — empresa
CREATE POLICY project_milestones_company_select
ON public.project_milestones
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_milestones.project_id
          AND p.company_id = public.current_user_company_id()
    )
);


-- CLIENTES — propios proyectos
CREATE POLICY project_milestones_select
ON public.project_milestones
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_milestones.project_id
          AND p.user_id = auth.uid()
    )
);


-- WORKERS — RBAC
CREATE POLICY project_milestones_rbac_select
ON public.project_milestones
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_milestones.read'
    )
);


-- ============================================================
-- 8. PROJECT MILESTONES — INSERT
-- ============================================================

DROP POLICY IF EXISTS project_milestones_rbac_insert
ON public.project_milestones;


CREATE POLICY project_milestones_rbac_insert
ON public.project_milestones
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_milestones.create'
    )
);


-- ============================================================
-- 9. PROJECT MILESTONES — UPDATE
-- ============================================================

DROP POLICY IF EXISTS project_milestones_rbac_update
ON public.project_milestones;


CREATE POLICY project_milestones_rbac_update
ON public.project_milestones
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_milestones.update'
    )
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_milestones.update'
    )
);


-- ============================================================
-- 10. PROJECT MILESTONES — DELETE
-- ============================================================

DROP POLICY IF EXISTS project_milestones_rbac_delete
ON public.project_milestones;


CREATE POLICY project_milestones_rbac_delete
ON public.project_milestones
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_milestones.delete'
    )
);


-- ============================================================
-- 11. PROJECT UPDATES — SELECT
-- ============================================================

DROP POLICY IF EXISTS project_updates_company_select
ON public.project_updates;

DROP POLICY IF EXISTS project_updates_select
ON public.project_updates;


-- CLIENTES — empresa
CREATE POLICY project_updates_company_select
ON public.project_updates
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_updates.project_id
          AND p.company_id = public.current_user_company_id()
    )
);


-- CLIENTES — propios proyectos
CREATE POLICY project_updates_select
ON public.project_updates
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_updates.project_id
          AND p.user_id = auth.uid()
    )
);


-- WORKERS — RBAC
CREATE POLICY project_updates_rbac_select
ON public.project_updates
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_updates.read'
    )
);


-- ============================================================
-- 12. PROJECT UPDATES — INSERT
-- ============================================================

DROP POLICY IF EXISTS project_updates_rbac_insert
ON public.project_updates;


CREATE POLICY project_updates_rbac_insert
ON public.project_updates
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_updates.create'
    )
);


-- ============================================================
-- 13. PROJECT UPDATES — UPDATE
-- ============================================================

DROP POLICY IF EXISTS project_updates_rbac_update
ON public.project_updates;


CREATE POLICY project_updates_rbac_update
ON public.project_updates
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_updates.update'
    )
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_updates.update'
    )
);


-- ============================================================
-- 14. PROJECT UPDATES — DELETE
-- ============================================================

DROP POLICY IF EXISTS project_updates_rbac_delete
ON public.project_updates;


CREATE POLICY project_updates_rbac_delete
ON public.project_updates
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'project_updates.delete'
    )
);


-- ============================================================
-- 15. PRIVILEGIOS DE TABLA
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.projects
TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.project_milestones
TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.project_updates
TO authenticated;


-- ============================================================
-- 16. VERIFICACIONES
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- Policies RBAC obligatorias
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'projects'
          AND policyname = 'projects_company_select'
    ) THEN
        RAISE EXCEPTION
            '102 failed: projects_company_select missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'project_milestones'
          AND policyname = 'project_milestones_rbac_select'
    ) THEN
        RAISE EXCEPTION
            '102 failed: project_milestones_rbac_select missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'project_updates'
          AND policyname = 'project_updates_rbac_select'
    ) THEN
        RAISE EXCEPTION
            '102 failed: project_updates_rbac_select missing';
    END IF;


    -- --------------------------------------------------------
    -- Comprobar que Support tiene projects.read
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'support'
          AND p.code = 'projects.read'
    ) THEN
        RAISE EXCEPTION
            '102 failed: support projects.read permission missing';
    END IF;


    -- --------------------------------------------------------
    -- Comprobar Direction
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'direction'
          AND p.code = 'projects.delete'
    ) THEN
        RAISE EXCEPTION
            '102 failed: direction projects.delete permission missing';
    END IF;


    -- --------------------------------------------------------
    -- Comprobar Developer
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'developer'
          AND p.code = 'projects.delete'
    ) THEN
        RAISE EXCEPTION
            '102 failed: developer projects.delete permission missing';
    END IF;

END $$;


COMMIT;