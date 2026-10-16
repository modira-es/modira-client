-- ============================================================
-- 057_immutable_accepted_documents.sql
-- ============================================================
-- INMUTABILIDAD DE DOCUMENTOS ACEPTADOS
--
-- Objetivo:
--
-- Una vez que un cliente ha registrado una aceptación documental
-- de una factura o presupuesto, el PDF concreto asociado queda
-- protegido contra:
--
--   1. UPDATE en Storage
--   2. DELETE en Storage
--   3. Reasociación mediante attach_*_document()
--   4. Reescritura del SHA-256 mediante set_*_document_hash()
--
-- Antes de la aceptación:
--
--   UPDATE / DELETE / attach / hash -> permitido
--
-- Después de la aceptación:
--
--   UPDATE / DELETE / attach / hash -> bloqueado
--
-- NO se modifica:
--
--   - 053
--   - 054
--   - 055
--   - 056
--   - respond_to_quotation()
--   - Stripe
--   - acknowledgement documental
--   - aceptación contractual
--
-- ============================================================


-- ============================================================
-- 1. FUNCIONES AUXILIARES PARA SABER SI UN PDF ESTÁ BLOQUEADO
-- ============================================================

-- ------------------------------------------------------------
-- 1.1 FACTURAS
-- ------------------------------------------------------------
--
-- Recibe una ruta de Storage:
--
--     numero_factura.pdf
--
-- y comprueba si existe una aceptación documental para la
-- factura correspondiente.
--
-- SECURITY DEFINER:
-- la función debe poder consultar la tabla de acknowledgements
-- independientemente de las políticas RLS del usuario que esté
-- ejecutando la operación de Storage.
--
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.invoice_document_storage_is_locked(
    p_storage_path TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

    SELECT EXISTS (
        SELECT 1
        FROM public.invoices i
        INNER JOIN public.invoice_document_acknowledgements a
            ON a.invoice_id = i.id
        WHERE
            i.numero_factura IS NOT NULL
            AND (
                i.numero_factura || '.pdf'
            ) = p_storage_path
    );

$function$;


-- ------------------------------------------------------------
-- 1.2 PRESUPUESTOS
-- ------------------------------------------------------------
--
-- Recibe una ruta:
--
--     company_uuid/numero_presupuesto.pdf
--
-- y comprueba si existe una aceptación documental para ese
-- presupuesto.
--
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.quotation_document_storage_is_locked(
    p_storage_path TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

    SELECT EXISTS (
        SELECT 1
        FROM public.quotations q
        INNER JOIN public.quotation_document_acknowledgements a
            ON a.quotation_id = q.id
        WHERE
            (
                q.company_id::TEXT
                || '/'
                || q.numero_presupuesto
                || '.pdf'
            ) = p_storage_path
    );

$function$;


-- ============================================================
-- 2. PERMISOS DE LAS FUNCIONES AUXILIARES
-- ============================================================

REVOKE ALL
ON FUNCTION public.invoice_document_storage_is_locked(TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.quotation_document_storage_is_locked(TEXT)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.invoice_document_storage_is_locked(TEXT)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.quotation_document_storage_is_locked(TEXT)
TO authenticated;


-- ============================================================
-- 3. FACTURAS — STORAGE UPDATE
-- ============================================================

DROP POLICY IF EXISTS
    invoice_documents_worker_update
ON storage.objects;


CREATE POLICY invoice_documents_worker_update
ON storage.objects
AS PERMISSIVE
FOR UPDATE
TO authenticated
USING (
    bucket_id = 'invoices'
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE objects.name = (
            i.numero_factura || '.pdf'
        )
    )
    AND NOT public.invoice_document_storage_is_locked(
        objects.name
    )
)
WITH CHECK (
    bucket_id = 'invoices'
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE objects.name = (
            i.numero_factura || '.pdf'
        )
    )
    AND NOT public.invoice_document_storage_is_locked(
        objects.name
    )
);


-- ============================================================
-- 4. FACTURAS — STORAGE DELETE
-- ============================================================

DROP POLICY IF EXISTS
    invoice_documents_worker_delete
ON storage.objects;


CREATE POLICY invoice_documents_worker_delete
ON storage.objects
AS PERMISSIVE
FOR DELETE
TO authenticated
USING (
    bucket_id = 'invoices'
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE objects.name = (
            i.numero_factura || '.pdf'
        )
    )
    AND NOT public.invoice_document_storage_is_locked(
        objects.name
    )
);


-- ============================================================
-- 5. PRESUPUESTOS — STORAGE UPDATE
-- ============================================================

DROP POLICY IF EXISTS
    quotation_documents_worker_update
ON storage.objects;


CREATE POLICY quotation_documents_worker_update
ON storage.objects
AS PERMISSIVE
FOR UPDATE
TO authenticated
USING (
    bucket_id = 'quotations'
    AND public.worker_can_write_quotation_storage_path(
        objects.name
    )
    AND NOT public.quotation_document_storage_is_locked(
        objects.name
    )
)
WITH CHECK (
    bucket_id = 'quotations'
    AND public.worker_can_write_quotation_storage_path(
        objects.name
    )
    AND NOT public.quotation_document_storage_is_locked(
        objects.name
    )
);


-- ============================================================
-- 6. PRESUPUESTOS — STORAGE DELETE
-- ============================================================

DROP POLICY IF EXISTS
    quotation_documents_worker_delete
ON storage.objects;


CREATE POLICY quotation_documents_worker_delete
ON storage.objects
AS PERMISSIVE
FOR DELETE
TO authenticated
USING (
    bucket_id = 'quotations'
    AND public.worker_can_write_quotation_storage_path(
        objects.name
    )
    AND NOT public.quotation_document_storage_is_locked(
        objects.name
    )
);


-- ============================================================
-- 7. PROTEGER attach_invoice_document()
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_invoice_document(
    p_invoice_id UUID,
    p_document_path TEXT
)
RETURNS public.invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_invoice public.invoices;
BEGIN

    -- ========================================================
    -- 1. WORKER
    -- ========================================================

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- ========================================================
    -- 2. DOCUMENTO OBLIGATORIO
    -- ========================================================

    IF p_document_path IS NULL
       OR TRIM(p_document_path) = ''
    THEN
        RAISE EXCEPTION
            'El documento es obligatorio';
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
    -- 4. BLOQUEAR SI YA EXISTE ACEPTACIÓN DOCUMENTAL
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = v_invoice.id
    ) THEN

        RAISE EXCEPTION
            'El documento de esta factura está bloqueado porque ya ha sido aceptado por el cliente';

    END IF;


    -- ========================================================
    -- 5. ACTUALIZAR DOCUMENTO
    -- ========================================================
    --
    -- El cambio de PDF invalida el hash anterior.
    --
    -- El nuevo documento deberá volver a pasar por el proceso
    -- server-side de cálculo de SHA-256.
    --
    -- ========================================================

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
-- 8. PROTEGER attach_quotation_document()
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_quotation_document(
    p_quotation_id UUID,
    p_document_path TEXT
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_quotation public.quotations;
    v_expected_path TEXT;

BEGIN

    -- ========================================================
    -- 1. WORKER
    -- ========================================================

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- ========================================================
    -- 2. OBTENER PRESUPUESTO
    -- ========================================================

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Presupuesto no encontrado';
    END IF;


    -- ========================================================
    -- 3. BLOQUEAR SI YA EXISTE ACEPTACIÓN DOCUMENTAL
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.quotation_document_acknowledgements a
        WHERE a.quotation_id = v_quotation.id
    ) THEN

        RAISE EXCEPTION
            'El documento de este presupuesto está bloqueado porque ya ha sido aceptado por el cliente';

    END IF;


    -- ========================================================
    -- 4. RUTA ESPERADA
    -- ========================================================

    v_expected_path :=
        v_quotation.company_id::TEXT
        || '/'
        || v_quotation.numero_presupuesto
        || '.pdf';


    -- ========================================================
    -- 5. VALIDAR RUTA
    -- ========================================================

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


    -- ========================================================
    -- 6. COMPROBAR EXISTENCIA FÍSICA
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'quotations'
          AND name = p_document_path
    ) THEN

        RAISE EXCEPTION
            'El documento no existe en el bucket de presupuestos';

    END IF;


    -- ========================================================
    -- 7. ACTUALIZAR DOCUMENTO
    -- ========================================================
    --
    -- Al cambiar/asociar el PDF, el hash anterior deja de ser
    -- válido.
    --
    -- ========================================================

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
$function$;


-- ============================================================
-- 9. PROTEGER set_invoice_document_hash()
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_invoice_document_hash(
    p_invoice_id UUID,
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

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión para validar el documento';
    END IF;


    -- ========================================================
    -- 2. WORKER
    -- ========================================================

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- ========================================================
    -- 3. FACTURA OBLIGATORIA
    -- ========================================================

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION
            'La factura es obligatoria';
    END IF;


    -- ========================================================
    -- 4. VALIDAR HASH
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
            'La huella digital del documento es obligatoria';
    END IF;


    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION
            'La huella digital del documento no es un SHA-256 válido';
    END IF;


    -- ========================================================
    -- 5. OBTENER FACTURA
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
    -- 6. BLOQUEAR SI YA EXISTE ACEPTACIÓN
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.invoice_document_acknowledgements a
        WHERE a.invoice_id = v_invoice.id
    ) THEN

        RAISE EXCEPTION
            'No se puede modificar la huella digital porque el documento ya ha sido aceptado por el cliente';

    END IF;


    -- ========================================================
    -- 7. PDF OBLIGATORIO
    -- ========================================================

    IF v_invoice.document_path IS NULL
       OR TRIM(v_invoice.document_path) = ''
    THEN
        RAISE EXCEPTION
            'La factura no tiene un documento PDF asociado';
    END IF;


    -- ========================================================
    -- 8. GUARDAR HASH
    -- ========================================================

    UPDATE public.invoices
    SET
        document_sha256 = v_hash,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_invoice_id
    RETURNING *
    INTO v_invoice;


    IF v_invoice.id IS NULL THEN
        RAISE EXCEPTION
            'No se ha podido registrar la huella digital del documento';
    END IF;


    RETURN v_invoice;

END;
$function$;


-- ============================================================
-- 10. PROTEGER set_quotation_document_hash()
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_quotation_document_hash(
    p_quotation_id UUID,
    p_document_path TEXT,
    p_document_sha256 TEXT
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_quotation public.quotations;
    v_expected_path TEXT;
    v_hash TEXT;

BEGIN

    -- ========================================================
    -- 1. AUTORIZACIÓN
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- ========================================================
    -- 2. VALIDAR HASH
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
    -- 3. OBTENER PRESUPUESTO
    -- ========================================================

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Presupuesto no encontrado';
    END IF;


    -- ========================================================
    -- 4. BLOQUEAR SI YA EXISTE ACEPTACIÓN
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.quotation_document_acknowledgements a
        WHERE a.quotation_id = v_quotation.id
    ) THEN

        RAISE EXCEPTION
            'No se puede modificar la huella digital porque el documento ya ha sido aceptado por el cliente';

    END IF;


    -- ========================================================
    -- 5. CALCULAR RUTA ESPERADA
    -- ========================================================

    v_expected_path :=
        v_quotation.company_id::TEXT
        || '/'
        || v_quotation.numero_presupuesto
        || '.pdf';


    -- ========================================================
    -- 6. VALIDAR RUTA
    -- ========================================================

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


    -- ========================================================
    -- 7. EL PDF DEBE EXISTIR
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'quotations'
          AND name = v_expected_path
    ) THEN

        RAISE EXCEPTION
            'El documento no existe en el bucket de presupuestos';

    END IF;


    -- ========================================================
    -- 8. DOCUMENT_PATH DEBE COINCIDIR
    -- ========================================================

    IF v_quotation.document_path IS DISTINCT FROM
       v_expected_path
    THEN

        RAISE EXCEPTION
            'El documento no está asociado al presupuesto';

    END IF;


    -- ========================================================
    -- 9. GUARDAR HASH
    -- ========================================================

    UPDATE public.quotations
    SET
        document_sha256 = v_hash,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_quotation.id
    RETURNING *
    INTO v_quotation;


    RETURN v_quotation;

END;
$function$;


-- ============================================================
-- 11. GARANTIZAR PERMISOS DE LAS RPC EXISTENTES
-- ============================================================
--
-- Se mantienen exactamente como estaban:
--
--   authenticated -> EXECUTE
--   anon          -> NO EXECUTE
--   service_role  -> NO EXECUTE
--
-- ============================================================

REVOKE ALL
ON FUNCTION public.attach_invoice_document(UUID, TEXT)
FROM PUBLIC, anon, service_role;

GRANT EXECUTE
ON FUNCTION public.attach_invoice_document(UUID, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.attach_quotation_document(UUID, TEXT)
FROM PUBLIC, anon, service_role;

GRANT EXECUTE
ON FUNCTION public.attach_quotation_document(UUID, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.set_invoice_document_hash(UUID, TEXT)
FROM PUBLIC, anon, service_role;

GRANT EXECUTE
ON FUNCTION public.set_invoice_document_hash(UUID, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
FROM PUBLIC, anon, service_role;

GRANT EXECUTE
ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
TO authenticated;


-- ============================================================
-- 12. VERIFICACIONES FINALES
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- 12.1 POLICIES DE FACTURAS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'invoice_documents_worker_update'
    ) THEN

        RAISE EXCEPTION
            '057 failed: invoice_documents_worker_update no existe';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'invoice_documents_worker_delete'
    ) THEN

        RAISE EXCEPTION
            '057 failed: invoice_documents_worker_delete no existe';

    END IF;


    -- --------------------------------------------------------
    -- 12.2 POLICIES DE PRESUPUESTOS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'quotation_documents_worker_update'
    ) THEN

        RAISE EXCEPTION
            '057 failed: quotation_documents_worker_update no existe';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'quotation_documents_worker_delete'
    ) THEN

        RAISE EXCEPTION
            '057 failed: quotation_documents_worker_delete no existe';

    END IF;


    -- --------------------------------------------------------
    -- 12.3 FUNCIONES AUXILIARES
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'invoice_document_storage_is_locked'
          AND pg_get_function_identity_arguments(p.oid)
              = 'p_storage_path text'
    ) THEN

        RAISE EXCEPTION
            '057 failed: invoice_document_storage_is_locked no existe';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'quotation_document_storage_is_locked'
          AND pg_get_function_identity_arguments(p.oid)
              = 'p_storage_path text'
    ) THEN

        RAISE EXCEPTION
            '057 failed: quotation_document_storage_is_locked no existe';

    END IF;


    -- --------------------------------------------------------
    -- 12.4 SECURITY DEFINER DE FUNCIONES CRÍTICAS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'attach_invoice_document'
          AND p.prosecdef = TRUE
    ) THEN

        RAISE EXCEPTION
            '057 failed: attach_invoice_document debe ser SECURITY DEFINER';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'attach_quotation_document'
          AND p.prosecdef = TRUE
    ) THEN

        RAISE EXCEPTION
            '057 failed: attach_quotation_document debe ser SECURITY DEFINER';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_invoice_document_hash'
          AND p.prosecdef = TRUE
    ) THEN

        RAISE EXCEPTION
            '057 failed: set_invoice_document_hash debe ser SECURITY DEFINER';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_quotation_document_hash'
          AND p.prosecdef = TRUE
    ) THEN

        RAISE EXCEPTION
            '057 failed: set_quotation_document_hash debe ser SECURITY DEFINER';

    END IF;


    -- --------------------------------------------------------
    -- 12.5 PERMISOS DE LAS RPC
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.attach_invoice_document(uuid,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '057 failed: authenticated debe poder ejecutar attach_invoice_document';

    END IF;


    IF NOT has_function_privilege(
        'authenticated',
        'public.attach_quotation_document(uuid,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '057 failed: authenticated debe poder ejecutar attach_quotation_document';

    END IF;


    IF NOT has_function_privilege(
        'authenticated',
        'public.set_invoice_document_hash(uuid,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '057 failed: authenticated debe poder ejecutar set_invoice_document_hash';

    END IF;


    IF NOT has_function_privilege(
        'authenticated',
        'public.set_quotation_document_hash(uuid,text,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '057 failed: authenticated debe poder ejecutar set_quotation_document_hash';

    END IF;


    -- --------------------------------------------------------
    -- 12.6 ANON NO DEBE TENER EXECUTE
    -- --------------------------------------------------------

    IF has_function_privilege(
        'anon',
        'public.attach_invoice_document(uuid,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '057 failed: anon no debe poder ejecutar attach_invoice_document';

    END IF;


    IF has_function_privilege(
        'anon',
        'public.attach_quotation_document(uuid,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '057 failed: anon no debe poder ejecutar attach_quotation_document';

    END IF;


    IF has_function_privilege(
        'anon',
        'public.set_invoice_document_hash(uuid,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '057 failed: anon no debe poder ejecutar set_invoice_document_hash';

    END IF;


    IF has_function_privilege(
        'anon',
        'public.set_quotation_document_hash(uuid,text,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '057 failed: anon no debe poder ejecutar set_quotation_document_hash';

    END IF;


    RAISE NOTICE
        '057 OK: documentos aceptados protegidos correctamente';

END;
$$;
