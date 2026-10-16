-- ============================================================
-- 088 — MAINTENANCE INVOICE BACKEND DOCUMENTATION
-- ============================================================
--
-- OBJETIVO
--
-- Completar el flujo automático de documentación de las
-- maintenance_invoices generadas por maintenance-stripe.
--
-- Las migraciones 049/050 ya proporcionan:
--   - maintenance_invoices
--   - document_path
--   - document_mime_type
--   - document_file_size
--   - document_sha256
--   - document_uploaded_at
--   - document_uploaded_by
--   - stripe_pdf_storage_path
--   - stripe_pdf_sha256
--   - bucket privado maintenance-invoices
--   - protección de facturas emitidas
--   - exigencia documental al salir de borrador
--
-- La migración 067 ya protege la huella SHA-256 mediante RPC.
--
-- Esta migración NO sustituye:
--   attach_maintenance_invoice_document()
--   set_maintenance_invoice_document_hash()
--
-- Esas funciones continúan siendo el flujo manual del worker.
--
-- Esta nueva RPC queda reservada exclusivamente al backend/service_role
-- utilizado por la Edge Function maintenance-stripe.
--
-- Flujo posterior:
--
--   Stripe invoice.finalized
--          ↓
--   createMaintenanceInvoiceFromStripeInvoice()
--          ↓
--   maintenance_invoices
--          ↓
--   Edge Function genera PDF Modira
--          ↓
--   Storage: maintenance-invoices
--          ↓
--   finalize_maintenance_invoice_backend_document()
--          ↓
--   document_path + metadata + SHA-256
--
-- La factura sigue siendo el mismo registro.
-- Cada ciclo Stripe genera una nueva maintenance_invoice.
--
-- ============================================================

BEGIN;


-- ============================================================
-- 1. COMPROBAR PRERREQUISITOS
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- maintenance_invoices
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: public.maintenance_invoices no existe';
    END IF;


    -- --------------------------------------------------------
    -- document_path
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
      AND column_name = 'document_path';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance_invoices.document_path no existe';
    END IF;


    -- --------------------------------------------------------
    -- document_sha256
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
      AND column_name = 'document_sha256';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance_invoices.document_sha256 no existe';
    END IF;


    -- --------------------------------------------------------
    -- document_mime_type
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
      AND column_name = 'document_mime_type';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance_invoices.document_mime_type no existe';
    END IF;


    -- --------------------------------------------------------
    -- document_file_size
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
      AND column_name = 'document_file_size';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance_invoices.document_file_size no existe';
    END IF;


    -- --------------------------------------------------------
    -- document_uploaded_at
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
      AND column_name = 'document_uploaded_at';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance_invoices.document_uploaded_at no existe';
    END IF;


    -- --------------------------------------------------------
    -- bucket maintenance-invoices
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM storage.buckets
    WHERE id = 'maintenance-invoices';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: bucket maintenance-invoices no existe';
    END IF;


    -- --------------------------------------------------------
    -- stripe_invoice_id
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
      AND column_name = 'stripe_invoice_id';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance_invoices.stripe_invoice_id no existe';
    END IF;


    -- --------------------------------------------------------
    -- índice de idempotencia Stripe
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'idx_maintenance_invoices_stripe_invoice_id';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: índice idx_maintenance_invoices_stripe_invoice_id no existe';
    END IF;

END $$;


-- ============================================================
-- 2. RPC — FINALIZAR DOCUMENTO DE FACTURA DESDE BACKEND
-- ============================================================
--
-- Esta función NO es para workers ni clientes.
--
-- Únicamente puede utilizarla el backend/service_role.
--
-- Responsabilidades:
--
--   1. validar que el llamador sea service_role;
--   2. localizar la factura;
--   3. bloquearla FOR UPDATE;
--   4. validar la ruta documental;
--   5. comprobar que el PDF existe físicamente en Storage;
--   6. comprobar que Storage identifica el archivo como PDF;
--   7. comprobar el tamaño;
--   8. validar SHA-256;
--   9. impedir sustituir un documento ya asociado;
--  10. guardar document_path;
--  11. guardar metadata documental;
--  12. guardar document_sha256;
--  13. registrar document_uploaded_at;
--  14. mantener el proceso idempotente.
--
-- IMPORTANTE:
--
-- La función NO cambia estado.
--
-- La factura puede estar:
--   borrador
--   pendiente
--   impagada
--   pagada
--
-- Esto es deliberado.
--
-- El estado de la factura continúa siendo responsabilidad del flujo
-- Stripe existente:
--
--   invoice.finalized
--   invoice.paid
--   invoice.payment_failed
--   invoice.voided
--
-- La documentación es una operación independiente.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.finalize_maintenance_invoice_backend_document(
    p_invoice_id UUID,
    p_document_path TEXT,
    p_document_sha256 TEXT
)
RETURNS public.maintenance_invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_invoice public.maintenance_invoices;
    v_path TEXT;
    v_hash TEXT;

    v_object_exists BOOLEAN;
    v_object_mime TEXT;
    v_object_size BIGINT;

    v_expected_prefix TEXT;

BEGIN

    -- ========================================================
    -- 1. SOLO BACKEND SERVICE_ROLE
    -- ========================================================

    IF COALESCE(
        current_setting('request.jwt.claim.role', true),
        ''
    ) <> 'service_role'
    THEN
        RAISE EXCEPTION
            'Acceso denegado: esta operación solo puede ejecutarse desde el backend';
    END IF;


    -- ========================================================
    -- 2. VALIDAR INVOICE ID
    -- ========================================================

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION
            'La factura de mantenimiento es obligatoria';
    END IF;


    -- ========================================================
    -- 3. NORMALIZAR RUTA
    -- ========================================================

    v_path := BTRIM(COALESCE(p_document_path, ''));

    IF v_path = '' THEN
        RAISE EXCEPTION
            'La ruta del documento es obligatoria';
    END IF;


    -- ========================================================
    -- 4. NORMALIZAR SHA-256
    -- ========================================================

    v_hash := LOWER(
        BTRIM(
            COALESCE(p_document_sha256, '')
        )
    );

    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION
            'La huella digital del documento no es un SHA-256 válido';
    END IF;


    -- ========================================================
    -- 5. OBTENER Y BLOQUEAR FACTURA
    -- ========================================================

    SELECT *
    INTO v_invoice
    FROM public.maintenance_invoices
    WHERE id = p_invoice_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura de mantenimiento no existe';
    END IF;


    -- ========================================================
    -- 6. VALIDAR RUTA
    -- ========================================================
    --
    -- Todas las facturas automáticas utilizan:
    --
    --   <invoice_uuid>/<archivo>.pdf
    --
    -- Esto evita que el backend pueda asociar accidentalmente
    -- un documento perteneciente a otra factura.
    --
    -- ========================================================

    v_expected_prefix := v_invoice.id::TEXT || '/';

    IF LEFT(v_path, LENGTH(v_expected_prefix))
       <> v_expected_prefix
    THEN
        RAISE EXCEPTION
            'La ruta del documento no pertenece a la factura';
    END IF;


    IF v_path = v_expected_prefix THEN
        RAISE EXCEPTION
            'La ruta del documento no contiene un nombre de archivo válido';
    END IF;


    IF v_path LIKE '%..%' THEN
        RAISE EXCEPTION
            'La ruta del documento contiene una secuencia no permitida';
    END IF;


    IF LEFT(v_path, 1) = '/' THEN
        RAISE EXCEPTION
            'La ruta del documento no puede comenzar por /';
    END IF;


    IF RIGHT(LOWER(v_path), 4) <> '.pdf' THEN
        RAISE EXCEPTION
            'El documento de una factura de mantenimiento debe ser un PDF';
    END IF;


    -- No permitimos subcarpetas adicionales.
    IF ARRAY_LENGTH(string_to_array(v_path, '/'), 1) <> 2 THEN
        RAISE EXCEPTION
            'La ruta del documento de la factura no es válida';
    END IF;


    -- ========================================================
    -- 7. DOCUMENTO YA ASOCIADO
    -- ========================================================
    --
    -- Una factura emitida no puede cambiar de documento.
    --
    -- Si el mismo proceso vuelve a ejecutarse con exactamente
    -- el mismo documento y hash, devolvemos la factura.
    --
    -- Esto hace que el proceso sea idempotente.
    --
    -- ========================================================

    IF v_invoice.document_path IS NOT NULL THEN

        IF v_invoice.document_path <> v_path THEN
            RAISE EXCEPTION
                'La factura ya tiene un documento asociado diferente; no se permite sustituirlo';
        END IF;


        IF v_invoice.document_sha256 IS NOT NULL
           AND LOWER(v_invoice.document_sha256) <> v_hash
        THEN
            RAISE EXCEPTION
                'La factura ya tiene una huella SHA-256 diferente; no se permite sustituirla';
        END IF;

    END IF;


    -- ========================================================
    -- 8. COMPROBAR OBJETO FÍSICO EN STORAGE
    -- ========================================================

    SELECT
        TRUE,
        COALESCE(
            NULLIF(o.metadata ->> 'mimetype', ''),
            NULLIF(o.metadata ->> 'mimeType', '')
        ),
        CASE
            WHEN COALESCE(o.metadata ->> 'size', '') ~ '^[0-9]+$'
            THEN (o.metadata ->> 'size')::BIGINT
            ELSE NULL
        END
    INTO
        v_object_exists,
        v_object_mime,
        v_object_size
    FROM storage.objects o
    WHERE o.bucket_id = 'maintenance-invoices'
      AND o.name = v_path
    LIMIT 1;


    IF NOT COALESCE(v_object_exists, FALSE) THEN
        RAISE EXCEPTION
            'El documento no existe físicamente en el bucket maintenance-invoices';
    END IF;


    -- ========================================================
    -- 9. VALIDAR MIME
    -- ========================================================

    IF v_object_mime IS NOT NULL
       AND LOWER(BTRIM(v_object_mime)) <> 'application/pdf'
    THEN
        RAISE EXCEPTION
            'El documento almacenado no es un PDF válido';
    END IF;


    -- ========================================================
    -- 10. VALIDAR TAMAÑO
    -- ========================================================
    --
    -- Máximo 20 MiB, alineado con la política documental
    -- existente del proyecto.
    --
    -- Si Storage no proporciona size en metadata, no inventamos
    -- un valor: la Edge Function continuará registrando el tamaño
    -- real mediante la metadata que le pase el Storage.
    --
    -- ========================================================

    IF v_object_size IS NOT NULL THEN

        IF v_object_size <= 0 THEN
            RAISE EXCEPTION
                'El PDF de la factura está vacío';
        END IF;


        IF v_object_size > 20 * 1024 * 1024 THEN
            RAISE EXCEPTION
                'El PDF de la factura supera el límite de 20 MiB';
        END IF;

    END IF;


    -- ========================================================
    -- 11. ASOCIAR DOCUMENTO + HASH
    -- ========================================================
    --
    -- El SHA-256 es calculado por la Edge Function sobre los bytes
    -- reales del PDF antes de llegar aquí.
    --
    -- La función SQL valida el formato y lo conserva como parte
    -- del registro documental.
    --
    -- No se modifica:
    --   - datos fiscales
    --   - importes
    --   - contrato
    --   - período
    --   - número
    --   - estado
    --
    -- Por tanto, no interfiere con la inmutabilidad existente.
    --
    -- ========================================================

    UPDATE public.maintenance_invoices
    SET
        document_path = v_path,
        document_mime_type = 'application/pdf',
        document_file_size = v_object_size,
        document_sha256 = v_hash,
        document_uploaded_at = COALESCE(
            document_uploaded_at,
            CURRENT_TIMESTAMP
        ),
        document_uploaded_by = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_invoice.id
    RETURNING *
    INTO v_invoice;


    -- ========================================================
    -- 12. DEVOLVER FACTURA ACTUALIZADA
    -- ========================================================

    RETURN v_invoice;

END;
$function$;


-- ============================================================
-- 3. SEGURIDAD DE LA RPC
-- ============================================================
--
-- Nadie excepto service_role puede ejecutarla.
--
-- No se concede EXECUTE a:
--   PUBLIC
--   anon
--   authenticated
--
-- El worker continuará utilizando las RPC existentes.
--
-- ============================================================

REVOKE ALL
ON FUNCTION public.finalize_maintenance_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.finalize_maintenance_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
TO service_role;


ALTER FUNCTION public.finalize_maintenance_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
SET search_path = public, pg_temp;


-- ============================================================
-- 4. DOCUMENTACIÓN
-- ============================================================

COMMENT ON FUNCTION public.finalize_maintenance_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
IS
'Asocia de forma segura el PDF de Modira y su SHA-256 a una maintenance_invoice desde el backend service_role. Valida pertenencia de la ruta, existencia física en Storage, PDF, tamaño e idempotencia. No modifica el estado de la factura ni sustituye las RPC existentes de workers.';


-- ============================================================
-- 5. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- La función debe existir exactamente una vez.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname =
          'finalize_maintenance_invoice_backend_document'
      AND pg_get_function_identity_arguments(p.oid) =
          'p_invoice_id uuid, p_document_path text, p_document_sha256 text';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: finalize_maintenance_invoice_backend_document() no existe exactamente una vez';
    END IF;


    -- --------------------------------------------------------
    -- Debe existir el bucket.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM storage.buckets
    WHERE id = 'maintenance-invoices';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance-invoices bucket missing';
    END IF;


    -- --------------------------------------------------------
    -- Debe continuar existiendo el índice Stripe.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname =
          'idx_maintenance_invoices_stripe_invoice_id';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: Stripe invoice idempotency index missing';
    END IF;


    -- --------------------------------------------------------
    -- Debe continuar existiendo el trigger documental.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid =
          'public.maintenance_invoices'::regclass
      AND tgname =
          'maintenance_invoices_require_document'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance_invoices_require_document trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- Debe continuar existiendo la protección de inmutabilidad.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid =
          'public.maintenance_invoices'::regclass
      AND tgname =
          'maintenance_invoices_protect_issued_data'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '088 failed: maintenance_invoices_protect_issued_data trigger missing';
    END IF;

END $$;


-- ============================================================
-- 6. RECARGAR ESQUEMA POSTGREST
-- ============================================================

NOTIFY pgrst, 'reload schema';


COMMIT;