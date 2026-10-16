BEGIN;

-- ============================================================
-- MODIRA — 044_quotations_irpf.sql
--
-- OBJETIVO
-- ============================================================
--
-- Añadir soporte de IRPF a los presupuestos SIN modificar ni
-- eliminar columnas existentes y sin alterar los datos
-- económicos históricos de quotations.
--
-- Además:
--   - el IRPF se calcula sobre precio_base;
--   - precio_total mantiene el significado actual:
--       precio_base + IVA;
--   - el IRPF se resta posteriormente al importe a pagar.
--
-- Los presupuestos existentes reciben:
--   irpf_aplicado = FALSE
--   irpf_porcentaje = 0
--   irpf_importe = 0
--
-- No se toca:
--   - invoices
--   - payments
--   - Stripe
--   - RLS existente
--   - políticas existentes
--   - numero_presupuesto
--   - relaciones existentes
--
-- IMPORTANTE:
-- Esta migración NO modifica el precio_total histórico de
-- ningún presupuesto existente.
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
          AND table_name = 'quotations'
    ) THEN
        RAISE EXCEPTION
            '044 stopped: public.quotations does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'precio_base'
    ) THEN
        RAISE EXCEPTION
            '044 stopped: quotations.precio_base does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'iva_porcentaje'
    ) THEN
        RAISE EXCEPTION
            '044 stopped: quotations.iva_porcentaje does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'precio_total'
    ) THEN
        RAISE EXCEPTION
            '044 stopped: quotations.precio_total does not exist';
    END IF;
END $$;


-- ============================================================
-- 2. NUEVOS CAMPOS DE IRPF
-- ============================================================
--
-- ADD COLUMN IF NOT EXISTS hace la migración idempotente.
-- Los valores DEFAULT solo se aplican a las nuevas columnas;
-- no se modifica ninguna columna económica existente.
-- ============================================================

ALTER TABLE public.quotations
    ADD COLUMN IF NOT EXISTS irpf_aplicado BOOLEAN
        NOT NULL DEFAULT FALSE;

ALTER TABLE public.quotations
    ADD COLUMN IF NOT EXISTS irpf_porcentaje NUMERIC(5,2)
        NOT NULL DEFAULT 0;

ALTER TABLE public.quotations
    ADD COLUMN IF NOT EXISTS irpf_importe NUMERIC(12,2)
        NOT NULL DEFAULT 0;


-- ============================================================
-- 3. RESTRICCIONES DE IRPF
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.quotations'::regclass
          AND conname = 'quotations_irpf_check'
    ) THEN
        ALTER TABLE public.quotations
            ADD CONSTRAINT quotations_irpf_check
            CHECK (
                irpf_porcentaje >= 0
                AND irpf_porcentaje <= 100
                AND irpf_importe >= 0
                AND irpf_importe <= precio_base
            );
    END IF;
END $$;


-- ============================================================
-- 4. FUNCIÓN DE CÁLCULO ECONÓMICO
-- ============================================================
--
-- Mantiene el precio_total del presupuesto con el significado
-- que ya tenía:
--
--   IVA = ROUND(precio_base * iva / 100, 2)
--   precio_total = ROUND(precio_base + IVA, 2)
--
-- El IRPF NO se descuenta de precio_total.
-- Se conserva como importe separado para conocer:
--
--   Importe a pagar = precio_total - irpf_importe
--
-- Esto permite que el presupuesto y la futura factura puedan
-- mostrar separadamente:
--
--   Base imponible
--   IVA
--   Total bruto
--   IRPF
--   A pagar
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_quotation_amounts()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_base NUMERIC(12,2);
    v_iva_porcentaje NUMERIC(5,2);
    v_iva_importe NUMERIC(12,2);
    v_irpf_porcentaje NUMERIC(5,2);
BEGIN
    v_base :=
        ROUND(
            GREATEST(COALESCE(NEW.precio_base, 0), 0),
            2
        );

    v_iva_porcentaje :=
        ROUND(
            GREATEST(COALESCE(NEW.iva_porcentaje, 0), 0),
            2
        );

    v_irpf_porcentaje :=
        ROUND(
            GREATEST(
                CASE
                    WHEN COALESCE(NEW.irpf_aplicado, FALSE)
                        THEN COALESCE(NEW.irpf_porcentaje, 0)
                    ELSE 0
                END,
                0
            ),
            2
        );

    v_iva_importe :=
        ROUND(
            v_base * v_iva_porcentaje / 100,
            2
        );

    NEW.precio_base :=
        v_base;

    NEW.iva_porcentaje :=
        v_iva_porcentaje;

    NEW.precio_total :=
        ROUND(
            v_base + v_iva_importe,
            2
        );

    NEW.irpf_porcentaje :=
        v_irpf_porcentaje;

    NEW.irpf_importe :=
        CASE
            WHEN COALESCE(NEW.irpf_aplicado, FALSE)
                THEN ROUND(
                    v_base * v_irpf_porcentaje / 100,
                    2
                )
            ELSE 0
        END;

    RETURN NEW;
END;
$function$;


-- ============================================================
-- 5. TRIGGER
-- ============================================================

DROP TRIGGER IF EXISTS sync_quotation_amounts_trigger
ON public.quotations;

CREATE TRIGGER sync_quotation_amounts_trigger
BEFORE INSERT OR UPDATE OF
    precio_base,
    iva_porcentaje,
    precio_total,
    irpf_aplicado,
    irpf_porcentaje
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.sync_quotation_amounts();


-- ============================================================
-- 6. PERMISOS DE LA FUNCIÓN
-- ============================================================
--
-- La función solo se ejecuta mediante el trigger.
-- No se expone como RPC pública.
-- ============================================================

REVOKE ALL
ON FUNCTION public.sync_quotation_amounts()
FROM PUBLIC;


-- ============================================================
-- 7. VERIFICACIONES FINALES
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'irpf_aplicado'
          AND data_type = 'boolean'
    ) THEN
        RAISE EXCEPTION
            '044 failed: irpf_aplicado was not created correctly';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'irpf_porcentaje'
          AND data_type = 'numeric'
    ) THEN
        RAISE EXCEPTION
            '044 failed: irpf_porcentaje was not created correctly';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'irpf_importe'
          AND data_type = 'numeric'
    ) THEN
        RAISE EXCEPTION
            '044 failed: irpf_importe was not created correctly';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid = 'public.quotations'::regclass
          AND tgname = 'sync_quotation_amounts_trigger'
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION
            '044 failed: quotation amount trigger is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.quotations'::regclass
          AND conname = 'quotations_irpf_check'
    ) THEN
        RAISE EXCEPTION
            '044 failed: quotations_irpf_check is missing';
    END IF;

END $$;


COMMIT;
