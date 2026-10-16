-- Migration 157: automatic processing of expense payments by scheduled date.
-- Approval thresholds remain data-driven through expense_approval_rules;
-- this migration does not hardcode any amount or category.

BEGIN;

-- Payments dated now or in the past are recorded as succeeded immediately.
-- Future-dated payments remain pending and are picked up by pg_cron.
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

  v_effective_payment_date := COALESCE(p_payment_date, CURRENT_TIMESTAMP);
  v_payment_status := CASE
    WHEN v_effective_payment_date <= CURRENT_TIMESTAMP THEN 'succeeded'
    ELSE 'pending'
  END;

  INSERT INTO public.expense_payments (
    expense_id,
    amount,
    payment_date,
    payment_method,
    reference,
    status,
    created_by
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

REVOKE ALL ON FUNCTION public.create_expense_payment(uuid, numeric, timestamptz, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_expense_payment(uuid, numeric, timestamptz, text, text) TO authenticated;

-- Process due pending payments in small batches. The existing validation and
-- synchronization triggers remain active when a payment is changed to succeeded.
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
    -- Isolate an invalid payment so it cannot stop the rest of the batch.
    -- If validation rejects it (for example, it would overpay the expense),
    -- leave it pending for an administrator to inspect and correct.
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

REVOKE ALL ON FUNCTION public.process_due_expense_payments() FROM PUBLIC, anon, authenticated;

-- Keep exactly one named job, making this migration safe to apply again.
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

COMMIT;
