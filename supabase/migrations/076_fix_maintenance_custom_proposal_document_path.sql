-- ============================================================
-- 076_fix_maintenance_custom_proposal_document_path.sql
-- Corrige la validación de la ruta del PDF de propuestas
-- personalizadas de mantenimiento.
--
-- La ruta válida tiene el formato:
-- <proposal_id>/<uuid>.pdf
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_maintenance_custom_proposal_document(
    p_proposal_id UUID,
    p_document_path TEXT,
    p_document_sha256 TEXT,
    p_worker_id UUID
)
RETURNS public.maintenance_custom_proposal_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;
    v_object storage.objects;
    v_document public.maintenance_custom_proposal_documents;
    v_hash TEXT;
    v_version INTEGER;

BEGIN

    IF p_worker_id IS NULL THEN
        RAISE EXCEPTION
            'worker_id es obligatorio';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.workers w
        WHERE w.id = p_worker_id
          AND w.is_active = TRUE
    ) THEN
        RAISE EXCEPTION
            'El trabajador indicado no está activo';
    END IF;

    v_hash := LOWER(BTRIM(COALESCE(p_document_sha256, '')));

    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION
            'El SHA-256 del documento no es válido';
    END IF;

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La propuesta personalizada no existe';
    END IF;

    IF v_proposal.status NOT IN (
        'submitted',
        'in_review',
        'clarification_requested'
    ) THEN
        RAISE EXCEPTION
            'No se puede asociar un nuevo PDF en el estado actual de la propuesta';
    END IF;

    IF p_document_path IS NULL
       OR BTRIM(p_document_path) = ''
    THEN
        RAISE EXCEPTION
            'La ruta del documento es obligatoria';
    END IF;

    -- La ruta debe ser exactamente:
    -- <proposal_id>/<nombre>.pdf
    --
    -- Se utiliza \. para exigir la extensión literal ".pdf".
    IF p_document_path !~
       (
           '^'
           || p_proposal_id::TEXT
           || '/[^/]+\.pdf$'
       )
    THEN
        RAISE EXCEPTION
            'La ruta del PDF no corresponde a la propuesta';
    END IF;

    SELECT *
    INTO v_object
    FROM storage.objects
    WHERE bucket_id = 'maintenance-proposals'
      AND name = p_document_path;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El PDF no existe en el bucket maintenance-proposals';
    END IF;

    IF LOWER(COALESCE(v_object.metadata->>'mimetype', ''))
       <> 'application/pdf'
    THEN
        RAISE EXCEPTION
            'El documento de respuesta debe ser un PDF';
    END IF;

    IF COALESCE((v_object.metadata->>'size')::BIGINT, 0)
       > 20971520
    THEN
        RAISE EXCEPTION
            'El PDF supera el límite de 20 MiB';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'maintenance_proposal_document_attach:' || p_worker_id::TEXT,
        40,
        3600
    );

    SELECT COALESCE(MAX(version), 0) + 1
    INTO v_version
    FROM public.maintenance_custom_proposal_documents
    WHERE proposal_id = v_proposal.id;

    -- Solo puede existir un documento actualmente publicado.
    -- Si la propuesta todavía no está cotizada, cualquier documento
    -- nuevo reemplaza el documento de trabajo anterior.
    UPDATE public.maintenance_custom_proposal_documents
    SET
        published_at = NULL
    WHERE proposal_id = v_proposal.id
      AND published_at IS NOT NULL;

    INSERT INTO public.maintenance_custom_proposal_documents (
        proposal_id,
        version,
        document_path,
        document_mime_type,
        document_file_size,
        document_sha256,
        document_uploaded_at,
        document_uploaded_by
    )
    VALUES (
        v_proposal.id,
        v_version,
        BTRIM(p_document_path),
        'application/pdf',
        NULLIF((v_object.metadata->>'size')::BIGINT, 0),
        v_hash,
        CURRENT_TIMESTAMP,
        p_worker_id
    )
    RETURNING *
    INTO v_document;

    UPDATE public.maintenance_custom_proposals
    SET
        current_document_id = v_document.id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_proposal.id;

    INSERT INTO public.maintenance_custom_proposal_events (
        proposal_id,
        actor_id,
        actor_type,
        event_type,
        notes,
        metadata
    )
    VALUES (
        v_proposal.id,
        p_worker_id,
        'worker',
        'document_uploaded',
        'Modira ha asociado un nuevo PDF de respuesta a la propuesta.',
        jsonb_build_object(
            'document_id', v_document.id,
            'document_version', v_document.version,
            'document_sha256', v_document.document_sha256
        )
    );

    RETURN v_document;

END;
$function$;


REVOKE ALL ON FUNCTION public.attach_maintenance_custom_proposal_document(
    UUID,
    TEXT,
    TEXT,
    UUID
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.attach_maintenance_custom_proposal_document(
    UUID,
    TEXT,
    TEXT,
    UUID
) TO service_role;