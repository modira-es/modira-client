-- ============================================================
-- MODIRA — 068_maintenance_recurring_billing_failure_policy.sql
-- ============================================================
--
-- Complementa 049-067 sin modificar esas migraciones.
--
-- Objetivos:
-- 1. Registrar los fallos consecutivos de cobro de cada contrato.
-- 2. Conservar fecha y motivo del último fallo.
-- 3. Bloquear el cobro automáticamente después de 3 fallos
--    consecutivos mediante la Edge Function.
-- 4. Resetear el contador cuando una factura Stripe se paga.
-- 5. Mantener la política de cobro en base de datos y no solo en código.
--
-- Política operativa:
-- - Stripe sigue siendo la fuente de verdad del estado de la suscripción.
-- - Modira refleja ese estado en maintenance_contracts.estado.
-- - Los fallos se cuentan de forma consecutiva.
-- - Al tercer fallo consecutivo, maintenance-stripe pausa la recaudación
--   Stripe con pause_collection=keep_as_draft y marca el contrato como
--   pausado.
-- - Un pago posterior reinicia el contador y permite reanudar la
--   recaudación si los datos fiscales actuales son válidos.
-- - Una pausa fiscal sigue siendo independiente y NO se elimina
--   automáticamente por un pago.
--
-- Es idempotente.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. ESTADO DE FALLOS DE COBRO EN EL CONTRATO
-- ============================================================

ALTER TABLE public.maintenance_contracts
  ADD COLUMN IF NOT EXISTS billing_failure_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_payment_failed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS billing_blocked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS billing_block_reason TEXT;

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_billing_failure_count_check;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_billing_failure_count_check
  CHECK (billing_failure_count >= 0);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_billing_blocked_at
ON public.maintenance_contracts (billing_blocked_at);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_billing_failure_count
ON public.maintenance_contracts (billing_failure_count);

COMMENT ON COLUMN public.maintenance_contracts.billing_failure_count IS
'Número de fallos consecutivos de cobro Stripe registrados por Modira. Se reinicia cuando una factura de mantenimiento se paga correctamente.';

COMMENT ON COLUMN public.maintenance_contracts.last_payment_failed_at IS
'Momento del último intento de cobro fallido de la suscripción Stripe.';

COMMENT ON COLUMN public.maintenance_contracts.billing_blocked_at IS
'Momento en que Modira alcanzó el umbral de 3 fallos consecutivos y bloqueó la recaudación automática mediante Stripe.';

COMMENT ON COLUMN public.maintenance_contracts.billing_block_reason IS
'Motivo del bloqueo de facturación. Los bloqueos por impago usan el prefijo payment_failed; los bloqueos fiscales se gestionan mediante pause_collection y el flujo fiscal existente.';


-- ============================================================
-- 2. REGISTRAR UN FALLO DE COBRO DE FORMA ATÓMICA
-- ============================================================

CREATE OR REPLACE FUNCTION public.register_maintenance_billing_failure(
  p_subscription_id TEXT,
  p_reason TEXT DEFAULT NULL
)
RETURNS public.maintenance_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_contract public.maintenance_contracts;
  v_count INTEGER;
  v_reason TEXT;
BEGIN
  IF p_subscription_id IS NULL OR BTRIM(p_subscription_id) = '' THEN
    RAISE EXCEPTION 'subscription_id obligatorio';
  END IF;

  v_reason := LEFT(
    COALESCE(NULLIF(BTRIM(p_reason), ''), 'Stripe ha rechazado o no ha podido completar el cobro.'),
    1000
  );

  SELECT *
  INTO v_contract
  FROM public.maintenance_contracts
  WHERE stripe_subscription_id = p_subscription_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'No existe un contrato de mantenimiento para la suscripción %',
      p_subscription_id;
  END IF;

  v_count := COALESCE(v_contract.billing_failure_count, 0) + 1;

  UPDATE public.maintenance_contracts
  SET
    billing_failure_count = v_count,
    last_payment_failed_at = CURRENT_TIMESTAMP,
    billing_blocked_at = CASE
      WHEN v_count >= 3
        THEN COALESCE(v_contract.billing_blocked_at, CURRENT_TIMESTAMP)
      ELSE v_contract.billing_blocked_at
    END,
    billing_block_reason = CASE
      WHEN v_count >= 3
        THEN COALESCE(
          NULLIF(v_contract.billing_block_reason, ''),
          'payment_failed: ' || v_reason
        )
      ELSE v_contract.billing_block_reason
    END,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_contract.id
  RETURNING *
  INTO v_contract;

  RETURN v_contract;
END;
$function$;


-- ============================================================
-- 3. REINICIAR FALLOS DESPUÉS DE UN PAGO CORRECTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.reset_maintenance_billing_failures(
  p_subscription_id TEXT
)
RETURNS public.maintenance_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_contract public.maintenance_contracts;
BEGIN
  IF p_subscription_id IS NULL OR BTRIM(p_subscription_id) = '' THEN
    RAISE EXCEPTION 'subscription_id obligatorio';
  END IF;

  SELECT *
  INTO v_contract
  FROM public.maintenance_contracts
  WHERE stripe_subscription_id = p_subscription_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'No existe un contrato de mantenimiento para la suscripción %',
      p_subscription_id;
  END IF;

  UPDATE public.maintenance_contracts
  SET
    billing_failure_count = 0,
    last_payment_failed_at = NULL,
    billing_blocked_at = NULL,
    billing_block_reason = NULL,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_contract.id
  RETURNING *
  INTO v_contract;

  RETURN v_contract;
END;
$function$;


-- ============================================================
-- 4. SOLO EL BACKEND PUEDE EJECUTAR ESTAS OPERACIONES
-- ============================================================

REVOKE ALL
ON FUNCTION public.register_maintenance_billing_failure(TEXT, TEXT)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.register_maintenance_billing_failure(TEXT, TEXT)
TO service_role;

REVOKE ALL
ON FUNCTION public.reset_maintenance_billing_failures(TEXT)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.reset_maintenance_billing_failures(TEXT)
TO service_role;


-- ============================================================
-- 5. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_contracts'
    AND column_name = 'billing_failure_count';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '068 failed: billing_failure_count missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'register_maintenance_billing_failure'
    AND pg_get_function_identity_arguments(p.oid)
      = 'p_subscription_id text, p_reason text';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '068 failed: register_maintenance_billing_failure() missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'reset_maintenance_billing_failures'
    AND pg_get_function_identity_arguments(p.oid)
      = 'p_subscription_id text';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '068 failed: reset_maintenance_billing_failures() missing';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
GRANT SELECT ON TABLE public.companies TO service_role;

COMMIT;

-- ============================================================
-- FIN — MODIRA 068
-- ============================================================
