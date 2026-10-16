BEGIN;

-- ============================================================
-- 1. CAMPOS DE RECTIFICACIÓN
-- ============================================================

ALTER TABLE public.maintenance_invoices
    ADD COLUMN IF NOT EXISTS rectification_reason TEXT,
    ADD COLUMN IF NOT EXISTS rectification_customer_data_source TEXT;


-- ============================================================
-- 2. RESTRICCIONES DE INTEGRIDAD
-- ============================================================

ALTER TABLE public.maintenance_invoices
    DROP CONSTRAINT IF EXISTS maintenance_invoices_not_self_rectifying;

ALTER TABLE public.maintenance_invoices
    ADD CONSTRAINT maintenance_invoices_not_self_rectifying
    CHECK (
        rectifies_invoice_id IS NULL
        OR rectifies_invoice_id <> id
    );

ALTER TABLE public.maintenance_invoices
    DROP CONSTRAINT IF EXISTS maintenance_invoices_rectification_consistency;

ALTER TABLE public.maintenance_invoices
    ADD CONSTRAINT maintenance_invoices_rectification_consistency
    CHECK (
        (
            rectifies_invoice_id IS NULL
            AND rectification_reason IS NULL
            AND rectification_customer_data_source IS NULL
        )
        OR
        (
            rectifies_invoice_id IS NOT NULL
            AND rectification_reason IS NOT NULL
            AND LENGTH(BTRIM(rectification_reason)) BETWEEN 1 AND 2000
            AND rectification_customer_data_source IN (
                'original_invoice',
                'current_company'
            )
        )
    );


-- ============================================================
-- 3. PROTECCIÓN DE LOS DATOS FISCALES DEL DESTINATARIO
-- ============================================================
--
-- Comportamiento:
--
-- Factura ordinaria:
--   Conserva el comportamiento actual: toma los datos fiscales
--   de la empresa y los guarda como snapshot.
--
-- Rectificativa con original_invoice:
--   Recupera los datos fiscales de la factura original.
--
-- Rectificativa con current_company:
--   Recupera los datos fiscales actuales de la empresa.
--
-- En ambos casos, la rectificativa conserva sus propios datos.
-- Nunca se modifica la factura original.
-- ============================================================

CREATE OR REPLACE FUNCTION public.guard_maintenance_invoice_fiscal_data()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_company public.companies;
    v_original public.maintenance_invoices;
BEGIN

    -- Los borradores pueden existir incompletos.
    -- La validación fiscal se realiza al emitirlos.
    IF COALESCE(NEW.estado, 'borrador') = 'borrador' THEN
        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- Validar empresa
    -- --------------------------------------------------------

    IF NEW.company_id IS NULL THEN
        RAISE EXCEPTION
            'No se puede emitir una factura de mantenimiento sin empresa';
    END IF;

    SELECT *
    INTO v_company
    FROM public.companies
    WHERE id = NEW.company_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No se puede emitir una factura de mantenimiento: la empresa no existe';
    END IF;


    -- --------------------------------------------------------
    -- CASO A: FACTURA RECTIFICATIVA
    -- --------------------------------------------------------

    IF NEW.rectifies_invoice_id IS NOT NULL THEN

        SELECT *
        INTO v_original
        FROM public.maintenance_invoices
        WHERE id = NEW.rectifies_invoice_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'No existe la factura de mantenimiento que se desea rectificar';
        END IF;

        IF v_original.id = NEW.id THEN
            RAISE EXCEPTION
                'Una factura no puede rectificarse a sí misma';
        END IF;

        IF v_original.company_id IS DISTINCT FROM NEW.company_id THEN
            RAISE EXCEPTION
                'La rectificativa y la factura original deben pertenecer a la misma empresa';
        END IF;


        -- ....................................................
        -- Opción A: snapshot fiscal de la factura original
        -- ....................................................

        IF NEW.rectification_customer_data_source = 'original_invoice' THEN

            NEW.customer_legal_name := v_original.customer_legal_name;
            NEW.customer_tax_id := v_original.customer_tax_id;
            NEW.customer_address := v_original.customer_address;
            NEW.customer_postal_code := v_original.customer_postal_code;
            NEW.customer_city := v_original.customer_city;
            NEW.customer_province := v_original.customer_province;
            NEW.customer_country := v_original.customer_country;


        -- ....................................................
        -- Opción B: datos fiscales actuales de la empresa
        -- ....................................................

        ELSIF NEW.rectification_customer_data_source = 'current_company' THEN

            IF NULLIF(BTRIM(v_company.legal_name), '') IS NULL
               AND NULLIF(BTRIM(v_company.company_name), '') IS NULL
            THEN
                RAISE EXCEPTION
                    'No se puede emitir la rectificativa: falta la razón social';
            END IF;

            IF NULLIF(BTRIM(v_company.cif_vat), '') IS NULL THEN
                RAISE EXCEPTION
                    'No se puede emitir la rectificativa: falta el NIF/CIF/VAT';
            END IF;

            IF NULLIF(BTRIM(v_company.address), '') IS NULL THEN
                RAISE EXCEPTION
                    'No se puede emitir la rectificativa: falta la dirección fiscal';
            END IF;

            IF NULLIF(BTRIM(v_company.postal_code), '') IS NULL THEN
                RAISE EXCEPTION
                    'No se puede emitir la rectificativa: falta el código postal';
            END IF;

            IF NULLIF(BTRIM(v_company.city), '') IS NULL THEN
                RAISE EXCEPTION
                    'No se puede emitir la rectificativa: falta la ciudad';
            END IF;

            IF NULLIF(BTRIM(v_company.country), '') IS NULL THEN
                RAISE EXCEPTION
                    'No se puede emitir la rectificativa: falta el país';
            END IF;

            NEW.customer_legal_name :=
                COALESCE(
                    NULLIF(BTRIM(v_company.legal_name), ''),
                    NULLIF(BTRIM(v_company.company_name), '')
                );

            NEW.customer_tax_id :=
                NULLIF(BTRIM(v_company.cif_vat), '');

            NEW.customer_address :=
                NULLIF(BTRIM(v_company.address), '');

            NEW.customer_postal_code :=
                NULLIF(BTRIM(v_company.postal_code), '');

            NEW.customer_city :=
                NULLIF(BTRIM(v_company.city), '');

            NEW.customer_province :=
                NULLIF(BTRIM(v_company.province), '');

            NEW.customer_country :=
                UPPER(NULLIF(BTRIM(v_company.country), ''));

        ELSE
            RAISE EXCEPTION
                'La rectificativa debe indicar de dónde proceden sus datos fiscales';
        END IF;


    -- --------------------------------------------------------
    -- CASO B: FACTURA ORDINARIA
    -- --------------------------------------------------------

    ELSE

        IF NULLIF(BTRIM(v_company.legal_name), '') IS NULL
           AND NULLIF(BTRIM(v_company.company_name), '') IS NULL
        THEN
            RAISE EXCEPTION
                'No se puede emitir la factura: falta la razón social';
        END IF;

        IF NULLIF(BTRIM(v_company.cif_vat), '') IS NULL THEN
            RAISE EXCEPTION
                'No se puede emitir la factura: falta el NIF/CIF/VAT';
        END IF;

        IF NULLIF(BTRIM(v_company.address), '') IS NULL THEN
            RAISE EXCEPTION
                'No se puede emitir la factura: falta la dirección fiscal';
        END IF;

        IF NULLIF(BTRIM(v_company.postal_code), '') IS NULL THEN
            RAISE EXCEPTION
                'No se puede emitir la factura: falta el código postal';
        END IF;

        IF NULLIF(BTRIM(v_company.city), '') IS NULL THEN
            RAISE EXCEPTION
                'No se puede emitir la factura: falta la ciudad';
        END IF;

        IF NULLIF(BTRIM(v_company.country), '') IS NULL THEN
            RAISE EXCEPTION
                'No se puede emitir la factura: falta el país';
        END IF;

        NEW.customer_legal_name :=
            COALESCE(
                NULLIF(BTRIM(v_company.legal_name), ''),
                NULLIF(BTRIM(v_company.company_name), '')
            );

        NEW.customer_tax_id :=
            NULLIF(BTRIM(v_company.cif_vat), '');

        NEW.customer_address :=
            NULLIF(BTRIM(v_company.address), '');

        NEW.customer_postal_code :=
            NULLIF(BTRIM(v_company.postal_code), '');

        NEW.customer_city :=
            NULLIF(BTRIM(v_company.city), '');

        NEW.customer_province :=
            NULLIF(BTRIM(v_company.province), '');

        NEW.customer_country :=
            UPPER(NULLIF(BTRIM(v_company.country), ''));

    END IF;


    -- --------------------------------------------------------
    -- Validación final del snapshot fiscal
    -- --------------------------------------------------------

    IF NULLIF(BTRIM(NEW.customer_legal_name), '') IS NULL
       OR NULLIF(BTRIM(NEW.customer_tax_id), '') IS NULL
       OR NULLIF(BTRIM(NEW.customer_address), '') IS NULL
       OR NULLIF(BTRIM(NEW.customer_postal_code), '') IS NULL
       OR NULLIF(BTRIM(NEW.customer_city), '') IS NULL
       OR NULLIF(BTRIM(NEW.customer_country), '') IS NULL
    THEN
        RAISE EXCEPTION
            'No se puede emitir la factura: los datos fiscales del destinatario están incompletos';
    END IF;

    RETURN NEW;
END;
$function$;


-- ============================================================
-- 4. PROTEGER LA INFORMACIÓN DE LAS FACTURAS EMITIDAS
-- ============================================================
--
-- Se mantienen las protecciones existentes y se añaden:
-- - La relación con la factura original.
-- - El motivo de rectificación.
-- - La elección de datos fiscales.
-- - Los datos fiscales del emisor.
-- - La imposibilidad de sustituir un documento ya asociado.
--
-- Se permite adjuntar el PDF y su hash cuando todavía no existen.
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_maintenance_invoice_issued_data()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN

    IF OLD.estado <> 'borrador' THEN

        IF NEW.maintenance_contract_id IS DISTINCT FROM OLD.maintenance_contract_id
           OR NEW.company_id IS DISTINCT FROM OLD.company_id
           OR NEW.user_id IS DISTINCT FROM OLD.user_id
           OR NEW.project_id IS DISTINCT FROM OLD.project_id
           OR NEW.serie IS DISTINCT FROM OLD.serie
           OR NEW.numero IS DISTINCT FROM OLD.numero
           OR NEW.fecha_emision IS DISTINCT FROM OLD.fecha_emision
           OR NEW.fecha_operacion IS DISTINCT FROM OLD.fecha_operacion
           OR NEW.fecha_vencimiento IS DISTINCT FROM OLD.fecha_vencimiento
           OR NEW.periodo_inicio IS DISTINCT FROM OLD.periodo_inicio
           OR NEW.periodo_fin IS DISTINCT FROM OLD.periodo_fin
           OR NEW.descripcion IS DISTINCT FROM OLD.descripcion
           OR NEW.contract_snapshot IS DISTINCT FROM OLD.contract_snapshot
           OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
           OR NEW.iva_aplicado IS DISTINCT FROM OLD.iva_aplicado
           OR NEW.iva_porcentaje IS DISTINCT FROM OLD.iva_porcentaje
           OR NEW.iva_importe IS DISTINCT FROM OLD.iva_importe
           OR NEW.irpf_aplicado IS DISTINCT FROM OLD.irpf_aplicado
           OR NEW.irpf_porcentaje IS DISTINCT FROM OLD.irpf_porcentaje
           OR NEW.irpf_importe IS DISTINCT FROM OLD.irpf_importe
           OR NEW.monto IS DISTINCT FROM OLD.monto
           OR NEW.importe_a_pagar IS DISTINCT FROM OLD.importe_a_pagar
           OR NEW.moneda IS DISTINCT FROM OLD.moneda

           OR NEW.customer_legal_name IS DISTINCT FROM OLD.customer_legal_name
           OR NEW.customer_tax_id IS DISTINCT FROM OLD.customer_tax_id
           OR NEW.customer_address IS DISTINCT FROM OLD.customer_address
           OR NEW.customer_postal_code IS DISTINCT FROM OLD.customer_postal_code
           OR NEW.customer_city IS DISTINCT FROM OLD.customer_city
           OR NEW.customer_province IS DISTINCT FROM OLD.customer_province
           OR NEW.customer_country IS DISTINCT FROM OLD.customer_country

           OR NEW.rectifies_invoice_id IS DISTINCT FROM OLD.rectifies_invoice_id
           OR NEW.rectification_reason IS DISTINCT FROM OLD.rectification_reason
           OR NEW.rectification_customer_data_source
                IS DISTINCT FROM OLD.rectification_customer_data_source

           OR NEW.issuer_legal_name IS DISTINCT FROM OLD.issuer_legal_name
           OR NEW.issuer_tax_id IS DISTINCT FROM OLD.issuer_tax_id
           OR NEW.issuer_address IS DISTINCT FROM OLD.issuer_address
           OR NEW.issuer_postal_code IS DISTINCT FROM OLD.issuer_postal_code
           OR NEW.issuer_city IS DISTINCT FROM OLD.issuer_city
           OR NEW.issuer_province IS DISTINCT FROM OLD.issuer_province
           OR NEW.issuer_country IS DISTINCT FROM OLD.issuer_country
        THEN
            RAISE EXCEPTION
                'La factura de mantenimiento emitida es inmutable en sus datos fiscales, económicos y de rectificación';
        END IF;


        -- Un documento ya asociado no se puede sustituir.
        -- Se permite su primera asociación cuando el campo estaba vacío.

        IF (
            OLD.document_path IS NOT NULL
            AND NEW.document_path IS DISTINCT FROM OLD.document_path
        )
        OR (
            OLD.document_sha256 IS NOT NULL
            AND NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256
        )
        OR (
            OLD.pdf_storage_path IS NOT NULL
            AND NEW.pdf_storage_path IS DISTINCT FROM OLD.pdf_storage_path
        )
        OR (
            OLD.pdf_sha256 IS NOT NULL
            AND NEW.pdf_sha256 IS DISTINCT FROM OLD.pdf_sha256
        )
        OR (
            OLD.electronic_document_storage_path IS NOT NULL
            AND NEW.electronic_document_storage_path
                IS DISTINCT FROM OLD.electronic_document_storage_path
        )
        OR (
            OLD.electronic_document_hash IS NOT NULL
            AND NEW.electronic_document_hash
                IS DISTINCT FROM OLD.electronic_document_hash
        )
        THEN
            RAISE EXCEPTION
                'No se puede sustituir un documento ya asociado a una factura emitida';
        END IF;

    END IF;

    RETURN NEW;
END;
$function$;


COMMIT;