-- Objetivo:
--   - Mantener la versión 1 al crear un presupuesto.
--   - No incrementar la versión al asociar el PDF o guardar su SHA-256.
--   - Incrementar la versión cuando cambie el contenido real del presupuesto.
--   - Mantener la protección contractual de presupuestos aceptados.
--
-- No modifica las versiones de los presupuestos existentes ni recrea el trigger.

BEGIN;

CREATE OR REPLACE FUNCTION public.version_quotation_before_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- Un presupuesto aceptado está contractualmente congelado.
    IF OLD.estado = 'Aceptado' THEN
        RAISE EXCEPTION
            'El presupuesto aceptado está contractualmente congelado y no puede modificarse';
    END IF;

    -- Solo versionar ediciones de presupuestos que continúan pendientes.
    IF OLD.estado = 'Pendiente'
       AND NEW.estado = 'Pendiente' THEN

        -- Incrementar únicamente si cambia el contenido del presupuesto.
        -- Los cambios exclusivos de document_path, document_sha256 o
        -- updated_at no incrementan la versión.
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
            NEW.quotation_version := OLD.quotation_version + 1;
        ELSE
            NEW.quotation_version := OLD.quotation_version;
        END IF;

    ELSE
        -- Al cambiar de estado, se conserva la versión actual.
        NEW.quotation_version := OLD.quotation_version;
    END IF;

    RETURN NEW;
END;
$function$;

COMMIT;
