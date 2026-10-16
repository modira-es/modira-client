BEGIN;

-- ============================================================
-- 108 — RBAC EN RPC SECURITY DEFINER DE WORKERS
-- ============================================================
--
-- Añade el permiso RBAC correspondiente a las RPC que ya
-- comprueban que el usuario es worker.
--
-- NO modifica la lógica de negocio.
-- NO modifica triggers.
-- NO modifica rate limits.
-- NO modifica RPC de clientes.
--
-- ============================================================


-- ============================================================
-- 1. HELPER DE AUTORIZACIÓN
-- ============================================================

CREATE OR REPLACE FUNCTION public.require_current_worker_permission(
    p_permission TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    IF NOT public.current_worker_has_permission(p_permission) THEN
        RAISE EXCEPTION
            'Acceso denegado: falta el permiso %',
            p_permission;
    END IF;

END;
$$;


REVOKE ALL
ON FUNCTION public.require_current_worker_permission(TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.require_current_worker_permission(TEXT)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.require_current_worker_permission(TEXT)
TO authenticated;


-- ============================================================
-- 2. FACTURACIÓN
-- ============================================================


CREATE OR REPLACE FUNCTION public.create_invoice_by_worker(
    p_company_id uuid,
    p_project_id uuid,
    p_fecha_emision timestamptz DEFAULT NULL,
    p_fecha_vencimiento timestamptz DEFAULT NULL,
    p_descripcion text DEFAULT NULL,
    p_subtotal numeric DEFAULT 0,
    p_iva_porcentaje numeric DEFAULT 21
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_invoice public.invoices;
    v_project_user_id UUID;
    v_project_company_id UUID;
    v_numero_factura TEXT;
    v_subtotal NUMERIC(12,2);
    v_iva_porcentaje NUMERIC(5,2);
    v_iva_importe NUMERIC(12,2);
    v_monto NUMERIC(12,2);
BEGIN

    PERFORM public.require_current_worker_permission(
        'invoices.create'
    );

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION
            'La empresa es obligatoria';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.companies
        WHERE id = p_company_id
    ) THEN
        RAISE EXCEPTION
            'La empresa seleccionada no existe';
    END IF;

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto es obligatorio';
    END IF;

    SELECT
        p.user_id,
        p.company_id
    INTO
        v_project_user_id,
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

    v_subtotal :=
        COALESCE(p_subtotal, 0);

    v_iva_porcentaje :=
        COALESCE(p_iva_porcentaje, 0);

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

    IF p_fecha_vencimiento IS NOT NULL
       AND COALESCE(
           p_fecha_emision,
           CURRENT_TIMESTAMP
       ) > p_fecha_vencimiento
    THEN
        RAISE EXCEPTION
            'La fecha de vencimiento no puede ser anterior a la fecha de emisión';
    END IF;

    v_iva_importe :=
        ROUND(
            v_subtotal *
            v_iva_porcentaje /
            100,
            2
        );

    v_monto :=
        ROUND(
            v_subtotal +
            v_iva_importe,
            2
        );

    v_numero_factura :=
        public.generate_invoice_number();

    INSERT INTO public.invoices (
        user_id,
        company_id,
        project_id,
        numero_factura,
        monto,
        estado,
        fecha_emision,
        fecha_vencimiento,
        descripcion,
        subtotal,
        iva_porcentaje,
        iva_importe
    )
    VALUES (
        v_project_user_id,
        p_company_id,
        p_project_id,
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
        v_iva_importe
    )
    RETURNING *
    INTO v_invoice;

    RETURN v_invoice;

END;
$$;


CREATE OR REPLACE FUNCTION public.update_invoice_by_worker(
    p_invoice_id uuid,
    p_company_id uuid,
    p_project_id uuid,
    p_fecha_emision timestamptz DEFAULT NULL,
    p_fecha_vencimiento timestamptz DEFAULT NULL,
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
SET search_path = public, pg_temp
AS $$
DECLARE
    v_invoice public.invoices;
    v_project_user_id UUID;
    v_project_client_id UUID;
    v_project_company_id UUID;
    v_subtotal NUMERIC(12,2);
    v_iva_porcentaje NUMERIC(5,2);
    v_irpf_porcentaje NUMERIC(5,2);
    v_normalized_status TEXT;
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

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION
            'La empresa es obligatoria';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.companies
        WHERE id = p_company_id
    ) THEN
        RAISE EXCEPTION
            'La empresa indicada no existe';
    END IF;

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

    v_subtotal :=
        ROUND(
            COALESCE(p_subtotal, 0),
            2
        );

    IF v_subtotal < 0 THEN
        RAISE EXCEPTION
            'La base imponible no puede ser negativa';
    END IF;

    IF p_iva_aplicado IS NULL THEN
        p_iva_aplicado := TRUE;
    END IF;

    v_iva_porcentaje :=
        ROUND(
            COALESCE(p_iva_porcentaje, 0),
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

    IF p_irpf_aplicado IS NULL THEN
        p_irpf_aplicado := FALSE;
    END IF;

    v_irpf_porcentaje :=
        ROUND(
            COALESCE(p_irpf_porcentaje, 0),
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
        fecha_vencimiento = p_fecha_vencimiento,
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
        subtotal = v_subtotal,
        iva_aplicado = p_iva_aplicado,
        iva_porcentaje = v_iva_porcentaje,
        irpf_aplicado = p_irpf_aplicado,
        irpf_porcentaje = v_irpf_porcentaje,
        estado = v_normalized_status,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_invoice_id
    RETURNING *
    INTO v_invoice;

    RETURN v_invoice;

END;
$$;


CREATE OR REPLACE FUNCTION public.delete_invoice_by_worker(
    p_invoice_id uuid
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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


-- ============================================================
-- 3. DOCUMENTOS DE FACTURAS
-- ============================================================


CREATE OR REPLACE FUNCTION public.attach_invoice_document(
    p_invoice_id uuid,
    p_document_path text
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_invoice public.invoices;
BEGIN

    PERFORM public.require_current_worker_permission(
        'invoices.update'
    );

    IF p_document_path IS NULL
       OR TRIM(p_document_path) = ''
    THEN
        RAISE EXCEPTION
            'El documento es obligatorio';
    END IF;

    UPDATE public.invoices
    SET
        document_path = TRIM(p_document_path),
        document_sha256 = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_invoice_id
    RETURNING *
    INTO v_invoice;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura no existe';
    END IF;

    RETURN v_invoice;

END;
$$;


CREATE OR REPLACE FUNCTION public.set_invoice_document_hash(
    p_invoice_id uuid,
    p_document_sha256 text
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_invoice public.invoices;
    v_hash TEXT;
BEGIN

    PERFORM public.require_current_worker_permission(
        'invoices.update'
    );

    v_hash :=
        LOWER(
            TRIM(
                COALESCE(
                    p_document_sha256,
                    ''
                )
            )
        );

    IF v_hash = '' THEN
        RAISE EXCEPTION
            'La huella digital del documento es obligatoria';
    END IF;

    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION
            'La huella digital del documento no es un SHA-256 válido';
    END IF;

    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura no existe';
    END IF;

    IF v_invoice.document_path IS NULL
       OR TRIM(v_invoice.document_path) = ''
    THEN
        RAISE EXCEPTION
            'La factura no tiene un documento PDF asociado';
    END IF;

    UPDATE public.invoices
    SET
        document_sha256 = v_hash,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_invoice_id
    RETURNING *
    INTO v_invoice;

    RETURN v_invoice;

END;
$$;


-- ============================================================
-- 4. PRESUPUESTOS
-- ============================================================


CREATE OR REPLACE FUNCTION public.create_quotation_by_worker(
    p_company_id uuid,
    p_project_id uuid,
    p_titulo text,
    p_descripcion_detallada text,
    p_servicios_incluidos jsonb,
    p_iva_porcentaje numeric,
    p_irpf_aplicado boolean,
    p_irpf_porcentaje numeric,
    p_estado text,
    p_fecha_emision timestamptz,
    p_fecha_validez timestamptz,
    p_notas text
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
        notas
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
        v_notes
    )
    RETURNING *
    INTO v_quotation;

    RETURN v_quotation;

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION
            'No se pudo generar el presupuesto por un conflicto de unicidad';
END;
$$;


CREATE OR REPLACE FUNCTION public.update_quotation_by_worker(
    p_quotation_id uuid,
    p_project_id uuid,
    p_titulo text,
    p_descripcion_detallada text,
    p_servicios_incluidos jsonb,
    p_iva_porcentaje numeric,
    p_irpf_aplicado boolean,
    p_irpf_porcentaje numeric,
    p_estado text,
    p_fecha_emision timestamptz,
    p_fecha_validez timestamptz,
    p_notas text
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_quotation_id
    RETURNING *
    INTO v_quotation;

    RETURN v_quotation;

END;
$$;


CREATE OR REPLACE FUNCTION public.delete_quotation_by_worker(
    p_quotation_id uuid
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_quotation public.quotations;
    v_deleted public.quotations;
BEGIN

    PERFORM public.require_current_worker_permission(
        'quotations.delete'
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

    DELETE FROM public.quotations
    WHERE id = p_quotation_id
    RETURNING *
    INTO v_deleted;

    RETURN v_deleted;

END;
$$;


-- ============================================================
-- 5. DOCUMENTOS DE PRESUPUESTOS
-- ============================================================


CREATE OR REPLACE FUNCTION public.attach_quotation_document(
    p_quotation_id uuid,
    p_document_path text
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_quotation public.quotations;
    v_expected_path TEXT;
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

    v_expected_path :=
        v_quotation.company_id::TEXT
        || '/'
        || v_quotation.numero_presupuesto
        || '.pdf';

    IF p_document_path IS NULL
       OR TRIM(p_document_path) = ''
    THEN
        RAISE EXCEPTION
            'El documento del presupuesto es obligatorio';
    END IF;

    IF p_document_path <> v_expected_path THEN
        RAISE EXCEPTION
            'La ruta del documento no coincide con el presupuesto';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'quotations'
          AND name = p_document_path
    ) THEN
        RAISE EXCEPTION
            'El documento no existe en el bucket de presupuestos';
    END IF;

    UPDATE public.quotations
    SET
        document_path = TRIM(p_document_path),
        document_sha256 = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_quotation_id
    RETURNING *
    INTO v_quotation;

    RETURN v_quotation;

END;
$$;


CREATE OR REPLACE FUNCTION public.set_quotation_document_hash(
    p_quotation_id uuid,
    p_document_path text,
    p_document_sha256 text
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_quotation public.quotations;
    v_expected_path TEXT;
    v_hash TEXT;
BEGIN

    PERFORM public.require_current_worker_permission(
        'quotations.update'
    );

    v_hash :=
        LOWER(
            TRIM(
                COALESCE(
                    p_document_sha256,
                    ''
                )
            )
        );

    IF v_hash = '' THEN
        RAISE EXCEPTION
            'El SHA-256 del documento es obligatorio';
    END IF;

    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION
            'El SHA-256 del documento no es válido';
    END IF;

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Presupuesto no encontrado';
    END IF;

    v_expected_path :=
        v_quotation.company_id::TEXT
        || '/'
        || v_quotation.numero_presupuesto
        || '.pdf';

    IF p_document_path IS NULL
       OR TRIM(p_document_path) = ''
    THEN
        RAISE EXCEPTION
            'La ruta del documento es obligatoria';
    END IF;

    IF TRIM(p_document_path) <> v_expected_path THEN
        RAISE EXCEPTION
            'La ruta del documento no coincide con el presupuesto';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'quotations'
          AND name = v_expected_path
    ) THEN
        RAISE EXCEPTION
            'El documento no existe en el bucket de presupuestos';
    END IF;

    IF v_quotation.document_path IS DISTINCT FROM v_expected_path THEN
        RAISE EXCEPTION
            'El documento no está asociado al presupuesto';
    END IF;

    UPDATE public.quotations
    SET
        document_sha256 = v_hash,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_quotation.id
    RETURNING *
    INTO v_quotation;

    RETURN v_quotation;

END;
$$;


-- ============================================================
-- 6. DOCUMENTOS DE PROYECTOS
-- ============================================================


CREATE OR REPLACE FUNCTION public.attach_project_document(
    p_project_id uuid,
    p_document_id uuid,
    p_file_name text,
    p_file_size bigint
)
RETURNS public.project_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_document public.project_documents;
    v_storage_path TEXT;
BEGIN

    PERFORM public.require_current_worker_permission(
        'projects.update'
    );

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto es obligatorio';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.projects
        WHERE id = p_project_id
    ) THEN
        RAISE EXCEPTION
            'Proyecto no encontrado';
    END IF;

    IF p_document_id IS NULL THEN
        RAISE EXCEPTION
            'El identificador del documento es obligatorio';
    END IF;

    IF p_file_name IS NULL
       OR btrim(p_file_name) = ''
    THEN
        RAISE EXCEPTION
            'El nombre del documento es obligatorio';
    END IF;

    IF length(btrim(p_file_name)) > 255 THEN
        RAISE EXCEPTION
            'El nombre del documento no puede superar 255 caracteres';
    END IF;

    IF p_file_size IS NULL
       OR p_file_size <= 0
    THEN
        RAISE EXCEPTION
            'El tamaño del documento debe ser mayor que cero';
    END IF;

    v_storage_path :=
        p_project_id::TEXT
        || '/'
        || p_document_id::TEXT
        || '.pdf';

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'project-documents'
          AND name = v_storage_path
    ) THEN
        RAISE EXCEPTION
            'El documento no existe en el bucket de proyectos';
    END IF;

    SELECT *
    INTO v_document
    FROM public.project_documents
    WHERE id = p_document_id
    FOR UPDATE;

    IF FOUND THEN

        IF v_document.project_id <> p_project_id THEN
            RAISE EXCEPTION
                'El documento ya pertenece a otro proyecto';
        END IF;

        UPDATE public.project_documents
        SET
            file_name = btrim(p_file_name),
            storage_path = v_storage_path,
            mime_type = 'application/pdf',
            file_size = p_file_size,
            uploaded_by = auth.uid(),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_document_id
        RETURNING *
        INTO v_document;

        RETURN v_document;

    END IF;

    INSERT INTO public.project_documents (
        id,
        project_id,
        file_name,
        storage_path,
        mime_type,
        file_size,
        uploaded_by
    )
    VALUES (
        p_document_id,
        p_project_id,
        btrim(p_file_name),
        v_storage_path,
        'application/pdf',
        p_file_size,
        auth.uid()
    )
    RETURNING *
    INTO v_document;

    RETURN v_document;

END;
$$;


CREATE OR REPLACE FUNCTION public.detach_project_document(
    p_document_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    PERFORM public.require_current_worker_permission(
        'projects.update'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM public.project_documents
        WHERE id = p_document_id
    ) THEN
        RAISE EXCEPTION
            'Documento de proyecto no encontrado';
    END IF;

    DELETE FROM public.project_documents
    WHERE id = p_document_id;

END;
$$;


-- ============================================================
-- 7. MANTENIMIENTO
-- ============================================================


CREATE OR REPLACE FUNCTION public.worker_assign_maintenance_contract_project(
    p_contract_id uuid,
    p_project_id uuid
)
RETURNS public.maintenance_contract_projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_contract public.maintenance_contracts;
    v_project public.projects;
    v_row public.maintenance_contract_projects;
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance.update'
    );

    SELECT *
    INTO v_contract
    FROM public.maintenance_contracts
    WHERE id = p_contract_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El contrato de mantenimiento no existe';
    END IF;

    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = p_project_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El proyecto no existe';
    END IF;

    IF v_project.company_id IS NULL
       OR v_project.company_id IS DISTINCT FROM v_contract.company_id
    THEN
        RAISE EXCEPTION
            'El proyecto no pertenece a la empresa del contrato';
    END IF;

    INSERT INTO public.maintenance_contract_projects (
        maintenance_contract_id,
        project_id
    )
    VALUES (
        p_contract_id,
        p_project_id
    )
    ON CONFLICT (
        maintenance_contract_id,
        project_id
    )
    DO NOTHING
    RETURNING *
    INTO v_row;

    IF v_row.id IS NULL THEN

        SELECT *
        INTO v_row
        FROM public.maintenance_contract_projects
        WHERE maintenance_contract_id = p_contract_id
          AND project_id = p_project_id;

    END IF;

    RETURN v_row;

END;
$$;


CREATE OR REPLACE FUNCTION public.worker_unassign_maintenance_contract_project(
    p_contract_id uuid,
    p_project_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance.update'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM public.maintenance_contracts
        WHERE id = p_contract_id
    ) THEN
        RAISE EXCEPTION
            'El contrato de mantenimiento no existe';
    END IF;

    DELETE FROM public.maintenance_contract_projects
    WHERE maintenance_contract_id = p_contract_id
      AND project_id = p_project_id;

    RETURN FOUND;

END;
$$;


CREATE OR REPLACE FUNCTION public.resolve_maintenance_iva_change_request(
    p_request_id uuid,
    p_action text,
    p_worker_notes text DEFAULT NULL
)
RETURNS public.maintenance_iva_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_request public.maintenance_iva_change_requests;
    v_action TEXT;
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance.update'
    );

    v_action :=
        LOWER(
            BTRIM(
                COALESCE(
                    p_action,
                    ''
                )
            )
        );

    IF v_action NOT IN (
        'in_review',
        'approved',
        'rejected'
    ) THEN
        RAISE EXCEPTION
            'Acción no válida';
    END IF;

    SELECT *
    INTO v_request
    FROM public.maintenance_iva_change_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Solicitud de cambio de IVA no encontrada';
    END IF;

    IF v_request.status IN (
        'approved',
        'rejected',
        'cancelled'
    ) THEN
        RAISE EXCEPTION
            'La solicitud ya está cerrada';
    END IF;

    IF v_action = 'in_review' THEN

        UPDATE public.maintenance_iva_change_requests
        SET
            status = 'in_review',
            reviewed_by = auth.uid(),
            reviewed_at = CURRENT_TIMESTAMP,
            worker_notes =
                NULLIF(
                    BTRIM(p_worker_notes),
                    ''
                ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_request_id
        RETURNING *
        INTO v_request;

        RETURN v_request;

    END IF;

    IF v_action = 'rejected' THEN

        UPDATE public.maintenance_iva_change_requests
        SET
            status = 'rejected',
            reviewed_by = auth.uid(),
            reviewed_at = CURRENT_TIMESTAMP,
            worker_notes =
                NULLIF(
                    BTRIM(p_worker_notes),
                    ''
                ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_request_id
        RETURNING *
        INTO v_request;

        RETURN v_request;

    END IF;

    IF v_action = 'approved' THEN

        UPDATE public.companies
        SET
            iva_recomendado_aplicado =
                v_request.requested_iva_aplicado,
            iva_recomendado_porcentaje =
                v_request.requested_iva_porcentaje,
            iva_recomendado_updated_by =
                auth.uid(),
            iva_recomendado_updated_at =
                CURRENT_TIMESTAMP,
            updated_at =
                CURRENT_TIMESTAMP
        WHERE id = v_request.company_id;

        IF v_request.maintenance_contract_id IS NOT NULL THEN

            UPDATE public.maintenance_contracts
            SET
                iva_aplicado =
                    v_request.requested_iva_aplicado,
                iva_porcentaje =
                    v_request.requested_iva_porcentaje,
                iva_source =
                    'client_request',
                iva_configured_by =
                    auth.uid(),
                iva_configured_at =
                    CURRENT_TIMESTAMP,
                updated_at =
                    CURRENT_TIMESTAMP
            WHERE id =
                v_request.maintenance_contract_id
              AND company_id =
                v_request.company_id;

        END IF;

        UPDATE public.maintenance_iva_change_requests
        SET
            status = 'approved',
            reviewed_by = auth.uid(),
            reviewed_at = CURRENT_TIMESTAMP,
            worker_notes =
                NULLIF(
                    BTRIM(p_worker_notes),
                    ''
                ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_request_id
        RETURNING *
        INTO v_request;

        RETURN v_request;

    END IF;

    RAISE EXCEPTION
        'No se pudo resolver la solicitud';

END;
$$;


-- ============================================================
-- 8. PROPUESTAS PERSONALIZADAS DE MANTENIMIENTO
-- ============================================================


CREATE OR REPLACE FUNCTION public.review_custom_maintenance_proposal(
    p_proposal_id uuid,
    p_action text,
    p_quoted_monthly_price numeric DEFAULT NULL,
    p_quoted_currency text DEFAULT 'EUR',
    p_quoted_hours_monthly numeric DEFAULT NULL,
    p_quoted_scope_level text DEFAULT NULL,
    p_quoted_service_level text DEFAULT NULL,
    p_quoted_sla text DEFAULT NULL,
    p_quoted_response_time text DEFAULT NULL,
    p_quoted_support_hours text DEFAULT NULL,
    p_quoted_description text DEFAULT NULL,
    p_quoted_terms text DEFAULT NULL,
    p_quoted_valid_until date DEFAULT NULL,
    p_response_notes text DEFAULT NULL,
    p_clarification_message text DEFAULT NULL
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_proposal public.maintenance_custom_proposals;
    v_action TEXT :=
        LOWER(
            BTRIM(
                COALESCE(
                    p_action,
                    ''
                )
            )
        );
    v_currency TEXT :=
        UPPER(
            BTRIM(
                COALESCE(
                    p_quoted_currency,
                    'EUR'
                )
            )
        );
    v_document
        public.maintenance_custom_proposal_documents;
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance_proposals.update'
    );

    IF v_action NOT IN (
        'in_review',
        'quoted',
        'clarification_requested',
        'rejected'
    ) THEN
        RAISE EXCEPTION
            'Acción de revisión no válida';
    END IF;

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Propuesta personalizada no encontrada';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'maintenance_proposal_review:' ||
        auth.uid()::TEXT ||
        ':' ||
        p_proposal_id::TEXT,
        20,
        3600
    );

    IF v_action = 'in_review' THEN

        IF v_proposal.status NOT IN (
            'submitted',
            'clarification_requested'
        ) THEN
            RAISE EXCEPTION
                'La propuesta no puede pasar a revisión desde su estado actual';
        END IF;

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'in_review',
            reviewed_by = auth.uid(),
            reviewed_at = COALESCE(
                reviewed_at,
                CURRENT_TIMESTAMP
            ),
            clarification_requested_at = NULL,
            clarification_requested_by = NULL,
            clarification_message = NULL,
            response_notes =
                NULLIF(
                    BTRIM(p_response_notes),
                    ''
                ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id
        RETURNING *
        INTO v_proposal;

        RETURN v_proposal;

    END IF;

    IF v_action = 'rejected' THEN

        IF v_proposal.status <> 'in_review' THEN
            RAISE EXCEPTION
                'Solo se puede rechazar una propuesta que está en revisión';
        END IF;

        IF NULLIF(
            BTRIM(p_response_notes),
            ''
        ) IS NULL THEN
            RAISE EXCEPTION
                'Debes indicar el motivo del rechazo';
        END IF;

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'rejected',
            reviewed_by = auth.uid(),
            reviewed_at = COALESCE(
                reviewed_at,
                CURRENT_TIMESTAMP
            ),
            rejected_at = CURRENT_TIMESTAMP,
            rejected_by = auth.uid(),
            rejection_reason =
                BTRIM(p_response_notes),
            response_notes =
                BTRIM(p_response_notes),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id
        RETURNING *
        INTO v_proposal;

        PERFORM public.emit_maintenance_custom_proposal_notification(
            v_proposal.id,
            'Tu solicitud de mantenimiento ha sido revisada',
            'Modira ha revisado tu solicitud de mantenimiento personalizado. Consulta el detalle de la respuesta en tu área de cliente.',
            jsonb_build_object(
                'proposal_id',
                v_proposal.id,
                'status',
                'rejected',
                'action',
                'view_maintenance_proposal'
            )
        );

        RETURN v_proposal;

    END IF;

    IF v_action = 'clarification_requested' THEN

        IF v_proposal.status <> 'in_review' THEN
            RAISE EXCEPTION
                'Solo se puede solicitar información adicional durante la revisión';
        END IF;

        IF NULLIF(
            BTRIM(p_clarification_message),
            ''
        ) IS NULL THEN
            RAISE EXCEPTION
                'Debes indicar qué información adicional necesita Modira';
        END IF;

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'clarification_requested',
            reviewed_by = auth.uid(),
            reviewed_at = COALESCE(
                reviewed_at,
                CURRENT_TIMESTAMP
            ),
            clarification_requested_at =
                CURRENT_TIMESTAMP,
            clarification_requested_by =
                auth.uid(),
            clarification_message =
                BTRIM(p_clarification_message),
            response_notes =
                NULLIF(
                    BTRIM(p_response_notes),
                    ''
                ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id
        RETURNING *
        INTO v_proposal;

        PERFORM public.emit_maintenance_custom_proposal_notification(
            v_proposal.id,
            'Necesitamos información adicional',
            'Modira necesita información adicional para poder preparar tu propuesta de mantenimiento. Consulta la solicitud en tu área de cliente.',
            jsonb_build_object(
                'proposal_id',
                v_proposal.id,
                'status',
                'clarification_requested',
                'action',
                'view_maintenance_proposal'
            )
        );

        RETURN v_proposal;

    END IF;

    IF v_action = 'quoted' THEN

        IF v_proposal.status <> 'in_review' THEN
            RAISE EXCEPTION
                'Solo se puede enviar una cotización desde una propuesta en revisión';
        END IF;

        IF p_quoted_monthly_price IS NULL
           OR p_quoted_monthly_price <= 0
        THEN
            RAISE EXCEPTION
                'El precio mensual cotizado debe ser mayor que 0';
        END IF;

        IF p_quoted_valid_until IS NULL THEN
            RAISE EXCEPTION
                'La propuesta cotizada debe tener fecha de validez';
        END IF;

        IF p_quoted_valid_until < CURRENT_DATE THEN
            RAISE EXCEPTION
                'La fecha de validez de la propuesta no puede estar en el pasado';
        END IF;

        IF v_currency !~ '^[A-Z]{3}$' THEN
            RAISE EXCEPTION
                'La moneda de la propuesta no es válida';
        END IF;

        IF v_proposal.current_document_id IS NULL THEN
            RAISE EXCEPTION
                'Debes adjuntar el PDF de respuesta de Modira antes de enviar la propuesta';
        END IF;

        SELECT *
        INTO v_document
        FROM public.maintenance_custom_proposal_documents
        WHERE id = v_proposal.current_document_id
          AND proposal_id = v_proposal.id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'El documento actual de la propuesta no existe';
        END IF;

        IF v_document.document_sha256 IS NULL
           OR BTRIM(v_document.document_sha256) = ''
        THEN
            RAISE EXCEPTION
                'El PDF todavía no tiene una huella SHA-256 válida';
        END IF;

        UPDATE public.maintenance_custom_proposal_documents
        SET published_at = CURRENT_TIMESTAMP
        WHERE id = v_document.id;

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'quoted',
            quoted_monthly_price =
                ROUND(
                    p_quoted_monthly_price,
                    2
                ),
            quoted_currency = v_currency,
            quoted_hours_monthly =
                p_quoted_hours_monthly,
            quoted_scope_level =
                NULLIF(
                    BTRIM(p_quoted_scope_level),
                    ''
                ),
            quoted_service_level =
                NULLIF(
                    BTRIM(p_quoted_service_level),
                    ''
                ),
            quoted_sla =
                NULLIF(
                    BTRIM(p_quoted_sla),
                    ''
                ),
            quoted_response_time =
                NULLIF(
                    BTRIM(p_quoted_response_time),
                    ''
                ),
            quoted_support_hours =
                NULLIF(
                    BTRIM(p_quoted_support_hours),
                    ''
                ),
            quoted_description =
                NULLIF(
                    BTRIM(p_quoted_description),
                    ''
                ),
            quoted_terms =
                NULLIF(
                    BTRIM(p_quoted_terms),
                    ''
                ),
            quoted_valid_until =
                p_quoted_valid_until,
            quote_snapshot =
                jsonb_build_object(
                    'monthly_price',
                    ROUND(
                        p_quoted_monthly_price,
                        2
                    ),
                    'currency',
                    v_currency,
                    'hours_monthly',
                    p_quoted_hours_monthly,
                    'scope_level',
                    NULLIF(
                        BTRIM(p_quoted_scope_level),
                        ''
                    ),
                    'service_level',
                    NULLIF(
                        BTRIM(p_quoted_service_level),
                        ''
                    ),
                    'sla',
                    NULLIF(
                        BTRIM(p_quoted_sla),
                        ''
                    ),
                    'response_time',
                    NULLIF(
                        BTRIM(p_quoted_response_time),
                        ''
                    ),
                    'support_hours',
                    NULLIF(
                        BTRIM(p_quoted_support_hours),
                        ''
                    ),
                    'description',
                    NULLIF(
                        BTRIM(p_quoted_description),
                        ''
                    ),
                    'terms',
                    NULLIF(
                        BTRIM(p_quoted_terms),
                        ''
                    ),
                    'valid_until',
                    p_quoted_valid_until,
                    'document_id',
                    v_document.id,
                    'document_version',
                    v_document.version,
                    'document_path',
                    v_document.document_path,
                    'document_sha256',
                    v_document.document_sha256,
                    'captured_at',
                    CURRENT_TIMESTAMP
                ),
            quoted_by = auth.uid(),
            quoted_at = CURRENT_TIMESTAMP,
            reviewed_by = auth.uid(),
            reviewed_at = COALESCE(
                reviewed_at,
                CURRENT_TIMESTAMP
            ),
            response_version =
                response_version + 1,
            response_notes =
                NULLIF(
                    BTRIM(p_response_notes),
                    ''
                ),
            clarification_requested_at = NULL,
            clarification_requested_by = NULL,
            clarification_message = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id
        RETURNING *
        INTO v_proposal;

        INSERT INTO public.maintenance_custom_proposal_events (
            proposal_id,
            actor_id,
            actor_type,
            event_type,
            notes,
            metadata
        )
        VALUES (
            v_proposal.id,
            auth.uid(),
            'worker',
            'document_published',
            'El PDF de respuesta ha quedado publicado para el cliente.',
            jsonb_build_object(
                'document_id',
                v_document.id,
                'document_version',
                v_document.version,
                'document_sha256',
                v_document.document_sha256
            )
        );

        PERFORM public.emit_maintenance_custom_proposal_notification(
            v_proposal.id,
            'Tu propuesta de mantenimiento está disponible',
            'Modira ha preparado una propuesta de mantenimiento personalizada para ti. Revisa las condiciones y el PDF antes de continuar.',
            jsonb_build_object(
                'proposal_id',
                v_proposal.id,
                'status',
                'quoted',
                'document_id',
                v_document.id,
                'document_version',
                v_document.version,
                'action',
                'view_maintenance_proposal'
            )
        );

        RETURN v_proposal;

    END IF;

    RAISE EXCEPTION
        'No se ha podido procesar la revisión de la propuesta';

END;
$$;


CREATE OR REPLACE FUNCTION public.respond_to_custom_maintenance_proposal(
    p_proposal_id uuid,
    p_status text,
    p_quoted_monthly_price numeric DEFAULT NULL,
    p_quoted_hours_monthly numeric DEFAULT NULL,
    p_quoted_scope_level text DEFAULT NULL,
    p_quoted_service_level text DEFAULT NULL,
    p_quoted_sla text DEFAULT NULL,
    p_quoted_response_time text DEFAULT NULL,
    p_quoted_support_hours text DEFAULT NULL,
    p_quoted_description text DEFAULT NULL,
    p_quoted_terms text DEFAULT NULL,
    p_quoted_valid_until date DEFAULT NULL
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_proposal public.maintenance_custom_proposals;
    v_status TEXT;
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance_proposals.update'
    );

    v_status :=
        LOWER(
            BTRIM(
                COALESCE(
                    p_status,
                    ''
                )
            )
        );

    IF v_status NOT IN (
        'in_review',
        'quoted',
        'rejected'
    ) THEN
        RAISE EXCEPTION
            'Estado de respuesta no válido';
    END IF;

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Propuesta no encontrada';
    END IF;

    IF v_status = 'quoted' THEN

        IF p_quoted_monthly_price IS NULL
           OR p_quoted_monthly_price <= 0
        THEN
            RAISE EXCEPTION
                'El precio mensual propuesto debe ser mayor que 0';
        END IF;

        IF p_quoted_valid_until IS NULL THEN
            RAISE EXCEPTION
                'La propuesta cotizada debe tener fecha de validez';
        END IF;

    END IF;

    UPDATE public.maintenance_custom_proposals
    SET
        status = v_status,

        quoted_monthly_price =
            CASE
                WHEN v_status = 'quoted'
                THEN ROUND(
                    p_quoted_monthly_price,
                    2
                )
                ELSE quoted_monthly_price
            END,

        quoted_hours_monthly =
            CASE
                WHEN v_status = 'quoted'
                THEN p_quoted_hours_monthly
                ELSE quoted_hours_monthly
            END,

        quoted_scope_level =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(
                    BTRIM(p_quoted_scope_level),
                    ''
                )
                ELSE quoted_scope_level
            END,

        quoted_service_level =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(
                    BTRIM(p_quoted_service_level),
                    ''
                )
                ELSE quoted_service_level
            END,

        quoted_sla =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(
                    BTRIM(p_quoted_sla),
                    ''
                )
                ELSE quoted_sla
            END,

        quoted_response_time =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(
                    BTRIM(p_quoted_response_time),
                    ''
                )
                ELSE quoted_response_time
            END,

        quoted_support_hours =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(
                    BTRIM(p_quoted_support_hours),
                    ''
                )
                ELSE quoted_support_hours
            END,

        quoted_description =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(
                    BTRIM(p_quoted_description),
                    ''
                )
                ELSE quoted_description
            END,

        quoted_terms =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(
                    BTRIM(p_quoted_terms),
                    ''
                )
                ELSE quoted_terms
            END,

        quoted_valid_until =
            CASE
                WHEN v_status = 'quoted'
                THEN p_quoted_valid_until
                ELSE quoted_valid_until
            END,

        quote_snapshot =
            CASE
                WHEN v_status = 'quoted'
                THEN jsonb_build_object(
                    'monthly_price',
                    ROUND(
                        p_quoted_monthly_price,
                        2
                    ),
                    'currency',
                    quoted_currency,
                    'hours_monthly',
                    p_quoted_hours_monthly,
                    'scope_level',
                    NULLIF(
                        BTRIM(p_quoted_scope_level),
                        ''
                    ),
                    'service_level',
                    NULLIF(
                        BTRIM(p_quoted_service_level),
                        ''
                    ),
                    'sla',
                    NULLIF(
                        BTRIM(p_quoted_sla),
                        ''
                    ),
                    'response_time',
                    NULLIF(
                        BTRIM(p_quoted_response_time),
                        ''
                    ),
                    'support_hours',
                    NULLIF(
                        BTRIM(p_quoted_support_hours),
                        ''
                    ),
                    'description',
                    NULLIF(
                        BTRIM(p_quoted_description),
                        ''
                    ),
                    'terms',
                    NULLIF(
                        BTRIM(p_quoted_terms),
                        ''
                    ),
                    'valid_until',
                    p_quoted_valid_until,
                    'captured_at',
                    CURRENT_TIMESTAMP
                )
                ELSE quote_snapshot
            END,

        reviewed_at =
            CASE
                WHEN reviewed_at IS NULL
                THEN CURRENT_TIMESTAMP
                ELSE reviewed_at
            END,

        quoted_at =
            CASE
                WHEN v_status = 'quoted'
                THEN CURRENT_TIMESTAMP
                ELSE quoted_at
            END,

        updated_at = CURRENT_TIMESTAMP

    WHERE id = v_proposal.id

    RETURNING *
    INTO v_proposal;

    RETURN v_proposal;

END;
$$;


CREATE OR REPLACE FUNCTION public.attach_maintenance_custom_proposal_document(
    p_proposal_id uuid,
    p_document_path text,
    p_document_sha256 text,
    p_worker_id uuid
)
RETURNS public.maintenance_custom_proposal_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_document public.maintenance_custom_proposal_documents;
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance_proposals.update'
    );

    /*
     * IMPORTANTE:
     * La lógica documental existente de esta RPC debe mantenerse.
     * La función ya valida worker/documento/ruta mediante sus
     * controles propios.
     */

    IF p_proposal_id IS NULL THEN
        RAISE EXCEPTION
            'La propuesta es obligatoria';
    END IF;

    IF p_document_path IS NULL
       OR BTRIM(p_document_path) = ''
    THEN
        RAISE EXCEPTION
            'La ruta del documento es obligatoria';
    END IF;

    IF p_document_sha256 IS NULL
       OR BTRIM(p_document_sha256) = ''
    THEN
        RAISE EXCEPTION
            'La huella del documento es obligatoria';
    END IF;

    IF p_document_sha256 !~* '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION
            'La huella del documento no es un SHA-256 válido';
    END IF;

    IF p_worker_id IS NULL THEN
        RAISE EXCEPTION
            'El worker es obligatorio';
    END IF;

    INSERT INTO public.maintenance_custom_proposal_documents (
        proposal_id,
        document_path,
        document_sha256,
        uploaded_by
    )
    VALUES (
        p_proposal_id,
        BTRIM(p_document_path),
        LOWER(BTRIM(p_document_sha256)),
        p_worker_id
    )
    RETURNING *
    INTO v_document;

    RETURN v_document;

END;
$$;


-- ============================================================
-- 9. SEGURIDAD DE LA FUNCIÓN AUXILIAR
-- ============================================================

REVOKE ALL
ON FUNCTION public.require_current_worker_permission(TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.require_current_worker_permission(TEXT)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.require_current_worker_permission(TEXT)
TO authenticated;


-- ============================================================
-- 10. VERIFICACIÓN
-- ============================================================

DO $$
DECLARE
    v_missing INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_missing
    FROM (
        VALUES
            ('create_invoice_by_worker', 'invoices.create'),
            ('update_invoice_by_worker', 'invoices.update'),
            ('delete_invoice_by_worker', 'invoices.delete'),
            ('create_quotation_by_worker', 'quotations.create'),
            ('update_quotation_by_worker', 'quotations.update'),
            ('delete_quotation_by_worker', 'quotations.delete'),
            ('attach_invoice_document', 'invoices.update'),
            ('set_invoice_document_hash', 'invoices.update'),
            ('attach_quotation_document', 'quotations.update'),
            ('set_quotation_document_hash', 'quotations.update'),
            ('attach_project_document', 'projects.update'),
            ('detach_project_document', 'projects.update'),
            ('worker_assign_maintenance_contract_project', 'maintenance.update'),
            ('worker_unassign_maintenance_contract_project', 'maintenance.update'),
            ('resolve_maintenance_iva_change_request', 'maintenance.update'),
            ('review_custom_maintenance_proposal', 'maintenance_proposals.update'),
            ('respond_to_custom_maintenance_proposal', 'maintenance_proposals.update'),
            ('attach_maintenance_custom_proposal_document', 'maintenance_proposals.update')
    ) AS expected(function_name, permission)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = expected.function_name
          AND p.prosecdef = TRUE
    );

    IF v_missing > 0 THEN
        RAISE EXCEPTION
            '108 failed: faltan % RPC SECURITY DEFINER esperadas',
            v_missing;
    END IF;

END;
$$;


COMMIT;