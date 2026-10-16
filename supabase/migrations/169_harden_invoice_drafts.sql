-- Migration 169: hardening final de borradores y facturas emitidas
-- Aplicar después de 167_link_invoices_to_quotations.sql y 168_invoice_drafts.sql.
-- Los borradores siguen siendo editables y eliminables; una factura emitida no.
-- Cada factura requiere un presupuesto aceptado de la misma empresa y proyecto.

BEGIN;

CREATE OR REPLACE FUNCTION "public"."create_invoice_by_worker"("p_company_id" "uuid", "p_project_id" "uuid", "p_fecha_emision" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_fecha_vencimiento" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_descripcion" "text" DEFAULT NULL::"text", "p_subtotal" numeric DEFAULT 0, "p_iva_porcentaje" numeric DEFAULT 21, "p_quotation_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$

DECLARE

    v_invoice public.invoices;

    v_project_user_id UUID;
    v_project_client_id UUID;
    v_project_company_id UUID;

    v_quotation_company_id UUID;
    v_quotation_project_id UUID;
    v_quotation_estado TEXT;

    v_numero_factura TEXT;

    v_subtotal NUMERIC(12,2);
    v_iva_porcentaje NUMERIC(5,2);
    v_iva_importe NUMERIC(12,2);
    v_monto NUMERIC(12,2);

    -- --------------------------------------------------------
    -- Fiscal issuer
    -- --------------------------------------------------------

    v_issuer_legal_name TEXT;
    v_issuer_tax_id TEXT;
    v_issuer_address TEXT;
    v_issuer_postal_code TEXT;
    v_issuer_city TEXT;
    v_issuer_province TEXT;
    v_issuer_country TEXT;

    -- --------------------------------------------------------
    -- Fiscal customer
    -- --------------------------------------------------------

    v_customer_legal_name TEXT;
    v_customer_tax_id TEXT;
    v_customer_address TEXT;
    v_customer_postal_code TEXT;
    v_customer_city TEXT;
    v_customer_province TEXT;
    v_customer_country TEXT;
    v_customer_contact_name TEXT;

BEGIN


    -- ========================================================
    -- 1. PERMISSION
    -- ========================================================

    PERFORM public.require_current_worker_permission(
        'invoices.create'
    );


    -- ========================================================
    -- 2. COMPANY
    -- ========================================================

    IF p_company_id IS NULL THEN

        RAISE EXCEPTION
            'La empresa es obligatoria';

    END IF;


    SELECT
        COALESCE(
            NULLIF(TRIM(c.legal_name), ''),
            NULLIF(TRIM(c.company_name), '')
        ),
        NULLIF(TRIM(c.cif_vat), ''),
        NULLIF(TRIM(c.address), ''),
        NULLIF(TRIM(c.postal_code), ''),
        NULLIF(TRIM(c.city), ''),
        NULLIF(TRIM(c.province), ''),
        COALESCE(
            NULLIF(TRIM(c.country), ''),
            'ES'
        )
    INTO
        v_issuer_legal_name,
        v_issuer_tax_id,
        v_issuer_address,
        v_issuer_postal_code,
        v_issuer_city,
        v_issuer_province,
        v_issuer_country
    FROM public.companies c
    WHERE c.id = p_company_id;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'La empresa seleccionada no existe';

    END IF;


    -- ========================================================
    -- 3. PROJECT
    -- ========================================================

    IF p_project_id IS NULL THEN

        RAISE EXCEPTION
            'El proyecto es obligatorio';

    END IF;


    SELECT
        p.user_id,
        p.client_id,
        p.company_id
    INTO
        v_project_user_id,
        v_project_client_id,
        v_project_company_id
    FROM public.projects p
    WHERE p.id = p_project_id;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'El proyecto seleccionado no existe';

    END IF;


    IF v_project_company_id IS DISTINCT FROM p_company_id THEN

        RAISE EXCEPTION
            'El proyecto no pertenece a la empresa seleccionada';

    END IF;


    IF v_project_user_id IS NULL THEN

        RAISE EXCEPTION
            'El proyecto no tiene un usuario propietario válido';

    END IF;


    -- ========================================================
    -- 3B. QUOTATION REFERENCE
    -- ========================================================

    IF p_quotation_id IS NULL THEN
        RAISE EXCEPTION
            'Debes seleccionar un presupuesto de referencia';
    END IF;

    SELECT q.company_id, q.project_id, q.estado
    INTO v_quotation_company_id, v_quotation_project_id, v_quotation_estado
    FROM public.quotations q
    WHERE q.id = p_quotation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El presupuesto seleccionado no existe';
    END IF;

    IF v_quotation_company_id IS DISTINCT FROM p_company_id THEN
        RAISE EXCEPTION
            'El presupuesto no pertenece a la empresa seleccionada';
    END IF;

    IF v_quotation_project_id IS DISTINCT FROM p_project_id THEN
        RAISE EXCEPTION
            'El presupuesto no pertenece al proyecto seleccionado';
    END IF;

    IF LOWER(TRIM(COALESCE(v_quotation_estado, ''))) <> 'aceptado' THEN
        RAISE EXCEPTION
            'Solo se pueden emitir facturas a partir de un presupuesto aceptado';
    END IF;


    -- ========================================================
    -- 4. CLIENT SNAPSHOT
    -- ========================================================
    --
    -- Si el proyecto no tiene cliente, mantenemos el
    -- comportamiento permisivo actual:
    --
    --   client_id = NULL
    --   customer snapshot = NULL
    --
    -- No hacemos obligatorio un cliente porque actualmente
    -- projects.client_id puede ser NULL.
    --
    -- ========================================================

    IF v_project_client_id IS NOT NULL THEN

        SELECT
            COALESCE(
                NULLIF(TRIM(c.empresa), ''),
                NULLIF(TRIM(c.nombre), '')
            ),
            NULLIF(TRIM(c.cif_vat), ''),
            NULLIF(TRIM(c.direccion), ''),
            NULLIF(TRIM(c.codigo_postal), ''),
            NULLIF(TRIM(c.ciudad), ''),
            NULLIF(TRIM(c.provincia), ''),
            COALESCE(
                NULLIF(TRIM(c.pais), ''),
                'ES'
            ),
            NULLIF(TRIM(c.nombre), '')
        INTO
            v_customer_legal_name,
            v_customer_tax_id,
            v_customer_address,
            v_customer_postal_code,
            v_customer_city,
            v_customer_province,
            v_customer_country,
            v_customer_contact_name
        FROM public.clients c
        WHERE c.id = v_project_client_id
          AND c.company_id = p_company_id;


        IF NOT FOUND THEN

            RAISE EXCEPTION
                'El cliente del proyecto no existe o no pertenece a la empresa seleccionada';

        END IF;

    END IF;


    -- ========================================================
    -- 5. ECONOMIC VALUES
    -- ========================================================

    v_subtotal :=
        COALESCE(
            p_subtotal,
            0
        );


    v_iva_porcentaje :=
        COALESCE(
            p_iva_porcentaje,
            0
        );


    IF v_subtotal < 0 THEN

        RAISE EXCEPTION
            'El importe no puede ser negativo';

    END IF;


    IF v_iva_porcentaje < 0
       OR v_iva_porcentaje > 100
    THEN

        RAISE EXCEPTION
            'El IVA debe estar entre 0 y 100';

    END IF;


    -- ========================================================
    -- 6. DATES
    -- ========================================================

    IF p_fecha_vencimiento IS NOT NULL
       AND COALESCE(
           p_fecha_emision,
           CURRENT_TIMESTAMP
       ) > p_fecha_vencimiento
    THEN

        RAISE EXCEPTION
            'La fecha de vencimiento no puede ser anterior a la fecha de emisión';

    END IF;


    -- ========================================================
    -- 7. CALCULATE IVA
    -- ========================================================

    v_iva_importe :=
        ROUND(
            v_subtotal
            *
            v_iva_porcentaje
            /
            100,
            2
        );


    -- ========================================================
    -- 8. CALCULATE TOTAL
    -- ========================================================

    v_monto :=
        ROUND(
            v_subtotal
            +
            v_iva_importe,
            2
        );


    -- ========================================================
    -- 9. GENERATE NUMBER
    -- ========================================================

    v_numero_factura :=
        public.generate_invoice_number();


    -- ========================================================
    -- 10. INSERT
    -- ========================================================

    INSERT INTO public.invoices (
        user_id,
        company_id,
        project_id,
        client_id,
        quotation_id,

        numero_factura,
        monto,
        estado,

        fecha_emision,
        fecha_vencimiento,

        descripcion,

        subtotal,
        iva_porcentaje,
        iva_importe,

        -- ----------------------------------------------------
        -- Issuer fiscal snapshot
        -- ----------------------------------------------------

        issuer_legal_name,
        issuer_tax_id,
        issuer_address,
        issuer_postal_code,
        issuer_city,
        issuer_province,
        issuer_country,

        -- ----------------------------------------------------
        -- Customer fiscal snapshot
        -- ----------------------------------------------------

        customer_legal_name,
        customer_tax_id,
        customer_address,
        customer_postal_code,
        customer_city,
        customer_province,
        customer_country,
        customer_contact_name
    )
    VALUES (
        v_project_user_id,
        p_company_id,
        p_project_id,
        v_project_client_id,
        p_quotation_id,

        v_numero_factura,
        v_monto,
        'pendiente',

        COALESCE(
            p_fecha_emision,
            CURRENT_TIMESTAMP
        ),
        p_fecha_vencimiento,

        NULLIF(
            TRIM(p_descripcion),
            ''
        ),

        v_subtotal,
        v_iva_porcentaje,
        v_iva_importe,

        -- issuer
        v_issuer_legal_name,
        v_issuer_tax_id,
        v_issuer_address,
        v_issuer_postal_code,
        v_issuer_city,
        v_issuer_province,
        v_issuer_country,

        -- customer
        v_customer_legal_name,
        v_customer_tax_id,
        v_customer_address,
        v_customer_postal_code,
        v_customer_city,
        v_customer_province,
        v_customer_country,
        v_customer_contact_name
    )
    RETURNING *
    INTO v_invoice;


    -- ========================================================
    -- 11. RETURN
    -- ========================================================

    RETURN v_invoice;


END;
$$;

CREATE OR REPLACE FUNCTION
public.save_invoice_draft_by_worker(
    p_invoice_id uuid,
    p_company_id uuid,
    p_project_id uuid,
    p_quotation_id uuid,
    p_fecha_emision timestamptz,
    p_fecha_vencimiento timestamptz,
    p_descripcion text,
    p_subtotal numeric,
    p_iva_aplicado boolean,
    p_iva_porcentaje numeric,
    p_irpf_aplicado boolean,
    p_irpf_porcentaje numeric
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_invoice public.invoices;

    v_quotation_company_id uuid;
    v_quotation_project_id uuid;
    v_quotation_estado text;
BEGIN

    PERFORM public.require_current_worker_permission(
        'invoices.update'
    );


    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Factura no encontrada';
    END IF;


    IF v_invoice.estado IS DISTINCT FROM 'borrador' THEN
        RAISE EXCEPTION
            'Solo se pueden editar facturas en borrador';
    END IF;


    IF v_invoice.document_path IS NOT NULL
       OR v_invoice.document_sha256 IS NOT NULL
    THEN
        RAISE EXCEPTION
            'El borrador tiene un documento oficial asociado';
    END IF;


    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = v_invoice.id
    ) THEN
        RAISE EXCEPTION
            'La factura tiene una aceptación documental y no se puede modificar';
    END IF;


    IF p_quotation_id IS NULL THEN
        RAISE EXCEPTION
            'Debes seleccionar un presupuesto de referencia';
    END IF;


    SELECT
        q.company_id,
        q.project_id,
        q.estado
    INTO
        v_quotation_company_id,
        v_quotation_project_id,
        v_quotation_estado
    FROM public.quotations q
    WHERE q.id = p_quotation_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El presupuesto seleccionado no existe';
    END IF;


    IF v_quotation_company_id IS DISTINCT FROM p_company_id
       OR v_quotation_project_id IS DISTINCT FROM p_project_id
    THEN
        RAISE EXCEPTION
            'El presupuesto debe pertenecer a la misma empresa y proyecto';
    END IF;

    IF LOWER(TRIM(COALESCE(v_quotation_estado, ''))) <> 'aceptado' THEN
        RAISE EXCEPTION
            'Solo se pueden guardar facturas vinculadas a un presupuesto aceptado';
    END IF;


    -- Autorizar únicamente esta operación de guardado.
    -- La transacción no deja la factura en estado pendiente.

    PERFORM set_config(
        'modira.invoice_save_draft',
        'on',
        true
    );


    v_invoice := public.update_invoice_by_worker(
        p_invoice_id,
        p_company_id,
        p_project_id,
        p_fecha_emision,
        p_fecha_vencimiento,
        p_descripcion,
        p_subtotal,
        p_iva_aplicado,
        p_iva_porcentaje,
        p_irpf_aplicado,
        p_irpf_porcentaje,
        'pendiente'
    );


    UPDATE public.invoices
    SET
        quotation_id = p_quotation_id,
        estado = 'borrador'
    WHERE id = p_invoice_id
    RETURNING *
    INTO v_invoice;


    RETURN v_invoice;

END;
$function$;

CREATE OR REPLACE FUNCTION
public.guard_invoice_draft_and_issued_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_create_draft boolean;
    v_save_draft boolean;
    v_finalize boolean;
    v_content_changed boolean;
    v_old_has_document boolean;
BEGIN

    v_create_draft :=
        COALESCE(
            current_setting('modira.invoice_create_draft', true),
            ''
        ) = 'on';

    v_save_draft :=
        COALESCE(
            current_setting('modira.invoice_save_draft', true),
            ''
        ) = 'on';

    v_finalize :=
        COALESCE(
            current_setting('modira.invoice_finalize', true),
            ''
        ) = 'on';


    -- El número asignado nunca se modifica.

    IF NEW.numero_factura IS DISTINCT FROM OLD.numero_factura THEN
        RAISE EXCEPTION
            'No se puede modificar el número de una factura';
    END IF;


    v_old_has_document :=
        OLD.document_path IS NOT NULL
        OR OLD.document_sha256 IS NOT NULL;


    -- Un borrador no puede conservar un PDF oficial registrado.

    IF NEW.estado = 'borrador'
       AND (
           NEW.document_path IS NOT NULL
           OR NEW.document_sha256 IS NOT NULL
       )
    THEN
        RAISE EXCEPTION
            'Un borrador no puede tener un documento oficial asociado';
    END IF;


    -- Determinar si se están modificando los datos que forman
    -- parte del contenido de la factura.

    v_content_changed :=
        ROW(
            NEW.user_id,
            NEW.company_id,
            NEW.project_id,
            NEW.client_id,
            NEW.quotation_id,
            NEW.fecha_emision,
            NEW.fecha_vencimiento,
            NEW.descripcion,
            NEW.subtotal,
            NEW.iva_aplicado,
            NEW.iva_porcentaje,
            NEW.iva_importe,
            NEW.irpf_aplicado,
            NEW.irpf_porcentaje,
            NEW.irpf_importe,
            NEW.monto,
            NEW.importe_a_pagar,
            NEW.issuer_legal_name,
            NEW.issuer_tax_id,
            NEW.issuer_address,
            NEW.issuer_postal_code,
            NEW.issuer_city,
            NEW.issuer_province,
            NEW.issuer_country,
            NEW.customer_legal_name,
            NEW.customer_tax_id,
            NEW.customer_address,
            NEW.customer_postal_code,
            NEW.customer_city,
            NEW.customer_province,
            NEW.customer_country,
            NEW.customer_contact_name,
            NEW.rectifies_invoice_id,
            NEW.rectification_reason,
            NEW.rectification_customer_data_source
        )
        IS DISTINCT FROM
        ROW(
            OLD.user_id,
            OLD.company_id,
            OLD.project_id,
            OLD.client_id,
            OLD.quotation_id,
            OLD.fecha_emision,
            OLD.fecha_vencimiento,
            OLD.descripcion,
            OLD.subtotal,
            OLD.iva_aplicado,
            OLD.iva_porcentaje,
            OLD.iva_importe,
            OLD.irpf_aplicado,
            OLD.irpf_porcentaje,
            OLD.irpf_importe,
            OLD.monto,
            OLD.importe_a_pagar,
            OLD.issuer_legal_name,
            OLD.issuer_tax_id,
            OLD.issuer_address,
            OLD.issuer_postal_code,
            OLD.issuer_city,
            OLD.issuer_province,
            OLD.issuer_country,
            OLD.customer_legal_name,
            OLD.customer_tax_id,
            OLD.customer_address,
            OLD.customer_postal_code,
            OLD.customer_city,
            OLD.customer_province,
            OLD.customer_country,
            OLD.customer_contact_name,
            OLD.rectifies_invoice_id,
            OLD.rectification_reason,
            OLD.rectification_customer_data_source
        );


    -- --------------------------------------------------------
    -- 1.1. CAMBIOS DE DOCUMENTO
    -- --------------------------------------------------------
    --
    -- Solo la finalización documental autorizada puede registrar
    -- o modificar la ruta/hash del documento.
    -- --------------------------------------------------------

    IF (
        NEW.document_path IS DISTINCT FROM OLD.document_path
        OR NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256
    )
    AND NOT v_finalize
    THEN
        RAISE EXCEPTION
            'El documento oficial solo puede registrarse mediante la finalización documental';
    END IF;


    -- --------------------------------------------------------
    -- 1.2. FACTURAS QUE YA TIENEN DOCUMENTO OFICIAL
    -- --------------------------------------------------------

    IF v_old_has_document THEN

        IF v_content_changed THEN
            RAISE EXCEPTION
                'Una factura con documento oficial no puede editarse. Debe corregirse mediante una factura rectificativa';
        END IF;

        IF NEW.estado = 'borrador' THEN
            RAISE EXCEPTION
                'Una factura con documento oficial no puede volver a borrador';
        END IF;

    END IF;


    -- --------------------------------------------------------
    -- 1.3. CAMBIOS DE ESTADO DESDE BORRADOR
    -- --------------------------------------------------------

    IF OLD.estado = 'borrador' THEN

        IF NEW.estado = 'borrador' THEN
            RETURN NEW;
        END IF;


        -- Guardar un borrador puede utilizar internamente la
        -- función de actualización existente, pero el estado
        -- final debe seguir siendo borrador.

        IF v_save_draft
           AND NEW.estado = 'pendiente'
           AND NEW.document_path IS NULL
           AND NEW.document_sha256 IS NULL
        THEN
            RETURN NEW;
        END IF;


        -- Crear un borrador reutiliza el generador de números
        -- existente y transforma el registro dentro de la misma
        -- transacción.

        IF v_create_draft
           AND NEW.estado = 'borrador'
           AND NEW.document_path IS NULL
           AND NEW.document_sha256 IS NULL
        THEN
            RETURN NEW;
        END IF;


        -- La transición a pendiente solo se permite cuando el
        -- PDF oficial y su hash están siendo finalizados.

        IF v_finalize
           AND NEW.estado = 'pendiente'
           AND NEW.document_path IS NOT NULL
           AND NEW.document_sha256 IS NOT NULL
        THEN
            RETURN NEW;
        END IF;


        RAISE EXCEPTION
            'Un borrador solo puede guardarse como borrador o finalizarse mediante el procedimiento documental';

    END IF;


    -- --------------------------------------------------------
    -- 1.4. FACTURAS EMITIDAS
    -- --------------------------------------------------------
    --
    -- No se permite devolver una factura emitida a borrador.
    -- Tampoco se permiten modificaciones de facturas pagadas,
    -- vencidas o canceladas.
    -- --------------------------------------------------------

    IF OLD.estado IS DISTINCT FROM 'borrador' THEN

        IF NEW.estado = 'borrador'
           AND NOT v_create_draft
           AND NOT v_save_draft
        THEN
            RAISE EXCEPTION
                'Una factura emitida no puede volver a borrador';
        END IF;


        -- Transiciones internas de las RPC de borradores. Estas RPC
        -- verifican primero que el registro original sea borrador y que
        -- no tenga documento; el GUC es local a esta transacción.
        IF (v_create_draft OR v_save_draft)
           AND NEW.estado = 'borrador'
           AND NEW.document_path IS NULL
           AND NEW.document_sha256 IS NULL
        THEN
            RETURN NEW;
        END IF;

        IF v_content_changed THEN
            RAISE EXCEPTION
                'Una factura emitida no puede editarse. Debe corregirse mediante una factura rectificativa';
        END IF;

    END IF;


    RETURN NEW;

END;
$function$;

DROP TRIGGER IF EXISTS invoices_guard_draft_and_issued_changes ON public.invoices;
CREATE TRIGGER invoices_guard_draft_and_issued_changes
BEFORE UPDATE ON public.invoices
FOR EACH ROW
EXECUTE FUNCTION public.guard_invoice_draft_and_issued_changes();

-- Defensa adicional frente a DELETE directo por RLS: no se pueden borrar facturas emitidas.
CREATE OR REPLACE FUNCTION public.guard_invoice_delete_draft_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.estado IS DISTINCT FROM 'borrador'
       OR OLD.document_path IS NOT NULL
       OR OLD.document_sha256 IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Solo se pueden eliminar borradores sin documento oficial';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = OLD.id
    ) THEN
        RAISE EXCEPTION
            'No se puede eliminar una factura con aceptación documental';
    END IF;

    RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS invoices_guard_delete_draft_only ON public.invoices;
CREATE TRIGGER invoices_guard_delete_draft_only
BEFORE DELETE ON public.invoices
FOR EACH ROW
EXECUTE FUNCTION public.guard_invoice_delete_draft_only();

CREATE OR REPLACE FUNCTION "public"."delete_invoice_by_worker"("p_invoice_id" "uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_invoice public.invoices;
BEGIN

    PERFORM public.require_current_worker_permission(
        'invoices.delete'
    );

    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Factura no encontrada';
    END IF;

    IF v_invoice.estado IS DISTINCT FROM 'borrador'
       OR v_invoice.document_path IS NOT NULL
       OR v_invoice.document_sha256 IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Solo se pueden eliminar borradores sin documento oficial. Las facturas emitidas deben corregirse mediante una factura rectificativa';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = v_invoice.id
    ) THEN
        RAISE EXCEPTION
            'No se puede eliminar una factura con aceptación documental';
    END IF;

    IF v_invoice.document_path IS NOT NULL
       AND TRIM(v_invoice.document_path) <> ''
    THEN

        DELETE FROM storage.objects
        WHERE bucket_id = 'invoices'
          AND name = v_invoice.document_path;

    ELSE

        DELETE FROM storage.objects
        WHERE bucket_id = 'invoices'
          AND name = v_invoice.numero_factura || '.pdf';

    END IF;

    DELETE FROM public.invoices
    WHERE id = p_invoice_id
    RETURNING *
    INTO v_invoice;

    RETURN v_invoice;

END;
$$;

ALTER FUNCTION public.guard_invoice_delete_draft_only() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guard_invoice_delete_draft_only() FROM PUBLIC;

COMMIT;
