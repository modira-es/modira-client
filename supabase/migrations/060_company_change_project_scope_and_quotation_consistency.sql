BEGIN;

-- ============================================================
-- 060 — CAMBIO DE EMPRESA + TRASLADO OPCIONAL DE PROYECTOS
-- ============================================================
--
-- OBJETIVO
--
-- Permitir que un cliente indique, al solicitar un cambio de empresa,
-- si desea trasladar también sus proyectos todavía operativos.
--
-- Estados trasladables:
--
--   Pendiente
--   Activo
--   Pausado
--
-- Estados que NO se trasladan:
--
--   Entregado
--   Completado
--
-- IMPORTANTE:
--
-- - No se modifica la RPC antigua request_company_change(TEXT).
-- - Se crea una nueva RPC:
--
--     request_company_change_with_projects(TEXT, BOOLEAN)
--
-- - La decisión queda almacenada en:
--
--     company_change_requests.apply_to_active_projects
--
-- - El traslado real de proyectos SOLO se ejecuta al aprobar
--   la solicitud mediante resolve_company_change_request().
-- - El frontend nunca modifica projects.company_id directamente.
-- - La actualización de proyectos se limita al usuario de la
--   solicitud y a su empresa actual registrada en la solicitud.
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
    ) THEN
        RAISE EXCEPTION
            '060 failed: company_change_requests no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'projects'
    ) THEN
        RAISE EXCEPTION
            '060 failed: projects no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'profiles'
    ) THEN
        RAISE EXCEPTION
            '060 failed: profiles no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'companies'
    ) THEN
        RAISE EXCEPTION
            '060 failed: companies no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '060 failed: current_user_is_worker() no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_active'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '060 failed: current_user_is_active() no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'log_activity'
    ) THEN
        RAISE EXCEPTION
            '060 failed: log_activity() no existe';
    END IF;

END;
$$;


-- ============================================================
-- 2. NUEVA COLUMNA
-- ============================================================
--
-- FALSE:
--   el cambio de empresa NO afecta a los proyectos.
--
-- TRUE:
--   al aprobarse la solicitud, se trasladan los proyectos:
--
--     Pendiente
--     Activo
--     Pausado
--
-- ============================================================

ALTER TABLE public.company_change_requests
ADD COLUMN IF NOT EXISTS apply_to_active_projects BOOLEAN
NOT NULL
DEFAULT FALSE;


COMMENT ON COLUMN public.company_change_requests.apply_to_active_projects
IS
'Indica si, al aprobar el cambio de empresa, deben trasladarse los proyectos del usuario en estado Pendiente, Activo o Pausado. Los proyectos Entregado y Completado nunca se trasladan.';


-- ============================================================
-- 3. NUEVA RPC — SOLICITAR CAMBIO DE EMPRESA
-- ============================================================
--
-- No reemplazamos request_company_change(TEXT).
--
-- Esta nueva RPC recibe:
--
--   p_requested_company_name
--   p_apply_to_active_projects
--
-- La decisión solamente se guarda.
--
-- NO modifica:
--
--   profiles
--   projects
--   companies
--
-- Eso solamente ocurre cuando un worker aprueba la solicitud.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_company_change_with_projects(
    p_requested_company_name TEXT,
    p_apply_to_active_projects BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE

    v_user_id UUID;
    v_current_company_id UUID;
    v_requested_company_id UUID;
    v_requested_company_name TEXT;
    v_request_id UUID;

    v_has_movable_projects BOOLEAN := FALSE;

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión para solicitar un cambio de empresa.';
    END IF;


    -- ========================================================
    -- 2. LOS WORKERS NO UTILIZAN ESTE FLUJO
    -- ========================================================

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Las cuentas de trabajadores no pueden solicitar cambio de empresa.';
    END IF;


    -- ========================================================
    -- 3. CUENTA ACTIVA
    -- ========================================================

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'La cuenta no está activa.';
    END IF;


    -- ========================================================
    -- 4. VALIDAR NOMBRE
    -- ========================================================

    v_requested_company_name :=
        NULLIF(
            TRIM(p_requested_company_name),
            ''
        );


    IF v_requested_company_name IS NULL THEN
        RAISE EXCEPTION
            'Debes indicar la empresa solicitada.';
    END IF;


    IF LENGTH(v_requested_company_name) > 200 THEN
        RAISE EXCEPTION
            'El nombre de la empresa no puede superar los 200 caracteres.';
    END IF;


    -- ========================================================
    -- 5. OBTENER EMPRESA ACTUAL
    -- ========================================================

    SELECT p.company_id
    INTO v_current_company_id
    FROM public.profiles p
    WHERE p.id = v_user_id;


    IF v_current_company_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario no tiene una empresa asociada.';
    END IF;


    -- ========================================================
    -- 6. BUSCAR EMPRESA DESTINO
    -- ========================================================

    SELECT c.id
    INTO v_requested_company_id
    FROM public.companies c
    WHERE c.is_active = TRUE
      AND LOWER(TRIM(c.company_name)) =
          LOWER(v_requested_company_name)
    LIMIT 1;


    -- ========================================================
    -- 7. IMPEDIR SOLICITAR LA EMPRESA ACTUAL
    -- ========================================================

    IF v_requested_company_id IS NOT NULL
       AND v_requested_company_id IS NOT DISTINCT FROM
           v_current_company_id
    THEN

        RAISE EXCEPTION
            'La empresa solicitada ya es tu empresa actual.';

    END IF;


    -- ========================================================
    -- 8. UNA SOLA SOLICITUD PENDIENTE
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.company_change_requests r
        WHERE r.user_id = v_user_id
          AND r.status = 'pending'
    ) THEN

        RAISE EXCEPTION
            'Ya tienes una solicitud de cambio de empresa pendiente.';

    END IF;


    -- ========================================================
    -- 9. COMPROBAR SI EXISTEN PROYECTOS TRASLADABLES
    -- ========================================================
    --
    -- Solamente:
    --
    --   Pendiente
    --   Activo
    --   Pausado
    --
    -- No se consideran:
    --
    --   Entregado
    --   Completado
    --
    -- Además, deben pertenecer:
    --
    --   al usuario
    --   a su empresa actual
    --
    -- ========================================================

    SELECT EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.user_id = v_user_id
          AND p.company_id = v_current_company_id
          AND p.estado IN (
              'Pendiente',
              'Activo',
              'Pausado'
          )
    )
    INTO v_has_movable_projects;


    -- ========================================================
    -- 10. NO PERMITIR QUE EL FRONTEND INVENTE UNA ELECCIÓN
    -- ========================================================
    --
    -- Si no existen proyectos trasladables, la solicitud siempre
    -- queda registrada como FALSE.
    --
    -- Así, aunque alguien manipule el frontend y envíe TRUE,
    -- no se almacena una decisión que no corresponde a ningún
    -- proyecto.
    --
    -- ========================================================

    IF NOT v_has_movable_projects THEN
        p_apply_to_active_projects := FALSE;
    END IF;


    -- ========================================================
    -- 11. INSERTAR SOLICITUD
    -- ========================================================

    INSERT INTO public.company_change_requests (
        user_id,
        current_company_id,
        requested_company_id,
        requested_company_name,
        apply_to_active_projects,
        status
    )
    VALUES (
        v_user_id,
        v_current_company_id,
        v_requested_company_id,
        v_requested_company_name,
        COALESCE(p_apply_to_active_projects, FALSE),
        'pending'
    )
    RETURNING id
    INTO v_request_id;


    -- ========================================================
    -- 12. DEVOLVER ID
    -- ========================================================

    RETURN v_request_id;

END;
$function$;


-- ============================================================
-- 4. PERMISOS DE LA NUEVA RPC
-- ============================================================

REVOKE ALL
ON FUNCTION public.request_company_change_with_projects(
    TEXT,
    BOOLEAN
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.request_company_change_with_projects(
    TEXT,
    BOOLEAN
)
TO authenticated;


ALTER FUNCTION public.request_company_change_with_projects(
    TEXT,
    BOOLEAN
)
SET search_path = public, pg_temp;


COMMENT ON FUNCTION public.request_company_change_with_projects(
    TEXT,
    BOOLEAN
)
IS
'Permite a un cliente solicitar un cambio de empresa indicando si desea trasladar sus proyectos Pendiente, Activo o Pausado. El traslado se ejecuta únicamente al aprobar la solicitud.';


-- ============================================================
-- 5. REDEFINIR resolve_company_change_request()
-- ============================================================
--
-- Se mantiene EXACTAMENTE la misma firma:
--
--   resolve_company_change_request(UUID, TEXT)
--
-- y el mismo retorno:
--
--   BOOLEAN
--
-- La única ampliación funcional es:
--
--   si la solicitud está aprobada y
--   apply_to_active_projects = TRUE
--
-- se trasladan los proyectos:
--
--   Pendiente
--   Activo
--   Pausado
--
-- pertenecientes al usuario y a current_company_id.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.resolve_company_change_request(
    p_request_id UUID,
    p_action TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE

    v_request public.company_change_requests%ROWTYPE;

    v_target_company_id UUID;
    v_target_company_name TEXT;
    v_company_code TEXT;

    v_moved_projects INTEGER := 0;

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado.';
    END IF;


    -- ========================================================
    -- 2. SOLO WORKERS ACTIVOS
    -- ========================================================

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'No tienes permisos para gestionar solicitudes de cambio de empresa.';
    END IF;


    -- ========================================================
    -- 3. VALIDAR PARÁMETROS
    -- ========================================================

    IF p_request_id IS NULL THEN
        RAISE EXCEPTION
            'La solicitud es obligatoria.';
    END IF;


    IF p_action NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION
            'La acción debe ser approved o rejected.';
    END IF;


    -- ========================================================
    -- 4. OBTENER Y BLOQUEAR SOLICITUD
    -- ========================================================

    SELECT *
    INTO v_request
    FROM public.company_change_requests
    WHERE id = p_request_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La solicitud indicada no existe.';
    END IF;


    IF v_request.status <> 'pending' THEN
        RAISE EXCEPTION
            'La solicitud ya ha sido gestionada.';
    END IF;


    -- ========================================================
    -- 5. RECHAZO
    -- ========================================================

    IF p_action = 'rejected' THEN

        UPDATE public.company_change_requests
        SET
            status = 'rejected',
            reviewed_by = (
                SELECT w.id
                FROM public.workers w
                WHERE w.auth_user_id = auth.uid()
                LIMIT 1
            ),
            reviewed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_request_id;


        RETURN TRUE;

    END IF;


    -- ========================================================
    -- 6. DETERMINAR EMPRESA DESTINO
    -- ========================================================

    v_target_company_id :=
        v_request.requested_company_id;


    v_target_company_name :=
        NULLIF(
            TRIM(v_request.requested_company_name),
            ''
        );


    -- ========================================================
    -- 7. SI YA EXISTE COMPANY_ID,
    --    COMPROBAR QUE SIGUE ACTIVA
    -- ========================================================

    IF v_target_company_id IS NOT NULL THEN

        SELECT c.company_name
        INTO v_target_company_name
        FROM public.companies c
        WHERE c.id = v_target_company_id
          AND c.is_active = TRUE;


        IF v_target_company_name IS NULL THEN
            v_target_company_id := NULL;
        END IF;

    END IF;


    -- ========================================================
    -- 8. SI NO TENEMOS COMPANY_ID,
    --    BUSCAR POR NOMBRE
    -- ========================================================

    IF v_target_company_id IS NULL
       AND v_target_company_name IS NOT NULL
    THEN

        SELECT c.id
        INTO v_target_company_id
        FROM public.companies c
        WHERE c.is_active = TRUE
          AND LOWER(TRIM(c.company_name)) =
              LOWER(v_target_company_name)
        ORDER BY c.created_at ASC
        LIMIT 1;

    END IF;


    -- ========================================================
    -- 9. SI NO EXISTE, CREAR EMPRESA
    -- ========================================================

    IF v_target_company_id IS NULL THEN

        IF v_target_company_name IS NULL THEN
            RAISE EXCEPTION
                'La solicitud no contiene un nombre de empresa válido.';
        END IF;


        v_company_code :=
            'CLI-' ||
            UPPER(
                REPLACE(
                    gen_random_uuid()::TEXT,
                    '-',
                    ''
                )
            );


        INSERT INTO public.companies (
            company_code,
            company_name,
            legal_name,
            created_by,
            is_active
        )
        VALUES (
            v_company_code,
            v_target_company_name,
            v_target_company_name,
            auth.uid(),
            TRUE
        )
        RETURNING id
        INTO v_target_company_id;

    END IF;


    -- ========================================================
    -- 10. CONFIRMAR EMPRESA DESTINO
    -- ========================================================

    SELECT c.company_name
    INTO v_target_company_name
    FROM public.companies c
    WHERE c.id = v_target_company_id
      AND c.is_active = TRUE;


    IF v_target_company_name IS NULL THEN
        RAISE EXCEPTION
            'La empresa solicitada no existe o está inactiva.';
    END IF;


    -- ========================================================
    -- 11. ACTUALIZAR PERFIL
    -- ========================================================

    UPDATE public.profiles
    SET
        company_id = v_target_company_id,
        empresa = v_target_company_name,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_request.user_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El perfil del usuario asociado a la solicitud no existe.';
    END IF;


    -- ========================================================
    -- 12. TRASLADAR PROYECTOS SI EL CLIENTE LO SOLICITÓ
    -- ========================================================
    --
    -- MUY IMPORTANTE:
    --
    -- No utilizamos únicamente user_id.
    --
    -- También exigimos:
    --
    --   company_id = current_company_id
    --
    -- almacenado en la solicitud.
    --
    -- Esto evita mover accidentalmente proyectos que entretanto
    -- hayan sido reasignados a otra empresa.
    --
    -- Estados permitidos:
    --
    --   Pendiente
    --   Activo
    --   Pausado
    --
    -- Entregado y Completado quedan fuera.
    --
    -- ========================================================

    IF COALESCE(
        v_request.apply_to_active_projects,
        FALSE
    ) THEN

        UPDATE public.projects
        SET
            company_id = v_target_company_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = v_request.user_id
          AND company_id = v_request.current_company_id
          AND estado IN (
              'Pendiente',
              'Activo',
              'Pausado'
          );


        GET DIAGNOSTICS v_moved_projects = ROW_COUNT;

    END IF;


    -- ========================================================
    -- 13. MARCAR SOLICITUD COMO APROBADA
    -- ========================================================

    UPDATE public.company_change_requests
    SET
        requested_company_id = v_target_company_id,
        requested_company_name = v_target_company_name,
        status = 'approved',
        reviewed_by = (
            SELECT w.id
            FROM public.workers w
            WHERE w.auth_user_id = auth.uid()
            LIMIT 1
        ),
        reviewed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_request_id;


    -- ========================================================
    -- 14. REGISTRO DE ACTIVIDAD
    -- ========================================================

    PERFORM public.log_activity(
        'company_change_approved',
        'company_change_request',
        v_request.id,
        CASE
            WHEN COALESCE(
                v_request.apply_to_active_projects,
                FALSE
            )
            THEN
                'El trabajador ha aprobado el cambio de empresa y se han trasladado los proyectos Pendiente, Activo y Pausado del usuario.'
            ELSE
                'El trabajador ha aprobado el cambio de empresa sin trasladar los proyectos.'
        END,
        jsonb_build_object(
            'user_id', v_request.user_id,
            'previous_company_id', v_request.current_company_id,
            'new_company_id', v_target_company_id,
            'apply_to_active_projects',
                COALESCE(
                    v_request.apply_to_active_projects,
                    FALSE
                ),
            'moved_projects_count',
                v_moved_projects
        )
    );


    -- ========================================================
    -- 15. ÉXITO
    -- ========================================================

    RETURN TRUE;

END;
$function$;


-- ============================================================
-- 6. PERMISOS DE resolve_company_change_request()
-- ============================================================

REVOKE ALL
ON FUNCTION public.resolve_company_change_request(
    UUID,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.resolve_company_change_request(
    UUID,
    TEXT
)
TO authenticated;


ALTER FUNCTION public.resolve_company_change_request(
    UUID,
    TEXT
)
SET search_path = public, pg_temp;


COMMENT ON FUNCTION public.resolve_company_change_request(
    UUID,
    TEXT
)
IS
'Permite a un worker resolver una solicitud de cambio de empresa. Si fue solicitada, traslada únicamente los proyectos del usuario en estado Pendiente, Activo o Pausado y pertenecientes a la empresa actual registrada en la solicitud.';


-- ============================================================
-- 7. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
    v_column_type TEXT;
BEGIN

    -- --------------------------------------------------------
    -- COLUMNA
    -- --------------------------------------------------------

    SELECT data_type
    INTO v_column_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'company_change_requests'
      AND column_name = 'apply_to_active_projects';


    IF v_column_type <> 'boolean' THEN
        RAISE EXCEPTION
            '060 failed: apply_to_active_projects no es BOOLEAN';
    END IF;


    -- --------------------------------------------------------
    -- NUEVA RPC
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'request_company_change_with_projects'
      AND pg_get_function_identity_arguments(p.oid) =
          'p_requested_company_name text, p_apply_to_active_projects boolean';


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '060 failed: request_company_change_with_projects() no existe correctamente';
    END IF;


    -- --------------------------------------------------------
    -- RPC DE RESOLUCIÓN
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'resolve_company_change_request'
      AND pg_get_function_identity_arguments(p.oid) =
          'p_request_id uuid, p_action text';


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '060 failed: resolve_company_change_request() no existe correctamente';
    END IF;


    -- --------------------------------------------------------
    -- RPC ANTIGUA
    -- --------------------------------------------------------
    --
    -- La mantenemos para compatibilidad.
    --

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'request_company_change'
      AND pg_get_function_identity_arguments(p.oid) =
          'p_requested_company_name text';


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '060 failed: la RPC antigua request_company_change(TEXT) ha desaparecido';
    END IF;


    -- --------------------------------------------------------
    -- ESTADOS DE PROYECTO
    -- --------------------------------------------------------
    --
    -- Verificación defensiva de que el modelo actual conserva
    -- los cinco estados documentados.
    --

    IF EXISTS (
        SELECT 1
        FROM public.projects
        WHERE estado IS NOT NULL
          AND estado NOT IN (
              'Pendiente',
              'Activo',
              'Pausado',
              'Entregado',
              'Completado'
          )
        LIMIT 1
    ) THEN
        RAISE EXCEPTION
            '060 failed: existen proyectos con un estado no contemplado por el modelo';
    END IF;

END;
$$;


COMMIT;