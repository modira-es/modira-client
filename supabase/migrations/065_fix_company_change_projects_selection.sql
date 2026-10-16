-- ============================================================
-- MODIRA — 065_fix_company_change_projects_selection.sql
-- ============================================================
-- OBJETIVO
-- 1. Mantener exactamente la opción elegida por el cliente:
--      apply_to_active_projects = TRUE/FALSE.
-- 2. NO convertir TRUE a FALSE durante la solicitud por el mero
--    hecho de que los proyectos tengan una company_id histórica
--    distinta de profiles.company_id.
-- 3. Al aprobar, trasladar únicamente proyectos:
--      - del usuario de la solicitud;
--      - en estado Pendiente, Activo o Pausado;
--      - sin ninguna factura normal asociada.
-- 4. NO mover Entregado/Completado.
-- 5. NO mover ningún proyecto que tenga factura.
-- 6. Mantener intactas las facturas y su snapshot fiscal.
-- 7. Mantener la lógica existente de creación/búsqueda de empresa,
--    validaciones y trazabilidad.
--
-- IMPORTANTE:
-- - Esta migración corrige las RPC desplegadas por la migración 064.
-- - No modifica tablas ni datos existentes.
-- - CREATE OR REPLACE conserva la firma exacta actualmente desplegada.
-- ============================================================

BEGIN;

-- ============================================================
-- 0. VALIDACIONES PREVIAS
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
            '065 stopped: public.company_change_requests does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'projects'
    ) THEN
        RAISE EXCEPTION
            '065 stopped: public.projects does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'invoices'
    ) THEN
        RAISE EXCEPTION
            '065 stopped: public.invoices does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'companies'
    ) THEN
        RAISE EXCEPTION
            '065 stopped: public.companies does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'profiles'
    ) THEN
        RAISE EXCEPTION
            '065 stopped: public.profiles does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    ) THEN
        RAISE EXCEPTION
            '065 stopped: public.workers does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
    ) THEN
        RAISE EXCEPTION
            '065 stopped: public.current_user_is_worker() does not exist';
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
            '065 stopped: public.log_activity() does not exist';
    END IF;

END;
$$;

-- ============================================================
-- 1. SOLICITAR CAMBIO DE EMPRESA
-- ============================================================
--
-- CAMBIO CLAVE RESPECTO A 064:
--
-- Antes se comprobaba si existían proyectos movibles y, si no,
-- se hacía:
--
--     v_apply_to_active_projects := FALSE;
--
-- Esto hacía que la decisión explícita del cliente se perdiera.
--
-- Ahora:
--     TRUE  -> se guarda TRUE.
--     FALSE -> se guarda FALSE.
--
-- La posibilidad real de mover proyectos se decide al APROBAR,
-- no al crear la solicitud.
--
-- Además, NO se exige que projects.company_id coincida con
-- profiles.company_id para conservar la decisión del cliente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_company_change_with_projects(
    p_requested_company_name TEXT,
    p_requested_legal_name TEXT,
    p_requested_cif_vat TEXT,
    p_requested_billing_email TEXT,
    p_requested_address TEXT,
    p_requested_postal_code TEXT,
    p_requested_city TEXT,
    p_requested_province TEXT,
    p_requested_country TEXT,
    p_reason TEXT,
    p_apply_to_active_projects BOOLEAN
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_user_id UUID;
    v_current_company_id UUID;
    v_requested_company_id UUID;
    v_request_id UUID;

    v_requested_company_name TEXT;
    v_legal_name TEXT;
    v_cif_vat TEXT;
    v_billing_email TEXT;
    v_address TEXT;
    v_postal_code TEXT;
    v_city TEXT;
    v_province TEXT;
    v_country TEXT;
    v_reason TEXT;

    v_apply_to_active_projects BOOLEAN := COALESCE(
        p_apply_to_active_projects,
        FALSE
    );

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
    -- 3. COMPROBAR PERFIL ACTIVO
    -- ========================================================

    SELECT p.company_id
    INTO v_current_company_id
    FROM public.profiles p
    WHERE p.id = v_user_id
      AND p.status = 'active'
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No se encontró un perfil activo para el usuario.';
    END IF;


    -- ========================================================
    -- 4. NORMALIZAR DATOS
    -- ========================================================

    v_requested_company_name :=
        NULLIF(BTRIM(p_requested_company_name), '');

    v_legal_name :=
        NULLIF(BTRIM(p_requested_legal_name), '');

    v_cif_vat :=
        UPPER(NULLIF(BTRIM(p_requested_cif_vat), ''));

    v_billing_email :=
        LOWER(NULLIF(BTRIM(p_requested_billing_email), ''));

    v_address :=
        NULLIF(BTRIM(p_requested_address), '');

    v_postal_code :=
        NULLIF(BTRIM(p_requested_postal_code), '');

    v_city :=
        NULLIF(BTRIM(p_requested_city), '');

    v_province :=
        NULLIF(BTRIM(p_requested_province), '');

    v_country :=
        UPPER(NULLIF(BTRIM(p_requested_country), ''));

    v_reason :=
        NULLIF(BTRIM(p_reason), '');


    -- ========================================================
    -- 5. VALIDACIONES
    -- ========================================================

    IF v_requested_company_name IS NULL THEN
        RAISE EXCEPTION
            'El nombre de empresa es obligatorio.';
    END IF;

    IF LENGTH(v_requested_company_name) > 200 THEN
        RAISE EXCEPTION
            'El nombre de empresa no puede superar 200 caracteres.';
    END IF;

    IF v_legal_name IS NULL THEN
        RAISE EXCEPTION
            'La razón social es obligatoria.';
    END IF;

    IF LENGTH(v_legal_name) > 300 THEN
        RAISE EXCEPTION
            'La razón social no puede superar 300 caracteres.';
    END IF;

    IF v_cif_vat IS NULL THEN
        RAISE EXCEPTION
            'El NIF/CIF/VAT es obligatorio.';
    END IF;

    IF LENGTH(v_cif_vat) > 100 THEN
        RAISE EXCEPTION
            'El NIF/CIF/VAT no puede superar 100 caracteres.';
    END IF;

    IF v_address IS NULL THEN
        RAISE EXCEPTION
            'La dirección fiscal es obligatoria.';
    END IF;

    IF LENGTH(v_address) > 500 THEN
        RAISE EXCEPTION
            'La dirección fiscal no puede superar 500 caracteres.';
    END IF;

    IF v_postal_code IS NULL THEN
        RAISE EXCEPTION
            'El código postal es obligatorio.';
    END IF;

    IF LENGTH(v_postal_code) > 30 THEN
        RAISE EXCEPTION
            'El código postal no puede superar 30 caracteres.';
    END IF;

    IF v_city IS NULL THEN
        RAISE EXCEPTION
            'La ciudad es obligatoria.';
    END IF;

    IF LENGTH(v_city) > 200 THEN
        RAISE EXCEPTION
            'La ciudad no puede superar 200 caracteres.';
    END IF;

    IF v_country IS NULL
       OR v_country !~ '^[A-Z]{2}$'
    THEN
        RAISE EXCEPTION
            'El país debe indicarse mediante un código ISO de dos letras.';
    END IF;

    IF v_billing_email IS NOT NULL
       AND LENGTH(v_billing_email) > 320
    THEN
        RAISE EXCEPTION
            'El email de facturación no puede superar 320 caracteres.';
    END IF;

    IF v_reason IS NOT NULL
       AND LENGTH(v_reason) > 1000
    THEN
        RAISE EXCEPTION
            'El motivo no puede superar 1000 caracteres.';
    END IF;


    -- ========================================================
    -- 6. COMPROBAR QUE NO SEA LA MISMA EMPRESA
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.companies c
        WHERE c.id = v_current_company_id
          AND LOWER(BTRIM(c.company_name))
              = LOWER(v_requested_company_name)
    ) THEN
        RAISE EXCEPTION
            'La empresa solicitada coincide con la empresa actual.';
    END IF;


    -- ========================================================
    -- 7. BUSCAR EMPRESA DESTINO SI YA EXISTE
    -- ========================================================

    SELECT c.id
    INTO v_requested_company_id
    FROM public.companies c
    WHERE c.is_active = TRUE
      AND LOWER(BTRIM(c.company_name))
          = LOWER(v_requested_company_name)
    ORDER BY c.created_at
    LIMIT 1;


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
    -- 9. CREAR SOLICITUD
    -- ========================================================
    --
    -- IMPORTANTE:
    -- v_apply_to_active_projects conserva exactamente la decisión
    -- del cliente.
    --
    -- NO se comprueba aquí si existen proyectos trasladables.
    -- Esa comprobación se hace en la aprobación para evitar que
    -- la solicitud cambie de significado entre creación y revisión.
    -- ========================================================

    INSERT INTO public.company_change_requests (
        user_id,
        current_company_id,
        requested_company_id,
        requested_company_name,

        requested_legal_name,
        requested_cif_vat,
        requested_billing_email,
        requested_address,
        requested_postal_code,
        requested_city,
        requested_province,
        requested_country,

        reason,
        apply_to_active_projects,
        status
    )
    VALUES (
        v_user_id,
        v_current_company_id,
        v_requested_company_id,
        v_requested_company_name,

        v_legal_name,
        v_cif_vat,
        v_billing_email,
        v_address,
        v_postal_code,
        v_city,
        v_province,
        v_country,

        v_reason,
        v_apply_to_active_projects,
        'pending'
    )
    RETURNING id
    INTO v_request_id;


    RETURN v_request_id;

END;
$function$;


-- ============================================================
-- 2. RESOLVER CAMBIO DE EMPRESA
-- ============================================================
--
-- CAMBIO CLAVE:
--
-- Si el cliente marcó TRUE:
--   - se mueve solo lo que puede moverse;
--   - no se exige que el proyecto tenga la misma company_id que
--     profiles.company_id;
--   - se vuelve a comprobar la ausencia de facturas EN EL MOMENTO
--     DE APROBAR.
--
-- Esto permite que un proyecto con company_id histórica distinta
-- siga siendo trasladable si:
--   - pertenece al usuario;
--   - está Pendiente/Activo/Pausado;
--   - no tiene factura normal.
--
-- La empresa del perfil cambia igualmente a la nueva empresa.
--
-- Las facturas nunca se modifican.
-- ============================================================

CREATE OR REPLACE FUNCTION public.resolve_company_change_request(
    p_request_id UUID,
    p_action TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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
    -- NO se filtra por company_id = current_company_id.
    --
    -- projects.company_id representa la empresa asociada al
    -- proyecto y puede ser histórica.
    --
    -- Solo se mueven proyectos que:
    --   1. pertenecen al usuario;
    --   2. están Pendiente, Activo o Pausado;
    --   3. NO tienen ninguna factura normal asociada.
    --
    -- La comprobación de factura se hace justo al aprobar.
    -- ========================================================

    IF COALESCE(
        v_request.apply_to_active_projects,
        FALSE
    ) THEN

        UPDATE public.projects p
        SET
            company_id = v_target_company_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE p.user_id = v_request.user_id
          AND p.estado IN (
              'Pendiente',
              'Activo',
              'Pausado'
          )
          AND NOT EXISTS (
              SELECT 1
              FROM public.invoices i
              WHERE i.project_id = p.id
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
                'El trabajador ha aprobado el cambio de empresa y se han trasladado los proyectos Pendiente, Activo y Pausado sin factura normal asociada.'
            ELSE
                'El trabajador ha aprobado el cambio de empresa sin trasladar los proyectos.'
        END,
        jsonb_build_object(
            'user_id',
            v_request.user_id,

            'previous_company_id',
            v_request.current_company_id,

            'new_company_id',
            v_target_company_id,

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
-- 3. PERMISOS
-- ============================================================
--
-- Se mantienen los permisos de ejecución de las RPC existentes.
-- No se crean GRANT nuevos innecesariamente.
-- ============================================================


-- ============================================================
-- 4. VERIFICACIÓN FINAL
-- ============================================================

DO $$
DECLARE
    v_request_exists BOOLEAN;
    v_resolve_exists BOOLEAN;
BEGIN

    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'request_company_change_with_projects'
          AND pg_get_function_identity_arguments(p.oid) =
              'p_requested_company_name text, p_requested_legal_name text, p_requested_cif_vat text, p_requested_billing_email text, p_requested_address text, p_requested_postal_code text, p_requested_city text, p_requested_province text, p_requested_country text, p_reason text, p_apply_to_active_projects boolean'
    )
    INTO v_request_exists;

    IF NOT v_request_exists THEN
        RAISE EXCEPTION
            '065 verification failed: request_company_change_with_projects() signature not found';
    END IF;


    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'resolve_company_change_request'
          AND pg_get_function_identity_arguments(p.oid) =
              'p_request_id uuid, p_action text'
    )
    INTO v_resolve_exists;

    IF NOT v_resolve_exists THEN
        RAISE EXCEPTION
            '065 verification failed: resolve_company_change_request() signature not found';
    END IF;

END;
$$;


COMMIT;

-- ============================================================
-- FIN 065
-- ============================================================
