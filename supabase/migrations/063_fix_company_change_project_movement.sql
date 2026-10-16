-- ============================================================
-- 063_fix_company_change_project_movement.sql
-- Traslada todos los proyectos Pendiente, Activo y Pausado
-- del usuario al aprobar un cambio de empresa cuando
-- apply_to_active_projects = TRUE.
--
-- No se limita a current_company_id porque un usuario puede
-- conservar proyectos históricos asociados a empresas anteriores.
-- Entregado y Completado no se trasladan.
-- ============================================================

CREATE OR REPLACE FUNCTION public.resolve_company_change_request(
    p_request_id UUID,
    p_action TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$

DECLARE

    v_request public.company_change_requests%ROWTYPE;

    v_target_company_id UUID;
    v_target_company_name TEXT;
    v_company_code TEXT;

    v_moved_projects INTEGER := 0;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado.';
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'No tienes permisos para gestionar solicitudes de cambio de empresa.';
    END IF;


    IF p_request_id IS NULL THEN
        RAISE EXCEPTION
            'La solicitud es obligatoria.';
    END IF;


    IF p_action NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION
            'La acción debe ser approved o rejected.';
    END IF;


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
    -- RECHAZO
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
    -- DETERMINAR EMPRESA DESTINO
    -- ========================================================

    v_target_company_id :=
        v_request.requested_company_id;


    v_target_company_name :=
        NULLIF(
            TRIM(v_request.requested_company_name),
            ''
        );


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
    -- CONFIRMAR EMPRESA DESTINO
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
    -- ACTUALIZAR PERFIL
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
    -- TRASLADAR PROYECTOS
    -- ========================================================
    --
    -- Se trasladan TODOS los proyectos del usuario que estén
    -- en Pendiente, Activo o Pausado.
    --
    -- No se exige company_id = current_company_id porque el usuario
    -- puede conservar proyectos históricos asociados a empresas
    -- anteriores.
    --
    -- Entregado y Completado quedan fuera.
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
          AND estado IN (
              'Pendiente',
              'Activo',
              'Pausado'
          );

        GET DIAGNOSTICS v_moved_projects = ROW_COUNT;

    END IF;


    -- ========================================================
    -- MARCAR SOLICITUD COMO APROBADA
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
    -- REGISTRO DE ACTIVIDAD
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


    RETURN TRUE;

END;

$function$;