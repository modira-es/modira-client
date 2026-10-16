BEGIN;

-- ============================================================
-- MODIRA — INVOICE DOCUMENT SECURITY
-- ============================================================
--
-- OBJETIVO
--
-- Esta migración establece el flujo seguro de validación y
-- aceptación del PDF de una factura.
--
-- FLUJO DE VALIDACIÓN DEL DOCUMENTO
--
-- Worker
--   ↓
-- Edge Function set-invoice-document-hash
--   ↓
-- descarga el PDF real desde Storage
--   ↓
-- calcula SHA-256
--   ↓
-- set_invoice_document_hash()
--   ↓
-- invoices.document_sha256
--
-- FLUJO DE ACEPTACIÓN
--
-- Cliente
--   ↓
-- record_invoice_document_acknowledgement()
--   ↓
-- obtiene document_path + document_sha256 directamente
-- desde invoices
--
-- El cliente nunca puede proporcionar:
--
--   document_path
--   document_sha256
--   accepted_at
--   user_id
--   acknowledgement_text_version
--
-- ============================================================


-- ============================================================
-- 1. RPC — SET INVOICE DOCUMENT HASH
-- ============================================================
--
-- Esta RPC es utilizada por la Edge Function:
--
--   set-invoice-document-hash
--
-- La Edge Function calcula el SHA-256 del PDF real almacenado
-- en Storage y proporciona únicamente ese hash a esta RPC.
--
-- La RPC:
--
-- - requiere autenticación;
-- - requiere worker activo;
-- - exige invoice_id;
-- - exige SHA-256 válido;
-- - exige que la factura exista;
-- - exige que la factura tenga document_path;
-- - únicamente modifica document_sha256;
-- - no permite que el cliente utilice esta vía.
--
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

    -- ========================================================
    -- 1. USUARIO AUTENTICADO
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión para validar el documento';
    END IF;


    -- ========================================================
    -- 2. SOLO WORKERS
    -- ========================================================

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- ========================================================
    -- 3. INVOICE ID OBLIGATORIO
    -- ========================================================

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION
            'La factura es obligatoria';
    END IF;


    -- ========================================================
    -- 4. NORMALIZAR Y VALIDAR SHA-256
    -- ========================================================

    v_hash := LOWER(TRIM(COALESCE(
        p_document_sha256,
        ''
    )));

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
    WHERE id = p_invoice_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura no existe';
    END IF;


    -- ========================================================
    -- 6. PDF OBLIGATORIO
    -- ========================================================
    --
    -- El hash solamente puede registrarse después de que
    -- attach_invoice_document() haya asociado el PDF.
    -- ========================================================

    IF v_invoice.document_path IS NULL
       OR TRIM(v_invoice.document_path) = ''
    THEN
        RAISE EXCEPTION
            'La factura no tiene un documento PDF asociado';
    END IF;


    -- ========================================================
    -- 7. GUARDAR SHA-256
    -- ========================================================
    --
    -- No se modifica:
    --
    -- document_path
    -- estado
    -- importe
    -- user_id
    -- company_id
    --
    -- Únicamente se registra la huella del documento.
    -- ========================================================

    UPDATE public.invoices
    SET
        document_sha256 = v_hash,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_invoice_id
    RETURNING *
    INTO v_invoice;


    -- ========================================================
    -- 8. COMPROBACIÓN FINAL
    -- ========================================================

    IF v_invoice.id IS NULL THEN
        RAISE EXCEPTION
            'No se ha podido registrar la huella digital del documento';
    END IF;


    RETURN v_invoice;

END;
$function$;


-- ============================================================
-- 2. PERMISOS — SET INVOICE DOCUMENT HASH
-- ============================================================
--
-- La RPC es accesible únicamente mediante usuarios
-- autenticados.
--
-- La propia función comprueba que sean workers activos.
--
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
-- 3. SEGURIDAD DEL SEARCH_PATH
-- ============================================================

ALTER FUNCTION public.set_invoice_document_hash(UUID, TEXT)
SET search_path = public, pg_temp;


-- ============================================================
-- 4. COMENTARIO
-- ============================================================

COMMENT ON FUNCTION public.set_invoice_document_hash(UUID, TEXT)
IS
'Registra el SHA-256 calculado server-side del PDF real asociado a una factura. Solo puede utilizarla un trabajador activo y únicamente modifica invoices.document_sha256.';


-- ============================================================
-- 5. RPC — RECORD INVOICE DOCUMENT ACKNOWLEDGEMENT
-- ============================================================
--
-- Crear la única vía mediante la cual un cliente puede registrar
-- la aceptación del PDF asociado a una factura antes de iniciar
-- su pago.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_invoice_document_acknowledgement(
    p_invoice_id UUID
)
RETURNS public.invoice_document_acknowledgements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_user_id UUID;
    v_invoice public.invoices;
    v_acknowledgement public.invoice_document_acknowledgements;

    v_acknowledgement_text_version TEXT :=
        'invoice_document_acknowledgement_v1';

BEGIN

    -- ========================================================
    -- 1. USUARIO AUTENTICADO
    -- ========================================================

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión para aceptar el documento de la factura';
    END IF;


    -- ========================================================
    -- 2. LOS WORKERS NO UTILIZAN ESTA RPC
    -- ========================================================

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Los trabajadores no pueden registrar una aceptación de cliente';
    END IF;


    -- ========================================================
    -- 3. INVOICE ID OBLIGATORIO
    -- ========================================================

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION
            'La factura es obligatoria';
    END IF;


    -- ========================================================
    -- 4. OBTENER FACTURA DEL USUARIO
    -- ========================================================

    SELECT *
    INTO v_invoice
    FROM public.invoices
    WHERE id = p_invoice_id
      AND user_id = v_user_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura no existe o no tienes acceso a ella';
    END IF;


    -- ========================================================
    -- 5. COMPROBAR ESTADO
    -- ========================================================

    IF LOWER(TRIM(COALESCE(v_invoice.estado, ''))) NOT IN (
        'pendiente',
        'vencida'
    ) THEN

        RAISE EXCEPTION
            'Esta factura no se encuentra en un estado que permita iniciar el pago';

    END IF;


    -- ========================================================
    -- 6. PDF OBLIGATORIO
    -- ========================================================

    IF v_invoice.document_path IS NULL
       OR TRIM(v_invoice.document_path) = ''
    THEN

        RAISE EXCEPTION
            'La factura no tiene un documento PDF asociado';

    END IF;


    -- ========================================================
    -- 7. SHA-256 OBLIGATORIO
    -- ========================================================

    IF v_invoice.document_sha256 IS NULL
       OR TRIM(v_invoice.document_sha256) = ''
       OR LOWER(TRIM(v_invoice.document_sha256))
          !~ '^[0-9a-f]{64}$'
    THEN

        RAISE EXCEPTION
            'El documento de la factura todavía no está validado';

    END IF;


    -- ========================================================
    -- 8. REGISTRAR ACEPTACIÓN
    -- ========================================================

    INSERT INTO public.invoice_document_acknowledgements (
        invoice_id,
        user_id,
        document_path,
        document_sha256,
        acknowledgement_text_version,
        accepted_at
    )
    VALUES (
        v_invoice.id,
        v_user_id,
        TRIM(v_invoice.document_path),
        LOWER(TRIM(v_invoice.document_sha256)),
        v_acknowledgement_text_version,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (
        invoice_id,
        user_id,
        document_sha256,
        acknowledgement_text_version
    )
    DO UPDATE
    SET
        document_path = EXCLUDED.document_path,
        accepted_at = EXCLUDED.accepted_at
    RETURNING *
    INTO v_acknowledgement;


    -- ========================================================
    -- 9. COMPROBACIÓN FINAL
    -- ========================================================

    IF v_acknowledgement.id IS NULL THEN
        RAISE EXCEPTION
            'No se ha podido registrar la aceptación del documento';
    END IF;


    RETURN v_acknowledgement;

END;
$function$;


-- ============================================================
-- 6. PERMISOS — RECORD ACKNOWLEDGEMENT
-- ============================================================

REVOKE ALL
ON FUNCTION public.record_invoice_document_acknowledgement(UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.record_invoice_document_acknowledgement(UUID)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.record_invoice_document_acknowledgement(UUID)
TO authenticated;


-- ============================================================
-- 7. SEGURIDAD DEL SEARCH_PATH
-- ============================================================

ALTER FUNCTION public.record_invoice_document_acknowledgement(UUID)
SET search_path = public, pg_temp;


-- ============================================================
-- 8. COMENTARIO
-- ============================================================

COMMENT ON FUNCTION public.record_invoice_document_acknowledgement(UUID)
IS
'Registra la aceptación de un cliente del PDF actualmente asociado a una factura. El documento y su SHA-256 se obtienen exclusivamente desde invoices; el cliente solo proporciona invoice_id.';


-- ============================================================
-- 9. PERMISOS PARA EDGE FUNCTIONS
-- ============================================================
--
-- Las Edge Functions utilizan el cliente service_role para:
--
-- - consultar invoices;
-- - consultar las aceptaciones registradas en
--   invoice_document_acknowledgements.
--
-- El acceso mediante service_role es necesario porque estas
-- comprobaciones se realizan server-side y no deben depender
-- de permisos directos del cliente.
--
-- ============================================================

GRANT SELECT
ON TABLE public.invoices
TO service_role;

GRANT SELECT
ON TABLE public.invoice_document_acknowledgements
TO service_role;

-- ============================================================
-- 10. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- invoice_document_acknowledgements
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'invoice_document_acknowledgements';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '055 failed: invoice_document_acknowledgements table missing';
    END IF;


    -- --------------------------------------------------------
    -- document_sha256
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'invoices'
      AND column_name = 'document_sha256';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '055 failed: invoices.document_sha256 missing';
    END IF;


    -- --------------------------------------------------------
    -- set_invoice_document_hash(uuid,text)
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'set_invoice_document_hash'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_invoice_id uuid, p_document_sha256 text';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '055 failed: set_invoice_document_hash(uuid,text) missing';
    END IF;


    -- --------------------------------------------------------
    -- set_invoice_document_hash debe ser SECURITY DEFINER
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'set_invoice_document_hash'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '055 failed: set_invoice_document_hash must be SECURITY DEFINER';
    END IF;


    -- --------------------------------------------------------
    -- authenticated debe poder ejecutar set_invoice_document_hash
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.set_invoice_document_hash(uuid,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '055 failed: authenticated must have EXECUTE on set_invoice_document_hash';

    END IF;


    -- --------------------------------------------------------
    -- anon NO debe poder ejecutar set_invoice_document_hash
    -- --------------------------------------------------------

    IF has_function_privilege(
        'anon',
        'public.set_invoice_document_hash(uuid,text)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '055 failed: anon must not have EXECUTE on set_invoice_document_hash';

    END IF;


    -- --------------------------------------------------------
    -- record_invoice_document_acknowledgement(uuid)
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname =
          'record_invoice_document_acknowledgement'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_invoice_id uuid';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '055 failed: record_invoice_document_acknowledgement(uuid) missing';
    END IF;


    -- --------------------------------------------------------
    -- record_invoice_document_acknowledgement debe ser
    -- SECURITY DEFINER
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname =
          'record_invoice_document_acknowledgement'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '055 failed: acknowledgement RPC must be SECURITY DEFINER';
    END IF;


    -- --------------------------------------------------------
    -- authenticated debe tener EXECUTE
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.record_invoice_document_acknowledgement(uuid)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '055 failed: authenticated must have EXECUTE permission';

    END IF;


    -- --------------------------------------------------------
    -- anon NO debe tener EXECUTE
    -- --------------------------------------------------------

    IF has_function_privilege(
        'anon',
        'public.record_invoice_document_acknowledgement(uuid)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '055 failed: anon must not have EXECUTE permission';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO debe insertar directamente
    -- acknowledgements
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.invoice_document_acknowledgements',
        'INSERT'
    ) THEN

        RAISE EXCEPTION
            '055 failed: authenticated must not have direct INSERT permission';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO debe actualizar directamente
    -- acknowledgements
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.invoice_document_acknowledgements',
        'UPDATE'
    ) THEN

        RAISE EXCEPTION
            '055 failed: authenticated must not have direct UPDATE permission';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO debe eliminar directamente
    -- acknowledgements
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.invoice_document_acknowledgements',
        'DELETE'
    ) THEN

        RAISE EXCEPTION
            '055 failed: authenticated must not have direct DELETE permission';

    END IF;


    -- --------------------------------------------------------
    -- service_role debe poder leer invoices
    -- --------------------------------------------------------

    IF NOT has_table_privilege(
        'service_role',
        'public.invoices',
        'SELECT'
    ) THEN

        RAISE EXCEPTION
            '055 failed: service_role must have SELECT on invoices';

    END IF;
-- --------------------------------------------------------
-- service_role debe poder leer
-- invoice_document_acknowledgements
-- --------------------------------------------------------

IF NOT has_table_privilege(
    'service_role',
    'public.invoice_document_acknowledgements',
    'SELECT'
) THEN

    RAISE EXCEPTION
        '055 failed: service_role must have SELECT on invoice_document_acknowledgements';

END IF;
END;
$$;

COMMIT;