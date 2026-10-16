BEGIN;


-- ============================================================
-- MIGRACIÓN 124 — RPCs DE GASTOS PARA WORKERS
-- ============================================================
--
-- Objetivo:
--
--   El Employee Area NO escribe directamente sobre:
--
--      expenses
--      expense_tax_lines
--      expense_payments
--      expense_documents
--      expense_allocations
--
--   Las escrituras pasan por RPCs SECURITY DEFINER.
--
-- Todas las RPCs:
--
--   - requieren autenticación;
--   - requieren worker activo;
--   - comprueban el permiso correspondiente;
--   - utilizan auth.uid() como actor;
--   - utilizan search_path controlado;
--   - preparan el flujo para rate limiting;
--   - no aceptan created_by / updated_by desde frontend.
--
-- IMPORTANTE:
--
--   Los permisos expenses.* se terminarán de registrar en
--   la migración 076.
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
      '124_expenses_worker_rpcs: no existe public.expenses.';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_tax_lines'
  ) THEN
    RAISE EXCEPTION
      '124_expenses_worker_rpcs: no existe public.expense_tax_lines.';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_documents'
  ) THEN
    RAISE EXCEPTION
      '124_expenses_worker_rpcs: no existe public.expense_documents.';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_payments'
  ) THEN
    RAISE EXCEPTION
      '124_expenses_worker_rpcs: no existe public.expense_payments.';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_allocations'
  ) THEN
    RAISE EXCEPTION
      '124_expenses_worker_rpcs: no existe public.expense_allocations.';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'current_user_is_worker'
      AND pronamespace = 'public'::regnamespace
      AND pronargs = 0
  ) THEN
    RAISE EXCEPTION
      '124_expenses_worker_rpcs: no existe current_user_is_worker().';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'current_user_is_active'
      AND pronamespace = 'public'::regnamespace
      AND pronargs = 0
  ) THEN
    RAISE EXCEPTION
      '124_expenses_worker_rpcs: no existe current_user_is_active().';
  END IF;


IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_current_worker_permissions'
      AND pg_get_function_identity_arguments(p.oid) = ''
) THEN
    RAISE EXCEPTION
      '124_expenses_worker_rpcs: no existe get_current_worker_permissions().';
END IF;

END;
$$;


-- ============================================================
-- 2. FUNCIÓN INTERNA DE AUTORIZACIÓN
-- ============================================================
--
-- Centraliza:
--
--   autenticación
--   worker
--   cuenta activa
--   permiso
--
-- Los códigos utilizados serán:
--
--   expenses.read
--   expenses.create
--   expenses.update
--   expenses.delete
--   expenses.approve
--   expenses.pay
--   expenses.documents
--   expenses.allocate
--
-- La migración 076 registrará/ajustará estos permisos en el
-- sistema RBAC.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.require_expense_permission(
  p_permission TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION
      'Usuario no autenticado';
  END IF;


  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Solo los trabajadores pueden gestionar gastos internos';
  END IF;


  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION
      'El trabajador no está activo';
  END IF;


  IF p_permission IS NULL
     OR BTRIM(p_permission) = '' THEN
    RAISE EXCEPTION
      'Permiso requerido no especificado';
  END IF;


  IF NOT public.current_user_has_permission(p_permission) THEN
    RAISE EXCEPTION
      'No tienes permiso para realizar esta operación';
  END IF;

END;
$$;


-- ============================================================
-- 3. RATE LIMIT HELPER
-- ============================================================
--
-- Si existe la infraestructura de rate limiting de workers,
-- la utilizamos.
--
-- No se falla si la función todavía no está disponible, ya que
-- 042 ya la introdujo en el proyecto, pero esta migración debe
-- poder coexistir con instalaciones donde aún no se haya
-- desplegado esa infraestructura.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.consume_expense_worker_rate_limit(
  p_operation TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_function_exists BOOLEAN;

  v_allowed BOOLEAN;

BEGIN

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION
      'Usuario no autenticado';
  END IF;


  SELECT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'consume_worker_write_rate_limit'
      AND pronamespace = 'public'::regnamespace
  )
  INTO v_function_exists;


  IF NOT v_function_exists THEN
    RETURN;
  END IF;


  /*
   * Límite específico para operaciones del módulo de gastos.
   *
   * 100 operaciones / 10 minutos / worker.
   */

  SELECT public.consume_worker_write_rate_limit(
    p_operation,
    100,
    600
  )
  INTO v_allowed;


  IF NOT COALESCE(v_allowed, FALSE) THEN
    RAISE EXCEPTION
      'Demasiadas operaciones sobre gastos. Inténtalo de nuevo más tarde.';
  END IF;

END;
$$;


-- ============================================================
-- 4. CREATE EXPENSE
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_expense(
  p_expense_date DATE,
  p_description TEXT,
  p_expense_type TEXT,
  p_category_id UUID,
  p_supplier_id UUID DEFAULT NULL,
  p_project_id UUID DEFAULT NULL,
  p_currency TEXT DEFAULT 'EUR',
  p_subtotal NUMERIC DEFAULT 0
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense public.expenses;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.create'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:create'
  );


  IF p_description IS NULL
     OR BTRIM(p_description) = '' THEN

    RAISE EXCEPTION
      'La descripción del gasto es obligatoria';

  END IF;


  IF LENGTH(BTRIM(p_description)) > 2000 THEN

    RAISE EXCEPTION
      'La descripción del gasto no puede superar 2.000 caracteres';

  END IF;


  IF p_currency IS NULL
     OR p_currency !~ '^[A-Z]{3}$' THEN

    RAISE EXCEPTION
      'La moneda debe tener formato ISO de 3 letras';

  END IF;


  IF p_subtotal IS NULL
     OR p_subtotal < 0 THEN

    RAISE EXCEPTION
      'El subtotal no puede ser negativo';

  END IF;


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
  RETURNING *
  INTO v_expense;


  RETURN v_expense;

END;
$$;


-- ============================================================
-- 5. UPDATE EXPENSE
-- ============================================================
--
-- Solo permite modificar gastos que todavía no están cerrados.
--
-- Estados bloqueados:
--
--   paid
--   cancelled
--
-- Los estados aprobados/en pago pueden ser modificados por
-- el flujo controlado mientras no estén cerrados.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_expense(
  p_expense_id UUID,
  p_expense_date DATE,
  p_description TEXT,
  p_expense_type TEXT,
  p_category_id UUID,
  p_supplier_id UUID,
  p_project_id UUID,
  p_currency TEXT,
  p_subtotal NUMERIC
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense public.expenses;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.update'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:update'
  );


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


  IF v_expense.status IN (
    'paid',
    'cancelled'
  ) THEN

    RAISE EXCEPTION
      'No se puede modificar un gasto en estado %',
      v_expense.status;

  END IF;


  IF p_description IS NULL
     OR BTRIM(p_description) = '' THEN

    RAISE EXCEPTION
      'La descripción del gasto es obligatoria';

  END IF;


  IF LENGTH(BTRIM(p_description)) > 2000 THEN

    RAISE EXCEPTION
      'La descripción no puede superar 2.000 caracteres';

  END IF;


  IF p_currency IS NULL
     OR p_currency !~ '^[A-Z]{3}$' THEN

    RAISE EXCEPTION
      'La moneda debe tener formato ISO de 3 letras';

  END IF;


  IF p_subtotal IS NULL
     OR p_subtotal < 0 THEN

    RAISE EXCEPTION
      'El subtotal no puede ser negativo';

  END IF;


  UPDATE public.expenses

  SET
    expense_date = COALESCE(
      p_expense_date,
      expense_date
    ),

    description = BTRIM(p_description),

    expense_type = p_expense_type,

    category_id = p_category_id,

    supplier_id = p_supplier_id,

    project_id = p_project_id,

    currency = p_currency,

    subtotal = ROUND(
      p_subtotal,
      2
    ),

    updated_by = auth.uid(),

    updated_at = CURRENT_TIMESTAMP

  WHERE id = p_expense_id

  RETURNING *
  INTO v_expense;


  RETURN v_expense;

END;
$$;


-- ============================================================
-- 6. DELETE EXPENSE
-- ============================================================
--
-- No se elimina físicamente un gasto que haya entrado en un
-- flujo contable.
--
-- Solo se permite eliminar:
--
--   draft
--
-- y únicamente si no tiene:
--
--   documentos
--   pagos
--   allocations
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_expense(
  p_expense_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_status TEXT;

  v_document_count INTEGER;

  v_payment_count INTEGER;

  v_allocation_count INTEGER;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.delete'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:delete'
  );


  SELECT status
  INTO v_status

  FROM public.expenses

  WHERE id = p_expense_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto % no existe',
      p_expense_id;

  END IF;


  IF v_status <> 'draft' THEN

    RAISE EXCEPTION
      'Solo se pueden eliminar gastos en estado draft';

  END IF;


  SELECT COUNT(*)
  INTO v_document_count

  FROM public.expense_documents

  WHERE expense_id = p_expense_id;


  SELECT COUNT(*)
  INTO v_payment_count

  FROM public.expense_payments

  WHERE expense_id = p_expense_id;


  SELECT COUNT(*)
  INTO v_allocation_count

  FROM public.expense_allocations

  WHERE expense_id = p_expense_id;


  IF v_document_count > 0 THEN

    RAISE EXCEPTION
      'No se puede eliminar un gasto que tiene documentos';

  END IF;


  IF v_payment_count > 0 THEN

    RAISE EXCEPTION
      'No se puede eliminar un gasto que tiene pagos';

  END IF;


  IF v_allocation_count > 0 THEN

    RAISE EXCEPTION
      'No se puede eliminar un gasto que tiene asignaciones';

  END IF;


  DELETE FROM public.expenses

  WHERE id = p_expense_id;


  RETURN TRUE;

END;
$$;


-- ============================================================
-- 7. APPROVE EXPENSE
-- ============================================================

CREATE OR REPLACE FUNCTION public.approve_expense(
  p_expense_id UUID
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense public.expenses;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.approve'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:approve'
  );


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


  IF v_expense.status <> 'pending_review' THEN

    RAISE EXCEPTION
      'Solo se pueden aprobar gastos en estado pending_review';

  END IF;


  IF v_expense.total_amount <= 0 THEN

    RAISE EXCEPTION
      'No se puede aprobar un gasto cuyo importe total sea 0';

  END IF;


  UPDATE public.expenses

  SET
    status = 'pending_payment',
    updated_by = auth.uid(),
    updated_at = CURRENT_TIMESTAMP

  WHERE id = p_expense_id

  RETURNING *
  INTO v_expense;


  RETURN v_expense;

END;
$$;


-- ============================================================
-- 8. REJECT EXPENSE
-- ============================================================

CREATE OR REPLACE FUNCTION public.reject_expense(
  p_expense_id UUID
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense public.expenses;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.approve'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:reject'
  );


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


  IF v_expense.status <> 'pending_review' THEN

    RAISE EXCEPTION
      'Solo se pueden rechazar gastos en estado pending_review';

  END IF;


  UPDATE public.expenses

  SET
    status = 'rejected',
    updated_by = auth.uid(),
    updated_at = CURRENT_TIMESTAMP

  WHERE id = p_expense_id

  RETURNING *
  INTO v_expense;


  RETURN v_expense;

END;
$$;


-- ============================================================
-- 9. CANCEL EXPENSE
-- ============================================================

CREATE OR REPLACE FUNCTION public.cancel_expense(
  p_expense_id UUID
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense public.expenses;

  v_paid_amount NUMERIC(14,2);

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.update'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:cancel'
  );


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


  IF v_expense.status IN (
    'paid',
    'cancelled'
  ) THEN

    RAISE EXCEPTION
      'No se puede cancelar un gasto en estado %',
      v_expense.status;

  END IF;


  SELECT public.get_expense_paid_amount(
    p_expense_id
  )
  INTO v_paid_amount;


  IF v_paid_amount > 0 THEN

    RAISE EXCEPTION
      'No se puede cancelar un gasto que ya tiene pagos confirmados';

  END IF;


  UPDATE public.expenses

  SET
    status = 'cancelled',
    updated_by = auth.uid(),
    updated_at = CURRENT_TIMESTAMP

  WHERE id = p_expense_id

  RETURNING *
  INTO v_expense;


  RETURN v_expense;

END;
$$;


-- ============================================================
-- 10. SUBMIT EXPENSE FOR REVIEW
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_expense_for_review(
  p_expense_id UUID
)
RETURNS public.expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense public.expenses;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.update'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:submit_review'
  );


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


  IF v_expense.status <> 'draft' THEN

    RAISE EXCEPTION
      'Solo se pueden enviar a revisión gastos en estado draft';

  END IF;


  IF v_expense.total_amount <= 0 THEN

    RAISE EXCEPTION
      'El gasto debe tener un importe total superior a 0';

  END IF;


  UPDATE public.expenses

  SET
    status = 'pending_review',
    updated_by = auth.uid(),
    updated_at = CURRENT_TIMESTAMP

  WHERE id = p_expense_id

  RETURNING *
  INTO v_expense;


  RETURN v_expense;

END;
$$;


-- ============================================================
-- 11. CREATE EXPENSE TAX LINE
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_expense_tax_line(
  p_expense_id UUID,
  p_tax_type TEXT,
  p_tax_rate NUMERIC,
  p_taxable_base NUMERIC,
  p_tax_amount NUMERIC,
  p_deductible_amount NUMERIC DEFAULT 0
)
RETURNS public.expense_tax_lines
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_line public.expense_tax_lines;

  v_status TEXT;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.update'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:tax'
  );


  SELECT status
  INTO v_status

  FROM public.expenses

  WHERE id = p_expense_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto % no existe',
      p_expense_id;

  END IF;


  IF v_status IN (
    'paid',
    'cancelled'
  ) THEN

    RAISE EXCEPTION
      'No se pueden modificar impuestos de un gasto en estado %',
      v_status;

  END IF;


  IF p_tax_rate < 0
     OR p_tax_rate > 100 THEN

    RAISE EXCEPTION
      'El porcentaje fiscal debe estar entre 0 y 100';

  END IF;


  IF p_taxable_base < 0
     OR p_tax_amount < 0
     OR p_deductible_amount < 0 THEN

    RAISE EXCEPTION
      'Los importes fiscales no pueden ser negativos';

  END IF;


  INSERT INTO public.expense_tax_lines (
    expense_id,
    tax_type,
    tax_rate,
    taxable_base,
    tax_amount,
    deductible_amount
  )
  VALUES (
    p_expense_id,
    p_tax_type,
    ROUND(p_tax_rate, 4),
    ROUND(p_taxable_base, 2),
    ROUND(p_tax_amount, 2),
    ROUND(p_deductible_amount, 2)
  )
  RETURNING *
  INTO v_line;


  RETURN v_line;

END;
$$;


-- ============================================================
-- 12. DELETE EXPENSE TAX LINE
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_expense_tax_line(
  p_tax_line_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense_id UUID;

  v_status TEXT;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.update'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:tax_delete'
  );


  SELECT
    etl.expense_id,
    e.status

  INTO
    v_expense_id,
    v_status

  FROM public.expense_tax_lines etl

  JOIN public.expenses e
    ON e.id = etl.expense_id

  WHERE etl.id = p_tax_line_id

  FOR UPDATE OF e;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'La línea fiscal % no existe',
      p_tax_line_id;

  END IF;


  IF v_status IN (
    'paid',
    'cancelled'
  ) THEN

    RAISE EXCEPTION
      'No se puede eliminar una línea fiscal de un gasto en estado %',
      v_status;

  END IF;


  DELETE FROM public.expense_tax_lines

  WHERE id = p_tax_line_id;


  RETURN TRUE;

END;
$$;


-- ============================================================
-- 13. CREATE EXPENSE PAYMENT
-- ============================================================
--
-- Los pagos se crean inicialmente como pending.
--
-- Para confirmar el pago utilizaremos la RPC específica
-- confirm_expense_payment().
--
-- Esto evita que el frontend pueda fabricar directamente
-- pagos succeeded.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_expense_payment(
  p_expense_id UUID,
  p_amount NUMERIC,
  p_payment_date TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  p_payment_method TEXT DEFAULT 'bank_transfer',
  p_reference TEXT DEFAULT NULL
)
RETURNS public.expense_payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_payment public.expense_payments;

  v_status TEXT;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.pay'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:payment_create'
  );


  SELECT status
  INTO v_status

  FROM public.expenses

  WHERE id = p_expense_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto % no existe',
      p_expense_id;

  END IF;


  IF v_status NOT IN (
    'pending_payment',
    'partially_paid'
  ) THEN

    RAISE EXCEPTION
      'El gasto no está pendiente de pago. Estado actual: %',
      v_status;

  END IF;


  IF p_amount <= 0 THEN

    RAISE EXCEPTION
      'El importe del pago debe ser mayor que 0';

  END IF;


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
    COALESCE(p_payment_date, CURRENT_TIMESTAMP),
    p_payment_method,
    NULLIF(BTRIM(p_reference), ''),
    'pending',
    auth.uid()
  )
  RETURNING *
  INTO v_payment;


  RETURN v_payment;

END;
$$;


-- ============================================================
-- 14. CONFIRM EXPENSE PAYMENT
-- ============================================================

CREATE OR REPLACE FUNCTION public.confirm_expense_payment(
  p_payment_id UUID
)
RETURNS public.expense_payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_payment public.expense_payments;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.pay'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:payment_confirm'
  );


  SELECT *
  INTO v_payment

  FROM public.expense_payments

  WHERE id = p_payment_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El pago % no existe',
      p_payment_id;

  END IF;


  IF v_payment.status <> 'pending' THEN

    RAISE EXCEPTION
      'Solo se pueden confirmar pagos pending';

  END IF;


  UPDATE public.expense_payments

  SET
    status = 'succeeded',
    updated_at = CURRENT_TIMESTAMP

  WHERE id = p_payment_id

  RETURNING *
  INTO v_payment;


  RETURN v_payment;

END;
$$;


-- ============================================================
-- 15. CANCEL EXPENSE PAYMENT
-- ============================================================

CREATE OR REPLACE FUNCTION public.cancel_expense_payment(
  p_payment_id UUID
)
RETURNS public.expense_payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_payment public.expense_payments;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.pay'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:payment_cancel'
  );


  SELECT *
  INTO v_payment

  FROM public.expense_payments

  WHERE id = p_payment_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El pago % no existe',
      p_payment_id;

  END IF;


  IF v_payment.status <> 'pending' THEN

    RAISE EXCEPTION
      'Solo se pueden cancelar pagos pending';

  END IF;


  UPDATE public.expense_payments

  SET
    status = 'cancelled',
    updated_at = CURRENT_TIMESTAMP

  WHERE id = p_payment_id

  RETURNING *
  INTO v_payment;


  RETURN v_payment;

END;
$$;


-- ============================================================
-- 16. ATTACH EXPENSE DOCUMENT
-- ============================================================
--
-- El PDF debe existir físicamente en Storage antes de llamar
-- a esta RPC.
--
-- Ruta:
--
--   expense_id/<uuid>.pdf
--
-- Se comprueba:
--
--   - bucket correcto;
--   - ruta correcta;
--   - objeto existente;
--   - MIME PDF;
--   - tamaño <= 20 MiB;
--   - hash SHA-256 con formato correcto.
--
-- El hash debe haber sido calculado por el backend sobre los
-- bytes reales del archivo.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_expense_document(
  p_expense_id UUID,
  p_document_type TEXT,
  p_file_name TEXT,
  p_storage_path TEXT,
  p_mime_type TEXT,
  p_file_size BIGINT,
  p_document_sha256 TEXT
)
RETURNS public.expense_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_document public.expense_documents;

  v_status TEXT;

  v_object_exists BOOLEAN;

  v_object_size BIGINT;

  v_object_mime TEXT;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.documents'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:document_attach'
  );


  SELECT status
  INTO v_status

  FROM public.expenses

  WHERE id = p_expense_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto % no existe',
      p_expense_id;

  END IF;


  IF v_status = 'cancelled' THEN

    RAISE EXCEPTION
      'No se pueden adjuntar documentos a un gasto cancelado';

  END IF;


  IF p_mime_type <> 'application/pdf' THEN

    RAISE EXCEPTION
      'El documento debe ser PDF';

  END IF;


  IF p_file_size <= 0
     OR p_file_size > 20971520 THEN

    RAISE EXCEPTION
      'El documento debe tener un tamaño entre 1 byte y 20 MiB';

  END IF;


  IF p_document_sha256 !~ '^[0-9A-Fa-f]{64}$' THEN

    RAISE EXCEPTION
      'El SHA-256 del documento no tiene un formato válido';

  END IF;


  -- ----------------------------------------------------------
  -- El objeto debe existir físicamente.
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM storage.objects
    WHERE bucket_id = 'expense-documents'
      AND name = p_storage_path
  )
  INTO v_object_exists;


  IF NOT v_object_exists THEN

    RAISE EXCEPTION
      'El documento no existe en Storage';

  END IF;


  -- ----------------------------------------------------------
  -- Comprobar metadatos reales del objeto.
  -- ----------------------------------------------------------

  SELECT
    COALESCE(
      (metadata ->> 'size')::BIGINT,
      NULL
    ),
    COALESCE(
      metadata ->> 'mimetype',
      NULL
    )

  INTO
    v_object_size,
    v_object_mime

  FROM storage.objects

  WHERE bucket_id = 'expense-documents'
    AND name = p_storage_path;


  IF v_object_size IS NOT NULL
     AND v_object_size <> p_file_size THEN

    RAISE EXCEPTION
      'El tamaño declarado no coincide con el objeto de Storage';

  END IF;


  IF v_object_mime IS NOT NULL
     AND v_object_mime <> 'application/pdf' THEN

    RAISE EXCEPTION
      'El objeto de Storage no es un PDF';

  END IF;


  INSERT INTO public.expense_documents (
    expense_id,
    document_type,
    file_name,
    storage_path,
    mime_type,
    file_size,
    document_sha256,
    uploaded_by,
    uploaded_at
  )
  VALUES (
    p_expense_id,
    p_document_type,
    BTRIM(p_file_name),
    p_storage_path,
    p_mime_type,
    p_file_size,
    LOWER(p_document_sha256),
    auth.uid(),
    CURRENT_TIMESTAMP
  )
  RETURNING *
  INTO v_document;


  RETURN v_document;

END;
$$;


-- ============================================================
-- 17. DELETE EXPENSE DOCUMENT
-- ============================================================
--
-- La fila de base de datos se elimina mediante RPC.
--
-- El objeto físico de Storage deberá eliminarse desde el
-- backend/service role utilizando la ruta devuelta antes de
-- completar el proceso.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_expense_document(
  p_document_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_storage_path TEXT;

  v_expense_id UUID;

  v_status TEXT;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.documents'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:document_delete'
  );


  SELECT
    ed.storage_path,
    ed.expense_id,
    e.status

  INTO
    v_storage_path,
    v_expense_id,
    v_status

  FROM public.expense_documents ed

  JOIN public.expenses e
    ON e.id = ed.expense_id

  WHERE ed.id = p_document_id

  FOR UPDATE OF ed;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El documento % no existe',
      p_document_id;

  END IF;


  IF v_status IN (
    'paid',
    'cancelled'
  ) THEN

    RAISE EXCEPTION
      'No se puede eliminar documentación de un gasto en estado %',
      v_status;

  END IF;


  DELETE FROM public.expense_documents

  WHERE id = p_document_id;


  RETURN v_storage_path;

END;
$$;


-- ============================================================
-- 18. CREATE EXPENSE ALLOCATION
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_expense_allocation(
  p_expense_id UUID,
  p_project_id UUID,
  p_amount NUMERIC,
  p_description TEXT DEFAULT NULL
)
RETURNS public.expense_allocations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_allocation public.expense_allocations;

  v_status TEXT;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.allocate'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:allocate'
  );


  SELECT status
  INTO v_status

  FROM public.expenses

  WHERE id = p_expense_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto % no existe',
      p_expense_id;

  END IF;


  IF v_status IN (
    'paid',
    'cancelled'
  ) THEN

    RAISE EXCEPTION
      'No se puede modificar la asignación de un gasto en estado %',
      v_status;

  END IF;


  INSERT INTO public.expense_allocations (
    expense_id,
    project_id,
    amount,
    description
  )
  VALUES (
    p_expense_id,
    p_project_id,
    ROUND(p_amount, 2),
    NULLIF(BTRIM(p_description), '')
  )
  RETURNING *
  INTO v_allocation;


  RETURN v_allocation;

END;
$$;


-- ============================================================
-- 19. DELETE EXPENSE ALLOCATION
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_expense_allocation(
  p_allocation_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense_id UUID;

  v_status TEXT;

BEGIN

  PERFORM public.require_expense_permission(
    'expenses.allocate'
  );

  PERFORM public.consume_expense_worker_rate_limit(
    'expenses:allocate_delete'
  );


  SELECT
    ea.expense_id,
    e.status

  INTO
    v_expense_id,
    v_status

  FROM public.expense_allocations ea

  JOIN public.expenses e
    ON e.id = ea.expense_id

  WHERE ea.id = p_allocation_id

  FOR UPDATE OF ea, e;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'La asignación % no existe',
      p_allocation_id;

  END IF;


  IF v_status IN (
    'paid',
    'cancelled'
  ) THEN

    RAISE EXCEPTION
      'No se puede modificar la asignación de un gasto en estado %',
      v_status;

  END IF;


  DELETE FROM public.expense_allocations

  WHERE id = p_allocation_id;


  RETURN TRUE;

END;
$$;


-- ============================================================
-- 20. PERMISOS EXECUTE DE LAS RPC
-- ============================================================
--
-- Las RPC se pueden invocar desde authenticated porque el
-- control real está dentro de require_expense_permission().
--
-- PUBLIC y anon no pueden utilizarlas.
--
-- ============================================================

REVOKE EXECUTE
ON FUNCTION public.require_expense_permission(TEXT)
FROM PUBLIC, anon, authenticated;


REVOKE EXECUTE
ON FUNCTION public.consume_expense_worker_rate_limit(TEXT)
FROM PUBLIC, anon, authenticated;


-- ------------------------------------------------------------
-- Expense CRUD
-- ------------------------------------------------------------

REVOKE EXECUTE
ON FUNCTION public.create_expense(
  DATE,
  TEXT,
  TEXT,
  UUID,
  UUID,
  UUID,
  TEXT,
  NUMERIC
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_expense(
  DATE,
  TEXT,
  TEXT,
  UUID,
  UUID,
  UUID,
  TEXT,
  NUMERIC
)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.update_expense(
  UUID,
  DATE,
  TEXT,
  TEXT,
  UUID,
  UUID,
  UUID,
  TEXT,
  NUMERIC
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_expense(
  UUID,
  DATE,
  TEXT,
  TEXT,
  UUID,
  UUID,
  UUID,
  TEXT,
  NUMERIC
)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.delete_expense(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_expense(UUID)
TO authenticated;


-- ------------------------------------------------------------
-- Workflow
-- ------------------------------------------------------------

REVOKE EXECUTE
ON FUNCTION public.submit_expense_for_review(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.submit_expense_for_review(UUID)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.approve_expense(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.approve_expense(UUID)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.reject_expense(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.reject_expense(UUID)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.cancel_expense(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.cancel_expense(UUID)
TO authenticated;


-- ------------------------------------------------------------
-- Fiscal
-- ------------------------------------------------------------

REVOKE EXECUTE
ON FUNCTION public.create_expense_tax_line(
  UUID,
  TEXT,
  NUMERIC,
  NUMERIC,
  NUMERIC,
  NUMERIC
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_expense_tax_line(
  UUID,
  TEXT,
  NUMERIC,
  NUMERIC,
  NUMERIC,
  NUMERIC
)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.delete_expense_tax_line(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_expense_tax_line(UUID)
TO authenticated;


-- ------------------------------------------------------------
-- Payments
-- ------------------------------------------------------------

REVOKE EXECUTE
ON FUNCTION public.create_expense_payment(
  UUID,
  NUMERIC,
  TIMESTAMPTZ,
  TEXT,
  TEXT
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_expense_payment(
  UUID,
  NUMERIC,
  TIMESTAMPTZ,
  TEXT,
  TEXT
)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.confirm_expense_payment(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.confirm_expense_payment(UUID)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.cancel_expense_payment(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.cancel_expense_payment(UUID)
TO authenticated;


-- ------------------------------------------------------------
-- Documents
-- ------------------------------------------------------------

REVOKE EXECUTE
ON FUNCTION public.attach_expense_document(
  UUID,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  BIGINT,
  TEXT
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.attach_expense_document(
  UUID,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  BIGINT,
  TEXT
)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.delete_expense_document(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_expense_document(UUID)
TO authenticated;


-- ------------------------------------------------------------
-- Allocations
-- ------------------------------------------------------------

REVOKE EXECUTE
ON FUNCTION public.create_expense_allocation(
  UUID,
  UUID,
  NUMERIC,
  TEXT
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_expense_allocation(
  UUID,
  UUID,
  NUMERIC,
  TEXT
)
TO authenticated;


REVOKE EXECUTE
ON FUNCTION public.delete_expense_allocation(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_expense_allocation(UUID)
TO authenticated;


-- ============================================================
-- 21. REVOCAR ESCRITURA DIRECTA
-- ============================================================
--
-- A partir de esta migración, el frontend no debe poder hacer:
--
--   INSERT expenses
--   UPDATE expenses
--   DELETE expenses
--
-- ni escribir directamente sobre las tablas secundarias.
--
-- La lectura se terminará de controlar en 076 mediante RLS.
--
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON public.expenses
FROM anon, authenticated;


REVOKE INSERT, UPDATE, DELETE
ON public.expense_tax_lines
FROM anon, authenticated;


REVOKE INSERT, UPDATE, DELETE
ON public.expense_documents
FROM anon, authenticated;


REVOKE INSERT, UPDATE, DELETE
ON public.expense_payments
FROM anon, authenticated;


REVOKE INSERT, UPDATE, DELETE
ON public.expense_allocations
FROM anon, authenticated;


-- ============================================================
-- 22. COMMENTS
-- ============================================================

COMMENT ON FUNCTION public.create_expense(
  DATE,
  TEXT,
  TEXT,
  UUID,
  UUID,
  UUID,
  TEXT,
  NUMERIC
)
IS
'Creates an internal Modira expense through a controlled worker RPC.';


COMMENT ON FUNCTION public.update_expense(
  UUID,
  DATE,
  TEXT,
  TEXT,
  UUID,
  UUID,
  UUID,
  TEXT,
  NUMERIC
)
IS
'Updates an internal Modira expense through a controlled worker RPC.';


COMMENT ON FUNCTION public.delete_expense(UUID)
IS
'Deletes a draft internal Modira expense when no dependent accounting records exist.';


COMMENT ON FUNCTION public.approve_expense(UUID)
IS
'Approves a reviewed internal Modira expense and moves it to pending_payment.';


COMMENT ON FUNCTION public.create_expense_payment(
  UUID,
  NUMERIC,
  TIMESTAMPTZ,
  TEXT,
  TEXT
)
IS
'Creates a pending payment for an internal Modira expense.';


COMMENT ON FUNCTION public.confirm_expense_payment(UUID)
IS
'Confirms a pending internal Modira expense payment.';


COMMENT ON FUNCTION public.attach_expense_document(
  UUID,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  BIGINT,
  TEXT
)
IS
'Registers a PDF already uploaded to the private expense-documents bucket and validates its metadata.';


-- ============================================================
-- 23. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE

  v_expense_functions INTEGER;

  v_write_privileges INTEGER;

BEGIN

  -- ----------------------------------------------------------
  -- Comprobar RPC principales
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_expense_functions

  FROM pg_proc p

  JOIN pg_namespace n
    ON n.oid = p.pronamespace

  WHERE n.nspname = 'public'

    AND p.proname IN (
      'create_expense',
      'update_expense',
      'delete_expense',
      'submit_expense_for_review',
      'approve_expense',
      'reject_expense',
      'cancel_expense',
      'create_expense_tax_line',
      'delete_expense_tax_line',
      'create_expense_payment',
      'confirm_expense_payment',
      'cancel_expense_payment',
      'attach_expense_document',
      'delete_expense_document',
      'create_expense_allocation',
      'delete_expense_allocation'
    );


  IF v_expense_functions < 16 THEN

    RAISE EXCEPTION
      '124_expenses_worker_rpcs: faltan RPCs de gastos. Encontradas: %',
      v_expense_functions;

  END IF;


  -- ----------------------------------------------------------
  -- Comprobar ausencia de escritura directa
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_write_privileges

  FROM information_schema.role_table_grants

  WHERE grantee IN (
    'anon',
    'authenticated'
  )

    AND privilege_type IN (
      'INSERT',
      'UPDATE',
      'DELETE'
    )

    AND table_name IN (
      'expenses',
      'expense_tax_lines',
      'expense_documents',
      'expense_payments',
      'expense_allocations'
    );


  IF v_write_privileges > 0 THEN

    RAISE EXCEPTION
      '124_expenses_worker_rpcs: existen privilegios directos de escritura sobre tablas de gastos: %',
      v_write_privileges;

  END IF;


  RAISE NOTICE
    '124_expenses_worker_rpcs: migración completada correctamente.';

END;
$$;


COMMIT;