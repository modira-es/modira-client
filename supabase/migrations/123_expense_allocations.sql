BEGIN;


-- ============================================================
-- MIGRACIÓN 123 — ASIGNACIÓN DE GASTOS A PROYECTOS
-- ============================================================
--
-- Permite distribuir un gasto interno de Modira entre uno o
-- varios proyectos.
--
-- Ejemplo:
--
--   Gasto software = 1.000 €
--
--   Proyecto A = 600 €
--   Proyecto B = 400 €
--
--   Total asignado = 1.000 €
--
-- IMPORTANTE:
--
--   expenses.project_id
--       -> permite una asignación simple a un único proyecto.
--
--   expense_allocations
--       -> permite repartir un gasto entre varios proyectos.
--
-- No se permite utilizar ambos mecanismos simultáneamente.
--
-- Estos datos pertenecen exclusivamente a la contabilidad
-- interna de Modira.
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
      '123_expense_allocations: no existe public.expenses. Ejecuta primero 120_expenses_core.';

  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_payments'
  ) THEN

    RAISE EXCEPTION
      '123_expense_allocations: no existe public.expense_payments. Ejecuta primero 122_expense_payments.';

  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'projects'
  ) THEN

    RAISE EXCEPTION
      '123_expense_allocations: no existe public.projects.';

  END IF;

END;
$$;


-- ============================================================
-- 2. TABLA expense_allocations
-- ============================================================

CREATE TABLE IF NOT EXISTS public.expense_allocations (

  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),


  -- ----------------------------------------------------------
  -- Gasto al que pertenece la asignación
  -- ----------------------------------------------------------

  expense_id UUID NOT NULL
    REFERENCES public.expenses(id)
    ON DELETE CASCADE,


  -- ----------------------------------------------------------
  -- Proyecto al que se imputa el coste
  -- ----------------------------------------------------------

  project_id UUID NOT NULL
    REFERENCES public.projects(id)
    ON DELETE RESTRICT,


  -- ----------------------------------------------------------
  -- Importe asignado
  -- ----------------------------------------------------------

  amount NUMERIC(14,2) NOT NULL,


  -- ----------------------------------------------------------
  -- Porcentaje del gasto asignado al proyecto
  --
  -- Se calcula automáticamente a partir de amount.
  -- ----------------------------------------------------------

  percentage NUMERIC(7,4) NOT NULL DEFAULT 0,


  -- ----------------------------------------------------------
  -- Descripción opcional
  -- ----------------------------------------------------------

  description TEXT,


  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,


  -- ==========================================================
  -- CONSTRAINTS
  -- ==========================================================

  CONSTRAINT expense_allocations_amount_check
    CHECK (
      amount > 0
    ),


  CONSTRAINT expense_allocations_percentage_check
    CHECK (
      percentage >= 0
      AND percentage <= 100
    ),


  CONSTRAINT expense_allocations_description_check
    CHECK (
      description IS NULL
      OR LENGTH(BTRIM(description)) <= 2000
    ),


  -- Un mismo proyecto no puede aparecer dos veces
  -- dentro del mismo gasto.
  CONSTRAINT expense_allocations_expense_project_unique
    UNIQUE (
      expense_id,
      project_id
    )

);


-- ============================================================
-- 3. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
  idx_expense_allocations_expense
ON public.expense_allocations (expense_id);


CREATE INDEX IF NOT EXISTS
  idx_expense_allocations_project
ON public.expense_allocations (project_id);


CREATE INDEX IF NOT EXISTS
  idx_expense_allocations_expense_project
ON public.expense_allocations (
  expense_id,
  project_id
);


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
      '123_expense_allocations: no existe public.update_updated_at_column().';

  END IF;

END;
$$;


DROP TRIGGER IF EXISTS
  expense_allocations_set_updated_at
ON public.expense_allocations;


CREATE TRIGGER
  expense_allocations_set_updated_at

BEFORE UPDATE

ON public.expense_allocations

FOR EACH ROW

EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 5. VALIDACIÓN DE ASIGNACIONES
-- ============================================================
--
-- Reglas:
--
-- 1. El gasto debe existir.
--
-- 2. El importe asignado debe ser > 0.
--
-- 3. La suma de todas las asignaciones del gasto no puede
--    superar expenses.total_amount.
--
-- 4. Si expenses.project_id está informado, no se pueden crear
--    allocations para ese gasto.
--
-- 5. La percentage se calcula automáticamente:
--
--      amount / total_amount * 100
--
-- 6. Se bloquea la fila del gasto durante el cálculo para evitar
--    que dos operaciones concurrentes puedan superar el total.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_expense_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_expense_total NUMERIC(14,2);

  v_direct_project_id UUID;

  v_allocated_amount NUMERIC(14,2);

  v_new_allocated_amount NUMERIC(14,2);

  v_percentage NUMERIC(7,4);

BEGIN

  -- ==========================================================
  -- DELETE
  -- ==========================================================

  IF TG_OP = 'DELETE' THEN

    RETURN OLD;

  END IF;


  -- ==========================================================
  -- Bloquear el gasto.
  --
  -- Esto evita carreras entre dos asignaciones simultáneas.
  -- ==========================================================

  SELECT
    total_amount,
    project_id

  INTO
    v_expense_total,
    v_direct_project_id

  FROM public.expenses

  WHERE id = NEW.expense_id

  FOR UPDATE;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto % no existe',
      NEW.expense_id;

  END IF;


  v_expense_total :=
    ROUND(
      GREATEST(
        COALESCE(v_expense_total, 0),
        0
      ),
      2
    );


  -- ==========================================================
  -- No permitir asignación directa + allocations.
  -- ==========================================================

  IF v_direct_project_id IS NOT NULL THEN

    RAISE EXCEPTION
      'El gasto % ya está asociado directamente al proyecto %. No puede utilizar expense_allocations.',
      NEW.expense_id,
      v_direct_project_id;

  END IF;


  -- ==========================================================
  -- El importe debe ser positivo.
  -- ==========================================================

  IF NEW.amount <= 0 THEN

    RAISE EXCEPTION
      'El importe de una asignación debe ser mayor que 0';

  END IF;


  -- ==========================================================
  -- Calcular lo ya asignado.
  --
  -- En UPDATE se excluye la propia fila.
  -- ==========================================================

  SELECT
    ROUND(
      COALESCE(
        SUM(amount),
        0
      ),
      2
    )

  INTO
    v_allocated_amount

  FROM public.expense_allocations

  WHERE expense_id = NEW.expense_id

    AND id IS DISTINCT FROM NEW.id;


  v_new_allocated_amount :=
    ROUND(
      v_allocated_amount + NEW.amount,
      2
    );


  -- ==========================================================
  -- No superar el total del gasto.
  -- ==========================================================

  IF v_new_allocated_amount > v_expense_total THEN

    RAISE EXCEPTION
      'Las asignaciones del gasto superan su importe total. Total del gasto: %, ya asignado: %, nueva asignación: %',
      v_expense_total,
      v_allocated_amount,
      NEW.amount;

  END IF;


  -- ==========================================================
  -- Calcular porcentaje automáticamente.
  --
  -- No confiamos en el porcentaje enviado por el frontend.
  -- ==========================================================

  IF v_expense_total > 0 THEN

    v_percentage :=
      ROUND(
        (
          NEW.amount
          / v_expense_total
        ) * 100,
        4
      );

  ELSE

    v_percentage := 0;

  END IF;


  NEW.percentage := v_percentage;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 6. TRIGGER DE VALIDACIÓN
-- ============================================================

DROP TRIGGER IF EXISTS
  expense_allocations_validate
ON public.expense_allocations;


CREATE TRIGGER
  expense_allocations_validate

BEFORE INSERT OR UPDATE

ON public.expense_allocations

FOR EACH ROW

EXECUTE FUNCTION public.validate_expense_allocation();


-- ============================================================
-- 7. PROTECCIÓN DEL expense_id
-- ============================================================
--
-- Una asignación existente no puede cambiar de gasto.
--
-- Si se necesita mover un coste de un gasto a otro:
--
--   DELETE + INSERT
--
-- Esto mantiene clara la trazabilidad.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_expense_allocation_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

  IF TG_OP = 'UPDATE' THEN

    IF NEW.expense_id IS DISTINCT FROM OLD.expense_id THEN

      RAISE EXCEPTION
        'No se puede cambiar el expense_id de una asignación existente';

    END IF;

  END IF;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 8. TRIGGER DE IDENTIDAD
-- ============================================================

DROP TRIGGER IF EXISTS
  expense_allocations_protect_identity
ON public.expense_allocations;


CREATE TRIGGER
  expense_allocations_protect_identity

BEFORE UPDATE

ON public.expense_allocations

FOR EACH ROW

EXECUTE FUNCTION public.protect_expense_allocation_identity();


-- ============================================================
-- 9. SINCRONIZACIÓN CON expenses.project_id
-- ============================================================
--
-- Caso simple:
--
--   expenses.project_id = Proyecto A
--
-- No existen expense_allocations.
--
-- Caso complejo:
--
--   expenses.project_id = NULL
--
--   expense_allocations:
--      Proyecto A -> 60%
--      Proyecto B -> 40%
--
-- ============================================================
--
-- Además, si un gasto tiene allocations y alguien intenta
-- establecer expenses.project_id, se rechazará.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_expense_project_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_allocation_count INTEGER;

BEGIN

  -- ----------------------------------------------------------
  -- Si no hay proyecto directo, no hay nada que comprobar.
  -- ----------------------------------------------------------

  IF NEW.project_id IS NULL THEN

    RETURN NEW;

  END IF;


  -- ----------------------------------------------------------
  -- Comprobar si existen allocations.
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_allocation_count

  FROM public.expense_allocations

  WHERE expense_id = NEW.id;


  IF v_allocation_count > 0 THEN

    RAISE EXCEPTION
      'El gasto % ya tiene asignaciones a proyectos. No puede establecerse project_id directamente.',
      NEW.id;

  END IF;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 10. TRIGGER expenses.project_id
-- ============================================================

DROP TRIGGER IF EXISTS
  expenses_validate_project_assignment
ON public.expenses;


CREATE TRIGGER
  expenses_validate_project_assignment

BEFORE INSERT OR UPDATE

ON public.expenses

FOR EACH ROW

EXECUTE FUNCTION public.validate_expense_project_assignment();


-- ============================================================
-- 11. VALIDACIÓN INVERSA
-- ============================================================
--
-- Si se elimina el project_id directo de un gasto y se
-- introducen allocations, el sistema sigue funcionando.
--
-- Si se intenta introducir una allocation mientras existe
-- project_id directo, validate_expense_allocation() lo impide.
--
-- No necesitamos un trigger adicional para ese caso.
--
-- ============================================================


-- ============================================================
-- 12. FUNCIÓN PARA OBTENER TOTAL ASIGNADO
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_expense_allocated_amount(
  p_expense_id UUID
)
RETURNS NUMERIC(14,2)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_allocated NUMERIC(14,2);

BEGIN

  IF p_expense_id IS NULL THEN

    RAISE EXCEPTION
      'get_expense_allocated_amount: expense_id es obligatorio';

  END IF;


  SELECT
    ROUND(
      COALESCE(
        SUM(amount),
        0
      ),
      2
    )

  INTO
    v_allocated

  FROM public.expense_allocations

  WHERE expense_id = p_expense_id;


  RETURN COALESCE(v_allocated, 0);

END;
$$;


-- ============================================================
-- 13. FUNCIÓN PARA OBTENER IMPORTE SIN ASIGNAR
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_expense_unallocated_amount(
  p_expense_id UUID
)
RETURNS NUMERIC(14,2)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_total NUMERIC(14,2);

  v_allocated NUMERIC(14,2);

BEGIN

  IF p_expense_id IS NULL THEN

    RAISE EXCEPTION
      'get_expense_unallocated_amount: expense_id es obligatorio';

  END IF;


  SELECT
    ROUND(
      COALESCE(total_amount, 0),
      2
    )

  INTO
    v_total

  FROM public.expenses

  WHERE id = p_expense_id;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto % no existe',
      p_expense_id;

  END IF;


  v_allocated :=
    public.get_expense_allocated_amount(
      p_expense_id
    );


  RETURN ROUND(
    GREATEST(
      v_total - v_allocated,
      0
    ),
    2
  );

END;
$$;


-- ============================================================
-- 14. RECÁLCULO DE PORCENTAJES
-- ============================================================
--
-- Si cambia el total_amount del gasto, los porcentajes de las
-- allocations existentes pueden cambiar.
--
-- Este trigger actualiza los porcentajes para mantenerlos
-- siempre coherentes con el importe actual del gasto.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.refresh_expense_allocation_percentages(
  p_expense_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_total NUMERIC(14,2);

BEGIN

  SELECT
    ROUND(
      COALESCE(total_amount, 0),
      2
    )

  INTO
    v_total

  FROM public.expenses

  WHERE id = p_expense_id;


  IF NOT FOUND THEN

    RAISE EXCEPTION
      'El gasto % no existe',
      p_expense_id;

  END IF;


  IF v_total <= 0 THEN

    UPDATE public.expense_allocations

    SET
      percentage = 0,
      updated_at = CURRENT_TIMESTAMP

    WHERE expense_id = p_expense_id;


  ELSE

    UPDATE public.expense_allocations

    SET
      percentage =
        ROUND(
          (
            amount
            / v_total
          ) * 100,
          4
        ),
      updated_at = CURRENT_TIMESTAMP

    WHERE expense_id = p_expense_id;

  END IF;

END;
$$;


-- ============================================================
-- 15. TRIGGER DE CAMBIO DE TOTAL
-- ============================================================
--
-- Cuando cambia total_amount:
--
--   recalculamos percentages.
--
-- Pero si el nuevo total es inferior a las asignaciones
-- existentes, el cambio debe rechazarse.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_expense_total_against_allocations()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

  v_allocated NUMERIC(14,2);

BEGIN

  IF NEW.total_amount IS DISTINCT FROM OLD.total_amount THEN

    SELECT
      ROUND(
        COALESCE(
          SUM(amount),
          0
        ),
        2
      )

    INTO
      v_allocated

    FROM public.expense_allocations

    WHERE expense_id = NEW.id;


    IF v_allocated > NEW.total_amount THEN

      RAISE EXCEPTION
        'No se puede reducir el total del gasto % por debajo de las asignaciones existentes. Total nuevo: %, asignado: %',
        NEW.id,
        NEW.total_amount,
        v_allocated;

    END IF;

  END IF;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 16. TRIGGER DE TOTAL vs ALLOCATIONS
-- ============================================================

DROP TRIGGER IF EXISTS
  expenses_validate_total_allocations
ON public.expenses;


CREATE TRIGGER
  expenses_validate_total_allocations

BEFORE UPDATE

ON public.expenses

FOR EACH ROW

EXECUTE FUNCTION public.validate_expense_total_against_allocations();


-- ============================================================
-- 17. ACTUALIZACIÓN DE PORCENTAJES TRAS CAMBIAR EL TOTAL
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_expense_allocation_percentages()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

  IF NEW.total_amount IS DISTINCT FROM OLD.total_amount THEN

    PERFORM public.refresh_expense_allocation_percentages(
      NEW.id
    );

  END IF;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 18. TRIGGER DE SINCRONIZACIÓN DE PORCENTAJES
-- ============================================================

DROP TRIGGER IF EXISTS
  expenses_sync_allocation_percentages
ON public.expenses;


CREATE TRIGGER
  expenses_sync_allocation_percentages

AFTER UPDATE OF total_amount

ON public.expenses

FOR EACH ROW

EXECUTE FUNCTION public.sync_expense_allocation_percentages();


-- ============================================================
-- 19. PERMISOS DE FUNCIONES INTERNAS
-- ============================================================

REVOKE EXECUTE
ON FUNCTION public.get_expense_allocated_amount(UUID)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.get_expense_allocated_amount(UUID)
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.get_expense_allocated_amount(UUID)
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.get_expense_unallocated_amount(UUID)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.get_expense_unallocated_amount(UUID)
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.get_expense_unallocated_amount(UUID)
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.refresh_expense_allocation_percentages(UUID)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.refresh_expense_allocation_percentages(UUID)
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.refresh_expense_allocation_percentages(UUID)
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.validate_expense_allocation()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_allocation()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_allocation()
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.protect_expense_allocation_identity()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.protect_expense_allocation_identity()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.protect_expense_allocation_identity()
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.validate_expense_project_assignment()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_project_assignment()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_project_assignment()
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.validate_expense_total_against_allocations()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_total_against_allocations()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_total_against_allocations()
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.sync_expense_allocation_percentages()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.sync_expense_allocation_percentages()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.sync_expense_allocation_percentages()
FROM authenticated;


-- ============================================================
-- 20. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.expense_allocations IS
  'Distribución de un gasto interno de Modira entre uno o varios proyectos.';


COMMENT ON COLUMN public.expense_allocations.amount IS
  'Importe del gasto imputado al proyecto. Es el valor económico principal de la asignación.';


COMMENT ON COLUMN public.expense_allocations.percentage IS
  'Porcentaje calculado automáticamente a partir de amount respecto al total del gasto.';


COMMENT ON COLUMN public.expense_allocations.description IS
  'Descripción opcional de por qué el gasto se imputa al proyecto.';


-- ============================================================
-- 21. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE

  v_table_exists BOOLEAN;

  v_required_columns INTEGER;

  v_validation_trigger BOOLEAN;

  v_total_trigger BOOLEAN;

  v_percentage_trigger BOOLEAN;

  v_function_exists BOOLEAN;

BEGIN

  -- ----------------------------------------------------------
  -- Tabla
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_allocations'
  )
  INTO v_table_exists;


  IF NOT v_table_exists THEN

    RAISE EXCEPTION
      '123_expense_allocations: no existe expense_allocations';

  END IF;


  -- ----------------------------------------------------------
  -- Columnas
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_required_columns

  FROM (
    VALUES
      ('expense_id'),
      ('project_id'),
      ('amount'),
      ('percentage'),
      ('description'),
      ('created_at'),
      ('updated_at')
  ) AS required_columns(column_name)

  WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'expense_allocations'
      AND c.column_name = required_columns.column_name
  );


  IF v_required_columns > 0 THEN

    RAISE EXCEPTION
      '123_expense_allocations: faltan % columnas obligatorias',
      v_required_columns;

  END IF;


  -- ----------------------------------------------------------
  -- Trigger de validación
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'expense_allocations_validate'
      AND tgrelid = 'public.expense_allocations'::regclass
      AND NOT tgisinternal
  )
  INTO v_validation_trigger;


  IF NOT v_validation_trigger THEN

    RAISE EXCEPTION
      '123_expense_allocations: falta el trigger de validación';

  END IF;


  -- ----------------------------------------------------------
  -- Trigger total vs allocations
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'expenses_validate_total_allocations'
      AND tgrelid = 'public.expenses'::regclass
      AND NOT tgisinternal
  )
  INTO v_total_trigger;


  IF NOT v_total_trigger THEN

    RAISE EXCEPTION
      '123_expense_allocations: falta el trigger de protección del total';

  END IF;


  -- ----------------------------------------------------------
  -- Trigger de porcentajes
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'expenses_sync_allocation_percentages'
      AND tgrelid = 'public.expenses'::regclass
      AND NOT tgisinternal
  )
  INTO v_percentage_trigger;


  IF NOT v_percentage_trigger THEN

    RAISE EXCEPTION
      '123_expense_allocations: falta el trigger de sincronización de porcentajes';

  END IF;


  -- ----------------------------------------------------------
  -- Función de importe asignado
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'get_expense_allocated_amount'
      AND pronamespace = 'public'::regnamespace
  )
  INTO v_function_exists;


  IF NOT v_function_exists THEN

    RAISE EXCEPTION
      '123_expense_allocations: falta get_expense_allocated_amount()';

  END IF;


  RAISE NOTICE
    '123_expense_allocations: migración completada correctamente.';

END;
$$;


COMMIT;