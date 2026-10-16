BEGIN;

-- ============================================================
-- MODIRA — 074_maintenance_custom_proposal_employee_workflow.sql
-- ============================================================
--
-- OBJETIVO
--
-- Completar el flujo de propuestas personalizadas de mantenimiento
-- para que Modira pueda gestionarlas desde el Employee Area:
--
-- CLIENTE
--   draft
--      ↓
--   submitted
--      ↓
-- EMPLEADO
--   in_review
--      ├── clarification_requested → cliente aporta información → submitted
--      ├── rejected
--      └── quoted + PDF firmado/versionado
--                    ↓
-- CLIENTE
--   lee/revisa PDF + checkbox de aceptación del documento
--                    ↓
--   accepted
--                    ↓
-- Stripe / maintenance_contracts (Edge Function existente)
--
-- IMPORTANTE
--
-- - NO sustituye 069/070.
-- - NO modifica la arquitectura Stripe.
-- - NO permite que un worker "acepte" una propuesta como cliente.
-- - "quoted" significa que Modira ha enviado una oferta.
-- - "accepted" sigue significando aceptación del cliente.
-- - El PDF vive en Storage privado.
-- - El SHA-256 se calcula server-side y se guarda en BD.
-- - La aceptación contractual queda bloqueada si no existe
--   acknowledgement del PDF actualmente publicado.
-- - Las notificaciones se dirigen al cliente real de la propuesta;
--   el frontend no puede elegir el user_id receptor.
--
-- ============================================================


-- ============================================================
-- 0. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_custom_proposals'
    ) THEN
        RAISE EXCEPTION
            '074 stopped: maintenance_custom_proposals does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'notifications'
    ) THEN
        RAISE EXCEPTION
            '074 stopped: notifications does not exist';
    END IF;

    IF to_regprocedure(
        'public.current_user_is_worker()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '074 stopped: current_user_is_worker() does not exist';
    END IF;

    IF to_regprocedure(
        'public.current_user_is_active()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '074 stopped: current_user_is_active() does not exist';
    END IF;

    IF to_regprocedure(
        'public.enforce_security_rate_limit(text, integer, integer)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '074 stopped: enforce_security_rate_limit(text, integer, integer) does not exist';
    END IF;

END $$;


-- ============================================================
-- 1. NUEVOS CAMPOS EN LA PROPUESTA
-- ============================================================
--
-- No duplicamos los campos comerciales que ya existen en 069.
-- Añadimos únicamente la trazabilidad necesaria para la revisión
-- del worker y la relación con el documento actualmente publicado.
--

ALTER TABLE public.maintenance_custom_proposals
    ADD COLUMN IF NOT EXISTS reviewed_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    ADD COLUMN IF NOT EXISTS quoted_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    ADD COLUMN IF NOT EXISTS clarification_requested_at TIMESTAMPTZ,

    ADD COLUMN IF NOT EXISTS clarification_requested_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    ADD COLUMN IF NOT EXISTS clarification_message TEXT,

    ADD COLUMN IF NOT EXISTS response_notes TEXT,

    ADD COLUMN IF NOT EXISTS response_version INTEGER
        NOT NULL DEFAULT 0,

    ADD COLUMN IF NOT EXISTS current_document_id UUID;


-- ============================================================
-- 2. NUEVO ESTADO — clarification_requested
-- ============================================================

ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_status_check;

ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_status_check
    CHECK (
        status IN (
            'draft',
            'submitted',
            'in_review',
            'clarification_requested',
            'quoted',
            'accepted',
            'rejected',
            'cancelled',
            'expired'
        )
    );


-- ============================================================
-- 3. CONSTRAINTS DE LOS NUEVOS CAMPOS
-- ============================================================

ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_response_version_check;

ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_response_version_check
    CHECK (response_version >= 0);


ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_clarification_message_check;

ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_clarification_message_check
    CHECK (
        clarification_message IS NULL
        OR (
            LENGTH(BTRIM(clarification_message)) > 0
            AND LENGTH(clarification_message) <= 4000
        )
    );


ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_response_notes_check;

ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_response_notes_check
    CHECK (
        response_notes IS NULL
        OR LENGTH(response_notes) <= 5000
    );


-- ============================================================
-- 4. UNA SOLA PROPUESTA ABIERTA POR EMPRESA
-- ============================================================
--
-- 069 ya tenía este índice, pero clarification_requested también
-- debe bloquear una segunda propuesta abierta.
--

DROP INDEX IF EXISTS
    public.idx_maintenance_custom_proposals_one_open_per_company;

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_one_open_per_company
ON public.maintenance_custom_proposals (
    company_id
)
WHERE status IN (
    'draft',
    'submitted',
    'in_review',
    'clarification_requested',
    'quoted'
);


-- ============================================================
-- 5. TABLA DE DOCUMENTOS DE RESPUESTA DE MODIRA
-- ============================================================
--
-- Se mantiene el PDF separado de maintenance_custom_proposals.
-- Esto permite conservar versiones y no sobrescribir un documento
-- que el cliente ya haya aceptado.
--

CREATE TABLE IF NOT EXISTS public.maintenance_custom_proposal_documents (

    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    proposal_id UUID NOT NULL
        REFERENCES public.maintenance_custom_proposals(id)
        ON DELETE RESTRICT,

    version INTEGER NOT NULL,

    document_path TEXT NOT NULL,

    document_mime_type TEXT NOT NULL DEFAULT 'application/pdf',

    document_file_size BIGINT,

    document_sha256 TEXT NOT NULL,

    document_uploaded_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    document_uploaded_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    published_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT
        maintenance_custom_proposal_documents_version_check
    CHECK (version > 0),

    CONSTRAINT
        maintenance_custom_proposal_documents_mime_check
    CHECK (
        LOWER(TRIM(document_mime_type)) = 'application/pdf'
    ),

    CONSTRAINT
        maintenance_custom_proposal_documents_size_check
    CHECK (
        document_file_size IS NULL
        OR (
            document_file_size > 0
            AND document_file_size <= 20971520
        )
    ),

    CONSTRAINT
        maintenance_custom_proposal_documents_sha256_check
    CHECK (
        document_sha256 ~ '^[0-9a-fA-F]{64}$'
    ),

    CONSTRAINT
        maintenance_custom_proposal_documents_path_check
    CHECK (
        LENGTH(BTRIM(document_path)) > 0
        AND LENGTH(document_path) <= 500
        AND document_path ~
            '^[0-9a-fA-F-]{36}/[^/]+\.pdf$'
    ),

    CONSTRAINT
        maintenance_custom_proposal_documents_unique_version
    UNIQUE (proposal_id, version),

    CONSTRAINT
        maintenance_custom_proposal_documents_unique_path
    UNIQUE (document_path)
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_documents_proposal
ON public.maintenance_custom_proposal_documents (
    proposal_id,
    version DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_documents_published
ON public.maintenance_custom_proposal_documents (
    proposal_id,
    published_at DESC
)
WHERE published_at IS NOT NULL;


CREATE UNIQUE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_documents_one_published_current
ON public.maintenance_custom_proposal_documents (
    proposal_id
)
WHERE published_at IS NOT NULL;


-- ============================================================
-- 6. RELACIÓN PROPUESTA → DOCUMENTO ACTUAL
-- ============================================================

ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_current_document_id_fkey;

ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_current_document_id_fkey
    FOREIGN KEY (current_document_id)
    REFERENCES public.maintenance_custom_proposal_documents(id)
    ON DELETE RESTRICT;


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_current_document
ON public.maintenance_custom_proposals (
    current_document_id
)
WHERE current_document_id IS NOT NULL;


-- ============================================================
-- 7. TABLA DE ACKNOWLEDGEMENT DEL PDF
-- ============================================================
--
-- Este registro NO es la aceptación contractual.
--
-- Significa:
--
-- "El cliente ha declarado haber leído/revisado este PDF concreto."
--
-- La aceptación contractual continúa siendo:
--
-- maintenance_custom_proposals.status = 'accepted'
--
-- El acknowledgement queda ligado a:
-- - proposal
-- - documento
-- - hash
-- - versión del texto del checkbox
--

CREATE TABLE IF NOT EXISTS
public.maintenance_custom_proposal_document_acknowledgements (

    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    proposal_id UUID NOT NULL
        REFERENCES public.maintenance_custom_proposals(id)
        ON DELETE RESTRICT,

    document_id UUID NOT NULL
        REFERENCES public.maintenance_custom_proposal_documents(id)
        ON DELETE RESTRICT,

    user_id UUID NOT NULL
        REFERENCES auth.users(id)
        ON DELETE RESTRICT,

    company_id UUID NOT NULL
        REFERENCES public.companies(id)
        ON DELETE RESTRICT,

    document_path TEXT NOT NULL,

    document_sha256 TEXT NOT NULL,

    acknowledgement_text_version TEXT NOT NULL,

    accepted_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT
        maintenance_custom_proposal_ack_sha256_check
    CHECK (
        document_sha256 ~ '^[0-9a-fA-F]{64}$'
    ),

    CONSTRAINT
        maintenance_custom_proposal_ack_path_check
    CHECK (
        LENGTH(BTRIM(document_path)) > 0
        AND LENGTH(document_path) <= 500
    ),

    CONSTRAINT
        maintenance_custom_proposal_ack_version_check
    CHECK (
        LENGTH(BTRIM(acknowledgement_text_version)) > 0
        AND LENGTH(acknowledgement_text_version) <= 100
    ),

    CONSTRAINT
        maintenance_custom_proposal_ack_unique
    UNIQUE (
        proposal_id,
        user_id,
        document_id,
        acknowledgement_text_version
    )
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_ack_proposal
ON public.maintenance_custom_proposal_document_acknowledgements (
    proposal_id,
    accepted_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_ack_document
ON public.maintenance_custom_proposal_document_acknowledgements (
    document_id,
    accepted_at DESC
);


-- ============================================================
-- 8. TABLA DE HISTÓRICO / AUDITORÍA
-- ============================================================

CREATE TABLE IF NOT EXISTS
public.maintenance_custom_proposal_events (

    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    proposal_id UUID NOT NULL
        REFERENCES public.maintenance_custom_proposals(id)
        ON DELETE RESTRICT,

    actor_id UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    actor_type TEXT NOT NULL DEFAULT 'user',

    event_type TEXT NOT NULL,

    old_status TEXT,

    new_status TEXT,

    notes TEXT,

    metadata JSONB,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT
        maintenance_custom_proposal_events_actor_type_check
    CHECK (
        actor_type IN (
            'client',
            'worker',
            'system'
        )
    ),

    CONSTRAINT
        maintenance_custom_proposal_events_type_check
    CHECK (
        event_type IN (
            'created',
            'submitted',
            'review_started',
            'clarification_requested',
            'clarification_resubmitted',
            'quoted',
            'rejected',
            'accepted',
            'document_uploaded',
            'document_published',
            'document_acknowledged',
            'expired',
            'cancelled'
        )
    ),

    CONSTRAINT
        maintenance_custom_proposal_events_notes_check
    CHECK (
        notes IS NULL
        OR LENGTH(notes) <= 5000
    ),

    CONSTRAINT
        maintenance_custom_proposal_events_metadata_check
    CHECK (
        metadata IS NULL
        OR pg_column_size(metadata) <= 8192
    )
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_events_proposal
ON public.maintenance_custom_proposal_events (
    proposal_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_events_type
ON public.maintenance_custom_proposal_events (
    event_type,
    created_at DESC
);


-- ============================================================
-- 9. RLS — DOCUMENTOS
-- ============================================================

ALTER TABLE public.maintenance_custom_proposal_documents
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS
    maintenance_custom_proposal_documents_client_select
ON public.maintenance_custom_proposal_documents;


CREATE POLICY
    maintenance_custom_proposal_documents_client_select
ON public.maintenance_custom_proposal_documents
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND published_at IS NOT NULL
    AND EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposals p
        WHERE p.id = maintenance_custom_proposal_documents.proposal_id
          AND p.user_id = auth.uid()
          AND p.company_id = public.current_user_company_id()
          AND p.current_document_id =
              maintenance_custom_proposal_documents.id
    )
);


DROP POLICY IF EXISTS
    maintenance_custom_proposal_documents_worker_select
ON public.maintenance_custom_proposal_documents;


CREATE POLICY
    maintenance_custom_proposal_documents_worker_select
ON public.maintenance_custom_proposal_documents
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_custom_proposal_documents
FROM PUBLIC, anon, authenticated;


GRANT SELECT
ON public.maintenance_custom_proposal_documents
TO authenticated;


-- ============================================================
-- 10. RLS — ACKNOWLEDGEMENTS
-- ============================================================

ALTER TABLE
public.maintenance_custom_proposal_document_acknowledgements
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS
    maintenance_custom_proposal_ack_client_select
ON public.maintenance_custom_proposal_document_acknowledgements;


CREATE POLICY
    maintenance_custom_proposal_ack_client_select
ON public.maintenance_custom_proposal_document_acknowledgements
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
    AND company_id = public.current_user_company_id()
);


DROP POLICY IF EXISTS
    maintenance_custom_proposal_ack_worker_select
ON public.maintenance_custom_proposal_document_acknowledgements;


CREATE POLICY
    maintenance_custom_proposal_ack_worker_select
ON public.maintenance_custom_proposal_document_acknowledgements
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_custom_proposal_document_acknowledgements
FROM PUBLIC, anon, authenticated;


GRANT SELECT
ON public.maintenance_custom_proposal_document_acknowledgements
TO authenticated;


-- ============================================================
-- 11. RLS — EVENTOS
-- ============================================================

ALTER TABLE public.maintenance_custom_proposal_events
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS
    maintenance_custom_proposal_events_client_select
ON public.maintenance_custom_proposal_events;


CREATE POLICY
    maintenance_custom_proposal_events_client_select
ON public.maintenance_custom_proposal_events
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposals p
        WHERE p.id = maintenance_custom_proposal_events.proposal_id
          AND p.user_id = auth.uid()
          AND p.company_id = public.current_user_company_id()
    )
);


DROP POLICY IF EXISTS
    maintenance_custom_proposal_events_worker_select
ON public.maintenance_custom_proposal_events;


CREATE POLICY
    maintenance_custom_proposal_events_worker_select
ON public.maintenance_custom_proposal_events
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_custom_proposal_events
FROM PUBLIC, anon, authenticated;


GRANT SELECT
ON public.maintenance_custom_proposal_events
TO authenticated;


-- ============================================================
-- 12. NOTIFICATIONS — AÑADIR TIPO DE MANTENIMIENTO
-- ============================================================

ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_tipo_check;


ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_tipo_check
    CHECK (
        tipo IN (
            'milestone_completed',
            'information_requested',
            'project_update',
            'document_available',
            'quotation',
            'invoice',
            'project_change_request',
            'maintenance_proposal',
            'system'
        )
    );


-- ============================================================
-- 13. STORAGE — BUCKET PRIVADO
-- ============================================================
--
-- 20 MiB y únicamente PDF, siguiendo el patrón de seguridad
-- documental que ya utiliza Modira.
--

INSERT INTO storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
VALUES (
    'maintenance-proposals',
    'maintenance-proposals',
    FALSE,
    20971520,
    ARRAY['application/pdf']::TEXT[]
)
ON CONFLICT (id)
DO UPDATE SET
    public = FALSE,
    file_size_limit = 20971520,
    allowed_mime_types = ARRAY['application/pdf']::TEXT[];


-- ============================================================
-- 14. STORAGE — FUNCIONES SEGURAS PARA RUTAS DE WORKER
-- ============================================================
--
-- READ:
--   Permite al worker consultar documentos históricos de la
--   propuesta, incluidos los ya publicados como quoted.
--
-- WRITE:
--   Solo permite subir durante la revisión y además aplica
--   rate limit antes de aceptar la entrada en Storage.
--

CREATE OR REPLACE FUNCTION
public.worker_can_read_maintenance_proposal_storage_path(
    p_storage_path TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

BEGIN

    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RETURN FALSE;
    END IF;

    IF p_storage_path IS NULL
       OR p_storage_path !~
          '^[0-9a-fA-F-]{36}/[^/]+\.pdf$'
    THEN
        RETURN FALSE;
    END IF;

    RETURN EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposals p
        WHERE p.id::TEXT = SPLIT_PART(
            p_storage_path,
            '/',
            1
        )
    );

END;
$function$;


REVOKE ALL
ON FUNCTION
public.worker_can_read_maintenance_proposal_storage_path(TEXT)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION
public.worker_can_read_maintenance_proposal_storage_path(TEXT)
TO authenticated;


ALTER FUNCTION
public.worker_can_read_maintenance_proposal_storage_path(TEXT)
SET search_path = pg_catalog, public, pg_temp;


CREATE OR REPLACE FUNCTION
public.worker_can_write_maintenance_proposal_storage_path(
    p_storage_path TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

BEGIN

    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RETURN FALSE;
    END IF;

    IF p_storage_path IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Formato:
    -- <proposal_uuid>/<archivo>.pdf
    IF p_storage_path !~
       '^[0-9a-fA-F-]{36}/[^/]+\.pdf$'
    THEN
        RETURN FALSE;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposals p
        WHERE p.id::TEXT = SPLIT_PART(
            p_storage_path,
            '/',
            1
        )
        AND p.status IN (
            'submitted',
            'in_review',
            'clarification_requested'
        )
    ) THEN
        RETURN FALSE;
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'maintenance_proposal_storage_upload:' || auth.uid()::TEXT,
        20,
        3600
    );

    RETURN TRUE;

END;
$function$;


REVOKE ALL
ON FUNCTION
public.worker_can_write_maintenance_proposal_storage_path(TEXT)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION
public.worker_can_write_maintenance_proposal_storage_path(TEXT)
TO authenticated;


ALTER FUNCTION
public.worker_can_write_maintenance_proposal_storage_path(TEXT)
SET search_path = pg_catalog, public, pg_temp;


-- ============================================================
-- 15. STORAGE — WORKER SELECT
-- ============================================================

DROP POLICY IF EXISTS
    maintenance_proposal_documents_worker_select
ON storage.objects;


CREATE POLICY
    maintenance_proposal_documents_worker_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'maintenance-proposals'
    AND public.worker_can_read_maintenance_proposal_storage_path(name)
);


-- ============================================================
-- 16. STORAGE — WORKER INSERT
-- ============================================================

DROP POLICY IF EXISTS
    maintenance_proposal_documents_worker_insert
ON storage.objects;


CREATE POLICY
    maintenance_proposal_documents_worker_insert
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'maintenance-proposals'
    AND public.worker_can_write_maintenance_proposal_storage_path(name)
);


-- ============================================================
-- 17. STORAGE — CLIENT SELECT
-- ============================================================

DROP POLICY IF EXISTS
    maintenance_proposal_documents_client_select
ON storage.objects;


CREATE POLICY
    maintenance_proposal_documents_client_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'maintenance-proposals'
    AND public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposal_documents d
        JOIN public.maintenance_custom_proposals p
          ON p.id = d.proposal_id
        WHERE d.document_path = storage.objects.name
          AND d.published_at IS NOT NULL
          AND p.current_document_id = d.id
          AND p.user_id = auth.uid()
          AND p.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- NO UPDATE / DELETE DE STORAGE PARA AUTHENTICATED
-- ============================================================
--
-- El PDF se trata como un documento inmutable una vez asociado.
-- Para una nueva respuesta se crea una nueva versión.
-- ============================================================

DROP POLICY IF EXISTS
    maintenance_proposal_documents_worker_update
ON storage.objects;

DROP POLICY IF EXISTS
    maintenance_proposal_documents_worker_delete
ON storage.objects;


-- ============================================================
-- 18. HELPER — EMITIR NOTIFICACIÓN AL CLIENTE
-- ============================================================

CREATE OR REPLACE FUNCTION
public.emit_maintenance_custom_proposal_notification(
    p_proposal_id UUID,
    p_titulo TEXT,
    p_mensaje TEXT,
    p_metadata JSONB DEFAULT NULL
)
RETURNS public.notifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;
    v_notification public.notifications;

BEGIN

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La propuesta personalizada no existe';
    END IF;

    IF v_proposal.user_id IS NULL THEN
        RAISE EXCEPTION
            'La propuesta no tiene usuario cliente';
    END IF;

    IF p_titulo IS NULL
       OR LENGTH(BTRIM(p_titulo)) = 0
       OR LENGTH(p_titulo) > 200
    THEN
        RAISE EXCEPTION
            'El título de la notificación no es válido';
    END IF;

    IF p_mensaje IS NULL
       OR LENGTH(BTRIM(p_mensaje)) = 0
       OR LENGTH(p_mensaje) > 2000
    THEN
        RAISE EXCEPTION
            'El mensaje de la notificación no es válido';
    END IF;

    IF p_metadata IS NOT NULL
       AND pg_column_size(p_metadata) > 8192
    THEN
        RAISE EXCEPTION
            'La metadata de la notificación supera 8 KiB';
    END IF;

    INSERT INTO public.notifications (
        user_id,
        project_id,
        tipo,
        titulo,
        mensaje,
        metadata
    )
    VALUES (
        v_proposal.user_id,
        NULL,
        'maintenance_proposal',
        BTRIM(p_titulo),
        BTRIM(p_mensaje),
        p_metadata
    )
    RETURNING *
    INTO v_notification;

    RETURN v_notification;

END;
$function$;


REVOKE ALL
ON FUNCTION
public.emit_maintenance_custom_proposal_notification(
    UUID,
    TEXT,
    TEXT,
    JSONB
)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION
public.emit_maintenance_custom_proposal_notification(
    UUID,
    TEXT,
    TEXT,
    JSONB
)
TO service_role;


ALTER FUNCTION
public.emit_maintenance_custom_proposal_notification(
    UUID,
    TEXT,
    TEXT,
    JSONB
)
SET search_path = pg_catalog, public, pg_temp;


-- ============================================================
-- 19. RPC — WORKER ASOCIA PDF + HASH
-- ============================================================
--
-- El worker sube primero el PDF a Storage.
--
-- Después una Edge Function:
--   1. descarga el PDF real;
--   2. calcula SHA-256;
--   3. llama a esta RPC con el hash.
--
-- El frontend NO decide qué hash guardar.
--

CREATE OR REPLACE FUNCTION
public.attach_maintenance_custom_proposal_document(
    p_proposal_id UUID,
    p_document_path TEXT,
    p_document_sha256 TEXT,
    p_worker_id UUID
)
RETURNS public.maintenance_custom_proposal_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;
    v_object storage.objects;
    v_document
        public.maintenance_custom_proposal_documents;
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
        WHERE w.auth_user_id = p_worker_id
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


REVOKE ALL
ON FUNCTION
public.attach_maintenance_custom_proposal_document(
    UUID,
    TEXT,
    TEXT,
    UUID
)
FROM PUBLIC, anon, authenticated;


-- El hash lo calcula la Edge Function server-side.
GRANT EXECUTE
ON FUNCTION
public.attach_maintenance_custom_proposal_document(
    UUID,
    TEXT,
    TEXT,
    UUID
)
TO service_role;


ALTER FUNCTION
public.attach_maintenance_custom_proposal_document(
    UUID,
    TEXT,
    TEXT,
    UUID
)
SET search_path = pg_catalog, public, pg_temp;


-- ============================================================
-- 20. RPC — WORKER REVISA / RESPONDE
-- ============================================================
--
-- Acciones permitidas:
--
--   in_review
--   quoted
--   clarification_requested
--   rejected
--
-- El worker nunca puede pasar directamente a accepted.
--

CREATE OR REPLACE FUNCTION
public.review_custom_maintenance_proposal(
    p_proposal_id UUID,
    p_action TEXT,
    p_quoted_monthly_price NUMERIC DEFAULT NULL,
    p_quoted_currency TEXT DEFAULT 'EUR',
    p_quoted_hours_monthly NUMERIC DEFAULT NULL,
    p_quoted_scope_level TEXT DEFAULT NULL,
    p_quoted_service_level TEXT DEFAULT NULL,
    p_quoted_sla TEXT DEFAULT NULL,
    p_quoted_response_time TEXT DEFAULT NULL,
    p_quoted_support_hours TEXT DEFAULT NULL,
    p_quoted_description TEXT DEFAULT NULL,
    p_quoted_terms TEXT DEFAULT NULL,
    p_quoted_valid_until DATE DEFAULT NULL,
    p_response_notes TEXT DEFAULT NULL,
    p_clarification_message TEXT DEFAULT NULL
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;
    v_action TEXT := LOWER(BTRIM(COALESCE(p_action, '')));
    v_currency TEXT := UPPER(BTRIM(COALESCE(p_quoted_currency, 'EUR')));
    v_document
        public.maintenance_custom_proposal_documents;

BEGIN

    IF auth.uid() IS NULL
       OR NOT public.current_user_is_worker()
    THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;

    IF v_action NOT IN (
        'in_review',
        'quoted',
        'clarification_requested',
        'rejected'
    )
    THEN
        RAISE EXCEPTION
            'Acción de revisión no válida';
    END IF;



    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Propuesta personalizada no encontrada';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'maintenance_proposal_review:' || auth.uid()::TEXT || ':' || p_proposal_id::TEXT,
        20,
        3600
    );


    -- ========================================================
    -- COMENZAR / CONTINUAR REVISIÓN
    -- ========================================================

    IF v_action = 'in_review' THEN

        IF v_proposal.status NOT IN (
            'submitted',
            'clarification_requested'
        )
        THEN
            RAISE EXCEPTION
                'La propuesta no puede pasar a revisión desde su estado actual';
        END IF;

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'in_review',
            reviewed_by = auth.uid(),
            reviewed_at = COALESCE(
                reviewed_at,
                CURRENT_TIMESTAMP
            ),
            clarification_requested_at = NULL,
            clarification_requested_by = NULL,
            clarification_message = NULL,
            response_notes = NULLIF(
                BTRIM(p_response_notes),
                ''
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id
        RETURNING *
        INTO v_proposal;

        RETURN v_proposal;

    END IF;


    -- ========================================================
    -- RECHAZAR
    -- ========================================================

    IF v_action = 'rejected' THEN

        IF v_proposal.status <> 'in_review' THEN
            RAISE EXCEPTION
                'Solo se puede rechazar una propuesta que está en revisión';
        END IF;

        IF NULLIF(BTRIM(p_response_notes), '') IS NULL THEN
            RAISE EXCEPTION
                'Debes indicar el motivo del rechazo';
        END IF;

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'rejected',
            reviewed_by = auth.uid(),
            reviewed_at = COALESCE(
                reviewed_at,
                CURRENT_TIMESTAMP
            ),
            rejected_at = CURRENT_TIMESTAMP,
            rejected_by = auth.uid(),
            rejection_reason = BTRIM(p_response_notes),
            response_notes = BTRIM(p_response_notes),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id
        RETURNING *
        INTO v_proposal;

        PERFORM public.emit_maintenance_custom_proposal_notification(
            v_proposal.id,
            'Tu solicitud de mantenimiento ha sido revisada',
            'Modira ha revisado tu solicitud de mantenimiento personalizado. Consulta el detalle de la respuesta en tu área de cliente.',
            jsonb_build_object(
                'proposal_id', v_proposal.id,
                'status', 'rejected',
                'action', 'view_maintenance_proposal'
            )
        );

        RETURN v_proposal;

    END IF;


    -- ========================================================
    -- SOLICITAR INFORMACIÓN
    -- ========================================================

    IF v_action = 'clarification_requested' THEN

        IF v_proposal.status <> 'in_review' THEN
            RAISE EXCEPTION
                'Solo se puede solicitar información adicional durante la revisión';
        END IF;

        IF NULLIF(BTRIM(p_clarification_message), '') IS NULL THEN
            RAISE EXCEPTION
                'Debes indicar qué información adicional necesita Modira';
        END IF;

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'clarification_requested',
            reviewed_by = auth.uid(),
            reviewed_at = COALESCE(
                reviewed_at,
                CURRENT_TIMESTAMP
            ),
            clarification_requested_at = CURRENT_TIMESTAMP,
            clarification_requested_by = auth.uid(),
            clarification_message = BTRIM(p_clarification_message),
            response_notes = NULLIF(
                BTRIM(p_response_notes),
                ''
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id
        RETURNING *
        INTO v_proposal;

        PERFORM public.emit_maintenance_custom_proposal_notification(
            v_proposal.id,
            'Necesitamos información adicional',
            'Modira necesita información adicional para poder preparar tu propuesta de mantenimiento. Consulta la solicitud en tu área de cliente.',
            jsonb_build_object(
                'proposal_id', v_proposal.id,
                'status', 'clarification_requested',
                'action', 'view_maintenance_proposal'
            )
        );

        RETURN v_proposal;

    END IF;


    -- ========================================================
    -- ENVIAR PROPUESTA COTIZADA
    -- ========================================================

    IF v_action = 'quoted' THEN

        IF v_proposal.status <> 'in_review' THEN
            RAISE EXCEPTION
                'Solo se puede enviar una cotización desde una propuesta en revisión';
        END IF;

        IF p_quoted_monthly_price IS NULL
           OR p_quoted_monthly_price <= 0
        THEN
            RAISE EXCEPTION
                'El precio mensual cotizado debe ser mayor que 0';
        END IF;

        IF p_quoted_valid_until IS NULL THEN
            RAISE EXCEPTION
                'La propuesta cotizada debe tener fecha de validez';
        END IF;

        IF p_quoted_valid_until < CURRENT_DATE THEN
            RAISE EXCEPTION
                'La fecha de validez de la propuesta no puede estar en el pasado';
        END IF;

        IF v_currency !~ '^[A-Z]{3}$' THEN
            RAISE EXCEPTION
                'La moneda de la propuesta no es válida';
        END IF;

        IF v_proposal.current_document_id IS NULL THEN
            RAISE EXCEPTION
                'Debes adjuntar el PDF de respuesta de Modira antes de enviar la propuesta';
        END IF;

        SELECT *
        INTO v_document
        FROM public.maintenance_custom_proposal_documents
        WHERE id = v_proposal.current_document_id
          AND proposal_id = v_proposal.id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'El documento actual de la propuesta no existe';
        END IF;

        IF v_document.document_sha256 IS NULL
           OR BTRIM(v_document.document_sha256) = ''
        THEN
            RAISE EXCEPTION
                'El PDF todavía no tiene una huella SHA-256 válida';
        END IF;

        UPDATE public.maintenance_custom_proposal_documents
        SET
            published_at = CURRENT_TIMESTAMP
        WHERE id = v_document.id;

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'quoted',

            quoted_monthly_price =
                ROUND(p_quoted_monthly_price, 2),

            quoted_currency = v_currency,

            quoted_hours_monthly =
                p_quoted_hours_monthly,

            quoted_scope_level =
                NULLIF(BTRIM(p_quoted_scope_level), ''),

            quoted_service_level =
                NULLIF(BTRIM(p_quoted_service_level), ''),

            quoted_sla =
                NULLIF(BTRIM(p_quoted_sla), ''),

            quoted_response_time =
                NULLIF(BTRIM(p_quoted_response_time), ''),

            quoted_support_hours =
                NULLIF(BTRIM(p_quoted_support_hours), ''),

            quoted_description =
                NULLIF(BTRIM(p_quoted_description), ''),

            quoted_terms =
                NULLIF(BTRIM(p_quoted_terms), ''),

            quoted_valid_until =
                p_quoted_valid_until,

            quote_snapshot =
                jsonb_build_object(
                    'monthly_price',
                        ROUND(p_quoted_monthly_price, 2),
                    'currency',
                        v_currency,
                    'hours_monthly',
                        p_quoted_hours_monthly,
                    'scope_level',
                        NULLIF(BTRIM(p_quoted_scope_level), ''),
                    'service_level',
                        NULLIF(BTRIM(p_quoted_service_level), ''),
                    'sla',
                        NULLIF(BTRIM(p_quoted_sla), ''),
                    'response_time',
                        NULLIF(BTRIM(p_quoted_response_time), ''),
                    'support_hours',
                        NULLIF(BTRIM(p_quoted_support_hours), ''),
                    'description',
                        NULLIF(BTRIM(p_quoted_description), ''),
                    'terms',
                        NULLIF(BTRIM(p_quoted_terms), ''),
                    'valid_until',
                        p_quoted_valid_until,
                    'document_id',
                        v_document.id,
                    'document_version',
                        v_document.version,
                    'document_path',
                        v_document.document_path,
                    'document_sha256',
                        v_document.document_sha256,
                    'captured_at',
                        CURRENT_TIMESTAMP
                ),

            quoted_by = auth.uid(),

            quoted_at = CURRENT_TIMESTAMP,

            reviewed_by = auth.uid(),

            reviewed_at = COALESCE(
                reviewed_at,
                CURRENT_TIMESTAMP
            ),

            response_version =
                response_version + 1,

            response_notes =
                NULLIF(BTRIM(p_response_notes), ''),

            clarification_requested_at = NULL,
            clarification_requested_by = NULL,
            clarification_message = NULL,

            updated_at = CURRENT_TIMESTAMP

        WHERE id = v_proposal.id

        RETURNING *
        INTO v_proposal;


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
            auth.uid(),
            'worker',
            'document_published',
            'El PDF de respuesta ha quedado publicado para el cliente.',
            jsonb_build_object(
                'document_id', v_document.id,
                'document_version', v_document.version,
                'document_sha256', v_document.document_sha256
            )
        );


        PERFORM public.emit_maintenance_custom_proposal_notification(
            v_proposal.id,
            'Tu propuesta de mantenimiento está disponible',
            'Modira ha preparado una propuesta de mantenimiento personalizada para ti. Revisa las condiciones y el PDF antes de continuar.',
            jsonb_build_object(
                'proposal_id', v_proposal.id,
                'status', 'quoted',
                'document_id', v_document.id,
                'document_version', v_document.version,
                'action', 'view_maintenance_proposal'
            )
        );

        RETURN v_proposal;

    END IF;


    RAISE EXCEPTION
        'No se ha podido procesar la revisión de la propuesta';

END;
$function$;


REVOKE ALL
ON FUNCTION
public.review_custom_maintenance_proposal(
    UUID,
    TEXT,
    NUMERIC,
    TEXT,
    NUMERIC,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    TEXT,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION
public.review_custom_maintenance_proposal(
    UUID,
    TEXT,
    NUMERIC,
    TEXT,
    NUMERIC,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    TEXT,
    TEXT
)
TO authenticated;


ALTER FUNCTION
public.review_custom_maintenance_proposal(
    UUID,
    TEXT,
    NUMERIC,
    TEXT,
    NUMERIC,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    TEXT,
    TEXT
)
SET search_path = pg_catalog, public, pg_temp;


-- ============================================================
-- 21. ELIMINAR VÍA ANTIGUA DE RESPUESTA DEL WORKER
-- ============================================================
--
-- 069 tenía respond_to_custom_maintenance_proposal().
-- La retiramos del acceso frontend para que no exista una segunda
-- vía que permita cotizar sin PDF/notifications/clarification.
--
-- La función puede seguir existiendo para compatibilidad interna,
-- pero authenticated ya no puede ejecutarla.
--

REVOKE ALL
ON FUNCTION public.respond_to_custom_maintenance_proposal(
    UUID,
    TEXT,
    NUMERIC,
    NUMERIC,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    DATE
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 22. RPC — CLIENTE RESPONDE A UNA PETICIÓN DE INFORMACIÓN
-- ============================================================
--
-- Permite al cliente aportar información adicional sin crear una
-- propuesta nueva.
--

CREATE OR REPLACE FUNCTION
public.respond_to_custom_maintenance_clarification(
    p_proposal_id UUID,
    p_informacion_adicional TEXT DEFAULT NULL,
    p_request_data JSONB DEFAULT NULL
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión';
    END IF;

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Esta operación está destinada a clientes';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'El usuario no está activo';
    END IF;

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
      AND user_id = auth.uid()
      AND company_id = public.current_user_company_id()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La propuesta no existe o no tienes acceso a ella';
    END IF;

    IF v_proposal.status <> 'clarification_requested' THEN
        RAISE EXCEPTION
            'La propuesta no está esperando información adicional';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'maintenance_proposal_clarification:' || auth.uid()::TEXT || ':' || p_proposal_id::TEXT,
        10,
        86400
    );



    IF p_request_data IS NOT NULL
       AND jsonb_typeof(p_request_data) <> 'object'
    THEN
        RAISE EXCEPTION
            'request_data debe ser un objeto JSON';
    END IF;

    UPDATE public.maintenance_custom_proposals
    SET
        informacion_adicional =
            COALESCE(
                NULLIF(BTRIM(p_informacion_adicional), ''),
                informacion_adicional
            ),

        request_data =
            CASE
                WHEN p_request_data IS NULL
                THEN request_data
                ELSE p_request_data
            END,

        status = 'submitted',

        submitted_at = CURRENT_TIMESTAMP,

        updated_at = CURRENT_TIMESTAMP

    WHERE id = v_proposal.id

    RETURNING *
    INTO v_proposal;


    INSERT INTO public.maintenance_custom_proposal_events (
        proposal_id,
        actor_id,
        actor_type,
        event_type,
        old_status,
        new_status,
        notes,
        metadata
    )
    VALUES (
        v_proposal.id,
        auth.uid(),
        'client',
        'clarification_resubmitted',
        'clarification_requested',
        'submitted',
        NULLIF(BTRIM(p_informacion_adicional), ''),
        NULL
    );


    RETURN v_proposal;

END;
$function$;


REVOKE ALL
ON FUNCTION
public.respond_to_custom_maintenance_clarification(
    UUID,
    TEXT,
    JSONB
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION
public.respond_to_custom_maintenance_clarification(
    UUID,
    TEXT,
    JSONB
)
TO authenticated;


ALTER FUNCTION
public.respond_to_custom_maintenance_clarification(
    UUID,
    TEXT,
    JSONB
)
SET search_path = pg_catalog, public, pg_temp;


-- ============================================================
-- 23. RPC — CLIENTE REGISTRA EL CHECKBOX DEL PDF
-- ============================================================
--
-- El cliente NO envía:
-- - user_id
-- - company_id
-- - document_path
-- - hash
--
-- Todo se obtiene de la propuesta/documento actual.
--

CREATE OR REPLACE FUNCTION
public.record_maintenance_custom_proposal_document_acknowledgement(
    p_proposal_id UUID
)
RETURNS public.maintenance_custom_proposal_document_acknowledgements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

DECLARE
    v_user_id UUID;
    v_proposal public.maintenance_custom_proposals;
    v_document
        public.maintenance_custom_proposal_documents;
    v_ack
        public.maintenance_custom_proposal_document_acknowledgements;

    v_text_version TEXT :=
        'maintenance_custom_proposal_document_acknowledgement_v1';

BEGIN

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión';
    END IF;

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Los trabajadores no pueden registrar el acknowledgement del cliente';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'El usuario no está activo';
    END IF;

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
      AND user_id = v_user_id
      AND company_id = public.current_user_company_id()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La propuesta no existe o no tienes acceso a ella';
    END IF;

    IF v_proposal.status <> 'quoted' THEN
        RAISE EXCEPTION
            'La propuesta todavía no está disponible para aceptación';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'maintenance_proposal_acknowledgement:' || auth.uid()::TEXT || ':' || p_proposal_id::TEXT,
        10,
        86400
    );



    IF v_proposal.current_document_id IS NULL THEN
        RAISE EXCEPTION
            'La propuesta no tiene un PDF publicado';
    END IF;

    SELECT *
    INTO v_document
    FROM public.maintenance_custom_proposal_documents
    WHERE id = v_proposal.current_document_id
      AND proposal_id = v_proposal.id
      AND published_at IS NOT NULL
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El PDF publicado de la propuesta no está disponible';
    END IF;

    INSERT INTO public.maintenance_custom_proposal_document_acknowledgements (
        proposal_id,
        document_id,
        user_id,
        company_id,
        document_path,
        document_sha256,
        acknowledgement_text_version,
        accepted_at
    )
    VALUES (
        v_proposal.id,
        v_document.id,
        v_user_id,
        v_proposal.company_id,
        v_document.document_path,
        LOWER(v_document.document_sha256),
        v_text_version,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (
        proposal_id,
        user_id,
        document_id,
        acknowledgement_text_version
    )
    DO UPDATE
    SET
        document_path = EXCLUDED.document_path,
        document_sha256 = EXCLUDED.document_sha256,
        accepted_at = EXCLUDED.accepted_at
    RETURNING *
    INTO v_ack;


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
        v_user_id,
        'client',
        'document_acknowledged',
        'El cliente ha confirmado que ha leído/revisado el PDF publicado.',
        jsonb_build_object(
            'document_id', v_document.id,
            'document_version', v_document.version,
            'document_sha256', v_document.document_sha256,
            'acknowledgement_text_version', v_text_version
        )
    );


    RETURN v_ack;

END;
$function$;


REVOKE ALL
ON FUNCTION
public.record_maintenance_custom_proposal_document_acknowledgement(UUID)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION
public.record_maintenance_custom_proposal_document_acknowledgement(UUID)
TO authenticated;


ALTER FUNCTION
public.record_maintenance_custom_proposal_document_acknowledgement(UUID)
SET search_path = pg_catalog, public, pg_temp;


-- ============================================================
-- 24. GUARD — ACEPTACIÓN CONTRACTUAL REQUIERE ACKNOWLEDGEMENT
-- ============================================================
--
-- Defensa adicional.
--
-- Aunque alguien intente cambiar directamente:
--
-- quoted → accepted
--
-- la BD comprobará que el cliente ha registrado antes el checkbox
-- sobre el PDF actualmente publicado.
--
-- También impide que un worker convierta directamente la propuesta
-- en accepted.
--

CREATE OR REPLACE FUNCTION
public.guard_maintenance_custom_proposal_acceptance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

BEGIN

    IF NEW.status = 'accepted'
       AND OLD.status IS DISTINCT FROM 'accepted'
    THEN

        IF OLD.status <> 'quoted' THEN
            RAISE EXCEPTION
                'Solo una propuesta cotizada puede pasar a aceptada';
        END IF;

        IF NEW.accepted_by IS NULL
           OR NEW.accepted_by IS DISTINCT FROM NEW.user_id
        THEN
            RAISE EXCEPTION
                'La aceptación debe pertenecer al usuario cliente de la propuesta';
        END IF;

        IF NEW.current_document_id IS NULL THEN
            RAISE EXCEPTION
                'La propuesta no tiene un PDF publicado';
        END IF;

        IF NEW.quoted_valid_until IS NOT NULL
           AND NEW.quoted_valid_until < CURRENT_DATE
        THEN
            RAISE EXCEPTION
                'La propuesta ha caducado';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM public.maintenance_custom_proposal_documents d
            WHERE d.id = NEW.current_document_id
              AND d.proposal_id = NEW.id
              AND d.published_at IS NOT NULL
              AND EXISTS (
                  SELECT 1
                  FROM public.maintenance_custom_proposal_document_acknowledgements a
                  WHERE a.proposal_id = NEW.id
                    AND a.document_id = d.id
                    AND a.user_id = NEW.user_id
                    AND LOWER(a.document_sha256)
                        = LOWER(d.document_sha256)
              )
        )
        THEN
            RAISE EXCEPTION
                'Antes de aceptar la propuesta debes confirmar que has leído el PDF publicado';
        END IF;

    END IF;

    RETURN NEW;

END;
$function$;


DROP TRIGGER IF EXISTS
    maintenance_custom_proposal_acceptance_guard
ON public.maintenance_custom_proposals;


CREATE TRIGGER
    maintenance_custom_proposal_acceptance_guard
BEFORE UPDATE
ON public.maintenance_custom_proposals
FOR EACH ROW
EXECUTE FUNCTION
    public.guard_maintenance_custom_proposal_acceptance();


-- ============================================================
-- 25. REDEFINIR LA ACEPTACIÓN DEL CLIENTE
-- ============================================================
--
-- Mantiene la misma firma de 069, pero ahora exige acknowledgement.
--

CREATE OR REPLACE FUNCTION
public.accept_custom_maintenance_proposal(
    p_proposal_id UUID
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión';
    END IF;

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Un trabajador no puede aceptar una propuesta como cliente';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'El usuario no está activo';
    END IF;

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
      AND user_id = auth.uid()
      AND company_id = public.current_user_company_id()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La propuesta no existe o no tienes acceso a ella';
    END IF;

    IF v_proposal.status <> 'quoted' THEN
        RAISE EXCEPTION
            'La propuesta todavía no puede aceptarse';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'maintenance_proposal_accept:' || auth.uid()::TEXT || ':' || p_proposal_id::TEXT,
        5,
        86400
    );



    IF v_proposal.quoted_monthly_price IS NULL
       OR v_proposal.quoted_monthly_price <= 0
    THEN
        RAISE EXCEPTION
            'La propuesta no tiene un precio válido';
    END IF;

    IF v_proposal.quoted_valid_until IS NOT NULL
       AND v_proposal.quoted_valid_until < CURRENT_DATE
    THEN

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'expired',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id;

        RAISE EXCEPTION
            'La propuesta ha caducado';
    END IF;

    IF v_proposal.current_document_id IS NULL THEN
        RAISE EXCEPTION
            'La propuesta no tiene un PDF publicado';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposal_document_acknowledgements a
        JOIN public.maintenance_custom_proposal_documents d
          ON d.id = a.document_id
        WHERE a.proposal_id = v_proposal.id
          AND a.user_id = auth.uid()
          AND a.document_id = v_proposal.current_document_id
          AND d.proposal_id = v_proposal.id
          AND d.published_at IS NOT NULL
          AND LOWER(a.document_sha256)
              = LOWER(d.document_sha256)
    )
    THEN
        RAISE EXCEPTION
            'Debes confirmar primero que has leído el PDF de la propuesta';
    END IF;

    UPDATE public.maintenance_custom_proposals
    SET
        status = 'accepted',
        accepted_at = CURRENT_TIMESTAMP,
        accepted_by = auth.uid(),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_proposal.id
    RETURNING *
    INTO v_proposal;

    RETURN v_proposal;

END;
$function$;


REVOKE ALL
ON FUNCTION public.accept_custom_maintenance_proposal(UUID)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.accept_custom_maintenance_proposal(UUID)
TO authenticated;


ALTER FUNCTION
public.accept_custom_maintenance_proposal(UUID)
SET search_path = pg_catalog, public, pg_temp;


-- ============================================================
-- 26. ACEPTACIÓN SERVER-SIDE PARA LA EDGE FUNCTION
-- ============================================================
--
-- La Edge Function de Stripe utiliza service_role.
-- Esta vía permite que el backend valide explícitamente al usuario
-- propietario de la propuesta sin depender de auth.uid() dentro
-- de una llamada service_role.
--
-- Se limita a service_role.
--

CREATE OR REPLACE FUNCTION
public.accept_custom_maintenance_proposal_for_user(
    p_proposal_id UUID,
    p_user_id UUID
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;
    v_profile_status TEXT;

BEGIN

    IF p_proposal_id IS NULL
       OR p_user_id IS NULL
    THEN
        RAISE EXCEPTION
            'proposal_id y user_id son obligatorios';
    END IF;

    SELECT status
    INTO v_profile_status
    FROM public.profiles
    WHERE id = p_user_id;

    IF v_profile_status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION
            'El usuario cliente no está activo';
    END IF;

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
      AND user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La propuesta no existe o no pertenece al usuario indicado';
    END IF;

    IF v_proposal.status <> 'quoted' THEN
        RAISE EXCEPTION
            'La propuesta todavía no puede aceptarse';
    END IF;

    PERFORM public.enforce_security_rate_limit(
        'maintenance_proposal_accept_backend:' || p_user_id::TEXT || ':' || p_proposal_id::TEXT,
        5,
        86400
    );



    IF v_proposal.quoted_monthly_price IS NULL
       OR v_proposal.quoted_monthly_price <= 0
    THEN
        RAISE EXCEPTION
            'La propuesta no tiene un precio válido';
    END IF;

    IF v_proposal.quoted_valid_until IS NOT NULL
       AND v_proposal.quoted_valid_until < CURRENT_DATE
    THEN
        UPDATE public.maintenance_custom_proposals
        SET
            status = 'expired',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id;

        RAISE EXCEPTION
            'La propuesta ha caducado';
    END IF;

    IF v_proposal.current_document_id IS NULL THEN
        RAISE EXCEPTION
            'La propuesta no tiene un PDF publicado';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposal_document_acknowledgements a
        JOIN public.maintenance_custom_proposal_documents d
          ON d.id = a.document_id
        WHERE a.proposal_id = v_proposal.id
          AND a.user_id = p_user_id
          AND a.document_id = v_proposal.current_document_id
          AND d.proposal_id = v_proposal.id
          AND d.published_at IS NOT NULL
          AND LOWER(a.document_sha256)
              = LOWER(d.document_sha256)
    )
    THEN
        RAISE EXCEPTION
            'El cliente debe confirmar primero que ha leído el PDF de la propuesta';
    END IF;

    UPDATE public.maintenance_custom_proposals
    SET
        status = 'accepted',
        accepted_at = CURRENT_TIMESTAMP,
        accepted_by = p_user_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_proposal.id
    RETURNING *
    INTO v_proposal;

    RETURN v_proposal;

END;
$function$;


REVOKE ALL
ON FUNCTION
public.accept_custom_maintenance_proposal_for_user(UUID, UUID)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION
public.accept_custom_maintenance_proposal_for_user(UUID, UUID)
TO service_role;


ALTER FUNCTION
public.accept_custom_maintenance_proposal_for_user(UUID, UUID)
SET search_path = pg_catalog, public, pg_temp;


-- ============================================================
-- 27. HISTÓRICO AUTOMÁTICO DE ESTADOS
-- ============================================================

CREATE OR REPLACE FUNCTION
public.record_maintenance_custom_proposal_status_event()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$

DECLARE
    v_actor_id UUID;
    v_actor_type TEXT;
    v_event_type TEXT;
    v_notes TEXT;
BEGIN

    v_actor_id := auth.uid();

    IF v_actor_id IS NULL THEN
        v_actor_type := 'system';
    ELSIF public.current_user_is_worker() THEN
        v_actor_type := 'worker';
    ELSE
        v_actor_type := 'client';
    END IF;

    IF TG_OP = 'INSERT' THEN

        v_event_type := 'created';

        INSERT INTO public.maintenance_custom_proposal_events (
            proposal_id,
            actor_id,
            actor_type,
            event_type,
            old_status,
            new_status
        )
        VALUES (
            NEW.id,
            v_actor_id,
            v_actor_type,
            v_event_type,
            NULL,
            NEW.status
        );

        RETURN NEW;

    END IF;


    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;


    v_event_type :=
        CASE NEW.status
            WHEN 'submitted'
                THEN 'submitted'
            WHEN 'in_review'
                THEN 'review_started'
            WHEN 'clarification_requested'
                THEN 'clarification_requested'
            WHEN 'quoted'
                THEN 'quoted'
            WHEN 'rejected'
                THEN 'rejected'
            WHEN 'accepted'
                THEN 'accepted'
            WHEN 'expired'
                THEN 'expired'
            WHEN 'cancelled'
                THEN 'cancelled'
            ELSE NULL
        END;

    IF v_event_type IS NULL THEN
        RETURN NEW;
    END IF;


    v_notes :=
        CASE NEW.status
            WHEN 'rejected'
                THEN NEW.rejection_reason
            WHEN 'clarification_requested'
                THEN NEW.clarification_message
            ELSE NULL
        END;


    INSERT INTO public.maintenance_custom_proposal_events (
        proposal_id,
        actor_id,
        actor_type,
        event_type,
        old_status,
        new_status,
        notes,
        metadata
    )
    VALUES (
        NEW.id,
        v_actor_id,
        v_actor_type,
        v_event_type,
        OLD.status,
        NEW.status,
        v_notes,
        CASE
            WHEN NEW.status = 'quoted'
            THEN jsonb_build_object(
                'response_version',
                NEW.response_version,
                'quoted_monthly_price',
                NEW.quoted_monthly_price,
                'quoted_currency',
                NEW.quoted_currency,
                'quoted_valid_until',
                NEW.quoted_valid_until,
                'current_document_id',
                NEW.current_document_id
            )
            ELSE NULL
        END
    );


    RETURN NEW;

END;
$function$;


DROP TRIGGER IF EXISTS
    maintenance_custom_proposal_status_event
ON public.maintenance_custom_proposals;


CREATE TRIGGER
    maintenance_custom_proposal_status_event
AFTER INSERT OR UPDATE OF status
ON public.maintenance_custom_proposals
FOR EACH ROW
EXECUTE FUNCTION
    public.record_maintenance_custom_proposal_status_event();


-- ============================================================
-- 28. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
    v_rls BOOLEAN;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM pg_constraint
    WHERE conrelid =
        'public.maintenance_custom_proposals'::regclass
      AND conname =
        'maintenance_custom_proposals_status_check';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '074 failed: maintenance proposal status constraint missing';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid =
        'public.maintenance_custom_proposal_documents'::regclass;

    IF v_rls IS NOT TRUE THEN
        RAISE EXCEPTION
            '074 failed: proposal documents RLS disabled';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid =
        'public.maintenance_custom_proposal_document_acknowledgements'::regclass;

    IF v_rls IS NOT TRUE THEN
        RAISE EXCEPTION
            '074 failed: proposal acknowledgements RLS disabled';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid =
        'public.maintenance_custom_proposal_events'::regclass;

    IF v_rls IS NOT TRUE THEN
        RAISE EXCEPTION
            '074 failed: proposal events RLS disabled';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'maintenance-proposals'
          AND public = FALSE
          AND file_size_limit = 20971520
          AND 'application/pdf' = ANY(allowed_mime_types)
    ) THEN
        RAISE EXCEPTION
            '074 failed: maintenance-proposals bucket is not correctly configured';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname =
              'review_custom_maintenance_proposal'
    ) THEN
        RAISE EXCEPTION
            '074 failed: review_custom_maintenance_proposal() missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname =
              'record_maintenance_custom_proposal_document_acknowledgement'
    ) THEN
        RAISE EXCEPTION
            '074 failed: document acknowledgement RPC missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname =
              'accept_custom_maintenance_proposal_for_user'
    ) THEN
        RAISE EXCEPTION
            '074 failed: server-side acceptance RPC missing';
    END IF;

END $$;

GRANT SELECT
ON public.workers
TO service_role;
COMMIT;
