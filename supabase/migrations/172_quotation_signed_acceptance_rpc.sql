BEGIN;

-- ============================================================
-- MIGRACIÓN 057
-- Registro atómico del documento firmado y aceptación
-- contractual de presupuestos.
--
-- Requisitos:
-- - La firma debe pertenecer al cliente autenticado.
-- - El presupuesto debe continuar pendiente.
-- - La versión oficial debe seguir siendo la vigente.
-- - El PDF original debe coincidir con la versión oficial.
-- - El PDF firmado debe existir en el bucket privado.
-- - El nombre del firmante se obtiene de profiles.
-- - El registro del documento y la aceptación son atómicos.
--
-- No modifica el PDF original.
-- No sustituye respond_to_quotation().
-- ============================================================


-- ============================================================
-- 1. FUNCIÓN TRANSACCIONAL DE ACEPTACIÓN CON FIRMA
-- ============================================================

CREATE OR REPLACE FUNCTION
public.finalize_quotation_signed_acceptance(
    p_quotation_id uuid,
    p_official_version_id uuid,
    p_source_document_path text,
    p_source_document_sha256 text,
    p_signed_document_path text,
    p_signed_document_sha256 text,
    p_signature_image_sha256 text,
    p_user_agent text DEFAULT NULL
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_quotation public.quotations%ROWTYPE;
    v_workflow public.quotation_workflow_state%ROWTYPE;
    v_version public.quotation_official_versions%ROWTYPE;
    v_profile public.profiles%ROWTYPE;
    v_source_object storage.objects%ROWTYPE;
    v_signed_object storage.objects%ROWTYPE;
    v_result public.quotations%ROWTYPE;
BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN Y TIPO DE USUARIO
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión para firmar el presupuesto'
            USING ERRCODE = '42501';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION 'La cuenta no está activa'
            USING ERRCODE = '42501';
    END IF;

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION 'La aceptación firmada debe realizarla el cliente'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- 2. VALIDAR PARÁMETROS
    -- ========================================================

    IF p_quotation_id IS NULL
       OR p_official_version_id IS NULL THEN
        RAISE EXCEPTION 'El presupuesto y su versión son obligatorios';
    END IF;

    IF p_source_document_path IS NULL
       OR length(btrim(p_source_document_path)) = 0
       OR length(p_source_document_path) > 500 THEN
        RAISE EXCEPTION 'La ruta del PDF original no es válida';
    END IF;

    IF p_signed_document_path IS NULL
       OR length(btrim(p_signed_document_path)) = 0
       OR length(p_signed_document_path) > 500 THEN
        RAISE EXCEPTION 'La ruta del PDF firmado no es válida';
    END IF;

    IF p_source_document_path = p_signed_document_path THEN
        RAISE EXCEPTION
            'El PDF firmado debe almacenarse en una ruta independiente';
    END IF;

    IF p_source_document_sha256 IS NULL
       OR p_source_document_sha256 !~* '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'El SHA-256 del PDF original no es válido';
    END IF;

    IF p_signed_document_sha256 IS NULL
       OR p_signed_document_sha256 !~* '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'El SHA-256 del PDF firmado no es válido';
    END IF;

    IF p_signature_image_sha256 IS NULL
       OR p_signature_image_sha256 !~* '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'El SHA-256 de la firma no es válido';
    END IF;

    IF p_user_agent IS NOT NULL
       AND length(p_user_agent) > 2000 THEN
        RAISE EXCEPTION 'El user agent supera la longitud permitida';
    END IF;


    -- ========================================================
    -- 3. LIMITAR INTENTOS
    -- ========================================================

    PERFORM public.enforce_security_rate_limit(
        'quotation_signed_acceptance:' || auth.uid()::text,
        5,
        3600
    );


    -- ========================================================
    -- 4. BLOQUEAR EL PRESUPUESTO
    -- ========================================================

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Presupuesto no encontrado';
    END IF;

    IF v_quotation.estado <> 'Pendiente' THEN
        RAISE EXCEPTION
            'El presupuesto ya no está pendiente de aceptación';
    END IF;


    -- ========================================================
    -- 5. VALIDAR ACCESO DEL CLIENTE
    -- ========================================================

    IF NOT (
        v_quotation.user_id = auth.uid()
        OR EXISTS (
            SELECT 1
            FROM public.clients c
            WHERE c.id = v_quotation.client_id
              AND c.profile_id = auth.uid()
        )
    ) THEN
        RAISE EXCEPTION 'No tienes acceso a este presupuesto'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- 6. VALIDAR ESTADO DEL FLUJO
    -- ========================================================

    SELECT *
    INTO v_workflow
    FROM public.quotation_workflow_state
    WHERE quotation_id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El presupuesto no dispone de un flujo de versiones oficial compatible con la firma';
    END IF;

    IF v_workflow.workflow_status <> 'presented' THEN
        RAISE EXCEPTION
            'El presupuesto no está disponible para su aceptación';
    END IF;

    IF v_workflow.current_version_id IS DISTINCT FROM
       p_official_version_id THEN
        RAISE EXCEPTION
            'La versión del presupuesto ha cambiado. Actualiza la página y vuelve a intentarlo';
    END IF;


    -- ========================================================
    -- 7. VALIDAR VERSIÓN OFICIAL
    -- ========================================================

    SELECT *
    INTO v_version
    FROM public.quotation_official_versions
    WHERE id = p_official_version_id
      AND quotation_id = p_quotation_id
      AND is_current = true
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La versión oficial indicada no existe o ya no está vigente';
    END IF;

    IF v_version.document_path IS NULL
       OR v_version.document_sha256 IS NULL THEN
        RAISE EXCEPTION
            'La versión oficial no tiene un PDF preparado';
    END IF;

    IF v_version.document_path IS DISTINCT FROM
       p_source_document_path THEN
        RAISE EXCEPTION
            'La ruta del PDF original no coincide con la versión oficial';
    END IF;

    IF lower(v_version.document_sha256) IS DISTINCT FROM
       lower(p_source_document_sha256) THEN
        RAISE EXCEPTION
            'El hash del PDF original no coincide con la versión oficial';
    END IF;

    IF v_quotation.document_path IS DISTINCT FROM
       v_version.document_path THEN
        RAISE EXCEPTION
            'El PDF asociado al presupuesto no coincide con la versión oficial';
    END IF;

    IF lower(COALESCE(v_quotation.document_sha256, '')) IS DISTINCT FROM
       lower(v_version.document_sha256) THEN
        RAISE EXCEPTION
            'La huella digital del presupuesto no coincide con la versión oficial';
    END IF;


    -- ========================================================
    -- 8. COMPROBAR QUE EXISTE EL PDF ORIGINAL
    -- ========================================================

    SELECT *
    INTO v_source_object
    FROM storage.objects
    WHERE bucket_id = 'quotations'
      AND name = p_source_document_path;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El PDF original no existe en el almacenamiento';
    END IF;

    IF lower(COALESCE(
        v_source_object.metadata->>'mimetype',
        ''
    )) <> 'application/pdf' THEN
        RAISE EXCEPTION
            'El documento original no está identificado como PDF';
    END IF;


    -- ========================================================
    -- 9. COMPROBAR QUE EXISTE EL PDF FIRMADO
    -- ========================================================

    SELECT *
    INTO v_signed_object
    FROM storage.objects
    WHERE bucket_id = 'quotations'
      AND name = p_signed_document_path;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El PDF firmado no existe en el almacenamiento';
    END IF;

    IF lower(COALESCE(
        v_signed_object.metadata->>'mimetype',
        ''
    )) <> 'application/pdf' THEN
        RAISE EXCEPTION
            'El documento firmado no está identificado como PDF';
    END IF;


    -- ========================================================
    -- 10. OBTENER EL NOMBRE DEL FIRMANTE
    -- ========================================================

    SELECT *
    INTO v_profile
    FROM public.profiles
    WHERE id = auth.uid()
      AND status = 'active';

    IF NOT FOUND
       OR v_profile.nombre IS NULL
       OR length(btrim(v_profile.nombre)) = 0 THEN
        RAISE EXCEPTION
            'No se puede obtener el nombre del firmante de su perfil';
    END IF;


    -- ========================================================
    -- 11. EVITAR DUPLICADOS
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.quotation_signed_documents
        WHERE quotation_id = p_quotation_id
    ) THEN
        RAISE EXCEPTION
            'Este presupuesto ya tiene un documento firmado registrado';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.quotation_acceptances
        WHERE quotation_id = p_quotation_id
    ) THEN
        RAISE EXCEPTION
            'Este presupuesto ya tiene una aceptación contractual registrada';
    END IF;


    -- ========================================================
    -- 12. REGISTRAR EL DOCUMENTO FIRMADO
    --
    -- El nombre procede del perfil autenticado, no de un
    -- parámetro controlado por el navegador.
    --
    -- La inserción y la aceptación posterior forman parte
    -- de la misma transacción.
    -- ========================================================

    INSERT INTO public.quotation_signed_documents (
        quotation_id,
        official_version_id,
        signer_user_id,
        signer_name_snapshot,
        source_document_path,
        source_document_sha256,
        signed_document_path,
        signed_document_sha256,
        signature_image_sha256,
        signed_at,
        user_agent
    )
    VALUES (
        p_quotation_id,
        p_official_version_id,
        auth.uid(),
        btrim(v_profile.nombre),
        p_source_document_path,
        lower(p_source_document_sha256),
        p_signed_document_path,
        lower(p_signed_document_sha256),
        lower(p_signature_image_sha256),
        clock_timestamp(),
        p_user_agent
    );


    -- ========================================================
    -- 13. COMPLETAR LA ACEPTACIÓN CONTRACTUAL EXISTENTE
    --
    -- Se reutiliza la función pública existente para mantener
    -- sus comprobaciones, el acuse de lectura y el registro
    -- contractual actual.
    --
    -- Si la aceptación falla, PostgreSQL revierte también
    -- la inserción anterior.
    -- ========================================================

    v_result := public.respond_to_quotation(
        'Aceptado',
        p_quotation_id
    );


    -- ========================================================
    -- 14. DEVOLVER EL PRESUPUESTO ACEPTADO
    -- ========================================================

    RETURN v_result;

END;
$$;


-- ============================================================
-- 2. PERMISOS DE EJECUCIÓN
-- ============================================================

REVOKE ALL ON FUNCTION
public.finalize_quotation_signed_acceptance(
    uuid,
    uuid,
    text,
    text,
    text,
    text,
    text,
    text
)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE ON FUNCTION
public.finalize_quotation_signed_acceptance(
    uuid,
    uuid,
    text,
    text,
    text,
    text,
    text,
    text
)
TO authenticated;


COMMENT ON FUNCTION
public.finalize_quotation_signed_acceptance(
    uuid,
    uuid,
    text,
    text,
    text,
    text,
    text,
    text
)
IS
'Registra el PDF firmado de un presupuesto y ejecuta la aceptación contractual existente dentro de la misma transacción. Valida identidad, permisos, versión oficial, rutas y existencia de los documentos.';
CREATE POLICY "quotation_signed_documents_client_select"
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'quotations'
    AND public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.quotation_signed_documents qsd
        JOIN public.quotations q
          ON q.id = qsd.quotation_id
        WHERE qsd.signed_document_path = storage.objects.name
          AND (
              q.user_id = auth.uid()
              OR EXISTS (
                  SELECT 1
                  FROM public.clients c
                  WHERE c.id = q.client_id
                    AND c.profile_id = auth.uid()
              )
          )
    )
);
CREATE POLICY "quotation_signed_documents_worker_select"
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'quotations'
    AND public.current_user_is_worker()
    AND public.current_worker_has_permission('quotations.read')
    AND EXISTS (
        SELECT 1
        FROM public.quotation_signed_documents qsd
        WHERE qsd.signed_document_path = storage.objects.name
    )
);

COMMIT;