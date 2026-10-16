BEGIN;

-- ============================================================
-- MODIRA — FIX BACKEND DOCUMENT FINALIZATION SECURITY
-- ============================================================
--
-- La RPC ya está protegida mediante EXECUTE:
--   service_role -> permitido
--   postgres     -> permitido
--   anon         -> denegado
--   authenticated -> denegado
--
-- Se elimina únicamente la comprobación de
-- request.jwt.claim.role porque está provocando falsos
-- rechazos desde la Edge Function.
--
-- NO se modifica ninguna validación documental.
-- ============================================================


CREATE OR REPLACE FUNCTION public.finalize_maintenance_invoice_backend_document(
    p_invoice_id UUID,
    p_document_path TEXT,
    p_document_sha256 TEXT
)
RETURNS public.maintenance_invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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
    -- 1. VALIDAR INVOICE ID
    -- ========================================================

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION
            'La factura de mantenimiento es obligatoria';
    END IF;


    -- ========================================================
    -- 2. NORMALIZAR RUTA
    -- ========================================================

    v_path := BTRIM(COALESCE(p_document_path, ''));

    IF v_path = '' THEN
        RAISE EXCEPTION
            'La ruta del documento es obligatoria';
    END IF;


    -- ========================================================
    -- 3. NORMALIZAR SHA-256
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
    -- 4. OBTENER Y BLOQUEAR FACTURA
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
    -- 5. VALIDAR RUTA
    -- ========================================================
    --
    -- Todas las facturas automáticas utilizan:
    --
    --   <invoice_uuid>/<archivo>.pdf
    --
    -- Esto evita que el backend pueda asociar accidentalmente
    -- un documento perteneciente a otra factura.
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
    -- 6. DOCUMENTO YA ASOCIADO
    -- ========================================================
    --
    -- Una factura emitida no puede cambiar de documento.
    --
    -- Si el mismo proceso vuelve a ejecutarse con exactamente
    -- el mismo documento y hash, devolvemos la factura.
    --
    -- Esto hace que el proceso sea idempotente.
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
    -- 7. COMPROBAR OBJETO FÍSICO EN STORAGE
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
    -- 8. VALIDAR MIME
    -- ========================================================

    IF v_object_mime IS NOT NULL
       AND LOWER(BTRIM(v_object_mime)) <> 'application/pdf'
    THEN
        RAISE EXCEPTION
            'El documento almacenado no es un PDF válido';
    END IF;


    -- ========================================================
    -- 9. VALIDAR TAMAÑO
    -- ========================================================
    --
    -- Máximo 20 MiB.
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
    -- 10. ASOCIAR DOCUMENTO + HASH
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
    -- 11. DEVOLVER FACTURA ACTUALIZADA
    -- ========================================================

    RETURN v_invoice;

END;
$function$;


-- ============================================================
-- PERMISOS
-- ============================================================
--
-- Esta RPC queda disponible únicamente para backend.
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


GRANT EXECUTE
ON FUNCTION public.finalize_maintenance_invoice_backend_document(
    UUID,
    TEXT,
    TEXT
)
TO postgres;


COMMIT;