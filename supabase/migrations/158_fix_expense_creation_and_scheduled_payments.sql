-- Migration 158: finalize expense creation with threshold-aware scheduled payment.
-- Supersedes the incomplete creation/payment flow from migrations 154-157.
-- The approval threshold is always read from expense_approval_rules; no amount is hardcoded.

BEGIN;

-- Mark payments created automatically by the expense-creation flow.
-- Existing/manual payments remain FALSE and are not modified by the amount-sync trigger.
ALTER TABLE public.expense_payments
  ADD COLUMN IF NOT EXISTS is_automatic boolean NOT NULL DEFAULT false;

-- If fiscal lines change the expense total while an automatic payment is still
-- pending (e.g. an expense awaiting approval or a future payment), keep its
-- scheduled amount aligned with the latest total. Succeeded payments are immutable.
CREATE OR REPLACE FUNCTION public.sync_automatic_expense_payment_amount()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.total_amount IS DISTINCT FROM OLD.total_amount THEN
    IF NEW.total_amount > 0 THEN
      UPDATE public.expense_payments
      SET amount = ROUND(NEW.total_amount, 2)
      WHERE expense_id = NEW.id
        AND is_automatic = true
        AND status = 'pending';
    END IF;

    PERFORM public.sync_expense_payment_status(NEW.id);
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS expenses_sync_automatic_payment_amount ON public.expenses;
CREATE TRIGGER expenses_sync_automatic_payment_amount
AFTER UPDATE OF total_amount ON public.expenses
FOR EACH ROW
WHEN (OLD.total_amount IS DISTINCT FROM NEW.total_amount)
EXECUTE FUNCTION public.sync_automatic_expense_payment_amount();

-- Atomic creation flow:
-- * threshold reached: expense remains pending_review and scheduled payment stays pending;
-- * below threshold + date now/past: payment is succeeded and trigger marks expense paid;
-- * below threshold + future date: payment stays pending until pg_cron processes it.
CREATE OR REPLACE FUNCTION public.create_expense_with_scheduled_payment(
  p_expense_date date,
  p_description text,
  p_expense_type text,
  p_category_id uuid,
  p_supplier_id uuid DEFAULT NULL::uuid,
  p_project_id uuid DEFAULT NULL::uuid,
  p_currency text DEFAULT 'EUR'::text,
  p_subtotal numeric DEFAULT 0,
  p_payment_date timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
  p_payment_method text DEFAULT 'bank_transfer'::text,
  p_reference text DEFAULT NULL::text
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expense public.expenses;
  v_payment_date timestamptz;
  v_requires_approval boolean;
  v_payment_status text;
BEGIN
  PERFORM public.require_expense_permission('expenses.create');
  PERFORM public.consume_expense_worker_rate_limit('expenses:create');

  IF p_description IS NULL OR BTRIM(p_description) = '' THEN
    RAISE EXCEPTION 'La descripción del gasto es obligatoria';
  END IF;

  IF LENGTH(BTRIM(p_description)) > 2000 THEN
    RAISE EXCEPTION 'La descripción del gasto no puede superar 2.000 caracteres';
  END IF;

  IF p_currency IS NULL OR p_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'La moneda debe tener formato ISO de 3 letras';
  END IF;

  IF p_subtotal IS NULL OR p_subtotal < 0 THEN
    RAISE EXCEPTION 'El subtotal no puede ser negativo';
  END IF;

  IF p_payment_method IS NULL OR p_payment_method NOT IN (
    'bank_transfer', 'card', 'cash', 'direct_debit', 'other'
  ) THEN
    RAISE EXCEPTION 'El método de pago no es válido';
  END IF;

  v_payment_date := COALESCE(p_payment_date, CURRENT_TIMESTAMP);

  INSERT INTO public.expenses (
    expense_date,
    description,
    expense_type,
    category_id,
    supplier_id,
    project_id,
    status,
    currency,
    subtotal,
    created_by,
    updated_by
  )
  VALUES (
    COALESCE(p_expense_date, CURRENT_DATE),
    BTRIM(p_description),
    p_expense_type,
    p_category_id,
    p_supplier_id,
    p_project_id,
    'draft',
    p_currency,
    ROUND(p_subtotal, 2),
    auth.uid(),
    auth.uid()
  )
  RETURNING * INTO v_expense;

  IF COALESCE(v_expense.total_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'El gasto debe tener un importe total superior a 0';
  END IF;

  v_requires_approval := public.expense_requires_approval(
    v_expense.total_amount,
    v_expense.category_id
  );

  UPDATE public.expenses
  SET status = CASE
        WHEN v_requires_approval THEN 'pending_review'
        ELSE 'pending_payment'
      END,
      updated_by = auth.uid(),
      updated_at = CURRENT_TIMESTAMP
  WHERE id = v_expense.id
  RETURNING * INTO v_expense;

  v_payment_status := CASE
    WHEN v_requires_approval THEN 'pending'
    WHEN v_payment_date > CURRENT_TIMESTAMP THEN 'pending'
    ELSE 'succeeded'
  END;

  INSERT INTO public.expense_payments (
    expense_id,
    amount,
    payment_date,
    payment_method,
    reference,
    status,
    created_by,
    is_automatic
  )
  VALUES (
    v_expense.id,
    ROUND(v_expense.total_amount, 2),
    v_payment_date,
    p_payment_method,
    NULLIF(BTRIM(p_reference), ''),
    v_payment_status,
    auth.uid(),
    true
  );

  -- The payment trigger updates the expense status if this payment succeeded.
  -- Fetch again so the RPC returns the final status (e.g. paid).
  SELECT * INTO v_expense
  FROM public.expenses
  WHERE id = v_expense.id;

  RETURN v_expense;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_expense_with_scheduled_payment(
  date, text, text, uuid, uuid, uuid, text, numeric, timestamptz, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_expense_with_scheduled_payment(
  date, text, text, uuid, uuid, uuid, text, numeric, timestamptz, text, text
) TO authenticated;

-- Preserve the current manual-payment validations, while allowing a payment
-- dated now/past to be confirmed immediately and a future one to stay pending.
CREATE OR REPLACE FUNCTION public.create_expense_payment(
  p_expense_id uuid,
  p_amount numeric,
  p_payment_date timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
  p_payment_method text DEFAULT 'bank_transfer'::text,
  p_reference text DEFAULT NULL::text
)
RETURNS public.expense_payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_payment public.expense_payments;
  v_expense_status text;
  v_effective_payment_date timestamptz;
  v_payment_status text;
BEGIN
  PERFORM public.require_expense_permission('expenses.pay');
  PERFORM public.consume_expense_worker_rate_limit('expenses:payment_create');

  SELECT status
    INTO v_expense_status
  FROM public.expenses
  WHERE id = p_expense_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El gasto % no existe', p_expense_id;
  END IF;

  IF v_expense_status NOT IN ('pending_payment', 'partially_paid') THEN
    RAISE EXCEPTION
      'El gasto no está pendiente de pago. Estado actual: %',
      v_expense_status;
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'El importe del pago debe ser mayor que 0';
  END IF;

  IF p_payment_method IS NULL OR p_payment_method NOT IN (
    'bank_transfer', 'card', 'cash', 'direct_debit', 'other'
  ) THEN
    RAISE EXCEPTION 'El método de pago no es válido';
  END IF;

  v_effective_payment_date := COALESCE(p_payment_date, CURRENT_TIMESTAMP);
  v_payment_status := CASE
    WHEN v_effective_payment_date <= CURRENT_TIMESTAMP THEN 'succeeded'
    ELSE 'pending'
  END;

  INSERT INTO public.expense_payments (
    expense_id, amount, payment_date, payment_method, reference, status, created_by
  )
  VALUES (
    p_expense_id,
    ROUND(p_amount, 2),
    v_effective_payment_date,
    p_payment_method,
    NULLIF(BTRIM(p_reference), ''),
    v_payment_status,
    auth.uid()
  )
  RETURNING * INTO v_payment;

  RETURN v_payment;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_expense_payment(
  uuid, numeric, timestamptz, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_expense_payment(
  uuid, numeric, timestamptz, text, text
) TO authenticated;

-- Process due payments in batches. Payments belonging to expenses still awaiting
-- Direction's approval are intentionally excluded until the expense is approved.
CREATE OR REPLACE FUNCTION public.process_due_expense_payments()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_payment_id uuid;
  v_processed integer := 0;
BEGIN
  FOR v_payment_id IN
    SELECT ep.id
    FROM public.expense_payments ep
    JOIN public.expenses e ON e.id = ep.expense_id
    WHERE ep.status = 'pending'
      AND ep.payment_date <= CURRENT_TIMESTAMP
      AND e.status IN ('pending_payment', 'partially_paid')
    ORDER BY ep.payment_date, ep.created_at
    LIMIT 500
    FOR UPDATE OF ep SKIP LOCKED
  LOOP
    BEGIN
      UPDATE public.expense_payments
      SET status = 'succeeded',
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_payment_id
        AND status = 'pending';

      IF FOUND THEN
        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING
        'No se ha podido procesar automáticamente el pago %: %',
        v_payment_id, SQLERRM;
    END;
  END LOOP;

  RETURN v_processed;
END;
$function$;

REVOKE ALL ON FUNCTION public.process_due_expense_payments()
  FROM PUBLIC, anon, authenticated;

-- Ensure exactly one scheduler exists, whether migration 157 was previously applied or not.
DO $schedule$
DECLARE
  v_job record;
BEGIN
  FOR v_job IN
    SELECT jobid
    FROM cron.job
    WHERE jobname = 'modira-process-due-expense-payments'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'modira-process-due-expense-payments',
    '* * * * *',
    'SELECT public.process_due_expense_payments();'
  );
END;
$schedule$;


BEGIN;

CREATE OR REPLACE FUNCTION public.approve_expense(
  p_expense_id uuid
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expense public.expenses;
BEGIN
  -- Mantener los controles de permisos y seguridad existentes.
  PERFORM public.require_expense_permission(
    'expenses.approve'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:approve'
  );

  -- Bloquear el gasto durante la aprobación.
  SELECT *
  INTO v_expense
  FROM public.expenses
  WHERE id = p_expense_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'El gasto % no existe',
      p_expense_id;
  END IF;

  -- Solo se pueden aprobar gastos pendientes de revisión.
  IF v_expense.status <> 'pending_review' THEN
    RAISE EXCEPTION
      'Solo se pueden aprobar gastos en estado pending_review';
  END IF;

  IF v_expense.total_amount <= 0 THEN
    RAISE EXCEPTION
      'No se puede aprobar un gasto cuyo importe total sea 0';
  END IF;

  -- La aprobación autoriza el gasto, pero no implica por sí sola
  -- que esté pagado.
  UPDATE public.expenses
  SET
    status = 'pending_payment',
    updated_by = auth.uid(),
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_expense_id
  RETURNING *
  INTO v_expense;

  -- Si existen pagos pendientes cuya fecha ya ha llegado,
  -- procesarlos inmediatamente después de aprobar el gasto.
  -- Los pagos con fecha futura permanecen pendientes.
  UPDATE public.expense_payments
  SET
    status = 'succeeded',
    updated_at = CURRENT_TIMESTAMP
  WHERE expense_id = p_expense_id
    AND status = 'pending'
    AND payment_date <= CURRENT_TIMESTAMP;

  -- Volver a leer el gasto para devolver su estado definitivo,
  -- actualizado por los mecanismos de sincronización de pagos.
  SELECT *
  INTO v_expense
  FROM public.expenses
  WHERE id = p_expense_id;

  RETURN v_expense;
END;
$function$;

COMMIT;


COMMIT;
