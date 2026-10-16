BEGIN;

-- ============================================================
-- 064 — FLUJO UNIFICADO DE CAMBIO DE EMPRESA + FISCALIDAD
-- ============================================================
--
-- OBJETIVO
--
-- Unificar en company_change_requests:
--   - cambio de empresa / razón social
--   - NIF/CIF/VAT
--   - datos fiscales
--   - motivo
--   - decisión sobre traslado de proyectos
--
-- company_fiscal_change_requests deja de existir.
--
-- REGLAS DE PROYECTOS
--   - Solo Pendiente / Activo / Pausado pueden trasladarse.
--   - Un proyecto que tenga AL MENOS una factura normal NO se traslada.
--   - Entregado / Completado nunca se trasladan.
--   - La comprobación de facturas se realiza también en la aprobación,
--     no solo al crear la solicitud.
--   - Las facturas existentes no se modifican.
--
-- REGLAS DE EMPRESA DESTINO
--   - Una empresa existente solo se reutiliza si no tiene perfiles,
--     proyectos ni facturas.
--   - Una empresa existente con historial NO se modifica fiscalmente.
--   - Si no existe una empresa reutilizable, se crea una nueva.
--
-- COMPATIBILIDAD
--   - Se conserva request_company_change(TEXT).
--   - Se conserva request_company_change_with_projects(TEXT, BOOLEAN)
--     como wrappers de compatibilidad.
--   - El nuevo frontend puede usar la sobrecarga unificada de
--     request_company_change_with_projects(...) con datos fiscales.
--
-- ============================================================

-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN
  IF to_regclass('public.company_change_requests') IS NULL THEN
    RAISE EXCEPTION
      '064 stopped: public.company_change_requests no existe';
  END IF;

  IF to_regclass('public.companies') IS NULL THEN
    RAISE EXCEPTION
      '064 stopped: public.companies no existe';
  END IF;

  IF to_regclass('public.profiles') IS NULL THEN
    RAISE EXCEPTION
      '064 stopped: public.profiles no existe';
  END IF;

  IF to_regclass('public.projects') IS NULL THEN
    RAISE EXCEPTION
      '064 stopped: public.projects no existe';
  END IF;

  IF to_regclass('public.invoices') IS NULL THEN
    RAISE EXCEPTION
      '064 stopped: public.invoices no existe';
  END IF;

  IF to_regclass('public.security_rate_limits') IS NULL THEN
    RAISE EXCEPTION
      '064 stopped: public.security_rate_limits no existe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'enforce_security_rate_limit'
      AND p.pronargs = 3
      AND p.proargtypes[0] = 'text'::regtype::oid
      AND p.proargtypes[1] = 'integer'::regtype::oid
      AND p.proargtypes[2] = 'integer'::regtype::oid
  ) THEN
    RAISE EXCEPTION
      '064 stopped: enforce_security_rate_limit(text, integer, integer) no existe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_user_is_worker'
      AND p.pronargs = 0
  ) THEN
    RAISE EXCEPTION
      '064 stopped: current_user_is_worker() no existe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_user_is_active'
      AND p.pronargs = 0
  ) THEN
    RAISE EXCEPTION
      '064 stopped: current_user_is_active() no existe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'log_activity'
  ) THEN
    RAISE EXCEPTION
      '064 stopped: log_activity() no existe';
  END IF;
END;
$$;

-- ============================================================
-- 2. CAMPOS FISCALES EN company_change_requests
-- ============================================================

ALTER TABLE public.company_change_requests
  ADD COLUMN IF NOT EXISTS current_company_name TEXT,
  ADD COLUMN IF NOT EXISTS current_legal_name TEXT,
  ADD COLUMN IF NOT EXISTS current_cif_vat TEXT,
  ADD COLUMN IF NOT EXISTS current_billing_email TEXT,
  ADD COLUMN IF NOT EXISTS current_address TEXT,
  ADD COLUMN IF NOT EXISTS current_postal_code TEXT,
  ADD COLUMN IF NOT EXISTS current_city TEXT,
  ADD COLUMN IF NOT EXISTS current_province TEXT,
  ADD COLUMN IF NOT EXISTS current_country TEXT,
  ADD COLUMN IF NOT EXISTS requested_legal_name TEXT,
  ADD COLUMN IF NOT EXISTS requested_cif_vat TEXT,
  ADD COLUMN IF NOT EXISTS requested_billing_email TEXT,
  ADD COLUMN IF NOT EXISTS requested_address TEXT,
  ADD COLUMN IF NOT EXISTS requested_postal_code TEXT,
  ADD COLUMN IF NOT EXISTS requested_city TEXT,
  ADD COLUMN IF NOT EXISTS requested_province TEXT,
  ADD COLUMN IF NOT EXISTS requested_country TEXT;

COMMENT ON COLUMN public.company_change_requests.current_company_name IS
  'Nombre de empresa vigente en el momento de crear la solicitud.';
COMMENT ON COLUMN public.company_change_requests.current_legal_name IS
  'Razón social vigente en el momento de crear la solicitud.';
COMMENT ON COLUMN public.company_change_requests.current_cif_vat IS
  'NIF/CIF/VAT vigente en el momento de crear la solicitud.';
COMMENT ON COLUMN public.company_change_requests.requested_company_name IS
  'Nombre de empresa solicitado para la nueva identidad.';
COMMENT ON COLUMN public.company_change_requests.requested_legal_name IS
  'Razón social solicitada para la nueva identidad.';
COMMENT ON COLUMN public.company_change_requests.requested_cif_vat IS
  'NIF/CIF/VAT solicitado para la nueva identidad.';
COMMENT ON COLUMN public.company_change_requests.apply_to_active_projects IS
  'Si es TRUE, al aprobar se intentan trasladar proyectos Pendiente, Activo o Pausado sin facturas normales. Entregado, Completado y cualquier proyecto con factura no se trasladan.';

-- ============================================================
-- 3. TRIGGER DE updated_at
-- ============================================================

DROP TRIGGER IF EXISTS company_change_requests_updated_at
ON public.company_change_requests;

CREATE TRIGGER company_change_requests_updated_at
BEFORE UPDATE ON public.company_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================
-- 4. RATE LIMIT UNIFICADO
--    3 solicitudes / empresa / 24 horas
-- ============================================================

CREATE OR REPLACE FUNCTION public.rate_limit_company_change_request()
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

  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.current_user_is_worker() THEN
    RETURN NEW;
  END IF;

  IF NEW.current_company_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_rate_key :=
    'company_change:' || NEW.current_company_id::TEXT;

  PERFORM public.enforce_security_rate_limit(
    v_rate_key,
    3,
    86400
  );

  RETURN NEW;
END;
$$;

REVOKE ALL
ON FUNCTION public.rate_limit_company_change_request()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS security_rate_limit_company_change_requests
ON public.company_change_requests;

DROP TRIGGER IF EXISTS company_change_requests_rate_limit
ON public.company_change_requests;

DROP TRIGGER IF EXISTS company_change_unified_rate_limit
ON public.company_change_requests;

CREATE TRIGGER company_change_unified_rate_limit
BEFORE INSERT ON public.company_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.rate_limit_company_change_request();

-- ============================================================
-- 5. RPC PRINCIPAL UNIFICADA
--
-- Misma lógica de request_company_change_with_projects, pero ahora
-- recibe también toda la identidad fiscal.
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_company_change_with_projects(
  p_requested_company_name TEXT,
  p_legal_name TEXT,
  p_cif_vat TEXT,
  p_billing_email TEXT DEFAULT NULL,
  p_address TEXT DEFAULT NULL,
  p_postal_code TEXT DEFAULT NULL,
  p_city TEXT DEFAULT NULL,
  p_province TEXT DEFAULT NULL,
  p_country TEXT DEFAULT 'ES',
  p_reason TEXT DEFAULT NULL,
  p_apply_to_active_projects BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id UUID;
  v_current_company_id UUID;
  v_requested_company_id UUID;
  v_request_id UUID;
  v_requested_company_name TEXT;
  v_legal_name TEXT;
  v_cif_vat TEXT;
  v_billing_email TEXT;
  v_address TEXT;
  v_postal_code TEXT;
  v_city TEXT;
  v_province TEXT;
  v_country TEXT;
  v_reason TEXT;
  v_current_company public.companies;
  v_has_movable_projects BOOLEAN := FALSE;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION
      'Debes iniciar sesión para solicitar un cambio de empresa.';
  END IF;

  IF public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Las cuentas de trabajadores no pueden solicitar cambio de empresa.';
  END IF;

  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION
      'La cuenta no está activa.';
  END IF;

  v_requested_company_name := NULLIF(BTRIM(p_requested_company_name), '');
  v_legal_name := NULLIF(BTRIM(p_legal_name), '');
  v_cif_vat := NULLIF(UPPER(BTRIM(p_cif_vat)), '');
  v_billing_email := NULLIF(BTRIM(p_billing_email), '');
  v_address := NULLIF(BTRIM(p_address), '');
  v_postal_code := NULLIF(BTRIM(p_postal_code), '');
  v_city := NULLIF(BTRIM(p_city), '');
  v_province := NULLIF(BTRIM(p_province), '');
  v_country := UPPER(NULLIF(BTRIM(COALESCE(p_country, 'ES')), ''));
  v_reason := NULLIF(BTRIM(p_reason), '');

  IF v_requested_company_name IS NULL
     OR LENGTH(v_requested_company_name) > 200 THEN
    RAISE EXCEPTION
      'El nombre de la empresa es obligatorio y no puede superar 200 caracteres.';
  END IF;

  IF v_legal_name IS NULL OR LENGTH(v_legal_name) > 300 THEN
    RAISE EXCEPTION
      'La razón social es obligatoria y no puede superar 300 caracteres.';
  END IF;

  IF v_cif_vat IS NULL OR LENGTH(v_cif_vat) > 100 THEN
    RAISE EXCEPTION
      'El NIF/CIF/VAT es obligatorio y no puede superar 100 caracteres.';
  END IF;

  IF v_address IS NULL OR LENGTH(v_address) > 500 THEN
    RAISE EXCEPTION
      'La dirección fiscal es obligatoria.';
  END IF;

  IF v_postal_code IS NULL OR LENGTH(v_postal_code) > 30 THEN
    RAISE EXCEPTION
      'El código postal es obligatorio.';
  END IF;

  IF v_city IS NULL OR LENGTH(v_city) > 200 THEN
    RAISE EXCEPTION
      'La ciudad es obligatoria.';
  END IF;

  IF v_province IS NOT NULL AND LENGTH(v_province) > 200 THEN
    RAISE EXCEPTION
      'La provincia no puede superar 200 caracteres.';
  END IF;

  IF v_country IS NULL OR v_country !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION
      'El país debe ser un código ISO de dos letras.';
  END IF;

  IF v_billing_email IS NOT NULL AND LENGTH(v_billing_email) > 320 THEN
    RAISE EXCEPTION
      'El email de facturación no puede superar 320 caracteres.';
  END IF;

  IF v_reason IS NOT NULL AND LENGTH(v_reason) > 1000 THEN
    RAISE EXCEPTION
      'El motivo no puede superar 1000 caracteres.';
  END IF;

  SELECT p.company_id
  INTO v_current_company_id
  FROM public.profiles p
  WHERE p.id = v_user_id
    AND p.status = 'active';

  IF v_current_company_id IS NULL THEN
    RAISE EXCEPTION
      'El usuario no tiene una empresa asociada.';
  END IF;

  SELECT *
  INTO v_current_company
  FROM public.companies c
  WHERE c.id = v_current_company_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'La empresa actual no existe.';
  END IF;

  IF LOWER(BTRIM(v_requested_company_name)) =
       LOWER(BTRIM(COALESCE(v_current_company.company_name, '')))
     AND COALESCE(NULLIF(BTRIM(v_current_company.legal_name), ''), NULL)
       IS NOT DISTINCT FROM v_legal_name
     AND COALESCE(NULLIF(BTRIM(v_current_company.cif_vat), ''), NULL)
       IS NOT DISTINCT FROM v_cif_vat
     AND COALESCE(NULLIF(BTRIM(v_current_company.billing_email), ''), NULL)
       IS NOT DISTINCT FROM v_billing_email
     AND COALESCE(NULLIF(BTRIM(v_current_company.address), ''), NULL)
       IS NOT DISTINCT FROM v_address
     AND COALESCE(NULLIF(BTRIM(v_current_company.postal_code), ''), NULL)
       IS NOT DISTINCT FROM v_postal_code
     AND COALESCE(NULLIF(BTRIM(v_current_company.city), ''), NULL)
       IS NOT DISTINCT FROM v_city
     AND COALESCE(NULLIF(BTRIM(v_current_company.province), ''), NULL)
       IS NOT DISTINCT FROM v_province
     AND COALESCE(UPPER(NULLIF(BTRIM(v_current_company.country), '')), 'ES')
       IS NOT DISTINCT FROM v_country
  THEN
    RAISE EXCEPTION
      'No se ha detectado ningún cambio en los datos de empresa o fiscales.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.company_change_requests r
    WHERE r.user_id = v_user_id
      AND r.status = 'pending'
  ) THEN
    RAISE EXCEPTION
      'Ya tienes una solicitud de cambio de empresa pendiente.';
  END IF;

  -- Solo guardamos como destino una empresa que sea completamente
  -- reutilizable. Una empresa con historial no se reutiliza.
  SELECT c.id
  INTO v_requested_company_id
  FROM public.companies c
  WHERE c.is_active = TRUE
    AND LOWER(BTRIM(c.company_name)) =
        LOWER(v_requested_company_name)
    AND c.id <> v_current_company_id
    AND c.cif_vat IS NOT DISTINCT FROM v_cif_vat
    AND NOT EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.company_id = c.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.projects p
      WHERE p.company_id = c.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.invoices i
      WHERE i.company_id = c.id
    )
  ORDER BY c.created_at ASC
  LIMIT 1;

  SELECT EXISTS (
    SELECT 1
    FROM public.projects p
    WHERE p.user_id = v_user_id
      AND p.estado IN ('Pendiente', 'Activo', 'Pausado')
      AND NOT EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE i.project_id = p.id
      )
  )
  INTO v_has_movable_projects;

  IF NOT v_has_movable_projects THEN
    p_apply_to_active_projects := FALSE;
  END IF;

  INSERT INTO public.company_change_requests (
    user_id,
    current_company_id,
    requested_company_id,
    requested_company_name,
    reason,
    status,
    apply_to_active_projects,
    current_company_name,
    current_legal_name,
    current_cif_vat,
    current_billing_email,
    current_address,
    current_postal_code,
    current_city,
    current_province,
    current_country,
    requested_legal_name,
    requested_cif_vat,
    requested_billing_email,
    requested_address,
    requested_postal_code,
    requested_city,
    requested_province,
    requested_country
  )
  VALUES (
    v_user_id,
    v_current_company_id,
    v_requested_company_id,
    v_requested_company_name,
    v_reason,
    'pending',
    COALESCE(p_apply_to_active_projects, FALSE),
    v_current_company.company_name,
    v_current_company.legal_name,
    v_current_company.cif_vat,
    v_current_company.billing_email,
    v_current_company.address,
    v_current_company.postal_code,
    v_current_company.city,
    v_current_company.province,
    v_current_company.country,
    v_legal_name,
    v_cif_vat,
    v_billing_email,
    v_address,
    v_postal_code,
    v_city,
    v_province,
    v_country
  )
  RETURNING id INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE ALL
ON FUNCTION public.request_company_change_with_projects(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.request_company_change_with_projects(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN
)
TO authenticated;

-- ============================================================
-- 6. WRAPPER DE COMPATIBILIDAD: 2 ARGUMENTOS
-- ============================================================
--
-- Mantiene funcionando temporalmente el frontend antiguo. Captura
-- los datos fiscales actuales, por lo que no permite saltarse el
-- nuevo flujo unificado.
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_company_change_with_projects(
  p_requested_company_name TEXT,
  p_apply_to_active_projects BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_company public.companies;
  v_company_id UUID;
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión para solicitar un cambio de empresa.';
  END IF;

  SELECT p.company_id
  INTO v_company_id
  FROM public.profiles p
  WHERE p.id = v_user_id
    AND p.status = 'active';

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'El usuario no tiene una empresa asociada.';
  END IF;

  SELECT *
  INTO v_company
  FROM public.companies
  WHERE id = v_company_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La empresa actual no existe.';
  END IF;

  -- El wrapper solo puede reutilizarse cuando la empresa actual ya
  -- dispone de todos los datos fiscales obligatorios. Si no los tiene,
  -- el cliente debe utilizar la nueva RPC unificada enviando los datos
  -- fiscales explícitamente. Nunca inventamos un NIF o una dirección.
  IF NULLIF(BTRIM(COALESCE(v_company.legal_name, '')), '') IS NULL
     OR NULLIF(BTRIM(COALESCE(v_company.cif_vat, '')), '') IS NULL
     OR NULLIF(BTRIM(COALESCE(v_company.address, '')), '') IS NULL
     OR NULLIF(BTRIM(COALESCE(v_company.postal_code, '')), '') IS NULL
     OR NULLIF(BTRIM(COALESCE(v_company.city, '')), '') IS NULL
  THEN
    RAISE EXCEPTION
      'Esta operación requiere utilizar el nuevo flujo unificado de cambio de empresa con los datos fiscales completos.';
  END IF;

  RETURN public.request_company_change_with_projects(
    p_requested_company_name,
    v_company.legal_name,
    v_company.cif_vat,
    v_company.billing_email,
    v_company.address,
    v_company.postal_code,
    v_company.city,
    v_company.province,
    COALESCE(v_company.country, 'ES'),
    NULL,
    p_apply_to_active_projects
  );
END;
$$;

REVOKE ALL
ON FUNCTION public.request_company_change_with_projects(TEXT, BOOLEAN)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.request_company_change_with_projects(TEXT, BOOLEAN)
TO authenticated;

-- ============================================================
-- 7. WRAPPER DE COMPATIBILIDAD: request_company_change(TEXT)
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_company_change(
  p_requested_company_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.request_company_change_with_projects(
    p_requested_company_name,
    FALSE
  );
END;
$$;

REVOKE ALL
ON FUNCTION public.request_company_change(TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.request_company_change(TEXT)
TO authenticated;

-- ============================================================
-- 8. RESOLUCIÓN UNIFICADA
-- ============================================================

CREATE OR REPLACE FUNCTION public.resolve_company_change_request(
  p_request_id UUID,
  p_action TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_request public.company_change_requests%ROWTYPE;
  v_target_company_id UUID;
  v_target_company_name TEXT;
  v_target_legal_name TEXT;
  v_company_code TEXT;
  v_worker_id UUID;
  v_moved_projects INTEGER := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado.';
  END IF;

  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'No tienes permisos para gestionar solicitudes de cambio de empresa.';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'La solicitud es obligatoria.';
  END IF;

  IF p_action NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'La acción debe ser approved o rejected.';
  END IF;

  SELECT *
  INTO v_request
  FROM public.company_change_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud indicada no existe.';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'La solicitud ya ha sido gestionada.';
  END IF;

  SELECT w.id
  INTO v_worker_id
  FROM public.workers w
  WHERE w.auth_user_id = auth.uid()
  LIMIT 1;

  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION
      'No se ha podido identificar al trabajador que gestiona la solicitud.';
  END IF;

  -- ----------------------------------------------------------
  -- RECHAZO
  -- ----------------------------------------------------------
  IF p_action = 'rejected' THEN
    UPDATE public.company_change_requests
    SET
      status = 'rejected',
      reviewed_by = v_worker_id,
      reviewed_at = CURRENT_TIMESTAMP,
      updated_at = CURRENT_TIMESTAMP
    WHERE id = p_request_id;

    PERFORM public.log_activity(
      'company_change_rejected',
      'company_change_request',
      v_request.id,
      'El trabajador ha rechazado una solicitud unificada de cambio de empresa y datos fiscales.',
      jsonb_build_object(
        'user_id', v_request.user_id,
        'previous_company_id', v_request.current_company_id
      )
    );

    RETURN TRUE;
  END IF;

  -- ----------------------------------------------------------
  -- VALIDAR SNAPSHOT SOLICITADO
  -- ----------------------------------------------------------
  v_target_company_name := NULLIF(BTRIM(v_request.requested_company_name), '');
  v_target_legal_name := NULLIF(BTRIM(v_request.requested_legal_name), '');

  IF v_target_company_name IS NULL THEN
    RAISE EXCEPTION
      'La solicitud no contiene un nombre de empresa válido.';
  END IF;

  IF v_target_legal_name IS NULL
     OR v_request.requested_cif_vat IS NULL
     OR v_request.requested_address IS NULL
     OR v_request.requested_postal_code IS NULL
     OR v_request.requested_city IS NULL
     OR v_request.requested_country IS NULL THEN
    RAISE EXCEPTION
      'La solicitud no contiene todos los datos fiscales obligatorios.';
  END IF;

  -- ----------------------------------------------------------
  -- DETERMINAR EMPRESA DESTINO
  --
  -- Solo se reutiliza una empresa completamente vacía de historial.
  -- Si tiene perfil, proyecto o factura, NO se modifica.
  -- ----------------------------------------------------------

  v_target_company_id := NULL;

  IF v_request.requested_company_id IS NOT NULL THEN
    SELECT c.id
    INTO v_target_company_id
    FROM public.companies c
    WHERE c.id = v_request.requested_company_id
      AND c.is_active = TRUE
      AND c.id <> v_request.current_company_id
      AND c.cif_vat IS NOT DISTINCT FROM v_request.requested_cif_vat
      AND NOT EXISTS (
        SELECT 1 FROM public.profiles p
        WHERE p.company_id = c.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.projects p
        WHERE p.company_id = c.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.invoices i
        WHERE i.company_id = c.id
      );
  END IF;

  IF v_target_company_id IS NULL THEN
    SELECT c.id
    INTO v_target_company_id
    FROM public.companies c
    WHERE c.is_active = TRUE
      AND c.id <> v_request.current_company_id
      AND LOWER(BTRIM(c.company_name)) =
          LOWER(BTRIM(v_target_company_name))
      AND c.cif_vat IS NOT DISTINCT FROM v_request.requested_cif_vat
      AND NOT EXISTS (
        SELECT 1 FROM public.profiles p
        WHERE p.company_id = c.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.projects p
        WHERE p.company_id = c.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.invoices i
        WHERE i.company_id = c.id
      )
    ORDER BY c.created_at ASC
    LIMIT 1;
  END IF;

  -- ----------------------------------------------------------
  -- CREAR NUEVA EMPRESA SI NO HAY DESTINO REUTILIZABLE
  -- ----------------------------------------------------------

  IF v_target_company_id IS NULL THEN
    v_company_code :=
      'CLI-' ||
      UPPER(REPLACE(gen_random_uuid()::TEXT, '-', ''));

    INSERT INTO public.companies (
      company_code,
      company_name,
      legal_name,
      cif_vat,
      billing_email,
      address,
      postal_code,
      city,
      province,
      country,
      created_by,
      is_active
    )
    VALUES (
      v_company_code,
      v_target_company_name,
      v_target_legal_name,
      UPPER(BTRIM(v_request.requested_cif_vat)),
      NULLIF(BTRIM(v_request.requested_billing_email), ''),
      NULLIF(BTRIM(v_request.requested_address), ''),
      NULLIF(BTRIM(v_request.requested_postal_code), ''),
      NULLIF(BTRIM(v_request.requested_city), ''),
      NULLIF(BTRIM(v_request.requested_province), ''),
      UPPER(BTRIM(v_request.requested_country)),
      v_request.user_id,
      TRUE
    )
    RETURNING id
    INTO v_target_company_id;
  ELSE
    -- Empresa totalmente vacía: es seguro completar su identidad.
    UPDATE public.companies
    SET
      company_name = v_target_company_name,
      legal_name = v_target_legal_name,
      cif_vat = UPPER(BTRIM(v_request.requested_cif_vat)),
      billing_email = NULLIF(BTRIM(v_request.requested_billing_email), ''),
      address = NULLIF(BTRIM(v_request.requested_address), ''),
      postal_code = NULLIF(BTRIM(v_request.requested_postal_code), ''),
      city = NULLIF(BTRIM(v_request.requested_city), ''),
      province = NULLIF(BTRIM(v_request.requested_province), ''),
      country = UPPER(BTRIM(v_request.requested_country)),
      updated_at = CURRENT_TIMESTAMP
    WHERE id = v_target_company_id;
  END IF;

  -- ----------------------------------------------------------
  -- CONFIRMAR DESTINO
  -- ----------------------------------------------------------

  SELECT c.company_name
  INTO v_target_company_name
  FROM public.companies c
  WHERE c.id = v_target_company_id
    AND c.is_active = TRUE;

  IF v_target_company_name IS NULL THEN
    RAISE EXCEPTION
      'La empresa destino no existe o está inactiva.';
  END IF;

  -- ----------------------------------------------------------
  -- ACTUALIZAR PERFIL
  -- ----------------------------------------------------------

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

  -- ----------------------------------------------------------
  -- TRASLADAR SOLO PROYECTOS ELEGIBLES
  -- ----------------------------------------------------------
  --
  -- La comprobación de invoices se realiza aquí otra vez porque una
  -- factura puede haberse creado después de presentar la solicitud.
  --
  -- No se exige company_id = current_company_id: un usuario puede
  -- conservar proyectos históricos asociados a empresas anteriores.
  --
  IF COALESCE(v_request.apply_to_active_projects, FALSE) THEN
    UPDATE public.projects p
    SET
      company_id = v_target_company_id,
      updated_at = CURRENT_TIMESTAMP
    WHERE p.user_id = v_request.user_id
      AND p.estado IN ('Pendiente', 'Activo', 'Pausado')
      AND NOT EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE i.project_id = p.id
      );

    GET DIAGNOSTICS v_moved_projects = ROW_COUNT;
  END IF;

  -- ----------------------------------------------------------
  -- CERRAR SOLICITUD
  -- ----------------------------------------------------------

  UPDATE public.company_change_requests
  SET
    requested_company_id = v_target_company_id,
    requested_company_name = v_target_company_name,
    status = 'approved',
    reviewed_by = v_worker_id,
    reviewed_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_request_id;

  PERFORM public.log_activity(
    'company_change_approved',
    'company_change_request',
    v_request.id,
    CASE
      WHEN COALESCE(v_request.apply_to_active_projects, FALSE)
      THEN
        'El trabajador ha aprobado el cambio unificado de empresa y datos fiscales. Se han trasladado únicamente los proyectos elegibles sin facturas normales.'
      ELSE
        'El trabajador ha aprobado el cambio unificado de empresa y datos fiscales sin trasladar los proyectos.'
    END,
    jsonb_build_object(
      'user_id', v_request.user_id,
      'previous_company_id', v_request.current_company_id,
      'new_company_id', v_target_company_id,
      'apply_to_active_projects',
        COALESCE(v_request.apply_to_active_projects, FALSE),
      'moved_projects_count',
        v_moved_projects,
      'invoice_history_preserved', TRUE
    )
  );

  RETURN TRUE;
END;
$$;

REVOKE ALL
ON FUNCTION public.resolve_company_change_request(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.resolve_company_change_request(UUID, TEXT)
TO authenticated;

-- ============================================================
-- 9. RLS — company_change_requests
-- ============================================================

ALTER TABLE public.company_change_requests
ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS company_change_requests_client_select
ON public.company_change_requests;

CREATE POLICY company_change_requests_client_select
ON public.company_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND user_id = auth.uid()
);

DROP POLICY IF EXISTS company_change_requests_client_insert
ON public.company_change_requests;

-- No INSERT directo del cliente. La creación se realiza mediante RPC.

DROP POLICY IF EXISTS company_change_requests_worker_select
ON public.company_change_requests;

CREATE POLICY company_change_requests_worker_select
ON public.company_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
);

DROP POLICY IF EXISTS company_change_requests_worker_update
ON public.company_change_requests;

DROP POLICY IF EXISTS company_change_requests_worker_delete
ON public.company_change_requests;

REVOKE ALL
ON public.company_change_requests
FROM anon, authenticated;

GRANT SELECT
ON public.company_change_requests
TO authenticated;

-- ============================================================
-- 10. ELIMINAR EL FLUJO FISCAL ANTIGUO
-- ============================================================

DROP TRIGGER IF EXISTS company_fiscal_change_rate_limit
ON public.company_fiscal_change_requests;

DROP TRIGGER IF EXISTS company_fiscal_change_requests_updated_at
ON public.company_fiscal_change_requests;

DROP FUNCTION IF EXISTS public.request_company_fiscal_change(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
);

DROP FUNCTION IF EXISTS public.review_company_fiscal_change(
  UUID, TEXT, TEXT
);

DROP FUNCTION IF EXISTS public.update_company_fiscal_data_by_worker(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
);

DROP FUNCTION IF EXISTS public.rate_limit_company_fiscal_change();

DROP TABLE IF EXISTS public.company_fiscal_change_requests;

-- ============================================================
-- 11. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
  v_column_type TEXT;
BEGIN
  -- Tabla fiscal antigua eliminada.
  IF to_regclass('public.company_fiscal_change_requests') IS NOT NULL THEN
    RAISE EXCEPTION
      '064 failed: company_fiscal_change_requests sigue existiendo';
  END IF;

  -- Funciones fiscales antiguas eliminadas.
  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'request_company_fiscal_change',
      'review_company_fiscal_change',
      'update_company_fiscal_data_by_worker',
      'rate_limit_company_fiscal_change'
    );

  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '064 failed: siguen existiendo funciones del flujo fiscal antiguo';
  END IF;

  -- Rate limit unificado.
  SELECT COUNT(*)
  INTO v_count
  FROM pg_trigger
  WHERE tgrelid = 'public.company_change_requests'::regclass
    AND tgname = 'company_change_unified_rate_limit'
    AND NOT tgisinternal;

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '064 failed: trigger company_change_unified_rate_limit no existe';
  END IF;

  -- Campo de alcance de proyectos.
  SELECT c.data_type
  INTO v_column_type
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'company_change_requests'
    AND c.column_name = 'apply_to_active_projects';

  IF v_column_type <> 'boolean' THEN
    RAISE EXCEPTION
      '064 failed: apply_to_active_projects no es BOOLEAN';
  END IF;

  -- Campos unificados mínimos.
  FOREACH v_column_type IN ARRAY ARRAY[
    'current_company_name',
    'current_legal_name',
    'current_cif_vat',
    'current_billing_email',
    'current_address',
    'current_postal_code',
    'current_city',
    'current_province',
    'current_country',
    'requested_legal_name',
    'requested_cif_vat',
    'requested_billing_email',
    'requested_address',
    'requested_postal_code',
    'requested_city',
    'requested_province',
    'requested_country'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = 'company_change_requests'
        AND c.column_name = v_column_type
    ) THEN
      RAISE EXCEPTION
        '064 failed: falta company_change_requests.%', v_column_type;
    END IF;
  END LOOP;

  -- RPC principal unificada.
  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'request_company_change_with_projects'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_requested_company_name text, p_legal_name text, p_cif_vat text, p_billing_email text, p_address text, p_postal_code text, p_city text, p_province text, p_country text, p_reason text, p_apply_to_active_projects boolean';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '064 failed: RPC unificada request_company_change_with_projects(...) no existe correctamente';
  END IF;

  -- Wrapper de compatibilidad de 2 argumentos.
  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'request_company_change_with_projects'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_requested_company_name text, p_apply_to_active_projects boolean';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '064 failed: wrapper request_company_change_with_projects(TEXT, BOOLEAN) no existe';
  END IF;

  -- Resolver.
  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'resolve_company_change_request'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_request_id uuid, p_action text';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '064 failed: resolve_company_change_request(UUID, TEXT) no existe';
  END IF;

  -- No deben quedar referencias a la tabla fiscal antigua en funciones.
  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND pg_get_functiondef(p.oid) ILIKE '%company_fiscal_change_requests%';

  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '064 failed: existen funciones públicas que todavía referencian company_fiscal_change_requests';
  END IF;
END;
$$;

COMMIT;





BEGIN;

-- ============================================================
-- 1. ELIMINAR LAS DOS VERSIONES ACTUALES DE LA RPC
-- ============================================================

DROP FUNCTION IF EXISTS public.request_company_change_with_projects(
    TEXT,
    BOOLEAN
);

DROP FUNCTION IF EXISTS public.request_company_change_with_projects(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN
);


-- ============================================================
-- 2. ASEGURAR LAS COLUMNAS FISCALES DE LA SOLICITUD
-- ============================================================

ALTER TABLE public.company_change_requests
    ADD COLUMN IF NOT EXISTS requested_legal_name TEXT;

ALTER TABLE public.company_change_requests
    ADD COLUMN IF NOT EXISTS requested_cif_vat TEXT;

ALTER TABLE public.company_change_requests
    ADD COLUMN IF NOT EXISTS requested_billing_email TEXT;

ALTER TABLE public.company_change_requests
    ADD COLUMN IF NOT EXISTS requested_address TEXT;

ALTER TABLE public.company_change_requests
    ADD COLUMN IF NOT EXISTS requested_postal_code TEXT;

ALTER TABLE public.company_change_requests
    ADD COLUMN IF NOT EXISTS requested_city TEXT;

ALTER TABLE public.company_change_requests
    ADD COLUMN IF NOT EXISTS requested_province TEXT;

ALTER TABLE public.company_change_requests
    ADD COLUMN IF NOT EXISTS requested_country TEXT;


-- ============================================================
-- 3. NUEVA RPC UNIFICADA
--
-- IMPORTANTE:
-- Los nombres de los parámetros coinciden EXACTAMENTE
-- con los que utiliza ClientArea.tsx
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_company_change_with_projects(
    p_requested_company_name TEXT,
    p_requested_legal_name TEXT,
    p_requested_cif_vat TEXT,
    p_requested_billing_email TEXT,
    p_requested_address TEXT,
    p_requested_postal_code TEXT,
    p_requested_city TEXT,
    p_requested_province TEXT,
    p_requested_country TEXT,
    p_reason TEXT,
    p_apply_to_active_projects BOOLEAN
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_user_id UUID;
    v_current_company_id UUID;
    v_requested_company_id UUID;
    v_request_id UUID;

    v_requested_company_name TEXT;
    v_legal_name TEXT;
    v_cif_vat TEXT;
    v_billing_email TEXT;
    v_address TEXT;
    v_postal_code TEXT;
    v_city TEXT;
    v_province TEXT;
    v_country TEXT;
    v_reason TEXT;

    v_apply_to_active_projects BOOLEAN := COALESCE(
        p_apply_to_active_projects,
        FALSE
    );

    v_has_movable_projects BOOLEAN := FALSE;

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión para solicitar un cambio de empresa.';
    END IF;


    -- ========================================================
    -- 2. LOS WORKERS NO UTILIZAN ESTE FLUJO
    -- ========================================================

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Las cuentas de trabajadores no pueden solicitar cambio de empresa.';
    END IF;


    -- ========================================================
    -- 3. COMPROBAR PERFIL ACTIVO
    -- ========================================================

    SELECT p.company_id
    INTO v_current_company_id
    FROM public.profiles p
    WHERE p.id = v_user_id
      AND p.status = 'active'
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No se encontró un perfil activo para el usuario.';
    END IF;


    -- ========================================================
    -- 4. NORMALIZAR DATOS
    -- ========================================================

    v_requested_company_name :=
        NULLIF(BTRIM(p_requested_company_name), '');

    v_legal_name :=
        NULLIF(BTRIM(p_requested_legal_name), '');

    v_cif_vat :=
        UPPER(NULLIF(BTRIM(p_requested_cif_vat), ''));

    v_billing_email :=
        LOWER(NULLIF(BTRIM(p_requested_billing_email), ''));

    v_address :=
        NULLIF(BTRIM(p_requested_address), '');

    v_postal_code :=
        NULLIF(BTRIM(p_requested_postal_code), '');

    v_city :=
        NULLIF(BTRIM(p_requested_city), '');

    v_province :=
        NULLIF(BTRIM(p_requested_province), '');

    v_country :=
        UPPER(NULLIF(BTRIM(p_requested_country), ''));

    v_reason :=
        NULLIF(BTRIM(p_reason), '');


    -- ========================================================
    -- 5. VALIDACIONES
    -- ========================================================

    IF v_requested_company_name IS NULL THEN
        RAISE EXCEPTION
            'El nombre de empresa es obligatorio.';
    END IF;

    IF LENGTH(v_requested_company_name) > 200 THEN
        RAISE EXCEPTION
            'El nombre de empresa no puede superar 200 caracteres.';
    END IF;

    IF v_legal_name IS NULL THEN
        RAISE EXCEPTION
            'La razón social es obligatoria.';
    END IF;

    IF LENGTH(v_legal_name) > 300 THEN
        RAISE EXCEPTION
            'La razón social no puede superar 300 caracteres.';
    END IF;

    IF v_cif_vat IS NULL THEN
        RAISE EXCEPTION
            'El NIF/CIF/VAT es obligatorio.';
    END IF;

    IF LENGTH(v_cif_vat) > 100 THEN
        RAISE EXCEPTION
            'El NIF/CIF/VAT no puede superar 100 caracteres.';
    END IF;

    IF v_address IS NULL THEN
        RAISE EXCEPTION
            'La dirección fiscal es obligatoria.';
    END IF;

    IF LENGTH(v_address) > 500 THEN
        RAISE EXCEPTION
            'La dirección fiscal no puede superar 500 caracteres.';
    END IF;

    IF v_postal_code IS NULL THEN
        RAISE EXCEPTION
            'El código postal es obligatorio.';
    END IF;

    IF LENGTH(v_postal_code) > 30 THEN
        RAISE EXCEPTION
            'El código postal no puede superar 30 caracteres.';
    END IF;

    IF v_city IS NULL THEN
        RAISE EXCEPTION
            'La ciudad es obligatoria.';
    END IF;

    IF LENGTH(v_city) > 200 THEN
        RAISE EXCEPTION
            'La ciudad no puede superar 200 caracteres.';
    END IF;

    IF v_country IS NULL OR v_country !~ '^[A-Z]{2}$' THEN
        RAISE EXCEPTION
            'El país debe indicarse mediante un código ISO de dos letras.';
    END IF;

    IF v_billing_email IS NOT NULL
       AND LENGTH(v_billing_email) > 320 THEN
        RAISE EXCEPTION
            'El email de facturación no puede superar 320 caracteres.';
    END IF;

    IF v_reason IS NOT NULL
       AND LENGTH(v_reason) > 1000 THEN
        RAISE EXCEPTION
            'El motivo no puede superar 1000 caracteres.';
    END IF;


    -- ========================================================
    -- 6. COMPROBAR QUE NO SEA LA MISMA EMPRESA
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.companies c
        WHERE c.id = v_current_company_id
          AND LOWER(BTRIM(c.company_name))
              = LOWER(v_requested_company_name)
    ) THEN
        RAISE EXCEPTION
            'La empresa solicitada coincide con la empresa actual.';
    END IF;


    -- ========================================================
    -- 7. BUSCAR EMPRESA DESTINO SI YA EXISTE
    -- ========================================================

    SELECT c.id
    INTO v_requested_company_id
    FROM public.companies c
    WHERE c.is_active = TRUE
      AND LOWER(BTRIM(c.company_name))
          = LOWER(v_requested_company_name)
    ORDER BY c.created_at
    LIMIT 1;


    -- ========================================================
    -- 8. UNA SOLA SOLICITUD PENDIENTE
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.company_change_requests r
        WHERE r.user_id = v_user_id
          AND r.status = 'pending'
    ) THEN
        RAISE EXCEPTION
            'Ya tienes una solicitud de cambio de empresa pendiente.';
    END IF;


    -- ========================================================
    -- 9. COMPROBAR PROYECTOS REALMENTE TRASLADABLES
    --
    -- Solo:
    --   Pendiente
    --   Activo
    --   Pausado
    --
    -- Y además:
    --   pertenecen al usuario;
    --   pertenecen a su empresa actual;
    --   NO tienen ninguna factura normal asociada.
    --
    -- Esto permite cambiar de empresa en proyectos antiguos
    -- siempre que nunca hayan tenido una factura.
    -- ========================================================

    SELECT EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.user_id = v_user_id
          AND p.company_id = v_current_company_id
          AND p.estado IN (
              'Pendiente',
              'Activo',
              'Pausado'
          )
          AND NOT EXISTS (
              SELECT 1
              FROM public.invoices i
              WHERE i.project_id = p.id
          )
    )
    INTO v_has_movable_projects;


    -- ========================================================
    -- 10. SI NO HAY PROYECTOS TRASLADABLES,
    --     NO SE GUARDA LA OPCIÓN COMO TRUE
    -- ========================================================

    IF NOT v_has_movable_projects THEN
        v_apply_to_active_projects := FALSE;
    END IF;


    -- ========================================================
    -- 11. CREAR SOLICITUD
    -- ========================================================

    INSERT INTO public.company_change_requests (
        user_id,
        current_company_id,
        requested_company_id,
        requested_company_name,

        requested_legal_name,
        requested_cif_vat,
        requested_billing_email,
        requested_address,
        requested_postal_code,
        requested_city,
        requested_province,
        requested_country,

        reason,
        apply_to_active_projects,
        status
    )
    VALUES (
        v_user_id,
        v_current_company_id,
        v_requested_company_id,
        v_requested_company_name,

        v_legal_name,
        v_cif_vat,
        v_billing_email,
        v_address,
        v_postal_code,
        v_city,
        v_province,
        v_country,

        v_reason,
        v_apply_to_active_projects,
        'pending'
    )
    RETURNING id
    INTO v_request_id;


    -- ========================================================
    -- 12. DEVOLVER ID REAL DE LA SOLICITUD
    -- ========================================================

    RETURN v_request_id;

END;
$function$;


-- ============================================================
-- 4. PERMISOS DE LA RPC
-- ============================================================

REVOKE ALL
ON FUNCTION public.request_company_change_with_projects(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.request_company_change_with_projects(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN
)
TO authenticated;


-- ============================================================
-- 5. RECARGAR EL SCHEMA CACHE DE POSTGREST
-- ============================================================

NOTIFY pgrst, 'reload schema';


COMMIT;