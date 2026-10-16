-- Migration 134 — Modira recurring expense forecasts and configurable approval rules
-- This migration creates forecasts only. It NEVER creates or pays real expenses automatically.
-- Existing expense status/payment workflow is preserved; submission for review is made rule-aware.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Permission catalog and role grants
-- -----------------------------------------------------------------------------
INSERT INTO public.worker_permissions (code, resource, action, description)
VALUES
  ('expenses.recurring.read', 'expenses.recurring', 'read', 'Consultar previsiones y configuraciones de gastos recurrentes.'),
  ('expenses.recurring.create', 'expenses.recurring', 'create', 'Crear configuraciones de gastos recurrentes.'),
  ('expenses.recurring.update', 'expenses.recurring', 'update', 'Modificar, pausar y reanudar gastos recurrentes.'),
  ('expenses.approval_rules.manage', 'expenses.approval_rules', 'manage', 'Configurar los límites y reglas de aprobación de gastos.'),
  ('expenses.approve', 'expenses', 'approve', 'Aprobar o rechazar gastos y configuraciones recurrentes que requieran revisión.')
ON CONFLICT (code) DO NOTHING;

-- Direction manages approval rules and recurring configuration. Accounting can view
-- forecasts and manage recurring templates, but does not receive approval-rule control.
INSERT INTO public.worker_role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.worker_roles r
JOIN public.worker_permissions p ON p.code IN (
  'expenses.recurring.read',
  'expenses.recurring.create',
  'expenses.recurring.update',
  'expenses.approval_rules.manage',
  'expenses.approve'
)
WHERE r.code = 'direction'
ON CONFLICT DO NOTHING;

INSERT INTO public.worker_role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.worker_roles r
JOIN public.worker_permissions p ON p.code IN (
  'expenses.recurring.read',
  'expenses.recurring.create',
  'expenses.recurring.update'
)
WHERE r.code = 'accounting'
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 2. Approval rules: optional global threshold plus category-specific overrides
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expense_approval_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid NULL REFERENCES public.expense_categories(id) ON DELETE CASCADE,
  minimum_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (minimum_amount >= 0),
  requires_approval boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid NULL,
  updated_by uuid NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- One global rule (category_id NULL) and one rule per category.
CREATE UNIQUE INDEX IF NOT EXISTS expense_approval_rules_scope_uidx
  ON public.expense_approval_rules (COALESCE(category_id, '00000000-0000-0000-0000-000000000000'::uuid));

ALTER TABLE public.expense_approval_rules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS expense_approval_rules_select ON public.expense_approval_rules;
CREATE POLICY expense_approval_rules_select
  ON public.expense_approval_rules FOR SELECT TO authenticated
  USING (
    public.current_user_is_worker()
    AND (
      public.current_worker_has_permission('expenses.approval_rules.manage')
      OR public.current_worker_has_permission('expenses.read')
    )
  );

REVOKE INSERT, UPDATE, DELETE ON public.expense_approval_rules FROM anon, authenticated;
GRANT SELECT ON public.expense_approval_rules TO authenticated;

-- Return whether a real expense or recurring template must be reviewed.
-- A category-specific rule overrides the global rule; without an applicable active
-- rule, approval is not mandatory.
CREATE OR REPLACE FUNCTION public.expense_requires_approval(
  p_amount numeric,
  p_category_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_requires boolean;
BEGIN
  SELECT r.requires_approval AND COALESCE(p_amount, 0) >= r.minimum_amount
    INTO v_requires
  FROM public.expense_approval_rules r
  WHERE r.is_active
    AND (r.category_id = p_category_id OR r.category_id IS NULL)
  ORDER BY (r.category_id IS NOT NULL) DESC
  LIMIT 1;

  RETURN COALESCE(v_requires, false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_expense_approval_rule(
  p_category_id uuid,
  p_minimum_amount numeric,
  p_requires_approval boolean,
  p_is_active boolean DEFAULT true
)
RETURNS public.expense_approval_rules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_rule public.expense_approval_rules;
BEGIN
  PERFORM public.require_expense_permission('expenses.approval_rules.manage');
  PERFORM public.consume_expense_worker_rate_limit('expenses:approval_rule');

  IF p_minimum_amount IS NULL OR p_minimum_amount < 0 THEN
    RAISE EXCEPTION 'El límite mínimo debe ser un importe igual o superior a 0';
  END IF;

  INSERT INTO public.expense_approval_rules (
    category_id, minimum_amount, requires_approval, is_active,
    created_by, updated_by
  ) VALUES (
    p_category_id, ROUND(p_minimum_amount, 2), COALESCE(p_requires_approval, true),
    COALESCE(p_is_active, true), auth.uid(), auth.uid()
  )
  ON CONFLICT ((COALESCE(category_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  DO UPDATE SET
    minimum_amount = EXCLUDED.minimum_amount,
    requires_approval = EXCLUDED.requires_approval,
    is_active = EXCLUDED.is_active,
    updated_by = auth.uid(),
    updated_at = CURRENT_TIMESTAMP
  RETURNING * INTO v_rule;

  RETURN v_rule;
END;
$function$;

REVOKE ALL ON FUNCTION public.expense_requires_approval(numeric, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.expense_requires_approval(numeric, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.set_expense_approval_rule(uuid, numeric, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_expense_approval_rule(uuid, numeric, boolean, boolean) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Recurring templates and forecast occurrences (not actual expenses)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.recurring_expense_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  description text NOT NULL CHECK (length(btrim(description)) BETWEEN 1 AND 5000),
  expense_type text NOT NULL CHECK (expense_type = ANY (ARRAY[
    'supplier_invoice','employee_expense','travel','meals','corporate_card','subscription','tax','other'
  ])),
  category_id uuid NULL REFERENCES public.expense_categories(id) ON DELETE SET NULL,
  supplier_id uuid NULL REFERENCES public.suppliers(id) ON DELETE SET NULL,
  project_id uuid NULL REFERENCES public.projects(id) ON DELETE SET NULL,
  currency varchar(3) NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
  frequency text NOT NULL CHECK (frequency IN ('weekly','monthly','quarterly','yearly')),
  start_date date NOT NULL,
  end_date date NULL,
  day_of_month smallint NULL CHECK (day_of_month BETWEEN 1 AND 31),
  subtotal numeric(14,2) NOT NULL CHECK (subtotal >= 0),
  total_tax numeric(14,2) NOT NULL DEFAULT 0 CHECK (total_tax >= 0),
  total_withholding numeric(14,2) NOT NULL DEFAULT 0 CHECK (total_withholding >= 0),
  total_amount numeric(14,2) NOT NULL CHECK (total_amount >= 0),
  tax_config jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(tax_config) = 'array'),
  approval_status text NOT NULL DEFAULT 'approved'
    CHECK (approval_status IN ('pending_review','approved','rejected')),
  lifecycle_status text NOT NULL DEFAULT 'active'
    CHECK (lifecycle_status IN ('active','paused','cancelled')),
  approved_by uuid NULL,
  approved_at timestamptz NULL,
  created_by uuid NOT NULL,
  updated_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (end_date IS NULL OR end_date >= start_date),
  CHECK (total_amount = GREATEST(ROUND(subtotal + total_tax - total_withholding, 2), 0))
);

CREATE TABLE IF NOT EXISTS public.recurring_expense_forecasts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recurring_template_id uuid NOT NULL REFERENCES public.recurring_expense_templates(id) ON DELETE RESTRICT,
  occurrence_date date NOT NULL,
  description text NOT NULL,
  currency varchar(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  subtotal numeric(14,2) NOT NULL CHECK (subtotal >= 0),
  total_tax numeric(14,2) NOT NULL CHECK (total_tax >= 0),
  total_withholding numeric(14,2) NOT NULL CHECK (total_withholding >= 0),
  total_amount numeric(14,2) NOT NULL CHECK (total_amount >= 0),
  category_id uuid NULL REFERENCES public.expense_categories(id) ON DELETE SET NULL,
  supplier_id uuid NULL REFERENCES public.suppliers(id) ON DELETE SET NULL,
  project_id uuid NULL REFERENCES public.projects(id) ON DELETE SET NULL,
  tax_config jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(tax_config) = 'array'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','converted','cancelled')),
  linked_expense_id uuid NULL REFERENCES public.expenses(id) ON DELETE RESTRICT,
  generated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (recurring_template_id, occurrence_date),
  UNIQUE (linked_expense_id),
  CHECK (total_amount = GREATEST(ROUND(subtotal + total_tax - total_withholding, 2), 0)),
  CHECK ((status = 'converted' AND linked_expense_id IS NOT NULL) OR (status <> 'converted' AND linked_expense_id IS NULL))
);

CREATE INDEX IF NOT EXISTS recurring_expense_templates_active_idx
  ON public.recurring_expense_templates (lifecycle_status, approval_status, start_date);
CREATE INDEX IF NOT EXISTS recurring_expense_forecasts_date_idx
  ON public.recurring_expense_forecasts (occurrence_date, status);

ALTER TABLE public.recurring_expense_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recurring_expense_forecasts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS recurring_expense_templates_select ON public.recurring_expense_templates;
CREATE POLICY recurring_expense_templates_select
  ON public.recurring_expense_templates FOR SELECT TO authenticated
  USING (public.current_user_is_worker() AND public.current_worker_has_permission('expenses.recurring.read'));

DROP POLICY IF EXISTS recurring_expense_forecasts_select ON public.recurring_expense_forecasts;
CREATE POLICY recurring_expense_forecasts_select
  ON public.recurring_expense_forecasts FOR SELECT TO authenticated
  USING (public.current_user_is_worker() AND public.current_worker_has_permission('expenses.recurring.read'));

REVOKE INSERT, UPDATE, DELETE ON public.recurring_expense_templates FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.recurring_expense_forecasts FROM anon, authenticated;
GRANT SELECT ON public.recurring_expense_templates, public.recurring_expense_forecasts TO authenticated;

-- Create a recurring template. Approval is required only when an active configured
-- rule applies to the amount/category. Forecasts are emitted only after approval.
CREATE OR REPLACE FUNCTION public.create_recurring_expense_template(
  p_description text,
  p_expense_type text,
  p_category_id uuid,
  p_supplier_id uuid,
  p_project_id uuid,
  p_currency text,
  p_frequency text,
  p_start_date date,
  p_end_date date,
  p_day_of_month smallint,
  p_subtotal numeric,
  p_total_tax numeric,
  p_total_withholding numeric,
  p_tax_config jsonb DEFAULT '[]'::jsonb
)
RETURNS public.recurring_expense_templates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_template public.recurring_expense_templates;
  v_total numeric(14,2);
  v_approval_status text;
BEGIN
  PERFORM public.require_expense_permission('expenses.recurring.create');
  PERFORM public.consume_expense_worker_rate_limit('expenses:recurring_create');

  IF p_description IS NULL OR length(btrim(p_description)) NOT BETWEEN 1 AND 5000 THEN
    RAISE EXCEPTION 'La descripción debe tener entre 1 y 5000 caracteres';
  END IF;
  IF p_frequency NOT IN ('weekly','monthly','quarterly','yearly') THEN
    RAISE EXCEPTION 'Periodicidad no válida';
  END IF;
  IF p_start_date IS NULL OR (p_end_date IS NOT NULL AND p_end_date < p_start_date) THEN
    RAISE EXCEPTION 'El intervalo de fechas no es válido';
  END IF;
  IF p_subtotal IS NULL OR p_subtotal < 0 OR COALESCE(p_total_tax,0) < 0 OR COALESCE(p_total_withholding,0) < 0 THEN
    RAISE EXCEPTION 'Los importes no pueden ser negativos';
  END IF;
  IF COALESCE(p_currency, 'EUR') !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'La moneda debe ser un código ISO de tres letras en mayúsculas';
  END IF;
  IF p_frequency IN ('monthly','quarterly','yearly') AND p_day_of_month IS NOT NULL
     AND p_day_of_month NOT BETWEEN 1 AND 31 THEN
    RAISE EXCEPTION 'El día del mes debe estar entre 1 y 31';
  END IF;
  IF p_tax_config IS NOT NULL AND jsonb_typeof(p_tax_config) <> 'array' THEN
    RAISE EXCEPTION 'La configuración de impuestos debe ser una lista JSON';
  END IF;

  v_total := GREATEST(ROUND(COALESCE(p_subtotal,0) + COALESCE(p_total_tax,0) - COALESCE(p_total_withholding,0), 2), 0);
  v_approval_status := CASE WHEN public.expense_requires_approval(v_total, p_category_id) THEN 'pending_review' ELSE 'approved' END;

  INSERT INTO public.recurring_expense_templates (
    description, expense_type, category_id, supplier_id, project_id, currency,
    frequency, start_date, end_date, day_of_month, subtotal, total_tax,
    total_withholding, total_amount, tax_config, approval_status,
    created_by, updated_by
  ) VALUES (
    btrim(p_description), p_expense_type, p_category_id, p_supplier_id, p_project_id,
    COALESCE(p_currency, 'EUR'), p_frequency, p_start_date, p_end_date, p_day_of_month,
    ROUND(p_subtotal,2), ROUND(COALESCE(p_total_tax,0),2), ROUND(COALESCE(p_total_withholding,0),2),
    v_total, COALESCE(p_tax_config,'[]'::jsonb), v_approval_status, auth.uid(), auth.uid()
  ) RETURNING * INTO v_template;

  RETURN v_template;
END;
$function$;

CREATE OR REPLACE FUNCTION public.review_recurring_expense_template(
  p_template_id uuid,
  p_decision text
)
RETURNS public.recurring_expense_templates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_template public.recurring_expense_templates;
BEGIN
  PERFORM public.require_expense_permission('expenses.approve');
  PERFORM public.consume_expense_worker_rate_limit('expenses:recurring_review');

  IF p_decision NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'La decisión debe ser approved o rejected';
  END IF;

  SELECT * INTO v_template
  FROM public.recurring_expense_templates
  WHERE id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'La configuración recurrente no existe'; END IF;
  IF v_template.approval_status <> 'pending_review' THEN
    RAISE EXCEPTION 'Solo se pueden revisar configuraciones pendientes de aprobación';
  END IF;

  UPDATE public.recurring_expense_templates
  SET approval_status = p_decision,
      approved_by = CASE WHEN p_decision = 'approved' THEN auth.uid() ELSE NULL END,
      approved_at = CASE WHEN p_decision = 'approved' THEN CURRENT_TIMESTAMP ELSE NULL END,
      updated_by = auth.uid(),
      updated_at = CURRENT_TIMESTAMP
  WHERE id = p_template_id
  RETURNING * INTO v_template;

  RETURN v_template;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_recurring_expense_template_status(
  p_template_id uuid,
  p_status text
)
RETURNS public.recurring_expense_templates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_template public.recurring_expense_templates;
BEGIN
  PERFORM public.require_expense_permission('expenses.recurring.update');
  PERFORM public.consume_expense_worker_rate_limit('expenses:recurring_status');

  IF p_status NOT IN ('active','paused','cancelled') THEN
    RAISE EXCEPTION 'Estado de recurrencia no válido';
  END IF;

  UPDATE public.recurring_expense_templates
  SET lifecycle_status = p_status,
      updated_by = auth.uid(),
      updated_at = CURRENT_TIMESTAMP
  WHERE id = p_template_id
  RETURNING * INTO v_template;

  IF NOT FOUND THEN RAISE EXCEPTION 'La configuración recurrente no existe'; END IF;
  RETURN v_template;
END;
$function$;


-- Update a recurring template. Material changes re-evaluate approval and refresh
-- only future, still-pending forecast snapshots; past/converted occurrences remain immutable.
CREATE OR REPLACE FUNCTION public.update_recurring_expense_template(
  p_template_id uuid,
  p_description text,
  p_expense_type text,
  p_category_id uuid,
  p_supplier_id uuid,
  p_project_id uuid,
  p_currency text,
  p_frequency text,
  p_start_date date,
  p_end_date date,
  p_day_of_month smallint,
  p_subtotal numeric,
  p_total_tax numeric,
  p_total_withholding numeric,
  p_tax_config jsonb DEFAULT '[]'::jsonb
)
RETURNS public.recurring_expense_templates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_template public.recurring_expense_templates;
  v_total numeric(14,2);
  v_approval_status text;
BEGIN
  PERFORM public.require_expense_permission('expenses.recurring.update');
  PERFORM public.consume_expense_worker_rate_limit('expenses:recurring_update');

  SELECT * INTO v_template
  FROM public.recurring_expense_templates
  WHERE id = p_template_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La configuración recurrente no existe'; END IF;
  IF v_template.lifecycle_status = 'cancelled' THEN
    RAISE EXCEPTION 'No se puede modificar una recurrencia cancelada';
  END IF;
  IF p_description IS NULL OR length(btrim(p_description)) NOT BETWEEN 1 AND 5000 THEN
    RAISE EXCEPTION 'La descripción debe tener entre 1 y 5000 caracteres';
  END IF;
  IF p_frequency NOT IN ('weekly','monthly','quarterly','yearly') THEN
    RAISE EXCEPTION 'Periodicidad no válida';
  END IF;
  IF p_start_date IS NULL OR (p_end_date IS NOT NULL AND p_end_date < p_start_date) THEN
    RAISE EXCEPTION 'El intervalo de fechas no es válido';
  END IF;
  IF p_subtotal IS NULL OR p_subtotal < 0 OR COALESCE(p_total_tax,0) < 0 OR COALESCE(p_total_withholding,0) < 0 THEN
    RAISE EXCEPTION 'Los importes no pueden ser negativos';
  END IF;
  IF COALESCE(p_currency, 'EUR') !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'La moneda debe ser un código ISO de tres letras en mayúsculas';
  END IF;
  IF p_tax_config IS NOT NULL AND jsonb_typeof(p_tax_config) <> 'array' THEN
    RAISE EXCEPTION 'La configuración de impuestos debe ser una lista JSON';
  END IF;

  v_total := GREATEST(ROUND(COALESCE(p_subtotal,0) + COALESCE(p_total_tax,0) - COALESCE(p_total_withholding,0), 2), 0);
  v_approval_status := CASE WHEN public.expense_requires_approval(v_total, p_category_id) THEN 'pending_review' ELSE 'approved' END;

  UPDATE public.recurring_expense_templates
  SET description = btrim(p_description),
      expense_type = p_expense_type,
      category_id = p_category_id,
      supplier_id = p_supplier_id,
      project_id = p_project_id,
      currency = COALESCE(p_currency, 'EUR'),
      frequency = p_frequency,
      start_date = p_start_date,
      end_date = p_end_date,
      day_of_month = p_day_of_month,
      subtotal = ROUND(p_subtotal,2),
      total_tax = ROUND(COALESCE(p_total_tax,0),2),
      total_withholding = ROUND(COALESCE(p_total_withholding,0),2),
      total_amount = v_total,
      tax_config = COALESCE(p_tax_config,'[]'::jsonb),
      approval_status = v_approval_status,
      approved_by = NULL,
      approved_at = NULL,
      updated_by = auth.uid(),
      updated_at = CURRENT_TIMESTAMP
  WHERE id = p_template_id
  RETURNING * INTO v_template;

  UPDATE public.recurring_expense_forecasts
  SET description = v_template.description,
      currency = v_template.currency,
      subtotal = v_template.subtotal,
      total_tax = v_template.total_tax,
      total_withholding = v_template.total_withholding,
      total_amount = v_template.total_amount,
      category_id = v_template.category_id,
      supplier_id = v_template.supplier_id,
      project_id = v_template.project_id,
      tax_config = v_template.tax_config
  WHERE recurring_template_id = p_template_id
    AND occurrence_date >= CURRENT_DATE
    AND status = 'pending';

  RETURN v_template;
END;
$function$;

-- Link a manually-created real expense to a forecast. This does not create or pay
-- the expense and cannot link a forecast twice.
CREATE OR REPLACE FUNCTION public.link_expense_forecast_to_expense(
  p_forecast_id uuid,
  p_expense_id uuid
)
RETURNS public.recurring_expense_forecasts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_forecast public.recurring_expense_forecasts;
  v_expense public.expenses;
BEGIN
  PERFORM public.require_expense_permission('expenses.update');
  PERFORM public.consume_expense_worker_rate_limit('expenses:forecast_link');

  SELECT * INTO v_forecast FROM public.recurring_expense_forecasts WHERE id = p_forecast_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La previsión no existe'; END IF;
  IF v_forecast.status <> 'pending' THEN RAISE EXCEPTION 'La previsión ya no está pendiente'; END IF;

  SELECT * INTO v_expense FROM public.expenses WHERE id = p_expense_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El gasto real no existe'; END IF;
  IF v_expense.status = 'cancelled' THEN RAISE EXCEPTION 'No se puede vincular un gasto cancelado'; END IF;
  IF v_expense.currency <> v_forecast.currency THEN RAISE EXCEPTION 'La moneda del gasto y la previsión no coincide'; END IF;

  UPDATE public.recurring_expense_forecasts
  SET status = 'converted', linked_expense_id = p_expense_id
  WHERE id = p_forecast_id
  RETURNING * INTO v_forecast;

  RETURN v_forecast;
END;
$function$;

-- Generate all due forecast occurrences from the configured start date, including
-- past-due occurrences if a template was approved late. Unique(template,date) makes
-- repeated cron runs safe. This function creates forecast rows only, never expenses.
CREATE OR REPLACE FUNCTION public.generate_recurring_expense_forecasts()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_template public.recurring_expense_templates;
  v_occurrence date;
  v_next date;
  v_month date;
  v_day integer;
  v_inserted integer := 0;
  v_count integer;
BEGIN
  FOR v_template IN
    SELECT * FROM public.recurring_expense_templates
    WHERE lifecycle_status = 'active'
      AND approval_status = 'approved'
      AND start_date <= CURRENT_DATE
      AND (end_date IS NULL OR end_date >= start_date)
  LOOP
    v_occurrence := v_template.start_date;

    WHILE v_occurrence <= CURRENT_DATE
      AND (v_template.end_date IS NULL OR v_occurrence <= v_template.end_date)
    LOOP
      INSERT INTO public.recurring_expense_forecasts (
        recurring_template_id, occurrence_date, description, currency,
        subtotal, total_tax, total_withholding, total_amount,
        category_id, supplier_id, project_id, tax_config
      ) VALUES (
        v_template.id, v_occurrence, v_template.description, v_template.currency,
        v_template.subtotal, v_template.total_tax, v_template.total_withholding,
        v_template.total_amount, v_template.category_id, v_template.supplier_id,
        v_template.project_id, v_template.tax_config
      ) ON CONFLICT (recurring_template_id, occurrence_date) DO NOTHING;

      GET DIAGNOSTICS v_count = ROW_COUNT;
      v_inserted := v_inserted + v_count;

      IF v_template.frequency = 'weekly' THEN
        v_next := v_occurrence + 7;
      ELSE
        v_month := (date_trunc('month', v_occurrence)::date +
          CASE v_template.frequency WHEN 'quarterly' THEN INTERVAL '3 months' WHEN 'yearly' THEN INTERVAL '12 months' ELSE INTERVAL '1 month' END)::date;
        v_day := COALESCE(v_template.day_of_month, EXTRACT(DAY FROM v_template.start_date)::integer);
        v_next := v_month + (LEAST(v_day, EXTRACT(DAY FROM (v_month + INTERVAL '1 month - 1 day'))::integer) - 1);
      END IF;

      IF v_next <= v_occurrence THEN
        RAISE EXCEPTION 'No se pudo avanzar la fecha de recurrencia para %', v_template.id;
      END IF;
      v_occurrence := v_next;
    END LOOP;
  END LOOP;

  RETURN v_inserted;
END;
$function$;

-- Rule-aware actual-expense review: if the configured threshold/category does not
-- require approval, send directly to pending_payment; otherwise use pending_review.
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

  IF NOT FOUND THEN RAISE EXCEPTION 'El gasto % no existe', p_expense_id; END IF;
  IF v_expense.status <> 'draft' THEN
    RAISE EXCEPTION 'Solo se pueden enviar a revisión gastos en estado draft';
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

REVOKE ALL ON FUNCTION public.create_recurring_expense_template(text,text,uuid,uuid,uuid,text,text,date,date,smallint,numeric,numeric,numeric,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_recurring_expense_template(text,text,uuid,uuid,uuid,text,text,date,date,smallint,numeric,numeric,numeric,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.update_recurring_expense_template(uuid,text,text,uuid,uuid,uuid,text,text,date,date,smallint,numeric,numeric,numeric,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_recurring_expense_template(uuid,text,text,uuid,uuid,uuid,text,text,date,date,smallint,numeric,numeric,numeric,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.review_recurring_expense_template(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.review_recurring_expense_template(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.set_recurring_expense_template_status(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_recurring_expense_template_status(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.link_expense_forecast_to_expense(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.link_expense_forecast_to_expense(uuid,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.generate_recurring_expense_forecasts() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.generate_recurring_expense_forecasts() TO service_role;
REVOKE ALL ON FUNCTION public.submit_expense_for_review(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_expense_for_review(uuid) TO authenticated;

-- Schedule one daily generation run. It catches up missed occurrences and is idempotent.
DO $block$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'modira-recurring-expense-forecasts';
  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;
  PERFORM cron.schedule(
    'modira-recurring-expense-forecasts',
    '15 6 * * *',
    'SELECT public.generate_recurring_expense_forecasts();'
  );
END;
$block$;

COMMIT;
