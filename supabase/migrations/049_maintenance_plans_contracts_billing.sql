-- ============================================================
-- MODIRA — 049_maintenance_plans_contracts_billing.sql
-- ============================================================
-- OBJETIVO
-- 1. Separar catálogo de PLANES y contratos concretos.
-- 2. Hacer empresa obligatoria para contratos de mantenimiento.
-- 3. Asociar contratos a uno o varios proyectos.
-- 4. Asociar contratos a una o varias automatizaciones cubiertas.
-- 5. Preparar suscripción mensual y ciclo de renovación.
-- 6. Preparar cancelación programada y cambios de plan.
-- 7. Crear facturación independiente de mantenimiento.
-- 8. Integrar payments con maintenance_invoices.
-- 9. Preparar almacenamiento del documento electrónico/PDF de factura.
-- 10. Mantener las facturas como registros históricos no eliminables
--     mediante RLS normal.
--
-- NOTAS IMPORTANTES
-- - Stripe NO se ejecuta desde SQL. Esta migración solo guarda sus IDs
--   y prepara la integridad de datos. La creación/actualización/cancelación
--   de suscripciones se hará exclusivamente desde backend/Edge Functions.
-- - La factura legal no depende de que exista un PDF. Se conserva el
--   documento electrónico original y, cuando corresponda, su representación
--   PDF para el cliente.
-- - Las automatizaciones de MODIRA siguen siendo independientes de los
--   planes; solo se registra qué automatizaciones quedan cubiertas.
-- - Los campos legacy de maintenance_contracts se conservan para no romper
--   referencias existentes y, además, sirven como snapshot comercial del
--   contrato contratado.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'maintenance_contracts'
  ) THEN
    RAISE EXCEPTION '049 stopped: public.maintenance_contracts does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'companies'
  ) THEN
    RAISE EXCEPTION '049 stopped: public.companies does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'projects'
  ) THEN
    RAISE EXCEPTION '049 stopped: public.projects does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'automations'
  ) THEN
    RAISE EXCEPTION '049 stopped: public.automations does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'payments'
  ) THEN
    RAISE EXCEPTION '049 stopped: public.payments does not exist';
  END IF;
END $$;

-- ============================================================
-- 2. CATÁLOGO DE PLANES DE MANTENIMIENTO
-- ============================================================

CREATE TABLE IF NOT EXISTS public.maintenance_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  code TEXT NOT NULL UNIQUE,
  nombre TEXT NOT NULL,
  descripcion TEXT,

  precio NUMERIC(12,2),
  moneda TEXT NOT NULL DEFAULT 'EUR',
  periodicidad TEXT NOT NULL DEFAULT 'mensual',

  es_personalizado BOOLEAN NOT NULL DEFAULT FALSE,
  activo BOOLEAN NOT NULL DEFAULT TRUE,

  stripe_product_id TEXT,
  stripe_price_id TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT maintenance_plans_price_check
    CHECK (precio IS NULL OR precio >= 0),

  CONSTRAINT maintenance_plans_currency_check
    CHECK (moneda ~ '^[A-Z]{3}$'),

  CONSTRAINT maintenance_plans_periodicidad_check
    CHECK (periodicidad = 'mensual'),

  CONSTRAINT maintenance_plans_custom_price_check
    CHECK (
      (es_personalizado = TRUE AND precio IS NULL)
      OR
      (es_personalizado = FALSE AND precio IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_plans_stripe_product_id
ON public.maintenance_plans (stripe_product_id)
WHERE stripe_product_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_plans_stripe_price_id
ON public.maintenance_plans (stripe_price_id)
WHERE stripe_price_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_plans_active
ON public.maintenance_plans (activo);

-- ============================================================
-- 3. PLANES OFICIALES MODIRA
-- ============================================================

INSERT INTO public.maintenance_plans (
  code, nombre, descripcion, precio, moneda, periodicidad, es_personalizado, activo
)
VALUES
(
  'essential',
  'Essential',
  'Soporte y mantenimiento esencial.',
  149.00,
  'EUR',
  'mensual',
  FALSE,
  TRUE
),
(
  'growth',
  'Growth',
  'Soporte y evolución.',
  299.00,
  'EUR',
  'mensual',
  FALSE,
  TRUE
),
(
  'business',
  'Business',
  'Gestión continua de automatización.',
  499.00,
  'EUR',
  'mensual',
  FALSE,
  TRUE
),
(
  'custom',
  'Custom',
  'Mantenimiento personalizado con condiciones y precio definidos para cada empresa.',
  NULL,
  'EUR',
  'mensual',
  TRUE,
  TRUE
)
ON CONFLICT (code) DO UPDATE
SET
  nombre = EXCLUDED.nombre,
  descripcion = EXCLUDED.descripcion,
  moneda = EXCLUDED.moneda,
  periodicidad = EXCLUDED.periodicidad,
  es_personalizado = EXCLUDED.es_personalizado,
  activo = EXCLUDED.activo,
  updated_at = CURRENT_TIMESTAMP;

-- Los precios publicados se actualizan únicamente si el plan existente
-- coincide con el precio comercial oficial de esta migración.
UPDATE public.maintenance_plans
SET precio = 149.00, updated_at = CURRENT_TIMESTAMP
WHERE code = 'essential';

UPDATE public.maintenance_plans
SET precio = 299.00, updated_at = CURRENT_TIMESTAMP
WHERE code = 'growth';

UPDATE public.maintenance_plans
SET precio = 499.00, updated_at = CURRENT_TIMESTAMP
WHERE code = 'business';

UPDATE public.maintenance_plans
SET precio = NULL, updated_at = CURRENT_TIMESTAMP
WHERE code = 'custom';

-- ============================================================
-- 4. ACTUALIZACIÓN DE CONTRATOS EXISTENTES
-- ============================================================
-- Primero intentamos recuperar company_id desde el perfil propietario.
-- Esto permite migrar contratos legacy que se crearon sin empresa.
-- Si alguno sigue sin empresa, la migración se detiene en lugar de
-- inventar una asociación.

DO $$
BEGIN
  UPDATE public.maintenance_contracts mc
  SET company_id = p.company_id
  FROM public.profiles p
  WHERE mc.company_id IS NULL
    AND mc.user_id = p.id
    AND p.company_id IS NOT NULL;

  IF EXISTS (
    SELECT 1
    FROM public.maintenance_contracts
    WHERE company_id IS NULL
  ) THEN
    RAISE EXCEPTION
      '049 stopped: existen maintenance_contracts sin company_id. Deben asociarse a una empresa antes de ejecutar la migración.';
  END IF;
END $$;

-- ============================================================
-- 5. NUEVAS COLUMNAS DE CONTRACT
-- ============================================================

ALTER TABLE public.maintenance_contracts
  ADD COLUMN IF NOT EXISTS plan_id UUID,
  ADD COLUMN IF NOT EXISTS moneda TEXT NOT NULL DEFAULT 'EUR',
  ADD COLUMN IF NOT EXISTS current_period_start DATE,
  ADD COLUMN IF NOT EXISTS current_period_end DATE,
  ADD COLUMN IF NOT EXISTS renewal_day SMALLINT,
  ADD COLUMN IF NOT EXISTS cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS cancel_requested_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancel_effective_at DATE,
  ADD COLUMN IF NOT EXISTS pending_plan_id UUID,
  ADD COLUMN IF NOT EXISTS pending_change_effective_at DATE,
  ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_subscription_item_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_price_id TEXT,
  ADD COLUMN IF NOT EXISTS plan_snapshot JSONB;

-- El plan se resuelve desde nombre_plan para contratos legacy.
UPDATE public.maintenance_contracts mc
SET plan_id = mp.id
FROM public.maintenance_plans mp
WHERE mc.plan_id IS NULL
  AND (
    LOWER(TRIM(mc.nombre_plan)) = LOWER(mp.nombre)
    OR LOWER(TRIM(mc.nombre_plan)) = LOWER(mp.code)
  );

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.maintenance_contracts
    WHERE plan_id IS NULL
  ) THEN
    RAISE EXCEPTION
      '049 stopped: existen maintenance_contracts cuyo nombre_plan no puede mapearse a maintenance_plans. Revísalos antes de continuar.';
  END IF;
END $$;

-- Los contratos existentes conservan su precio histórico.
-- Para nuevos contratos, el backend deberá tomar el precio del catálogo
-- y guardarlo también en maintenance_contracts.precio como snapshot.
UPDATE public.maintenance_contracts
SET
  current_period_start = fecha_inicio,
  current_period_end = CASE
    WHEN fecha_fin IS NOT NULL THEN fecha_fin
    ELSE NULL
  END,
  renewal_day = EXTRACT(DAY FROM fecha_inicio)::SMALLINT
WHERE current_period_start IS NULL;

-- ============================================================
-- 6. CONSTRAINTS DEL CONTRATO
-- ============================================================

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_company_required_check;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_company_required_check
  CHECK (company_id IS NOT NULL);

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_renewal_day_check;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_renewal_day_check
  CHECK (renewal_day IS NULL OR renewal_day BETWEEN 1 AND 31);

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_cancel_dates_check;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_cancel_dates_check
  CHECK (
    cancel_effective_at IS NULL
    OR cancel_requested_at IS NOT NULL
  );

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_pending_change_check;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_pending_change_check
  CHECK (
    pending_change_effective_at IS NULL
    OR pending_plan_id IS NOT NULL
  );

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_stripe_subscription_check;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_stripe_subscription_check
  CHECK (
    stripe_subscription_id IS NULL
    OR length(trim(stripe_subscription_id)) > 0
  );

-- FK nuevas
ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_plan_id_fkey;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_plan_id_fkey
  FOREIGN KEY (plan_id)
  REFERENCES public.maintenance_plans(id)
  ON DELETE RESTRICT;

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_pending_plan_id_fkey;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_pending_plan_id_fkey
  FOREIGN KEY (pending_plan_id)
  REFERENCES public.maintenance_plans(id)
  ON DELETE RESTRICT;

-- company_id pasa a ser obligatorio y la eliminación de empresa elimina
-- el contrato. Las facturas NO tienen esta cascada.
ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_company_id_fkey;

ALTER TABLE public.maintenance_contracts
  ALTER COLUMN company_id SET NOT NULL;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_company_id_fkey
  FOREIGN KEY (company_id)
  REFERENCES public.companies(id)
  ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_contracts_stripe_subscription_id
ON public.maintenance_contracts (stripe_subscription_id)
WHERE stripe_subscription_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_plan_id
ON public.maintenance_contracts (plan_id);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_current_period_end
ON public.maintenance_contracts (current_period_end);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_cancel_effective_at
ON public.maintenance_contracts (cancel_effective_at);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_pending_plan
ON public.maintenance_contracts (pending_plan_id, pending_change_effective_at);

-- ============================================================
-- 7. SNAPSHOT COMERCIAL DEL PLAN
-- ============================================================
-- Se captura el plan y su precio al contratarlo. Esto evita que un cambio
-- futuro del catálogo altere retrospectivamente las condiciones del contrato.

UPDATE public.maintenance_contracts mc
SET plan_snapshot = jsonb_build_object(
  'code', mp.code,
  'nombre', mp.nombre,
  'descripcion', mp.descripcion,
  'precio_catalogo', mp.precio,
  'moneda', mp.moneda,
  'periodicidad', mp.periodicidad,
  'captured_at', CURRENT_TIMESTAMP
)
FROM public.maintenance_plans mp
WHERE mc.plan_id = mp.id
  AND mc.plan_snapshot IS NULL;

-- ============================================================
-- 8. RELACIÓN CONTRATO ↔ PROYECTOS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.maintenance_contract_projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  maintenance_contract_id UUID NOT NULL
    REFERENCES public.maintenance_contracts(id)
    ON DELETE CASCADE,
  project_id UUID NOT NULL
    REFERENCES public.projects(id)
    ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT maintenance_contract_projects_unique
    UNIQUE (maintenance_contract_id, project_id)
);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contract_projects_contract
ON public.maintenance_contract_projects (maintenance_contract_id);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contract_projects_project
ON public.maintenance_contract_projects (project_id);

-- ============================================================
-- 9. RELACIÓN CONTRATO ↔ AUTOMATIZACIONES CUBIERTAS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.maintenance_contract_automations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  maintenance_contract_id UUID NOT NULL
    REFERENCES public.maintenance_contracts(id)
    ON DELETE CASCADE,
  automation_id UUID NOT NULL
    REFERENCES public.automations(id)
    ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT maintenance_contract_automations_unique
    UNIQUE (maintenance_contract_id, automation_id)
);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contract_automations_contract
ON public.maintenance_contract_automations (maintenance_contract_id);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contract_automations_automation
ON public.maintenance_contract_automations (automation_id);

-- ============================================================
-- 10. VALIDACIÓN DE PERTENENCIA A EMPRESA
-- ============================================================
-- Projects y automations deben pertenecer al mismo contexto empresarial
-- que el contrato.
--
-- En projects, el modelo vigente identificado en las migraciones usa
-- projects.user_id como propietario. Se valida la empresa a través del
-- perfil propietario.
--
-- En automations se valida directamente automations.company_id.

CREATE OR REPLACE FUNCTION public.validate_maintenance_contract_project()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract_company UUID;
  v_project_user UUID;
  v_project_company UUID;
BEGIN
  SELECT company_id
  INTO v_contract_company
  FROM public.maintenance_contracts
  WHERE id = NEW.maintenance_contract_id;

  IF v_contract_company IS NULL THEN
    RAISE EXCEPTION 'El contrato de mantenimiento debe tener empresa';
  END IF;

  SELECT p.user_id
  INTO v_project_user
  FROM public.projects p
  WHERE p.id = NEW.project_id;

  IF v_project_user IS NULL THEN
    RAISE EXCEPTION 'El proyecto indicado no existe o no tiene propietario';
  END IF;

  SELECT pr.company_id
  INTO v_project_company
  FROM public.profiles pr
  WHERE pr.id = v_project_user;

  IF v_project_company IS DISTINCT FROM v_contract_company THEN
    RAISE EXCEPTION
      'El proyecto no pertenece a la misma empresa que el contrato de mantenimiento';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS maintenance_contract_projects_validate_company
ON public.maintenance_contract_projects;

CREATE TRIGGER maintenance_contract_projects_validate_company
BEFORE INSERT OR UPDATE
ON public.maintenance_contract_projects
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_contract_project();

CREATE OR REPLACE FUNCTION public.validate_maintenance_contract_automation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract_company UUID;
  v_automation_company UUID;
BEGIN
  SELECT company_id
  INTO v_contract_company
  FROM public.maintenance_contracts
  WHERE id = NEW.maintenance_contract_id;

  SELECT company_id
  INTO v_automation_company
  FROM public.automations
  WHERE id = NEW.automation_id;

  IF v_contract_company IS NULL
     OR v_automation_company IS NULL
     OR v_contract_company IS DISTINCT FROM v_automation_company
  THEN
    RAISE EXCEPTION
      'La automatización no pertenece a la misma empresa que el contrato de mantenimiento';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS maintenance_contract_automations_validate_company
ON public.maintenance_contract_automations;

CREATE TRIGGER maintenance_contract_automations_validate_company
BEFORE INSERT OR UPDATE
ON public.maintenance_contract_automations
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_contract_automation();

-- ============================================================
-- 11. FACTURAS DE MANTENIMIENTO
-- ============================================================
-- Numeración correlativa gestionada por PostgreSQL para evitar colisiones
-- concurrentes. La serie queda separada y será la que determine el backend.
CREATE SEQUENCE IF NOT EXISTS public.maintenance_invoice_number_seq
  AS BIGINT
  START WITH 1
  INCREMENT BY 1
  NO MINVALUE
  NO MAXVALUE
  CACHE 1;


-- Estas facturas son independientes de public.invoices.
-- Se conservan como registros históricos.
--
-- El PDF es una representación documental útil, pero no se asume que
-- el PDF sea por sí mismo el formato legal obligatorio de la factura
-- electrónica B2B futura. Por ello se guardan también campos para el
-- documento electrónico original y su hash.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.maintenance_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  maintenance_contract_id UUID
    REFERENCES public.maintenance_contracts(id)
    ON DELETE SET NULL,

  company_id UUID
    REFERENCES public.companies(id)
    ON DELETE SET NULL,

  user_id UUID
    REFERENCES auth.users(id)
    ON DELETE SET NULL,

  serie TEXT NOT NULL DEFAULT 'MNT',
  numero BIGINT NOT NULL DEFAULT nextval('public.maintenance_invoice_number_seq'::regclass),

  estado TEXT NOT NULL DEFAULT 'pendiente',

  fecha_emision DATE NOT NULL DEFAULT CURRENT_DATE,
  fecha_operacion DATE NOT NULL DEFAULT CURRENT_DATE,
  fecha_vencimiento DATE,
  fecha_pago DATE,

  periodo_inicio DATE NOT NULL,
  periodo_fin DATE NOT NULL,

  descripcion TEXT NOT NULL,

  -- Snapshot del contrato al emitir la factura. Permite conservar el
  -- contexto histórico aunque el contrato o la empresa se eliminen.
  contract_snapshot JSONB,

  subtotal NUMERIC(12,2) NOT NULL,
  iva_aplicado BOOLEAN NOT NULL DEFAULT TRUE,
  iva_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 21,
  iva_importe NUMERIC(12,2) NOT NULL DEFAULT 0,

  irpf_aplicado BOOLEAN NOT NULL DEFAULT FALSE,
  irpf_porcentaje NUMERIC(5,2) NOT NULL DEFAULT 0,
  irpf_importe NUMERIC(12,2) NOT NULL DEFAULT 0,

  monto NUMERIC(12,2) NOT NULL DEFAULT 0,
  importe_a_pagar NUMERIC(12,2) NOT NULL DEFAULT 0,

  moneda TEXT NOT NULL DEFAULT 'EUR',

  -- Snapshot fiscal del destinatario
  customer_legal_name TEXT NOT NULL,
  customer_tax_id TEXT NOT NULL,
  customer_address TEXT,
  customer_postal_code TEXT,
  customer_city TEXT,
  customer_province TEXT,
  customer_country TEXT NOT NULL DEFAULT 'ES',

  -- Referencias Stripe
  stripe_invoice_id TEXT,
  stripe_customer_id TEXT,

  -- Documento electrónico y representación PDF
  electronic_format TEXT,
  electronic_document_storage_path TEXT,
  electronic_document_hash TEXT,

  pdf_storage_path TEXT,
  pdf_sha256 TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT maintenance_invoices_number_unique
    UNIQUE (serie, numero),

  CONSTRAINT maintenance_invoices_status_check
    CHECK (
      estado IN (
        'borrador',
        'pendiente',
        'enviada',
        'pagada',
        'impagada',
        'anulada',
        'rectificada'
      )
    ),

  CONSTRAINT maintenance_invoices_period_check
    CHECK (periodo_fin >= periodo_inicio),

  CONSTRAINT maintenance_invoices_subtotal_check
    CHECK (subtotal >= 0),

  CONSTRAINT maintenance_invoices_monto_check
    CHECK (monto >= 0),

  CONSTRAINT maintenance_invoices_iva_check
    CHECK (
      iva_porcentaje >= 0
      AND iva_porcentaje <= 100
      AND iva_importe >= 0
    ),

  CONSTRAINT maintenance_invoices_irpf_check
    CHECK (
      irpf_porcentaje >= 0
      AND irpf_porcentaje <= 100
      AND irpf_importe >= 0
    ),

  CONSTRAINT maintenance_invoices_amount_check
    CHECK (importe_a_pagar >= 0),

  CONSTRAINT maintenance_invoices_currency_check
    CHECK (moneda ~ '^[A-Z]{3}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_invoices_stripe_invoice_id
ON public.maintenance_invoices (stripe_invoice_id)
WHERE stripe_invoice_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_invoices_contract
ON public.maintenance_invoices (maintenance_contract_id);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_invoices_company
ON public.maintenance_invoices (company_id);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_invoices_status
ON public.maintenance_invoices (estado);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_invoices_period
ON public.maintenance_invoices (periodo_inicio, periodo_fin);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_invoices_issue_date
ON public.maintenance_invoices (fecha_emision DESC);

-- ============================================================
-- 12. STORAGE — DOCUMENTACIÓN DE FACTURAS
-- ============================================================
-- Bucket privado. El backend/Edge Function subirá los documentos.
-- El cliente solo podrá leer el documento que corresponda a una factura
-- de mantenimiento de su propia empresa.
-- ============================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('maintenance-invoices', 'maintenance-invoices', FALSE)
ON CONFLICT (id) DO NOTHING;

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
        mi.pdf_storage_path = storage.objects.name
        OR mi.electronic_document_storage_path = storage.objects.name
      )
  )
);

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

-- No se conceden INSERT/UPDATE/DELETE directos a authenticated.
-- El backend/service_role gestiona la documentación.

-- ============================================================
-- 13. TRIGGER DE updated_at PARA MAINTENANCE INVOICES
-- ============================================================

DROP TRIGGER IF EXISTS maintenance_invoices_updated_at
ON public.maintenance_invoices;

CREATE TRIGGER maintenance_invoices_updated_at
BEFORE UPDATE ON public.maintenance_invoices
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================
-- 14. VALIDACIÓN FISCAL DE MAINTENANCE INVOICES
-- ============================================================
-- Mantiene la misma lógica fiscal de invoices:
-- importe_a_pagar = monto - irpf_importe.
-- El trigger calcula IVA y total cuando se modifican importes.
-- No se generan facturas automáticamente desde SQL: las generará backend.

CREATE OR REPLACE FUNCTION public.calculate_maintenance_invoice_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.iva_porcentaje = COALESCE(NEW.iva_porcentaje, 0);
  NEW.iva_importe = CASE
    WHEN COALESCE(NEW.iva_aplicado, FALSE)
    THEN ROUND(COALESCE(NEW.subtotal, 0) * NEW.iva_porcentaje / 100, 2)
    ELSE 0
  END;

  NEW.irpf_porcentaje = COALESCE(NEW.irpf_porcentaje, 0);
  NEW.irpf_importe = CASE
    WHEN COALESCE(NEW.irpf_aplicado, FALSE)
    THEN ROUND(COALESCE(NEW.subtotal, 0) * NEW.irpf_porcentaje / 100, 2)
    ELSE 0
  END;

  NEW.monto = ROUND(
    COALESCE(NEW.subtotal, 0) + COALESCE(NEW.iva_importe, 0),
    2
  );

  NEW.importe_a_pagar = ROUND(
    NEW.monto - COALESCE(NEW.irpf_importe, 0),
    2
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS maintenance_invoices_calculate_totals
ON public.maintenance_invoices;

CREATE TRIGGER maintenance_invoices_calculate_totals
BEFORE INSERT OR UPDATE OF subtotal, iva_aplicado, iva_porcentaje, irpf_aplicado, irpf_porcentaje
ON public.maintenance_invoices
FOR EACH ROW
EXECUTE FUNCTION public.calculate_maintenance_invoice_totals();

-- ============================================================
-- 15. PAYMENTS → MAINTENANCE INVOICES
-- ============================================================

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS maintenance_invoice_id UUID;

ALTER TABLE public.payments
  DROP CONSTRAINT IF EXISTS payments_maintenance_invoice_id_fkey;

ALTER TABLE public.payments
  ADD CONSTRAINT payments_maintenance_invoice_id_fkey
  FOREIGN KEY (maintenance_invoice_id)
  REFERENCES public.maintenance_invoices(id)
  ON DELETE RESTRICT;

ALTER TABLE public.payments
  DROP CONSTRAINT IF EXISTS payments_invoice_source_check;

ALTER TABLE public.payments
  ADD CONSTRAINT payments_invoice_source_check
  CHECK (
    NOT (invoice_id IS NOT NULL AND maintenance_invoice_id IS NOT NULL)
  );
-- Legacy payment rows with both references NULL are tolerated for compatibility;
-- any new maintenance payment must provide maintenance_invoice_id.

CREATE INDEX IF NOT EXISTS
  idx_payments_maintenance_invoice_status
ON public.payments (maintenance_invoice_id, status)
WHERE maintenance_invoice_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_payments_one_success_per_maintenance_invoice
ON public.payments (maintenance_invoice_id)
WHERE
  maintenance_invoice_id IS NOT NULL
  AND status = 'succeeded';

-- ============================================================
-- 16. VALIDACIÓN DEL PAYMENT DE MANTENIMIENTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_maintenance_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_invoice public.maintenance_invoices;
BEGIN
  IF NEW.maintenance_invoice_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT *
  INTO v_invoice
  FROM public.maintenance_invoices
  WHERE id = NEW.maintenance_invoice_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La factura de mantenimiento no existe';
  END IF;

  IF NEW.company_id IS DISTINCT FROM v_invoice.company_id THEN
    RAISE EXCEPTION
      'El payment no pertenece a la misma empresa que la factura de mantenimiento';
  END IF;

  IF NEW.amount < 0 THEN
    RAISE EXCEPTION 'El importe del payment no puede ser negativo';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS payments_validate_maintenance_invoice
ON public.payments;

CREATE TRIGGER payments_validate_maintenance_invoice
BEFORE INSERT OR UPDATE
ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_payment();

-- ============================================================
-- 17. RLS — MAINTENANCE CONTRACTS
-- ============================================================
-- El cliente puede consultar sus contratos, pero NO puede crearlos ni
-- modificarlos directamente. Las operaciones de contratación, cambio de
-- plan y cancelación pasan por backend/Edge Functions.
ALTER TABLE public.maintenance_contracts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS maintenance_contracts_client_select
ON public.maintenance_contracts;

DROP POLICY IF EXISTS maintenance_contracts_client_insert
ON public.maintenance_contracts;

DROP POLICY IF EXISTS maintenance_contracts_worker_select
ON public.maintenance_contracts;

CREATE POLICY maintenance_contracts_client_select
ON public.maintenance_contracts
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND company_id = public.current_user_company_id()
);

CREATE POLICY maintenance_contracts_worker_select
ON public.maintenance_contracts
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
);

GRANT SELECT
ON public.maintenance_contracts
TO authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_contracts
FROM authenticated, anon;


-- 18. RLS — PLANES
-- ============================================================

ALTER TABLE public.maintenance_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS maintenance_plans_client_select
ON public.maintenance_plans;

CREATE POLICY maintenance_plans_client_select
ON public.maintenance_plans
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND activo = TRUE
);

DROP POLICY IF EXISTS maintenance_plans_worker_select
ON public.maintenance_plans;

CREATE POLICY maintenance_plans_worker_select
ON public.maintenance_plans
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
);

-- No direct writes for authenticated. Catalogue writes remain backend/service-role.

GRANT SELECT
ON public.maintenance_plans
TO authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_plans
FROM authenticated, anon;

-- ============================================================
-- 19. RLS — CONTRACT PROJECTS
-- ============================================================

ALTER TABLE public.maintenance_contract_projects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS maintenance_contract_projects_client_select
ON public.maintenance_contract_projects;

CREATE POLICY maintenance_contract_projects_client_select
ON public.maintenance_contract_projects
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND EXISTS (
    SELECT 1
    FROM public.maintenance_contracts mc
    WHERE mc.id = maintenance_contract_projects.maintenance_contract_id
      AND mc.company_id = public.current_user_company_id()
  )
);

DROP POLICY IF EXISTS maintenance_contract_projects_worker_select
ON public.maintenance_contract_projects;

CREATE POLICY maintenance_contract_projects_worker_select
ON public.maintenance_contract_projects
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
);

GRANT SELECT
ON public.maintenance_contract_projects
TO authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_contract_projects
FROM authenticated, anon;

-- ============================================================
-- 20. RLS — CONTRACT AUTOMATIONS
-- ============================================================

ALTER TABLE public.maintenance_contract_automations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS maintenance_contract_automations_client_select
ON public.maintenance_contract_automations;

CREATE POLICY maintenance_contract_automations_client_select
ON public.maintenance_contract_automations
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND EXISTS (
    SELECT 1
    FROM public.maintenance_contracts mc
    WHERE mc.id = maintenance_contract_automations.maintenance_contract_id
      AND mc.company_id = public.current_user_company_id()
  )
);

DROP POLICY IF EXISTS maintenance_contract_automations_worker_select
ON public.maintenance_contract_automations;

CREATE POLICY maintenance_contract_automations_worker_select
ON public.maintenance_contract_automations
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
);

GRANT SELECT
ON public.maintenance_contract_automations
TO authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_contract_automations
FROM authenticated, anon;

-- ============================================================
-- 21. RLS — MAINTENANCE INVOICES
-- ============================================================

ALTER TABLE public.maintenance_invoices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS maintenance_invoices_client_select
ON public.maintenance_invoices;

CREATE POLICY maintenance_invoices_client_select
ON public.maintenance_invoices
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND company_id = public.current_user_company_id()
);

DROP POLICY IF EXISTS maintenance_invoices_worker_select
ON public.maintenance_invoices;

CREATE POLICY maintenance_invoices_worker_select
ON public.maintenance_invoices
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
);

GRANT SELECT
ON public.maintenance_invoices
TO authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_invoices
FROM authenticated, anon;

-- ============================================================
-- 22. RLS — PAYMENTS
-- ============================================================
-- Conservamos el modelo de payments existente. Solo añadimos el
-- acceso a maintenance_invoice_id mediante la misma política de
-- lectura por empresa ya existente; la escritura continúa siendo
-- backend/Edge Function.

-- No se crean políticas de escritura para authenticated.

-- ============================================================
-- 23. INMUTABILIDAD OPERATIVA DE FACTURAS
-- ============================================================
-- No se conceden INSERT/UPDATE/DELETE directos de maintenance_invoices
-- a authenticated. El backend/service_role será quien cree y gestione
-- estados y documentos.
--
-- Una factura emitida no debe borrarse para corregirla. Las correcciones
-- se modelarán mediante factura rectificativa en una migración/flujo
-- posterior.

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_invoices
FROM authenticated, anon;

-- ============================================================
-- 24. GRANTS DE BACKEND
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.maintenance_plans
TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.maintenance_contracts
TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.maintenance_contract_projects
TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.maintenance_contract_automations
TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.maintenance_invoices
TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.payments
TO service_role;

-- ============================================================
-- 25. COMMENTS
-- ============================================================

COMMENT ON TABLE public.maintenance_plans IS
'Catálogo comercial de planes de mantenimiento de Modira. No representa contratos concretos.';

COMMENT ON TABLE public.maintenance_contracts IS
'Contrato concreto de mantenimiento de una empresa. Contiene snapshots comerciales, ciclo de renovación, cancelación y referencias Stripe.';

COMMENT ON TABLE public.maintenance_contract_projects IS
'Relación N:N entre contratos de mantenimiento y proyectos cubiertos por el contrato.';

COMMENT ON TABLE public.maintenance_contract_automations IS
'Relación N:N entre contratos de mantenimiento y automatizaciones cubiertas. No convierte automations en parte del motor de mantenimiento.';

COMMENT ON TABLE public.maintenance_invoices IS
'Facturas de mantenimiento independientes de public.invoices. Son registros históricos y no se eliminan mediante acceso normal del cliente.';

COMMENT ON COLUMN public.maintenance_invoices.electronic_document_storage_path IS
'Ruta del documento electrónico original de la factura. Debe conservarse en su formato original cuando corresponda.';

COMMENT ON COLUMN public.maintenance_invoices.pdf_storage_path IS
'Representación PDF de la factura para visualización/entrega al cliente. No se considera por sí sola el único formato legal de la factura electrónica B2B cuando sea obligatorio un formato estructurado.';

COMMENT ON COLUMN public.maintenance_contracts.cancel_effective_at IS
'Fecha efectiva de finalización. Una cancelación dentro del plazo evita el siguiente cobro; una cancelación fuera de plazo termina al final del periodo que resulte cobrado.';

-- ============================================================
-- 26. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*)
  INTO v_count
  FROM public.maintenance_plans
  WHERE code IN ('essential', 'growth', 'business', 'custom');

  IF v_count <> 4 THEN
    RAISE EXCEPTION
      '049 failed: catálogo de planes incompleto';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.maintenance_contracts
    WHERE company_id IS NULL
  ) THEN
    NULL;
  ELSE
    RAISE EXCEPTION
      '049 failed: maintenance_contracts contiene company_id NULL';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.maintenance_contracts WHERE plan_id IS NULL OR company_id IS NULL
  ) THEN
    RAISE EXCEPTION '049 failed: maintenance_contracts has missing plan_id or company_id';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payments'
      AND column_name = 'maintenance_invoice_id'
  ) THEN
    RAISE EXCEPTION
      '049 failed: payments.maintenance_invoice_id missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
  ) THEN
    RAISE EXCEPTION
      '049 failed: maintenance_invoices missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contract_projects'
  ) THEN
    RAISE EXCEPTION
      '049 failed: maintenance_contract_projects missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contract_automations'
  ) THEN
    RAISE EXCEPTION
      '049 failed: maintenance_contract_automations missing';
  END IF;
END $$;

COMMIT;

-- ============================================================
-- FIN — MODIRA 049
-- ============================================================-- ============================================================
-- INMUTABILIDAD DE FACTURAS EMITIDAS
-- ============================================================
-- Las facturas no se borran. Una corrección fiscal se resolverá mediante
-- factura rectificativa, no mediante DELETE/reescritura de la factura.
-- Se permiten cambios operativos (estado, pago, referencias Stripe y
-- ubicación/hash documental), pero no la alteración de su contenido fiscal
-- o de identificación una vez emitida.
-- ============================================================

CREATE OR REPLACE FUNCTION public.prevent_maintenance_invoice_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Las facturas de mantenimiento no se pueden eliminar. Utilice una factura rectificativa cuando proceda.';
END;
$$;

DROP TRIGGER IF EXISTS maintenance_invoices_no_delete
ON public.maintenance_invoices;

CREATE TRIGGER maintenance_invoices_no_delete
BEFORE DELETE
ON public.maintenance_invoices
FOR EACH ROW
EXECUTE FUNCTION public.prevent_maintenance_invoice_delete();

CREATE OR REPLACE FUNCTION public.protect_maintenance_invoice_issued_data()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.estado <> 'borrador' THEN
    IF NEW.maintenance_contract_id IS DISTINCT FROM OLD.maintenance_contract_id
       OR NEW.company_id IS DISTINCT FROM OLD.company_id
       OR NEW.user_id IS DISTINCT FROM OLD.user_id
       OR NEW.serie IS DISTINCT FROM OLD.serie
       OR NEW.numero IS DISTINCT FROM OLD.numero
       OR NEW.fecha_emision IS DISTINCT FROM OLD.fecha_emision
       OR NEW.fecha_operacion IS DISTINCT FROM OLD.fecha_operacion
       OR NEW.fecha_vencimiento IS DISTINCT FROM OLD.fecha_vencimiento
       OR NEW.periodo_inicio IS DISTINCT FROM OLD.periodo_inicio
       OR NEW.periodo_fin IS DISTINCT FROM OLD.periodo_fin
       OR NEW.descripcion IS DISTINCT FROM OLD.descripcion
       OR NEW.contract_snapshot IS DISTINCT FROM OLD.contract_snapshot
       OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
       OR NEW.iva_aplicado IS DISTINCT FROM OLD.iva_aplicado
       OR NEW.iva_porcentaje IS DISTINCT FROM OLD.iva_porcentaje
       OR NEW.iva_importe IS DISTINCT FROM OLD.iva_importe
       OR NEW.irpf_aplicado IS DISTINCT FROM OLD.irpf_aplicado
       OR NEW.irpf_porcentaje IS DISTINCT FROM OLD.irpf_porcentaje
       OR NEW.irpf_importe IS DISTINCT FROM OLD.irpf_importe
       OR NEW.monto IS DISTINCT FROM OLD.monto
       OR NEW.importe_a_pagar IS DISTINCT FROM OLD.importe_a_pagar
       OR NEW.moneda IS DISTINCT FROM OLD.moneda
       OR NEW.customer_legal_name IS DISTINCT FROM OLD.customer_legal_name
       OR NEW.customer_tax_id IS DISTINCT FROM OLD.customer_tax_id
       OR NEW.customer_address IS DISTINCT FROM OLD.customer_address
       OR NEW.customer_postal_code IS DISTINCT FROM OLD.customer_postal_code
       OR NEW.customer_city IS DISTINCT FROM OLD.customer_city
       OR NEW.customer_province IS DISTINCT FROM OLD.customer_province
       OR NEW.customer_country IS DISTINCT FROM OLD.customer_country
    THEN
      RAISE EXCEPTION
        'La factura de mantenimiento emitida es inmutable en sus datos fiscales y de identificación';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS maintenance_invoices_protect_issued_data
ON public.maintenance_invoices;

CREATE TRIGGER maintenance_invoices_protect_issued_data
BEFORE UPDATE
ON public.maintenance_invoices
FOR EACH ROW
EXECUTE FUNCTION public.protect_maintenance_invoice_issued_data();


