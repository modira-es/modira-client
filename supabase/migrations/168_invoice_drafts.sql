BEGIN;

-- ============================================================
-- MIGRACIÓN 072: BORRADORES INTERNOS DE FACTURAS
-- ============================================================
--
-- Añade:
--   create_invoice_draft_by_worker()
--   save_invoice_draft_by_worker()
--
-- El envío al cliente se realiza mediante el flujo documental
-- actual. La finalización del documento convierte un borrador
-- en una factura pendiente cuando el PDF y el SHA-256 quedan
-- registrados correctamente.
--
-- No sustituye:
--   create_invoice_by_worker()
--   update_invoice_by_worker()
--   set_invoice_rectification_by_worker()
--   register_stripe_invoice_payment()
--
-- ============================================================


-- ============================================================
-- 1. PROTECCIÓN DE BORRADORES Y FACTURAS CON DOCUMENTO OFICIAL
-- ============================================================

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


        IF OLD.estado IN ('pagada', 'vencida', 'cancelada')
           AND v_content_changed
        THEN
            RAISE EXCEPTION
                'Una factura emitida no puede editarse. Debe corregirse mediante una factura rectificativa';
        END IF;


        -- Compatibilidad transitoria con facturas pendientes
        -- antiguas que aún no tienen documento oficial asociado.
        --
        -- Una vez finalizado el documento, la protección anterior
        -- bloquea los cambios de contenido.

    END IF;


    RETURN NEW;

END;
$function$;


DROP TRIGGER IF EXISTS
invoices_guard_draft_and_issued_changes
ON public.invoices;

CREATE TRIGGER
invoices_guard_draft_and_issued_changes
BEFORE UPDATE ON public.invoices
FOR EACH ROW
EXECUTE FUNCTION
public.guard_invoice_draft_and_issued_changes();


-- ============================================================
-- 2. CREAR UN BORRADOR
-- ============================================================
--
-- Reutiliza el generador de números y las validaciones actuales.
-- El número se conserva al guardar y al enviar al cliente.
-- No genera PDF ni SHA-256.
-- ============================================================

CREATE OR REPLACE FUNCTION
public.create_invoice_draft_by_worker(
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
BEGIN

    PERFORM public.require_current_worker_permission(
        'invoices.create'
    );


    -- Reutilizar la función actual de creación:
    -- mantiene validaciones, presupuesto, empresa, proyecto,
    -- snapshot fiscal y generador de números.

    v_invoice := public.create_invoice_by_worker(
        p_company_id,
        p_project_id,
        p_fecha_emision,
        p_fecha_vencimiento,
        p_descripcion,
        p_subtotal,
        CASE
            WHEN COALESCE(p_iva_aplicado, TRUE)
                THEN COALESCE(p_iva_porcentaje, 0)
            ELSE 0
        END,
        p_quotation_id
    );


    -- Autorizar exclusivamente la conversión interna del
    -- registro recién creado en borrador.

    PERFORM set_config(
        'modira.invoice_create_draft',
        'on',
        true
    );


    UPDATE public.invoices
    SET
        estado = 'borrador',

        fecha_emision = COALESCE(
            p_fecha_emision,
            fecha_emision
        ),

        fecha_vencimiento = p_fecha_vencimiento,

        descripcion = NULLIF(
            TRIM(COALESCE(p_descripcion, '')),
            ''
        ),

        subtotal = ROUND(
            COALESCE(p_subtotal, 0),
            2
        ),

        iva_aplicado = COALESCE(
            p_iva_aplicado,
            TRUE
        ),

        iva_porcentaje = CASE
            WHEN COALESCE(p_iva_aplicado, TRUE)
                THEN ROUND(COALESCE(p_iva_porcentaje, 0), 2)
            ELSE 0
        END,

        irpf_aplicado = COALESCE(
            p_irpf_aplicado,
            FALSE
        ),

        irpf_porcentaje = CASE
            WHEN COALESCE(p_irpf_aplicado, FALSE)
                THEN ROUND(COALESCE(p_irpf_porcentaje, 0), 2)
            ELSE 0
        END

    WHERE id = v_invoice.id

    RETURNING *
    INTO v_invoice;


    RETURN v_invoice;

END;
$function$;


-- ============================================================
-- 3. GUARDAR UN BORRADOR EXISTENTE
-- ============================================================
--
-- Solo acepta registros cuyo estado actual sea borrador.
-- Reutiliza update_invoice_by_worker para mantener los cálculos
-- y snapshots fiscales existentes.
--
-- La función de actualización actual exige un estado existente
-- distinto de borrador. Por eso se utiliza un ajuste interno
-- dentro de la misma transacción y el estado final siempre
-- vuelve a borrador.
-- ============================================================

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
        q.project_id
    INTO
        v_quotation_company_id,
        v_quotation_project_id
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


-- ============================================================
-- 4. FINALIZACIÓN DEL DOCUMENTO OFICIAL
-- ============================================================
--
-- Conserva las validaciones actuales:
-- - número de factura y ruta;
-- - PDF existente en Storage;
-- - SHA-256 válido;
-- - protección de aceptaciones;
-- - idempotencia;
-- - prohibición de sobrescribir documentos diferentes.
--
-- NUEVO:
-- Si el registro está en borrador, el estado pasa a pendiente
-- en la misma operación que registra documento_path y SHA-256.
--
-- De esta forma, el cliente no ve la factura como emitida
-- hasta que el documento oficial queda registrado.
-- ============================================================

CREATE OR REPLACE FUNCTION
public.finalize_invoice_backend_document(
    p_invoice_id uuid,
    p_document_path text,
    p_document_sha256 text
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_invoice public.invoices;
    v_hash text;
    v_expected_path text;
BEGIN

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION
            'La factura es obligatoria';
    END IF;


    IF p_document_path IS NULL
       OR TRIM(p_document_path) = ''
    THEN
        RAISE EXCEPTION
            'La ruta del documento es obligatoria';
    END IF;


    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura no existe';
    END IF;


    v_expected_path :=
        v_invoice.numero_factura || '.pdf';


    IF TRIM(p_document_path) <> v_expected_path THEN
        RAISE EXCEPTION
            'La ruta del documento no coincide con la factura';
    END IF;


    IF LOWER(TRIM(p_document_path)) NOT LIKE '%.pdf' THEN
        RAISE EXCEPTION
            'El documento debe ser un PDF';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'invoices'
          AND name = TRIM(p_document_path)
    ) THEN
        RAISE EXCEPTION
            'El PDF no existe en el bucket de facturas';
    END IF;


    v_hash := LOWER(
        TRIM(COALESCE(p_document_sha256, ''))
    );


    IF v_hash = '' THEN
        RAISE EXCEPTION
            'El SHA-256 del documento es obligatorio';
    END IF;


    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION
            'El SHA-256 del documento no es válido';
    END IF;


    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = v_invoice.id
    ) THEN
        RAISE EXCEPTION
            'El documento de esta factura ya ha sido aceptado y no puede modificarse';
    END IF;


    -- Reintento idempotente: si ya se finalizó exactamente
    -- el mismo documento, devolver el registro actual.

    IF v_invoice.document_path = TRIM(p_document_path)
       AND LOWER(COALESCE(v_invoice.document_sha256, '')) = v_hash
    THEN
        RETURN v_invoice;
    END IF;


    IF v_invoice.document_path IS NOT NULL
       AND TRIM(v_invoice.document_path) <> ''
       AND v_invoice.document_path IS DISTINCT FROM TRIM(p_document_path)
    THEN
        RAISE EXCEPTION
            'La factura ya tiene asociado otro documento';
    END IF;


    IF v_invoice.document_sha256 IS NOT NULL
       AND LOWER(TRIM(v_invoice.document_sha256)) IS DISTINCT FROM v_hash
    THEN
        RAISE EXCEPTION
            'La factura ya tiene asociado otro SHA-256';
    END IF;


    -- Autorizar el registro documental y, cuando corresponda,
    -- la transición atómica de borrador a pendiente.

    PERFORM set_config(
        'modira.invoice_finalize',
        'on',
        true
    );


    UPDATE public.invoices
    SET
        document_path = TRIM(p_document_path),
        document_sha256 = v_hash,

        estado = CASE
            WHEN estado = 'borrador' THEN 'pendiente'
            ELSE estado
        END,

        updated_at = CURRENT_TIMESTAMP

    WHERE id = v_invoice.id

    RETURNING *
    INTO v_invoice;


    IF v_invoice.id IS NULL THEN
        RAISE EXCEPTION
            'No se ha podido finalizar el documento de la factura';
    END IF;


    RETURN v_invoice;

END;
$function$;


-- ============================================================
-- 5. LOS CLIENTES NO PUEDEN VER BORRADORES
-- ============================================================

DROP POLICY IF EXISTS
invoices_company_select
ON public.invoices;

CREATE POLICY invoices_company_select
ON public.invoices
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
    AND estado IS DISTINCT FROM 'borrador'
);


-- ============================================================
-- 6. LOS BORRADORES NO SON PAGABLES
-- ============================================================
--
-- Conserva la validación de propietario, proyecto y empresa
-- de la función actual.
-- ============================================================

CREATE OR REPLACE FUNCTION
public.can_user_pay_project_invoice(
    p_invoice_id uuid,
    p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_invoice public.invoices;
    v_project public.projects;
BEGIN

    IF p_user_id IS NULL THEN
        RETURN FALSE;
    END IF;


    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id;


    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;


    IF v_invoice.estado = 'borrador' THEN
        RETURN FALSE;
    END IF;


    IF v_invoice.project_id IS NULL THEN
        RETURN FALSE;
    END IF;


    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = v_invoice.project_id;


    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;


    RETURN
        v_project.user_id = p_user_id
        AND v_project.company_id =
            public.current_user_company_id();

END;
$function$;


-- ============================================================
-- 7. PERMISOS DE LAS NUEVAS FUNCIONES
-- ============================================================

REVOKE ALL ON FUNCTION
public.create_invoice_draft_by_worker(
    uuid,
    uuid,
    uuid,
    timestamptz,
    timestamptz,
    text,
    numeric,
    boolean,
    numeric,
    boolean,
    numeric
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
public.create_invoice_draft_by_worker(
    uuid,
    uuid,
    uuid,
    timestamptz,
    timestamptz,
    text,
    numeric,
    boolean,
    numeric,
    boolean,
    numeric
)
TO authenticated;


REVOKE ALL ON FUNCTION
public.save_invoice_draft_by_worker(
    uuid,
    uuid,
    uuid,
    uuid,
    timestamptz,
    timestamptz,
    text,
    numeric,
    boolean,
    numeric,
    boolean,
    numeric
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
public.save_invoice_draft_by_worker(
    uuid,
    uuid,
    uuid,
    uuid,
    timestamptz,
    timestamptz,
    text,
    numeric,
    boolean,
    numeric,
    boolean,
    numeric
)
TO authenticated;


COMMIT;