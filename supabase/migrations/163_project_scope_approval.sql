BEGIN;

-- 133_project_scope_approval.sql
-- Flujo de alcance oficial de proyectos:
-- versiones inmutables una vez publicadas, PDF privado, solicitudes de cambios,
-- aceptación inmutable y activación condicionada a la aceptación de la versión vigente.
-- No modifica project_documents ni project_change_requests.

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------

CREATE TABLE public.project_scope_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL
        REFERENCES public.projects(id) ON DELETE RESTRICT,
    version_number integer NOT NULL CHECK (version_number >= 1),
    status text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'pending_client', 'changes_requested', 'accepted', 'superseded')),
    content_snapshot jsonb NOT NULL
        CHECK (jsonb_typeof(content_snapshot) = 'object'),
    document_path text,
    document_sha256 text,
    is_current boolean NOT NULL DEFAULT false,
    created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    published_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
    published_at timestamptz,
    CONSTRAINT project_scope_versions_version_unique UNIQUE (project_id, version_number),
    CONSTRAINT project_scope_versions_id_project_unique UNIQUE (id, project_id),
    CONSTRAINT project_scope_versions_path_length_check
        CHECK (document_path IS NULL OR length(document_path) <= 500),
    CONSTRAINT project_scope_versions_sha256_check
        CHECK (document_sha256 IS NULL OR document_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT project_scope_versions_publication_consistency_check
        CHECK (
            (published_at IS NULL AND published_by IS NULL
                AND document_path IS NULL AND document_sha256 IS NULL)
            OR
            (published_at IS NOT NULL AND published_by IS NOT NULL
                AND document_path IS NOT NULL AND document_sha256 IS NOT NULL)
        ),
    CONSTRAINT project_scope_versions_status_publication_check
        CHECK (status = 'draft' OR published_at IS NOT NULL)
);

CREATE UNIQUE INDEX project_scope_versions_one_current_idx
    ON public.project_scope_versions(project_id)
    WHERE is_current = true;

CREATE UNIQUE INDEX project_scope_versions_one_draft_idx
    ON public.project_scope_versions(project_id)
    WHERE status = 'draft';

CREATE INDEX project_scope_versions_project_history_idx
    ON public.project_scope_versions(project_id, version_number DESC);

CREATE TABLE public.project_scope_acceptances (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL
        REFERENCES public.projects(id) ON DELETE RESTRICT,
    scope_version_id uuid NOT NULL,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    company_id uuid REFERENCES public.companies(id) ON DELETE RESTRICT,
    CONSTRAINT project_scope_acceptances_version_project_fkey
        FOREIGN KEY (scope_version_id, project_id)
        REFERENCES public.project_scope_versions(id, project_id) ON DELETE RESTRICT,
    accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    pdf_sha256 text NOT NULL CHECK (pdf_sha256 ~ '^[0-9a-f]{64}$'),
    content_snapshot jsonb NOT NULL CHECK (jsonb_typeof(content_snapshot) = 'object'),
    content_snapshot_sha256 text NOT NULL CHECK (content_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    acknowledged boolean NOT NULL DEFAULT true CHECK (acknowledged = true),
    user_agent text,
    CONSTRAINT project_scope_acceptances_one_per_version UNIQUE (scope_version_id),
    CONSTRAINT project_scope_acceptances_user_agent_length_check
        CHECK (user_agent IS NULL OR length(user_agent) <= 2000)
);

CREATE INDEX project_scope_acceptances_project_idx
    ON public.project_scope_acceptances(project_id, accepted_at DESC);

CREATE TABLE public.project_scope_change_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL
        REFERENCES public.projects(id) ON DELETE RESTRICT,
    scope_version_id uuid NOT NULL,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL,
    comments text NOT NULL CHECK (length(btrim(comments)) BETWEEN 10 AND 5000),
    CONSTRAINT project_scope_change_requests_version_project_fkey
        FOREIGN KEY (scope_version_id, project_id)
        REFERENCES public.project_scope_versions(id, project_id) ON DELETE RESTRICT,
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'in_review', 'rejected', 'addressed')),
    user_agent text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    reviewed_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
    reviewed_at timestamptz,
    review_notes text,
    resolved_at timestamptz,
    CONSTRAINT project_scope_change_requests_user_agent_length_check
        CHECK (user_agent IS NULL OR length(user_agent) <= 2000),
    CONSTRAINT project_scope_change_requests_review_notes_length_check
        CHECK (review_notes IS NULL OR length(review_notes) <= 5000),
    CONSTRAINT project_scope_change_requests_review_consistency_check
        CHECK (
            (reviewed_by IS NULL AND reviewed_at IS NULL)
            OR
            (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
        )
);

CREATE UNIQUE INDEX project_scope_change_requests_one_open_per_version_idx
    ON public.project_scope_change_requests(scope_version_id)
    WHERE status IN ('pending', 'in_review');

CREATE INDEX project_scope_change_requests_project_idx
    ON public.project_scope_change_requests(project_id, created_at DESC);

COMMENT ON TABLE public.project_scope_versions IS
    'Versiones del documento oficial de alcance. El contenido y el PDF quedan inmutables tras su publicación.';
COMMENT ON TABLE public.project_scope_acceptances IS
    'Registro inmutable de aceptación de una versión concreta del alcance, con hashes del PDF y del snapshot.';
COMMENT ON TABLE public.project_scope_change_requests IS
    'Solicitudes de cambios vinculadas a una versión concreta del alcance; independiente de project_change_requests.';
COMMENT ON COLUMN public.project_scope_versions.content_snapshot IS
    'Snapshot JSON del alcance: objetivos, alcance incluido/excluido, fases, entregables, criterios de aceptación, dependencias y condiciones.';

-- ---------------------------------------------------------------------------
-- 2. RLS: lectura limitada. Las escrituras pasan por RPC validadas.
-- ---------------------------------------------------------------------------

ALTER TABLE public.project_scope_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_scope_acceptances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_scope_change_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.project_scope_versions FROM anon, authenticated;
REVOKE ALL ON TABLE public.project_scope_acceptances FROM anon, authenticated;
REVOKE ALL ON TABLE public.project_scope_change_requests FROM anon, authenticated;

GRANT SELECT ON TABLE public.project_scope_versions TO authenticated;
GRANT SELECT ON TABLE public.project_scope_acceptances TO authenticated;
GRANT SELECT ON TABLE public.project_scope_change_requests TO authenticated;

DROP POLICY IF EXISTS project_scope_versions_select ON public.project_scope_versions;
CREATE POLICY project_scope_versions_select
ON public.project_scope_versions
FOR SELECT TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('projects.read')
    )
    OR
    (
        published_at IS NOT NULL
        AND public.current_user_is_active()
        AND NOT public.current_user_is_worker()
        AND EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_scope_versions.project_id
              AND (
                    p.user_id = auth.uid()
                    OR (
                        p.company_id IS NOT NULL
                        AND p.company_id = public.current_user_company_id()
                    )
              )
        )
    )
);

DROP POLICY IF EXISTS project_scope_acceptances_select ON public.project_scope_acceptances;
CREATE POLICY project_scope_acceptances_select
ON public.project_scope_acceptances
FOR SELECT TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('projects.read')
    )
    OR
    (
        public.current_user_is_active()
        AND NOT public.current_user_is_worker()
        AND user_id = auth.uid()
    )
);

DROP POLICY IF EXISTS project_scope_change_requests_select ON public.project_scope_change_requests;
CREATE POLICY project_scope_change_requests_select
ON public.project_scope_change_requests
FOR SELECT TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('projects.read')
    )
    OR
    (
        public.current_user_is_active()
        AND NOT public.current_user_is_worker()
        AND user_id = auth.uid()
    )
);

-- ---------------------------------------------------------------------------
-- 3. Protección de inmutabilidad de versiones publicadas y aceptaciones
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.protect_project_scope_version_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.published_at IS NOT NULL THEN
            RAISE EXCEPTION 'No se puede eliminar una versión publicada del alcance.'
                USING ERRCODE = '42501';
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.published_at IS NOT NULL AND (
        NEW.project_id IS DISTINCT FROM OLD.project_id
        OR NEW.version_number IS DISTINCT FROM OLD.version_number
        OR NEW.content_snapshot IS DISTINCT FROM OLD.content_snapshot
        OR NEW.document_path IS DISTINCT FROM OLD.document_path
        OR NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256
        OR NEW.created_by IS DISTINCT FROM OLD.created_by
        OR NEW.created_at IS DISTINCT FROM OLD.created_at
        OR NEW.published_by IS DISTINCT FROM OLD.published_by
        OR NEW.published_at IS DISTINCT FROM OLD.published_at
    ) THEN
        RAISE EXCEPTION 'El contenido de una versión publicada del alcance es inmutable.'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS protect_project_scope_version_immutability
ON public.project_scope_versions;
CREATE TRIGGER protect_project_scope_version_immutability
BEFORE UPDATE OR DELETE ON public.project_scope_versions
FOR EACH ROW
EXECUTE FUNCTION public.protect_project_scope_version_immutability();

CREATE OR REPLACE FUNCTION public.protect_project_scope_acceptance_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    RAISE EXCEPTION 'Los registros de aceptación del alcance no se pueden modificar ni eliminar.'
        USING ERRCODE = '42501';
END;
$function$;

DROP TRIGGER IF EXISTS protect_project_scope_acceptance_immutability
ON public.project_scope_acceptances;
CREATE TRIGGER protect_project_scope_acceptance_immutability
BEFORE UPDATE OR DELETE ON public.project_scope_acceptances
FOR EACH ROW
EXECUTE FUNCTION public.protect_project_scope_acceptance_immutability();

REVOKE ALL ON FUNCTION public.protect_project_scope_version_immutability() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.protect_project_scope_acceptance_immutability() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Bucket privado del PDF oficial del alcance
-- ---------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'project-scope-documents',
    'project-scope-documents',
    false,
    10485760,
    ARRAY['application/pdf']::text[]
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = 10485760,
    allowed_mime_types = ARRAY['application/pdf']::text[];

DROP POLICY IF EXISTS project_scope_documents_worker_upload ON storage.objects;
CREATE POLICY project_scope_documents_worker_upload
ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
    bucket_id = 'project-scope-documents'
    AND public.current_user_is_worker()
    AND public.current_worker_has_permission('projects.update')
    AND (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id::text = (storage.foldername(name))[1]
    )
);

DROP POLICY IF EXISTS project_scope_documents_select ON storage.objects;
CREATE POLICY project_scope_documents_select
ON storage.objects
FOR SELECT TO authenticated
USING (
    bucket_id = 'project-scope-documents'
    AND (
        (
            public.current_user_is_worker()
            AND public.current_worker_has_permission('projects.read')
            AND EXISTS (
                SELECT 1
                FROM public.projects p
                WHERE p.id::text = (storage.foldername(name))[1]
            )
        )
        OR
        (
            public.current_user_is_active()
            AND NOT public.current_user_is_worker()
            AND EXISTS (
                SELECT 1
                FROM public.project_scope_versions v
                JOIN public.projects p ON p.id = v.project_id
                WHERE v.document_path = name
                  AND v.published_at IS NOT NULL
                  AND (
                        p.user_id = auth.uid()
                        OR (
                            p.company_id IS NOT NULL
                            AND p.company_id = public.current_user_company_id()
                        )
                  )
            )
        )
    )
);

-- No se crean políticas de UPDATE o DELETE para este bucket:
-- los PDF oficiales no se sobrescriben ni se eliminan desde el cliente.

-- ---------------------------------------------------------------------------
-- 5. Crear y editar borradores
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_project_scope_draft(
    p_project_id uuid,
    p_content_snapshot jsonb
)
RETURNS public.project_scope_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_project public.projects%ROWTYPE;
    v_current_status text;
    v_next_version integer;
    v_result public.project_scope_versions%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Se requiere un trabajador autenticado.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public.require_current_worker_permission('projects.update');

    IF p_project_id IS NULL
       OR p_content_snapshot IS NULL
       OR jsonb_typeof(p_content_snapshot) <> 'object'
       OR pg_column_size(p_content_snapshot) > 262144 THEN
        RAISE EXCEPTION 'El proyecto y un alcance JSON válido de hasta 256 KiB son obligatorios.';
    END IF;

    SELECT * INTO v_project
    FROM public.projects
    WHERE id = p_project_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el proyecto indicado.';
    END IF;

    IF v_project.estado IN ('Entregado', 'Completado') THEN
        RAISE EXCEPTION 'No se puede crear o modificar el alcance de un proyecto finalizado.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.project_scope_versions
        WHERE project_id = p_project_id AND status = 'draft'
    ) THEN
        RAISE EXCEPTION 'Ya existe un borrador del alcance para este proyecto.';
    END IF;

    SELECT status INTO v_current_status
    FROM public.project_scope_versions
    WHERE project_id = p_project_id AND is_current = true
    FOR UPDATE;

    IF v_current_status IS NOT NULL
       AND v_current_status NOT IN ('changes_requested', 'accepted') THEN
        RAISE EXCEPTION 'No se puede crear una versión nueva mientras la versión vigente espera respuesta del cliente.';
    END IF;

    SELECT COALESCE(MAX(version_number), 0) + 1
    INTO v_next_version
    FROM public.project_scope_versions
    WHERE project_id = p_project_id;

    INSERT INTO public.project_scope_versions (
        project_id, version_number, status, content_snapshot, created_by
    )
    VALUES (
        p_project_id, v_next_version, 'draft', p_content_snapshot, auth.uid()
    )
    RETURNING * INTO v_result;

    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_project_scope_draft(
    p_version_id uuid,
    p_content_snapshot jsonb
)
RETURNS public.project_scope_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_version public.project_scope_versions%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Se requiere un trabajador autenticado.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public.require_current_worker_permission('projects.update');

    IF p_content_snapshot IS NULL
       OR jsonb_typeof(p_content_snapshot) <> 'object'
       OR pg_column_size(p_content_snapshot) > 262144 THEN
        RAISE EXCEPTION 'El alcance debe ser un objeto JSON válido de hasta 256 KiB.';
    END IF;

    SELECT * INTO v_version
    FROM public.project_scope_versions
    WHERE id = p_version_id
    FOR UPDATE;

    IF NOT FOUND OR v_version.status <> 'draft' OR v_version.published_at IS NOT NULL THEN
        RAISE EXCEPTION 'Solo se pueden editar borradores no publicados.';
    END IF;

    UPDATE public.project_scope_versions
    SET content_snapshot = p_content_snapshot
    WHERE id = p_version_id
    RETURNING * INTO v_version;

    RETURN v_version;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Publicar versión tras generar y subir el PDF
-- Ruta obligatoria: <project_uuid>/V<version_number>.pdf
-- La Edge Function debe calcular el SHA-256 real de los bytes del PDF.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.publish_project_scope_version(
    p_version_id uuid,
    p_document_path text,
    p_document_sha256 text
)
RETURNS public.project_scope_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_version public.project_scope_versions%ROWTYPE;
    v_project public.projects%ROWTYPE;
    v_object storage.objects%ROWTYPE;
    v_expected_path text;
BEGIN
    -- La Edge Function debe generar el PDF, calcular el SHA-256 real de sus
    -- bytes y llamar a esta RPC con el JWT del trabajador autenticado.
    IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Se requiere un trabajador autenticado.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public.require_current_worker_permission('projects.update');

    IF p_version_id IS NULL
       OR p_document_path IS NULL
       OR p_document_sha256 IS NULL
       OR p_document_sha256 !~ '^[0-9a-fA-F]{64}$' THEN
        RAISE EXCEPTION 'La versión, la ruta y el SHA-256 del PDF son obligatorios.';
    END IF;

    SELECT * INTO v_version
    FROM public.project_scope_versions
    WHERE id = p_version_id
    FOR UPDATE;

    IF NOT FOUND OR v_version.status <> 'draft' OR v_version.published_at IS NOT NULL THEN
        RAISE EXCEPTION 'Solo se puede publicar un borrador no publicado.';
    END IF;

    SELECT * INTO v_project
    FROM public.projects
    WHERE id = v_version.project_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el proyecto asociado.';
    END IF;

    v_expected_path := v_version.project_id::text || '/V' || v_version.version_number::text || '.pdf';

    IF p_document_path <> v_expected_path THEN
        RAISE EXCEPTION 'La ruta del PDF no corresponde a la versión que se está publicando.';
    END IF;

    SELECT * INTO v_object
    FROM storage.objects
    WHERE bucket_id = 'project-scope-documents'
      AND name = p_document_path;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encuentra el PDF en el bucket privado del alcance.';
    END IF;

    IF lower(COALESCE(v_object.metadata->>'mimetype', '')) <> 'application/pdf' THEN
        RAISE EXCEPTION 'El documento del alcance debe ser un PDF.';
    END IF;

    IF v_object.metadata ? 'size'
       AND (v_object.metadata->>'size') ~ '^[0-9]+$'
       AND (v_object.metadata->>'size')::bigint > 10485760 THEN
        RAISE EXCEPTION 'El PDF del alcance no puede superar 10 MiB.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.project_scope_versions
        WHERE project_id = v_version.project_id
          AND is_current = true
          AND status NOT IN ('changes_requested', 'accepted')
    ) THEN
        RAISE EXCEPTION 'La versión vigente aún no permite publicar una nueva versión.';
    END IF;

    -- La versión anterior se conserva en el historial, pero deja de ser vigente.
    UPDATE public.project_scope_versions
    SET is_current = false,
        status = 'superseded'
    WHERE project_id = v_version.project_id
      AND is_current = true;

    UPDATE public.project_scope_change_requests
    SET status = 'addressed',
        reviewed_by = auth.uid(),
        reviewed_at = clock_timestamp(),
        resolved_at = clock_timestamp(),
        review_notes = left(
            concat_ws(
                E'\n',
                NULLIF(review_notes, ''),
                'Se ha publicado la versión V' || v_version.version_number::text || ' del alcance.'
            ),
            5000
        )
    WHERE project_id = v_version.project_id
      AND scope_version_id IN (
          SELECT id
          FROM public.project_scope_versions
          WHERE project_id = v_version.project_id
            AND status = 'superseded'
      )
      AND status IN ('pending', 'in_review');

    UPDATE public.project_scope_versions
    SET status = 'pending_client',
        is_current = true,
        document_path = p_document_path,
        document_sha256 = lower(p_document_sha256),
        published_by = auth.uid(),
        published_at = clock_timestamp()
    WHERE id = p_version_id
    RETURNING * INTO v_version;

    -- Si se modifica un alcance de un proyecto activo, se pausa hasta aprobar
    -- la nueva versión.
    UPDATE public.projects
    SET estado = 'Pausado'
    WHERE id = v_version.project_id
      AND estado = 'Activo';

    RETURN v_version;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. Solicitar cambios: solo el cliente del proyecto, sobre la versión vigente
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_project_scope_changes(
    p_version_id uuid,
    p_comments text,
    p_user_agent text DEFAULT NULL
)
RETURNS public.project_scope_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_version public.project_scope_versions%ROWTYPE;
    v_project public.projects%ROWTYPE;
    v_result public.project_scope_change_requests%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL
       OR NOT public.current_user_is_active()
       OR public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Solo un cliente activo puede solicitar cambios al alcance.'
            USING ERRCODE = '42501';
    END IF;

    IF p_comments IS NULL OR length(btrim(p_comments)) NOT BETWEEN 10 AND 5000 THEN
        RAISE EXCEPTION 'Explica los cambios solicitados (entre 10 y 5000 caracteres).';
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
       OR v_version.published_at IS NULL THEN
        RAISE EXCEPTION 'Solo se pueden solicitar cambios sobre la versión vigente pendiente de revisión.';
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

    INSERT INTO public.project_scope_change_requests (
        project_id, scope_version_id, user_id, company_id, comments, user_agent
    )
    VALUES (
        v_project.id, v_version.id, auth.uid(),
        public.current_user_company_id(), btrim(p_comments), p_user_agent
    )
    RETURNING * INTO v_result;

    UPDATE public.project_scope_versions
    SET status = 'changes_requested'
    WHERE id = v_version.id;

    RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. Revisar una solicitud: el trabajador puede ponerla en revisión o rechazarla
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.resolve_project_scope_change_request(
    p_request_id uuid,
    p_action text,
    p_review_notes text DEFAULT NULL
)
RETURNS public.project_scope_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_request public.project_scope_change_requests%ROWTYPE;
    v_result public.project_scope_change_requests%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Se requiere un trabajador autenticado.'
            USING ERRCODE = '42501';
    END IF;

    PERFORM public.require_current_worker_permission('projects.update');

    IF p_action IS NULL OR p_action NOT IN ('in_review', 'rejected') THEN
        RAISE EXCEPTION 'Acción no válida. Usa in_review o rejected.';
    END IF;

    IF p_review_notes IS NOT NULL AND length(p_review_notes) > 5000 THEN
        RAISE EXCEPTION 'Las notas de revisión no pueden superar 5000 caracteres.';
    END IF;

    SELECT * INTO v_request
    FROM public.project_scope_change_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF NOT FOUND OR v_request.status NOT IN ('pending', 'in_review') THEN
        RAISE EXCEPTION 'La solicitud no existe o ya está resuelta.';
    END IF;

    UPDATE public.project_scope_change_requests
    SET status = p_action,
        reviewed_by = auth.uid(),
        reviewed_at = clock_timestamp(),
        resolved_at = CASE WHEN p_action = 'rejected' THEN clock_timestamp() ELSE NULL END,
        review_notes = p_review_notes
    WHERE id = p_request_id
    RETURNING * INTO v_result;

    IF p_action = 'rejected' THEN
        UPDATE public.project_scope_versions
        SET status = 'pending_client'
        WHERE id = v_request.scope_version_id
          AND is_current = true
          AND status = 'changes_requested';
    END IF;

    RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 9. Aceptar una versión exacta del alcance
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
-- 10. No activar un proyecto sin aceptar la versión vigente del alcance
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.guard_project_scope_activation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_has_accepted_scope boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.estado = 'Activo' THEN
            RAISE EXCEPTION 'Un proyecto nuevo debe comenzar en Pendiente y requiere un alcance aceptado antes de activarse.'
                USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.estado = 'Activo' AND OLD.estado IS DISTINCT FROM NEW.estado THEN
        IF auth.uid() IS NULL
           OR NOT public.current_user_is_worker()
           OR NOT public.current_worker_has_permission('projects.update') THEN
            RAISE EXCEPTION 'Solo un trabajador autorizado puede activar un proyecto.'
                USING ERRCODE = '42501';
        END IF;

        SELECT EXISTS (
            SELECT 1
            FROM public.project_scope_versions v
            JOIN public.project_scope_acceptances a
              ON a.scope_version_id = v.id
             AND a.project_id = v.project_id
            WHERE v.project_id = NEW.id
              AND v.is_current = true
              AND v.status = 'accepted'
              AND v.published_at IS NOT NULL
              AND v.document_sha256 = a.pdf_sha256
        )
        INTO v_has_accepted_scope;

        IF NOT v_has_accepted_scope THEN
            RAISE EXCEPTION 'No se puede activar el proyecto sin aceptación registrada de su versión vigente del alcance.'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS guard_project_scope_activation_insert ON public.projects;
CREATE TRIGGER guard_project_scope_activation_insert
BEFORE INSERT ON public.projects
FOR EACH ROW
EXECUTE FUNCTION public.guard_project_scope_activation();

DROP TRIGGER IF EXISTS guard_project_scope_activation_update ON public.projects;
CREATE TRIGGER guard_project_scope_activation_update
BEFORE UPDATE OF estado ON public.projects
FOR EACH ROW
EXECUTE FUNCTION public.guard_project_scope_activation();

-- Los proyectos que utilizan el nuevo flujo no pueden recibir nuevos hitos
-- hasta que la versión vigente del alcance esté aceptada. Proyectos históricos
-- sin versiones de alcance siguen funcionando como antes.
CREATE OR REPLACE FUNCTION public.guard_project_milestone_scope_acceptance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_has_scope boolean;
    v_has_accepted_scope boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM public.project_scope_versions v
        WHERE v.project_id = NEW.project_id
    )
    INTO v_has_scope;

    IF NOT v_has_scope THEN
        RETURN NEW;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM public.project_scope_versions v
        JOIN public.project_scope_acceptances a
          ON a.scope_version_id = v.id
         AND a.project_id = v.project_id
        WHERE v.project_id = NEW.project_id
          AND v.is_current = true
          AND v.status = 'accepted'
          AND v.document_sha256 = a.pdf_sha256
    )
    INTO v_has_accepted_scope;

    IF NOT v_has_accepted_scope THEN
        RAISE EXCEPTION 'No se pueden crear hitos hasta que el cliente acepte la versión vigente del alcance.'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS guard_project_milestone_scope_acceptance
ON public.project_milestones;
CREATE TRIGGER guard_project_milestone_scope_acceptance
BEFORE INSERT ON public.project_milestones
FOR EACH ROW
EXECUTE FUNCTION public.guard_project_milestone_scope_acceptance();

REVOKE ALL ON FUNCTION public.guard_project_scope_activation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_project_milestone_scope_acceptance() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 11. Permisos de ejecución: solo usuarios autenticados; las funciones validan rol
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.create_project_scope_draft(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_project_scope_draft(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.publish_project_scope_version(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_project_scope_changes(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_project_scope_change_request(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.accept_project_scope(uuid, boolean, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_project_scope_draft(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_project_scope_draft(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_project_scope_version(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_project_scope_changes(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_project_scope_change_request(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_project_scope(uuid, boolean, text) TO authenticated;

COMMENT ON FUNCTION public.create_project_scope_draft(uuid, jsonb) IS
    'Crea un borrador de alcance para un proyecto; requiere projects.update.';
COMMENT ON FUNCTION public.update_project_scope_draft(uuid, jsonb) IS
    'Actualiza únicamente borradores no publicados del alcance.';
COMMENT ON FUNCTION public.publish_project_scope_version(uuid, text, text) IS
    'Publica una versión inmutable del alcance después de verificar la existencia del PDF privado.';
COMMENT ON FUNCTION public.request_project_scope_changes(uuid, text, text) IS
    'Registra una solicitud de cambios del cliente asociada a una versión vigente concreta.';
COMMENT ON FUNCTION public.resolve_project_scope_change_request(uuid, text, text) IS
    'Permite al trabajador revisar o rechazar una solicitud de cambios del alcance.';
COMMENT ON FUNCTION public.accept_project_scope(uuid, boolean, text) IS
    'Registra la aceptación inmutable del cliente para la versión vigente exacta del alcance.';

-- ---------------------------------------------------------------------------
-- 12. Comprobaciones finales de la migración
-- ---------------------------------------------------------------------------

DO $verify$
BEGIN
    IF to_regclass('public.project_scope_versions') IS NULL
       OR to_regclass('public.project_scope_acceptances') IS NULL
       OR to_regclass('public.project_scope_change_requests') IS NULL THEN
        RAISE EXCEPTION 'Falta alguna tabla del flujo de alcance.';
    END IF;

    IF to_regprocedure('public.accept_project_scope(uuid,boolean,text)') IS NULL
       OR to_regprocedure('public.publish_project_scope_version(uuid,text,text)') IS NULL
       OR to_regprocedure('public.request_project_scope_changes(uuid,text,text)') IS NULL THEN
        RAISE EXCEPTION 'Falta alguna función esencial del flujo de alcance.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM storage.buckets
        WHERE id = 'project-scope-documents' AND public = false
    ) THEN
        RAISE EXCEPTION 'No se ha configurado el bucket privado del alcance.';
    END IF;
END;
$verify$;

COMMIT;
