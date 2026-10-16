-- ============================================================
-- MODIRA — 067_maintenance_billing_hardening.sql
-- ============================================================
--
-- Cierra los huecos de concurrencia, integridad Stripe, evidencia
-- contractual y Storage detectados en 049-066.
--
-- IMPORTANTE:
-- - No modifica 049-066.
-- - Es idempotente.
-- - La Edge Function maintenance-stripe debe desplegarse junto con
--   esta migración.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. EVIDENCIA CONTRACTUAL EN MAINTENANCE_CONTRACTS
-- ============================================================

ALTER TABLE public.maintenance_contracts
  ADD COLUMN IF NOT EXISTS stripe_checkout_session_id TEXT,
  ADD COLUMN IF NOT EXISTS contracted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS terms_version TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_contracts_checkout_session_id
ON public.maintenance_contracts (stripe_checkout_session_id)
WHERE stripe_checkout_session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_contracted_at
ON public.maintenance_contracts (contracted_at);

COMMENT ON COLUMN public.maintenance_contracts.stripe_checkout_session_id IS
'Checkout Session de Stripe que originó la contratación del mantenimiento. Evidencia técnica del proceso de contratación.';

COMMENT ON COLUMN public.maintenance_contracts.contracted_at IS
'Momento en que Modira registra la contratación completada mediante Stripe Checkout.';

COMMENT ON COLUMN public.maintenance_contracts.terms_version IS
'Versión de los términos/condiciones aceptados durante la contratación.';


-- ============================================================
-- 2. UNA SOLA CONTRATACIÓN ACTIVA POR EMPRESA
-- ============================================================
--
-- Evita que dos suscripciones Stripe diferentes queden activas
-- simultáneamente para una misma empresa.
-- ============================================================

DO $$
DECLARE
  v_duplicates INTEGER;
BEGIN
  SELECT COUNT(*)
  INTO v_duplicates
  FROM (
    SELECT company_id
    FROM public.maintenance_contracts
    WHERE estado IN ('activo', 'pausado')
    GROUP BY company_id
    HAVING COUNT(*) > 1
  ) d;

  IF v_duplicates > 0 THEN
    RAISE EXCEPTION
      '067 stopped: existen empresas con más de un maintenance_contract activo/pausado. Revísalas antes de continuar.';
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_contracts_one_live_per_company
ON public.maintenance_contracts (company_id)
WHERE estado IN ('activo', 'pausado');


-- ============================================================
-- 3. LOCK DURANTE CHECKOUT
-- ============================================================
--
-- El SELECT previo de maintenance_contracts no es suficiente
-- para evitar dos Checkout Sessions concurrentes.
--
-- Esta tabla funciona como lock persistente con expiración:
-- - PK por company_id => una contratación simultánea por empresa.
-- - expires_at => un fallo/crash no bloquea indefinidamente.
-- - stripe_checkout_session_id => permite trazabilidad.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.maintenance_checkout_locks (
  company_id UUID PRIMARY KEY
    REFERENCES public.companies(id)
    ON DELETE CASCADE,

  user_id UUID NOT NULL
    REFERENCES auth.users(id)
    ON DELETE CASCADE,

  plan_id UUID NOT NULL
    REFERENCES public.maintenance_plans(id)
    ON DELETE RESTRICT,

  stripe_checkout_session_id TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMPTZ NOT NULL,

  CONSTRAINT maintenance_checkout_locks_dates_check
    CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_checkout_locks_stripe_session
ON public.maintenance_checkout_locks (stripe_checkout_session_id)
WHERE stripe_checkout_session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_checkout_locks_expires_at
ON public.maintenance_checkout_locks (expires_at);

ALTER TABLE public.maintenance_checkout_locks ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON public.maintenance_checkout_locks
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.maintenance_checkout_locks
TO service_role;

-- ============================================================
-- 4. STORAGE — NO SOBRESCRIBIR DOCUMENTOS YA ASOCIADOS
-- ============================================================
--
-- Los workers pueden subir un PDF únicamente si:
-- - es un PDF;
-- - la ruta empieza por un UUID de maintenance_invoice existente;
-- - esa ruta todavía no está asociada a ninguna factura.
--
-- Una vez asociado mediante attach_maintenance_invoice_document(),
-- el objeto no puede ser sobrescrito directamente por authenticated.
--
-- service_role sigue pudiendo gestionar Storage desde backend.
-- ============================================================

DROP POLICY IF EXISTS maintenance_invoice_storage_worker_insert
ON storage.objects;

CREATE POLICY maintenance_invoice_storage_worker_insert
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'maintenance-invoices'
  AND public.current_user_is_worker()
  AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/.+\.pdf$'
  AND EXISTS (
    SELECT 1
    FROM public.maintenance_invoices mi
    WHERE mi.id = split_part(storage.objects.name, '/', 1)::UUID
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.maintenance_invoices mi
    WHERE mi.document_path = storage.objects.name
       OR mi.pdf_storage_path = storage.objects.name
       OR mi.electronic_document_storage_path = storage.objects.name
       OR mi.stripe_pdf_storage_path = storage.objects.name
  )
);

DROP POLICY IF EXISTS maintenance_invoice_storage_worker_update
ON storage.objects;

CREATE POLICY maintenance_invoice_storage_worker_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'maintenance-invoices'
  AND public.current_user_is_worker()
  AND NOT EXISTS (
    SELECT 1
    FROM public.maintenance_invoices mi
    WHERE mi.document_path = storage.objects.name
       OR mi.pdf_storage_path = storage.objects.name
       OR mi.electronic_document_storage_path = storage.objects.name
       OR mi.stripe_pdf_storage_path = storage.objects.name
  )
)
WITH CHECK (
  bucket_id = 'maintenance-invoices'
  AND public.current_user_is_worker()
  AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/.+\.pdf$'
  AND EXISTS (
    SELECT 1
    FROM public.maintenance_invoices mi
    WHERE mi.id = split_part(storage.objects.name, '/', 1)::UUID
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.maintenance_invoices mi
    WHERE mi.document_path = storage.objects.name
       OR mi.pdf_storage_path = storage.objects.name
       OR mi.electronic_document_storage_path = storage.objects.name
       OR mi.stripe_pdf_storage_path = storage.objects.name
  )
);


-- ============================================================
-- 5. HASH DOCUMENTAL — EVITAR CAMBIOS MANUALES DE HASH
-- ============================================================
--
-- El hash del PDF Modira se calculará server-side por la Edge
-- Function maintenance-stripe con la acción:
--
--   hash_maintenance_invoice_document
--
-- El worker ya no necesita proporcionar el SHA-256 manualmente.
-- Mantenemos la RPC existente para compatibilidad, pero impedimos
-- que un hash ya fijado pueda sustituirse por otro.
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_maintenance_invoice_document_hash(
  p_invoice_id UUID,
  p_sha256 TEXT
)
RETURNS public.maintenance_invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_invoice public.maintenance_invoices;
  v_hash TEXT;
BEGIN
  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Acceso denegado: se requiere un trabajador activo';
  END IF;

  v_hash := LOWER(TRIM(COALESCE(p_sha256, '')));

  IF v_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION
      'La huella digital del documento no es un SHA-256 válido';
  END IF;

  SELECT *
  INTO v_invoice
  FROM public.maintenance_invoices
  WHERE id = p_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'La factura de mantenimiento no existe';
  END IF;

  IF v_invoice.document_path IS NULL THEN
    RAISE EXCEPTION
      'La factura todavía no tiene document_path';
  END IF;

  IF v_invoice.document_sha256 IS NOT NULL
     AND LOWER(v_invoice.document_sha256) <> v_hash
  THEN
    RAISE EXCEPTION
      'La factura ya tiene una huella SHA-256 diferente; no se permite sustituirla';
  END IF;

  UPDATE public.maintenance_invoices
  SET
    document_sha256 = v_hash,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_invoice_id
  RETURNING *
  INTO v_invoice;

  RETURN v_invoice;
END;
$function$;

REVOKE ALL
ON FUNCTION public.set_maintenance_invoice_document_hash(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.set_maintenance_invoice_document_hash(UUID, TEXT)
TO authenticated;


-- ============================================================
-- 6. VALIDACIÓN DE CONSISTENCIA DE DATOS FISCALES ACTUALES
-- ============================================================
--
-- 051 ya protege la emisión de maintenance_invoices:
-- una factura no borrador requiere:
-- - razón social;
-- - NIF/CIF/VAT;
-- - dirección;
-- - código postal;
-- - ciudad;
-- - país.
--
-- No duplicamos esa lógica aquí para evitar dos fuentes de verdad.
--
-- La Edge Function la comprueba ANTES de Checkout y ANTES de cada
-- ciclo de facturación. El trigger 051 sigue siendo la última barrera
-- de base de datos al insertar/emitir la factura.
-- ============================================================


-- ============================================================
-- 7. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN

  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_checkout_locks';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '067 failed: maintenance_checkout_locks missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_contracts'
    AND column_name = 'stripe_checkout_session_id';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '067 failed: stripe_checkout_session_id missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND indexname = 'idx_maintenance_contracts_one_live_per_company';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '067 failed: one-live-contract index missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND indexname = 'idx_maintenance_checkout_locks_stripe_session';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '067 failed: checkout session index missing';
  END IF;

END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- FIN — MODIRA 067
-- ============================================================
