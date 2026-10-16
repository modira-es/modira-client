-- ============================================================
-- FIX: Permitir aceptar presupuestos sin invalidar su PDF
-- ============================================================
-- El cambio de estado no modifica el contenido del documento.
-- Se mantiene la invalidación cuando cambian los datos reales
-- representados en el PDF.
-- ============================================================

CREATE OR REPLACE FUNCTION public.invalidate_quotation_document_on_content_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
    IF OLD.company_id IS DISTINCT FROM NEW.company_id
       OR OLD.user_id IS DISTINCT FROM NEW.user_id
       OR OLD.project_id IS DISTINCT FROM NEW.project_id
       OR OLD.client_id IS DISTINCT FROM NEW.client_id
       OR OLD.numero_presupuesto IS DISTINCT FROM NEW.numero_presupuesto
       OR OLD.titulo IS DISTINCT FROM NEW.titulo
       OR OLD.descripcion_detallada IS DISTINCT FROM NEW.descripcion_detallada
       OR OLD.servicios_incluidos IS DISTINCT FROM NEW.servicios_incluidos
       OR OLD.precio_base IS DISTINCT FROM NEW.precio_base
       OR OLD.iva_porcentaje IS DISTINCT FROM NEW.iva_porcentaje
       OR OLD.precio_total IS DISTINCT FROM NEW.precio_total
       OR OLD.irpf_aplicado IS DISTINCT FROM NEW.irpf_aplicado
       OR OLD.irpf_porcentaje IS DISTINCT FROM NEW.irpf_porcentaje
       OR OLD.irpf_importe IS DISTINCT FROM NEW.irpf_importe
       OR OLD.fecha_emision IS DISTINCT FROM NEW.fecha_emision
       OR OLD.fecha_validez IS DISTINCT FROM NEW.fecha_validez
       OR OLD.notas IS DISTINCT FROM NEW.notas
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
    THEN
        NEW.document_path := NULL;
        NEW.document_sha256 := NULL;
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION public.invalidate_quotation_document_on_content_change()
OWNER TO postgres;

COMMENT ON FUNCTION public.invalidate_quotation_document_on_content_change()
IS 'Invalida document_path y document_sha256 cuando cambia cualquier dato representado en el PDF oficial de un presupuesto, incluidos los snapshots fiscales. El cambio de estado no invalida el documento.';