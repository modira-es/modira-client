BEGIN;

CREATE OR REPLACE FUNCTION public.resolve_company_iva_change_request(
    p_request_id uuid,
    p_action text,
    p_worker_notes text DEFAULT NULL::text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_request public.company_iva_change_requests%ROWTYPE;
    v_user_id UUID := auth.uid();
    v_action TEXT := LOWER(TRIM(COALESCE(p_action, '')));
    v_notes TEXT := NULLIF(BTRIM(COALESCE(p_worker_notes, '')), '');

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado.';
    END IF;


    -- ========================================================
    -- 2. AUTORIZACIÓN RBAC
    -- ========================================================

    PERFORM public.require_current_worker_permission(
        'companies.update'
    );


    -- ========================================================
    -- 3. VALIDAR ACCIÓN
    -- ========================================================

    IF v_action NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION
            'La acción debe ser approved o rejected.';
    END IF;


    -- ========================================================
    -- 4. VALIDAR NOTAS
    -- ========================================================

    IF v_notes IS NOT NULL
       AND (
            LENGTH(v_notes) > 2000
            OR pg_column_size(v_notes) > 16384
       )
    THEN
        RAISE EXCEPTION
            'Las notas de revisión no pueden superar los 2000 caracteres.';
    END IF;


    -- ========================================================
    -- 5. BLOQUEAR LA SOLICITUD
    -- ========================================================

    SELECT *
    INTO v_request
    FROM public.company_iva_change_requests
    WHERE id = p_request_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La solicitud de cambio de IVA no existe.';
    END IF;


    -- ========================================================
    -- 6. SOLO SE PUEDE RESOLVER UNA SOLICITUD ACTIVA
    -- ========================================================

    IF v_request.status NOT IN ('pending', 'in_review') THEN
        RAISE EXCEPTION
            'La solicitud de cambio de IVA ya ha sido resuelta.';
    END IF;


    -- ========================================================
    -- 7. APROBACIÓN
    -- ========================================================

    IF v_action = 'approved' THEN

        UPDATE public.companies
        SET
            iva_aprobado_aplicado =
                v_request.requested_iva_aplicado,

            iva_aprobado_porcentaje =
                CASE
                    WHEN v_request.requested_iva_aplicado
                    THEN v_request.requested_iva_porcentaje
                    ELSE 0
                END,

            iva_aprobado_por =
                v_user_id,

            iva_aprobado_at =
                CURRENT_TIMESTAMP,

            updated_at =
                CURRENT_TIMESTAMP

        WHERE id = v_request.company_id;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'La empresa asociada a la solicitud no existe.';
        END IF;

    END IF;


    -- ========================================================
    -- 8. ACTUALIZAR SOLICITUD
    -- ========================================================

    UPDATE public.company_iva_change_requests
    SET
        status =
            v_action,

        reviewed_by =
            v_user_id,

        reviewed_at =
            CURRENT_TIMESTAMP,

        worker_notes =
            v_notes,

        updated_at =
            CURRENT_TIMESTAMP

    WHERE id = v_request.id;


    RETURN TRUE;

END;
$function$;

REVOKE EXECUTE
ON FUNCTION public.resolve_company_iva_change_request(
    uuid,
    text,
    text
)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.resolve_company_iva_change_request(
    uuid,
    text,
    text
)
TO authenticated;

COMMIT;