BEGIN;

-- ============================================================
-- MIGRACIÓN 120 — FISCALIDAD DE GASTOS
-- ============================================================
--
-- Esta migración amplía el sistema interno de gastos de Modira
-- creado en 070_expenses_core.
--
-- Añade:
--   1. Totales económicos en expenses.
--   2. Líneas fiscales en expense_tax_lines.
--   3. Cálculo centralizado de impuestos y retenciones.
--   4. Sincronización automática de los totales.
--
-- IMPORTANTE:
--   - Estos gastos pertenecen exclusivamente a la contabilidad
--     interna de Modira.
--   - No existe company_id en estas estructuras.
--   - Los clientes de Modira no tendrán acceso a estos datos.
--   - Los importes fiscales no deben depender del frontend.
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
      '120_expenses_tax: no existe public.expenses. Ejecuta primero 070_expenses_core.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_categories'
  ) THEN
    RAISE EXCEPTION
      '120_expenses_tax: no existe public.expense_categories. Ejecuta primero 070_expenses_core.';
  END IF;

END;
$$;


-- ============================================================
-- 2. AÑADIR TOTALES ECONÓMICOS A expenses
-- ============================================================

ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS subtotal NUMERIC(14,2)
    NOT NULL DEFAULT 0,

  ADD COLUMN IF NOT EXISTS total_tax NUMERIC(14,2)
    NOT NULL DEFAULT 0,

  ADD COLUMN IF NOT EXISTS total_withholding NUMERIC(14,2)
    NOT NULL DEFAULT 0,

  ADD COLUMN IF NOT EXISTS total_amount NUMERIC(14,2)
    NOT NULL DEFAULT 0;


-- ============================================================
-- 3. CONSTRAINTS DE LOS TOTALES
-- ============================================================

DO $$
BEGIN

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'expenses_subtotal_check'
      AND conrelid = 'public.expenses'::regclass
  ) THEN

    ALTER TABLE public.expenses
      ADD CONSTRAINT expenses_subtotal_check
      CHECK (subtotal >= 0);

  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'expenses_total_tax_check'
      AND conrelid = 'public.expenses'::regclass
  ) THEN

    ALTER TABLE public.expenses
      ADD CONSTRAINT expenses_total_tax_check
      CHECK (total_tax >= 0);

  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'expenses_total_withholding_check'
      AND conrelid = 'public.expenses'::regclass
  ) THEN

    ALTER TABLE public.expenses
      ADD CONSTRAINT expenses_total_withholding_check
      CHECK (total_withholding >= 0);

  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'expenses_total_amount_check'
      AND conrelid = 'public.expenses'::regclass
  ) THEN

    ALTER TABLE public.expenses
      ADD CONSTRAINT expenses_total_amount_check
      CHECK (total_amount >= 0);

  END IF;

END;
$$;


-- ============================================================
-- 4. TABLA expense_tax_lines
-- ============================================================
--
-- Un gasto puede tener varias líneas fiscales.
--
-- Ejemplo:
--
--   Base 1.000 €
--   IVA 21%  -> 210 €
--   IRPF 15% -> 150 €
--
-- Resultado:
--
--   subtotal          = 1.000 €
--   total_tax         =   210 €
--   total_withholding =   150 €
--   total_amount      = 1.060 €
--
-- tax_amount siempre se almacena como valor positivo.
-- La naturaleza del impuesto determina si suma o resta:
--
--   vat         -> suma
--   other       -> suma
--   withholding -> resta
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.expense_tax_lines (

  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  expense_id UUID NOT NULL
    REFERENCES public.expenses(id)
    ON DELETE CASCADE,

  tax_type TEXT NOT NULL,

  tax_rate NUMERIC(7,4) NOT NULL DEFAULT 0,

  taxable_base NUMERIC(14,2) NOT NULL DEFAULT 0,

  tax_amount NUMERIC(14,2) NOT NULL DEFAULT 0,

  deductible_amount NUMERIC(14,2) NOT NULL DEFAULT 0,

  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,


  CONSTRAINT expense_tax_lines_type_check
    CHECK (
      tax_type IN (
        'vat',
        'withholding',
        'other'
      )
    ),

  CONSTRAINT expense_tax_lines_rate_check
    CHECK (
      tax_rate >= 0
      AND tax_rate <= 100
    ),

  CONSTRAINT expense_tax_lines_taxable_base_check
    CHECK (
      taxable_base >= 0
    ),

  CONSTRAINT expense_tax_lines_amount_check
    CHECK (
      tax_amount >= 0
    ),

  CONSTRAINT expense_tax_lines_deductible_check
    CHECK (
      deductible_amount >= 0
      AND deductible_amount <= tax_amount
    )

);


-- ============================================================
-- 5. ÍNDICES expense_tax_lines
-- ============================================================

CREATE INDEX IF NOT EXISTS
  idx_expense_tax_lines_expense
ON public.expense_tax_lines (expense_id);

CREATE INDEX IF NOT EXISTS
  idx_expense_tax_lines_type
ON public.expense_tax_lines (tax_type);

CREATE INDEX IF NOT EXISTS
  idx_expense_tax_lines_expense_type
ON public.expense_tax_lines (expense_id, tax_type);


-- ============================================================
-- 6. TRIGGER updated_at PARA expense_tax_lines
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
      '120_expenses_tax: no existe public.update_updated_at_column().';

  END IF;

END;
$$;


DROP TRIGGER IF EXISTS
  expense_tax_lines_set_updated_at
ON public.expense_tax_lines;

CREATE TRIGGER
  expense_tax_lines_set_updated_at

BEFORE UPDATE
ON public.expense_tax_lines

FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 7. FUNCIÓN DE RECÁLCULO DE TOTALES DEL GASTO
-- ============================================================
--
-- Esta función obtiene las líneas fiscales del gasto y calcula:
--
--   total_tax
--   total_withholding
--   total_amount
--
-- El subtotal pertenece al propio expense.
--
-- Fórmula:
--
--   total_amount =
--     subtotal
--     + impuestos
--     - retenciones
--
-- Los importes se redondean siempre a 2 decimales.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.recalculate_expense_totals(
  p_expense_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_subtotal NUMERIC(14,2);

  v_total_tax NUMERIC(14,2);

  v_total_withholding NUMERIC(14,2);

  v_total_amount NUMERIC(14,2);

BEGIN

  IF p_expense_id IS NULL THEN
    RAISE EXCEPTION
      'recalculate_expense_totals: expense_id es obligatorio';
  END IF;


  SELECT
    ROUND(COALESCE(subtotal, 0), 2)
  INTO
    v_subtotal
  FROM public.expenses
  WHERE id = p_expense_id;


  IF NOT FOUND THEN
    RAISE EXCEPTION
      'recalculate_expense_totals: el gasto % no existe',
      p_expense_id;
  END IF;


  SELECT
    ROUND(
      COALESCE(
        SUM(
          CASE
            WHEN tax_type IN ('vat', 'other')
              THEN tax_amount
            ELSE 0
          END
        ),
        0
      ),
      2
    ),

    ROUND(
      COALESCE(
        SUM(
          CASE
            WHEN tax_type = 'withholding'
              THEN tax_amount
            ELSE 0
          END
        ),
        0
      ),
      2
    )

  INTO
    v_total_tax,
    v_total_withholding

  FROM public.expense_tax_lines

  WHERE expense_id = p_expense_id;


  v_total_amount :=
    ROUND(
      GREATEST(
        v_subtotal
        + v_total_tax
        - v_total_withholding,
        0
      ),
      2
    );


  UPDATE public.expenses

  SET
    total_tax = v_total_tax,
    total_withholding = v_total_withholding,
    total_amount = v_total_amount,
    updated_at = CURRENT_TIMESTAMP

  WHERE id = p_expense_id;

END;
$$;


-- ============================================================
-- 8. PERMISOS DE LA FUNCIÓN DE RECÁLCULO
-- ============================================================

REVOKE EXECUTE
ON FUNCTION public.recalculate_expense_totals(UUID)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.recalculate_expense_totals(UUID)
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.recalculate_expense_totals(UUID)
FROM authenticated;


-- ============================================================
-- 9. FUNCIÓN PARA SINCRONIZAR LOS TOTALES DE expenses
-- ============================================================
--
-- Se ejecuta antes de insertar o modificar un gasto.
--
-- Esto evita que subtotal / total_tax /
-- total_withholding / total_amount puedan quedar
-- incoherentes cuando el subtotal cambia.
--
-- Las líneas fiscales se gestionan posteriormente mediante
-- expense_tax_lines.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_expense_amounts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

  NEW.subtotal :=
    ROUND(
      GREATEST(
        COALESCE(NEW.subtotal, 0),
        0
      ),
      2
    );


  NEW.total_tax :=
    ROUND(
      GREATEST(
        COALESCE(NEW.total_tax, 0),
        0
      ),
      2
    );


  NEW.total_withholding :=
    ROUND(
      GREATEST(
        COALESCE(NEW.total_withholding, 0),
        0
      ),
      2
    );


  NEW.total_amount :=
    ROUND(
      GREATEST(
        NEW.subtotal
        + NEW.total_tax
        - NEW.total_withholding,
        0
      ),
      2
    );


  RETURN NEW;

END;
$$;


-- ============================================================
-- 10. TRIGGER SOBRE expenses
-- ============================================================

DROP TRIGGER IF EXISTS
  expenses_sync_amounts
ON public.expenses;

CREATE TRIGGER
  expenses_sync_amounts

BEFORE INSERT OR UPDATE
ON public.expenses

FOR EACH ROW
EXECUTE FUNCTION public.sync_expense_amounts();


-- ============================================================
-- 11. FUNCIÓN TRIGGER PARA expense_tax_lines
-- ============================================================
--
-- Cada vez que se crea, modifica o elimina una línea fiscal,
-- se recalculan automáticamente los totales del gasto.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_expense_totals_from_tax_line()
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


  PERFORM public.recalculate_expense_totals(
    v_expense_id
  );


  RETURN COALESCE(NEW, OLD);

END;
$$;


-- ============================================================
-- 12. TRIGGER SOBRE expense_tax_lines
-- ============================================================

DROP TRIGGER IF EXISTS
  expense_tax_lines_sync_expense
ON public.expense_tax_lines;

CREATE TRIGGER
  expense_tax_lines_sync_expense

AFTER INSERT OR UPDATE OR DELETE
ON public.expense_tax_lines

FOR EACH ROW
EXECUTE FUNCTION public.sync_expense_totals_from_tax_line();


-- ============================================================
-- 13. VALIDACIÓN DE coherencia DE LAS LÍNEAS FISCALES
-- ============================================================
--
-- El importe fiscal se calcula como:
--
--   taxable_base × tax_rate / 100
--
-- La línea puede utilizar un tax_amount distinto si en el futuro
-- se necesita representar un importe fiscal legalmente redondeado
-- o una corrección contable.
--
-- Por eso NO forzamos aquí una igualdad exacta mediante CHECK.
--
-- El backend será responsable de generar los valores correctos.
--
-- ============================================================


-- ============================================================
-- 14. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.expense_tax_lines IS
  'Líneas fiscales de los gastos internos de Modira. Permite representar IVA, retenciones y otros impuestos.';


COMMENT ON COLUMN public.expenses.subtotal IS
  'Base económica del gasto antes de impuestos y retenciones.';


COMMENT ON COLUMN public.expenses.total_tax IS
  'Total de impuestos que incrementan el coste del gasto. No incluye retenciones.';


COMMENT ON COLUMN public.expenses.total_withholding IS
  'Total de retenciones practicadas. Se resta del subtotal e impuestos para obtener el importe final.';


COMMENT ON COLUMN public.expenses.total_amount IS
  'Importe final del gasto: subtotal + impuestos - retenciones.';


COMMENT ON COLUMN public.expense_tax_lines.tax_type IS
  'Tipo fiscal: vat, withholding u other.';


COMMENT ON COLUMN public.expense_tax_lines.tax_rate IS
  'Porcentaje fiscal aplicado a la base imponible.';


COMMENT ON COLUMN public.expense_tax_lines.taxable_base IS
  'Base imponible sobre la que se calcula la línea fiscal.';


COMMENT ON COLUMN public.expense_tax_lines.tax_amount IS
  'Importe fiscal positivo. Su tratamiento depende de tax_type.';


COMMENT ON COLUMN public.expense_tax_lines.deductible_amount IS
  'Parte del impuesto que puede considerarse fiscalmente deducible.';


-- ============================================================
-- 15. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE

  v_missing_columns INTEGER;

  v_tax_lines_exists BOOLEAN;

  v_function_exists BOOLEAN;

  v_trigger_exists BOOLEAN;

BEGIN

  -- ----------------------------------------------------------
  -- Comprobar columnas económicas de expenses
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_missing_columns

  FROM (
    VALUES
      ('subtotal'),
      ('total_tax'),
      ('total_withholding'),
      ('total_amount')
  ) AS required_columns(column_name)

  WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'expenses'
      AND c.column_name = required_columns.column_name
  );


  IF v_missing_columns > 0 THEN

    RAISE EXCEPTION
      '120_expenses_tax: faltan % columnas económicas en expenses.',
      v_missing_columns;

  END IF;


  -- ----------------------------------------------------------
  -- Comprobar expense_tax_lines
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_tax_lines'
  )
  INTO v_tax_lines_exists;


  IF NOT v_tax_lines_exists THEN

    RAISE EXCEPTION
      '120_expenses_tax: no existe expense_tax_lines.';

  END IF;


  -- ----------------------------------------------------------
  -- Comprobar función de recálculo
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'recalculate_expense_totals'
      AND pronamespace = 'public'::regnamespace
  )
  INTO v_function_exists;


  IF NOT v_function_exists THEN

    RAISE EXCEPTION
      '120_expenses_tax: no existe recalculate_expense_totals().';

  END IF;


  -- ----------------------------------------------------------
  -- Comprobar trigger de sincronización
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'expense_tax_lines_sync_expense'
      AND tgrelid = 'public.expense_tax_lines'::regclass
      AND NOT tgisinternal
  )
  INTO v_trigger_exists;


  IF NOT v_trigger_exists THEN

    RAISE EXCEPTION
      '120_expenses_tax: no existe el trigger expense_tax_lines_sync_expense.';

  END IF;


  RAISE NOTICE
    '120_expenses_tax: migración completada correctamente.';

END;
$$;


COMMIT;