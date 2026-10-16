-- ============================================================
-- 061 — FIX INVALIDACIÓN DOCUMENTAL DE QUOTATIONS
-- ============================================================
-- Corrige invalidate_quotation_document_on_content_change()
-- que hacía referencia a OLD/NEW.iva_importe.
--
-- La tabla public.quotations NO dispone de una columna
-- iva_importe. El importe de IVA se calcula dentro de
-- sync_quotation_amounts() y queda reflejado en precio_total.
--
-- Este error impedía actualizar un quotation al adjuntar
-- un PDF, provocando:
--
--   record "old" has no field "iva_importe"
--
-- La migración conserva el trigger existente y únicamente
-- reemplaza la función con una versión compatible con el
-- esquema real de public.quotations.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. CORRECCIÓN DE LA FUNCIÓN
-- ============================================================

CREATE OR REPLACE FUNCTION public.invalidate_quotation_document_on_content_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    /*
     * Solo necesitamos invalidar el documento si el presupuesto
     * resultante vuelve a estar Pendiente.
     *
     * Esto cubre:
     *
     *   Pendiente -> Pendiente
     *   Rechazado -> Pendiente
     *
     * y evita conservar un PDF antiguo cuando cambia el contenido.
     *
     * IMPORTANTE:
     * public.quotations no tiene iva_importe.
     * El IVA se representa mediante iva_porcentaje y el resultado
     * fiscal queda reflejado en precio_total.
     */

    IF LOWER(TRIM(COALESCE(NEW.estado, ''))) = 'pendiente'
       AND (
            OLD.company_id IS DISTINCT FROM NEW.company_id
         OR OLD.user_id IS DISTINCT FROM NEW.user_id
         OR OLD.project_id IS DISTINCT FROM NEW.project_id
         OR OLD.client_id IS DISTINCT FROM NEW.client_id
         OR OLD.titulo IS DISTINCT FROM NEW.titulo
         OR OLD.descripcion_detallada IS DISTINCT FROM NEW.descripcion_detallada
         OR OLD.servicios_incluidos IS DISTINCT FROM NEW.servicios_incluidos
         OR OLD.precio_base IS DISTINCT FROM NEW.precio_base
         OR OLD.iva_porcentaje IS DISTINCT FROM NEW.iva_porcentaje
         OR OLD.irpf_aplicado IS DISTINCT FROM NEW.irpf_aplicado
         OR OLD.irpf_porcentaje IS DISTINCT FROM NEW.irpf_porcentaje
         OR OLD.irpf_importe IS DISTINCT FROM NEW.irpf_importe
         OR OLD.precio_total IS DISTINCT FROM NEW.precio_total
         OR OLD.fecha_emision IS DISTINCT FROM NEW.fecha_emision
         OR OLD.fecha_validez IS DISTINCT FROM NEW.fecha_validez
         OR OLD.notas IS DISTINCT FROM NEW.notas
       )
    THEN

        /*
         * Si cambia el contenido de un presupuesto Pendiente,
         * el PDF anterior deja de ser válido.
         */
        NEW.document_path := NULL;
        NEW.document_sha256 := NULL;

    END IF;


    RETURN NEW;

END;
$$;


-- ============================================================
-- 2. GARANTIZAR QUE EL TRIGGER CORRECTO EXISTE
-- ============================================================

DROP TRIGGER IF EXISTS quotations_invalidate_document_on_content_change
ON public.quotations;

CREATE TRIGGER quotations_invalidate_document_on_content_change
BEFORE UPDATE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.invalidate_quotation_document_on_content_change();


-- ============================================================
-- 3. VERIFICACIONES DE SEGURIDAD
-- ============================================================

DO $$
DECLARE
    v_function_count INTEGER;
    v_trigger_count INTEGER;
    v_function_definition TEXT;
BEGIN

    -- --------------------------------------------------------
    -- La función debe existir exactamente una vez.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_function_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'invalidate_quotation_document_on_content_change'
      AND pg_get_function_identity_arguments(p.oid) = '';

    IF v_function_count <> 1 THEN
        RAISE EXCEPTION
            '061 failed: invalidate_quotation_document_on_content_change() missing or duplicated';
    END IF;


    -- --------------------------------------------------------
    -- Debe existir exactamente un trigger.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_trigger_count
    FROM pg_trigger
    WHERE tgrelid = 'public.quotations'::regclass
      AND tgname = 'quotations_invalidate_document_on_content_change'
      AND NOT tgisinternal;

    IF v_trigger_count <> 1 THEN
        RAISE EXCEPTION
            '061 failed: quotations_invalidate_document_on_content_change trigger missing or duplicated';
    END IF;


    -- --------------------------------------------------------
    -- La función NO puede contener iva_importe.
    -- --------------------------------------------------------

    SELECT pg_get_functiondef(p.oid)
    INTO v_function_definition
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'invalidate_quotation_document_on_content_change'
      AND pg_get_function_identity_arguments(p.oid) = '';

    IF LOWER(v_function_definition) LIKE '%old.iva_importe%'
       OR LOWER(v_function_definition) LIKE '%new.iva_importe%'
    THEN
        RAISE EXCEPTION
            '061 failed: invalid reference to iva_importe remains in quotation document invalidation function';
    END IF;


    -- --------------------------------------------------------
    -- La función debe ser SECURITY DEFINER.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'invalidate_quotation_document_on_content_change'
          AND pg_get_function_identity_arguments(p.oid) = ''
          AND p.prosecdef = TRUE
    ) THEN
        RAISE EXCEPTION
            '061 failed: quotation document invalidation function must be SECURITY DEFINER';
    END IF;


    -- --------------------------------------------------------
    -- La función debe utilizar el search_path endurecido.
    -- --------------------------------------------------------

    IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'invalidate_quotation_document_on_content_change'
      AND pg_get_function_identity_arguments(p.oid) = ''
      AND p.proconfig @> ARRAY['search_path=public, pg_temp']
) THEN
        RAISE EXCEPTION
            '061 failed: quotation document invalidation function search_path is not hardened';
    END IF;


    -- --------------------------------------------------------
    -- Comprobación final.
    -- --------------------------------------------------------

    RAISE NOTICE
        '061 OK: quotation document invalidation function corrected successfully';

END;
$$;

GRANT SELECT ON TABLE public.quotations TO service_role;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
COMMIT;
