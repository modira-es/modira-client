-- ============================================================
-- 071_invoice_accepted_immutability_and_backend_document.sql
-- ============================================================
--
-- OBJETIVO
-- ------------------------------------------------------------
-- 1. Proteger los datos esenciales de una factura después de
--    que el cliente haya registrado la aceptación documental.
--
-- 2. Permitir todavía los cambios legítimos derivados del pago:
--      - estado
--      - fecha_pago
--      - stripe_invoice_id
--      - updated_at
--
-- 3. Crear una RPC exclusiva de backend para registrar el PDF
--    oficial generado server-side junto con su SHA-256.
--
-- IMPORTANTE
-- ------------------------------------------------------------
-- Esta migración NO modifica:
--   - create_invoice_by_worker()
--   - update_invoice_by_worker()
--   - delete_invoice_by_worker()
--   - Stripe
--   - register_stripe_invoice_payment()
--   - acknowledgement documental
--   - RLS existente
--   - Storage policies existentes
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. FUNCIÓN DE INMUTABILIDAD DE FACTURAS ACEPTADAS
-- ============================================================
--
-- Una factura aceptada documentalmente no puede cambiar en sus
-- datos fiscales, económicos, identidad o documento.
--
-- SÍ se permiten cambios operativos posteriores relacionados
-- con el pago.
--
-- Esto es deliberado para no romper:
--
--   cliente acepta PDF
--        ↓
--   Stripe
--        ↓
--   register_stripe_invoice_payment()
--        ↓
--   estado = pagada
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_accepted_invoice_data()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    -- ========================================================
    -- 1. COMPROBAR SI EXISTE ACEPTACIÓN DOCUMENTAL
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = OLD.id
    ) THEN

        -- ====================================================
        -- 2. DATOS DE IDENTIDAD / RELACIONES
        -- ====================================================

        IF NEW.user_id IS DISTINCT FROM OLD.user_id
           OR NEW.company_id IS DISTINCT FROM OLD.company_id
           OR NEW.project_id IS DISTINCT FROM OLD.project_id
           OR NEW.client_id IS DISTINCT FROM OLD.client_id
           OR NEW.quotation_id IS DISTINCT FROM OLD.quotation_id
        THEN

            RAISE EXCEPTION
                'La factura está bloqueada porque el cliente ya ha aceptado su documento';

        END IF;


        -- ====================================================
        -- 3. IDENTIDAD FISCAL / NUMERACIÓN
        -- ====================================================

        IF NEW.numero_factura IS DISTINCT FROM OLD.numero_factura
        THEN

            RAISE EXCEPTION
                'No se puede modificar el número de una factura aceptada';

        END IF;


        -- ====================================================
        -- 4. FECHA DE EMISIÓN / VENCIMIENTO
        -- ====================================================

        IF NEW.fecha_emision IS DISTINCT FROM OLD.fecha_emision
           OR NEW.fecha_vencimiento IS DISTINCT FROM OLD.fecha_vencimiento
        THEN

            RAISE EXCEPTION
                'No se pueden modificar las fechas fiscales de una factura aceptada';

        END IF;


        -- ====================================================
        -- 5. DESCRIPCIÓN
        -- ====================================================

        IF NEW.descripcion IS DISTINCT FROM OLD.descripcion
        THEN

            RAISE EXCEPTION
                'No se puede modificar la descripción de una factura aceptada';

        END IF;


        -- ====================================================
        -- 6. DATOS ECONÓMICOS
        -- ====================================================

        IF NEW.monto IS DISTINCT FROM OLD.monto
           OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
           OR NEW.iva_aplicado IS DISTINCT FROM OLD.iva_aplicado
           OR NEW.iva_porcentaje IS DISTINCT FROM OLD.iva_porcentaje
           OR NEW.iva_importe IS DISTINCT FROM OLD.iva_importe
           OR NEW.irpf_aplicado IS DISTINCT FROM OLD.irpf_aplicado
           OR NEW.irpf_porcentaje IS DISTINCT FROM OLD.irpf_porcentaje
           OR NEW.irpf_importe IS DISTINCT FROM OLD.irpf_importe
           OR NEW.importe_a_pagar IS DISTINCT FROM OLD.importe_a_pagar
        THEN

            RAISE EXCEPTION
                'No se pueden modificar los importes fiscales o económicos de una factura aceptada';

        END IF;


        -- ====================================================
        -- 7. SNAPSHOT FISCAL DEL EMISOR
        -- ====================================================

        IF NEW.issuer_legal_name IS DISTINCT FROM OLD.issuer_legal_name
           OR NEW.issuer_tax_id IS DISTINCT FROM OLD.issuer_tax_id
           OR NEW.issuer_address IS DISTINCT FROM OLD.issuer_address
           OR NEW.issuer_postal_code IS DISTINCT FROM OLD.issuer_postal_code
           OR NEW.issuer_city IS DISTINCT FROM OLD.issuer_city
           OR NEW.issuer_province IS DISTINCT FROM OLD.issuer_province
           OR NEW.issuer_country IS DISTINCT FROM OLD.issuer_country
        THEN

            RAISE EXCEPTION
                'No se pueden modificar los datos fiscales del emisor de una factura aceptada';

        END IF;


        -- ====================================================
        -- 8. SNAPSHOT FISCAL DEL CLIENTE
        -- ====================================================

        IF NEW.customer_legal_name IS DISTINCT FROM OLD.customer_legal_name
           OR NEW.customer_tax_id IS DISTINCT FROM OLD.customer_tax_id
           OR NEW.customer_address IS DISTINCT FROM OLD.customer_address
           OR NEW.customer_postal_code IS DISTINCT FROM OLD.customer_postal_code
           OR NEW.customer_city IS DISTINCT FROM OLD.customer_city
           OR NEW.customer_province IS DISTINCT FROM OLD.customer_province
           OR NEW.customer_country IS DISTINCT FROM OLD.customer_country
           OR NEW.customer_contact_name IS DISTINCT FROM OLD.customer_contact_name
        THEN

            RAISE EXCEPTION
                'No se pueden modificar los datos fiscales del cliente de una factura aceptada';

        END IF;


        -- ====================================================
        -- 9. RECTIFICACIÓN
        -- ====================================================
        --
        -- Una factura aceptada tampoco puede convertirse
        -- posteriormente en otra factura rectificadora.
        --
        -- La rectificadora siempre será una NUEVA factura.
        --
        -- ====================================================

        IF NEW.rectifies_invoice_id IS DISTINCT FROM OLD.rectifies_invoice_id
           OR NEW.rectification_reason IS DISTINCT FROM OLD.rectification_reason
        THEN

            RAISE EXCEPTION
                'No se puede modificar la rectificación de una factura aceptada';

        END IF;


        -- ====================================================
        -- 10. DOCUMENTO
        -- ====================================================
        --
        -- La protección documental ya existe mediante 057,
        -- pero también la protegemos a nivel de fila.
        --
        -- Esto evita que una actualización SQL directa pueda
        -- cambiar el PDF/hash de una factura aceptada.
        --
        -- ====================================================

        IF NEW.document_path IS DISTINCT FROM OLD.document_path
           OR NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256
        THEN

            RAISE EXCEPTION
                'No se puede modificar el documento de una factura aceptada';

        END IF;

    END IF;


    RETURN NEW;

END;
$function$;


-- ============================================================
-- 2. TRIGGER DE INMUTABILIDAD
-- ============================================================
--
-- BEFORE UPDATE:
--
--   - si no está aceptada -> comportamiento normal
--   - si está aceptada -> protect_accepted_invoice_data()
--
-- No se ejecuta en INSERT.
--
-- ============================================================

DROP TRIGGER IF EXISTS
    invoices_protect_accepted_data
ON public.invoices;


CREATE TRIGGER invoices_protect_accepted_data
BEFORE UPDATE
ON public.invoices
FOR EACH ROW
EXECUTE FUNCTION public.protect_accepted_invoice_data();


-- ============================================================
-- 3. RPC BACKEND PARA FINALIZAR EL DOCUMENTO OFICIAL
-- ============================================================
--
-- Esta función será utilizada posteriormente por la Edge
-- Function que genere automáticamente el PDF oficial.
--
-- Flujo futuro:
--
--   Edge Function
--       ↓
--   genera PDF
--       ↓
--   Storage privado /invoices
--       ↓
--   calcula SHA-256 real
--       ↓
--   finalize_invoice_backend_document()
--       ↓
--   invoices.document_path
--   invoices.document_sha256
--
-- Esta RPC NO genera el PDF.
-- Solo registra de forma segura el documento ya generado.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.finalize_invoice_backend_document(
    p_invoice_id UUID,
    p_document_path TEXT,
    p_document_sha256 TEXT
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_invoice public.invoices;
    v_hash TEXT;
    v_expected_path TEXT;

BEGIN

    -- ========================================================
    -- 1. VALIDAR IDENTIFICADOR
    -- ========================================================

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION
            'La factura es obligatoria';
    END IF;


    -- ========================================================
    -- 2. VALIDAR RUTA
    -- ========================================================

    IF p_document_path IS NULL
       OR TRIM(p_document_path) = ''
    THEN

        RAISE EXCEPTION
            'La ruta del documento es obligatoria';

    END IF;


    -- ========================================================
    -- 3. OBTENER FACTURA
    -- ========================================================

    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id
    FOR UPDATE;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'La factura no existe';

    END IF;


    -- ========================================================
    -- 4. RUTA OFICIAL ESPERADA
    -- ========================================================
    --
    -- Se mantiene la convención que ya utiliza 057:
    --
    --     numero_factura.pdf
    --
    -- Esto mantiene compatibilidad con el Storage actual y
    -- con invoice_document_storage_is_locked().
    --
    -- ========================================================

    v_expected_path :=
        v_invoice.numero_factura
        || '.pdf';


    IF TRIM(p_document_path) <> v_expected_path THEN

        RAISE EXCEPTION
            'La ruta del documento no coincide con la factura';

    END IF;


    -- ========================================================
    -- 5. VALIDAR EXTENSIÓN
    -- ========================================================

    IF LOWER(TRIM(p_document_path)) NOT LIKE '%.pdf' THEN

        RAISE EXCEPTION
            'El documento debe ser un PDF';

    END IF;


    -- ========================================================
    -- 6. COMPROBAR EXISTENCIA REAL EN STORAGE
    -- ========================================================
    --
    -- La Edge Function debe haber generado previamente el
    -- archivo en el bucket privado "invoices".
    --
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'invoices'
          AND name = TRIM(p_document_path)
    ) THEN

        RAISE EXCEPTION
            'El PDF no existe en el bucket de facturas';

    END IF;


    -- ========================================================
    -- 7. VALIDAR SHA-256
    -- ========================================================

    v_hash := LOWER(
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


    -- ========================================================
    -- 8. NO PERMITIR CAMBIAR DOCUMENTO DESPUÉS DE ACEPTACIÓN
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = v_invoice.id
    ) THEN

        RAISE EXCEPTION
            'El documento de esta factura ya ha sido aceptado y no puede modificarse';

    END IF;


    -- ========================================================
    -- 9. IDEMPOTENCIA
    -- ========================================================
    --
    -- Si la Edge Function reintenta exactamente el mismo
    -- documento + hash, devolvemos la factura sin modificarla.
    --
    -- Esto es importante para evitar duplicaciones en reintentos.
    --
    -- ========================================================

    IF v_invoice.document_path = TRIM(p_document_path)
       AND LOWER(
            COALESCE(v_invoice.document_sha256, '')
           ) = v_hash
    THEN

        RETURN v_invoice;

    END IF;


    -- ========================================================
    -- 10. NO SOBRESCRIBIR UN DOCUMENTO DIFERENTE
    -- ========================================================
    --
    -- Si ya existe otro PDF/hash asociado y no coincide con el
    -- nuevo documento, se rechaza.
    --
    -- La generación automática deberá ser idempotente.
    --
    -- ========================================================

    IF v_invoice.document_path IS NOT NULL
       AND TRIM(v_invoice.document_path) <> ''
       AND v_invoice.document_path IS DISTINCT FROM
           TRIM(p_document_path)
    THEN

        RAISE EXCEPTION
            'La factura ya tiene asociado otro documento';

    END IF;


    IF v_invoice.document_sha256 IS NOT NULL
       AND LOWER(TRIM(v_invoice.document_sha256)) IS DISTINCT FROM
           v_hash
    THEN

        RAISE EXCEPTION
            'La factura ya tiene asociado otro SHA-256';

    END IF;


    -- ========================================================
    -- 11. GUARDAR DOCUMENTO + HASH
    -- ========================================================

    UPDATE public.invoices
    SET
        document_path = TRIM(p_document_path),
        document_sha256 = v_hash,
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
-- 4. SEGURIDAD DE LA RPC BACKEND
-- ============================================================
--
-- IMPORTANTE:
--
-- Esta RPC NO se expone al cliente autenticado.
--
-- La utilizará posteriormente la Edge Function mediante
-- service_role.
--
-- ============================================================

REVOKE ALL
ON FUNCTION public.finalize_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.finalize_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
FROM anon;

REVOKE ALL
ON FUNCTION public.finalize_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
FROM authenticated;

GRANT EXECUTE
ON FUNCTION public.finalize_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
TO service_role;


-- ============================================================
-- 5. COMENTARIOS
-- ============================================================

COMMENT ON FUNCTION public.protect_accepted_invoice_data()
IS
'Protege los datos fiscales, económicos, identidad y documento de una factura después de su aceptación documental. Permite únicamente cambios operativos de pago.';


COMMENT ON FUNCTION public.finalize_invoice_backend_document(UUID, TEXT, TEXT)
IS
'Registra de forma idempotente el PDF oficial generado server-side para una factura y su SHA-256. Exclusivo para service_role.';


-- ============================================================
-- 6. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Trigger
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.invoices'::regclass
      AND tgname = 'invoices_protect_accepted_data'
      AND NOT tgisinternal;


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '071 verification failed: accepted invoice protection trigger missing';

    END IF;


    -- --------------------------------------------------------
    -- Función de protección
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'protect_accepted_invoice_data'
      AND pg_get_function_identity_arguments(p.oid) = '';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '071 verification failed: protect_accepted_invoice_data() missing';

    END IF;


    -- --------------------------------------------------------
    -- RPC backend
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'finalize_invoice_backend_document'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_invoice_id uuid, p_document_path text, p_document_sha256 text';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '071 verification failed: finalize_invoice_backend_document() missing';

    END IF;


    -- --------------------------------------------------------
    -- RPC debe ser SECURITY DEFINER
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'finalize_invoice_backend_document'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_invoice_id uuid, p_document_path text, p_document_sha256 text'
      AND p.prosecdef = TRUE;


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '071 verification failed: backend document RPC must be SECURITY DEFINER';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO debe ejecutar la RPC
    -- --------------------------------------------------------

    IF has_function_privilege(
        'authenticated',
        'public.finalize_invoice_backend_document(uuid,text,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '071 verification failed: authenticated must NOT have EXECUTE on backend document RPC';

    END IF;


    -- --------------------------------------------------------
    -- anon NO debe ejecutar la RPC
    -- --------------------------------------------------------

    IF has_function_privilege(
        'anon',
        'public.finalize_invoice_backend_document(uuid,text,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '071 verification failed: anon must NOT have EXECUTE on backend document RPC';

    END IF;


    -- --------------------------------------------------------
    -- service_role sí debe poder ejecutar la RPC
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'service_role',
        'public.finalize_invoice_backend_document(uuid,text,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '071 verification failed: service_role must have EXECUTE on backend document RPC';

    END IF;


    RAISE NOTICE
        '071 completed successfully: accepted invoice immutability and backend document finalization are ready.';

END $$;


COMMIT;