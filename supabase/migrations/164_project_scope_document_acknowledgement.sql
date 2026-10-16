BEGIN;

-- 164_project_scope_document_acknowledgement.sql
-- Exige un registro de confirmación documental para la misma versión y el mismo
-- PDF antes de permitir la aceptación definitiva del alcance del proyecto.
-- No modifica la migración 163 ni la Edge Function que genera el PDF.

-- ---------------------------------------------------------------------------
-- 1. Registro de confirmación documental previo a la aceptación
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.project_scope_document_acknowledgements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL
        REFERENCES public.projects(id) ON DELETE RESTRICT,
    scope_version_id uuid NOT NULL,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    company_id uuid REFERENCES public.companies(id) ON DELETE RESTRICT,
    document_path text NOT NULL CHECK (length(document_path) BETWEEN 1 AND 500),
    pdf_sha256 text NOT NULL CHECK (pdf_sha256 ~ '^[0-9a-f]{64}$'),
    acknowledged_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    user_agent text,
    CONSTRAINT project_scope_document_acknowledgements_version_project_fkey
        FOREIGN KEY (scope_version_id, project_id)
        REFERENCES public.project_scope_versions(id, project_id) ON DELETE RESTRICT,
    CONSTRAINT project_scope_document_acknowledgements_one_per_user_version
        UNIQUE (scope_version_id, user_id),
    CONSTRAINT project_scope_document_acknowledgements_user_agent_length_check
        CHECK (user_agent IS NULL OR length(user_agent) <= 2000)
);

CREATE INDEX IF NOT EXISTS project_scope_document_acknowledgements_project_idx
    ON public.project_scope_document_acknowledgements(project_id, acknowledged_at DESC);

ALTER TABLE public.project_scope_document_acknowledgements ENABLE ROW LEVEL SECURITY;

-- Las escrituras solo se realizan mediante la RPC validada.
REVOKE ALL ON TABLE public.project_scope_document_acknowledgements FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.project_scope_document_acknowledgements IS
    'Confirmación documental previa a aceptar una versión concreta del alcance; vinculada al usuario, ruta y hash exactos del PDF.';

-- ---------------------------------------------------------------------------
-- 2. Inmutabilidad del registro documental
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.protect_project_scope_document_acknowledgement_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    RAISE EXCEPTION 'Los registros de confirmación documental del alcance no se pueden modificar ni eliminar.'
        USING ERRCODE = '42501';
END;
$function$;

DROP TRIGGER IF EXISTS protect_project_scope_document_acknowledgement_immutability
    ON public.project_scope_document_acknowledgements;
CREATE TRIGGER protect_project_scope_document_acknowledgement_immutability
BEFORE UPDATE OR DELETE ON public.project_scope_document_acknowledgements
FOR EACH ROW
EXECUTE FUNCTION public.protect_project_scope_document_acknowledgement_immutability();

REVOKE ALL ON FUNCTION public.protect_project_scope_document_acknowledgement_immutability()
    FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Registrar que el cliente declara haber leído el PDF de una versión exacta
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.record_project_scope_document_acknowledgement(
    p_version_id uuid,
    p_user_agent text DEFAULT NULL
)
RETURNS public.project_scope_document_acknowledgements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_version public.project_scope_versions%ROWTYPE;
    v_project public.projects%ROWTYPE;
    v_result public.project_scope_document_acknowledgements%ROWTYPE;
    v_object storage.objects%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL
       OR NOT public.current_user_is_active()
       OR public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Solo un cliente activo puede confirmar la lectura del alcance.'
            USING ERRCODE = '42501';
    END IF;

    IF p_user_agent IS NOT NULL AND length(p_user_agent) > 2000 THEN
        RAISE EXCEPTION 'El user-agent supera la longitud permitida.';
    END IF;

    SELECT * INTO v_version
    FROM public.project_scope_versions
    WHERE id = p_version_id
    FOR UPDATE;

    IF NOT FOUND
       OR NOT v_version.is_current
       OR v_version.status <> 'pending_client'
       OR v_version.published_at IS NULL
       OR v_version.document_path IS NULL
       OR v_version.document_sha256 IS NULL THEN
        RAISE EXCEPTION 'La versión no está publicada y pendiente de aceptación.';
    END IF;

    SELECT * INTO v_project
    FROM public.projects
    WHERE id = v_version.project_id
    FOR UPDATE;

    IF NOT FOUND
       OR NOT (
            v_project.user_id = auth.uid()
            OR (
                v_project.company_id IS NOT NULL
                AND v_project.company_id = public.current_user_company_id()
            )
       ) THEN
        RAISE EXCEPTION 'No tienes acceso a este proyecto.'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_object
    FROM storage.objects
    WHERE bucket_id = 'project-scope-documents'
      AND name = v_version.document_path;

    IF NOT FOUND
       OR lower(COALESCE(v_object.metadata->>'mimetype', '')) <> 'application/pdf' THEN
        RAISE EXCEPTION 'El PDF oficial del alcance ya no está disponible o no es un PDF.';
    END IF;

    -- Hacer la RPC idempotente: si ya existe la confirmación para este usuario
    -- y versión, devolverla solo si sigue correspondiendo al mismo PDF.
    SELECT * INTO v_result
    FROM public.project_scope_document_acknowledgements
    WHERE scope_version_id = v_version.id
      AND user_id = auth.uid()
    FOR UPDATE;

    IF FOUND THEN
        IF v_result.project_id IS DISTINCT FROM v_project.id
           OR v_result.company_id IS DISTINCT FROM v_project.company_id
           OR v_result.document_path IS DISTINCT FROM v_version.document_path
           OR v_result.pdf_sha256 IS DISTINCT FROM v_version.document_sha256 THEN
            RAISE EXCEPTION 'La confirmación documental no coincide con la versión actual del PDF.';
        END IF;
        RETURN v_result;
    END IF;

    INSERT INTO public.project_scope_document_acknowledgements (
        project_id,
        scope_version_id,
        user_id,
        company_id,
        document_path,
        pdf_sha256,
        user_agent
    )
    VALUES (
        v_project.id,
        v_version.id,
        auth.uid(),
        v_project.company_id,
        v_version.document_path,
        v_version.document_sha256,
        p_user_agent
    )
    RETURNING * INTO v_result;

    RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Reforzar la aceptación: exige la confirmación documental coincidente
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.accept_project_scope(
    p_version_id uuid,
    p_acknowledged boolean,
    p_user_agent text DEFAULT NULL
)
RETURNS public.project_scope_acceptances
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_version public.project_scope_versions%ROWTYPE;
    v_project public.projects%ROWTYPE;
    v_result public.project_scope_acceptances%ROWTYPE;
    v_ack public.project_scope_document_acknowledgements%ROWTYPE;
    v_snapshot_hash text;
    v_object storage.objects%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL
       OR NOT public.current_user_is_active()
       OR public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Solo un cliente activo puede aceptar el alcance.'
            USING ERRCODE = '42501';
    END IF;

    IF p_acknowledged IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Debes confirmar que has leído y aceptas el documento de alcance.';
    END IF;

    IF p_user_agent IS NOT NULL AND length(p_user_agent) > 2000 THEN
        RAISE EXCEPTION 'El user-agent supera la longitud permitida.';
    END IF;

    SELECT * INTO v_version
    FROM public.project_scope_versions
    WHERE id = p_version_id
    FOR UPDATE;

    IF NOT FOUND
       OR NOT v_version.is_current
       OR v_version.status <> 'pending_client'
       OR v_version.published_at IS NULL
       OR v_version.document_path IS NULL
       OR v_version.document_sha256 IS NULL THEN
        RAISE EXCEPTION 'La versión no está publicada y pendiente de aceptación.';
    END IF;

    SELECT * INTO v_project
    FROM public.projects
    WHERE id = v_version.project_id
    FOR UPDATE;

    IF NOT FOUND
       OR NOT (
            v_project.user_id = auth.uid()
            OR (
                v_project.company_id IS NOT NULL
                AND v_project.company_id = public.current_user_company_id()
            )
       ) THEN
        RAISE EXCEPTION 'No tienes acceso a este proyecto.'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_object
    FROM storage.objects
    WHERE bucket_id = 'project-scope-documents'
      AND name = v_version.document_path;

    IF NOT FOUND
       OR lower(COALESCE(v_object.metadata->>'mimetype', '')) <> 'application/pdf' THEN
        RAISE EXCEPTION 'El PDF oficial del alcance ya no está disponible o no es un PDF.';
    END IF;

    -- La lectura/confirmación debe pertenecer al mismo usuario y coincidir
    -- con la versión, empresa, ruta y hash del PDF que se está aceptando.
    SELECT * INTO v_ack
    FROM public.project_scope_document_acknowledgements
    WHERE scope_version_id = v_version.id
      AND project_id = v_project.id
      AND user_id = auth.uid()
      AND company_id IS NOT DISTINCT FROM v_project.company_id
      AND document_path = v_version.document_path
      AND pdf_sha256 = v_version.document_sha256
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Debes abrir el PDF oficial y confirmar que has leído su contenido antes de aceptar el alcance.'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.project_scope_acceptances
        WHERE scope_version_id = v_version.id
    ) THEN
        RAISE EXCEPTION 'Esta versión ya tiene una aceptación registrada.';
    END IF;

    v_snapshot_hash := encode(
        extensions.digest(convert_to(v_version.content_snapshot::text, 'UTF8'), 'sha256'),
        'hex'
    );

    INSERT INTO public.project_scope_acceptances (
        project_id,
        scope_version_id,
        user_id,
        company_id,
        pdf_sha256,
        content_snapshot,
        content_snapshot_sha256,
        acknowledged,
        user_agent
    )
    VALUES (
        v_project.id,
        v_version.id,
        auth.uid(),
        v_project.company_id,
        v_version.document_sha256,
        v_version.content_snapshot,
        v_snapshot_hash,
        true,
        p_user_agent
    )
    RETURNING * INTO v_result;

    UPDATE public.project_scope_versions
    SET status = 'accepted'
    WHERE id = v_version.id;

    RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Permisos: la confirmación y la aceptación solo se ejecutan mediante RPC
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.record_project_scope_document_acknowledgement(uuid, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_project_scope_document_acknowledgement(uuid, text)
    TO authenticated;

REVOKE ALL ON FUNCTION public.accept_project_scope(uuid, boolean, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_project_scope(uuid, boolean, text)
    TO authenticated;

REVOKE ALL ON FUNCTION public.protect_project_scope_document_acknowledgement_immutability()
    FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.record_project_scope_document_acknowledgement(uuid, text) IS
    'Registra la confirmación explícita del cliente para el PDF exacto de la versión vigente del alcance.';
COMMENT ON FUNCTION public.accept_project_scope(uuid, boolean, text) IS
    'Acepta la versión vigente del alcance únicamente si existe una confirmación documental previa coincidente con el usuario y el PDF.';

-- ---------------------------------------------------------------------------
-- 6. Comprobaciones finales
-- ---------------------------------------------------------------------------

DO $verify$
BEGIN
    IF to_regclass('public.project_scope_document_acknowledgements') IS NULL THEN
        RAISE EXCEPTION 'No se ha creado la tabla de confirmaciones documentales del alcance.';
    END IF;

    IF to_regprocedure('public.record_project_scope_document_acknowledgement(uuid,text)') IS NULL
       OR to_regprocedure('public.accept_project_scope(uuid,boolean,text)') IS NULL THEN
        RAISE EXCEPTION 'Falta alguna función del flujo de confirmación documental del alcance.';
    END IF;
END;
$verify$;

COMMIT;
