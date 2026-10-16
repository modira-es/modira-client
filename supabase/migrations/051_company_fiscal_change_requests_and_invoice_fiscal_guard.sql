-- ============================================================
-- MODIRA — 051_company_fiscal_change_requests_and_invoice_fiscal_guard.sql
-- ============================================================
-- OBJETIVO
-- 1. Permitir al CLIENTE proponer cambios en los datos fiscales de su empresa.
-- 2. Mantener los cambios de companies protegidos: el cliente NO obtiene
--    UPDATE directo sobre public.companies.
-- 3. Permitir al WORKER ACTIVO revisar y aprobar/rechazar solicitudes.
-- 4. Permitir al WORKER ACTIVO modificar directamente los datos fiscales
--    cuando Modira recibe la información por otro canal (correo, soporte,
--    documentación, etc.), dejando igualmente trazabilidad.
-- 5. Registrar en BD el estado anterior y el estado propuesto de cada cambio.
-- 6. Registrar quién solicitó/revisó/aplicó el cambio y cuándo.
-- 7. Registrar actividad mediante public.log_activity().
-- 8. Hacer que los datos fiscales completos sean requisito para EMITIR
--    una factura de mantenimiento.
-- 9. En el momento de emisión de una factura de mantenimiento, tomar los
--    datos fiscales actuales de companies y guardarlos en el snapshot fiscal
--    de maintenance_invoices.
-- 10. No imponer este requisito a quotations/presupuestos: un presupuesto
--     puede existir y circular antes de que se complete la información fiscal.
--
-- DECISIONES DE DISEÑO
-- - El cliente NO modifica companies directamente.
-- - El cliente crea una solicitud.
-- - El worker puede aprobar/rechazar la solicitud.
-- - El worker también puede aplicar un cambio directo mediante RPC; ese cambio
--   crea una solicitud ya aprobada para conservar la misma trazabilidad.
-- - No se crean nuevas tablas de facturas ni se modifica la arquitectura Stripe.
-- - Las facturas históricas no se reescriben.
-- - Este guard fiscal afecta a maintenance_invoices, que es el flujo fiscal
--   desarrollado en las migraciones 049/050.
-- ============================================================

BEGIN;

-- ============================================================
-- 0. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'companies'
  ) THEN
    RAISE EXCEPTION
      '051 stopped: public.companies does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
  ) THEN
    RAISE EXCEPTION
      '051 stopped: public.maintenance_invoices does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_user_company_id'
  ) THEN
    RAISE EXCEPTION
      '051 stopped: public.current_user_company_id() does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_user_is_active'
  ) THEN
    RAISE EXCEPTION
      '051 stopped: public.current_user_is_active() does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'current_user_is_worker'
  ) THEN
    RAISE EXCEPTION
      '051 stopped: public.current_user_is_worker() does not exist';
  END IF;

END $$;

-- ============================================================
-- 1. SOLICITUDES DE CAMBIO DE DATOS FISCALES
-- ============================================================

CREATE TABLE IF NOT EXISTS public.company_fiscal_change_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  company_id UUID NOT NULL
    REFERENCES public.companies(id)
    ON DELETE RESTRICT,

  requested_by UUID NOT NULL
    REFERENCES auth.users(id)
    ON DELETE RESTRICT,

  requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- Estado fiscal anterior en el momento de crear la solicitud.
  current_legal_name TEXT,
  current_cif_vat TEXT,
  current_billing_email TEXT,
  current_address TEXT,
  current_postal_code TEXT,
  current_city TEXT,
  current_province TEXT,
  current_country TEXT,

  -- Estado propuesto.
  requested_legal_name TEXT NOT NULL,
  requested_cif_vat TEXT NOT NULL,
  requested_billing_email TEXT,
  requested_address TEXT NOT NULL,
  requested_postal_code TEXT NOT NULL,
  requested_city TEXT NOT NULL,
  requested_province TEXT,
  requested_country TEXT NOT NULL,

  reason TEXT,

  status TEXT NOT NULL DEFAULT 'pending',

  reviewed_by UUID
    REFERENCES auth.users(id)
    ON DELETE SET NULL,

  reviewed_at TIMESTAMPTZ,

  rejection_reason TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT company_fiscal_change_requests_status_check
    CHECK (
      status IN (
        'pending',
        'approved',
        'rejected',
        'cancelled'
      )
    ),

  CONSTRAINT company_fiscal_change_requests_status_review_check
    CHECK (
      (status = 'pending' AND reviewed_by IS NULL AND reviewed_at IS NULL)
      OR
      (status IN ('approved', 'rejected') AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
      OR
      (status = 'cancelled')
    ),

  CONSTRAINT company_fiscal_change_requests_legal_name_length
    CHECK (char_length(requested_legal_name) <= 300),

  CONSTRAINT company_fiscal_change_requests_tax_id_length
    CHECK (char_length(requested_cif_vat) <= 100),

  CONSTRAINT company_fiscal_change_requests_email_length
    CHECK (
      requested_billing_email IS NULL
      OR char_length(requested_billing_email) <= 320
    ),

  CONSTRAINT company_fiscal_change_requests_address_length
    CHECK (char_length(requested_address) <= 500),

  CONSTRAINT company_fiscal_change_requests_postal_length
    CHECK (char_length(requested_postal_code) <= 30),

  CONSTRAINT company_fiscal_change_requests_city_length
    CHECK (char_length(requested_city) <= 200),

  CONSTRAINT company_fiscal_change_requests_province_length
    CHECK (
      requested_province IS NULL
      OR char_length(requested_province) <= 200
    ),

  CONSTRAINT company_fiscal_change_requests_country_length
    CHECK (char_length(requested_country) = 2)
);

CREATE INDEX IF NOT EXISTS
  idx_company_fiscal_change_requests_company
ON public.company_fiscal_change_requests (company_id, requested_at DESC);

CREATE INDEX IF NOT EXISTS
  idx_company_fiscal_change_requests_status
ON public.company_fiscal_change_requests (status, requested_at DESC);

CREATE INDEX IF NOT EXISTS
  idx_company_fiscal_change_requests_requested_by
ON public.company_fiscal_change_requests (requested_by, requested_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_company_fiscal_change_requests_one_pending_per_company
ON public.company_fiscal_change_requests (company_id)
WHERE status = 'pending';

-- ============================================================
-- 2. updated_at
-- ============================================================

DROP TRIGGER IF EXISTS company_fiscal_change_requests_updated_at
ON public.company_fiscal_change_requests;

CREATE TRIGGER company_fiscal_change_requests_updated_at
BEFORE UPDATE ON public.company_fiscal_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================
-- 3. RLS DE SOLICITUDES
-- ============================================================

ALTER TABLE public.company_fiscal_change_requests
ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS company_fiscal_change_requests_client_select
ON public.company_fiscal_change_requests;

CREATE POLICY company_fiscal_change_requests_client_select
ON public.company_fiscal_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND requested_by = auth.uid()
  AND company_id = public.current_user_company_id()
);

DROP POLICY IF EXISTS company_fiscal_change_requests_worker_select
ON public.company_fiscal_change_requests;

CREATE POLICY company_fiscal_change_requests_worker_select
ON public.company_fiscal_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
);

-- No INSERT/UPDATE/DELETE directo para authenticated.
-- Las modificaciones se realizan exclusivamente mediante RPC.

REVOKE ALL
ON public.company_fiscal_change_requests
FROM authenticated, anon;

GRANT SELECT
ON public.company_fiscal_change_requests
TO authenticated;

-- ============================================================
-- 4. RPC — CLIENTE SOLICITA CAMBIO FISCAL
-- ============================================================
--
-- El cliente nunca recibe UPDATE sobre companies.
-- Esta función captura un snapshot de los datos actuales y guarda
-- la propuesta completa.
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_company_fiscal_change(
  p_legal_name TEXT,
  p_cif_vat TEXT,
  p_billing_email TEXT DEFAULT NULL,
  p_address TEXT DEFAULT NULL,
  p_postal_code TEXT DEFAULT NULL,
  p_city TEXT DEFAULT NULL,
  p_province TEXT DEFAULT NULL,
  p_country TEXT DEFAULT 'ES',
  p_reason TEXT DEFAULT NULL
)
RETURNS public.company_fiscal_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_company_id UUID;
  v_company public.companies;
  v_request public.company_fiscal_change_requests;
  v_legal_name TEXT;
  v_cif_vat TEXT;
  v_billing_email TEXT;
  v_address TEXT;
  v_postal_code TEXT;
  v_city TEXT;
  v_province TEXT;
  v_country TEXT;
  v_reason TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Esta operación está destinada a clientes; los workers utilizan la operación interna';
  END IF;

  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'La cuenta no está activa';
  END IF;

  v_company_id := public.current_user_company_id();

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION
      'El usuario no tiene una empresa asociada';
  END IF;

  SELECT *
  INTO v_company
  FROM public.companies
  WHERE id = v_company_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La empresa asociada no existe';
  END IF;

  v_legal_name := NULLIF(BTRIM(p_legal_name), '');
  v_cif_vat := NULLIF(UPPER(BTRIM(p_cif_vat)), '');
  v_billing_email := NULLIF(BTRIM(p_billing_email), '');
  v_address := NULLIF(BTRIM(p_address), '');
  v_postal_code := NULLIF(BTRIM(p_postal_code), '');
  v_city := NULLIF(BTRIM(p_city), '');
  v_province := NULLIF(BTRIM(p_province), '');
  v_country := UPPER(NULLIF(BTRIM(COALESCE(p_country, 'ES')), ''));
  v_reason := NULLIF(BTRIM(p_reason), '');

  IF v_legal_name IS NULL
     OR LENGTH(v_legal_name) > 300
  THEN
    RAISE EXCEPTION 'La razón social es obligatoria y no puede superar 300 caracteres';
  END IF;

  IF v_cif_vat IS NULL
     OR LENGTH(v_cif_vat) > 100
  THEN
    RAISE EXCEPTION 'El NIF/CIF/VAT es obligatorio y no puede superar 100 caracteres';
  END IF;

  IF v_address IS NULL
     OR LENGTH(v_address) > 500
  THEN
    RAISE EXCEPTION 'La dirección fiscal es obligatoria';
  END IF;

  IF v_postal_code IS NULL
     OR LENGTH(v_postal_code) > 30
  THEN
    RAISE EXCEPTION 'El código postal es obligatorio';
  END IF;

  IF v_city IS NULL
     OR LENGTH(v_city) > 200
  THEN
    RAISE EXCEPTION 'La ciudad es obligatoria';
  END IF;

  IF v_country IS NULL
     OR v_country !~ '^[A-Z]{2}$'
  THEN
    RAISE EXCEPTION 'El país debe ser un código ISO de dos letras';
  END IF;

  IF v_billing_email IS NOT NULL
     AND LENGTH(v_billing_email) > 320
  THEN
    RAISE EXCEPTION 'El email de facturación no puede superar 320 caracteres';
  END IF;

  IF v_reason IS NOT NULL
     AND LENGTH(v_reason) > 1000
  THEN
    RAISE EXCEPTION 'El motivo no puede superar 1000 caracteres';
  END IF;

  -- Evita solicitudes duplicadas mientras exista una pendiente.
  IF EXISTS (
    SELECT 1
    FROM public.company_fiscal_change_requests
    WHERE company_id = v_company_id
      AND status = 'pending'
  ) THEN
    RAISE EXCEPTION
      'Ya existe una solicitud de cambio fiscal pendiente para esta empresa';
  END IF;

  -- No tiene sentido crear una solicitud si no hay ningún cambio.
  IF COALESCE(NULLIF(BTRIM(v_company.legal_name), ''), NULL)
       IS NOT DISTINCT FROM v_legal_name
     AND COALESCE(NULLIF(BTRIM(v_company.cif_vat), ''), NULL)
       IS NOT DISTINCT FROM v_cif_vat
     AND COALESCE(NULLIF(BTRIM(v_company.billing_email), ''), NULL)
       IS NOT DISTINCT FROM v_billing_email
     AND COALESCE(NULLIF(BTRIM(v_company.address), ''), NULL)
       IS NOT DISTINCT FROM v_address
     AND COALESCE(NULLIF(BTRIM(v_company.postal_code), ''), NULL)
       IS NOT DISTINCT FROM v_postal_code
     AND COALESCE(NULLIF(BTRIM(v_company.city), ''), NULL)
       IS NOT DISTINCT FROM v_city
     AND COALESCE(NULLIF(BTRIM(v_company.province), ''), NULL)
       IS NOT DISTINCT FROM v_province
     AND COALESCE(UPPER(NULLIF(BTRIM(v_company.country), '')), 'ES')
       IS NOT DISTINCT FROM v_country
  THEN
    RAISE EXCEPTION
      'No se ha detectado ningún cambio en los datos fiscales';
  END IF;

  INSERT INTO public.company_fiscal_change_requests (
    company_id,
    requested_by,
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
    requested_country,
    reason,
    status
  )
  VALUES (
    v_company_id,
    auth.uid(),
    v_company.legal_name,
    v_company.cif_vat,
    v_company.billing_email,
    v_company.address,
    v_company.postal_code,
    v_company.city,
    v_company.province,
    v_company.country,
    v_legal_name,
    v_cif_vat,
    v_billing_email,
    v_address,
    v_postal_code,
    v_city,
    v_province,
    v_country,
    v_reason,
    'pending'
  )
  RETURNING *
  INTO v_request;

  PERFORM public.log_activity(
    'company_fiscal_change_requested',
    'company_fiscal_change_request',
    v_request.id,
    'El cliente ha solicitado un cambio de datos fiscales.',
    jsonb_build_object(
      'company_id', v_company_id,
      'changed_fields', jsonb_build_array(
        'legal_name',
        'cif_vat',
        'billing_email',
        'address',
        'postal_code',
        'city',
        'province',
        'country'
      )
    )
  );

  RETURN v_request;
END;
$$;

REVOKE ALL
ON FUNCTION public.request_company_fiscal_change(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.request_company_fiscal_change(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
)
TO authenticated;

-- ============================================================
-- 5. RPC — WORKER APRUEBA O RECHAZA UNA SOLICITUD
-- ============================================================

CREATE OR REPLACE FUNCTION public.review_company_fiscal_change(
  p_request_id UUID,
  p_action TEXT,
  p_rejection_reason TEXT DEFAULT NULL
)
RETURNS public.company_fiscal_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_request public.company_fiscal_change_requests;
  v_company public.companies;
  v_action TEXT := LOWER(BTRIM(COALESCE(p_action, '')));
  v_rejection_reason TEXT := NULLIF(BTRIM(p_rejection_reason), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador activo';
  END IF;

  IF v_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'Acción no válida. Debe ser approve o reject';
  END IF;

  SELECT *
  INTO v_request
  FROM public.company_fiscal_change_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud de cambio fiscal no existe';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'La solicitud ya ha sido revisada';
  END IF;

  IF v_action = 'reject' THEN
    UPDATE public.company_fiscal_change_requests
    SET
      status = 'rejected',
      reviewed_by = auth.uid(),
      reviewed_at = CURRENT_TIMESTAMP,
      rejection_reason = v_rejection_reason,
      updated_at = CURRENT_TIMESTAMP
    WHERE id = v_request.id
    RETURNING *
    INTO v_request;

    PERFORM public.log_activity(
      'company_fiscal_change_rejected',
      'company_fiscal_change_request',
      v_request.id,
      'El trabajador ha rechazado una solicitud de cambio fiscal.',
      jsonb_build_object(
        'company_id', v_request.company_id,
        'rejection_reason_provided', (v_rejection_reason IS NOT NULL)
      )
    );

    RETURN v_request;
  END IF;

  SELECT *
  INTO v_company
  FROM public.companies
  WHERE id = v_request.company_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La empresa asociada ya no existe';
  END IF;

  UPDATE public.companies
  SET
    legal_name = v_request.requested_legal_name,
    cif_vat = v_request.requested_cif_vat,
    billing_email = v_request.requested_billing_email,
    address = v_request.requested_address,
    postal_code = v_request.requested_postal_code,
    city = v_request.requested_city,
    province = v_request.requested_province,
    country = v_request.requested_country,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_request.company_id;

  UPDATE public.company_fiscal_change_requests
  SET
    status = 'approved',
    reviewed_by = auth.uid(),
    reviewed_at = CURRENT_TIMESTAMP,
    rejection_reason = NULL,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_request.id
  RETURNING *
  INTO v_request;

  PERFORM public.log_activity(
    'company_fiscal_change_approved',
    'company_fiscal_change_request',
    v_request.id,
    'El trabajador ha aprobado un cambio de datos fiscales y los datos de la empresa han sido actualizados.',
    jsonb_build_object(
      'company_id', v_request.company_id
    )
  );

  RETURN v_request;
END;
$$;

REVOKE ALL
ON FUNCTION public.review_company_fiscal_change(UUID, TEXT, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.review_company_fiscal_change(UUID, TEXT, TEXT)
TO authenticated;

-- ============================================================
-- 6. RPC — WORKER MODIFICA DIRECTAMENTE LOS DATOS FISCALES
-- ============================================================
--
-- Se utiliza cuando la información llega por correo, soporte, documentación,
-- etc. No obliga al cliente a repetirla.
--
-- Para conservar exactamente la misma trazabilidad que una aprobación,
-- se crea una solicitud ya aprobada con snapshot anterior/nuevo y el worker
-- que la aplicó queda registrado como requested_by y reviewed_by.
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_company_fiscal_data_by_worker(
  p_company_id UUID,
  p_legal_name TEXT,
  p_cif_vat TEXT,
  p_billing_email TEXT DEFAULT NULL,
  p_address TEXT DEFAULT NULL,
  p_postal_code TEXT DEFAULT NULL,
  p_city TEXT DEFAULT NULL,
  p_province TEXT DEFAULT NULL,
  p_country TEXT DEFAULT 'ES',
  p_reason TEXT DEFAULT NULL
)
RETURNS public.company_fiscal_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_company public.companies;
  v_request public.company_fiscal_change_requests;
  v_legal_name TEXT;
  v_cif_vat TEXT;
  v_billing_email TEXT;
  v_address TEXT;
  v_postal_code TEXT;
  v_city TEXT;
  v_province TEXT;
  v_country TEXT;
  v_reason TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador activo';
  END IF;

  IF p_company_id IS NULL THEN
    RAISE EXCEPTION 'La empresa es obligatoria';
  END IF;

  SELECT *
  INTO v_company
  FROM public.companies
  WHERE id = p_company_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La empresa no existe';
  END IF;

  v_legal_name := NULLIF(BTRIM(p_legal_name), '');
  v_cif_vat := NULLIF(UPPER(BTRIM(p_cif_vat)), '');
  v_billing_email := NULLIF(BTRIM(p_billing_email), '');
  v_address := NULLIF(BTRIM(p_address), '');
  v_postal_code := NULLIF(BTRIM(p_postal_code), '');
  v_city := NULLIF(BTRIM(p_city), '');
  v_province := NULLIF(BTRIM(p_province), '');
  v_country := UPPER(NULLIF(BTRIM(COALESCE(p_country, 'ES')), ''));
  v_reason := NULLIF(BTRIM(p_reason), '');

  IF v_legal_name IS NULL OR LENGTH(v_legal_name) > 300 THEN
    RAISE EXCEPTION 'La razón social es obligatoria';
  END IF;

  IF v_cif_vat IS NULL OR LENGTH(v_cif_vat) > 100 THEN
    RAISE EXCEPTION 'El NIF/CIF/VAT es obligatorio';
  END IF;

  IF v_address IS NULL OR LENGTH(v_address) > 500 THEN
    RAISE EXCEPTION 'La dirección fiscal es obligatoria';
  END IF;

  IF v_postal_code IS NULL OR LENGTH(v_postal_code) > 30 THEN
    RAISE EXCEPTION 'El código postal es obligatorio';
  END IF;

  IF v_city IS NULL OR LENGTH(v_city) > 200 THEN
    RAISE EXCEPTION 'La ciudad es obligatoria';
  END IF;

  IF v_country IS NULL OR v_country !~ '^[A-Z]{2}$' THEN
    RAISE EXCEPTION 'El país debe ser un código ISO de dos letras';
  END IF;

  IF v_billing_email IS NOT NULL AND LENGTH(v_billing_email) > 320 THEN
    RAISE EXCEPTION 'El email de facturación no puede superar 320 caracteres';
  END IF;

  IF v_reason IS NOT NULL AND LENGTH(v_reason) > 1000 THEN
    RAISE EXCEPTION 'El motivo no puede superar 1000 caracteres';
  END IF;

  IF COALESCE(NULLIF(BTRIM(v_company.legal_name), ''), NULL)
       IS NOT DISTINCT FROM v_legal_name
     AND COALESCE(NULLIF(BTRIM(v_company.cif_vat), ''), NULL)
       IS NOT DISTINCT FROM v_cif_vat
     AND COALESCE(NULLIF(BTRIM(v_company.billing_email), ''), NULL)
       IS NOT DISTINCT FROM v_billing_email
     AND COALESCE(NULLIF(BTRIM(v_company.address), ''), NULL)
       IS NOT DISTINCT FROM v_address
     AND COALESCE(NULLIF(BTRIM(v_company.postal_code), ''), NULL)
       IS NOT DISTINCT FROM v_postal_code
     AND COALESCE(NULLIF(BTRIM(v_company.city), ''), NULL)
       IS NOT DISTINCT FROM v_city
     AND COALESCE(NULLIF(BTRIM(v_company.province), ''), NULL)
       IS NOT DISTINCT FROM v_province
     AND COALESCE(UPPER(NULLIF(BTRIM(v_company.country), '')), 'ES')
       IS NOT DISTINCT FROM v_country
  THEN
    RAISE EXCEPTION 'No se ha detectado ningún cambio en los datos fiscales';
  END IF;

  UPDATE public.companies
  SET
    legal_name = v_legal_name,
    cif_vat = v_cif_vat,
    billing_email = v_billing_email,
    address = v_address,
    postal_code = v_postal_code,
    city = v_city,
    province = v_province,
    country = v_country,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_company_id;

  INSERT INTO public.company_fiscal_change_requests (
    company_id,
    requested_by,
    requested_at,
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
    requested_country,
    reason,
    status,
    reviewed_by,
    reviewed_at
  )
  VALUES (
    p_company_id,
    auth.uid(),
    CURRENT_TIMESTAMP,
    v_company.legal_name,
    v_company.cif_vat,
    v_company.billing_email,
    v_company.address,
    v_company.postal_code,
    v_company.city,
    v_company.province,
    v_company.country,
    v_legal_name,
    v_cif_vat,
    v_billing_email,
    v_address,
    v_postal_code,
    v_city,
    v_province,
    v_country,
    COALESCE(v_reason, 'Modificación realizada directamente por trabajador.'),
    'approved',
    auth.uid(),
    CURRENT_TIMESTAMP
  )
  RETURNING *
  INTO v_request;

  PERFORM public.log_activity(
    'company_fiscal_data_updated_by_worker',
    'company_fiscal_change_request',
    v_request.id,
    'Un trabajador ha actualizado directamente los datos fiscales de la empresa.',
    jsonb_build_object(
      'company_id', p_company_id,
      'source', 'worker_direct_update'
    )
  );

  RETURN v_request;
END;
$$;

REVOKE ALL
ON FUNCTION public.update_company_fiscal_data_by_worker(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_company_fiscal_data_by_worker(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
)
TO authenticated;

-- ============================================================
-- 7. GUARD FISCAL PARA MAINTENANCE_INVOICES
-- ============================================================
--
-- Una factura de mantenimiento puede permanecer en borrador sin datos
-- fiscales completos.
--
-- En el momento en que se crea/pasa a un estado distinto de borrador:
-- 1. Debe existir company_id.
-- 2. La empresa debe tener datos fiscales mínimos completos.
-- 3. El snapshot customer_* de la factura se toma de companies.
--
-- De esta forma:
-- companies = fuente actual de datos fiscales.
-- maintenance_invoices.customer_* = snapshot histórico de la factura.
--
-- Una vez emitida, cambiar companies NO modifica la factura ya emitida.
-- ============================================================

CREATE OR REPLACE FUNCTION public.guard_maintenance_invoice_fiscal_data()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_company public.companies;
BEGIN
  -- Los borradores pueden existir incompletos.
  IF COALESCE(NEW.estado, 'borrador') = 'borrador' THEN
    RETURN NEW;
  END IF;

  IF NEW.company_id IS NULL THEN
    RAISE EXCEPTION
      'No se puede emitir una factura de mantenimiento sin empresa';
  END IF;

  SELECT *
  INTO v_company
  FROM public.companies
  WHERE id = NEW.company_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'No se puede emitir una factura de mantenimiento: la empresa no existe';
  END IF;

  IF NULLIF(BTRIM(v_company.legal_name), '') IS NULL
     AND NULLIF(BTRIM(v_company.company_name), '') IS NULL
  THEN
    RAISE EXCEPTION
      'No se puede emitir la factura: falta la razón social';
  END IF;

  IF NULLIF(BTRIM(v_company.cif_vat), '') IS NULL THEN
    RAISE EXCEPTION
      'No se puede emitir la factura: falta el NIF/CIF/VAT';
  END IF;

  IF NULLIF(BTRIM(v_company.address), '') IS NULL THEN
    RAISE EXCEPTION
      'No se puede emitir la factura: falta la dirección fiscal';
  END IF;

  IF NULLIF(BTRIM(v_company.postal_code), '') IS NULL THEN
    RAISE EXCEPTION
      'No se puede emitir la factura: falta el código postal';
  END IF;

  IF NULLIF(BTRIM(v_company.city), '') IS NULL THEN
    RAISE EXCEPTION
      'No se puede emitir la factura: falta la ciudad';
  END IF;

  IF NULLIF(BTRIM(v_company.country), '') IS NULL THEN
    RAISE EXCEPTION
      'No se puede emitir la factura: falta el país';
  END IF;

  -- Guardamos el snapshot fiscal de la empresa en la factura.
  NEW.customer_legal_name :=
    COALESCE(
      NULLIF(BTRIM(v_company.legal_name), ''),
      NULLIF(BTRIM(v_company.company_name), '')
    );

  NEW.customer_tax_id :=
    NULLIF(BTRIM(v_company.cif_vat), '');

  NEW.customer_address :=
    NULLIF(BTRIM(v_company.address), '');

  NEW.customer_postal_code :=
    NULLIF(BTRIM(v_company.postal_code), '');

  NEW.customer_city :=
    NULLIF(BTRIM(v_company.city), '');

  NEW.customer_province :=
    NULLIF(BTRIM(v_company.province), '');

  NEW.customer_country :=
    UPPER(NULLIF(BTRIM(v_company.country), ''));

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS maintenance_invoices_guard_fiscal_data
ON public.maintenance_invoices;

CREATE TRIGGER maintenance_invoices_guard_fiscal_data
BEFORE INSERT OR UPDATE OF estado, company_id
ON public.maintenance_invoices
FOR EACH ROW
EXECUTE FUNCTION public.guard_maintenance_invoice_fiscal_data();

-- ============================================================
-- 8. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.company_fiscal_change_requests IS
'Solicitudes y cambios auditables de datos fiscales de empresas. Los clientes proponen cambios; los workers pueden aprobarlos/rechazarlos o aplicar cambios directos, siempre mediante RPC.';

COMMENT ON COLUMN public.company_fiscal_change_requests.current_legal_name IS
'Snapshot del dato existente en companies cuando se creó la solicitud.';

COMMENT ON COLUMN public.company_fiscal_change_requests.requested_legal_name IS
'Valor fiscal propuesto/aplicado por la solicitud.';

COMMENT ON FUNCTION public.request_company_fiscal_change(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) IS
'Permite al cliente proponer cambios en los datos fiscales de su propia empresa sin conceder UPDATE directo sobre companies.';

COMMENT ON FUNCTION public.review_company_fiscal_change(
  UUID, TEXT, TEXT
) IS
'Permite a un worker activo aprobar o rechazar una solicitud de cambio fiscal. La aprobación actualiza companies de forma atómica.';

COMMENT ON FUNCTION public.update_company_fiscal_data_by_worker(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) IS
'Permite a un worker activo modificar directamente los datos fiscales de una empresa cuando la información llega por otro canal. El cambio queda registrado como solicitud aprobada para mantener trazabilidad.';

COMMENT ON FUNCTION public.guard_maintenance_invoice_fiscal_data() IS
'Impide emitir facturas de mantenimiento sin datos fiscales mínimos completos y toma un snapshot fiscal de companies en customer_*.';

-- ============================================================
-- 9. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
  v_update_privilege BOOLEAN;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'company_fiscal_change_requests'
  ) THEN
    RAISE EXCEPTION
      '051 failed: company_fiscal_change_requests missing';
  END IF;

  SELECT has_table_privilege(
    'authenticated',
    'public.companies',
    'UPDATE'
  )
  INTO v_update_privilege;

  IF v_update_privilege THEN
    RAISE EXCEPTION
      '051 failed: authenticated todavía conserva UPDATE directo sobre companies';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'request_company_fiscal_change'
    AND pg_get_function_identity_arguments(p.oid)
      = 'p_legal_name text, p_cif_vat text, p_billing_email text, p_address text, p_postal_code text, p_city text, p_province text, p_country text, p_reason text';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '051 failed: request_company_fiscal_change() missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'review_company_fiscal_change'
    AND pg_get_function_identity_arguments(p.oid)
      = 'p_request_id uuid, p_action text, p_rejection_reason text';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '051 failed: review_company_fiscal_change() missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'update_company_fiscal_data_by_worker'
    AND pg_get_function_identity_arguments(p.oid)
      = 'p_company_id uuid, p_legal_name text, p_cif_vat text, p_billing_email text, p_address text, p_postal_code text, p_city text, p_province text, p_country text, p_reason text';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '051 failed: update_company_fiscal_data_by_worker() missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_trigger
  WHERE tgrelid = 'public.maintenance_invoices'::regclass
    AND tgname = 'maintenance_invoices_guard_fiscal_data';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '051 failed: maintenance invoice fiscal guard trigger missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'company_fiscal_change_requests'
    AND policyname IN (
      'company_fiscal_change_requests_client_select',
      'company_fiscal_change_requests_worker_select'
    );

  IF v_count <> 2 THEN
    RAISE EXCEPTION
      '051 failed: fiscal change request SELECT policies incomplete';
  END IF;
END $$;

COMMIT;

-- ============================================================
-- FIN 051
-- ============================================================
