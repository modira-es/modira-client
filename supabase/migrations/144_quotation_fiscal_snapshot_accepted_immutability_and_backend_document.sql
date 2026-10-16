-- ============================================================
-- 143 — QUOTATIONS: FISCAL SNAPSHOT + ACCEPTED IMMUTABILITY
--      + BACKEND DOCUMENT FINALIZATION
-- ============================================================
--
-- Additive migration. No modifica las migraciones anteriores.
--
-- 1. Añade snapshot fiscal del emisor y cliente a quotations.
-- 2. Mantiene la creación/edición exclusivamente mediante las
--    RPC de worker existentes, conservando quotations.create/update.
-- 3. Protege un presupuesto cuando ya existe acknowledgement del
--    PDF y, una vez Aceptado, mantiene su contenido congelado.
-- 4. Añade finalize_quotation_backend_document(), exclusiva de
--    service_role, para registrar de forma idempotente el PDF + SHA-256
--    generado por la Edge Function.
-- 5. Amplía la invalidación del documento para cualquier dato que
--    quede representado en el PDF, incluidos los snapshots fiscales.
-- 6. Rellena el snapshot de presupuestos históricos que todavía no
--    tienen aceptación documental y siguen siendo editables.
--
-- NO incluye rectificaciones: son específicas de facturas.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. SNAPSHOT FISCAL EN public.quotations
-- ============================================================

ALTER TABLE public.quotations
    ADD COLUMN IF NOT EXISTS issuer_legal_name TEXT,
    ADD COLUMN IF NOT EXISTS issuer_tax_id TEXT,
    ADD COLUMN IF NOT EXISTS issuer_address TEXT,
    ADD COLUMN IF NOT EXISTS issuer_postal_code TEXT,
    ADD COLUMN IF NOT EXISTS issuer_city TEXT,
    ADD COLUMN IF NOT EXISTS issuer_province TEXT,
    ADD COLUMN IF NOT EXISTS issuer_country TEXT,
    ADD COLUMN IF NOT EXISTS customer_legal_name TEXT,
    ADD COLUMN IF NOT EXISTS customer_tax_id TEXT,
    ADD COLUMN IF NOT EXISTS customer_address TEXT,
    ADD COLUMN IF NOT EXISTS customer_postal_code TEXT,
    ADD COLUMN IF NOT EXISTS customer_city TEXT,
    ADD COLUMN IF NOT EXISTS customer_province TEXT,
    ADD COLUMN IF NOT EXISTS customer_country TEXT,
    ADD COLUMN IF NOT EXISTS customer_contact_name TEXT;

COMMENT ON COLUMN public.quotations.issuer_legal_name IS
'Nombre/razón social del emisor congelado para el documento del presupuesto.';
COMMENT ON COLUMN public.quotations.issuer_tax_id IS
'NIF/CIF del emisor congelado para el documento del presupuesto.';
COMMENT ON COLUMN public.quotations.customer_legal_name IS
'Nombre/razón social del cliente congelado para el documento del presupuesto.';
COMMENT ON COLUMN public.quotations.customer_tax_id IS
'NIF/CIF del cliente congelado para el documento del presupuesto.';

-- ============================================================
-- 2. CREACIÓN COMO WORKER — MISMA FIRMA Y MISMO PERMISO
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_quotation_by_worker(p_company_id uuid, p_project_id uuid, p_titulo text, p_descripcion_detallada text, p_servicios_incluidos jsonb, p_iva_porcentaje numeric, p_irpf_aplicado boolean, p_irpf_porcentaje numeric, p_estado text, p_fecha_emision timestamp with time zone, p_fecha_validez timestamp with time zone, p_notas text)
 RETURNS quotations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_quotation public.quotations;
    v_project public.projects%ROWTYPE;

    v_title TEXT;
    v_description TEXT;
    v_notes TEXT;
    v_state TEXT;

    v_iva NUMERIC(5,2);
    v_irpf NUMERIC(5,2);
    v_irpf_applied BOOLEAN;

    v_subtotal NUMERIC(12,2);
    v_iva_importe NUMERIC(12,2);
    v_irpf_importe NUMERIC(12,2);
    v_total NUMERIC(12,2);

    v_service JSONB;
    v_service_description TEXT;
    v_quantity NUMERIC;
    v_price NUMERIC;

    v_fecha_emision TIMESTAMPTZ;
    v_fecha_validez TIMESTAMPTZ;
    -- --------------------------------------------------------
    -- Fiscal issuer snapshot
    -- --------------------------------------------------------
    v_issuer_legal_name TEXT;
    v_issuer_tax_id TEXT;
    v_issuer_address TEXT;
    v_issuer_postal_code TEXT;
    v_issuer_city TEXT;
    v_issuer_province TEXT;
    v_issuer_country TEXT;

    -- --------------------------------------------------------
    -- Fiscal customer snapshot
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

    PERFORM public.require_current_worker_permission(
        'quotations.create'
    );

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Acceso denegado';
    END IF;

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION
            'La empresa es obligatoria';
    END IF;

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto es obligatorio';
    END IF;

    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = p_project_id
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El proyecto seleccionado no existe';
    END IF;

    IF v_project.company_id IS NULL
       OR v_project.company_id <> p_company_id
    THEN
        RAISE EXCEPTION
            'El proyecto no pertenece a la empresa seleccionada';
    END IF;

    IF v_project.user_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto no tiene un usuario propietario válido';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM auth.users u
        WHERE u.id = v_project.user_id
    ) THEN
        RAISE EXCEPTION
            'El propietario del proyecto no existe';
    END IF;

    IF v_project.client_id IS NOT NULL
       AND NOT EXISTS (
            SELECT 1
            FROM public.clients c
            WHERE c.id = v_project.client_id
              AND c.company_id = v_project.company_id
       )
    THEN
        RAISE EXCEPTION
            'El cliente del proyecto no pertenece a la empresa';
    END IF;


    -- ========================================================
    -- FISCAL SNAPSHOT
    -- ========================================================
    --
    -- El presupuesto conserva una fotografía de los datos
    -- fiscales del emisor y del cliente usados para su documento.
    -- El cliente del proyecto puede ser NULL y, en ese caso,
    -- el snapshot del cliente permanece NULL.
    --
    -- ========================================================

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
    WHERE c.id = v_project.company_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La empresa del proyecto no existe';
    END IF;

    IF v_project.client_id IS NOT NULL THEN

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
        WHERE c.id = v_project.client_id
          AND c.company_id = v_project.company_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'El cliente del proyecto no existe o no pertenece a la empresa seleccionada';
        END IF;

    END IF;

    v_title := NULLIF(BTRIM(p_titulo), '');

    IF v_title IS NULL THEN
        RAISE EXCEPTION
            'El título del presupuesto es obligatorio';
    END IF;

    IF LENGTH(v_title) > 300 THEN
        RAISE EXCEPTION
            'El título no puede superar 300 caracteres';
    END IF;

    v_description :=
        NULLIF(
            BTRIM(
                COALESCE(
                    p_descripcion_detallada,
                    ''
                )
            ),
            ''
        );

    IF v_description IS NOT NULL
       AND LENGTH(v_description) > 10000
    THEN
        RAISE EXCEPTION
            'La descripción del presupuesto no puede superar 10000 caracteres';
    END IF;

    v_notes :=
        NULLIF(
            BTRIM(
                COALESCE(
                    p_notas,
                    ''
                )
            ),
            ''
        );

    IF v_notes IS NOT NULL
       AND LENGTH(v_notes) > 10000
    THEN
        RAISE EXCEPTION
            'Las notas del presupuesto no pueden superar 10000 caracteres';
    END IF;

    v_state :=
        INITCAP(
            LOWER(
                BTRIM(
                    COALESCE(
                        p_estado,
                        'Pendiente'
                    )
                )
            )
        );

    IF v_state NOT IN (
        'Pendiente',
        'Aceptado',
        'Rechazado'
    ) THEN
        RAISE EXCEPTION
            'Estado de presupuesto no válido';
    END IF;

    v_iva :=
        ROUND(
            COALESCE(
                p_iva_porcentaje,
                0
            ),
            2
        );

    IF v_iva < 0 OR v_iva > 100 THEN
        RAISE EXCEPTION
            'El porcentaje de IVA debe estar entre 0 y 100';
    END IF;

    v_irpf_applied :=
        COALESCE(
            p_irpf_aplicado,
            FALSE
        );

    v_irpf :=
        ROUND(
            COALESCE(
                p_irpf_porcentaje,
                0
            ),
            2
        );

    IF NOT v_irpf_applied THEN

        IF v_irpf <> 0 THEN
            RAISE EXCEPTION
                'Si el IRPF no se aplica, el porcentaje debe ser 0';
        END IF;

        v_irpf := 0;

    ELSE

        IF v_irpf <= 0 OR v_irpf > 100 THEN
            RAISE EXCEPTION
                'El porcentaje de IRPF debe ser mayor que 0 y menor o igual que 100';
        END IF;

    END IF;

    IF p_servicios_incluidos IS NULL
       OR jsonb_typeof(p_servicios_incluidos) <> 'array'
    THEN
        RAISE EXCEPTION
            'Los servicios incluidos deben ser un array JSON';
    END IF;

    IF jsonb_array_length(p_servicios_incluidos) = 0 THEN
        RAISE EXCEPTION
            'Debe existir al menos un servicio';
    END IF;

    IF jsonb_array_length(p_servicios_incluidos) > 100 THEN
        RAISE EXCEPTION
            'El presupuesto no puede contener más de 100 servicios';
    END IF;

    v_subtotal := 0;

    FOR v_service IN
        SELECT value
        FROM jsonb_array_elements(
            p_servicios_incluidos
        )
    LOOP

        IF jsonb_typeof(v_service) <> 'object' THEN
            RAISE EXCEPTION
                'Cada servicio debe ser un objeto JSON';
        END IF;

        v_service_description :=
            NULLIF(
                BTRIM(
                    COALESCE(
                        v_service->>'descripcion',
                        ''
                    )
                ),
                ''
            );

        IF v_service_description IS NULL THEN
            RAISE EXCEPTION
                'Todos los servicios deben tener una descripción';
        END IF;

        IF LENGTH(v_service_description) > 2000 THEN
            RAISE EXCEPTION
                'La descripción de un servicio no puede superar 2000 caracteres';
        END IF;

        IF NOT (v_service ? 'cantidad')
           OR NOT (v_service ? 'precio')
        THEN
            RAISE EXCEPTION
                'Cada servicio debe contener cantidad y precio';
        END IF;

        BEGIN
            v_quantity :=
                (v_service->>'cantidad')::NUMERIC;

            v_price :=
                (v_service->>'precio')::NUMERIC;

        EXCEPTION
            WHEN invalid_text_representation
              OR numeric_value_out_of_range
        THEN
            RAISE EXCEPTION
                'Cantidad o precio de servicio no válidos';
        END;

        IF v_quantity IS NULL
           OR v_quantity <= 0
           OR v_quantity > 1000000
        THEN
            RAISE EXCEPTION
                'La cantidad de un servicio debe ser mayor que 0';
        END IF;

        IF v_price IS NULL
           OR v_price < 0
           OR v_price > 100000000
        THEN
            RAISE EXCEPTION
                'El precio de un servicio no puede ser negativo';
        END IF;

        v_subtotal :=
            v_subtotal
            + ROUND(
                v_quantity * v_price,
                2
            );

        IF v_subtotal > 1000000000 THEN
            RAISE EXCEPTION
                'El importe total del presupuesto supera el límite permitido';
        END IF;

    END LOOP;

    v_subtotal :=
        ROUND(
            v_subtotal,
            2
        );

    v_iva_importe :=
        ROUND(
            v_subtotal * (v_iva / 100),
            2
        );

    IF v_irpf_applied THEN
        v_irpf_importe :=
            ROUND(
                v_subtotal * (v_irpf / 100),
                2
            );
    ELSE
        v_irpf_importe := 0;
    END IF;

    v_total :=
        ROUND(
            v_subtotal
            + v_iva_importe
            - v_irpf_importe,
            2
        );

    IF v_total < 0 THEN
        RAISE EXCEPTION
            'El total del presupuesto no puede ser negativo';
    END IF;

    v_fecha_emision :=
        COALESCE(
            p_fecha_emision,
            CURRENT_TIMESTAMP
        );

    v_fecha_validez :=
        p_fecha_validez;

    INSERT INTO public.quotations (
        company_id,
        user_id,
        project_id,
        client_id,
        titulo,
        descripcion_detallada,
        servicios_incluidos,
        precio_base,
        iva_porcentaje,
        precio_total,
        irpf_aplicado,
        irpf_porcentaje,
        irpf_importe,
        estado,
        fecha_emision,
        fecha_validez,
        notas,

        issuer_legal_name,
        issuer_tax_id,
        issuer_address,
        issuer_postal_code,
        issuer_city,
        issuer_province,
        issuer_country,

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
        v_project.company_id,
        v_project.user_id,
        v_project.id,
        v_project.client_id,
        v_title,
        v_description,
        p_servicios_incluidos,
        v_subtotal,
        v_iva,
        v_total,
        v_irpf_applied,
        v_irpf,
        v_irpf_importe,
        v_state,
        v_fecha_emision,
        v_fecha_validez,
        v_notes,

        v_issuer_legal_name,
        v_issuer_tax_id,
        v_issuer_address,
        v_issuer_postal_code,
        v_issuer_city,
        v_issuer_province,
        v_issuer_country,

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
    INTO v_quotation;

    RETURN v_quotation;

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION
            'No se pudo generar el presupuesto por un conflicto de unicidad';
END;
$function$

;

REVOKE ALL ON FUNCTION public.create_quotation_by_worker(
    UUID, UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN, NUMERIC, TEXT,
    TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_quotation_by_worker(
    UUID, UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN, NUMERIC, TEXT,
    TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) TO authenticated;

ALTER FUNCTION public.create_quotation_by_worker(
    UUID, UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN, NUMERIC, TEXT,
    TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) SET search_path = public, pg_temp;

-- ============================================================
-- 3. EDICIÓN COMO WORKER — MISMA FIRMA Y MISMO PERMISO
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_quotation_by_worker(p_quotation_id uuid, p_project_id uuid, p_titulo text, p_descripcion_detallada text, p_servicios_incluidos jsonb, p_iva_porcentaje numeric, p_irpf_aplicado boolean, p_irpf_porcentaje numeric, p_estado text, p_fecha_emision timestamp with time zone, p_fecha_validez timestamp with time zone, p_notas text)
 RETURNS quotations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_quotation public.quotations;
    v_project public.projects%ROWTYPE;

    v_title TEXT;
    v_description TEXT;
    v_notes TEXT;
    v_state TEXT;

    v_iva NUMERIC(5,2);
    v_irpf NUMERIC(5,2);
    v_irpf_applied BOOLEAN;

    v_subtotal NUMERIC(12,2);
    v_iva_importe NUMERIC(12,2);
    v_irpf_importe NUMERIC(12,2);
    v_total NUMERIC(12,2);

    v_service JSONB;
    v_service_description TEXT;
    v_quantity NUMERIC;
    v_price NUMERIC;

    v_fecha_emision TIMESTAMPTZ;
    -- --------------------------------------------------------
    -- Fiscal issuer snapshot
    -- --------------------------------------------------------
    v_issuer_legal_name TEXT;
    v_issuer_tax_id TEXT;
    v_issuer_address TEXT;
    v_issuer_postal_code TEXT;
    v_issuer_city TEXT;
    v_issuer_province TEXT;
    v_issuer_country TEXT;

    -- --------------------------------------------------------
    -- Fiscal customer snapshot
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

    PERFORM public.require_current_worker_permission(
        'quotations.update'
    );

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Presupuesto no encontrado';
    END IF;

    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = p_project_id
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El proyecto seleccionado no existe';
    END IF;

    IF v_project.company_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto seleccionado no tiene empresa';
    END IF;

    IF v_project.user_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto seleccionado no tiene un usuario propietario válido';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM auth.users u
        WHERE u.id = v_project.user_id
    ) THEN
        RAISE EXCEPTION
            'El propietario del proyecto no existe';
    END IF;

    IF v_project.client_id IS NOT NULL
       AND NOT EXISTS (
            SELECT 1
            FROM public.clients c
            WHERE c.id = v_project.client_id
              AND c.company_id = v_project.company_id
       )
    THEN
        RAISE EXCEPTION
            'El cliente del proyecto no pertenece a la empresa';
    END IF;


    -- ========================================================
    -- FISCAL SNAPSHOT
    -- ========================================================
    --
    -- El presupuesto conserva una fotografía de los datos
    -- fiscales del emisor y del cliente usados para su documento.
    -- El cliente del proyecto puede ser NULL y, en ese caso,
    -- el snapshot del cliente permanece NULL.
    --
    -- ========================================================

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
    WHERE c.id = v_project.company_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La empresa del proyecto no existe';
    END IF;

    IF v_project.client_id IS NOT NULL THEN

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
        WHERE c.id = v_project.client_id
          AND c.company_id = v_project.company_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'El cliente del proyecto no existe o no pertenece a la empresa seleccionada';
        END IF;

    END IF;

    v_title :=
        NULLIF(
            BTRIM(p_titulo),
            ''
        );

    IF v_title IS NULL THEN
        RAISE EXCEPTION
            'El título del presupuesto es obligatorio';
    END IF;

    IF LENGTH(v_title) > 300 THEN
        RAISE EXCEPTION
            'El título no puede superar 300 caracteres';
    END IF;

    v_description :=
        NULLIF(
            BTRIM(
                COALESCE(
                    p_descripcion_detallada,
                    ''
                )
            ),
            ''
        );

    IF v_description IS NOT NULL
       AND LENGTH(v_description) > 10000
    THEN
        RAISE EXCEPTION
            'La descripción del presupuesto no puede superar 10000 caracteres';
    END IF;

    v_notes :=
        NULLIF(
            BTRIM(
                COALESCE(
                    p_notas,
                    ''
                )
            ),
            ''
        );

    IF v_notes IS NOT NULL
       AND LENGTH(v_notes) > 10000
    THEN
        RAISE EXCEPTION
            'Las notas del presupuesto no pueden superar 10000 caracteres';
    END IF;

    v_state :=
        INITCAP(
            LOWER(
                BTRIM(
                    COALESCE(
                        p_estado,
                        'Pendiente'
                    )
                )
            )
        );

    IF v_state NOT IN (
        'Pendiente',
        'Aceptado',
        'Rechazado'
    ) THEN
        RAISE EXCEPTION
            'Estado de presupuesto no válido';
    END IF;

    v_iva :=
        ROUND(
            COALESCE(
                p_iva_porcentaje,
                0
            ),
            2
        );

    IF v_iva < 0 OR v_iva > 100 THEN
        RAISE EXCEPTION
            'El porcentaje de IVA debe estar entre 0 y 100';
    END IF;

    v_irpf_applied :=
        COALESCE(
            p_irpf_aplicado,
            FALSE
        );

    v_irpf :=
        ROUND(
            COALESCE(
                p_irpf_porcentaje,
                0
            ),
            2
        );

    IF NOT v_irpf_applied THEN

        IF v_irpf <> 0 THEN
            RAISE EXCEPTION
                'Si el IRPF no se aplica, el porcentaje debe ser 0';
        END IF;

        v_irpf := 0;

    ELSE

        IF v_irpf <= 0 OR v_irpf > 100 THEN
            RAISE EXCEPTION
                'El porcentaje de IRPF debe ser mayor que 0 y menor o igual que 100';
        END IF;

    END IF;

    IF p_servicios_incluidos IS NULL
       OR jsonb_typeof(p_servicios_incluidos) <> 'array'
    THEN
        RAISE EXCEPTION
            'Los servicios incluidos deben ser un array JSON';
    END IF;

    IF jsonb_array_length(p_servicios_incluidos) = 0 THEN
        RAISE EXCEPTION
            'Debe existir al menos un servicio';
    END IF;

    IF jsonb_array_length(p_servicios_incluidos) > 100 THEN
        RAISE EXCEPTION
            'El presupuesto no puede contener más de 100 servicios';
    END IF;

    v_subtotal := 0;

    FOR v_service IN
        SELECT value
        FROM jsonb_array_elements(
            p_servicios_incluidos
        )
    LOOP

        IF jsonb_typeof(v_service) <> 'object' THEN
            RAISE EXCEPTION
                'Cada servicio debe ser un objeto JSON';
        END IF;

        v_service_description :=
            NULLIF(
                BTRIM(
                    COALESCE(
                        v_service->>'descripcion',
                        ''
                    )
                ),
                ''
            );

        IF v_service_description IS NULL THEN
            RAISE EXCEPTION
                'Todos los servicios deben tener una descripción';
        END IF;

        IF LENGTH(v_service_description) > 2000 THEN
            RAISE EXCEPTION
                'La descripción de un servicio no puede superar 2000 caracteres';
        END IF;

        IF NOT (v_service ? 'cantidad')
           OR NOT (v_service ? 'precio')
        THEN
            RAISE EXCEPTION
                'Cada servicio debe contener cantidad y precio';
        END IF;

        BEGIN

            v_quantity :=
                (v_service->>'cantidad')::NUMERIC;

            v_price :=
                (v_service->>'precio')::NUMERIC;

        EXCEPTION
            WHEN invalid_text_representation
              OR numeric_value_out_of_range
        THEN
            RAISE EXCEPTION
                'Cantidad o precio de servicio no válidos';
        END;

        IF v_quantity IS NULL
           OR v_quantity <= 0
           OR v_quantity > 1000000
        THEN
            RAISE EXCEPTION
                'La cantidad de un servicio debe ser mayor que 0';
        END IF;

        IF v_price IS NULL
           OR v_price < 0
           OR v_price > 100000000
        THEN
            RAISE EXCEPTION
                'El precio de un servicio no puede ser negativo';
        END IF;

        v_subtotal :=
            v_subtotal
            + ROUND(
                v_quantity * v_price,
                2
            );

        IF v_subtotal > 1000000000 THEN
            RAISE EXCEPTION
                'El importe total del presupuesto supera el límite permitido';
        END IF;

    END LOOP;

    v_subtotal :=
        ROUND(
            v_subtotal,
            2
        );

    v_iva_importe :=
        ROUND(
            v_subtotal * (v_iva / 100),
            2
        );

    IF v_irpf_applied THEN
        v_irpf_importe :=
            ROUND(
                v_subtotal * (v_irpf / 100),
                2
            );
    ELSE
        v_irpf_importe := 0;
    END IF;

    v_total :=
        ROUND(
            v_subtotal
            + v_iva_importe
            - v_irpf_importe,
            2
        );

    IF v_total < 0 THEN
        RAISE EXCEPTION
            'El total del presupuesto no puede ser negativo';
    END IF;

    v_fecha_emision :=
        COALESCE(
            p_fecha_emision,
            v_quotation.fecha_emision
        );

    UPDATE public.quotations
    SET
        company_id = v_project.company_id,
        user_id = v_project.user_id,
        project_id = v_project.id,
        client_id = v_project.client_id,
        titulo = v_title,
        descripcion_detallada = v_description,
        servicios_incluidos = p_servicios_incluidos,
        precio_base = v_subtotal,
        iva_porcentaje = v_iva,
        precio_total = v_total,
        irpf_aplicado = v_irpf_applied,
        irpf_porcentaje = v_irpf,
        irpf_importe = v_irpf_importe,
        estado = v_state,
        fecha_emision = v_fecha_emision,
        fecha_validez = p_fecha_validez,
        notas = v_notes,

        issuer_legal_name = v_issuer_legal_name,
        issuer_tax_id = v_issuer_tax_id,
        issuer_address = v_issuer_address,
        issuer_postal_code = v_issuer_postal_code,
        issuer_city = v_issuer_city,
        issuer_province = v_issuer_province,
        issuer_country = v_issuer_country,

        customer_legal_name = v_customer_legal_name,
        customer_tax_id = v_customer_tax_id,
        customer_address = v_customer_address,
        customer_postal_code = v_customer_postal_code,
        customer_city = v_customer_city,
        customer_province = v_customer_province,
        customer_country = v_customer_country,
        customer_contact_name = v_customer_contact_name,

        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_quotation_id
    RETURNING *
    INTO v_quotation;

    RETURN v_quotation;

END;
$function$

;

REVOKE ALL ON FUNCTION public.update_quotation_by_worker(
    UUID, UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN, NUMERIC, TEXT,
    TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.update_quotation_by_worker(
    UUID, UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN, NUMERIC, TEXT,
    TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) TO authenticated;

ALTER FUNCTION public.update_quotation_by_worker(
    UUID, UUID, TEXT, TEXT, JSONB, NUMERIC, BOOLEAN, NUMERIC, TEXT,
    TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) SET search_path = public, pg_temp;

-- ============================================================
-- 4. PROTECCIÓN DE DATOS CON ACKNOWLEDGEMENT / ACEPTACIÓN
-- ============================================================
--
-- La RPC respond_to_quotation() hace:
--   acknowledgement -> quotation_acceptances -> estado Aceptado.
--
-- Por ello se permite exclusivamente la transición Pendiente ->
-- Aceptado cuando todos los demás campos protegidos permanecen iguales.
-- Después de estar Aceptado, version_quotation_before_update() ya
-- impide cualquier modificación del presupuesto.
--
-- Además, si existe acknowledgement mientras el presupuesto sigue
-- Pendiente, no se permite cambiar el contenido del PDF ya leído.
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_accepted_quotation_data()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_has_ack BOOLEAN := FALSE;
BEGIN

    SELECT EXISTS (
        SELECT 1
        FROM public.quotation_document_acknowledgements a
        WHERE a.quotation_id = OLD.id
    )
    INTO v_has_ack;

    IF v_has_ack THEN

        -- La única modificación permitida después del acknowledgement
        -- antes de la aceptación contractual es Pendiente -> Aceptado,
        -- sin tocar ningún dato representado en el PDF.
        IF NOT (
            LOWER(TRIM(COALESCE(OLD.estado, ''))) = 'pendiente'
            AND LOWER(TRIM(COALESCE(NEW.estado, ''))) = 'aceptado'
        ) THEN
            IF NEW.company_id IS DISTINCT FROM OLD.company_id
               OR NEW.user_id IS DISTINCT FROM OLD.user_id
               OR NEW.project_id IS DISTINCT FROM OLD.project_id
               OR NEW.client_id IS DISTINCT FROM OLD.client_id
               OR NEW.numero_presupuesto IS DISTINCT FROM OLD.numero_presupuesto
               OR NEW.titulo IS DISTINCT FROM OLD.titulo
               OR NEW.descripcion_detallada IS DISTINCT FROM OLD.descripcion_detallada
               OR NEW.servicios_incluidos IS DISTINCT FROM OLD.servicios_incluidos
               OR NEW.precio_base IS DISTINCT FROM OLD.precio_base
               OR NEW.iva_porcentaje IS DISTINCT FROM OLD.iva_porcentaje
               OR NEW.precio_total IS DISTINCT FROM OLD.precio_total
               OR NEW.irpf_aplicado IS DISTINCT FROM OLD.irpf_aplicado
               OR NEW.irpf_porcentaje IS DISTINCT FROM OLD.irpf_porcentaje
               OR NEW.irpf_importe IS DISTINCT FROM OLD.irpf_importe
               OR NEW.estado IS DISTINCT FROM OLD.estado
               OR NEW.fecha_emision IS DISTINCT FROM OLD.fecha_emision
               OR NEW.fecha_validez IS DISTINCT FROM OLD.fecha_validez
               OR NEW.notas IS DISTINCT FROM OLD.notas
               OR NEW.issuer_legal_name IS DISTINCT FROM OLD.issuer_legal_name
               OR NEW.issuer_tax_id IS DISTINCT FROM OLD.issuer_tax_id
               OR NEW.issuer_address IS DISTINCT FROM OLD.issuer_address
               OR NEW.issuer_postal_code IS DISTINCT FROM OLD.issuer_postal_code
               OR NEW.issuer_city IS DISTINCT FROM OLD.issuer_city
               OR NEW.issuer_province IS DISTINCT FROM OLD.issuer_province
               OR NEW.issuer_country IS DISTINCT FROM OLD.issuer_country
               OR NEW.customer_legal_name IS DISTINCT FROM OLD.customer_legal_name
               OR NEW.customer_tax_id IS DISTINCT FROM OLD.customer_tax_id
               OR NEW.customer_address IS DISTINCT FROM OLD.customer_address
               OR NEW.customer_postal_code IS DISTINCT FROM OLD.customer_postal_code
               OR NEW.customer_city IS DISTINCT FROM OLD.customer_city
               OR NEW.customer_province IS DISTINCT FROM OLD.customer_province
               OR NEW.customer_country IS DISTINCT FROM OLD.customer_country
               OR NEW.customer_contact_name IS DISTINCT FROM OLD.customer_contact_name
               OR NEW.document_path IS DISTINCT FROM OLD.document_path
               OR NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256
            THEN
                RAISE EXCEPTION
                    'El presupuesto está bloqueado porque el cliente ya ha aceptado su documento';
            END IF;
        ELSE
            -- Pendiente -> Aceptado: todo salvo estado debe permanecer idéntico.
            IF NEW.company_id IS DISTINCT FROM OLD.company_id
               OR NEW.user_id IS DISTINCT FROM OLD.user_id
               OR NEW.project_id IS DISTINCT FROM OLD.project_id
               OR NEW.client_id IS DISTINCT FROM OLD.client_id
               OR NEW.numero_presupuesto IS DISTINCT FROM OLD.numero_presupuesto
               OR NEW.titulo IS DISTINCT FROM OLD.titulo
               OR NEW.descripcion_detallada IS DISTINCT FROM OLD.descripcion_detallada
               OR NEW.servicios_incluidos IS DISTINCT FROM OLD.servicios_incluidos
               OR NEW.precio_base IS DISTINCT FROM OLD.precio_base
               OR NEW.iva_porcentaje IS DISTINCT FROM OLD.iva_porcentaje
               OR NEW.precio_total IS DISTINCT FROM OLD.precio_total
               OR NEW.irpf_aplicado IS DISTINCT FROM OLD.irpf_aplicado
               OR NEW.irpf_porcentaje IS DISTINCT FROM OLD.irpf_porcentaje
               OR NEW.irpf_importe IS DISTINCT FROM OLD.irpf_importe
               OR NEW.fecha_emision IS DISTINCT FROM OLD.fecha_emision
               OR NEW.fecha_validez IS DISTINCT FROM OLD.fecha_validez
               OR NEW.notas IS DISTINCT FROM OLD.notas
               OR NEW.issuer_legal_name IS DISTINCT FROM OLD.issuer_legal_name
               OR NEW.issuer_tax_id IS DISTINCT FROM OLD.issuer_tax_id
               OR NEW.issuer_address IS DISTINCT FROM OLD.issuer_address
               OR NEW.issuer_postal_code IS DISTINCT FROM OLD.issuer_postal_code
               OR NEW.issuer_city IS DISTINCT FROM OLD.issuer_city
               OR NEW.issuer_province IS DISTINCT FROM OLD.issuer_province
               OR NEW.issuer_country IS DISTINCT FROM OLD.issuer_country
               OR NEW.customer_legal_name IS DISTINCT FROM OLD.customer_legal_name
               OR NEW.customer_tax_id IS DISTINCT FROM OLD.customer_tax_id
               OR NEW.customer_address IS DISTINCT FROM OLD.customer_address
               OR NEW.customer_postal_code IS DISTINCT FROM OLD.customer_postal_code
               OR NEW.customer_city IS DISTINCT FROM OLD.customer_city
               OR NEW.customer_province IS DISTINCT FROM OLD.customer_province
               OR NEW.customer_country IS DISTINCT FROM OLD.customer_country
               OR NEW.customer_contact_name IS DISTINCT FROM OLD.customer_contact_name
               OR NEW.document_path IS DISTINCT FROM OLD.document_path
               OR NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256
            THEN
                RAISE EXCEPTION
                    'No se puede aceptar el presupuesto modificando el documento o sus datos';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS quotations_protect_accepted_data
ON public.quotations;

CREATE TRIGGER quotations_protect_accepted_data
BEFORE UPDATE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.protect_accepted_quotation_data();

REVOKE ALL
ON FUNCTION public.protect_accepted_quotation_data()
FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.protect_accepted_quotation_data()
IS 'Protege los datos y el documento de un presupuesto cuando existe acknowledgement. Permite únicamente Pendiente -> Aceptado sin cambiar el contenido del documento.';

-- ============================================================
-- 5. FINALIZACIÓN BACKEND DEL PDF + SHA-256
-- ============================================================

CREATE OR REPLACE FUNCTION public.finalize_quotation_backend_document(
    p_quotation_id UUID,
    p_document_path TEXT,
    p_document_sha256 TEXT
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_quotation public.quotations;
    v_hash TEXT;
    v_expected_path TEXT;
BEGIN

    IF p_quotation_id IS NULL THEN
        RAISE EXCEPTION 'El presupuesto es obligatorio';
    END IF;

    IF p_document_path IS NULL OR TRIM(p_document_path) = '' THEN
        RAISE EXCEPTION 'La ruta del documento es obligatoria';
    END IF;

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El presupuesto no existe';
    END IF;

    v_expected_path :=
        v_quotation.company_id::TEXT
        || '/'
        || v_quotation.numero_presupuesto
        || '.pdf';

    IF TRIM(p_document_path) <> v_expected_path THEN
        RAISE EXCEPTION 'La ruta del documento no coincide con el presupuesto';
    END IF;

    IF LOWER(TRIM(p_document_path)) NOT LIKE '%.pdf' THEN
        RAISE EXCEPTION 'El documento debe ser un PDF';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'quotations'
          AND name = TRIM(p_document_path)
    ) THEN
        RAISE EXCEPTION 'El PDF no existe en el bucket de presupuestos';
    END IF;

    v_hash := LOWER(TRIM(COALESCE(p_document_sha256, '')));

    IF v_hash = '' THEN
        RAISE EXCEPTION 'El SHA-256 del documento es obligatorio';
    END IF;

    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'El SHA-256 del documento no es válido';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.quotation_document_acknowledgements a
        WHERE a.quotation_id = v_quotation.id
    ) THEN
        RAISE EXCEPTION
            'El documento de este presupuesto ya ha sido aceptado y no puede modificarse';
    END IF;

    IF v_quotation.document_path = TRIM(p_document_path)
       AND LOWER(COALESCE(v_quotation.document_sha256, '')) = v_hash
    THEN
        RETURN v_quotation;
    END IF;

    IF v_quotation.document_path IS NOT NULL
       AND TRIM(v_quotation.document_path) <> ''
       AND v_quotation.document_path IS DISTINCT FROM TRIM(p_document_path)
    THEN
        RAISE EXCEPTION 'El presupuesto ya tiene asociado otro documento';
    END IF;

    IF v_quotation.document_sha256 IS NOT NULL
       AND LOWER(TRIM(v_quotation.document_sha256)) IS DISTINCT FROM v_hash
    THEN
        RAISE EXCEPTION 'El presupuesto ya tiene asociado otro SHA-256';
    END IF;

    UPDATE public.quotations
    SET
        document_path = TRIM(p_document_path),
        document_sha256 = v_hash,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_quotation.id
    RETURNING *
    INTO v_quotation;

    IF v_quotation.id IS NULL THEN
        RAISE EXCEPTION 'No se ha podido finalizar el documento del presupuesto';
    END IF;

    RETURN v_quotation;
END;
$function$;

REVOKE ALL
ON FUNCTION public.finalize_quotation_backend_document(UUID, TEXT, TEXT)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.finalize_quotation_backend_document(UUID, TEXT, TEXT)
TO service_role;

COMMENT ON FUNCTION public.finalize_quotation_backend_document(UUID, TEXT, TEXT)
IS 'Registra de forma idempotente el PDF oficial generado server-side para un presupuesto y su SHA-256. Exclusivo para service_role.';

-- ============================================================
-- 6. INVALIDACIÓN DEL PDF CUANDO CAMBIA SU CONTENIDO
-- ============================================================

CREATE OR REPLACE FUNCTION public.invalidate_quotation_document_on_content_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
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
       OR OLD.estado IS DISTINCT FROM NEW.estado
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
$function$;

DROP TRIGGER IF EXISTS quotations_invalidate_document_on_content_change
ON public.quotations;

CREATE TRIGGER quotations_invalidate_document_on_content_change
BEFORE UPDATE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.invalidate_quotation_document_on_content_change();

COMMENT ON FUNCTION public.invalidate_quotation_document_on_content_change()
IS 'Invalida document_path y document_sha256 cuando cambia cualquier dato representado en el PDF oficial de un presupuesto, incluidos los snapshots fiscales.';

-- ============================================================
-- 7. BACKFILL DE SNAPSHOT PARA PRESUPUESTOS EDITABLES
-- ============================================================
--
-- No tocamos presupuestos con acknowledgement documental ni
-- presupuestos ya Aceptados, porque su contenido contractual debe
-- permanecer congelado.
--
-- Se utilizan subconsultas correlacionadas en lugar de un JOIN
-- sobre el alias del UPDATE, evitando referencias inválidas al
-- alias de quotations dentro del FROM/JOIN.
-- ============================================================

UPDATE public.quotations AS q
SET
    issuer_legal_name = (
        SELECT COALESCE(
            NULLIF(TRIM(c.legal_name), ''),
            NULLIF(TRIM(c.company_name), '')
        )
        FROM public.companies AS c
        WHERE c.id = q.company_id
    ),
    issuer_tax_id = (
        SELECT NULLIF(TRIM(c.cif_vat), '')
        FROM public.companies AS c
        WHERE c.id = q.company_id
    ),
    issuer_address = (
        SELECT NULLIF(TRIM(c.address), '')
        FROM public.companies AS c
        WHERE c.id = q.company_id
    ),
    issuer_postal_code = (
        SELECT NULLIF(TRIM(c.postal_code), '')
        FROM public.companies AS c
        WHERE c.id = q.company_id
    ),
    issuer_city = (
        SELECT NULLIF(TRIM(c.city), '')
        FROM public.companies AS c
        WHERE c.id = q.company_id
    ),
    issuer_province = (
        SELECT NULLIF(TRIM(c.province), '')
        FROM public.companies AS c
        WHERE c.id = q.company_id
    ),
    issuer_country = (
        SELECT COALESCE(NULLIF(TRIM(c.country), ''), 'ES')
        FROM public.companies AS c
        WHERE c.id = q.company_id
    ),
    customer_legal_name = (
        SELECT CASE
            WHEN cl.id IS NULL THEN NULL
            ELSE COALESCE(
                NULLIF(TRIM(cl.empresa), ''),
                NULLIF(TRIM(cl.nombre), '')
            )
        END
        FROM public.clients AS cl
        WHERE cl.id = q.client_id
    ),
    customer_tax_id = (
        SELECT NULLIF(TRIM(cl.cif_vat), '')
        FROM public.clients AS cl
        WHERE cl.id = q.client_id
    ),
    customer_address = (
        SELECT NULLIF(TRIM(cl.direccion), '')
        FROM public.clients AS cl
        WHERE cl.id = q.client_id
    ),
    customer_postal_code = (
        SELECT NULLIF(TRIM(cl.codigo_postal), '')
        FROM public.clients AS cl
        WHERE cl.id = q.client_id
    ),
    customer_city = (
        SELECT NULLIF(TRIM(cl.ciudad), '')
        FROM public.clients AS cl
        WHERE cl.id = q.client_id
    ),
    customer_province = (
        SELECT NULLIF(TRIM(cl.provincia), '')
        FROM public.clients AS cl
        WHERE cl.id = q.client_id
    ),
    customer_country = (
        SELECT COALESCE(NULLIF(TRIM(cl.pais), ''), 'ES')
        FROM public.clients AS cl
        WHERE cl.id = q.client_id
    ),
    customer_contact_name = (
        SELECT NULLIF(TRIM(cl.nombre), '')
        FROM public.clients AS cl
        WHERE cl.id = q.client_id
    ),
    updated_at = CURRENT_TIMESTAMP
WHERE q.estado <> 'Aceptado'
  AND NOT EXISTS (
      SELECT 1
      FROM public.quotation_document_acknowledgements AS a
      WHERE a.quotation_id = q.id
  );

-- ============================================================
-- 8. VERIFICACIONES FINALES
-- ============================================================

-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
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
            '143 verification failed: expected 15 quotation fiscal snapshot columns, found %',
            v_count;
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.quotations'::regclass
      AND tgname = 'quotations_protect_accepted_data'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '143 verification failed: quotation accepted-data protection trigger missing';
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.quotations'::regclass
      AND tgname = 'quotations_invalidate_document_on_content_change'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '143 verification failed: quotation document invalidation trigger missing';
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'finalize_quotation_backend_document'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_quotation_id uuid, p_document_path text, p_document_sha256 text';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '143 verification failed: finalize_quotation_backend_document() missing';
    END IF;

    IF NOT has_function_privilege(
        'service_role',
        'public.finalize_quotation_backend_document(uuid,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '143 verification failed: service_role must have EXECUTE on backend quotation document RPC';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'public.finalize_quotation_backend_document(uuid,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '143 verification failed: authenticated must NOT have EXECUTE on backend quotation document RPC';
    END IF;

    IF has_function_privilege(
        'anon',
        'public.finalize_quotation_backend_document(uuid,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '143 verification failed: anon must NOT have EXECUTE on backend quotation document RPC';
    END IF;

    RAISE NOTICE
        '143 completed successfully: quotation fiscal snapshots, accepted-document protection and backend PDF finalization are ready.';
END;
$$;
GRANT SELECT
ON TABLE public.quotation_document_acknowledgements
TO service_role;
COMMIT;
