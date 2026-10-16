-- 073_invoice_worker_rectification_and_document_invalidation.sql
-- MODIRA
--
-- Additive migration:
-- 1) Allows workers with invoices.create or invoices.update to register
--    rectification metadata safely.
-- 2) Invalidates the backend-generated invoice document whenever data
--    that is represented in the official PDF changes.
--
-- It does not modify migrations 049-072.

BEGIN;

-- ============================================================
-- 1. WORKER RPC — RECTIFICATION
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_invoice_rectification_by_worker(
    p_invoice_id UUID,
    p_rectifies_invoice_id UUID,
    p_rectification_reason TEXT
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invoice public.invoices;
    v_original public.invoices;
    v_can_create BOOLEAN := false;
    v_can_update BOOLEAN := false;
    v_reason TEXT;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    SELECT COALESCE(
        public.current_worker_has_permission('invoices.create'),
        false
    )
    INTO v_can_create;

    SELECT COALESCE(
        public.current_worker_has_permission('invoices.update'),
        false
    )
    INTO v_can_update;

    IF NOT v_can_create AND NOT v_can_update THEN
        RAISE EXCEPTION 'No tienes permiso para gestionar rectificaciones de facturas';
    END IF;

    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id
    FOR UPDATE;

    IF v_invoice.id IS NULL THEN
        RAISE EXCEPTION 'Factura no encontrada';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = v_invoice.id
    ) THEN
        RAISE EXCEPTION 'La factura ya tiene una aceptación documental y sus datos no pueden modificarse';
    END IF;

    -- Limpiar la relación.
    IF p_rectifies_invoice_id IS NULL THEN
        UPDATE public.invoices
        SET
            rectifies_invoice_id = NULL,
            rectification_reason = NULL
        WHERE id = v_invoice.id
        RETURNING * INTO v_invoice;

        RETURN v_invoice;
    END IF;

    IF p_rectifies_invoice_id = p_invoice_id THEN
        RAISE EXCEPTION 'Una factura no puede rectificarse a sí misma';
    END IF;

    v_reason := trim(COALESCE(p_rectification_reason, ''));

    IF v_reason = '' THEN
        RAISE EXCEPTION 'El motivo de rectificación es obligatorio';
    END IF;

    IF length(v_reason) > 2000 THEN
        RAISE EXCEPTION 'El motivo de rectificación no puede superar 2000 caracteres';
    END IF;

    SELECT *
    INTO v_original
    FROM public.invoices
    WHERE id = p_rectifies_invoice_id;

    IF v_original.id IS NULL THEN
        RAISE EXCEPTION 'La factura original que se quiere rectificar no existe';
    END IF;

    IF v_original.company_id IS DISTINCT FROM v_invoice.company_id THEN
        RAISE EXCEPTION 'La factura original debe pertenecer a la misma empresa';
    END IF;

    IF v_original.rectifies_invoice_id IS NOT NULL THEN
        RAISE EXCEPTION 'La factura original seleccionada ya es una factura rectificativa';
    END IF;

    UPDATE public.invoices
    SET
        rectifies_invoice_id = p_rectifies_invoice_id,
        rectification_reason = v_reason
    WHERE id = v_invoice.id
    RETURNING * INTO v_invoice;

    RETURN v_invoice;
END;
$$;

REVOKE ALL ON FUNCTION public.set_invoice_rectification_by_worker(UUID, UUID, TEXT)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.set_invoice_rectification_by_worker(UUID, UUID, TEXT)
TO authenticated;

COMMENT ON FUNCTION public.set_invoice_rectification_by_worker(UUID, UUID, TEXT)
IS 'Registra o limpia la relación de rectificación de una factura. Solo workers con invoices.create o invoices.update y nunca después de la aceptación documental.';

-- ============================================================
-- 2. INVALIDACIÓN DEL PDF OFICIAL
-- ============================================================

CREATE OR REPLACE FUNCTION public.invalidate_invoice_backend_document_on_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- El trigger de protección de datos aceptados de la migración 071
    -- debe rechazar primero cualquier modificación protegida.
    --
    -- Para facturas todavía modificables, cualquier cambio que altere
    -- el contenido representado en el PDF invalida la ruta/hash actuales.
    IF
        OLD.numero_factura IS DISTINCT FROM NEW.numero_factura
        OR OLD.fecha_emision IS DISTINCT FROM NEW.fecha_emision
        OR OLD.fecha_vencimiento IS DISTINCT FROM NEW.fecha_vencimiento
        OR OLD.descripcion IS DISTINCT FROM NEW.descripcion
        OR OLD.subtotal IS DISTINCT FROM NEW.subtotal
        OR OLD.iva_aplicado IS DISTINCT FROM NEW.iva_aplicado
        OR OLD.iva_porcentaje IS DISTINCT FROM NEW.iva_porcentaje
        OR OLD.iva_importe IS DISTINCT FROM NEW.iva_importe
        OR OLD.irpf_aplicado IS DISTINCT FROM NEW.irpf_aplicado
        OR OLD.irpf_porcentaje IS DISTINCT FROM NEW.irpf_porcentaje
        OR OLD.irpf_importe IS DISTINCT FROM NEW.irpf_importe
        OR OLD.monto IS DISTINCT FROM NEW.monto
        OR OLD.importe_a_pagar IS DISTINCT FROM NEW.importe_a_pagar
        OR OLD.company_id IS DISTINCT FROM NEW.company_id
        OR OLD.project_id IS DISTINCT FROM NEW.project_id
        OR OLD.client_id IS DISTINCT FROM NEW.client_id
        OR OLD.quotation_id IS DISTINCT FROM NEW.quotation_id
        OR OLD.user_id IS DISTINCT FROM NEW.user_id
        OR OLD.issuer_legal_name IS DISTINCT FROM NEW.issuer_legal_name
        OR OLD.issuer_tax_id IS DISTINCT FROM NEW.issuer_tax_id
        OR OLD.issuer_address IS DISTINCT FROM NEW.issuer_address
        OR OLD.issuer_postal_code IS DISTINCT FROM NEW.issuer_postal_code
        OR OLD.issuer_city IS DISTINCT FROM NEW.issuer_city
        OR OLD.issuer_province IS DISTINCT FROM NEW.issuer_province
        OR OLD.issuer_country IS DISTINCT FROM NEW.issuer_country
        OR OLD.customer_legal_name IS DISTINCT FROM NEW.customer_legal_name
        OR OLD.customer_tax_id IS DISTINCT FROM NEW.customer_tax_id
        OR OLD.customer_address IS DISTINCT FROM NEW.customer_address
        OR OLD.customer_postal_code IS DISTINCT FROM NEW.customer_postal_code
        OR OLD.customer_city IS DISTINCT FROM NEW.customer_city
        OR OLD.customer_province IS DISTINCT FROM NEW.customer_province
        OR OLD.customer_country IS DISTINCT FROM NEW.customer_country
        OR OLD.customer_contact_name IS DISTINCT FROM NEW.customer_contact_name
        OR OLD.rectifies_invoice_id IS DISTINCT FROM NEW.rectifies_invoice_id
        OR OLD.rectification_reason IS DISTINCT FROM NEW.rectification_reason
    THEN
        NEW.document_path := NULL;
        NEW.document_sha256 := NULL;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS invoices_zz_invalidate_backend_document
ON public.invoices;

CREATE TRIGGER invoices_zz_invalidate_backend_document
BEFORE UPDATE ON public.invoices
FOR EACH ROW
EXECUTE FUNCTION public.invalidate_invoice_backend_document_on_change();

REVOKE ALL ON FUNCTION public.invalidate_invoice_backend_document_on_change()
FROM PUBLIC;

COMMENT ON FUNCTION public.invalidate_invoice_backend_document_on_change()
IS 'Invalida document_path y document_sha256 cuando cambia cualquier dato representado en el PDF oficial. La protección de aceptación documental de la migración 071 se mantiene.';

COMMIT;
