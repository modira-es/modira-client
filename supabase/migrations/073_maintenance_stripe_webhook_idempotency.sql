-- ============================================================
-- MODIRA — 073_maintenance_stripe_webhook_idempotency.sql
-- ============================================================
-- OBJETIVO
-- 1. Convertir stripe_webhook_events en una idempotencia con estado real.
-- 2. Evitar que un evento marcado antes de procesarse quede bloqueado
--    para siempre si la Edge Function falla, hace timeout o se reinicia.
-- 3. Permitir que Stripe reintente eventos fallidos.
-- 4. Permitir recuperar automáticamente eventos cuyo estado quedó en
--    "processing" por una ejecución que murió sin ejecutar el catch.
-- 5. Mantener el histórico de eventos y de intentos sin borrar el registro.
--
-- IMPORTANTE
-- - No modifica ni elimina ninguna migración anterior.
-- - Los registros existentes se consideran ya procesados y se migran a
--   status = 'processed', porque antes de esta migración la tabla solo
--   representaba eventos ya reclamados por el sistema anterior.
-- - La Edge Function 073 es la que mueve los eventos nuevos entre
--   processing -> processed / failed.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. VALIDACIÓN
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'stripe_webhook_events'
  ) THEN
    RAISE EXCEPTION
      '073 stopped: public.stripe_webhook_events does not exist';
  END IF;
END $$;

-- ============================================================
-- 2. NUEVOS CAMPOS DE ESTADO / RETRY
-- ============================================================

ALTER TABLE public.stripe_webhook_events
  ADD COLUMN IF NOT EXISTS status TEXT,
  ADD COLUMN IF NOT EXISTS attempt_count INTEGER,
  ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_error TEXT,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;

-- ============================================================
-- 3. MIGRAR FILAS EXISTENTES
-- ============================================================
-- Antes de 073 la existencia del event_id significaba "ya reclamado".
-- Para no reinterpretar históricamente esos eventos como fallidos, los
-- dejamos como processed.

UPDATE public.stripe_webhook_events
SET
  status = COALESCE(status, 'processed'),
  attempt_count = COALESCE(attempt_count, 1),
  processed_at = COALESCE(processed_at, created_at),
  updated_at = COALESCE(updated_at, created_at)
WHERE
  status IS NULL
  OR attempt_count IS NULL
  OR processed_at IS NULL
  OR updated_at IS NULL;

-- ============================================================
-- 4. DEFAULTS + NOT NULL
-- ============================================================

ALTER TABLE public.stripe_webhook_events
  ALTER COLUMN status SET DEFAULT 'processed',
  ALTER COLUMN status SET NOT NULL,
  ALTER COLUMN attempt_count SET DEFAULT 0,
  ALTER COLUMN attempt_count SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP,
  ALTER COLUMN updated_at SET NOT NULL;

-- ============================================================
-- 5. INTEGRIDAD DEL ESTADO
-- ============================================================

ALTER TABLE public.stripe_webhook_events
  DROP CONSTRAINT IF EXISTS stripe_webhook_events_status_check;

ALTER TABLE public.stripe_webhook_events
  ADD CONSTRAINT stripe_webhook_events_status_check
  CHECK (status IN ('processing', 'processed', 'failed'));

ALTER TABLE public.stripe_webhook_events
  DROP CONSTRAINT IF EXISTS stripe_webhook_events_attempt_count_check;

ALTER TABLE public.stripe_webhook_events
  ADD CONSTRAINT stripe_webhook_events_attempt_count_check
  CHECK (attempt_count >= 0);

-- Un evento procesado correctamente no necesita una marca de ejecución
-- activa. Un evento en processing sí debe tenerla.
ALTER TABLE public.stripe_webhook_events
  DROP CONSTRAINT IF EXISTS stripe_webhook_events_processing_state_check;

ALTER TABLE public.stripe_webhook_events
  ADD CONSTRAINT stripe_webhook_events_processing_state_check
  CHECK (
    (status = 'processing' AND processing_started_at IS NOT NULL)
    OR
    (status IN ('processed', 'failed') AND processing_started_at IS NULL)
  );

-- Un evento processed conserva cuándo terminó correctamente.
ALTER TABLE public.stripe_webhook_events
  DROP CONSTRAINT IF EXISTS stripe_webhook_events_processed_state_check;

ALTER TABLE public.stripe_webhook_events
  ADD CONSTRAINT stripe_webhook_events_processed_state_check
  CHECK (
    (status = 'processed' AND processed_at IS NOT NULL)
    OR
    (status IN ('processing', 'failed'))
  );

-- ============================================================
-- 6. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
  idx_stripe_webhook_events_status
ON public.stripe_webhook_events (status);

CREATE INDEX IF NOT EXISTS
  idx_stripe_webhook_events_processing_started_at
ON public.stripe_webhook_events (processing_started_at)
WHERE status = 'processing';

CREATE INDEX IF NOT EXISTS
  idx_stripe_webhook_events_failed
ON public.stripe_webhook_events (updated_at)
WHERE status = 'failed';

-- El índice UNIQUE existente de stripe_event_id se mantiene como la
-- garantía fundamental de idempotencia por evento Stripe.

-- ============================================================
-- 7. VERIFICACIONES FINALES
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'stripe_webhook_events'
      AND column_name = 'status'
      AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION '073 failed: stripe_webhook_events.status no está configurado correctamente';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'stripe_webhook_events'
      AND column_name = 'attempt_count'
      AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION '073 failed: stripe_webhook_events.attempt_count no está configurado correctamente';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'stripe_webhook_events'
      AND c.conname = 'stripe_webhook_events_status_check'
  ) THEN
    RAISE EXCEPTION '073 failed: status check no existe';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.stripe_webhook_events
    WHERE status = 'processing'
      AND processing_started_at IS NULL
  ) THEN
    RAISE EXCEPTION '073 failed: existe un webhook processing sin processing_started_at';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.stripe_webhook_events
    WHERE status = 'processed'
      AND processed_at IS NULL
  ) THEN
    RAISE EXCEPTION '073 failed: existe un webhook processed sin processed_at';
  END IF;
END $$;
GRANT SELECT, INSERT, UPDATE
ON TABLE public.stripe_webhook_events
TO service_role;
DROP INDEX IF EXISTS public.idx_maintenance_contracts_one_live_per_company;
COMMIT;
