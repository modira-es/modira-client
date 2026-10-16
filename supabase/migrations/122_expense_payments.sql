BEGIN;


-- ============================================================
-- MIGRACIÓN 122 — PAGOS DE GASTOS
-- ============================================================
--
-- Registra los pagos realizados por Modira asociados a sus
-- gastos internos.
--
-- IMPORTANTE:
--
--   expense_payments NO sustituye ni modifica payments.
--
--   payments:
--     -> cobros de Modira a clientes.
--
--   expense_payments:
--     -> pagos realizados por Modira por sus gastos internos.
--
-- Esta migración:
--
--   1. Crea expense_payments.
--   2. Define métodos y estados de pago.
--   3. Controla importes.
--   4. Impide pagos superiores al importe pendiente.
--   5. Calcula automáticamente el estado de pago del gasto.
--   6. Mantiene pending_payment / partially_paid / paid.
--
-- El sistema completo de RLS/RBAC se implementará posteriormente
-- en la migración 076.
--
-- ============================================================


-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
BEGIN

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expenses'
  ) THEN

    RAISE EXCEPTION
      '122_expense_payments: no existe public.expenses. Ejecuta primero 120_expenses_core.';

  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_tax_lines'
  ) THEN

    RAISE EXCEPTION
      '122_expense_payments: no existe public.expense_tax_lines. Ejecuta primero 121_expenses_tax.';

  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_documents'
  ) THEN

    RAISE EXCEPTION
      '122_expense_payments: no existe public.expense_documents. Ejecuta primero 121_expense_documents.';

  END IF;

END;
$$;


-- ============================================================
-- 2. TABLA expense_payments
-- ============================================================

CREATE TABLE IF NOT EXISTS public.expense_payments (

  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),


  -- ----------------------------------------------------------
  -- Gasto al que pertenece el pago
  -- ----------------------------------------------------------

  expense_id UUID NOT NULL
    REFERENCES public.expenses(id)
    ON DELETE RESTRICT,


  -- ----------------------------------------------------------
  -- Importe pagado
  -- ----------------------------------------------------------

  amount NUMERIC(14,2) NOT NULL,


  -- ----------------------------------------------------------
  -- Fecha del pago
  -- ----------------------------------------------------------

  payment_date TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,


  -- ----------------------------------------------------------
  -- Método utilizado
  -- ----------------------------------------------------------

  payment_method TEXT NOT NULL,


  -- ----------------------------------------------------------
  -- Referencia externa / bancaria
  -- ----------------------------------------------------------

  reference TEXT,


  -- ----------------------------------------------------------
  -- Estado del pago
  -- ----------------------------------------------------------

  status TEXT NOT NULL DEFAULT 'pending',


  -- ----------------------------------------------------------
  -- Usuario que registra el pago
  -- ----------------------------------------------------------

  created_by UUID
    REFERENCES auth.users(id)
    ON DELETE SET NULL,


  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,


  -- ==========================================================
  -- CONSTRAINTS
  -- ==========================================================

  CONSTRAINT expense_payments_amount_check
    CHECK (
      amount > 0
    ),


  CONSTRAINT expense_payments_method_check
    CHECK (
      payment_method IN (
        'bank_transfer',
        'card',
        'cash',
        'direct_debit',
        'other'
      )
    ),


  CONSTRAINT expense_payments_status_check
    CHECK (
      status IN (
        'pending',
        'succeeded',
        'failed',
        'cancelled'
      )
    ),


  CONSTRAINT expense_payments_reference_check
    CHECK (
      reference IS NULL
      OR LENGTH(BTRIM(reference)) BETWEEN 1 AND 255
    )

);


-- ============================================================
-- 3. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
  idx_expense_payments_expense
ON public.expense_payments (expense_id);


CREATE INDEX IF NOT EXISTS
  idx_expense_payments_status
ON public.expense_payments (status);


CREATE INDEX IF NOT EXISTS
  idx_expense_payments_payment_date
ON public.expense_payments (payment_date DESC);


CREATE INDEX IF NOT EXISTS
  idx_expense_payments_created_by
ON public.expense_payments (created_by);


CREATE INDEX IF NOT EXISTS
  idx_expense_payments_expense_status
ON public.expense_payments (expense_id, status);


-- ============================================================
-- 4. TRIGGER updated_at
-- ============================================================

DO $$
BEGIN

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'update_updated_at_column'
      AND pronamespace = 'public'::regnamespace
  ) THEN

    RAISE EXCEPTION
      '122_expense_payments: no existe public.update_updated_at_column().';

  END IF;

END;
$$;


DROP TRIGGER IF EXISTS
  expense_payments_set_updated_at
ON public.expense_payments;


CREATE TRIGGER
  expense_payments_set_updated_at

BEFORE UPDATE

ON public.expense_payments

FOR EACH ROW

EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 5. VALIDACIÓN DE TRANSICIONES DE ESTADO
-- ============================================================
--
-- Estados permitidos:
--
--   pending
--       ↓
--   succeeded
--
--   pending
--       ↓
--   failed
--
--   pending
--       ↓
--   cancelled
--
-- Una vez que un pago ha sido confirmado como succeeded,
-- no se puede devolver arbitrariamente a pending/failed/cancelled.
--
-- De igual manera, un pago fallido o cancelado no puede
-- convertirse posteriormente en succeeded.
--
-- Para corregir un pago confirmado se registrará un nuevo
-- movimiento mediante el flujo contable correspondiente.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_expense_payment_state()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

  IF TG_OP = 'UPDATE' THEN

    -- --------------------------------------------------------
    -- No se permite modificar el gasto al que pertenece
    -- --------------------------------------------------------

    IF NEW.expense_id IS DISTINCT FROM OLD.expense_id THEN

      RAISE EXCEPTION
        'No se puede cambiar el expense_id de un pago existente';

    END IF;


    -- --------------------------------------------------------
    -- Un pago confirmado es inmutable
    -- --------------------------------------------------------

    IF OLD.status = 'succeeded' THEN

      IF NEW.status IS DISTINCT FROM OLD.status THEN

        RAISE EXCEPTION
          'Un pago succeeded no puede cambiar de estado';

      END IF;


      IF NEW.amount IS DISTINCT FROM OLD.amount THEN

        RAISE EXCEPTION
          'No se puede modificar el importe de un pago succeeded';

      END IF;


      IF NEW.payment_date IS DISTINCT FROM OLD.payment_date THEN

        RAISE EXCEPTION
          'No se puede modificar la fecha de un pago succeeded';

      END IF;


      IF NEW.payment_method IS DISTINCT FROM OLD.payment_method THEN

        RAISE EXCEPTION
          'No se puede modificar el método de un pago succeeded';

      END IF;


      IF NEW.reference IS DISTINCT FROM OLD.reference THEN

        RAISE EXCEPTION
          'No se puede modificar la referencia de un pago succeeded';

      END IF;

    END IF;


    -- --------------------------------------------------------
    -- Estados finales no pueden reabrirse
    -- --------------------------------------------------------

    IF OLD.status IN ('failed', 'cancelled')
       AND NEW.status IS DISTINCT FROM OLD.status THEN

      RAISE EXCEPTION
        'Un pago % no puede cambiar posteriormente de estado',
        OLD.status;

    END IF;


    -- --------------------------------------------------------
    -- pending solamente puede pasar a un estado final
    -- --------------------------------------------------------

    IF OLD.status = 'pending'
       AND NEW.status NOT IN (
         'pending',
         'succeeded',
         'failed',
         'cancelled'
       ) THEN

      RAISE EXCEPTION
        'Transición de estado de pago no válida';

    END IF;

  END IF;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 6. TRIGGER DE TRANSICIONES
-- ============================================================

DROP TRIGGER IF EXISTS
  expense_payments_validate_state
ON public.expense_payments;


CREATE TRIGGER
  expense_payments_validate_state

BEFORE UPDATE

ON public.expense_payments

FOR EACH ROW

EXECUTE FUNCTION public.validate_expense_payment_state();


-- ============================================================
-- 7. FUNCIÓN PARA CALCULAR PAGOS CONFIRMADOS
-- ============================================================
--
-- Solo los pagos:
--
--   status = 'succeeded'
--
-- cuentan como dinero realmente pagado.
--
-- Los estados pending / failed / cancelled no afectan al
-- importe pagado.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_expense_paid_amount(
  p_expense_id UUID
)
RETURNS NUMERIC(14,2)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_paid NUMERIC(14,2);

BEGIN

  IF p_expense_id IS NULL THEN

    RAISE EXCEPTION
      'get_expense_paid_amount: expense_id es obligatorio';

  END IF;


  SELECT
    ROUND(
      COALESCE(
        SUM(amount),
        0
      ),
      2
    )

  INTO v_paid

  FROM public.expense_payments

  WHERE expense_id = p_expense_id

    AND status = 'succeeded';


  RETURN COALESCE(v_paid, 0);

END;
$$;


-- ============================================================
-- 8. FUNCIÓN PARA ACTUALIZAR EL ESTADO DE PAGO DEL GASTO
-- ============================================================
--
-- Estados del gasto:
--
--   approved
--       ↓
--   pending_payment
--       ↓
--   partially_paid
--       ↓
--   paid
--
-- Solo se modifica automáticamente el estado cuando el gasto
-- ya está dentro del flujo de pago.
--
-- No se modifican automáticamente:
--
--   draft
--   pending_review
--   rejected
--   cancelled
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_expense_payment_status(
  p_expense_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_total_amount NUMERIC(14,2);

  v_paid_amount NUMERIC(14,2);

  v_current_status TEXT;

  v_new_status TEXT;

BEGIN

  IF p_expense_id IS NULL THEN

    RAISE EXCEPTION
      'sync_expense_payment_status: expense_id es obligatorio';

  END IF;


  SELECT
    total_amount,
    status

  INTO
    v_total_amount,
    v_current_status

  FROM public.expenses

  WHERE id = p_expense_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'sync_expense_payment_status: el gasto % no existe',
      p_expense_id;

  END IF;


  v_total_amount :=
    ROUND(
      GREATEST(
        COALESCE(v_total_amount, 0),
        0
      ),
      2
    );


  v_paid_amount :=
    public.get_expense_paid_amount(
      p_expense_id
    );


  -- ----------------------------------------------------------
  -- No tocar estados que todavía no pertenecen al ciclo
  -- de pago.
  -- ----------------------------------------------------------

  IF v_current_status IN (
    'draft',
    'pending_review',
    'rejected',
    'cancelled'
  ) THEN

    RETURN;

  END IF;


  -- ----------------------------------------------------------
  -- Si el gasto no tiene importe:
  -- no se considera automáticamente pagado.
  -- ----------------------------------------------------------

  IF v_total_amount <= 0 THEN

    RETURN;

  END IF;


  -- ----------------------------------------------------------
  -- Determinar nuevo estado
  -- ----------------------------------------------------------

  IF v_paid_amount >= v_total_amount THEN

    v_new_status := 'paid';

  ELSIF v_paid_amount > 0 THEN

    v_new_status := 'partially_paid';

  ELSE

    v_new_status := 'pending_payment';

  END IF;


  -- ----------------------------------------------------------
  -- Actualizar solamente si ha cambiado
  -- ----------------------------------------------------------

  IF v_current_status IS DISTINCT FROM v_new_status THEN

    UPDATE public.expenses

    SET
      status = v_new_status,
      updated_at = CURRENT_TIMESTAMP

    WHERE id = p_expense_id;

  END IF;

END;
$$;


-- ============================================================
-- 9. PROTECCIÓN CONTRA SOBREPAGO
-- ============================================================
--
-- Antes de registrar un pago succeeded, se comprueba:
--
--   pagos succeeded existentes + nuevo pago
--       <= total_amount
--
-- Esto evita que el gasto termine con:
--
--   total = 1.000 €
--   pagado = 1.200 €
--
-- Los pagos pending no se consideran pagos confirmados.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_expense_payment_amount()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_total_amount NUMERIC(14,2);

  v_paid_amount NUMERIC(14,2);

  v_new_paid_amount NUMERIC(14,2);

BEGIN

  -- ----------------------------------------------------------
  -- Solo necesitamos comprobar el límite cuando el pago
  -- pasa a succeeded.
  -- ----------------------------------------------------------

  IF NEW.status <> 'succeeded' THEN

    RETURN NEW;

  END IF;


  SELECT
    total_amount

  INTO
    v_total_amount

  FROM public.expenses

  WHERE id = NEW.expense_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto asociado al pago no existe';

  END IF;


  v_total_amount :=
    ROUND(
      GREATEST(
        COALESCE(v_total_amount, 0),
        0
      ),
      2
    );


  -- ----------------------------------------------------------
  -- Pagos succeeded anteriores.
  --
  -- En UPDATE excluimos el propio registro para evitar
  -- contabilizarlo dos veces.
  -- ----------------------------------------------------------

  SELECT
    ROUND(
      COALESCE(
        SUM(amount),
        0
      ),
      2
    )

  INTO
    v_paid_amount

  FROM public.expense_payments

  WHERE expense_id = NEW.expense_id

    AND status = 'succeeded'

    AND id IS DISTINCT FROM NEW.id;


  v_new_paid_amount :=
    ROUND(
      v_paid_amount + NEW.amount,
      2
    );


  IF v_new_paid_amount > v_total_amount THEN

    RAISE EXCEPTION
      'El pago de % supera el importe pendiente del gasto. Total del gasto: %, ya pagado: %, nuevo pago: %',
      NEW.amount,
      v_total_amount,
      v_paid_amount,
      NEW.amount;

  END IF;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 10. TRIGGER DE SOBREPAGO
-- ============================================================

DROP TRIGGER IF EXISTS
  expense_payments_validate_amount
ON public.expense_payments;


CREATE TRIGGER
  expense_payments_validate_amount

BEFORE INSERT OR UPDATE

ON public.expense_payments

FOR EACH ROW

EXECUTE FUNCTION public.validate_expense_payment_amount();


-- ============================================================
-- 11. TRIGGER PARA SINCRONIZAR EL ESTADO DEL GASTO
-- ============================================================
--
-- Después de crear/modificar/eliminar un pago se recalcula
-- el estado económico del gasto.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_expense_status_from_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense_id UUID;

BEGIN

  IF TG_OP = 'DELETE' THEN

    v_expense_id := OLD.expense_id;

  ELSE

    v_expense_id := NEW.expense_id;

  END IF;


  PERFORM public.sync_expense_payment_status(
    v_expense_id
  );


  RETURN COALESCE(NEW, OLD);

END;
$$;


-- ============================================================
-- 12. TRIGGER DE SINCRONIZACIÓN
-- ============================================================

DROP TRIGGER IF EXISTS
  expense_payments_sync_expense_status
ON public.expense_payments;


CREATE TRIGGER
  expense_payments_sync_expense_status

AFTER INSERT OR UPDATE OR DELETE

ON public.expense_payments

FOR EACH ROW

EXECUTE FUNCTION public.sync_expense_status_from_payment();


-- ============================================================
-- 13. PERMISOS DE FUNCIONES INTERNAS
-- ============================================================

REVOKE EXECUTE
ON FUNCTION public.get_expense_paid_amount(UUID)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.get_expense_paid_amount(UUID)
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.get_expense_paid_amount(UUID)
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.sync_expense_payment_status(UUID)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.sync_expense_payment_status(UUID)
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.sync_expense_payment_status(UUID)
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.validate_expense_payment_state()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_payment_state()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_payment_state()
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.validate_expense_payment_amount()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_payment_amount()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_payment_amount()
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.sync_expense_status_from_payment()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.sync_expense_status_from_payment()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.sync_expense_status_from_payment()
FROM authenticated;


-- ============================================================
-- 14. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.expense_payments IS
  'Pagos realizados por Modira asociados a gastos internos. Es independiente de payments, que representa cobros a clientes.';


COMMENT ON COLUMN public.expense_payments.amount IS
  'Importe del pago realizado por Modira.';


COMMENT ON COLUMN public.expense_payments.payment_method IS
  'Método de pago: bank_transfer, card, cash, direct_debit u other.';


COMMENT ON COLUMN public.expense_payments.reference IS
  'Referencia bancaria, número de operación o identificador externo del pago.';


COMMENT ON COLUMN public.expense_payments.status IS
  'Estado del pago: pending, succeeded, failed o cancelled.';


-- ============================================================
-- 15. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE

  v_table_exists BOOLEAN;

  v_required_columns INTEGER;

  v_state_trigger BOOLEAN;

  v_amount_trigger BOOLEAN;

  v_sync_trigger BOOLEAN;

  v_function_exists BOOLEAN;

BEGIN

  -- ----------------------------------------------------------
  -- Tabla
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_payments'
  )
  INTO v_table_exists;


  IF NOT v_table_exists THEN

    RAISE EXCEPTION
      '122_expense_payments: no existe expense_payments';

  END IF;


  -- ----------------------------------------------------------
  -- Columnas
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_required_columns

  FROM (
    VALUES
      ('expense_id'),
      ('amount'),
      ('payment_date'),
      ('payment_method'),
      ('reference'),
      ('status'),
      ('created_by'),
      ('created_at'),
      ('updated_at')
  ) AS required_columns(column_name)

  WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'expense_payments'
      AND c.column_name = required_columns.column_name
  );


  IF v_required_columns > 0 THEN

    RAISE EXCEPTION
      '122_expense_payments: faltan % columnas obligatorias',
      v_required_columns;

  END IF;


  -- ----------------------------------------------------------
  -- Trigger de estados
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'expense_payments_validate_state'
      AND tgrelid = 'public.expense_payments'::regclass
      AND NOT tgisinternal
  )
  INTO v_state_trigger;


  IF NOT v_state_trigger THEN

    RAISE EXCEPTION
      '122_expense_payments: falta el trigger de validación de estados';

  END IF;


  -- ----------------------------------------------------------
  -- Trigger de importe
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'expense_payments_validate_amount'
      AND tgrelid = 'public.expense_payments'::regclass
      AND NOT tgisinternal
  )
  INTO v_amount_trigger;


  IF NOT v_amount_trigger THEN

    RAISE EXCEPTION
      '122_expense_payments: falta el trigger de validación de importe';

  END IF;


  -- ----------------------------------------------------------
  -- Trigger de sincronización
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'expense_payments_sync_expense_status'
      AND tgrelid = 'public.expense_payments'::regclass
      AND NOT tgisinternal
  )
  INTO v_sync_trigger;


  IF NOT v_sync_trigger THEN

    RAISE EXCEPTION
      '122_expense_payments: falta el trigger de sincronización del gasto';

  END IF;


  -- ----------------------------------------------------------
  -- Función de cálculo
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'get_expense_paid_amount'
      AND pronamespace = 'public'::regnamespace
  )
  INTO v_function_exists;


  IF NOT v_function_exists THEN

    RAISE EXCEPTION
      '122_expense_payments: falta get_expense_paid_amount()';

  END IF;


  RAISE NOTICE
    '122_expense_payments: migración completada correctamente.';

END;
$$;


COMMIT;