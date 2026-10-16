-- ============================================================
-- MODIRA 072
-- MANTENIMIENTO MULTICONTRATO POR PROYECTO
-- + RATE LIMIT DE CONTRATACIONES
-- ============================================================

BEGIN;

-- ============================================================
-- 1. VALIDACIÓN CONTRATO ↔ PROYECTO
-- ============================================================
--
-- Una empresa puede tener múltiples contratos de mantenimiento.
--
-- Cada proyecto, sin embargo, solo puede pertenecer a UN contrato
-- de mantenimiento activo.
--
-- Ejemplo permitido:
--
--   Empresa
--     ├── Proyecto A → Essential
--     └── Proyecto B → Business
--
-- Ejemplo NO permitido:
--
--   Proyecto A
--     ├── Essential
--     └── Business
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_maintenance_contract_project()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_contract_company_id UUID;
    v_project_company_id UUID;
    v_contract_status TEXT;
BEGIN

    -- --------------------------------------------------------
    -- El contrato debe existir
    -- --------------------------------------------------------

    SELECT
        mc.company_id,
        mc.estado
    INTO
        v_contract_company_id,
        v_contract_status
    FROM public.maintenance_contracts mc
    WHERE mc.id = NEW.maintenance_contract_id;

    IF v_contract_company_id IS NULL THEN
        RAISE EXCEPTION
            'El contrato de mantenimiento no existe.';
    END IF;


    -- --------------------------------------------------------
    -- El proyecto debe existir y pertenecer a la misma empresa
    -- --------------------------------------------------------

    SELECT p.company_id
    INTO v_project_company_id
    FROM public.projects p
    WHERE p.id = NEW.project_id;

    IF v_project_company_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto de mantenimiento no existe.';
    END IF;


    IF v_project_company_id IS DISTINCT FROM v_contract_company_id THEN
        RAISE EXCEPTION
            'El proyecto no pertenece a la misma empresa que el contrato.';
    END IF;


    -- --------------------------------------------------------
    -- Un proyecto no puede tener dos contratos ACTIVOS
    -- --------------------------------------------------------

    IF LOWER(COALESCE(v_contract_status, '')) = 'activo' THEN

        IF EXISTS (
            SELECT 1
            FROM public.maintenance_contract_projects mcp
            JOIN public.maintenance_contracts mc
              ON mc.id = mcp.maintenance_contract_id
            WHERE mcp.project_id = NEW.project_id
              AND mc.estado = 'activo'
              AND mc.id <> NEW.maintenance_contract_id
        ) THEN

            RAISE EXCEPTION
                'El proyecto ya tiene otro contrato de mantenimiento activo.';
        END IF;

    END IF;


    RETURN NEW;
END;
$$;


REVOKE ALL
ON FUNCTION public.validate_maintenance_contract_project()
FROM PUBLIC, anon, authenticated;


DROP TRIGGER IF EXISTS validate_maintenance_contract_project
ON public.maintenance_contract_projects;


CREATE TRIGGER validate_maintenance_contract_project
BEFORE INSERT OR UPDATE
ON public.maintenance_contract_projects
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_contract_project();


-- ============================================================
-- 2. PROTECCIÓN ADICIONAL AL ACTIVAR UN CONTRATO
-- ============================================================
--
-- Evita que alguien pueda:
--
--   contrato A = pausado
--   proyecto X = asociado a A
--
-- y después activar:
--
--   contrato B = proyecto X
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_maintenance_contract_activation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    IF LOWER(COALESCE(NEW.estado, '')) = 'activo'
       AND LOWER(COALESCE(OLD.estado, '')) IS DISTINCT FROM 'activo'
    THEN

        IF EXISTS (
            SELECT 1
            FROM public.maintenance_contract_projects mcp
            JOIN public.maintenance_contracts other_mc
              ON other_mc.id = mcp.maintenance_contract_id
            WHERE mcp.maintenance_contract_id = NEW.id
              AND other_mc.id <> NEW.id
              AND other_mc.estado = 'activo'
        ) THEN
            RAISE EXCEPTION
                'No se puede activar el contrato porque alguno de sus proyectos ya tiene otro contrato activo.';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM public.maintenance_contract_projects mcp
            JOIN public.maintenance_contract_projects other_mcp
              ON other_mcp.project_id = mcp.project_id
             AND other_mcp.maintenance_contract_id <> mcp.maintenance_contract_id
            JOIN public.maintenance_contracts other_mc
              ON other_mc.id = other_mcp.maintenance_contract_id
            WHERE mcp.maintenance_contract_id = NEW.id
              AND other_mc.estado = 'activo'
        ) THEN
            RAISE EXCEPTION
                'No se puede activar el contrato porque uno de sus proyectos ya está cubierto por otro contrato activo.';
        END IF;

    END IF;

    RETURN NEW;
END;
$$;


REVOKE ALL
ON FUNCTION public.validate_maintenance_contract_activation()
FROM PUBLIC, anon, authenticated;


DROP TRIGGER IF EXISTS validate_maintenance_contract_activation
ON public.maintenance_contracts;


CREATE TRIGGER validate_maintenance_contract_activation
BEFORE UPDATE OF estado
ON public.maintenance_contracts
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_contract_activation();


-- ============================================================
-- 3. RATE LIMIT DE CONTRATACIONES
-- ============================================================
--
-- 4 contrataciones / empresa / 24 horas.
--
-- Se reutiliza:
--
--   public.security_rate_limits
--   public.enforce_security_rate_limit(...)
--
-- Esta función SOLO debe poder ejecutarla service_role.
--
-- La Edge Function maintenance-stripe la utilizará antes de
-- crear una nueva sesión de Stripe.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.consume_maintenance_contract_checkout_rate_limit(
    p_company_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rate_key TEXT;
BEGIN

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION
            'company_id es obligatorio para aplicar el rate limit.';
    END IF;


    v_rate_key :=
        'maintenance:contract_checkout:' || p_company_id::TEXT;


    PERFORM public.enforce_security_rate_limit(
        v_rate_key,
        4,
        86400
    );

END;
$$;


REVOKE ALL
ON FUNCTION public.consume_maintenance_contract_checkout_rate_limit(UUID)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.consume_maintenance_contract_checkout_rate_limit(UUID)
TO service_role;


COMMENT ON FUNCTION public.consume_maintenance_contract_checkout_rate_limit(UUID)
IS
'Rate limit interno para contrataciones de mantenimiento: máximo 4 intentos de contratación por empresa cada 24 horas. Solo service_role.';


-- ============================================================
-- 4. VERIFICACIONES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Trigger proyecto ↔ contrato

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.maintenance_contract_projects'::regclass
      AND tgname = 'validate_maintenance_contract_project'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '072 failed: validate_maintenance_contract_project trigger missing';
    END IF;


    -- Trigger activación

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.maintenance_contracts'::regclass
      AND tgname = 'validate_maintenance_contract_activation'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '072 failed: validate_maintenance_contract_activation trigger missing';
    END IF;


    -- Rate limit function

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'consume_maintenance_contract_checkout_rate_limit'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_company_id uuid';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '072 failed: maintenance checkout rate limit function missing';
    END IF;


    -- SECURITY DEFINER

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'consume_maintenance_contract_checkout_rate_limit'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '072 failed: rate limit function must be SECURITY DEFINER';
    END IF;

END;
$$;

GRANT SELECT
ON TABLE public.projects
TO service_role;
COMMIT;