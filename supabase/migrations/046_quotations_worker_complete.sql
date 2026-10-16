BEGIN;

-- ============================================================
-- MODIRA — 046_quotations_worker_update_delete_and_pdf_fix.sql
--
-- Completa el endurecimiento 045 sin devolver permisos directos
-- de escritura sobre public.quotations.
--
-- 1. Corrige Storage INSERT de quotations: 032/008 exigía que
--    quotations.document_path ya estuviera informado ANTES de
--    subir el objeto, lo que hacía imposible el primer upload.
-- 2. Añade RPC segura de UPDATE para workers activos.
-- 3. Añade RPC segura de DELETE para workers activos.
-- 4. Mantiene INSERT/UPDATE/DELETE directos revocados.
-- ============================================================

-- ============================================================
-- 1. STORAGE: CORREGIR EL CICLO DE SUBIDA INICIAL
-- ============================================================

DROP POLICY IF EXISTS quotation_documents_worker_insert
ON storage.objects;

CREATE POLICY quotation_documents_worker_insert
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'quotations'
    AND public.current_user_is_worker()
    AND name ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/.+\.pdf$'
    AND EXISTS (
        SELECT 1
        FROM public.quotations q
        WHERE (
            q.company_id::TEXT
            || '/'
            || q.numero_presupuesto
            || '.pdf'
        ) = objects.name
    )
);

DROP POLICY IF EXISTS quotation_documents_worker_update
ON storage.objects;

CREATE POLICY quotation_documents_worker_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (
    bucket_id = 'quotations'
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.quotations q
        WHERE q.document_path = objects.name
    )
)
WITH CHECK (
    bucket_id = 'quotations'
    AND public.current_user_is_worker()
    AND name ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/.+\.pdf$'
    AND EXISTS (
        SELECT 1
        FROM public.quotations q
        WHERE (
            q.company_id::TEXT
            || '/'
            || q.numero_presupuesto
            || '.pdf'
        ) = objects.name
    )
);

-- ============================================================
-- 2. RPC — ACTUALIZAR PRESUPUESTO COMO WORKER
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_quotation_by_worker(
    p_quotation_id UUID,
    p_project_id UUID,
    p_titulo TEXT,
    p_descripcion_detallada TEXT,
    p_servicios_incluidos JSONB,
    p_iva_porcentaje NUMERIC,
    p_irpf_aplicado BOOLEAN,
    p_irpf_porcentaje NUMERIC,
    p_estado TEXT,
    p_fecha_emision TIMESTAMPTZ,
    p_fecha_validez TIMESTAMPTZ,
    p_notas TEXT
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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
BEGIN
    IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador activo';
    END IF;

    IF p_quotation_id IS NULL THEN
        RAISE EXCEPTION 'El presupuesto es obligatorio';
    END IF;

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Presupuesto no encontrado';
    END IF;

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION 'El proyecto es obligatorio';
    END IF;

    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = p_project_id
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El proyecto seleccionado no existe';
    END IF;

    IF v_project.company_id IS NULL THEN
        RAISE EXCEPTION 'El proyecto seleccionado no tiene empresa';
    END IF;

    IF v_project.user_id IS NULL THEN
        RAISE EXCEPTION 'El proyecto seleccionado no tiene un usuario propietario válido';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM auth.users u WHERE u.id = v_project.user_id
    ) THEN
        RAISE EXCEPTION 'El propietario del proyecto no existe';
    END IF;

    IF v_project.client_id IS NOT NULL
       AND NOT EXISTS (
            SELECT 1
            FROM public.clients c
            WHERE c.id = v_project.client_id
              AND c.company_id = v_project.company_id
       ) THEN
        RAISE EXCEPTION 'El cliente del proyecto no pertenece a la empresa';
    END IF;

    v_title := NULLIF(BTRIM(p_titulo), '');

    IF v_title IS NULL THEN
        RAISE EXCEPTION 'El título del presupuesto es obligatorio';
    END IF;

    IF LENGTH(v_title) > 300 THEN
        RAISE EXCEPTION 'El título no puede superar 300 caracteres';
    END IF;

    v_description := NULLIF(
        BTRIM(COALESCE(p_descripcion_detallada, '')),
        ''
    );

    IF v_description IS NOT NULL AND LENGTH(v_description) > 10000 THEN
        RAISE EXCEPTION 'La descripción del presupuesto no puede superar 10000 caracteres';
    END IF;

    v_notes := NULLIF(
        BTRIM(COALESCE(p_notas, '')),
        ''
    );

    IF v_notes IS NOT NULL AND LENGTH(v_notes) > 10000 THEN
        RAISE EXCEPTION 'Las notas del presupuesto no pueden superar 10000 caracteres';
    END IF;

    v_state := INITCAP(
        LOWER(
            BTRIM(COALESCE(p_estado, 'Pendiente'))
        )
    );

    IF v_state NOT IN ('Pendiente', 'Aceptado', 'Rechazado') THEN
        RAISE EXCEPTION 'Estado de presupuesto no válido';
    END IF;

    v_iva := ROUND(COALESCE(p_iva_porcentaje, 0), 2);

    IF v_iva < 0 OR v_iva > 100 THEN
        RAISE EXCEPTION 'El porcentaje de IVA debe estar entre 0 y 100';
    END IF;

    v_irpf_applied := COALESCE(p_irpf_aplicado, FALSE);
    v_irpf := ROUND(COALESCE(p_irpf_porcentaje, 0), 2);

    IF NOT v_irpf_applied THEN
        IF v_irpf <> 0 THEN
            RAISE EXCEPTION 'Si el IRPF no se aplica, el porcentaje debe ser 0';
        END IF;
        v_irpf := 0;
    ELSE
        IF v_irpf <= 0 OR v_irpf > 100 THEN
            RAISE EXCEPTION 'El porcentaje de IRPF debe ser mayor que 0 y menor o igual que 100';
        END IF;
    END IF;

    IF p_servicios_incluidos IS NULL
       OR jsonb_typeof(p_servicios_incluidos) <> 'array' THEN
        RAISE EXCEPTION 'Los servicios incluidos deben ser un array JSON';
    END IF;

    IF jsonb_array_length(p_servicios_incluidos) = 0 THEN
        RAISE EXCEPTION 'Debe existir al menos un servicio';
    END IF;

    IF jsonb_array_length(p_servicios_incluidos) > 100 THEN
        RAISE EXCEPTION 'El presupuesto no puede contener más de 100 servicios';
    END IF;

    v_subtotal := 0;

    FOR v_service IN
        SELECT value FROM jsonb_array_elements(p_servicios_incluidos)
    LOOP
        IF jsonb_typeof(v_service) <> 'object' THEN
            RAISE EXCEPTION 'Cada servicio debe ser un objeto JSON';
        END IF;

        v_service_description := NULLIF(
            BTRIM(COALESCE(v_service->>'descripcion', '')),
            ''
        );

        IF v_service_description IS NULL THEN
            RAISE EXCEPTION 'Todos los servicios deben tener una descripción';
        END IF;

        IF LENGTH(v_service_description) > 2000 THEN
            RAISE EXCEPTION 'La descripción de un servicio no puede superar 2000 caracteres';
        END IF;

        IF NOT (v_service ? 'cantidad') OR NOT (v_service ? 'precio') THEN
            RAISE EXCEPTION 'Cada servicio debe contener cantidad y precio';
        END IF;

        BEGIN
            v_quantity := (v_service->>'cantidad')::NUMERIC;
            v_price := (v_service->>'precio')::NUMERIC;
        EXCEPTION
            WHEN invalid_text_representation OR numeric_value_out_of_range THEN
                RAISE EXCEPTION 'Cantidad o precio de servicio no válidos';
        END;

        IF v_quantity IS NULL OR v_quantity <= 0 OR v_quantity > 1000000 THEN
            RAISE EXCEPTION 'La cantidad de un servicio debe ser mayor que 0';
        END IF;

        IF v_price IS NULL OR v_price < 0 OR v_price > 100000000 THEN
            RAISE EXCEPTION 'El precio de un servicio no puede ser negativo';
        END IF;

        v_subtotal := v_subtotal + ROUND(v_quantity * v_price, 2);

        IF v_subtotal > 1000000000 THEN
            RAISE EXCEPTION 'El importe total del presupuesto supera el límite permitido';
        END IF;
    END LOOP;

    v_subtotal := ROUND(v_subtotal, 2);

    v_iva_importe := ROUND(v_subtotal * (v_iva / 100), 2);

    IF v_irpf_applied THEN
        v_irpf_importe := ROUND(v_subtotal * (v_irpf / 100), 2);
    ELSE
        v_irpf_importe := 0;
    END IF;

    v_total := ROUND(
        v_subtotal + v_iva_importe - v_irpf_importe,
        2
    );

    IF v_total < 0 THEN
        RAISE EXCEPTION 'El total del presupuesto no puede ser negativo';
    END IF;

    v_fecha_emision := COALESCE(
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
$function$;

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
-- 3. RPC — ELIMINAR PRESUPUESTO COMO WORKER
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_quotation_by_worker(
    p_quotation_id UUID
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_quotation public.quotations;
    v_deleted public.quotations;
BEGIN
    IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador activo';
    END IF;

    IF p_quotation_id IS NULL THEN
        RAISE EXCEPTION 'El presupuesto es obligatorio';
    END IF;

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Presupuesto no encontrado';
    END IF;

    DELETE FROM public.quotations
    WHERE id = p_quotation_id
    RETURNING *
    INTO v_deleted;

    RETURN v_deleted;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_quotation_by_worker(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.delete_quotation_by_worker(UUID)
TO authenticated;

ALTER FUNCTION public.delete_quotation_by_worker(UUID)
SET search_path = public, pg_temp;

-- ============================================================
-- 4. CONSERVAR EL MODELO DE 045
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON public.quotations
FROM anon, authenticated;

GRANT SELECT
ON public.quotations
TO authenticated;

COMMIT;
