BEGIN;

-- 132_project_status_worker_only.sql
-- Solo trabajadores activos pueden cambiar projects.estado.
-- Los clientes únicamente pueden insertar proyectos en estado Pendiente.
-- Se conserva la política de UPDATE de clientes para los demás campos.

DO $precheck$
BEGIN
    IF to_regclass('public.projects') IS NULL THEN
        RAISE EXCEPTION 'No existe la tabla public.projects.';
    END IF;

    IF to_regprocedure('public.current_user_is_worker()') IS NULL THEN
        RAISE EXCEPTION 'No existe la función public.current_user_is_worker().';
    END IF;

    IF to_regprocedure('public.current_user_is_active()') IS NULL THEN
        RAISE EXCEPTION 'No existe la función public.current_user_is_active().';
    END IF;

    IF to_regprocedure('public.current_user_company_id()') IS NULL THEN
        RAISE EXCEPTION 'No existe la función public.current_user_company_id().';
    END IF;
END;
$precheck$;

CREATE OR REPLACE FUNCTION public.enforce_project_status_worker_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
BEGIN
    -- Los trabajadores activos pueden gestionar el estado.
    IF COALESCE(public.current_user_is_worker(), false) THEN
        RETURN NEW;
    END IF;

    -- Un cliente no puede crear un proyecto en un estado distinto de Pendiente.
    IF TG_OP = 'INSERT' THEN
        IF NEW.estado IS DISTINCT FROM 'Pendiente' THEN
            RAISE EXCEPTION
                'Solo un trabajador puede crear un proyecto en un estado distinto de Pendiente.'
                USING ERRCODE = '42501';
        END IF;

        RETURN NEW;
    END IF;

    -- Un cliente puede modificar otros campos si RLS lo permite,
    -- pero nunca cambiar el estado del proyecto.
    IF OLD.estado IS DISTINCT FROM NEW.estado THEN
        RAISE EXCEPTION
            'Solo un trabajador activo puede cambiar el estado del proyecto.'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS enforce_project_status_worker_only
ON public.projects;

CREATE TRIGGER enforce_project_status_worker_only
BEFORE INSERT OR UPDATE OF estado
ON public.projects
FOR EACH ROW
EXECUTE FUNCTION public.enforce_project_status_worker_only();

-- Defensa adicional mediante RLS: las inserciones directas de clientes
-- solo pueden crear proyectos en estado Pendiente.
DROP POLICY IF EXISTS projects_insert_policy
ON public.projects;

CREATE POLICY projects_insert_policy
ON public.projects
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
    AND (
        (
            public.current_user_company_id() IS NOT NULL
            AND company_id = public.current_user_company_id()
        )
        OR
        (
            public.current_user_company_id() IS NULL
            AND company_id IS NULL
        )
    )
    AND estado = 'Pendiente'
);

-- Verificaciones finales para que la migración falle si no quedó instalada.
DO $verify$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'projects'
          AND t.tgname = 'enforce_project_status_worker_only'
          AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'No se ha creado el trigger de protección de estado.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'projects'
          AND policyname = 'projects_insert_policy'
          AND cmd = 'INSERT'
    ) THEN
        RAISE EXCEPTION 'No se ha recreado projects_insert_policy.';
    END IF;
END;
$verify$;

COMMIT;
