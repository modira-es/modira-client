BEGIN;

-- ============================================================
-- MODIRA — 096 WORKER RBAC CONTEXT
-- ============================================================
--
-- OBJETIVO
--
-- Crear la capa segura de lectura/autorización del RBAC creada
-- en la migración 095.
--
-- Esta migración crea:
--
--   1. current_worker_has_permission(TEXT)
--   2. current_worker_has_any_permission(TEXT[])
--   3. current_worker_has_all_permissions(TEXT[])
--   4. get_current_worker_permissions()
--
-- IMPORTANTE
--
-- ESTA MIGRACIÓN:
--
--   - NO modifica ninguna policy existente.
--   - NO modifica clients.
--   - NO modifica companies.
--   - NO modifica quotations.
--   - NO modifica invoices.
--   - NO modifica payments.
--   - NO modifica projects.
--   - NO modifica support.
--   - NO modifica Storage.
--   - NO modifica workers.
--   - NO modifica profiles.
--   - NO modifica current_user_is_worker().
--   - NO asigna ningún rol.
--   - NO crea permisos.
--   - NO cambia el acceso efectivo de ningún worker.
--
-- Su única finalidad es proporcionar las funciones centrales que
-- utilizarán las migraciones RBAC posteriores.
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================
--
-- Comprobamos que la infraestructura creada en 095 existe.
--
-- Si algo falta, la migración se detiene antes de modificar
-- cualquier función.
-- ============================================================

DO $$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- --------------------------------------------------------
    -- worker_roles
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_roles'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC 096 stopped: public.worker_roles does not exist. Run migration 095 first.';
    END IF;


    -- --------------------------------------------------------
    -- worker_permissions
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_permissions'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC 096 stopped: public.worker_permissions does not exist. Run migration 095 first.';
    END IF;


    -- --------------------------------------------------------
    -- worker_role_permissions
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_role_permissions'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC 096 stopped: public.worker_role_permissions does not exist. Run migration 095 first.';
    END IF;


    -- --------------------------------------------------------
    -- worker_role_assignments
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'worker_role_assignments'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC 096 stopped: public.worker_role_assignments does not exist. Run migration 095 first.';
    END IF;


    -- --------------------------------------------------------
    -- workers
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC 096 stopped: public.workers does not exist.';
    END IF;


    -- --------------------------------------------------------
    -- workers.auth_user_id
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'workers'
          AND column_name = 'auth_user_id'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC 096 stopped: workers.auth_user_id does not exist.';
    END IF;


    -- --------------------------------------------------------
    -- workers.is_active
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'workers'
          AND column_name = 'is_active'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC 096 stopped: workers.is_active does not exist.';
    END IF;


    -- --------------------------------------------------------
    -- current_user_is_worker()
    --
    -- Debe existir porque seguirá siendo la primera barrera:
    --
    --   authenticated
    --        ↓
    --   worker activo
    --        ↓
    --   RBAC
    --
    -- No sustituimos esta función.
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
          AND p.pronargs = 0
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC 096 stopped: public.current_user_is_worker() does not exist.';
    END IF;

END;
$$;


-- ============================================================
-- 2. current_worker_has_permission(TEXT)
-- ============================================================
--
-- Comprueba si el usuario autenticado actualmente tiene un
-- permiso concreto.
--
-- Ejemplo:
--
--   SELECT public.current_worker_has_permission(
--       'quotations.create'
--   );
--
-- Devuelve:
--
--   TRUE
--       → usuario autenticado
--       → worker activo
--       → tiene al menos un rol activo
--       → ese rol posee el permiso
--
--   FALSE
--       → cualquier otro caso
--
-- La función NO acepta worker_auth_user_id como argumento.
--
-- Esto es deliberado.
--
-- El usuario nunca puede preguntar:
--
--   "¿Tiene este otro worker el permiso X?"
--
-- La función siempre trabaja con:
--
--   auth.uid()
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_worker_has_permission(
    p_permission_code TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

    SELECT
        CASE
            WHEN auth.uid() IS NULL THEN FALSE

            WHEN p_permission_code IS NULL THEN FALSE

            WHEN btrim(p_permission_code) = '' THEN FALSE

            WHEN NOT public.current_user_is_worker() THEN FALSE

            ELSE EXISTS (
                SELECT 1
                FROM public.worker_role_assignments wra

                INNER JOIN public.worker_roles wr
                    ON wr.id = wra.role_id

                INNER JOIN public.worker_role_permissions wrp
                    ON wrp.role_id = wr.id

                INNER JOIN public.worker_permissions wp
                    ON wp.id = wrp.permission_id

                WHERE wra.worker_auth_user_id = auth.uid()

                  AND wr.is_active = TRUE

                  AND wp.code = lower(btrim(p_permission_code))
            )
        END;

$function$;


-- ============================================================
-- 3. current_worker_has_any_permission(TEXT[])
-- ============================================================
--
-- Devuelve TRUE si el worker actual posee AL MENOS UNO de los
-- permisos recibidos.
--
-- Ejemplo:
--
--   SELECT public.current_worker_has_any_permission(
--       ARRAY[
--           'quotations.read',
--           'billing.read'
--       ]
--   );
--
-- Útil cuando una operación puede ser autorizada mediante
-- diferentes permisos.
--
-- Ejemplo futuro:
--
--   quotations.read
--   OR
--   system.audit.read
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_worker_has_any_permission(
    p_permission_codes TEXT[]
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

    SELECT
        CASE
            WHEN auth.uid() IS NULL THEN FALSE

            WHEN p_permission_codes IS NULL THEN FALSE

            WHEN cardinality(p_permission_codes) = 0 THEN FALSE

            WHEN NOT public.current_user_is_worker() THEN FALSE

            ELSE EXISTS (
                SELECT 1
                FROM public.worker_role_assignments wra

                INNER JOIN public.worker_roles wr
                    ON wr.id = wra.role_id

                INNER JOIN public.worker_role_permissions wrp
                    ON wrp.role_id = wr.id

                INNER JOIN public.worker_permissions wp
                    ON wp.id = wrp.permission_id

                INNER JOIN (
                    SELECT DISTINCT
                        lower(btrim(value)) AS permission_code
                    FROM unnest(p_permission_codes) AS value
                    WHERE btrim(value) <> ''
                ) requested
                    ON requested.permission_code = wp.code

                WHERE wra.worker_auth_user_id = auth.uid()

                  AND wr.is_active = TRUE
            )
        END;

$function$;


-- ============================================================
-- 4. current_worker_has_all_permissions(TEXT[])
-- ============================================================
--
-- Devuelve TRUE únicamente cuando el worker actual posee TODOS
-- los permisos solicitados.
--
-- Ejemplo:
--
--   SELECT public.current_worker_has_all_permissions(
--       ARRAY[
--           'clients.read',
--           'clients.update'
--       ]
--   );
--
-- Esto será útil para operaciones que requieren una combinación
-- concreta de permisos.
--
-- IMPORTANTE:
--
-- Una lista NULL o vacía devuelve FALSE.
--
-- Esto evita que una llamada accidental con:
--
--   ARRAY[]::TEXT[]
--
-- pueda interpretarse como autorización.
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_worker_has_all_permissions(
    p_permission_codes TEXT[]
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

    WITH requested AS (
        SELECT DISTINCT
            lower(btrim(value)) AS permission_code
        FROM unnest(
            COALESCE(
                p_permission_codes,
                ARRAY[]::TEXT[]
            )
        ) AS value
        WHERE btrim(value) <> ''
    ),

    requested_count AS (
        SELECT COUNT(*)::BIGINT AS total
        FROM requested
    ),

    granted AS (
        SELECT DISTINCT
            wp.code
        FROM public.worker_role_assignments wra

        INNER JOIN public.worker_roles wr
            ON wr.id = wra.role_id

        INNER JOIN public.worker_role_permissions wrp
            ON wrp.role_id = wr.id

        INNER JOIN public.worker_permissions wp
            ON wp.id = wrp.permission_id

        INNER JOIN requested r
            ON r.permission_code = wp.code

        WHERE wra.worker_auth_user_id = auth.uid()

          AND wr.is_active = TRUE
    )

    SELECT
        CASE
            WHEN auth.uid() IS NULL THEN FALSE

            WHEN p_permission_codes IS NULL THEN FALSE

            WHEN cardinality(p_permission_codes) = 0 THEN FALSE

            WHEN NOT public.current_user_is_worker() THEN FALSE

            ELSE (
                SELECT COUNT(*)::BIGINT
                FROM granted
            )
            =
            (
                SELECT total
                FROM requested_count
            )
        END;

$function$;


-- ============================================================
-- 5. get_current_worker_permissions()
-- ============================================================
--
-- Devuelve todos los permisos efectivos del worker autenticado.
--
-- Esta será la función principal que utilizará el frontend para
-- conocer qué puede mostrar.
--
-- Ejemplo:
--
--   SELECT *
--   FROM public.get_current_worker_permissions();
--
-- Resultado futuro:
--
--   clients.read
--   clients.update
--   companies.read
--   companies.update
--   quotations.read
--   quotations.create
--   quotations.update
--   ...
--
-- Solo devuelve permisos del usuario autenticado.
--
-- Un cliente normal:
--
--   → devuelve 0 filas.
--
-- Un worker inactivo:
--
--   → devuelve 0 filas.
--
-- Un worker activo sin roles:
--
--   → devuelve 0 filas.
--
-- Un worker activo con roles:
--
--   → devuelve la unión de permisos de todos sus roles activos.
--
-- Si dos roles proporcionan el mismo permiso:
--
--   → aparece una sola vez.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_current_worker_permissions()
RETURNS TABLE (
    permission_code TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

    SELECT DISTINCT
        wp.code AS permission_code

    FROM public.worker_role_assignments wra

    INNER JOIN public.worker_roles wr
        ON wr.id = wra.role_id

    INNER JOIN public.worker_role_permissions wrp
        ON wrp.role_id = wr.id

    INNER JOIN public.worker_permissions wp
        ON wp.id = wrp.permission_id

    WHERE wra.worker_auth_user_id = auth.uid()

      AND wr.is_active = TRUE

      AND public.current_user_is_worker()

    ORDER BY wp.code;

$function$;


-- ============================================================
-- 6. PROTECCIÓN DE EXECUTE
-- ============================================================
--
-- PostgreSQL concede EXECUTE a PUBLIC por defecto al crear una
-- función.
--
-- Como estas funciones forman parte de la capa de autorización,
-- eliminamos explícitamente ese acceso.
--
-- Permitimos EXECUTE únicamente a authenticated.
--
-- IMPORTANTE:
--
-- authenticated NO significa que el usuario sea worker.
--
-- La propia función comprueba:
--
--   auth.uid()
--   +
--   current_user_is_worker()
--   +
--   RBAC
--
-- Por tanto:
--
-- Cliente:
--   puede llamar → recibe FALSE / 0 filas.
--
-- Worker activo:
--   puede llamar → recibe sus permisos.
--
-- Worker inactivo:
--   puede llamar → recibe FALSE / 0 filas.
--
-- ============================================================

REVOKE ALL
ON FUNCTION public.current_worker_has_permission(TEXT)
FROM PUBLIC, anon, authenticated;


REVOKE ALL
ON FUNCTION public.current_worker_has_any_permission(TEXT[])
FROM PUBLIC, anon, authenticated;


REVOKE ALL
ON FUNCTION public.current_worker_has_all_permissions(TEXT[])
FROM PUBLIC, anon, authenticated;


REVOKE ALL
ON FUNCTION public.get_current_worker_permissions()
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.current_worker_has_permission(TEXT)
TO authenticated;


GRANT EXECUTE
ON FUNCTION public.current_worker_has_any_permission(TEXT[])
TO authenticated;


GRANT EXECUTE
ON FUNCTION public.current_worker_has_all_permissions(TEXT[])
TO authenticated;


GRANT EXECUTE
ON FUNCTION public.get_current_worker_permissions()
TO authenticated;


-- ============================================================
-- 7. COMENTARIOS
-- ============================================================

COMMENT ON FUNCTION public.current_worker_has_permission(TEXT)
IS
'MODIRA RBAC: comprueba si el worker autenticado posee un permiso concreto.';


COMMENT ON FUNCTION public.current_worker_has_any_permission(TEXT[])
IS
'MODIRA RBAC: comprueba si el worker autenticado posee al menos uno de los permisos indicados.';


COMMENT ON FUNCTION public.current_worker_has_all_permissions(TEXT[])
IS
'MODIRA RBAC: comprueba si el worker autenticado posee todos los permisos indicados.';


COMMENT ON FUNCTION public.get_current_worker_permissions()
IS
'MODIRA RBAC: devuelve los permisos efectivos del worker autenticado.';


-- ============================================================
-- 8. VERIFICACIONES FINALES
-- ============================================================
--
-- Verificamos:
--
--   - existencia de las cuatro funciones;
--   - SECURITY DEFINER;
--   - search_path correcto;
--   - EXECUTE para authenticated;
--   - ausencia de EXECUTE para anon/PUBLIC.
--
-- Si cualquiera de estas comprobaciones falla, toda la
-- transacción se revierte.
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- current_worker_has_permission(TEXT)
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_worker_has_permission'
      AND pg_get_function_identity_arguments(p.oid) = 'p_permission_code text'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC 096 verification failed: current_worker_has_permission(TEXT) is not correctly defined';
    END IF;


    -- --------------------------------------------------------
    -- current_worker_has_any_permission(TEXT[])
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_worker_has_any_permission'
      AND pg_get_function_identity_arguments(p.oid) = 'p_permission_codes text[]'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC 096 verification failed: current_worker_has_any_permission(TEXT[]) is not correctly defined';
    END IF;


    -- --------------------------------------------------------
    -- current_worker_has_all_permissions(TEXT[])
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_worker_has_all_permissions'
      AND pg_get_function_identity_arguments(p.oid) = 'p_permission_codes text[]'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC 096 verification failed: current_worker_has_all_permissions(TEXT[]) is not correctly defined';
    END IF;


    -- --------------------------------------------------------
    -- get_current_worker_permissions()
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_current_worker_permissions'
      AND p.pronargs = 0
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC 096 verification failed: get_current_worker_permissions() is not correctly defined';
    END IF;


    -- --------------------------------------------------------
    -- Verificar search_path de las cuatro funciones.
    -- --------------------------------------------------------
    --
    -- Queremos:
    --
    --   public, pg_temp
    --
    -- y no un search_path heredado del usuario.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'current_worker_has_permission',
          'current_worker_has_any_permission',
          'current_worker_has_all_permissions',
          'get_current_worker_permissions'
      )
      AND p.proconfig @> ARRAY[
          'search_path=public, pg_temp'
      ];

    IF v_count <> 4 THEN
        RAISE EXCEPTION
            'RBAC 096 verification failed: one or more RBAC functions have an unexpected search_path';
    END IF;


    -- --------------------------------------------------------
    -- Verificar EXECUTE para authenticated.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.routine_privileges
    WHERE routine_schema = 'public'
      AND routine_name IN (
          'current_worker_has_permission',
          'current_worker_has_any_permission',
          'current_worker_has_all_permissions',
          'get_current_worker_permissions'
      )
      AND grantee = 'authenticated'
      AND privilege_type = 'EXECUTE';

    IF v_count <> 4 THEN
        RAISE EXCEPTION
            'RBAC 096 verification failed: authenticated does not have EXECUTE on all RBAC functions';
    END IF;


    -- --------------------------------------------------------
    -- Verificar que PUBLIC NO tenga EXECUTE.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.routine_privileges
    WHERE routine_schema = 'public'
      AND routine_name IN (
          'current_worker_has_permission',
          'current_worker_has_any_permission',
          'current_worker_has_all_permissions',
          'get_current_worker_permissions'
      )
      AND grantee = 'PUBLIC'
      AND privilege_type = 'EXECUTE';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'RBAC 096 verification failed: PUBLIC still has EXECUTE on RBAC functions';
    END IF;


    -- --------------------------------------------------------
    -- Verificar que anon NO tenga EXECUTE.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.routine_privileges
    WHERE routine_schema = 'public'
      AND routine_name IN (
          'current_worker_has_permission',
          'current_worker_has_any_permission',
          'current_worker_has_all_permissions',
          'get_current_worker_permissions'
      )
      AND grantee = 'anon'
      AND privilege_type = 'EXECUTE';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'RBAC 096 verification failed: anon still has EXECUTE on RBAC functions';
    END IF;


    -- --------------------------------------------------------
    -- Verificación:
    -- no se han creado policies sobre las funciones porque
    -- las funciones no utilizan RLS como mecanismo de acceso.
    -- --------------------------------------------------------
    --
    -- No se realiza ninguna modificación de policies existentes.
    -- --------------------------------------------------------

END;
$$;


-- ============================================================
-- 9. COMMIT
-- ============================================================

COMMIT;