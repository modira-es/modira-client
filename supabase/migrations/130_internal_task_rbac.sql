-- ============================================================
-- MIGRATION 130
-- Internal tasks RBAC permissions
-- ============================================================

BEGIN;


-- ============================================================
-- 1. PRECONDITIONS
-- ============================================================

DO $$
BEGIN
    IF to_regclass('public.worker_permissions') IS NULL THEN
        RAISE EXCEPTION
            'Migration 130 requires public.worker_permissions to exist.';
    END IF;

    IF to_regclass('public.worker_roles') IS NULL THEN
        RAISE EXCEPTION
            'Migration 130 requires public.worker_roles to exist.';
    END IF;

    IF to_regclass('public.worker_role_permissions') IS NULL THEN
        RAISE EXCEPTION
            'Migration 130 requires public.worker_role_permissions to exist.';
    END IF;
END
$$;


-- ============================================================
-- 2. CREATE INTERNAL TASK PERMISSIONS
-- ============================================================
--
-- Permissions are stored in the existing RBAC system.
--
-- No new role system is introduced.
--
-- ============================================================

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
VALUES
(
    'internal_tasks.create',
    'internal_tasks',
    'create',
    'Create internal tasks.'
),
(
    'internal_tasks.read',
    'internal_tasks',
    'read',
    'View internal tasks when access is granted.'
),
(
    'internal_tasks.update',
    'internal_tasks',
    'update',
    'Update internal tasks within the limits of the worker role.'
),
(
    'internal_tasks.assign',
    'internal_tasks',
    'assign',
    'Assign or reassign internal tasks.'
),
(
    'internal_tasks.review',
    'internal_tasks',
    'review',
    'Review tasks submitted for review and return them to progress or approve them.'
),
(
    'internal_tasks.complete',
    'internal_tasks',
    'complete',
    'Complete internal tasks.'
),
(
    'internal_tasks.delete',
    'internal_tasks',
    'delete',
    'Delete or administratively remove internal tasks.'
),
(
    'internal_tasks.manage_visibility',
    'internal_tasks',
    'manage_visibility',
    'Manage explicit worker and role visibility for internal tasks.'
)
ON CONFLICT (code) DO NOTHING;


-- ============================================================
-- 3. VERIFY REQUIRED ROLES EXIST
-- ============================================================

DO $$
DECLARE
    v_missing_roles TEXT;
BEGIN

    SELECT string_agg(required_role, ', ')
    INTO v_missing_roles
    FROM (
        SELECT required_role
        FROM (
            VALUES
                ('direction'),
                ('developer'),
                ('accounting'),
                ('commercial'),
                ('support')
        ) AS required_roles(required_role)
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.worker_roles wr
            WHERE wr.code = required_role
              AND wr.is_active = TRUE
        )
    ) missing;

    IF v_missing_roles IS NOT NULL THEN
        RAISE EXCEPTION
            'Migration 130 requires these active worker roles: %',
            v_missing_roles;
    END IF;

END
$$;


-- ============================================================
-- 4. DIRECTION
-- ============================================================
--
-- Direction has complete control over internal tasks.
--
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
WHERE wr.code = 'direction'
  AND wr.is_active = TRUE
  AND wp.code IN (
      'internal_tasks.create',
      'internal_tasks.read',
      'internal_tasks.update',
      'internal_tasks.assign',
      'internal_tasks.review',
      'internal_tasks.complete',
      'internal_tasks.delete',
      'internal_tasks.manage_visibility'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 5. DEVELOPER
-- ============================================================
--
-- Developer acts as operational manager.
--
-- Can:
--   create
--   read
--   update
--   assign new tasks
--
-- Cannot:
--   final review
--   final completion
--   manage visibility
--   delete
--
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
WHERE wr.code = 'developer'
  AND wr.is_active = TRUE
  AND wp.code IN (
      'internal_tasks.create',
      'internal_tasks.read',
      'internal_tasks.update',
      'internal_tasks.assign'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 6. ACCOUNTING
-- ============================================================
--
-- Accounting workers can create, view and update tasks they
-- are allowed to access.
--
-- They do not receive assignment, review, completion or
-- visibility-management privileges.
--
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
WHERE wr.code = 'accounting'
  AND wr.is_active = TRUE
  AND wp.code IN (
      'internal_tasks.create',
      'internal_tasks.read',
      'internal_tasks.update'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 7. COMMERCIAL
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
WHERE wr.code = 'commercial'
  AND wr.is_active = TRUE
  AND wp.code IN (
      'internal_tasks.create',
      'internal_tasks.read',
      'internal_tasks.update'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 8. SUPPORT
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
WHERE wr.code = 'support'
  AND wr.is_active = TRUE
  AND wp.code IN (
      'internal_tasks.create',
      'internal_tasks.read',
      'internal_tasks.update'
  )
ON CONFLICT DO NOTHING;


-- ============================================================
-- 9. VERIFICATION
-- ============================================================

DO $$
DECLARE
    v_required_permissions INTEGER := 8;
    v_permissions_found INTEGER;
    v_direction_permissions INTEGER;
    v_developer_permissions INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_permissions_found
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

    IF v_permissions_found <> v_required_permissions THEN
        RAISE EXCEPTION
            'Migration 130 verification failed: expected % internal task permissions, found %.',
            v_required_permissions,
            v_permissions_found;
    END IF;


    SELECT COUNT(*)
    INTO v_direction_permissions
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
        ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
        ON wp.id = wrp.permission_id
    WHERE wr.code = 'direction'
      AND wr.is_active = TRUE
      AND wp.code IN (
          'internal_tasks.create',
          'internal_tasks.read',
          'internal_tasks.update',
          'internal_tasks.assign',
          'internal_tasks.review',
          'internal_tasks.complete',
          'internal_tasks.delete',
          'internal_tasks.manage_visibility'
      );

    IF v_direction_permissions <> 8 THEN
        RAISE EXCEPTION
            'Migration 130 verification failed: direction must have all 8 internal task permissions, found %.',
            v_direction_permissions;
    END IF;


    SELECT COUNT(*)
    INTO v_developer_permissions
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
        ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
        ON wp.id = wrp.permission_id
    WHERE wr.code = 'developer'
      AND wr.is_active = TRUE
      AND wp.code IN (
          'internal_tasks.create',
          'internal_tasks.read',
          'internal_tasks.update',
          'internal_tasks.assign'
      );

    IF v_developer_permissions <> 4 THEN
        RAISE EXCEPTION
            'Migration 130 verification failed: developer must have 4 operational permissions, found %.',
            v_developer_permissions;
    END IF;

END
$$;


-- ============================================================
-- 10. COMMENTS
-- ============================================================

COMMENT ON TABLE public.worker_permissions IS
'Existing RBAC permission catalogue, including internal task permissions created by migration 130.';


COMMIT;