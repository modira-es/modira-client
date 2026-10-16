BEGIN;

-- ============================================================
-- MODIRA — 043_invoice_paid_status_hardening.sql
--
-- SEGURIDAD — ESTADO "PAGADA" DE FACTURAS
--
-- Contexto:
-- - 011 permite actualmente que update_invoice_by_worker()
--   reciba p_estado = 'pagada'.
-- - 030 y 031 endurecen payments y el flujo Stripe, pero no
--   impiden que un worker marque invoices como "pagada".
-- - 031 establece que el pago confirmado es el que debe llevar
--   la factura a "pagada".
--
-- Objetivo:
-- 1. Impedir que una factura pase a "pagada" sin existir un
--    payment con status = "succeeded".
-- 2. Impedir que una factura ya pagada vuelva a otro estado.
-- 3. Mantener intactos los flujos existentes de Stripe 030/031.
-- 4. No modificar la firma ni los permisos de las RPC existentes.
-- 5. No modificar datos históricos existentes.
--
-- La transición Stripe funciona porque 031:
--   payment -> status = succeeded
--   invoice -> estado = pagada
-- dentro de la misma transacción.
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'invoices'
    ) THEN
        RAISE EXCEPTION
            '043 stopped: public.invoices does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'payments'
    ) THEN
        RAISE EXCEPTION
            '043 stopped: public.payments does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'invoices'
          AND column_name = 'estado'
    ) THEN
        RAISE EXCEPTION
            '043 stopped: invoices.estado does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'payments'
          AND column_name = 'invoice_id'
    ) THEN
        RAISE EXCEPTION
            '043 stopped: payments.invoice_id does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'payments'
          AND column_name = 'status'
    ) THEN
        RAISE EXCEPTION
            '043 stopped: payments.status does not exist';
    END IF;

END $$;


-- ============================================================
-- 2. FUNCIÓN DE PROTECCIÓN DEL ESTADO PAGADA
-- ============================================================
--
-- Regla:
--
--   cualquier estado
--          |
--          +----> pagada
--                   |
--                   +--> requiere payment.succeeded
--
-- Y:
--
--   pagada
--      |
--      +----> cualquier otro estado = PROHIBIDO
--
-- No dependemos del frontend ni de que el worker utilice
-- correctamente update_invoice_by_worker().
--
-- Esto protege también frente a futuras RPCs SECURITY DEFINER
-- que pudieran intentar modificar invoices de forma incorrecta.
--
-- Importante:
-- El flujo de 031 es compatible porque, antes de modificar
-- invoices.estado, register_stripe_invoice_payment() ya ha:
--
--   - creado el payment como succeeded, o
--   - actualizado un payment existente a succeeded.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_invoice_paid_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$

BEGIN

    -- ========================================================
    -- 1. NO HAY CAMBIO DE ESTADO
    -- ========================================================

    IF NEW.estado IS NOT DISTINCT FROM OLD.estado THEN
        RETURN NEW;
    END IF;


    -- ========================================================
    -- 2. UNA FACTURA YA PAGADA NO PUEDE RETROCEDER
    -- ========================================================

    IF LOWER(
        TRIM(
            COALESCE(OLD.estado, '')
        )
    ) = 'pagada'
    AND LOWER(
        TRIM(
            COALESCE(NEW.estado, '')
        )
    ) <> 'pagada'
    THEN

        RAISE EXCEPTION
            'Una factura pagada no puede volver a otro estado';

    END IF;


    -- ========================================================
    -- 3. PARA ENTRAR EN PAGADA DEBE EXISTIR UN PAGO EXITOSO
    -- ========================================================

    IF LOWER(
        TRIM(
            COALESCE(NEW.estado, '')
        )
    ) = 'pagada'
    AND LOWER(
        TRIM(
            COALESCE(OLD.estado, '')
        )
    ) <> 'pagada'
    THEN

        IF NOT EXISTS (
            SELECT 1
            FROM public.payments p
            WHERE p.invoice_id = NEW.id
              AND p.status = 'succeeded'
        ) THEN

            RAISE EXCEPTION
                'Una factura solo puede marcarse como pagada cuando existe un pago confirmado';

        END IF;

    END IF;


    RETURN NEW;

END;
$function$;


-- ============================================================
-- 3. TRIGGER
-- ============================================================
--
-- Solo vigila cambios de estado.
-- No interviene en:
--
-- - creación normal de facturas pendientes;
-- - edición de datos fiscales;
-- - edición de empresa/proyecto;
-- - documentos PDF;
-- - pagos failed/canceled;
-- - actualización de un PaymentIntent failed/canceled -> succeeded
--   porque 031 registra primero el payment.
--
-- ============================================================

DROP TRIGGER IF EXISTS invoices_protect_paid_status
ON public.invoices;

CREATE TRIGGER invoices_protect_paid_status
BEFORE UPDATE OF estado
ON public.invoices
FOR EACH ROW
EXECUTE FUNCTION public.protect_invoice_paid_status();


-- ============================================================
-- 4. PERMISOS
-- ============================================================
--
-- La función solo se utiliza internamente como trigger.
-- No debe exponerse como RPC al frontend.
--
-- ============================================================

REVOKE ALL
ON FUNCTION public.protect_invoice_paid_status()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 5. COMPROBACIONES
-- ============================================================

DO $$
DECLARE
    v_trigger_count INTEGER;
    v_function_exists BOOLEAN;
BEGIN

    -- --------------------------------------------------------
    -- Trigger presente
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_trigger_count
    FROM pg_trigger
    WHERE tgrelid = 'public.invoices'::regclass
      AND tgname = 'invoices_protect_paid_status'
      AND NOT tgisinternal;

    IF v_trigger_count <> 1 THEN
        RAISE EXCEPTION
            '043 failed: invoices_protect_paid_status trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- Función presente
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'protect_invoice_paid_status'
    )
    INTO v_function_exists;

    IF NOT v_function_exists THEN
        RAISE EXCEPTION
            '043 failed: protect_invoice_paid_status() missing';
    END IF;

END $$;


-- ============================================================
-- 6. COMENTARIO
-- ============================================================

COMMENT ON FUNCTION public.protect_invoice_paid_status()
IS
'Protege el estado pagada de invoices: exige un payment succeeded para entrar en pagada y bloquea cualquier retroceso desde pagada. Compatible con register_stripe_invoice_payment().';


COMMIT;
