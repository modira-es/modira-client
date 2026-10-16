BEGIN;

-- ============================================================
-- 1. ORIGEN DE LOS DATOS FISCALES DE LA RECTIFICATIVA
-- ============================================================
-- original_invoice:
--   Conserva los datos fiscales del destinatario de la factura
--   original.
--
-- current_company:
--   Recupera los datos fiscales actuales del destinatario desde
--   public.clients.
--
-- Los campos issuer_* no se modifican en esta operación.
-- ============================================================

ALTER TABLE public.invoices
    ADD COLUMN IF NOT EXISTS rectification_customer_data_source TEXT
    NOT NULL DEFAULT 'original_invoice';


ALTER TABLE public.invoices
    DROP CONSTRAINT IF EXISTS
        invoices_rectification_customer_data_source_check;


ALTER TABLE public.invoices
    ADD CONSTRAINT
        invoices_rectification_customer_data_source_check
    CHECK (
        rectification_customer_data_source IN (
            'original_invoice',
            'current_company'
        )
    );


-- ============================================================
-- 2. REEMPLAZAR LA RPC DE RECTIFICACIÓN
-- ============================================================
-- Se elimina la firma anterior para evitar que PostgreSQL
-- mantenga dos versiones ambiguas de la función.
--
-- El cuarto parámetro tiene un valor predeterminado, por lo
-- que las llamadas anteriores con tres parámetros seguirán
-- siendo compatibles.
-- ============================================================

DROP FUNCTION IF EXISTS public.set_invoice_rectification_by_worker(
    UUID,
    UUID,
    TEXT
);


CREATE OR REPLACE FUNCTION public.set_invoice_rectification_by_worker(
    p_invoice_id UUID,
    p_rectifies_invoice_id UUID,
    p_rectification_reason TEXT,
    p_rectification_customer_data_source TEXT DEFAULT 'original_invoice'
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_invoice public.invoices;
    v_original public.invoices;

    v_can_create BOOLEAN := FALSE;
    v_can_update BOOLEAN := FALSE;

    v_reason TEXT;
    v_customer_data_source TEXT;

    v_customer_legal_name TEXT;
    v_customer_tax_id TEXT;
    v_customer_address TEXT;
    v_customer_postal_code TEXT;
    v_customer_city TEXT;
    v_customer_province TEXT;
    v_customer_country TEXT;
    v_customer_contact_name TEXT;

    v_client_company_id UUID;

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN Y PERMISOS
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    SELECT COALESCE(
        public.current_worker_has_permission('invoices.create'),
        FALSE
    )
    INTO v_can_create;


    SELECT COALESCE(
        public.current_worker_has_permission('invoices.update'),
        FALSE
    )
    INTO v_can_update;


    IF NOT v_can_create AND NOT v_can_update THEN
        RAISE EXCEPTION
            'No tienes permiso para gestionar rectificaciones de facturas';
    END IF;


    -- ========================================================
    -- 2. BLOQUEAR LA FACTURA QUE SE QUIERE RECTIFICAR
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


    -- No se permite modificar una factura cuya aceptación
    -- documental ya esté registrada.

    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = v_invoice.id
    ) THEN
        RAISE EXCEPTION
            'La factura ya tiene una aceptación documental y sus datos no pueden modificarse';
    END IF;


    -- No se debe cambiar la rectificación de un documento
    -- oficial ya generado. Primero debe existir un flujo
    -- explícito de corrección del documento.

    IF (
        v_invoice.document_path IS NOT NULL
        OR v_invoice.document_sha256 IS NOT NULL
    )
    AND (
        v_invoice.rectifies_invoice_id
            IS DISTINCT FROM p_rectifies_invoice_id
        OR v_invoice.rectification_reason
            IS DISTINCT FROM NULLIF(
                TRIM(COALESCE(p_rectification_reason, '')),
                ''
            )
        OR v_invoice.rectification_customer_data_source
            IS DISTINCT FROM COALESCE(
                NULLIF(
                    TRIM(p_rectification_customer_data_source),
                    ''
                ),
                'original_invoice'
            )
    ) THEN
        RAISE EXCEPTION
            'La factura ya tiene un documento oficial. No se puede modificar su rectificación sin un procedimiento explícito de nueva emisión';
    END IF;


    -- ========================================================
    -- 3. VALIDAR EL ORIGEN DE LOS DATOS FISCALES
    -- ========================================================

    v_customer_data_source := COALESCE(
        NULLIF(
            TRIM(p_rectification_customer_data_source),
            ''
        ),
        'original_invoice'
    );


    IF v_customer_data_source NOT IN (
        'original_invoice',
        'current_company'
    ) THEN
        RAISE EXCEPTION
            'El origen de los datos fiscales debe ser original_invoice o current_company';
    END IF;


    -- ========================================================
    -- 4. ELIMINAR LA RELACIÓN DE RECTIFICACIÓN
    -- ========================================================
    -- Si no se selecciona una factura original, se limpia
    -- también el motivo y se restaura el origen predeterminado.
    -- ========================================================

    IF p_rectifies_invoice_id IS NULL THEN

        UPDATE public.invoices
        SET
            rectifies_invoice_id = NULL,
            rectification_reason = NULL,
            rectification_customer_data_source = 'original_invoice'
        WHERE id = v_invoice.id
        RETURNING *
        INTO v_invoice;

        RETURN v_invoice;

    END IF;


    -- ========================================================
    -- 5. VALIDAR EL MOTIVO
    -- ========================================================

    IF p_rectifies_invoice_id = p_invoice_id THEN
        RAISE EXCEPTION
            'Una factura no puede rectificarse a sí misma';
    END IF;


    v_reason := TRIM(
        COALESCE(p_rectification_reason, '')
    );


    IF v_reason = '' THEN
        RAISE EXCEPTION
            'El motivo de rectificación es obligatorio';
    END IF;


    IF LENGTH(v_reason) > 2000 THEN
        RAISE EXCEPTION
            'El motivo de rectificación no puede superar 2000 caracteres';
    END IF;


    -- ========================================================
    -- 6. VALIDAR LA FACTURA ORIGINAL
    -- ========================================================

    SELECT *
    INTO v_original
    FROM public.invoices
    WHERE id = p_rectifies_invoice_id
    FOR SHARE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura original que se quiere rectificar no existe';
    END IF;


    IF v_original.company_id
        IS DISTINCT FROM v_invoice.company_id
    THEN
        RAISE EXCEPTION
            'La factura original debe pertenecer a la misma empresa';
    END IF;


    IF v_original.rectifies_invoice_id IS NOT NULL THEN
        RAISE EXCEPTION
            'La factura original seleccionada ya es una factura rectificativa';
    END IF;


    -- ========================================================
    -- 7. CONSERVAR LOS DATOS FISCALES ORIGINALES
    -- ========================================================
    -- Por defecto, la rectificativa utiliza exactamente los
    -- datos del destinatario guardados en la factura original.
    -- No se consulta ni modifica public.companies.
    -- ========================================================

    v_customer_legal_name :=
        v_original.customer_legal_name;

    v_customer_tax_id :=
        v_original.customer_tax_id;

    v_customer_address :=
        v_original.customer_address;

    v_customer_postal_code :=
        v_original.customer_postal_code;

    v_customer_city :=
        v_original.customer_city;

    v_customer_province :=
        v_original.customer_province;

    v_customer_country :=
        v_original.customer_country;

    v_customer_contact_name :=
        v_original.customer_contact_name;


    -- ========================================================
    -- 8. DATOS FISCALES ACTUALES DEL DESTINATARIO
    -- ========================================================
    -- Opción B:
    --
    -- current_company consulta el cliente asociado a la factura
    -- original en public.clients.
    --
    -- No se copian datos de public.companies a customer_*,
    -- porque esos datos pertenecen al emisor.
    -- ========================================================

    IF v_customer_data_source = 'current_company' THEN

        IF v_original.client_id IS NULL THEN
            RAISE EXCEPTION
                'La factura original no tiene un cliente asociado. No se pueden recuperar sus datos fiscales actuales';
        END IF;


        SELECT
            c.company_id,

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
            v_client_company_id,
            v_customer_legal_name,
            v_customer_tax_id,
            v_customer_address,
            v_customer_postal_code,
            v_customer_city,
            v_customer_province,
            v_customer_country,
            v_customer_contact_name

        FROM public.clients c

        WHERE c.id = v_original.client_id;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'No se encuentra el cliente asociado a la factura original';
        END IF;


        IF v_client_company_id
            IS DISTINCT FROM v_original.company_id
        THEN
            RAISE EXCEPTION
                'El cliente de la factura original no pertenece a la empresa correspondiente';
        END IF;


        -- Evitamos emitir una rectificativa con datos fiscales
        -- actuales incompletos.

        IF NULLIF(TRIM(COALESCE(v_customer_legal_name, '')), '') IS NULL
           OR NULLIF(TRIM(COALESCE(v_customer_tax_id, '')), '') IS NULL
           OR NULLIF(TRIM(COALESCE(v_customer_address, '')), '') IS NULL
           OR NULLIF(TRIM(COALESCE(v_customer_postal_code, '')), '') IS NULL
           OR NULLIF(TRIM(COALESCE(v_customer_city, '')), '') IS NULL
           OR NULLIF(TRIM(COALESCE(v_customer_country, '')), '') IS NULL
        THEN
            RAISE EXCEPTION
                'El cliente no tiene todos los datos fiscales actuales obligatorios';
        END IF;

    END IF;


    -- ========================================================
    -- 9. GUARDAR LA RECTIFICACIÓN Y EL SNAPSHOT DEL DESTINATARIO
    -- ========================================================
    -- Solo se actualiza la factura rectificativa.
    --
    -- La factura original permanece intacta.
    -- Los campos issuer_* permanecen intactos.
    -- ========================================================

    UPDATE public.invoices

    SET
        rectifies_invoice_id =
            p_rectifies_invoice_id,

        rectification_reason =
            v_reason,

        rectification_customer_data_source =
            v_customer_data_source,

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
            v_customer_contact_name

    WHERE id = v_invoice.id

    RETURNING *
    INTO v_invoice;


    RETURN v_invoice;

END;

$function$;


-- ============================================================
-- 3. PERMISOS DE EJECUCIÓN
-- ============================================================

REVOKE ALL
ON FUNCTION public.set_invoice_rectification_by_worker(
    UUID,
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.set_invoice_rectification_by_worker(
    UUID,
    UUID,
    TEXT,
    TEXT
)
TO authenticated;


-- ============================================================
-- 4. VALIDACIÓN DE LA MIGRACIÓN
-- ============================================================

DO $$
DECLARE
    v_column_exists BOOLEAN;
    v_function_exists BOOLEAN;
BEGIN

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'invoices'
          AND column_name = 'rectification_customer_data_source'
    )
    INTO v_column_exists;


    IF NOT v_column_exists THEN
        RAISE EXCEPTION
            'Migración fallida: falta rectification_customer_data_source';
    END IF;


    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_invoice_rectification_by_worker'
          AND pg_get_function_identity_arguments(p.oid)
              = 'p_invoice_id uuid, p_rectifies_invoice_id uuid, p_rectification_reason text, p_rectification_customer_data_source text'
    )
    INTO v_function_exists;


    IF NOT v_function_exists THEN
        RAISE EXCEPTION
            'Migración fallida: la función de rectificación no tiene la nueva firma';
    END IF;

END;
$$;

GRANT SELECT ON TABLE public.clients TO service_role;
COMMIT;