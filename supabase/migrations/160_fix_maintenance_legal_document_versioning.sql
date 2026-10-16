-- ============================================================
-- 160_fix_maintenance_legal_document_versioning.sql
-- Modira — corregir publicación/versionado de documentos legales
--
-- Corrige publish_legal_document_version():
--   1. Calcula y guarda content_hash (SHA-256) del contenido.
--   2. Serializa publicaciones concurrentes por tipo documental.
--   3. No permite reutilizar una versión del mismo tipo.
--   4. No permite programar fechas futuras con la lógica actual,
--      porque desactivaría la versión vigente antes de tiempo.
--   5. Cierra la vigencia de la versión anterior al publicar otra.
--   6. Restringe la RPC a service_role: no debe poder publicar
--      documentos legales cualquier usuario autenticado.
--
-- Importante:
--   Esta migración NO inventa ni publica el texto de las condiciones.
--   La versión de condiciones particulares se publicará cuando exista
--   su texto definitivo.
-- ============================================================

BEGIN;

-- El contrato debe conservar por separado las dos versiones aceptadas.
-- terms_version ya representa las condiciones generales; esta columna
-- almacenará la versión de las condiciones particulares.
ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS specific_conditions_version TEXT;

COMMENT ON COLUMN public.maintenance_contracts.specific_conditions_version
IS 'Versión de las condiciones particulares de mantenimiento aceptadas para este contrato.';

CREATE OR REPLACE FUNCTION public.publish_legal_document_version(
    p_document_type TEXT,
    p_version TEXT,
    p_title TEXT,
    p_content TEXT,
    p_effective_from TIMESTAMPTZ DEFAULT NOW()
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $function$
DECLARE
    v_document_id UUID;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_content_hash TEXT;
BEGIN
    -- Solo se versionan estos dos tipos desde esta RPC.
    IF p_document_type IS NULL
       OR p_document_type NOT IN (
           'maintenance_contract_terms',
           'maintenance_specific_conditions'
       )
    THEN
        RAISE EXCEPTION
            'Tipo de documento no permitido: %',
            p_document_type;
    END IF;

    IF p_version IS NULL OR BTRIM(p_version) = '' THEN
        RAISE EXCEPTION 'La versión del documento es obligatoria';
    END IF;

    IF p_title IS NULL OR BTRIM(p_title) = '' THEN
        RAISE EXCEPTION 'El título del documento es obligatorio';
    END IF;

    IF p_content IS NULL OR BTRIM(p_content) = '' THEN
        RAISE EXCEPTION 'El contenido del documento es obligatorio';
    END IF;

    IF p_effective_from IS NULL THEN
        RAISE EXCEPTION 'La fecha de entrada en vigor es obligatoria';
    END IF;

    -- Esta implementación publica inmediatamente. Aceptar una fecha futura
    -- y desactivar ya la versión anterior dejaría el checkout sin términos
    -- vigentes hasta que llegase esa fecha.
    IF p_effective_from > v_now THEN
        RAISE EXCEPTION
            'La publicación debe entrar en vigor ahora o en una fecha pasada. No se admiten fechas futuras en esta versión de la función.';
    END IF;

    -- Evita que dos publicaciones del mismo tipo se pisen entre sí.
    PERFORM pg_advisory_xact_lock(
        hashtextextended('legal-document-publish:' || p_document_type, 0)
    );

    -- No se permite reutilizar el identificador de versión dentro del tipo.
    IF EXISTS (
        SELECT 1
        FROM public.legal_documents ld
        WHERE ld.document_type = p_document_type
          AND ld.version = p_version
    ) THEN
        RAISE EXCEPTION
            'La versión % ya existe para el documento %',
            p_version,
            p_document_type;
    END IF;

    -- SHA-256 del contenido exacto guardado, codificado en UTF-8.
    v_content_hash := encode(
        extensions.digest(convert_to(p_content, 'UTF8'), 'sha256'),
        'hex'
    );

    -- Cierra la versión que estaba vigente sin alterar su contenido/hash.
    UPDATE public.legal_documents
       SET is_current = FALSE,
           effective_until = CASE
               WHEN effective_until IS NULL
                    OR effective_until > p_effective_from
               THEN p_effective_from
               ELSE effective_until
           END
     WHERE document_type = p_document_type
       AND is_current = TRUE;

    INSERT INTO public.legal_documents (
        document_type,
        version,
        title,
        content,
        content_hash,
        effective_from,
        effective_until,
        is_current
    )
    VALUES (
        p_document_type,
        BTRIM(p_version),
        BTRIM(p_title),
        p_content,
        v_content_hash,
        p_effective_from,
        NULL,
        TRUE
    )
    RETURNING id INTO v_document_id;

    RETURN v_document_id;
END;
$function$;

-- La publicación de documentos es una operación administrativa del backend.
REVOKE ALL ON FUNCTION public.publish_legal_document_version(
    TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.publish_legal_document_version(
    TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ
) TO service_role;

COMMIT;
