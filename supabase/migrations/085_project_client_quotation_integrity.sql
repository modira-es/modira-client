-- ============================================================
-- 085_project_client_quotation_integrity.sql
--
-- OBJETIVO
--
-- 1. Sincronizar projects.client_id con el cliente asociado
--    al propietario del proyecto.
--
-- 2. Corregir proyectos existentes que tengan:
--
--       projects.client_id IS NULL
--
--    cuando exista una relación inequívoca:
--
--       projects.user_id
--            ↓
--       clients.profile_id
--
-- 3. Mantener la relación automáticamente en nuevos proyectos
--    y cambios de propietario.
--
-- 4. Mantener la integridad empresa / propietario / cliente.
--
-- 5. Mantener la regla de 059:
--
--       quotation.project_id
--              ↓
--       project.client_id
--              ↓
--       quotation.client_id
--
-- 6. La empresa puede visualizar todos los presupuestos de sus
--    proyectos, mientras que la respuesta contractual queda
--    reservada al propietario del proyecto.
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    IF to_regclass('public.projects') IS NULL THEN
        RAISE EXCEPTION
            '085 stopped: public.projects no existe';
    END IF;


    IF to_regclass('public.clients') IS NULL THEN
        RAISE EXCEPTION
            '085 stopped: public.clients no existe';
    END IF;


    IF to_regclass('public.profiles') IS NULL THEN
        RAISE EXCEPTION
            '085 stopped: public.profiles no existe';
    END IF;


    IF to_regclass('public.quotations') IS NULL THEN
        RAISE EXCEPTION
            '085 stopped: public.quotations no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'user_id'
    ) THEN
        RAISE EXCEPTION
            '085 stopped: projects.user_id no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'client_id'
    ) THEN
        RAISE EXCEPTION
            '085 stopped: projects.client_id no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'company_id'
    ) THEN
        RAISE EXCEPTION
            '085 stopped: projects.company_id no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'profile_id'
    ) THEN
        RAISE EXCEPTION
            '085 stopped: clients.profile_id no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'company_id'
    ) THEN
        RAISE EXCEPTION
            '085 stopped: clients.company_id no existe';
    END IF;

END;
$$;


-- ============================================================
-- 2. CORREGIR PROYECTOS EXISTENTES
-- ============================================================
--
-- Un proyecto cuyo propietario es:
--
--     projects.user_id
--
-- debe utilizar como cliente:
--
--     clients.profile_id = projects.user_id
--
-- y además el cliente debe pertenecer a la misma empresa.
--
-- Solo se actualizan relaciones inequívocas.
--
-- ============================================================
UPDATE public.projects p
SET
    client_id = matches.client_id,
    updated_at = CURRENT_TIMESTAMP
FROM (
    SELECT
        p2.id AS project_id,
        c.id AS client_id
    FROM public.projects p2
    JOIN public.clients c
      ON c.profile_id = p2.user_id
     AND c.company_id = p2.company_id
    WHERE (
        SELECT COUNT(*)
        FROM public.clients c2
        WHERE c2.profile_id = p2.user_id
          AND c2.company_id = p2.company_id
    ) = 1
) matches
WHERE p.id = matches.project_id;


-- ============================================================
-- 3. FUNCIÓN — SINCRONIZAR CLIENTE DEL PROYECTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_project_client_from_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_client_id UUID;
    v_client_count INTEGER;

BEGIN

    -- --------------------------------------------------------
    -- Si no hay propietario todavía, no podemos determinar
    -- el cliente.
    -- --------------------------------------------------------

    IF NEW.user_id IS NULL THEN
        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- El propietario debe pertenecer a la empresa.
    --
    -- Esto queda además protegido por 084.
    -- --------------------------------------------------------

    IF NEW.company_id IS NULL THEN
        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- Buscar el cliente correspondiente al perfil propietario.
    -- --------------------------------------------------------

   SELECT
    COUNT(*)
INTO
    v_client_count
FROM public.clients c
WHERE c.profile_id = NEW.user_id
  AND c.company_id = NEW.company_id;


IF v_client_count = 1 THEN

    SELECT c.id
    INTO v_client_id
    FROM public.clients c
    WHERE c.profile_id = NEW.user_id
      AND c.company_id = NEW.company_id
    LIMIT 1;

    NEW.client_id := v_client_id;

    RETURN NEW;

END IF;


    -- --------------------------------------------------------
    -- Si existe exactamente un cliente correspondiente,
    -- utilizarlo.
    -- --------------------------------------------------------

 


    -- --------------------------------------------------------
    -- Si no existe cliente correspondiente:
    --
    -- No inventamos un client_id.
    --
    -- El proyecto puede existir, pero un presupuesto Pendiente
    -- será rechazado por la protección 059 hasta que exista
    -- una relación cliente válida.
    -- --------------------------------------------------------

    IF v_client_count = 0 THEN

        NEW.client_id := NULL;

        RETURN NEW;

    END IF;


    -- --------------------------------------------------------
    -- Si existen varios clientes para el mismo perfil/empresa,
    -- la relación es ambigua y no debemos elegir uno al azar.
    -- --------------------------------------------------------

    RAISE EXCEPTION
        'El propietario del proyecto tiene varios clientes asociados dentro de la misma empresa';


END;
$function$;


-- ============================================================
-- 4. TRIGGER — SINCRONIZAR PROYECTO / CLIENTE
-- ============================================================

DROP TRIGGER IF EXISTS
projects_sync_client_from_owner
ON public.projects;


CREATE TRIGGER
projects_sync_client_from_owner
BEFORE INSERT OR UPDATE OF user_id, company_id
ON public.projects
FOR EACH ROW
EXECUTE FUNCTION public.sync_project_client_from_owner();


-- ============================================================
-- 5. PROTEGER LA RELACIÓN CLIENTE / EMPRESA
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_project_client_company()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_client_company UUID;
    v_client_profile UUID;

BEGIN

    -- Un proyecto puede existir sin cliente mientras no se
    -- publique un presupuesto Pendiente.
    IF NEW.client_id IS NULL THEN
        RETURN NEW;
    END IF;


    SELECT
        c.company_id,
        c.profile_id
    INTO
        v_client_company,
        v_client_profile
    FROM public.clients c
    WHERE c.id = NEW.client_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El cliente asociado al proyecto no existe';
    END IF;


    -- El cliente debe pertenecer a la empresa del proyecto.

    IF NEW.company_id IS NOT NULL
       AND v_client_company IS DISTINCT FROM NEW.company_id
    THEN
        RAISE EXCEPTION
            'El cliente del proyecto debe pertenecer a la empresa del proyecto';
    END IF;


    -- El cliente debe corresponder al propietario del proyecto.

    IF NEW.user_id IS NOT NULL
       AND v_client_profile IS DISTINCT FROM NEW.user_id
    THEN
        RAISE EXCEPTION
            'El cliente del proyecto debe corresponder al propietario del proyecto';
    END IF;


    RETURN NEW;

END;
$function$;


-- ============================================================
-- 6. TRIGGER — PROTEGER CLIENTE DEL PROYECTO
-- ============================================================

DROP TRIGGER IF EXISTS
projects_validate_client_company
ON public.projects;


CREATE TRIGGER
projects_validate_client_company
BEFORE INSERT OR UPDATE OF user_id, company_id, client_id
ON public.projects
FOR EACH ROW
EXECUTE FUNCTION public.validate_project_client_company();


-- ============================================================
-- 7. PROTECCIÓN DE RESPUESTA DEL PRESUPUESTO
-- ============================================================
--
-- Toda la empresa puede VER el presupuesto gracias a 080.
--
-- Pero solamente el propietario del proyecto puede realizar
-- la transición:
--
--      Pendiente → Aceptado
--      Pendiente → Rechazado
--
-- Los workers siguen pudiendo hacerlo mediante su flujo
-- autorizado.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_quotation_project_owner_response()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_project_owner UUID;

BEGIN

    -- --------------------------------------------------------
    -- Solo nos interesa responder un presupuesto.
    -- --------------------------------------------------------

    IF LOWER(TRIM(COALESCE(OLD.estado, ''))) <> 'pendiente'
       OR LOWER(TRIM(COALESCE(NEW.estado, ''))) NOT IN (
            'aceptado',
            'rechazado'
       )
    THEN
        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- Los workers mantienen su autorización existente.
    -- --------------------------------------------------------

    IF public.current_user_is_worker() THEN
        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- Usuario autenticado.
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- Obtener propietario actual del proyecto.
    -- --------------------------------------------------------

    SELECT p.user_id
    INTO v_project_owner
    FROM public.projects p
    WHERE p.id = NEW.project_id;


    IF v_project_owner IS NULL THEN
        RAISE EXCEPTION
            'El presupuesto no tiene un propietario de proyecto válido';
    END IF;


    -- --------------------------------------------------------
    -- SOLO EL PROPIETARIO DEL PROYECTO
    -- --------------------------------------------------------

    IF v_project_owner IS DISTINCT FROM auth.uid() THEN

        RAISE EXCEPTION
            'Solo el propietario del proyecto puede responder a este presupuesto';

    END IF;


    RETURN NEW;

END;
$function$;


-- ============================================================
-- 8. TRIGGER — PROTEGER RESPUESTA
-- ============================================================

DROP TRIGGER IF EXISTS
quotations_project_owner_response
ON public.quotations;


CREATE TRIGGER
quotations_project_owner_response
BEFORE UPDATE OF estado
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.protect_quotation_project_owner_response();


-- ============================================================
-- 9. COMPROBACIÓN FINAL
-- ============================================================

DO $$
DECLARE
    v_invalid INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_invalid
    FROM public.projects p
    JOIN public.clients c
      ON c.id = p.client_id
    WHERE p.client_id IS NOT NULL
      AND (
          c.company_id IS DISTINCT FROM p.company_id
          OR c.profile_id IS DISTINCT FROM p.user_id
      );


    IF v_invalid > 0 THEN

        RAISE EXCEPTION
            '085 failed: existen % proyectos con relación propietario/cliente/empresa inconsistente',
            v_invalid;

    END IF;

END;
$$;


COMMIT;