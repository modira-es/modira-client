-- ============================================================
-- 081_project_invoice_payment_authorization.sql
-- ============================================================

BEGIN;


-- ============================================================
-- 1. FUNCIÓN DE AUTORIZACIÓN
-- ============================================================

CREATE OR REPLACE FUNCTION public.can_user_pay_project_invoice(
    p_invoice_id UUID,
    p_user_id UUID DEFAULT auth.uid()
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_invoice public.invoices;
    v_project public.projects;

BEGIN

    IF p_user_id IS NULL THEN
        RETURN FALSE;
    END IF;


    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id;


    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;


    -- Las facturas de mantenimiento tienen su propia
    -- autorización económica.

    IF v_invoice.project_id IS NULL THEN
        RETURN FALSE;
    END IF;


    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = v_invoice.project_id;


    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;


    RETURN
        v_project.user_id = p_user_id
        AND v_project.company_id =
            public.current_user_company_id();

END;
$function$;


-- ============================================================
-- 2. PERMISOS
-- ============================================================

REVOKE ALL
ON FUNCTION public.can_user_pay_project_invoice(UUID, UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.can_user_pay_project_invoice(UUID, UUID)
TO authenticated;


COMMIT;