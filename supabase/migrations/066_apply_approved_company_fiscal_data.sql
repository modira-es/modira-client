-- ============================================================
-- MODIRA — 066_apply_approved_company_fiscal_data.sql
-- ============================================================
--
-- OBJETIVO
--
-- Aplicar a public.companies los datos fiscales solicitados por
-- un cliente únicamente cuando su solicitud de cambio de empresa
-- haya sido aprobada por un worker.
--
-- IMPORTANTE
--
-- - NO modifica la migración 065.
-- - NO redefine resolve_company_change_request().
-- - NO modifica profiles.
-- - NO modifica projects.
-- - NO modifica invoices.
-- - NO modifica datos fiscales históricos de facturas.
-- - NO modifica los valores requested_* de la solicitud.
-- - NO muestra datos pendientes como datos actuales.
--
-- Flujo:
--
--   company_change_requests
--          pending
--             |
--             | worker aprueba
--             v
--          approved
--             |
--             v
--       companies.*
--
-- Los campos requested_* permanecen como registro histórico
-- de lo que solicitó originalmente el cliente.
-- ============================================================


BEGIN;


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- Tabla companies
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'companies'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: public.companies does not exist';
    END IF;


    -- --------------------------------------------------------
    -- Tabla company_change_requests
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: public.company_change_requests does not exist';
    END IF;


    -- --------------------------------------------------------
    -- profiles
    --
    -- Se utiliza para obtener la empresa actual del usuario
    -- cuando requested_company_id sea NULL.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'profiles'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: public.profiles does not exist';
    END IF;


    -- --------------------------------------------------------
    -- Columnas fiscales solicitadas
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
          AND column_name = 'requested_legal_name'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: requested_legal_name is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
          AND column_name = 'requested_cif_vat'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: requested_cif_vat is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
          AND column_name = 'requested_billing_email'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: requested_billing_email is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
          AND column_name = 'requested_address'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: requested_address is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
          AND column_name = 'requested_postal_code'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: requested_postal_code is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
          AND column_name = 'requested_city'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: requested_city is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
          AND column_name = 'requested_province'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: requested_province is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'company_change_requests'
          AND column_name = 'requested_country'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: requested_country is missing';
    END IF;


    -- --------------------------------------------------------
    -- Columnas fiscales actuales de companies
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'legal_name'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: companies.legal_name is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'cif_vat'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: companies.cif_vat is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'billing_email'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: companies.billing_email is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'address'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: companies.address is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'postal_code'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: companies.postal_code is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'city'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: companies.city is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'province'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: companies.province is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'country'
    ) THEN
        RAISE EXCEPTION
            '066 stopped: companies.country is missing';
    END IF;

END $$;


-- ============================================================
-- 2. FUNCIÓN — APLICAR DATOS FISCALES AL APROBAR
-- ============================================================
--
-- Esta función NO sustituye resolve_company_change_request().
--
-- Se ejecuta automáticamente mediante trigger cuando una
-- solicitud pasa de:
--
--     pending → approved
--
-- La empresa destino se obtiene primero desde
-- requested_company_id.
--
-- Si requested_company_id todavía es NULL, se obtiene desde
-- profiles.company_id, que ya habrá sido actualizado por el
-- flujo de aprobación de la 065.
-- ============================================================

CREATE OR REPLACE FUNCTION public.apply_approved_company_change_fiscal_data()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_target_company_id UUID;
    v_profile_company_id UUID;
BEGIN

    -- ========================================================
    -- 1. ESTE TRIGGER SOLO DEBE ACTUAR EN:
    --
    --    pending → approved
    -- ========================================================

    IF OLD.status IS DISTINCT FROM 'pending'
       OR NEW.status IS DISTINCT FROM 'approved'
    THEN
        RETURN NEW;
    END IF;


    -- ========================================================
    -- 2. SEGURIDAD
    --
    -- La aprobación debe proceder de un worker activo.
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            '066: no se puede aplicar un cambio fiscal sin usuario autenticado';
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            '066: solo un trabajador activo puede aprobar cambios fiscales';
    END IF;


    -- ========================================================
    -- 3. DETERMINAR EMPRESA DESTINO
    --
    -- Primera opción:
    --     requested_company_id
    --
    -- Si todavía es NULL:
    --     profiles.company_id
    --
    -- Esto permite funcionar tanto si la empresa destino
    -- ya existía como si la 065 acaba de crearla.
    -- ========================================================

    v_target_company_id := NEW.requested_company_id;


    IF v_target_company_id IS NULL THEN

        SELECT p.company_id
        INTO v_profile_company_id
        FROM public.profiles p
        WHERE p.id = NEW.user_id
        LIMIT 1;

        v_target_company_id := v_profile_company_id;

    END IF;


    -- ========================================================
    -- 4. LA EMPRESA DESTINO DEBE EXISTIR
    -- ========================================================

    IF v_target_company_id IS NULL THEN
        RAISE EXCEPTION
            '066: no se pudo determinar la empresa destino de la solicitud aprobada';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.companies c
        WHERE c.id = v_target_company_id
    ) THEN
        RAISE EXCEPTION
            '066: la empresa destino de la solicitud aprobada no existe';
    END IF;


    -- ========================================================
    -- 5. APLICAR LOS DATOS FISCALES APROBADOS
    --
    -- IMPORTANTE:
    --
    -- Aquí requested_* deja de ser únicamente una propuesta
    -- y pasa a convertirse en el estado actual de companies.
    --
    -- La solicitud NO se modifica.
    -- Solo se actualiza la empresa.
    -- ========================================================

    UPDATE public.companies
    SET
        legal_name = NEW.requested_legal_name,
        cif_vat = NEW.requested_cif_vat,
        billing_email = NEW.requested_billing_email,
        address = NEW.requested_address,
        postal_code = NEW.requested_postal_code,
        city = NEW.requested_city,
        province = NEW.requested_province,
        country = NEW.requested_country,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_target_company_id;


    -- ========================================================
    -- 6. DEVOLVER LA SOLICITUD SIN MODIFICARLA
    -- ========================================================

    RETURN NEW;

END;
$function$;


-- ============================================================
-- 3. SEGURIDAD DE LA FUNCIÓN
-- ============================================================
--
-- La función solo debe ejecutarse internamente mediante trigger.
-- No se expone como RPC.
-- ============================================================

REVOKE ALL
ON FUNCTION public.apply_approved_company_change_fiscal_data()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 4. TRIGGER
-- ============================================================
--
-- Se elimina únicamente el trigger de la 066 si existiera,
-- para que la migración sea repetible.
--
-- NO se toca ningún trigger creado por migraciones anteriores.
-- ============================================================

DROP TRIGGER IF EXISTS
    company_change_requests_apply_approved_fiscal_data
ON public.company_change_requests;


CREATE TRIGGER
    company_change_requests_apply_approved_fiscal_data
AFTER UPDATE OF status
ON public.company_change_requests
FOR EACH ROW
WHEN (
    OLD.status = 'pending'
    AND NEW.status = 'approved'
)
EXECUTE FUNCTION public.apply_approved_company_change_fiscal_data();


-- ============================================================
-- 5. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_function_count INTEGER;
    v_trigger_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Función
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_function_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'apply_approved_company_change_fiscal_data'
      AND pg_get_function_identity_arguments(p.oid) = '';

    IF v_function_count <> 1 THEN
        RAISE EXCEPTION
            '066 failed: función apply_approved_company_change_fiscal_data() missing';
    END IF;


    -- --------------------------------------------------------
    -- Trigger
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_trigger_count
    FROM pg_trigger
    WHERE tgrelid = 'public.company_change_requests'::regclass
      AND tgname = 'company_change_requests_apply_approved_fiscal_data'
      AND NOT tgisinternal;

    IF v_trigger_count <> 1 THEN
        RAISE EXCEPTION
            '066 failed: fiscal approval trigger missing';
    END IF;

END $$;


-- ============================================================
-- 6. COMMIT
-- ============================================================

COMMIT;