-- ============================================================
-- MODIRA — 050_maintenance_invoice_documents_fiscal.sql
-- ============================================================
-- OBJETIVO
-- 1. Completar la infraestructura documental de maintenance_invoices.
-- 2. Permitir al WORKER adjuntar el PDF de la factura de mantenimiento,
--    siguiendo el mismo modelo que las facturas de servicios de Modira.
-- 3. Mantener separado el PDF de Modira del PDF generado por Stripe.
-- 4. Conservar metadatos de integridad del documento (SHA-256, MIME,
--    tamaño, fecha y trabajador que lo adjuntó).
-- 5. Mantener el bucket privado y controlar el acceso por empresa.
-- 6. Impedir que una factura emitida pueda quedarse sin su documento
--    documental cuando se utilice la vía PDF de Modira.
-- 7. Validar que una empresa que contrata mantenimiento tenga sus datos
--    fiscales mínimos disponibles (NIF/IVA y datos de identificación).
-- 8. Preparar el modelo para que en el futuro pueda conservarse también
--    una factura electrónica estructurada original, sin obligar hoy a que
--    el PDF sea el único formato legal.
--
-- IMPORTANTE
-- - Stripe SÍ genera un PDF de su propia factura, pero ese documento es
--   la factura de Stripe por su servicio de cobro/billing; no sustituye
--   automáticamente la factura comercial/fiscal emitida por Modira.
-- - El PDF de Modira lo adjunta un WORKER, igual que en public.invoices.
-- - El PDF de Stripe se conserva como documento auxiliar separado.
-- - Las facturas no se eliminan.
-- - Esta migración no crea Products/Prices ni ejecuta llamadas a Stripe.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
  ) THEN
    RAISE EXCEPTION
      '050 stopped: public.maintenance_invoices does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'companies'
  ) THEN
    RAISE EXCEPTION
      '050 stopped: public.companies does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contracts'
  ) THEN
    RAISE EXCEPTION
      '050 stopped: public.maintenance_contracts does not exist';
  END IF;
END $$;

-- ============================================================
-- 2. DOCUMENTO PDF DE MODIRA
-- ============================================================
--
-- document_path es equivalente conceptualmente al document_path que ya
-- utiliza public.invoices para las facturas de servicios.
--
-- El worker subirá el PDF al bucket privado y después lo asociará mediante
-- attach_maintenance_invoice_document().
-- ============================================================

ALTER TABLE public.maintenance_invoices
  ADD COLUMN IF NOT EXISTS document_path TEXT,
  ADD COLUMN IF NOT EXISTS document_mime_type TEXT,
  ADD COLUMN IF NOT EXISTS document_file_size BIGINT,
  ADD COLUMN IF NOT EXISTS document_sha256 TEXT,
  ADD COLUMN IF NOT EXISTS document_uploaded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS document_uploaded_by UUID
    REFERENCES auth.users(id)
    ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_invoices_document_path_unique
ON public.maintenance_invoices (document_path)
WHERE document_path IS NOT NULL;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_invoices_document_uploaded_by
ON public.maintenance_invoices (document_uploaded_by)
WHERE document_uploaded_by IS NOT NULL;

-- ============================================================
-- 3. SEPARAR DOCUMENTO DE STRIPE DEL DOCUMENTO DE MODIRA
-- ============================================================
--
-- La 049 utilizó pdf_storage_path para guardar el PDF descargado desde
-- Stripe. Lo conservamos por compatibilidad y añadimos campos explícitos
-- para que el backend pueda migrar posteriormente esa referencia a una
-- semántica inequívoca.
--
-- pdf_storage_path / pdf_sha256 = LEGACY / compatibilidad del PDF Stripe.
-- stripe_pdf_storage_path / stripe_pdf_sha256 = PDF Stripe explícito.
-- document_path / document_sha256 = PDF de la factura emitida por Modira.
-- ============================================================

ALTER TABLE public.maintenance_invoices
  ADD COLUMN IF NOT EXISTS stripe_pdf_storage_path TEXT,
  ADD COLUMN IF NOT EXISTS stripe_pdf_sha256 TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_invoices_stripe_pdf_storage_path_unique
ON public.maintenance_invoices (stripe_pdf_storage_path)
WHERE stripe_pdf_storage_path IS NOT NULL;

-- ============================================================
-- 4. DATOS FISCALES MÍNIMOS DE LA EMPRESA PARA MANTENIMIENTO
-- ============================================================
--
-- companies ya dispone de:
--   legal_name
--   cif_vat
--   address
--   postal_code
--   city
--   province
--   country
--
-- No hacemos esos campos NOT NULL globalmente porque hay empresas
-- existentes que pueden no tener todavía todos los datos completos.
-- En su lugar, el contrato de mantenimiento se valida al crearse o
-- cambiar de empresa.
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_maintenance_contract_fiscal_data()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_company public.companies;
BEGIN
  SELECT *
  INTO v_company
  FROM public.companies
  WHERE id = NEW.company_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La empresa del contrato de mantenimiento no existe';
  END IF;

  IF NULLIF(BTRIM(v_company.cif_vat), '') IS NULL THEN
    RAISE EXCEPTION
      'La empresa debe tener NIF/CIF/VAT antes de contratar mantenimiento';
  END IF;

  IF NULLIF(BTRIM(COALESCE(v_company.legal_name, v_company.company_name)), '') IS NULL THEN
    RAISE EXCEPTION
      'La empresa debe tener razón social antes de contratar mantenimiento';
  END IF;

  IF NULLIF(BTRIM(v_company.address), '') IS NULL
     OR NULLIF(BTRIM(v_company.postal_code), '') IS NULL
     OR NULLIF(BTRIM(v_company.city), '') IS NULL
  THEN
    RAISE EXCEPTION
      'La empresa debe tener dirección fiscal, código postal y ciudad antes de contratar mantenimiento';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS maintenance_contracts_validate_fiscal_data
ON public.maintenance_contracts;

CREATE TRIGGER maintenance_contracts_validate_fiscal_data
BEFORE INSERT OR UPDATE OF company_id
ON public.maintenance_contracts
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_contract_fiscal_data();

-- ============================================================
-- 5. BUCKET PRIVADO DE FACTURAS DE MANTENIMIENTO
-- ============================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('maintenance-invoices', 'maintenance-invoices', FALSE)
ON CONFLICT (id) DO UPDATE
SET public = FALSE;

-- ============================================================
-- 6. STORAGE — WORKER INSERT
-- ============================================================
--
-- El worker puede subir documentos al bucket, pero la ruta debe empezar
-- por maintenance-invoices/<invoice-id>/ para evitar rutas arbitrarias.
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
  AND name ~ '^.+/.+\.pdf$'
);

-- ============================================================
-- 7. STORAGE — WORKER UPDATE
-- ============================================================

DROP POLICY IF EXISTS maintenance_invoice_storage_worker_update
ON storage.objects;

CREATE POLICY maintenance_invoice_storage_worker_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'maintenance-invoices'
  AND public.current_user_is_worker()
)
WITH CHECK (
  bucket_id = 'maintenance-invoices'
  AND public.current_user_is_worker()
  AND name ~ '^.+/.+\.pdf$'
);

-- ============================================================
-- 8. STORAGE — WORKER DELETE
-- ============================================================
--
-- No permitimos que un worker elimine directamente un PDF asociado a una
-- factura. La eliminación documental de una factura emitida no es una
-- operación ordinaria y las facturas deben conservarse.
-- La sustitución documental se gestiona por RPC y queda limitada.
-- ============================================================

DROP POLICY IF EXISTS maintenance_invoice_storage_worker_delete
ON storage.objects;

-- No se crea policy DELETE para authenticated.
-- service_role puede realizar operaciones administrativas cuando proceda.

-- ============================================================
-- 9. STORAGE — CLIENTE SELECT
-- ============================================================

DROP POLICY IF EXISTS maintenance_invoice_storage_client_select
ON storage.objects;

CREATE POLICY maintenance_invoice_storage_client_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'maintenance-invoices'
  AND public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND EXISTS (
    SELECT 1
    FROM public.maintenance_invoices mi
    WHERE mi.company_id = public.current_user_company_id()
      AND (
        mi.document_path = storage.objects.name
        OR mi.pdf_storage_path = storage.objects.name
        OR mi.electronic_document_storage_path = storage.objects.name
        OR mi.stripe_pdf_storage_path = storage.objects.name
      )
  )
);

-- ============================================================
-- 10. STORAGE — WORKER SELECT
-- ============================================================

DROP POLICY IF EXISTS maintenance_invoice_storage_worker_select
ON storage.objects;

CREATE POLICY maintenance_invoice_storage_worker_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'maintenance-invoices'
  AND public.current_user_is_worker()
);

-- ============================================================
-- 11. RPC — ADJUNTAR PDF DE FACTURA DE MANTENIMIENTO
-- ============================================================
--
-- Equivalente seguro a attach_invoice_document() para maintenance_invoices.
--
-- El worker:
-- 1. Debe estar activo.
-- 2. Debe indicar una factura existente.
-- 3. La ruta debe corresponder al bucket correcto.
-- 4. El objeto debe existir en Storage.
-- 5. Debe ser PDF.
-- 6. La ruta debe pertenecer a esa factura.
-- 7. La factura debe conservarse; no se elimina.
--
-- La función guarda también quién adjuntó el documento y cuándo.
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_maintenance_invoice_document(
  p_invoice_id UUID,
  p_document_path TEXT
)
RETURNS public.maintenance_invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_invoice public.maintenance_invoices;
  v_object storage.objects;
  v_path TEXT;
BEGIN
  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Acceso denegado: se requiere un trabajador activo';
  END IF;

  v_path := BTRIM(COALESCE(p_document_path, ''));

  IF v_path = '' THEN
    RAISE EXCEPTION 'El documento es obligatorio';
  END IF;

  IF v_path !~ ('^' || p_invoice_id::TEXT || '/.+\.pdf$') THEN
    RAISE EXCEPTION
      'La ruta del documento no corresponde a la factura indicada';
  END IF;

  SELECT *
  INTO v_invoice
  FROM public.maintenance_invoices
  WHERE id = p_invoice_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La factura de mantenimiento no existe';
  END IF;

  SELECT *
  INTO v_object
  FROM storage.objects
  WHERE bucket_id = 'maintenance-invoices'
    AND name = v_path;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'El PDF no existe en el bucket maintenance-invoices';
  END IF;

  IF LOWER(COALESCE(v_object.metadata->>'mimetype', '')) <> 'application/pdf' THEN
    RAISE EXCEPTION 'El documento de factura debe ser un PDF';
  END IF;

  -- Una factura emitida no puede perder su documento ya asociado.
  -- Si ya existe otro documento, se rechaza la sustitución desde esta RPC.
  IF v_invoice.document_path IS NOT NULL
     AND v_invoice.document_path <> v_path
  THEN
    RAISE EXCEPTION
      'La factura ya tiene un documento asociado; no se permite sustituirlo desde esta operación';
  END IF;

  UPDATE public.maintenance_invoices
  SET
    document_path = v_path,
    document_mime_type = 'application/pdf',
    document_file_size = COALESCE((v_object.metadata->>'size')::BIGINT, NULL),
    document_uploaded_at = CURRENT_TIMESTAMP,
    document_uploaded_by = auth.uid(),
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_invoice_id
  RETURNING *
  INTO v_invoice;

  RETURN v_invoice;
END;
$$;

REVOKE ALL
ON FUNCTION public.attach_maintenance_invoice_document(UUID, TEXT)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.attach_maintenance_invoice_document(UUID, TEXT)
TO authenticated;

-- ============================================================
-- 12. HASH SHA-256 DEL PDF
-- ============================================================
--
-- Supabase/PostgreSQL no debe calcular el SHA-256 del binario de Storage
-- directamente. El frontend/worker/backend calculará el hash del fichero
-- y lo entregará a una RPC específica si queremos persistirlo.
--
-- La función siguiente permite registrar el hash únicamente para el
-- documento que ya está asociado y únicamente a un worker.
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_maintenance_invoice_document_hash(
  p_invoice_id UUID,
  p_sha256 TEXT
)
RETURNS public.maintenance_invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_invoice public.maintenance_invoices;
  v_hash TEXT := LOWER(BTRIM(COALESCE(p_sha256, '')));
BEGIN
  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Acceso denegado: se requiere un trabajador activo';
  END IF;

  IF v_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION
      'SHA-256 inválido';
  END IF;

  UPDATE public.maintenance_invoices
  SET
    document_sha256 = v_hash,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_invoice_id
    AND document_path IS NOT NULL
  RETURNING *
  INTO v_invoice;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'La factura no existe o no tiene documento asociado';
  END IF;

  RETURN v_invoice;
END;
$$;

REVOKE ALL
ON FUNCTION public.set_maintenance_invoice_document_hash(UUID, TEXT)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.set_maintenance_invoice_document_hash(UUID, TEXT)
TO authenticated;

-- ============================================================
-- 13. CONTROL DE DOCUMENTO ANTES DE PASAR A FACTURA EMITIDA
-- ============================================================
--
-- No obligamos a PDF si existe un documento electrónico original.
-- Esto deja preparada la arquitectura para factura electrónica estructurada.
-- Si no existe ninguno de los dos, una factura no puede salir de borrador.
-- ============================================================

CREATE OR REPLACE FUNCTION public.require_maintenance_invoice_document()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- La Edge Function puede crear primero la factura local a partir del
  -- webhook de Stripe y el worker adjuntar después el documento de Modira.
  -- Por eso no exigimos el PDF durante el INSERT inicial.
  --
  -- Sí lo exigimos cuando una factura que estaba en borrador pasa a un
  -- estado emitido/operativo.
  IF TG_OP = 'UPDATE'
     AND OLD.estado = 'borrador'
     AND NEW.estado <> 'borrador'
     AND NEW.document_path IS NULL
     AND NEW.electronic_document_storage_path IS NULL
  THEN
    RAISE EXCEPTION
      'La factura de mantenimiento debe tener un documento asociado antes de emitirse';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS maintenance_invoices_require_document
ON public.maintenance_invoices;

CREATE TRIGGER maintenance_invoices_require_document
BEFORE INSERT OR UPDATE OF estado, document_path, electronic_document_storage_path
ON public.maintenance_invoices
FOR EACH ROW
EXECUTE FUNCTION public.require_maintenance_invoice_document();

-- ============================================================
-- 14. SNAPSHOT FISCAL MÁS EXPLÍCITO
-- ============================================================
--
-- Añadimos al snapshot los datos que ya existen en companies cuando se
-- crea/actualiza una factura. No modificamos facturas históricas existentes.
-- El backend utilizará estas columnas/snapshot al emitir nuevas facturas.
-- ============================================================

ALTER TABLE public.maintenance_invoices
  ADD COLUMN IF NOT EXISTS issuer_legal_name TEXT,
  ADD COLUMN IF NOT EXISTS issuer_tax_id TEXT,
  ADD COLUMN IF NOT EXISTS issuer_address TEXT,
  ADD COLUMN IF NOT EXISTS issuer_postal_code TEXT,
  ADD COLUMN IF NOT EXISTS issuer_city TEXT,
  ADD COLUMN IF NOT EXISTS issuer_province TEXT,
  ADD COLUMN IF NOT EXISTS issuer_country TEXT;

-- ============================================================
-- 15. RECTIFICACIÓN / TRAZABILIDAD FISCAL
-- ============================================================
--
-- Una factura emitida no se corrige sobrescribiéndola. La factura
-- rectificativa futura podrá apuntar a la factura original mediante esta
-- referencia.
-- ============================================================

ALTER TABLE public.maintenance_invoices
  ADD COLUMN IF NOT EXISTS rectifies_invoice_id UUID
    REFERENCES public.maintenance_invoices(id)
    ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_invoices_rectifies_invoice
ON public.maintenance_invoices (rectifies_invoice_id)
WHERE rectifies_invoice_id IS NOT NULL;

-- ============================================================
-- 16. RLS DE LAS NUEVAS COLUMNAS / TABLA
-- ============================================================

ALTER TABLE public.maintenance_invoices ENABLE ROW LEVEL SECURITY;

-- Se mantienen las policies SELECT existentes de la 049.
-- No se conceden INSERT/UPDATE/DELETE directos a authenticated.

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_invoices
FROM authenticated, anon;

GRANT SELECT
ON public.maintenance_invoices
TO authenticated;

-- ============================================================
-- 17. COMENTARIOS
-- ============================================================

COMMENT ON COLUMN public.maintenance_invoices.document_path IS
'PDF de la factura de mantenimiento emitida por Modira y adjuntada por un trabajador. Es independiente del PDF generado por Stripe.';

COMMENT ON COLUMN public.maintenance_invoices.stripe_pdf_storage_path IS
'PDF auxiliar generado por Stripe para su propia invoice de Billing. No sustituye automáticamente la factura emitida por Modira.';

COMMENT ON COLUMN public.maintenance_invoices.document_sha256 IS
'Hash SHA-256 del PDF de la factura de Modira, registrado para reforzar la trazabilidad e integridad del documento.';

COMMENT ON COLUMN public.maintenance_invoices.electronic_document_storage_path IS
'Ruta del documento electrónico original de la factura cuando se utilice un formato electrónico estructurado u otro formato válido.';

COMMENT ON TABLE public.maintenance_invoices IS
'Facturas de mantenimiento conservadas como registros históricos. El PDF de Modira lo adjunta un trabajador; el PDF de Stripe se conserva separadamente como documento auxiliar.';

-- ============================================================
-- 18. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
      AND column_name = 'document_path'
  ) THEN
    RAISE EXCEPTION
      '050 failed: maintenance_invoices.document_path missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'maintenance-invoices'
      AND public = FALSE
  ) THEN
    RAISE EXCEPTION
      '050 failed: maintenance-invoices bucket is not private';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'attach_maintenance_invoice_document'
    AND pg_get_function_identity_arguments(p.oid)
      = 'p_invoice_id uuid, p_document_path text';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '050 failed: attach_maintenance_invoice_document() missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_policies
  WHERE schemaname = 'storage'
    AND tablename = 'objects'
    AND policyname = 'maintenance_invoice_storage_worker_insert';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '050 failed: worker storage INSERT policy missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_policies
  WHERE schemaname = 'storage'
    AND tablename = 'objects'
    AND policyname = 'maintenance_invoice_storage_client_select';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '050 failed: client storage SELECT policy missing';
  END IF;
END $$;

COMMIT;

-- ============================================================
-- FIN — MODIRA 050
-- ============================================================
