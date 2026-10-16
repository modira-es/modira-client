-- ============================================================
-- 072_invoice_fiscal_snapshot_on_create_update.sql
-- ============================================================
--
-- OBJETIVO
-- ------------------------------------------------------------
-- 1. Hacer que create_invoice_by_worker() genere automáticamente
--    el snapshot fiscal del emisor y del cliente.
--
-- 2. Hacer que update_invoice_by_worker() mantenga actualizado
--    el snapshot mientras la factura todavía sea editable.
--
-- 3. Asociar correctamente client_id al crear una factura,
--    utilizando el client_id del proyecto.
--
-- 4. Mantener todas las validaciones y permisos existentes.
--
-- 5. No modificar Stripe.
-- 6. No modificar pagos.
-- 7. No modificar acknowledgements.
-- 8. No modificar Storage.
--
-- IMPORTANTE
-- ------------------------------------------------------------
-- Las facturas antiguas NO se modifican.
-- El snapshot se genera para las nuevas facturas y para las
-- facturas todavía editables cuando se actualicen.
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- invoices
    -- --------------------------------------------------------

    IF to_regclass('public.invoices') IS NULL THEN
        RAISE EXCEPTION
            '072 stopped: public.invoices does not exist';
    END IF;


    -- --------------------------------------------------------
    -- companies
    -- --------------------------------------------------------

    IF to_regclass('public.companies') IS NULL THEN
        RAISE EXCEPTION
            '072 stopped: public.companies does not exist';
    END IF;


    -- --------------------------------------------------------
    -- clients
    -- --------------------------------------------------------

    IF to_regclass('public.clients') IS NULL THEN
        RAISE EXCEPTION
            '072 stopped: public.clients does not exist';
    END IF;


    -- --------------------------------------------------------
    -- projects
    -- --------------------------------------------------------

    IF to_regclass('public.projects') IS NULL THEN
        RAISE EXCEPTION
            '072 stopped: public.projects does not exist';
    END IF;


    -- --------------------------------------------------------
    -- create_invoice_by_worker()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'create_invoice_by_worker'
          AND pg_get_function_identity_arguments(p.oid)
              =
              'p_company_id uuid, p_project_id uuid, p_fecha_emision timestamp with time zone, p_fecha_vencimiento timestamp with time zone, p_descripcion text, p_subtotal numeric, p_iva_porcentaje numeric'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: create_invoice_by_worker() expected signature not found';

    END IF;


    -- --------------------------------------------------------
    -- update_invoice_by_worker()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'update_invoice_by_worker'
          AND pg_get_function_identity_arguments(p.oid)
              =
              'p_invoice_id uuid, p_company_id uuid, p_project_id uuid, p_fecha_emision timestamp with time zone, p_fecha_vencimiento timestamp with time zone, p_descripcion text, p_subtotal numeric, p_iva_aplicado boolean, p_iva_porcentaje numeric, p_irpf_aplicado boolean, p_irpf_porcentaje numeric, p_estado text'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: update_invoice_by_worker() expected signature not found';

    END IF;


    -- --------------------------------------------------------
    -- fiscal fields of companies
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'legal_name'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: companies.legal_name is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'cif_vat'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: companies.cif_vat is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'address'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: companies.address is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'postal_code'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: companies.postal_code is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'city'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: companies.city is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'province'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: companies.province is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'country'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: companies.country is missing';

    END IF;


    -- --------------------------------------------------------
    -- fiscal fields of clients
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'empresa'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: clients.empresa is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'nombre'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: clients.nombre is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'cif_vat'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: clients.cif_vat is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'direccion'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: clients.direccion is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'codigo_postal'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: clients.codigo_postal is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'ciudad'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: clients.ciudad is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'provincia'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: clients.provincia is missing';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'pais'
    ) THEN

        RAISE EXCEPTION
            '072 stopped: clients.pais is missing';

    END IF;


END $$;


-- ============================================================
-- 2. CREATE_INVOICE_BY_WORKER
-- ============================================================
--
-- Misma firma.
--
-- Se conserva toda la lógica existente:
--
--   - invoices.create
--   - company validation
--   - project validation
--   - company/project consistency
--   - project owner validation
--   - subtotal validation
--   - IVA validation
--   - due date validation
--   - amount calculation
--   - invoice number generation
--
-- Se añade:
--
--   - project.client_id
--   - client_id en invoice
--   - issuer fiscal snapshot
--   - customer fiscal snapshot
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_invoice_by_worker(
    p_company_id uuid,
    p_project_id uuid,
    p_fecha_emision timestamp with time zone DEFAULT NULL,
    p_fecha_vencimiento timestamp with time zone DEFAULT NULL,
    p_descripcion text DEFAULT NULL,
    p_subtotal numeric DEFAULT 0,
    p_iva_porcentaje numeric DEFAULT 21
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE

    v_invoice public.invoices;

    v_project_user_id UUID;
    v_project_client_id UUID;
    v_project_company_id UUID;

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
$function$;


-- ============================================================
-- 3. UPDATE_INVOICE_BY_WORKER
-- ============================================================
--
-- Se mantiene la firma y la lógica existente.
--
-- Se añade:
--
--   - snapshot fiscal del emisor
--   - snapshot fiscal del cliente
--
-- La función sigue permitiendo editar facturas que todavía
-- sean editables.
--
-- Si la factura ya fue aceptada:
--
--   071 -> trigger -> bloquea el UPDATE
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_invoice_by_worker(
    p_invoice_id uuid,
    p_company_id uuid,
    p_project_id uuid,
    p_fecha_emision timestamp with time zone DEFAULT NULL,
    p_fecha_vencimiento timestamp with time zone DEFAULT NULL,
    p_descripcion text DEFAULT NULL,
    p_subtotal numeric DEFAULT 0,
    p_iva_aplicado boolean DEFAULT true,
    p_iva_porcentaje numeric DEFAULT 21,
    p_irpf_aplicado boolean DEFAULT false,
    p_irpf_porcentaje numeric DEFAULT 0,
    p_estado text DEFAULT 'pendiente'
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE

    v_invoice public.invoices;

    v_project_user_id UUID;
    v_project_client_id UUID;
    v_project_company_id UUID;

    v_subtotal NUMERIC(12,2);
    v_iva_porcentaje NUMERIC(5,2);
    v_irpf_porcentaje NUMERIC(5,2);

    v_normalized_status TEXT;

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
        'invoices.update'
    );


    -- ========================================================
    -- 2. LOCK INVOICE
    -- ========================================================

    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id
    FOR UPDATE;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'Factura no encontrada';

    END IF;


    -- ========================================================
    -- 3. COMPANY
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
            'La empresa indicada no existe';

    END IF;


    -- ========================================================
    -- 4. PROJECT
    -- ========================================================

    IF p_project_id IS NULL THEN

        RAISE EXCEPTION
            'El proyecto es obligatorio';

    END IF;


    SELECT
        user_id,
        client_id,
        company_id
    INTO
        v_project_user_id,
        v_project_client_id,
        v_project_company_id
    FROM public.projects
    WHERE id = p_project_id;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'El proyecto indicado no existe';

    END IF;


    IF v_project_company_id IS DISTINCT FROM p_company_id THEN

        RAISE EXCEPTION
            'El proyecto no pertenece a la empresa seleccionada';

    END IF;


    -- ========================================================
    -- 5. CLIENT SNAPSHOT
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
    -- 6. SUBTOTAL
    -- ========================================================

    v_subtotal :=
        ROUND(
            COALESCE(
                p_subtotal,
                0
            ),
            2
        );


    IF v_subtotal < 0 THEN

        RAISE EXCEPTION
            'La base imponible no puede ser negativa';

    END IF;


    -- ========================================================
    -- 7. IVA
    -- ========================================================

    IF p_iva_aplicado IS NULL THEN

        p_iva_aplicado := TRUE;

    END IF;


    v_iva_porcentaje :=
        ROUND(
            COALESCE(
                p_iva_porcentaje,
                0
            ),
            2
        );


    IF p_iva_aplicado THEN

        IF v_iva_porcentaje < 0
           OR v_iva_porcentaje > 100
        THEN

            RAISE EXCEPTION
                'El porcentaje de IVA debe estar entre 0 y 100';

        END IF;

    ELSE

        v_iva_porcentaje := 0;

    END IF;


    -- ========================================================
    -- 8. IRPF
    -- ========================================================

    IF p_irpf_aplicado IS NULL THEN

        p_irpf_aplicado := FALSE;

    END IF;


    v_irpf_porcentaje :=
        ROUND(
            COALESCE(
                p_irpf_porcentaje,
                0
            ),
            2
        );


    IF p_irpf_aplicado THEN

        IF v_irpf_porcentaje <= 0
           OR v_irpf_porcentaje > 100
        THEN

            RAISE EXCEPTION
                'El porcentaje de IRPF debe ser mayor que 0 y menor o igual que 100';

        END IF;

    ELSE

        v_irpf_porcentaje := 0;

    END IF;


    -- ========================================================
    -- 9. STATUS
    -- ========================================================

    v_normalized_status :=
        LOWER(
            TRIM(
                COALESCE(
                    p_estado,
                    'pendiente'
                )
            )
        );


    IF v_normalized_status NOT IN (
        'pendiente',
        'pagada',
        'vencida',
        'cancelada'
    ) THEN

        RAISE EXCEPTION
            'Estado de factura no válido';

    END IF;


    -- ========================================================
    -- 10. UPDATE
    -- ========================================================

    UPDATE public.invoices
    SET

        user_id = v_project_user_id,

        company_id = p_company_id,

        project_id = p_project_id,

        client_id = v_project_client_id,

        fecha_emision =
            COALESCE(
                p_fecha_emision,
                fecha_emision
            ),

        fecha_vencimiento =
            p_fecha_vencimiento,

        descripcion =
            NULLIF(
                TRIM(
                    COALESCE(
                        p_descripcion,
                        ''
                    )
                ),
                ''
            ),

        subtotal =
            v_subtotal,

        iva_aplicado =
            p_iva_aplicado,

        iva_porcentaje =
            v_iva_porcentaje,

        irpf_aplicado =
            p_irpf_aplicado,

        irpf_porcentaje =
            v_irpf_porcentaje,

        estado =
            v_normalized_status,

        -- ----------------------------------------------------
        -- Fiscal snapshot — issuer
        -- ----------------------------------------------------

        issuer_legal_name =
            v_issuer_legal_name,

        issuer_tax_id =
            v_issuer_tax_id,

        issuer_address =
            v_issuer_address,

        issuer_postal_code =
            v_issuer_postal_code,

        issuer_city =
            v_issuer_city,

        issuer_province =
            v_issuer_province,

        issuer_country =
            v_issuer_country,

        -- ----------------------------------------------------
        -- Fiscal snapshot — customer
        -- ----------------------------------------------------

        customer_legal_name =
            v_customer_legal_name,

        customer_tax_id =
            v_customer_tax_id,

        customer_address =
            v_customer_address,

        customer_postal_code =
            v_customer_postal_code,

        customer_city =
            v_customer_city,

        customer_province =
            v_customer_province,

        customer_country =
            v_customer_country,

        customer_contact_name =
            v_customer_contact_name,

        updated_at =
            CURRENT_TIMESTAMP

    WHERE id = p_invoice_id

    RETURNING *
    INTO v_invoice;


    -- ========================================================
    -- 11. RETURN
    -- ========================================================

    RETURN v_invoice;


END;
$function$;


-- ============================================================
-- 4. PERMISOS
-- ============================================================
--
-- CREATE y UPDATE ya utilizan require_current_worker_permission.
--
-- Mantenemos explícitamente los permisos de ejecución existentes
-- para authenticated.
--
-- ============================================================

REVOKE ALL
ON FUNCTION public.create_invoice_by_worker(
    UUID,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    NUMERIC,
    NUMERIC
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION public.create_invoice_by_worker(
    UUID,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    NUMERIC,
    NUMERIC
)
TO authenticated;


REVOKE ALL
ON FUNCTION public.update_invoice_by_worker(
    UUID,
    UUID,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    TEXT
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION public.update_invoice_by_worker(
    UUID,
    UUID,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    TEXT
)
TO authenticated;


-- ============================================================
-- 5. SEARCH PATH
-- ============================================================

ALTER FUNCTION public.create_invoice_by_worker(
    UUID,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    NUMERIC,
    NUMERIC
)
SET search_path = public, pg_temp;


ALTER FUNCTION public.update_invoice_by_worker(
    UUID,
    UUID,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    TEXT
)
SET search_path = public, pg_temp;


-- ============================================================
-- 6. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN


    -- --------------------------------------------------------
    -- create_invoice_by_worker
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'create_invoice_by_worker'
      AND pg_get_function_identity_arguments(p.oid)
          =
          'p_company_id uuid, p_project_id uuid, p_fecha_emision timestamp with time zone, p_fecha_vencimiento timestamp with time zone, p_descripcion text, p_subtotal numeric, p_iva_porcentaje numeric';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '072 verification failed: create_invoice_by_worker() is missing or duplicated';

    END IF;


    -- --------------------------------------------------------
    -- update_invoice_by_worker
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'update_invoice_by_worker'
      AND pg_get_function_identity_arguments(p.oid)
          =
          'p_invoice_id uuid, p_company_id uuid, p_project_id uuid, p_fecha_emision timestamp with time zone, p_fecha_vencimiento timestamp with time zone, p_descripcion text, p_subtotal numeric, p_iva_aplicado boolean, p_iva_porcentaje numeric, p_irpf_aplicado boolean, p_irpf_porcentaje numeric, p_estado text';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '072 verification failed: update_invoice_by_worker() is missing or duplicated';

    END IF;


    -- --------------------------------------------------------
    -- Ambos deben seguir siendo SECURITY DEFINER
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'create_invoice_by_worker'
      AND p.prosecdef = TRUE;


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '072 verification failed: create_invoice_by_worker() must remain SECURITY DEFINER';

    END IF;


    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'update_invoice_by_worker'
      AND p.prosecdef = TRUE;


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '072 verification failed: update_invoice_by_worker() must remain SECURITY DEFINER';

    END IF;


    -- --------------------------------------------------------
    -- Snapshot columns
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'invoices'
      AND column_name IN (
          'issuer_legal_name',
          'issuer_tax_id',
          'issuer_address',
          'issuer_postal_code',
          'issuer_city',
          'issuer_province',
          'issuer_country',
          'customer_legal_name',
          'customer_tax_id',
          'customer_address',
          'customer_postal_code',
          'customer_city',
          'customer_province',
          'customer_country',
          'customer_contact_name'
      );


    IF v_count <> 15 THEN

        RAISE EXCEPTION
            '072 verification failed: expected 15 fiscal snapshot columns, found %',
            v_count;

    END IF;


    RAISE NOTICE
        '072 completed successfully: invoice creation and update now persist fiscal snapshots automatically.';

END $$;


COMMIT;