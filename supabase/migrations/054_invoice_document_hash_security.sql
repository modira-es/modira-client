-- ============================================================
-- 054_invoice_document_hash_security.sql
-- ============================================================
--
-- Objetivo:
--   1. Invalidar el hash anterior cuando se vuelve a asociar
--      un PDF a una factura.
--   2. Permitir establecer el SHA-256 únicamente mediante
--      una RPC protegida para workers.
--
-- La migración 052 ya crea:
--   invoices.document_sha256
--   invoice_document_acknowledgements
--
-- Esta migración NO vuelve a crear esas estructuras.
-- ============================================================


-- ============================================================
-- 1. attach_invoice_document()
-- ============================================================
--
-- Se conserva el comportamiento existente:
--   - solo worker activo;
--   - documento obligatorio;
--   - actualiza document_path;
--   - actualiza updated_at.
--
-- Cambio de seguridad:
--   - cada vez que se asocia un PDF, se invalida el SHA-256
--     anterior.
--
-- Esto es importante incluso si el nuevo PDF utiliza exactamente
-- el mismo path (por ejemplo:  FAC-0001.pdf), porque el contenido
-- del archivo puede haber cambiado.
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_invoice_document(
    p_invoice_id UUID,
    p_document_path TEXT
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_invoice public.invoices;
BEGIN

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    IF p_document_path IS NULL
       OR TRIM(p_document_path) = '' THEN

        RAISE EXCEPTION
            'El documento es obligatorio';
    END IF;


    UPDATE public.invoices
    SET
        document_path = TRIM(p_document_path),

        -- El PDF asociado puede haber cambiado.
        -- El hash anterior deja de ser válido inmediatamente.
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
$function$;


-- ============================================================
-- 2. Permisos de attach_invoice_document()
-- ============================================================
--
-- Mantenemos el mismo modelo existente:
--   authenticated -> puede invocar la RPC
--   la propia RPC comprueba current_user_is_worker()
--
-- anon queda sin acceso.
-- ============================================================

REVOKE ALL
ON FUNCTION public.attach_invoice_document(UUID, TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.attach_invoice_document(UUID, TEXT)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.attach_invoice_document(UUID, TEXT)
TO authenticated;


-- ============================================================
-- 3. set_invoice_document_hash()
-- ============================================================
--
-- Esta RPC NO calcula el hash.
--
-- El hash debe calcularse sobre el PDF REAL almacenado en
-- Supabase Storage por la Edge Function.
--
-- La RPC únicamente recibe el SHA-256 ya calculado y lo guarda
-- después de comprobar:
--   - que existe un worker activo;
--   - que la factura existe;
--   - que la factura tiene document_path;
--   - que el hash tiene formato SHA-256 válido.
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_invoice_document_hash(
    p_invoice_id UUID,
    p_document_sha256 TEXT
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_invoice public.invoices;
    v_hash TEXT;
BEGIN

    -- --------------------------------------------------------
    -- 1. Solo workers activos
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- --------------------------------------------------------
    -- 2. Factura obligatoria
    -- --------------------------------------------------------

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION
            'La factura es obligatoria';
    END IF;


    -- --------------------------------------------------------
    -- 3. Normalización y validación del SHA-256
    -- --------------------------------------------------------

    v_hash := LOWER(TRIM(COALESCE(p_document_sha256, '')));

    IF v_hash = ''
       OR v_hash !~ '^[0-9a-f]{64}$'
    THEN
        RAISE EXCEPTION
            'El SHA-256 del documento no es válido';
    END IF;


    -- --------------------------------------------------------
    -- 4. Obtener factura
    -- --------------------------------------------------------

    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura no existe';
    END IF;


    -- --------------------------------------------------------
    -- 5. Debe existir un documento asociado
    -- --------------------------------------------------------

    IF v_invoice.document_path IS NULL
       OR TRIM(v_invoice.document_path) = ''
    THEN
        RAISE EXCEPTION
            'La factura no tiene un documento asociado';
    END IF;


    -- --------------------------------------------------------
    -- 6. Guardar hash
    -- --------------------------------------------------------

    UPDATE public.invoices
SET
    document_path = TRIM(p_document_path),
    document_sha256 = NULL,
    updated_at = CURRENT_TIMESTAMP
WHERE id = p_invoice_id
RETURNING *
INTO v_invoice;


    RETURN v_invoice;

END;
$function$;


-- ============================================================
-- 4. Permisos de set_invoice_document_hash()
-- ============================================================
--
-- La función puede ser invocada por usuarios autenticados,
-- pero la propia función exige current_user_is_worker().
--
-- No se permite ejecución anónima.
-- ============================================================

REVOKE ALL
ON FUNCTION public.set_invoice_document_hash(UUID, TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.set_invoice_document_hash(UUID, TEXT)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.set_invoice_document_hash(UUID, TEXT)
TO authenticated;


-- ============================================================
-- 5. Comentarios
-- ============================================================

COMMENT ON FUNCTION public.set_invoice_document_hash(UUID, TEXT)
IS
'Registra el SHA-256 del PDF actualmente asociado a una factura. Solo workers activos. El hash debe haber sido calculado previamente sobre el archivo real almacenado en Storage.';


COMMENT ON FUNCTION public.attach_invoice_document(UUID, TEXT)
IS
'Asocia un PDF a una factura. Al asociar/reemplazar el documento invalida el SHA-256 anterior para impedir que una aceptación previa autorice el nuevo documento.';


-- ============================================================
-- 6. Verificaciones finales
-- ============================================================
--
-- Si alguna de estas comprobaciones falla, la migración debe
-- considerarse incorrecta.
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- La columna document_sha256 debe existir.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'invoices'
          AND column_name = 'document_sha256'
    ) THEN
        RAISE EXCEPTION
            'La migración 052 debe ejecutarse antes que la 054: falta invoices.document_sha256';
    END IF;


    -- --------------------------------------------------------
    -- La tabla de acknowledgements debe existir.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'invoice_document_acknowledgements'
    ) THEN
        RAISE EXCEPTION
            'La migración 052 debe ejecutarse antes que la 054: falta invoice_document_acknowledgements';
    END IF;


    -- --------------------------------------------------------
    -- attach_invoice_document debe existir.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'attach_invoice_document'
          AND pg_get_function_identity_arguments(p.oid)
              = 'p_invoice_id uuid, p_document_path text'
    ) THEN
        RAISE EXCEPTION
            'No se ha encontrado attach_invoice_document(uuid,text)';
    END IF;


    -- --------------------------------------------------------
    -- set_invoice_document_hash debe existir.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_invoice_document_hash'
          AND pg_get_function_identity_arguments(p.oid)
              = 'p_invoice_id uuid, p_document_sha256 text'
    ) THEN
        RAISE EXCEPTION
            'No se ha creado set_invoice_document_hash(uuid,text)';
    END IF;

END
$$;