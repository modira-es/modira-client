-- ============================================================
-- MODIRA — WORKER RBAC
-- 098_worker_role_assignments.sql
-- ============================================================
--
-- OBJETIVO
-- ------------------------------------------------------------
-- 1. Crear las RPC para asignar roles a workers.
-- 2. Crear las RPC para eliminar roles.
-- 3. Crear una RPC para reemplazar el conjunto completo de
--    roles de un worker.
-- 4. Permitir consultar los roles asignados.
--
-- IMPORTANTE
-- ------------------------------------------------------------
-- Esta migración NO:
--   - modifica RLS de clientes;
--   - modifica RLS de empresas;
--   - modifica RLS de presupuestos;
--   - modifica RLS de facturación;
--   - modifica RLS de proyectos;
--   - modifica RLS de soporte;
--   - modifica RLS de ninguna tabla de negocio.
--
-- Tampoco asigna automáticamente roles a workers existentes.
--
-- Dependencias:
--   095_worker_rbac_core.sql
--   096_worker_rbac_permission_functions.sql
--   097_seed_worker_roles_and_permissions.sql
--
-- ============================================================

BEGIN;


-- ============================================================
-- 0. PRE-CHECKS
-- ============================================================

DO $$
BEGIN

    IF to_regclass('public.worker_roles') IS NULL THEN
        RAISE EXCEPTION
            '098: falta public.worker_roles. Ejecuta primero 095.';
    END IF;

    IF to_regclass('public.worker_permissions') IS NULL THEN
        RAISE EXCEPTION
            '098: falta public.worker_permissions. Ejecuta primero 095.';
    END IF;

    IF to_regclass('public.worker_role_permissions') IS NULL THEN
        RAISE EXCEPTION
            '098: falta public.worker_role_permissions. Ejecuta primero 095.';
    END IF;

    IF to_regclass('public.worker_role_assignments') IS NULL THEN
        RAISE EXCEPTION
            '098: falta public.worker_role_assignments. Ejecuta primero 095.';
    END IF;

    IF to_regclass('public.workers') IS NULL THEN
        RAISE EXCEPTION
            '098: falta public.workers.';
    END IF;

    IF to_regprocedure('public.current_user_is_admin()') IS NULL THEN
        RAISE EXCEPTION
            '098: falta public.current_user_is_admin().';
    END IF;

    IF to_regprocedure('public.current_user_is_worker()') IS NULL THEN
        RAISE EXCEPTION
            '098: falta public.current_user_is_worker().';
    END IF;

    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '098: falta public.current_worker_has_permission(text). Ejecuta primero 096.';
    END IF;

END;
$$;


-- ============================================================
-- 1. FUNCIÓN INTERNA DE AUTORIZACIÓN
-- ============================================================
--
-- Determina si el usuario actual puede gestionar roles RBAC.
--
-- Permitidos:
--
--   A) Admin existente del sistema:
--      current_user_is_admin()
--
--   B) Worker interno con permiso:
--      system.roles.manage
--
-- Actualmente ese permiso pertenece a Dirección.
--
-- La función es SECURITY DEFINER porque posteriormente las RPC
-- de asignación no tendrán acceso directo a las tablas RBAC.
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_user_can_manage_worker_roles()
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Administrador existente.
    IF public.current_user_is_admin() THEN
        RETURN TRUE;
    END IF;

    -- Worker activo con permiso explícito.
    IF public.current_user_is_worker()
       AND public.current_worker_has_permission(
           'system.roles.manage'
       ) THEN
        RETURN TRUE;
    END IF;

    RETURN FALSE;

END;
$$;


-- ============================================================
-- 2. SEGURIDAD DE LA FUNCIÓN INTERNA
-- ============================================================

REVOKE ALL
ON FUNCTION public.current_user_can_manage_worker_roles()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.current_user_can_manage_worker_roles()
FROM anon;

REVOKE ALL
ON FUNCTION public.current_user_can_manage_worker_roles()
FROM authenticated;

GRANT EXECUTE
ON FUNCTION public.current_user_can_manage_worker_roles()
TO authenticated;


COMMENT ON FUNCTION public.current_user_can_manage_worker_roles()
IS
'Comprueba si el usuario autenticado puede gestionar asignaciones RBAC de workers.';


-- ============================================================
-- 3. ASIGNAR UN ROL A UN WORKER
-- ============================================================
--
-- Parámetros:
--
--   p_worker_auth_user_id
--       auth.users.id del worker.
--
--   p_role_code
--       Código del rol RBAC.
--
-- Ejemplo:
--
--   SELECT public.assign_worker_role(
--       'UUID-DEL-WORKER',
--       'commercial'
--   );
--
-- La función es idempotente:
-- si el worker ya tiene el rol, no crea duplicados.
-- ============================================================

CREATE OR REPLACE FUNCTION public.assign_worker_role(
    p_worker_auth_user_id UUID,
    p_role_code TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role_id UUID;
    v_worker_exists BOOLEAN;
    v_normalized_role TEXT;
BEGIN

    -- --------------------------------------------------------
    -- Autenticación
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Authentication required'
            USING ERRCODE = '42501';
    END IF;


    -- --------------------------------------------------------
    -- Autorización
    -- --------------------------------------------------------

    IF NOT public.current_user_can_manage_worker_roles() THEN
        RAISE EXCEPTION
            'Insufficient permissions to manage worker roles'
            USING ERRCODE = '42501';
    END IF;


    -- --------------------------------------------------------
    -- Validación worker
    -- --------------------------------------------------------

    IF p_worker_auth_user_id IS NULL THEN
        RAISE EXCEPTION
            'Worker auth user id is required'
            USING ERRCODE = '22023';
    END IF;


    SELECT EXISTS (
        SELECT 1
        FROM public.workers w
        WHERE w.auth_user_id = p_worker_auth_user_id
    )
    INTO v_worker_exists;


    IF NOT v_worker_exists THEN
        RAISE EXCEPTION
            'Worker does not exist'
            USING ERRCODE = '22023';
    END IF;


    -- --------------------------------------------------------
    -- Normalización del rol
    -- --------------------------------------------------------

    v_normalized_role := LOWER(BTRIM(p_role_code));


    IF v_normalized_role = '' THEN
        RAISE EXCEPTION
            'Role code is required'
            USING ERRCODE = '22023';
    END IF;


    -- --------------------------------------------------------
    -- Buscar rol
    -- --------------------------------------------------------

    SELECT r.id
    INTO v_role_id
    FROM public.worker_roles r
    WHERE r.code = v_normalized_role
      AND r.is_active = TRUE;


    IF v_role_id IS NULL THEN
        RAISE EXCEPTION
            'Role does not exist or is inactive: %',
            v_normalized_role
            USING ERRCODE = '22023';
    END IF;


    -- --------------------------------------------------------
    -- Asignación
    -- --------------------------------------------------------

    INSERT INTO public.worker_role_assignments (
        worker_auth_user_id,
        role_id
    )
    VALUES (
        p_worker_auth_user_id,
        v_role_id
    )
    ON CONFLICT (
        worker_auth_user_id,
        role_id
    )
    DO NOTHING;


    RETURN TRUE;

END;
$$;


-- ============================================================
-- 4. SEGURIDAD assign_worker_role()
-- ============================================================

REVOKE ALL
ON FUNCTION public.assign_worker_role(UUID, TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.assign_worker_role(UUID, TEXT)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.assign_worker_role(UUID, TEXT)
TO authenticated;


COMMENT ON FUNCTION public.assign_worker_role(UUID, TEXT)
IS
'Asigna un rol RBAC activo a un worker existente. Solo admins o workers con system.roles.manage.';


-- ============================================================
-- 5. ELIMINAR UN ROL DE UN WORKER
-- ============================================================
--
-- No elimina el worker.
-- No elimina el rol.
-- Solo elimina la relación worker ↔ role.
-- ============================================================

CREATE OR REPLACE FUNCTION public.remove_worker_role(
    p_worker_auth_user_id UUID,
    p_role_code TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role_id UUID;
    v_normalized_role TEXT;
BEGIN

    -- --------------------------------------------------------
    -- Autenticación
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Authentication required'
            USING ERRCODE = '42501';
    END IF;


    -- --------------------------------------------------------
    -- Autorización
    -- --------------------------------------------------------

    IF NOT public.current_user_can_manage_worker_roles() THEN
        RAISE EXCEPTION
            'Insufficient permissions to manage worker roles'
            USING ERRCODE = '42501';
    END IF;


    -- --------------------------------------------------------
    -- Validaciones
    -- --------------------------------------------------------

    IF p_worker_auth_user_id IS NULL THEN
        RAISE EXCEPTION
            'Worker auth user id is required'
            USING ERRCODE = '22023';
    END IF;


    v_normalized_role := LOWER(BTRIM(p_role_code));


    IF v_normalized_role = '' THEN
        RAISE EXCEPTION
            'Role code is required'
            USING ERRCODE = '22023';
    END IF;


    SELECT r.id
    INTO v_role_id
    FROM public.worker_roles r
    WHERE r.code = v_normalized_role;


    IF v_role_id IS NULL THEN
        RAISE EXCEPTION
            'Role does not exist: %',
            v_normalized_role
            USING ERRCODE = '22023';
    END IF;


    -- --------------------------------------------------------
    -- Evitar que un worker se quite a sí mismo su último rol
    -- de administración RBAC.
    --
    -- Esto evita un bloqueo accidental de la administración
    -- desde una cuenta worker.
    -- --------------------------------------------------------

    IF p_worker_auth_user_id = auth.uid()
       AND v_normalized_role = 'direction'
       AND public.current_user_is_worker()
       AND NOT public.current_user_is_admin() THEN

        IF (
            SELECT COUNT(*)
            FROM public.worker_role_assignments wra
            JOIN public.worker_roles wr
                ON wr.id = wra.role_id
            WHERE wra.worker_auth_user_id = auth.uid()
              AND wr.is_active = TRUE
              AND wr.code = 'direction'
        ) <= 1 THEN

            RAISE EXCEPTION
                'A worker cannot remove its last Direction role'
                USING ERRCODE = '42501';

        END IF;

    END IF;


    -- --------------------------------------------------------
    -- Eliminación de relación
    -- --------------------------------------------------------

    DELETE FROM public.worker_role_assignments
    WHERE worker_auth_user_id = p_worker_auth_user_id
      AND role_id = v_role_id;


    RETURN TRUE;

END;
$$;


-- ============================================================
-- 6. SEGURIDAD remove_worker_role()
-- ============================================================

REVOKE ALL
ON FUNCTION public.remove_worker_role(UUID, TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.remove_worker_role(UUID, TEXT)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.remove_worker_role(UUID, TEXT)
TO authenticated;


COMMENT ON FUNCTION public.remove_worker_role(UUID, TEXT)
IS
'Elimina una asignación RBAC de un worker. Solo admins o workers con system.roles.manage.';


-- ============================================================
-- 7. REEMPLAZAR TODOS LOS ROLES DE UN WORKER
-- ============================================================
--
-- Esta es la función que posteriormente puede utilizar la
-- pantalla de administración de empleados.
--
-- Ejemplo:
--
-- SELECT public.replace_worker_roles(
--     'UUID-DEL-WORKER',
--     ARRAY['commercial']
-- );
--
-- O:
--
-- SELECT public.replace_worker_roles(
--     'UUID-DEL-WORKER',
--     ARRAY['developer', 'support']
-- );
--
-- El conjunto final será EXACTAMENTE el indicado.
--
-- IMPORTANTE:
-- un array NULL equivale a ningún rol.
-- un array vacío también equivale a ningún rol.
-- ============================================================

CREATE OR REPLACE FUNCTION public.replace_worker_roles(
    p_worker_auth_user_id UUID,
    p_role_codes TEXT[]
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_worker_exists BOOLEAN;
    v_requested_roles TEXT[];
    v_role_count INTEGER;
    v_existing_direction_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Autenticación
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Authentication required'
            USING ERRCODE = '42501';
    END IF;


    -- --------------------------------------------------------
    -- Autorización
    -- --------------------------------------------------------

    IF NOT public.current_user_can_manage_worker_roles() THEN
        RAISE EXCEPTION
            'Insufficient permissions to manage worker roles'
            USING ERRCODE = '42501';
    END IF;


    -- --------------------------------------------------------
    -- Validar worker
    -- --------------------------------------------------------

    IF p_worker_auth_user_id IS NULL THEN
        RAISE EXCEPTION
            'Worker auth user id is required'
            USING ERRCODE = '22023';
    END IF;


    SELECT EXISTS (
        SELECT 1
        FROM public.workers w
        WHERE w.auth_user_id = p_worker_auth_user_id
    )
    INTO v_worker_exists;


    IF NOT v_worker_exists THEN
        RAISE EXCEPTION
            'Worker does not exist'
            USING ERRCODE = '22023';
    END IF;


    -- --------------------------------------------------------
    -- Normalizar roles recibidos
    -- --------------------------------------------------------

    SELECT COALESCE(
        ARRAY_AGG(DISTINCT LOWER(BTRIM(role_code))),
        ARRAY[]::TEXT[]
    )
    INTO v_requested_roles
    FROM UNNEST(
        COALESCE(p_role_codes, ARRAY[]::TEXT[])
    ) AS role_code
    WHERE BTRIM(role_code) <> '';


    -- --------------------------------------------------------
    -- Verificar que todos los roles solicitados existen
    -- y están activos.
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM UNNEST(v_requested_roles) AS requested(code)
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.worker_roles r
            WHERE r.code = requested.code
              AND r.is_active = TRUE
        )
    ) THEN

        RAISE EXCEPTION
            'One or more requested roles do not exist or are inactive'
            USING ERRCODE = '22023';

    END IF;


    -- --------------------------------------------------------
    -- Protección contra autoeliminación del último rol
    -- de Dirección.
    -- --------------------------------------------------------

    IF p_worker_auth_user_id = auth.uid()
       AND public.current_user_is_worker()
       AND NOT public.current_user_is_admin() THEN

        SELECT COUNT(*)
        INTO v_existing_direction_count
        FROM public.worker_role_assignments wra
        JOIN public.worker_roles r
            ON r.id = wra.role_id
        WHERE wra.worker_auth_user_id = auth.uid()
          AND r.code = 'direction'
          AND r.is_active = TRUE;


        IF v_existing_direction_count > 0
           AND NOT ('direction' = ANY(v_requested_roles)) THEN

            RAISE EXCEPTION
                'A worker cannot remove its last Direction role'
                USING ERRCODE = '42501';

        END IF;

    END IF;


    -- --------------------------------------------------------
    -- Sustituir conjunto de roles
    -- --------------------------------------------------------

    DELETE FROM public.worker_role_assignments
    WHERE worker_auth_user_id = p_worker_auth_user_id;


    INSERT INTO public.worker_role_assignments (
        worker_auth_user_id,
        role_id
    )
    SELECT
        p_worker_auth_user_id,
        r.id
    FROM public.worker_roles r
    WHERE r.code = ANY(v_requested_roles)
      AND r.is_active = TRUE
    ON CONFLICT (
        worker_auth_user_id,
        role_id
    )
    DO NOTHING;


    -- --------------------------------------------------------
    -- Número final de roles
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_role_count
    FROM public.worker_role_assignments wra
    WHERE wra.worker_auth_user_id = p_worker_auth_user_id;


    RETURN v_role_count;

END;
$$;


-- ============================================================
-- 8. SEGURIDAD replace_worker_roles()
-- ============================================================

REVOKE ALL
ON FUNCTION public.replace_worker_roles(UUID, TEXT[])
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.replace_worker_roles(UUID, TEXT[])
FROM anon;

GRANT EXECUTE
ON FUNCTION public.replace_worker_roles(UUID, TEXT[])
TO authenticated;


COMMENT ON FUNCTION public.replace_worker_roles(UUID, TEXT[])
IS
'Reemplaza de forma atómica el conjunto de roles RBAC de un worker.';


-- ============================================================
-- 9. CONSULTAR ROLES DE UN WORKER
-- ============================================================
--
-- Permite a la administración consultar qué roles tiene
-- un worker concreto.
--
-- Un worker también puede consultar SUS PROPIOS roles.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_worker_roles(
    p_worker_auth_user_id UUID
)
RETURNS TABLE (
    role_id UUID,
    role_code TEXT,
    role_name TEXT,
    role_description TEXT,
    is_system_role BOOLEAN,
    is_active BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Authentication required'
            USING ERRCODE = '42501';
    END IF;


    IF p_worker_auth_user_id IS NULL THEN
        RAISE EXCEPTION
            'Worker auth user id is required'
            USING ERRCODE = '22023';
    END IF;


    -- Un worker puede consultar sus propios roles.
    -- Para consultar los de otro worker se necesita
    -- capacidad administrativa.
    IF p_worker_auth_user_id <> auth.uid()
       AND NOT public.current_user_can_manage_worker_roles() THEN

        RAISE EXCEPTION
            'Insufficient permissions to view worker roles'
            USING ERRCODE = '42501';

    END IF;


    RETURN QUERY
    SELECT
        r.id,
        r.code,
        r.name,
        r.description,
        r.is_system_role,
        r.is_active
    FROM public.worker_role_assignments wra
    JOIN public.worker_roles r
        ON r.id = wra.role_id
    WHERE wra.worker_auth_user_id = p_worker_auth_user_id
    ORDER BY r.name;

END;
$$;


-- ============================================================
-- 10. SEGURIDAD get_worker_roles()
-- ============================================================

REVOKE ALL
ON FUNCTION public.get_worker_roles(UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.get_worker_roles(UUID)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.get_worker_roles(UUID)
TO authenticated;


COMMENT ON FUNCTION public.get_worker_roles(UUID)
IS
'Devuelve los roles RBAC de un worker. El propio worker puede consultar los suyos; administración puede consultar cualquiera.';


-- ============================================================
-- 11. LISTADO ADMINISTRATIVO DE WORKERS + ROLES
-- ============================================================
--
-- Pensado para Employee/Workers area.
--
-- Devuelve:
--   auth_user_id
--   worker_id
--   nombre
--   estado activo/inactivo
--   roles
--
-- No expone contraseñas ni secretos de Auth.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_all_worker_role_assignments()
RETURNS TABLE (
    worker_id UUID,
    auth_user_id UUID,
    worker_name TEXT,
    is_active BOOLEAN,
    role_codes TEXT[],
    role_names TEXT[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Authentication required'
            USING ERRCODE = '42501';
    END IF;


    IF NOT public.current_user_can_manage_worker_roles() THEN
        RAISE EXCEPTION
            'Insufficient permissions to view worker role assignments'
            USING ERRCODE = '42501';
    END IF;


    RETURN QUERY
    SELECT
        w.id AS worker_id,
        w.auth_user_id,
        COALESCE(
            NULLIF(BTRIM(w.nombre), ''),
            NULLIF(BTRIM(w.name), ''),
            'Worker'
        ) AS worker_name,
        w.is_active,

        COALESCE(
            ARRAY_AGG(
                r.code
                ORDER BY r.name
            ) FILTER (WHERE r.id IS NOT NULL),
            ARRAY[]::TEXT[]
        ) AS role_codes,

        COALESCE(
            ARRAY_AGG(
                r.name
                ORDER BY r.name
            ) FILTER (WHERE r.id IS NOT NULL),
            ARRAY[]::TEXT[]
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
        w.is_active,
        w.nombre,
        w.name

    ORDER BY
        worker_name;

END;
$$;


-- ============================================================
-- 12. SEGURIDAD get_all_worker_role_assignments()
-- ============================================================

REVOKE ALL
ON FUNCTION public.get_all_worker_role_assignments()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.get_all_worker_role_assignments()
FROM anon;

GRANT EXECUTE
ON FUNCTION public.get_all_worker_role_assignments()
TO authenticated;


COMMENT ON FUNCTION public.get_all_worker_role_assignments()
IS
'Listado administrativo de workers y sus roles RBAC. Solo admins o workers con system.roles.manage.';


-- ============================================================
-- 13. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_functions INTEGER;
    v_direction_role BOOLEAN;
    v_commercial_role BOOLEAN;
    v_developer_role BOOLEAN;
    v_support_role BOOLEAN;
    v_accounting_role BOOLEAN;
BEGIN

    -- --------------------------------------------------------
    -- Funciones esperadas
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_functions
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'current_user_can_manage_worker_roles',
          'assign_worker_role',
          'remove_worker_role',
          'replace_worker_roles',
          'get_worker_roles',
          'get_all_worker_role_assignments'
      );


    IF v_functions <> 6 THEN
        RAISE EXCEPTION
            '098: se esperaban 6 funciones RBAC y se encontraron %.',
            v_functions;
    END IF;


    -- --------------------------------------------------------
    -- Roles creados por 097
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'direction'
          AND is_active = TRUE
    )
    INTO v_direction_role;


    SELECT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'commercial'
          AND is_active = TRUE
    )
    INTO v_commercial_role;


    SELECT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'developer'
          AND is_active = TRUE
    )
    INTO v_developer_role;


    SELECT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'support'
          AND is_active = TRUE
    )
    INTO v_support_role;


    SELECT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'accounting'
          AND is_active = TRUE
    )
    INTO v_accounting_role;


    IF NOT v_direction_role
       OR NOT v_commercial_role
       OR NOT v_developer_role
       OR NOT v_support_role
       OR NOT v_accounting_role THEN

        RAISE EXCEPTION
            '098: faltan uno o varios roles RBAC definidos en 097.';

    END IF;


    -- --------------------------------------------------------
    -- Comprobar que no se han creado asignaciones automáticas
    -- por esta migración.
    --
    -- La 098 no debe inventar asignaciones.
    -- --------------------------------------------------------

    -- No hacemos una validación COUNT = 0 aquí porque un entorno
    -- puede haber asignado roles manualmente entre migraciones.
    -- La migración únicamente garantiza que no ejecuta ningún
    -- INSERT automático sobre worker_role_assignments.

END;
$$;


-- ============================================================
-- 14. COMPROBACIÓN DE SECURITY DEFINER
-- ============================================================

DO $$
DECLARE
    v_bad_functions INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_bad_functions
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'current_user_can_manage_worker_roles',
          'assign_worker_role',
          'remove_worker_role',
          'replace_worker_roles',
          'get_worker_roles',
          'get_all_worker_role_assignments'
      )
      AND (
          p.prosecdef IS NOT TRUE
          OR NOT (
              p.proconfig @>
              ARRAY['search_path=public, pg_temp']
          )
      );


    IF v_bad_functions <> 0 THEN
        RAISE EXCEPTION
            '098: una o varias funciones RBAC no tienen SECURITY DEFINER/search_path seguro.';
    END IF;

END;
$$;


-- ============================================================
-- 15. COMENTARIOS
-- ============================================================

COMMENT ON FUNCTION public.assign_worker_role(UUID, TEXT)
IS
'Asigna un rol RBAC activo a un worker existente.';

COMMENT ON FUNCTION public.remove_worker_role(UUID, TEXT)
IS
'Elimina una asignación RBAC concreta de un worker.';

COMMENT ON FUNCTION public.replace_worker_roles(UUID, TEXT[])
IS
'Reemplaza el conjunto completo de roles RBAC de un worker.';

COMMENT ON FUNCTION public.get_worker_roles(UUID)
IS
'Consulta los roles RBAC asignados a un worker.';

COMMENT ON FUNCTION public.get_all_worker_role_assignments()
IS
'Consulta administrativa de todos los workers y sus roles RBAC.';


COMMIT;

