-- ============================================================
-- 151_roles_permissions_admin_api.sql
-- API RBAC segura para la página "Roles y permisos" de Modira.
--
-- No concede SELECT/INSERT/UPDATE/DELETE directos sobre las
-- tablas RBAC. Las operaciones pasan por RPC SECURITY DEFINER.
--
-- Requisitos existentes:
--   worker_roles, worker_permissions,
--   worker_role_permissions, worker_role_assignments, workers
--   current_user_is_worker()
--   current_user_can_manage_worker_roles()
--   current_worker_has_permission(text)
--
-- Importante:
--   - Los roles del sistema no pueden modificarse mediante las
--     RPC de edición de roles/permisos incluidas aquí.
--   - No se implementa borrado de roles.
--   - La asignación de roles a trabajadores sigue usando las
--     RPC existentes assign_worker_role/remove_worker_role.
--   - No se crea infraestructura de auditoría nueva.
-- ============================================================

BEGIN;

-- ============================================================
-- 0. PREVALIDACIÓN: detenerse con un error claro si el esquema
--    real no coincide con el auditado.
-- ============================================================

DO $$
BEGIN
    IF to_regclass('public.workers') IS NULL
       OR to_regclass('public.worker_roles') IS NULL
       OR to_regclass('public.worker_permissions') IS NULL
       OR to_regclass('public.worker_role_permissions') IS NULL
       OR to_regclass('public.worker_role_assignments') IS NULL
    THEN
        RAISE EXCEPTION
            '151 stopped: falta una o más tablas RBAC esperadas';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'workers'
          AND column_name = 'display_name'
    ) THEN
        RAISE EXCEPTION
            '151 stopped: public.workers.display_name no existe; revisar el esquema antes de aplicar la migración';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'worker_role_assignments'
          AND column_name = 'worker_auth_user_id'
    ) THEN
        RAISE EXCEPTION
            '151 stopped: worker_role_assignments.worker_auth_user_id no existe';
    END IF;
END;
$$;


-- ============================================================
-- 1. CATÁLOGO DE ROLES
-- Devuelve el catálogo real y contadores para la tabla frontend.
-- Acceso de lectura: system.roles.read o system.roles.manage.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_worker_role_catalog()
RETURNS TABLE (
    role_id uuid,
    role_code text,
    role_name text,
    role_description text,
    is_system_role boolean,
    is_active boolean,
    worker_count bigint,
    permission_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.current_user_can_manage_worker_roles()
        OR (
            public.current_user_is_worker()
            AND (
                public.current_worker_has_permission('system.roles.read')
                OR public.current_worker_has_permission('system.roles.manage')
            )
        )
    ) THEN
        RAISE EXCEPTION 'Insufficient permissions to read worker roles'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        r.id,
        r.code,
        r.name,
        r.description,
        r.is_system_role,
        r.is_active,
        (
            SELECT COUNT(DISTINCT wra.worker_auth_user_id)
            FROM public.worker_role_assignments wra
            JOIN public.workers w
              ON w.auth_user_id = wra.worker_auth_user_id
            WHERE wra.role_id = r.id
        ) AS worker_count,
        (
            SELECT COUNT(DISTINCT wrp.permission_id)
            FROM public.worker_role_permissions wrp
            WHERE wrp.role_id = r.id
        ) AS permission_count
    FROM public.worker_roles r
    ORDER BY r.is_system_role DESC, r.name ASC;
END;
$function$;


-- ============================================================
-- 2. CATÁLOGO DE PERMISOS
-- Devuelve los permisos existentes y los roles activos que los
-- tienen asignados. No genera permisos ni acciones ficticias.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_worker_permission_catalog()
RETURNS TABLE (
    permission_id uuid,
    permission_code text,
    resource text,
    action text,
    permission_description text,
    role_count bigint,
    role_codes text[],
    role_names text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.current_user_can_manage_worker_roles()
        OR (
            public.current_user_is_worker()
            AND (
                public.current_worker_has_permission('system.roles.read')
                OR public.current_worker_has_permission('system.roles.manage')
            )
        )
    ) THEN
        RAISE EXCEPTION 'Insufficient permissions to read worker permissions'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        p.id,
        p.code,
        p.resource,
        p.action,
        p.description,
        (
            SELECT COUNT(DISTINCT r2.id)
            FROM public.worker_role_permissions wrp2
            JOIN public.worker_roles r2
              ON r2.id = wrp2.role_id
            WHERE wrp2.permission_id = p.id
              AND r2.is_active = TRUE
        ) AS role_count,
        COALESCE((
            SELECT ARRAY_AGG(DISTINCT r3.code ORDER BY r3.code)
            FROM public.worker_role_permissions wrp3
            JOIN public.worker_roles r3
              ON r3.id = wrp3.role_id
            WHERE wrp3.permission_id = p.id
              AND r3.is_active = TRUE
        ), ARRAY[]::text[]) AS role_codes,
        COALESCE((
            SELECT ARRAY_AGG(DISTINCT r4.name ORDER BY r4.name)
            FROM public.worker_role_permissions wrp4
            JOIN public.worker_roles r4
              ON r4.id = wrp4.role_id
            WHERE wrp4.permission_id = p.id
              AND r4.is_active = TRUE
        ), ARRAY[]::text[]) AS role_names
    FROM public.worker_permissions p
    ORDER BY p.resource, p.action, p.code;
END;
$function$;


-- ============================================================
-- 3. ASIGNACIONES DE TRABAJADORES
-- Corrige la RPC existente: la estructura auditada de workers
-- utiliza display_name, no nombre/name.
--
-- Conserva la firma de retorno para no romper los consumidores
-- existentes. Añade acceso de lectura a system.roles.read.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_all_worker_role_assignments()
RETURNS TABLE (
    worker_id uuid,
    auth_user_id uuid,
    worker_name text,
    is_active boolean,
    role_codes text[],
    role_names text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
        public.current_user_can_manage_worker_roles()
        OR (
            public.current_user_is_worker()
            AND (
                public.current_worker_has_permission('system.roles.read')
                OR public.current_worker_has_permission('system.roles.manage')
            )
        )
    ) THEN
        RAISE EXCEPTION 'Insufficient permissions to view worker role assignments'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        w.id,
        w.auth_user_id,
        COALESCE(NULLIF(BTRIM(w.display_name), ''), 'Trabajador') AS worker_name,
        w.is_active,
        COALESCE(
            ARRAY_AGG(r.code ORDER BY r.name)
                FILTER (WHERE r.id IS NOT NULL),
            ARRAY[]::text[]
        ) AS role_codes,
        COALESCE(
            ARRAY_AGG(r.name ORDER BY r.name)
                FILTER (WHERE r.id IS NOT NULL),
            ARRAY[]::text[]
        ) AS role_names
    FROM public.workers w
    LEFT JOIN public.worker_role_assignments wra
      ON wra.worker_auth_user_id = w.auth_user_id
    LEFT JOIN public.worker_roles r
      ON r.id = wra.role_id
     AND r.is_active = TRUE
    GROUP BY
        w.id,
        w.auth_user_id,
        w.display_name,
        w.is_active
    ORDER BY worker_name;
END;
$function$;


-- ============================================================
-- 4. CREAR UN ROL PERSONALIZADO
-- No permite crear roles con códigos reservados del sistema.
-- No crea permisos nuevos: los permisos se eligen del catálogo.
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_worker_custom_role(
    p_code text,
    p_name text,
    p_description text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_name text;
    v_role_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public.current_user_can_manage_worker_roles() THEN
        RAISE EXCEPTION 'Insufficient permissions to create worker roles'
            USING ERRCODE = '42501';
    END IF;

    v_code := LOWER(BTRIM(COALESCE(p_code, '')));
    v_name := BTRIM(COALESCE(p_name, ''));

    IF v_name = '' THEN
        RAISE EXCEPTION 'Role name is required'
            USING ERRCODE = '22023';
    END IF;

    IF v_code !~ '^[a-z][a-z0-9_]{0,49}$' THEN
        RAISE EXCEPTION
            'Invalid role code. Use lowercase letters, numbers and underscores, starting with a letter.'
            USING ERRCODE = '22023';
    END IF;

    IF v_code IN ('direction', 'commercial', 'accounting', 'developer', 'support') THEN
        RAISE EXCEPTION 'This role code is reserved for a system role'
            USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.worker_roles r
        WHERE LOWER(r.code) = v_code
    ) THEN
        RAISE EXCEPTION 'A role with this code already exists'
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO public.worker_roles (
        code,
        name,
        description,
        is_system_role,
        is_active
    )
    VALUES (
        v_code,
        v_name,
        NULLIF(BTRIM(COALESCE(p_description, '')), ''),
        FALSE,
        TRUE
    )
    RETURNING id INTO v_role_id;

    RETURN v_role_id;
END;
$function$;


-- ============================================================
-- 5. EDITAR METADATOS DE UN ROL PERSONALIZADO
-- No permite modificar nombre/descripción de roles del sistema.
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_worker_custom_role(
    p_role_id uuid,
    p_name text,
    p_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_name text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public.current_user_can_manage_worker_roles() THEN
        RAISE EXCEPTION 'Insufficient permissions to update worker roles'
            USING ERRCODE = '42501';
    END IF;

    v_name := BTRIM(COALESCE(p_name, ''));

    IF p_role_id IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'Role id and name are required'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_roles r
        WHERE r.id = p_role_id
          AND r.is_system_role = FALSE
    ) THEN
        RAISE EXCEPTION 'Role not found or system roles cannot be edited'
            USING ERRCODE = '42501';
    END IF;

    UPDATE public.worker_roles
    SET
        name = v_name,
        description = NULLIF(BTRIM(COALESCE(p_description, '')), ''),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_role_id
      AND is_system_role = FALSE;

    RETURN FOUND;
END;
$function$;


-- ============================================================
-- 6. REEMPLAZAR LOS PERMISOS DE UN ROL PERSONALIZADO
-- Valida todo el conjunto antes de cambiar la relación.
-- Un código desconocido provoca error y no deja cambios parciales.
-- Los roles del sistema quedan protegidos.
-- ============================================================

CREATE OR REPLACE FUNCTION public.replace_worker_custom_role_permissions(
    p_role_code text,
    p_permission_codes text[]
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_role_id uuid;
    v_requested_codes text[];
    v_valid_count bigint;
    v_requested_count bigint;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public.current_user_can_manage_worker_roles() THEN
        RAISE EXCEPTION 'Insufficient permissions to manage role permissions'
            USING ERRCODE = '42501';
    END IF;

    SELECT r.id
    INTO v_role_id
    FROM public.worker_roles r
    WHERE r.code = LOWER(BTRIM(COALESCE(p_role_code, '')))
      AND r.is_active = TRUE
      AND r.is_system_role = FALSE;

    IF v_role_id IS NULL THEN
        RAISE EXCEPTION 'Custom role not found or inactive'
            USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(
        ARRAY_AGG(DISTINCT LOWER(BTRIM(x.code))),
        ARRAY[]::text[]
    )
    INTO v_requested_codes
    FROM UNNEST(COALESCE(p_permission_codes, ARRAY[]::text[])) AS x(code)
    WHERE BTRIM(COALESCE(x.code, '')) <> '';

    SELECT CARDINALITY(v_requested_codes)::bigint
    INTO v_requested_count;

    SELECT COUNT(DISTINCT p.id)::bigint
    INTO v_valid_count
    FROM public.worker_permissions p
    WHERE p.code = ANY(v_requested_codes);

    IF v_valid_count <> v_requested_count THEN
        RAISE EXCEPTION 'One or more permission codes do not exist'
            USING ERRCODE = '22023';
    END IF;

    DELETE FROM public.worker_role_permissions wrp
    WHERE wrp.role_id = v_role_id;

    INSERT INTO public.worker_role_permissions (role_id, permission_id)
    SELECT v_role_id, p.id
    FROM public.worker_permissions p
    WHERE p.code = ANY(v_requested_codes);

    UPDATE public.worker_roles
    SET updated_at = CURRENT_TIMESTAMP
    WHERE id = v_role_id;

    RETURN TRUE;
END;
$function$;


-- ============================================================
-- 7. PERMISOS DE EJECUCIÓN DE LAS RPC
-- Sin ejecución para PUBLIC/anon. Solo authenticated puede
-- invocarlas, y cada función comprueba autorización internamente.
-- ============================================================

REVOKE ALL ON FUNCTION public.get_worker_role_catalog()
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_worker_role_catalog()
TO authenticated;

REVOKE ALL ON FUNCTION public.get_worker_permission_catalog()
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_worker_permission_catalog()
TO authenticated;

REVOKE ALL ON FUNCTION public.get_all_worker_role_assignments()
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_all_worker_role_assignments()
TO authenticated;

REVOKE ALL ON FUNCTION public.create_worker_custom_role(text, text, text)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_worker_custom_role(text, text, text)
TO authenticated;

REVOKE ALL ON FUNCTION public.update_worker_custom_role(uuid, text, text)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_worker_custom_role(uuid, text, text)
TO authenticated;

REVOKE ALL ON FUNCTION public.replace_worker_custom_role_permissions(text, text[])
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_worker_custom_role_permissions(text, text[])
TO authenticated;


-- ============================================================
-- 8. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_missing text[];
BEGIN
    SELECT ARRAY_AGG(expected.name)
    INTO v_missing
    FROM (
        VALUES
            ('get_worker_role_catalog'),
            ('get_worker_permission_catalog'),
            ('get_all_worker_role_assignments'),
            ('create_worker_custom_role'),
            ('update_worker_custom_role'),
            ('replace_worker_custom_role_permissions')
    ) AS expected(name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = expected.name
    );

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            '151 failed: faltan RPC esperadas: %',
            ARRAY_TO_STRING(v_missing, ', ');
    END IF;
END;
$$;

COMMIT;
