-- ============================================================
-- 084_project_ownership_integrity.sql
-- ============================================================

BEGIN;


-- ============================================================
-- 1. VALIDAR QUE EL PROPIETARIO PERTENECE A LA EMPRESA
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_project_owner_company()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_owner_company UUID;

BEGIN

    IF NEW.user_id IS NULL THEN
        RETURN NEW;
    END IF;


    SELECT company_id
    INTO v_owner_company
    FROM public.profiles
    WHERE id = NEW.user_id;


    IF v_owner_company IS NULL THEN
        RAISE EXCEPTION
            'El propietario del proyecto no tiene empresa asociada';
    END IF;


    IF NEW.company_id IS NOT NULL
       AND v_owner_company IS DISTINCT FROM NEW.company_id
    THEN
        RAISE EXCEPTION
            'El propietario del proyecto debe pertenecer a la empresa del proyecto';
    END IF;


    RETURN NEW;

END;
$function$;


DROP TRIGGER IF EXISTS
projects_validate_owner_company
ON public.projects;

CREATE TRIGGER
projects_validate_owner_company
BEFORE INSERT OR UPDATE OF user_id, company_id
ON public.projects
FOR EACH ROW
EXECUTE FUNCTION public.validate_project_owner_company();


COMMIT;