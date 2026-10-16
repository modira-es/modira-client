BEGIN;

-- ============================================================
-- 126 — AUDITORÍA DE GASTOS
-- ============================================================
--
-- OBJETIVO
--
-- Registrar en el sistema general activity_log las operaciones
-- relevantes realizadas sobre el módulo interno de gastos.
--
-- IMPORTANTE:
--
-- NO se crea una tabla de auditoría independiente.
--
-- Modira ya dispone de:
--
--     public.activity_log
--     public.log_activity(...)
--
-- Por tanto, esta migración reutiliza el sistema general
-- de auditoría existente.
--
-- Los gastos son exclusivamente internos de Modira.
-- Los clientes no reciben acceso a ellos.
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- expenses
    -- --------------------------------------------------------

    IF to_regclass('public.expenses') IS NULL THEN
        RAISE EXCEPTION
            '126 stopped: public.expenses no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_tax_lines
    -- --------------------------------------------------------

    IF to_regclass('public.expense_tax_lines') IS NULL THEN
        RAISE EXCEPTION
            '126 stopped: public.expense_tax_lines no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_documents
    -- --------------------------------------------------------

    IF to_regclass('public.expense_documents') IS NULL THEN
        RAISE EXCEPTION
            '126 stopped: public.expense_documents no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_payments
    -- --------------------------------------------------------

    IF to_regclass('public.expense_payments') IS NULL THEN
        RAISE EXCEPTION
            '126 stopped: public.expense_payments no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_allocations
    -- --------------------------------------------------------

    IF to_regclass('public.expense_allocations') IS NULL THEN
        RAISE EXCEPTION
            '126 stopped: public.expense_allocations no existe';
    END IF;


    -- --------------------------------------------------------
    -- activity_log
    -- --------------------------------------------------------

    IF to_regclass('public.activity_log') IS NULL THEN
        RAISE EXCEPTION
            '126 stopped: public.activity_log no existe';
    END IF;


    -- --------------------------------------------------------
    -- log_activity()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'log_activity'
    ) THEN
        RAISE EXCEPTION
            '126 stopped: public.log_activity() no existe';
    END IF;


    -- --------------------------------------------------------
    -- current_user_is_worker()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '126 stopped: public.current_user_is_worker() no existe';
    END IF;


    -- --------------------------------------------------------
    -- current_user_is_active()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_active'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '126 stopped: public.current_user_is_active() no existe';
    END IF;

END;
$$;


-- ============================================================
-- 2. FUNCIÓN AUXILIAR — AUDITORÍA DE EXPENSES
-- ============================================================
--
-- Esta función se utiliza exclusivamente desde triggers.
--
-- No se expone como RPC.
--
-- El objetivo es centralizar el registro de las operaciones
-- principales de expenses.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.audit_expense_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_action TEXT;
    v_description TEXT;
    v_metadata JSONB;
    v_expense_id UUID;
    v_expense_number TEXT;

BEGIN

    -- ========================================================
    -- 1. DETERMINAR EXPENSE ID
    -- ========================================================

    IF TG_OP = 'DELETE' THEN
        v_expense_id := OLD.id;
        v_expense_number := OLD.expense_number;
    ELSE
        v_expense_id := NEW.id;
        v_expense_number := NEW.expense_number;
    END IF;


    -- ========================================================
    -- 2. DETERMINAR ACCIÓN
    -- ========================================================

    IF TG_OP = 'INSERT' THEN

        v_action := 'expense_created';

        v_description :=
            'Se ha creado un gasto interno.';

        v_metadata := jsonb_build_object(
            'operation', 'INSERT',
            'expense_number', v_expense_number,
            'expense_type',
                NEW.expense_type,
            'status',
                NEW.status,
            'category_id',
                NEW.category_id,
            'supplier_id',
                NEW.supplier_id,
            'project_id',
                NEW.project_id
        );


    ELSIF TG_OP = 'DELETE' THEN

        v_action := 'expense_deleted';

        v_description :=
            'Se ha eliminado un gasto interno.';

        v_metadata := jsonb_build_object(
            'operation', 'DELETE',
            'expense_number', v_expense_number,
            'expense_type',
                OLD.expense_type,
            'status',
                OLD.status,
            'category_id',
                OLD.category_id,
            'supplier_id',
                OLD.supplier_id,
            'project_id',
                OLD.project_id
        );


    ELSE

        -- ----------------------------------------------------
        -- UPDATE NORMAL
        -- ----------------------------------------------------

        v_action := 'expense_updated';

        v_description :=
            'Se ha modificado un gasto interno.';

        v_metadata := jsonb_build_object(
            'operation', 'UPDATE',
            'expense_number', NEW.expense_number,
            'previous_status', OLD.status,
            'new_status', NEW.status,
            'previous_project_id', OLD.project_id,
            'new_project_id', NEW.project_id,
            'previous_category_id', OLD.category_id,
            'new_category_id', NEW.category_id,
            'previous_supplier_id', OLD.supplier_id,
            'new_supplier_id', NEW.supplier_id
        );

        -- ----------------------------------------------------
        -- CAMBIO DE ESTADO
        -- ----------------------------------------------------

        IF OLD.status IS DISTINCT FROM NEW.status THEN

            v_action := 'expense_status_changed';

            v_description :=
                'Ha cambiado el estado de un gasto interno.';

            v_metadata := v_metadata
                || jsonb_build_object(
                    'status_changed', TRUE
                );

        END IF;

    END IF;


    -- ========================================================
    -- 3. REGISTRAR EN ACTIVITY_LOG
    -- ========================================================

    PERFORM public.log_activity(
        v_action,
        'expense',
        v_expense_id,
        v_description,
        v_metadata
    );


    -- ========================================================
    -- 4. DEVOLVER FILA
    -- ========================================================

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;

END;
$function$;


-- ============================================================
-- 3. SEGURIDAD DE LA FUNCIÓN
-- ============================================================
--
-- Esta función únicamente debe ejecutarse mediante triggers.
--
-- No debe ser invocable directamente desde PostgREST.
--
-- ============================================================

REVOKE ALL
ON FUNCTION public.audit_expense_change()
FROM PUBLIC, anon, authenticated;


ALTER FUNCTION public.audit_expense_change()
SET search_path = public, pg_temp;


-- ============================================================
-- 4. TRIGGER PRINCIPAL — EXPENSES
-- ============================================================
--
-- Registra:
--
-- INSERT
-- UPDATE
-- DELETE
--
-- La función determina automáticamente la operación.
--
-- ============================================================

DROP TRIGGER IF EXISTS expenses_audit_activity
ON public.expenses;


CREATE TRIGGER expenses_audit_activity
AFTER INSERT OR UPDATE OR DELETE
ON public.expenses
FOR EACH ROW
EXECUTE FUNCTION public.audit_expense_change();


-- ============================================================
-- 5. FUNCIÓN — AUDITORÍA DE SUBRECURSOS
-- ============================================================
--
-- Los documentos, pagos, impuestos y asignaciones forman parte
-- de un expense existente.
--
-- Se registra:
--
--   - creación
--   - modificación
--   - eliminación
--
-- El resource_id del activity_log continúa siendo el ID del
-- gasto principal, no el ID del subrecurso.
--
-- Esto permite consultar toda la actividad de un gasto desde
-- un único recurso.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.audit_expense_related_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_expense_id UUID;
    v_action TEXT;
    v_resource_type TEXT;
    v_description TEXT;
    v_metadata JSONB;

BEGIN

    -- ========================================================
    -- 1. EXPENSE ID
    -- ========================================================

    IF TG_OP = 'DELETE' THEN
        v_expense_id := OLD.expense_id;
    ELSE
        v_expense_id := NEW.expense_id;
    END IF;


    -- ========================================================
    -- 2. RESOURCE TYPE
    -- ========================================================

    CASE TG_TABLE_NAME

        WHEN 'expense_documents' THEN
            v_resource_type := 'expense_document';

        WHEN 'expense_payments' THEN
            v_resource_type := 'expense_payment';

        WHEN 'expense_tax_lines' THEN
            v_resource_type := 'expense_tax_line';

        WHEN 'expense_allocations' THEN
            v_resource_type := 'expense_allocation';

        ELSE
            RAISE EXCEPTION
                '126: tabla de gasto relacionada no soportada: %',
                TG_TABLE_NAME;

    END CASE;


    -- ========================================================
    -- 3. ACTION
    -- ========================================================

    v_action :=
        'expense_' ||
        CASE TG_TABLE_NAME
            WHEN 'expense_documents' THEN 'document'
            WHEN 'expense_payments' THEN 'payment'
            WHEN 'expense_tax_lines' THEN 'tax'
            WHEN 'expense_allocations' THEN 'allocation'
        END
        || '_' ||
        LOWER(TG_OP);


    -- ========================================================
    -- 4. DESCRIPTION
    -- ========================================================

    v_description :=
        CASE TG_OP
            WHEN 'INSERT'
                THEN 'Se ha creado un elemento relacionado con un gasto interno.'
            WHEN 'UPDATE'
                THEN 'Se ha modificado un elemento relacionado con un gasto interno.'
            WHEN 'DELETE'
                THEN 'Se ha eliminado un elemento relacionado con un gasto interno.'
        END;


    -- ========================================================
    -- 5. METADATA
    -- ========================================================

    v_metadata := jsonb_build_object(
        'operation', TG_OP,
        'table_name', TG_TABLE_NAME,
        'expense_id', v_expense_id
    );


    -- ========================================================
    -- DOCUMENTOS
    -- ========================================================

    IF TG_TABLE_NAME = 'expense_documents' THEN

        v_metadata := v_metadata
            || jsonb_build_object(
                'document_type',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.document_type
                        ELSE NEW.document_type
                    END,
                'file_name',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.file_name
                        ELSE NEW.file_name
                    END
            );

    END IF;


    -- ========================================================
    -- PAYMENTS
    -- ========================================================

    IF TG_TABLE_NAME = 'expense_payments' THEN

        v_metadata := v_metadata
            || jsonb_build_object(
                'amount',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.amount
                        ELSE NEW.amount
                    END,
                'payment_method',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.payment_method
                        ELSE NEW.payment_method
                    END,
                'status',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.status
                        ELSE NEW.status
                    END
            );

    END IF;


    -- ========================================================
    -- TAX
    -- ========================================================

    IF TG_TABLE_NAME = 'expense_tax_lines' THEN

        v_metadata := v_metadata
            || jsonb_build_object(
                'tax_type',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.tax_type
                        ELSE NEW.tax_type
                    END,
                'tax_rate',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.tax_rate
                        ELSE NEW.tax_rate
                    END,
                'tax_amount',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.tax_amount
                        ELSE NEW.tax_amount
                    END
            );

    END IF;


    -- ========================================================
    -- ALLOCATIONS
    -- ========================================================

    IF TG_TABLE_NAME = 'expense_allocations' THEN

        v_metadata := v_metadata
            || jsonb_build_object(
                'project_id',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.project_id
                        ELSE NEW.project_id
                    END,
                'amount',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.amount
                        ELSE NEW.amount
                    END,
                'percentage',
                    CASE
                        WHEN TG_OP = 'DELETE'
                        THEN OLD.percentage
                        ELSE NEW.percentage
                    END
            );

    END IF;


    -- ========================================================
    -- 6. REGISTRAR
    -- ========================================================

    PERFORM public.log_activity(
        v_action,
        v_resource_type,
        v_expense_id,
        v_description,
        v_metadata
    );


    -- ========================================================
    -- 7. RETURN
    -- ========================================================

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;

END;
$function$;


-- ============================================================
-- 6. SEGURIDAD DE LA FUNCIÓN
-- ============================================================

REVOKE ALL
ON FUNCTION public.audit_expense_related_change()
FROM PUBLIC, anon, authenticated;


ALTER FUNCTION public.audit_expense_related_change()
SET search_path = public, pg_temp;


-- ============================================================
-- 7. TRIGGERS — DOCUMENTOS
-- ============================================================

DROP TRIGGER IF EXISTS expense_documents_audit_activity
ON public.expense_documents;


CREATE TRIGGER expense_documents_audit_activity
AFTER INSERT OR UPDATE OR DELETE
ON public.expense_documents
FOR EACH ROW
EXECUTE FUNCTION public.audit_expense_related_change();


-- ============================================================
-- 8. TRIGGERS — PAGOS
-- ============================================================

DROP TRIGGER IF EXISTS expense_payments_audit_activity
ON public.expense_payments;


CREATE TRIGGER expense_payments_audit_activity
AFTER INSERT OR UPDATE OR DELETE
ON public.expense_payments
FOR EACH ROW
EXECUTE FUNCTION public.audit_expense_related_change();


-- ============================================================
-- 9. TRIGGERS — IMPUESTOS
-- ============================================================

DROP TRIGGER IF EXISTS expense_tax_lines_audit_activity
ON public.expense_tax_lines;


CREATE TRIGGER expense_tax_lines_audit_activity
AFTER INSERT OR UPDATE OR DELETE
ON public.expense_tax_lines
FOR EACH ROW
EXECUTE FUNCTION public.audit_expense_related_change();


-- ============================================================
-- 10. TRIGGERS — ASIGNACIONES
-- ============================================================

DROP TRIGGER IF EXISTS expense_allocations_audit_activity
ON public.expense_allocations;


CREATE TRIGGER expense_allocations_audit_activity
AFTER INSERT OR UPDATE OR DELETE
ON public.expense_allocations
FOR EACH ROW
EXECUTE FUNCTION public.audit_expense_related_change();


-- ============================================================
-- 11. RLS — ACTIVITY_LOG
-- ============================================================
--
-- activity_log ya es el sistema general de auditoría.
--
-- Esta migración NO cambia su arquitectura ni concede escritura
-- directa al frontend.
--
-- Se reafirma que:
--
--   INSERT -> bloqueado
--   UPDATE -> bloqueado
--   DELETE -> bloqueado
--
-- La escritura se realiza mediante log_activity().
--
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON public.activity_log
FROM anon, authenticated;


GRANT SELECT
ON public.activity_log
TO authenticated;


-- ============================================================
-- 12. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- activity_log
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'activity_log';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '126 failed: activity_log no existe';
    END IF;


    -- --------------------------------------------------------
    -- log_activity()
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'log_activity';

    IF v_count < 1 THEN
        RAISE EXCEPTION
            '126 failed: log_activity() no existe';
    END IF;


    -- --------------------------------------------------------
    -- audit_expense_change()
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'audit_expense_change'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '126 failed: audit_expense_change() debe existir como SECURITY DEFINER';
    END IF;


    -- --------------------------------------------------------
    -- audit_expense_related_change()
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'audit_expense_related_change'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '126 failed: audit_expense_related_change() debe existir como SECURITY DEFINER';
    END IF;


    -- --------------------------------------------------------
    -- trigger expenses
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.expenses'::regclass
      AND tgname = 'expenses_audit_activity'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '126 failed: expenses_audit_activity no existe';
    END IF;


    -- --------------------------------------------------------
    -- trigger documents
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.expense_documents'::regclass
      AND tgname = 'expense_documents_audit_activity'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '126 failed: expense_documents_audit_activity no existe';
    END IF;


    -- --------------------------------------------------------
    -- trigger payments
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.expense_payments'::regclass
      AND tgname = 'expense_payments_audit_activity'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '126 failed: expense_payments_audit_activity no existe';
    END IF;


    -- --------------------------------------------------------
    -- trigger tax lines
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.expense_tax_lines'::regclass
      AND tgname = 'expense_tax_lines_audit_activity'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '126 failed: expense_tax_lines_audit_activity no existe';
    END IF;


    -- --------------------------------------------------------
    -- trigger allocations
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.expense_allocations'::regclass
      AND tgname = 'expense_allocations_audit_activity'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '126 failed: expense_allocations_audit_activity no existe';
    END IF;


    -- --------------------------------------------------------
    -- authenticated NO debe poder escribir directamente
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '126 failed: authenticated no debe tener INSERT directo sobre activity_log';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '126 failed: authenticated no debe tener UPDATE directo sobre activity_log';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.activity_log',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '126 failed: authenticated no debe tener DELETE directo sobre activity_log';
    END IF;

END;
$$;


-- ============================================================
-- 13. COMENTARIOS
-- ============================================================

COMMENT ON FUNCTION public.audit_expense_change()
IS
'Registra en activity_log las operaciones INSERT, UPDATE y DELETE realizadas sobre expenses. Función interna ejecutada exclusivamente mediante trigger.';


COMMENT ON FUNCTION public.audit_expense_related_change()
IS
'Registra en activity_log las operaciones sobre documentos, pagos, impuestos y asignaciones de gastos. Función interna ejecutada exclusivamente mediante trigger.';


-- ============================================================
-- 14. RECARGAR ESQUEMA POSTGREST
-- ============================================================

NOTIFY pgrst, 'reload schema';


COMMIT;