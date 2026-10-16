BEGIN;

-- ============================================================
-- MODIRA — RATE LIMIT CLIENT PROFILE + FISCAL CHANGE REQUESTS
-- ============================================================
--
-- OBJETIVO
--
-- 1. Limitar cambios reales de nombre/teléfono en profiles:
--      7 cambios / usuario / 1 hora
--
-- 2. Limitar solicitudes de cambio de datos fiscales:
--      3 solicitudes / empresa / 24 horas
--
-- IMPORTANTE
--
-- - Reutiliza public.security_rate_limits.
-- - Reutiliza public.enforce_security_rate_limit().
-- - No crea una nueva tabla de rate limiting.
-- - No modifica RLS.
-- - No modifica permisos de tablas.
-- - No modifica la lógica de negocio de la RPC fiscal.
-- - Los workers quedan excluidos.
-- - No se limitan lecturas.
-- - El cambio de perfil solo cuenta si nombre o telefono
--   realmente han cambiado.
-- - La solicitud fiscal se limita por empresa, no por usuario.
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'security_rate_limits'
  ) THEN
    RAISE EXCEPTION
      'Rate limit migration stopped: security_rate_limits does not exist';
  END IF;


  -- ----------------------------------------------------------
  -- Comprobar que existe la función de rate limiting con la
  -- firma correcta:
  --
  --   text
  --   integer
  --   integer
  --
  -- No se comprueban los nombres de los parámetros para evitar
  -- depender de cómo estén nombrados en PostgreSQL.
  -- ----------------------------------------------------------

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'enforce_security_rate_limit'
      AND p.pronargs = 3
      AND p.proargtypes[0] = 'text'::regtype::oid
      AND p.proargtypes[1] = 'integer'::regtype::oid
      AND p.proargtypes[2] = 'integer'::regtype::oid
  ) THEN
    RAISE EXCEPTION
      'Rate limit migration stopped: enforce_security_rate_limit(text, integer, integer) does not exist';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'profiles'
  ) THEN
    RAISE EXCEPTION
      'Rate limit migration stopped: profiles does not exist';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'company_fiscal_change_requests'
  ) THEN
    RAISE EXCEPTION
      'Rate limit migration stopped: company_fiscal_change_requests does not exist';
  END IF;

END;
$$;


-- ============================================================
-- 2. RATE LIMIT PARA CAMBIOS DE PERFIL
-- ============================================================
--
-- Solo cuenta cambios reales de:
--
--   nombre
--   telefono
--
-- Límite:
--
--   7 cambios / usuario / 1 hora
--
-- Los workers quedan excluidos.
--
-- La clave queda aislada por usuario:
--
--   profiles:update:<auth.uid>
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.rate_limit_profile_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID;
  v_rate_key TEXT;
BEGIN

  v_user_id := auth.uid();


  -- ----------------------------------------------------------
  -- Sin sesión autenticada:
  -- no aplicar este límite.
  --
  -- La autorización/RLS existente continúa siendo la encargada
  -- de impedir actualizaciones no autorizadas.
  -- ----------------------------------------------------------

  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;


  -- ----------------------------------------------------------
  -- Los workers utilizan sus propios mecanismos internos.
  -- No consumir el rate limit de clientes.
  -- ----------------------------------------------------------

  IF public.current_user_is_worker() THEN
    RETURN NEW;
  END IF;


  -- ----------------------------------------------------------
  -- Solo contar cambios reales de los campos que el cliente
  -- puede modificar.
  --
  -- Un UPDATE que envíe el mismo nombre/teléfono no consume
  -- una operación.
  -- ----------------------------------------------------------

  IF NEW.nombre IS NOT DISTINCT FROM OLD.nombre
     AND NEW.telefono IS NOT DISTINCT FROM OLD.telefono
  THEN
    RETURN NEW;
  END IF;


  -- ----------------------------------------------------------
  -- 7 cambios por usuario cada 1 hora.
  -- ----------------------------------------------------------

  v_rate_key :=
    'profiles:update:' || v_user_id::TEXT;

  PERFORM public.enforce_security_rate_limit(
    v_rate_key,
    7,
    3600
  );


  RETURN NEW;

END;
$$;


-- ------------------------------------------------------------
-- Seguridad de la función
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.rate_limit_profile_update()
FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- Trigger
--
-- BEFORE UPDATE:
-- el rate limit se ejecuta antes de aceptar el cambio.
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS profiles_rate_limit_update
ON public.profiles;

CREATE TRIGGER profiles_rate_limit_update
BEFORE UPDATE
ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.rate_limit_profile_update();


-- ============================================================
-- 3. RATE LIMIT PARA SOLICITUDES FISCALES
-- ============================================================
--
-- La operación afecta a la EMPRESA.
--
-- Por eso la clave NO es auth.uid().
--
-- Es:
--
--   company_fiscal_change:<company_id>
--
-- Límite:
--
--   3 solicitudes / empresa / 24 horas
--
-- Los workers quedan excluidos.
--
-- La protección se ejecuta como trigger sobre el INSERT.
--
-- Esto significa que:
--
--   request_company_fiscal_change()
--             ↓
--        validaciones
--             ↓
--          INSERT
--             ↓
--      BEFORE INSERT trigger
--             ↓
--        rate limit
--             ↓
--          INSERT
--
-- No necesitamos duplicar la lógica de la RPC.
-- ============================================================

CREATE OR REPLACE FUNCTION public.rate_limit_company_fiscal_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID;
  v_rate_key TEXT;
BEGIN

  v_user_id := auth.uid();


  -- ----------------------------------------------------------
  -- Sin autenticación no aplicar el contador.
  --
  -- La tabla ya no concede INSERT directo a authenticated,
  -- y la RPC exige auth.uid().
  -- ----------------------------------------------------------

  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;


  -- ----------------------------------------------------------
  -- Los workers utilizan la operación interna.
  -- No consumir el límite de clientes.
  -- ----------------------------------------------------------

  IF public.current_user_is_worker() THEN
    RETURN NEW;
  END IF;


  -- ----------------------------------------------------------
  -- company_id es obligatorio en la tabla.
  --
  -- Si por algún motivo llegase NULL, dejamos que la propia
  -- integridad de la tabla/RPC gestione el error.
  -- No creamos una clave artificial.
  -- ----------------------------------------------------------

  IF NEW.company_id IS NULL THEN
    RETURN NEW;
  END IF;


  -- ----------------------------------------------------------
  -- Rate limit POR EMPRESA:
  --
  -- 3 solicitudes cada 24 horas.
  -- ----------------------------------------------------------

  v_rate_key :=
    'company_fiscal_change:' || NEW.company_id::TEXT;

  PERFORM public.enforce_security_rate_limit(
    v_rate_key,
    3,
    86400
  );


  RETURN NEW;

END;
$$;


-- ------------------------------------------------------------
-- Seguridad de la función
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.rate_limit_company_fiscal_change()
FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- Trigger
--
-- Solo INSERT.
--
-- Las actualizaciones administrativas de una solicitud fiscal
-- no consumen el límite.
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS company_fiscal_change_rate_limit
ON public.company_fiscal_change_requests;

CREATE TRIGGER company_fiscal_change_rate_limit
BEFORE INSERT
ON public.company_fiscal_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.rate_limit_company_fiscal_change();


-- ============================================================
-- 4. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN

  -- ----------------------------------------------------------
  -- profiles trigger
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_count
  FROM pg_trigger
  WHERE tgrelid = 'public.profiles'::regclass
    AND tgname = 'profiles_rate_limit_update'
    AND NOT tgisinternal;

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      'Rate limit migration failed: profiles_rate_limit_update trigger missing';
  END IF;


  -- ----------------------------------------------------------
  -- fiscal trigger
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_count
  FROM pg_trigger
  WHERE tgrelid =
        'public.company_fiscal_change_requests'::regclass
    AND tgname = 'company_fiscal_change_rate_limit'
    AND NOT tgisinternal;

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      'Rate limit migration failed: company_fiscal_change_rate_limit trigger missing';
  END IF;


  -- ----------------------------------------------------------
  -- profile trigger function
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n
    ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'rate_limit_profile_update'
    AND pg_get_function_identity_arguments(p.oid) = '';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      'Rate limit migration failed: rate_limit_profile_update missing';
  END IF;


  -- ----------------------------------------------------------
  -- fiscal trigger function
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n
    ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'rate_limit_company_fiscal_change'
    AND pg_get_function_identity_arguments(p.oid) = '';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      'Rate limit migration failed: rate_limit_company_fiscal_change missing';
  END IF;


  -- ----------------------------------------------------------
  -- SECURITY DEFINER
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n
    ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'rate_limit_profile_update',
      'rate_limit_company_fiscal_change'
    )
    AND p.prosecdef = TRUE;

  IF v_count <> 2 THEN
    RAISE EXCEPTION
      'Rate limit migration failed: trigger functions must be SECURITY DEFINER';
  END IF;

END;
$$;


COMMIT;