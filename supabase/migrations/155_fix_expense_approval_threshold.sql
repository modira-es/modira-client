-- Corrige el envío de gastos reales para que solo requieran aprobación
-- cuando una regla activa de Dirección lo exija por importe/categoría.
CREATE OR REPLACE FUNCTION public.submit_expense_for_review(p_expense_id uuid)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expense public.expenses;
  v_new_status text;
BEGIN
  PERFORM public.require_expense_permission('expenses.update');
  PERFORM public.consume_expense_worker_rate_limit('expenses:submit_review');

  SELECT * INTO v_expense
  FROM public.expenses
  WHERE id = p_expense_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El gasto % no existe', p_expense_id;
  END IF;

  IF v_expense.status <> 'draft' THEN
    RAISE EXCEPTION 'Solo se pueden registrar gastos en estado draft';
  END IF;

  IF v_expense.total_amount <= 0 THEN
    RAISE EXCEPTION 'El gasto debe tener un importe total superior a 0';
  END IF;

  v_new_status := CASE
    WHEN public.expense_requires_approval(v_expense.total_amount, v_expense.category_id)
      THEN 'pending_review'
    ELSE 'pending_payment'
  END;

  UPDATE public.expenses
  SET status = v_new_status,
      updated_by = auth.uid(),
      updated_at = CURRENT_TIMESTAMP
  WHERE id = p_expense_id
  RETURNING * INTO v_expense;

  RETURN v_expense;
END;
$function$;

REVOKE ALL ON FUNCTION public.submit_expense_for_review(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_expense_for_review(uuid) TO authenticated;
