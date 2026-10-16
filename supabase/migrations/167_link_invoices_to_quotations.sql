-- Migration: vincular facturas con presupuestos de referencia
-- Añade p_quotation_id a create_invoice_by_worker y valida que
-- el presupuesto pertenezca a la misma empresa y proyecto.

BEGIN;

DROP FUNCTION IF EXISTS public.create_invoice_by_worker(
    uuid,
    uuid,
    timestamptz,
    timestamptz,
    text,
    numeric,
    numeric
);

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

    SELECT q.company_id, q.project_id
    INTO v_quotation_company_id, v_quotation_project_id
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


ALTER FUNCTION "public"."create_invoice_by_worker"("p_company_id" "uuid", "p_project_id" "uuid", "p_fecha_emision" timestamp with time zone, "p_fecha_vencimiento" timestamp with time zone, "p_descripcion" "text", "p_subtotal" numeric, "p_iva_porcentaje" numeric, "p_quotation_id" "uuid") OWNER TO "postgres";


REVOKE ALL ON FUNCTION public.create_invoice_by_worker(
    uuid,
    uuid,
    timestamptz,
    timestamptz,
    text,
    numeric,
    numeric,
    uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_invoice_by_worker(
    uuid,
    uuid,
    timestamptz,
    timestamptz,
    text,
    numeric,
    numeric,
    uuid
) TO authenticated;

COMMIT;
