BEGIN;

-- ============================================================
-- 070 - HARDEN WORKER AUTOMATION EXECUTION
--
-- create_automation_run()
--
-- Los clientes siguen pudiendo ejecutar únicamente sus propias
-- automatizaciones.
--
-- Los workers necesitan explícitamente:
--     automations.execute
--
-- Esto evita que current_user_is_worker() sea suficiente para
-- ejecutar automatizaciones.
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_automation_run(
    p_automation_id uuid
)
RETURNS public.automation_runs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_automation public.automations;
    v_run public.automation_runs;

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;


    -- ========================================================
    -- 2. CUENTA ACTIVA
    -- ========================================================

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'Acceso denegado: la cuenta no está activa';
    END IF;


    -- ========================================================
    -- 3. COMPROBAR QUE EXISTE LA AUTOMATIZACIÓN
    -- ========================================================

    SELECT *
    INTO v_automation
    FROM public.automations
    WHERE id = p_automation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La automatización indicada no existe';
    END IF;


    -- ========================================================
    -- 4. AUTORIZACIÓN
    -- ========================================================
    --
    -- Worker:
    --     necesita explícitamente automations.execute.
    --
    -- Cliente:
    --     solamente puede crear ejecuciones de una
    --     automatización cuyo propietario sea él mismo.
    --

    IF public.current_user_is_worker() THEN

        IF NOT public.current_worker_has_permission(
            'automations.execute'
        ) THEN
            RAISE EXCEPTION
                'Acceso denegado: se requiere el permiso automations.execute';
        END IF;

    ELSIF v_automation.user_id <> auth.uid() THEN

        RAISE EXCEPTION
            'Acceso denegado';

    END IF;


    -- ========================================================
    -- 5. CREAR EJECUCIÓN
    -- ========================================================

    INSERT INTO public.automation_runs (
        automation_id,
        company_id,
        estado,
        inicio
    )
    VALUES (
        v_automation.id,
        v_automation.company_id,
        'pendiente',
        CURRENT_TIMESTAMP
    )
    RETURNING *
    INTO v_run;


    RETURN v_run;

END;

$function$;


-- ============================================================
-- VERIFICACIÓN BÁSICA
-- ============================================================

DO $$
DECLARE
    v_definition text;
BEGIN

    SELECT pg_get_functiondef(
        'public.create_automation_run(uuid)'::regprocedure
    )
    INTO v_definition;

    IF position(
        'current_worker_has_permission' IN v_definition
    ) = 0
    OR position(
        'automations.execute' IN v_definition
    ) = 0 THEN

        RAISE EXCEPTION
            'Hardening de create_automation_run() no verificado';

    END IF;

END;
$$;


COMMIT;