BEGIN;

-- ============================================================
-- MODIRA — 042_worker_write_security_hardening.sql
--
-- HARDENING DE SEGURIDAD PARA 039 / 040 / 041
-- + ESCRITURAS DE WORKERS EXISTENTES
--
-- OBJETIVOS
-- 1. Rate limit SERVER-SIDE para escrituras de workers.
-- 2. El límite se aplica en PostgreSQL, no en React.
-- 3. Proteger notifications.metadata y sus textos.
-- 4. Limitar las subidas físicas al bucket project-documents.
--
-- NO:
-- - introduce jerarquía de workers;
-- - cambia roles/permisos de workers;
-- - cambia el acceso del cliente;
-- - limita SELECT;
-- - aplica rate limit a notifications directamente;
-- - modifica las RPC históricas 039/040/041.
--
-- La identidad del límite es exclusivamente auth.uid().
-- Las operaciones de clientes sobre tablas mixtas NO consumen
-- el límite porque current_user_is_worker() devuelve FALSE.
--
-- ============================================================


-- ============================================================
-- 0. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'project_milestones'
    ) THEN
        RAISE EXCEPTION
            '042 stopped: project_milestones does not exist. Apply 039 first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'notifications'
    ) THEN
        RAISE EXCEPTION
            '042 stopped: notifications does not exist. Apply 040 first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'project_updates'
    ) THEN
        RAISE EXCEPTION
            '042 stopped: project_updates does not exist. Apply 041 first.';
    END IF;

    IF to_regprocedure('public.current_user_is_worker()') IS NULL THEN
        RAISE EXCEPTION
            '042 stopped: current_user_is_worker() does not exist.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'project-documents'
    ) THEN
        RAISE EXCEPTION
            '042 stopped: project-documents bucket does not exist.';
    END IF;
END $$;


-- ============================================================
-- 1. TABLA INTERNA DE RATE LIMITS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.worker_write_rate_limits (
    worker_id UUID NOT NULL
        REFERENCES auth.users(id)
        ON DELETE CASCADE,

    operation_key TEXT NOT NULL,

    window_started_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    request_count INTEGER NOT NULL
        DEFAULT 0,

    updated_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (worker_id, operation_key),

    CONSTRAINT worker_write_rate_limits_count_check
        CHECK (request_count >= 0),

    CONSTRAINT worker_write_rate_limits_operation_check
        CHECK (
            LENGTH(TRIM(operation_key)) BETWEEN 1 AND 100
        )
);

CREATE INDEX IF NOT EXISTS
    idx_worker_write_rate_limits_updated_at
ON public.worker_write_rate_limits(updated_at);


-- ============================================================
-- 2. RLS / PRIVILEGIOS DE LA INFRAESTRUCTURA
-- ============================================================

ALTER TABLE public.worker_write_rate_limits
ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON public.worker_write_rate_limits
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 3. FUNCIÓN ATÓMICA DE RATE LIMIT
-- ============================================================
--
-- La función NO es ejecutable desde el frontend.
--
-- Identidad:
--     auth.uid()
--
-- Concurrencia:
--     advisory lock por worker + operación
--
-- Si se llama fuera de una sesión autenticada/worker, no
-- consume ningún contador.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.consume_worker_write_rate_limit(
    p_operation_key TEXT,
    p_limit INTEGER,
    p_window_seconds INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_worker_id UUID;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_window_started_at TIMESTAMPTZ;
    v_request_count INTEGER;
BEGIN

    IF auth.uid() IS NULL THEN
        RETURN TRUE;
    END IF;

    IF p_operation_key IS NULL
       OR LENGTH(TRIM(p_operation_key)) = 0
       OR LENGTH(p_operation_key) > 100
    THEN
        RAISE EXCEPTION 'Invalid worker rate limit operation';
    END IF;

    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 10000 THEN
        RAISE EXCEPTION 'Invalid worker rate limit limit';
    END IF;

    IF p_window_seconds IS NULL
       OR p_window_seconds < 1
       OR p_window_seconds > 86400
    THEN
        RAISE EXCEPTION 'Invalid worker rate limit window';
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RETURN TRUE;
    END IF;

    v_worker_id := auth.uid();

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_worker_id::TEXT || ':' || p_operation_key,
            42042
        )
    );

    SELECT
        window_started_at,
        request_count
    INTO
        v_window_started_at,
        v_request_count
    FROM public.worker_write_rate_limits
    WHERE worker_id = v_worker_id
      AND operation_key = p_operation_key
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.worker_write_rate_limits (
            worker_id,
            operation_key,
            window_started_at,
            request_count,
            updated_at
        )
        VALUES (
            v_worker_id,
            p_operation_key,
            v_now,
            1,
            v_now
        );

        RETURN TRUE;
    END IF;

    IF EXTRACT(
        EPOCH FROM (v_now - v_window_started_at)
    ) >= p_window_seconds
    THEN
        UPDATE public.worker_write_rate_limits
        SET
            window_started_at = v_now,
            request_count = 1,
            updated_at = v_now
        WHERE worker_id = v_worker_id
          AND operation_key = p_operation_key;

        RETURN TRUE;
    END IF;

    IF v_request_count >= p_limit THEN
        RETURN FALSE;
    END IF;

    UPDATE public.worker_write_rate_limits
    SET
        request_count = request_count + 1,
        updated_at = v_now
    WHERE worker_id = v_worker_id
      AND operation_key = p_operation_key;

    RETURN TRUE;
END;
$function$;


REVOKE ALL
ON FUNCTION public.consume_worker_write_rate_limit(
    TEXT,
    INTEGER,
    INTEGER
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 4. FUNCIÓN TRIGGER GENÉRICA
-- ============================================================
--
-- SOLO cuenta operaciones cuyo actor sea un worker activo.
--
-- IMPORTANTE:
-- notifications NO aparece aquí. Una operación de milestone
-- o project_update puede generar una notification internamente;
-- no queremos contar dos veces la misma acción.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.enforce_worker_write_rate_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_operation_key TEXT;
    v_limit INTEGER;
    v_allowed BOOLEAN;
BEGIN

    IF auth.uid() IS NULL
       OR NOT public.current_user_is_worker()
    THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
    END IF;


    -- --------------------------------------------------------
    -- SOLO operaciones con escritura de worker confirmada
    -- en el esquema actual.
    --
    -- Límite = operaciones por 10 minutos por worker.
    -- --------------------------------------------------------

    CASE TG_TABLE_NAME

        WHEN 'project_milestones' THEN
            v_operation_key := 'project_milestones.write';
            v_limit := 60;

        WHEN 'project_updates' THEN
            v_operation_key := 'project_updates.write';
            v_limit := 40;

        WHEN 'invoices' THEN
            v_operation_key := 'invoices.write';
            v_limit := 40;

        WHEN 'project_documents' THEN
            v_operation_key := 'project_documents.write';
            v_limit := 30;

        WHEN 'support_tickets' THEN
            v_operation_key := 'support_tickets.write';
            v_limit := 60;

        WHEN 'automation_runs' THEN
            v_operation_key := 'automation_runs.write';
            v_limit := 40;

        WHEN 'quotations' THEN
            v_operation_key := 'quotations.write';
            v_limit := 60;

        WHEN 'maintenance_contracts' THEN
            v_operation_key := 'maintenance_contracts.write';
            v_limit := 30;

        ELSE
            -- No imponer límites a tablas no verificadas.
            IF TG_OP = 'DELETE' THEN
                RETURN OLD;
            ELSE
                RETURN NEW;
            END IF;
    END CASE;


    v_allowed :=
        public.consume_worker_write_rate_limit(
            v_operation_key,
            v_limit,
            600
        );

    IF NOT v_allowed THEN
        RAISE EXCEPTION
            'Demasiadas operaciones. Inténtalo de nuevo más tarde.';
    END IF;


    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$function$;


REVOKE ALL
ON FUNCTION public.enforce_worker_write_rate_limit()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 5. RATE LIMIT — HITOS 039
-- ============================================================

DROP TRIGGER IF EXISTS
    worker_write_rate_limit_project_milestones
ON public.project_milestones;

CREATE TRIGGER
    worker_write_rate_limit_project_milestones
BEFORE INSERT OR UPDATE OR DELETE
ON public.project_milestones
FOR EACH ROW
EXECUTE FUNCTION public.enforce_worker_write_rate_limit();


-- ============================================================
-- 6. RATE LIMIT — NOVEDADES 041
-- ============================================================

DROP TRIGGER IF EXISTS
    worker_write_rate_limit_project_updates
ON public.project_updates;

CREATE TRIGGER
    worker_write_rate_limit_project_updates
BEFORE INSERT OR UPDATE OR DELETE
ON public.project_updates
FOR EACH ROW
EXECUTE FUNCTION public.enforce_worker_write_rate_limit();


-- ============================================================
-- 7. RATE LIMIT — FACTURAS
-- ============================================================
--
-- 011 mantiene INSERT/UPDATE/DELETE directo revocado y usa
-- RPCs de worker. El trigger protege la escritura final.
--
-- ============================================================

DROP TRIGGER IF EXISTS
    worker_write_rate_limit_invoices
ON public.invoices;

CREATE TRIGGER
    worker_write_rate_limit_invoices
BEFORE INSERT OR UPDATE OR DELETE
ON public.invoices
FOR EACH ROW
EXECUTE FUNCTION public.enforce_worker_write_rate_limit();


-- ============================================================
-- 8. RATE LIMIT — METADATA DE DOCUMENTOS
-- ============================================================
--
-- 013 mantiene INSERT/UPDATE/DELETE directo revocado y usa
-- attach_project_document()/detach_project_document().
--
-- El trigger protege la escritura de la referencia.
--
-- ============================================================

DROP TRIGGER IF EXISTS
    worker_write_rate_limit_project_documents
ON public.project_documents;

CREATE TRIGGER
    worker_write_rate_limit_project_documents
BEFORE INSERT OR UPDATE OR DELETE
ON public.project_documents
FOR EACH ROW
EXECUTE FUNCTION public.enforce_worker_write_rate_limit();


-- ============================================================
-- 9. RATE LIMIT — SUPPORT TICKETS
-- ============================================================
--
-- El cliente puede crear tickets.
-- El worker puede actualizar tickets.
--
-- El trigger solo cuenta la operación cuando el actor es worker.
--
-- ============================================================

DROP TRIGGER IF EXISTS
    worker_write_rate_limit_support_tickets
ON public.support_tickets;

CREATE TRIGGER
    worker_write_rate_limit_support_tickets
BEFORE INSERT OR UPDATE OR DELETE
ON public.support_tickets
FOR EACH ROW
EXECUTE FUNCTION public.enforce_worker_write_rate_limit();


-- ============================================================
-- 10. RATE LIMIT — AUTOMATION RUNS
-- ============================================================
--
-- La tabla es mixta: el cliente también puede crear runs.
--
-- Solo las operaciones cuyo actor sea worker consumen el límite.
--
-- ============================================================

DROP TRIGGER IF EXISTS
    worker_write_rate_limit_automation_runs
ON public.automation_runs;

CREATE TRIGGER
    worker_write_rate_limit_automation_runs
BEFORE INSERT OR UPDATE OR DELETE
ON public.automation_runs
FOR EACH ROW
EXECUTE FUNCTION public.enforce_worker_write_rate_limit();


-- ============================================================
-- 11. RATE LIMIT — PRESUPUESTOS
-- ============================================================
--
-- Se protege la escritura cuando el actor es worker.
-- Las respuestas del cliente no consumen este límite.
--
-- ============================================================

DROP TRIGGER IF EXISTS
    worker_write_rate_limit_quotations
ON public.quotations;

CREATE TRIGGER
    worker_write_rate_limit_quotations
BEFORE INSERT OR UPDATE OR DELETE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.enforce_worker_write_rate_limit();


-- ============================================================
-- 12. RATE LIMIT — CONTRATOS DE MANTENIMIENTO
-- ============================================================
--
-- 005 concede INSERT a authenticated y distingue mediante RLS
-- entre cliente y worker. El límite solo se consume si el actor
-- es worker.
--
-- ============================================================

DROP TRIGGER IF EXISTS
    worker_write_rate_limit_maintenance_contracts
ON public.maintenance_contracts;

CREATE TRIGGER
    worker_write_rate_limit_maintenance_contracts
BEFORE INSERT OR UPDATE OR DELETE
ON public.maintenance_contracts
FOR EACH ROW
EXECUTE FUNCTION public.enforce_worker_write_rate_limit();


-- ============================================================
-- 13. NOTIFICATIONS — LIMITAR METADATA
-- ============================================================
--
-- No aplicamos un trigger de rate limit sobre notifications.
--
-- Las notificaciones son efectos secundarios de operaciones
-- como completar un hito o publicar una novedad.
--
-- En su lugar:
--     metadata <= 8 KiB
--
-- ============================================================

ALTER TABLE public.notifications
DROP CONSTRAINT IF EXISTS notifications_metadata_size_check;

ALTER TABLE public.notifications
ADD CONSTRAINT notifications_metadata_size_check
CHECK (
    metadata IS NULL
    OR pg_column_size(metadata) <= 8192
);


-- ============================================================
-- 14. NOTIFICATIONS — LIMITES DE TEXTO
-- ============================================================

ALTER TABLE public.notifications
DROP CONSTRAINT IF EXISTS notifications_titulo_length_check;

ALTER TABLE public.notifications
ADD CONSTRAINT notifications_titulo_length_check
CHECK (
    titulo IS NULL
    OR LENGTH(titulo) <= 200
);


ALTER TABLE public.notifications
DROP CONSTRAINT IF EXISTS notifications_mensaje_length_check;

ALTER TABLE public.notifications
ADD CONSTRAINT notifications_mensaje_length_check
CHECK (
    mensaje IS NULL
    OR LENGTH(mensaje) <= 2000
);


ALTER TABLE public.notifications
DROP CONSTRAINT IF EXISTS notifications_tipo_length_check;

ALTER TABLE public.notifications
ADD CONSTRAINT notifications_tipo_length_check
CHECK (
    tipo IS NULL
    OR LENGTH(tipo) <= 100
);


-- ============================================================
-- 15. STORAGE — ENDURECER project-documents
-- ============================================================
--
-- El bucket ya es privado y las policies 013 controlan el
-- acceso del worker.
--
-- Añadimos una barrera independiente:
--
--     máximo 20 MiB
--     MIME permitido: application/pdf
--
-- Esto protege la subida física, que no pasa por
-- project_documents.
--
-- ============================================================

UPDATE storage.buckets
SET
    public = FALSE,
    file_size_limit = 20971520,
    allowed_mime_types = ARRAY[
        'application/pdf'
    ]::TEXT[]
WHERE id = 'project-documents';


-- ============================================================
-- 16. DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.worker_write_rate_limits IS
'Rate limits internos para operaciones de escritura realizadas por workers. Identidad derivada exclusivamente de auth.uid().';


COMMENT ON FUNCTION public.consume_worker_write_rate_limit(
    TEXT,
    INTEGER,
    INTEGER
)
IS
'Rate limit atómico interno para escrituras de workers. Utiliza auth.uid() y advisory locks para impedir bypass por concurrencia.';


COMMENT ON FUNCTION public.enforce_worker_write_rate_limit()
IS
'Trigger interno de rate limiting para escrituras de workers. No limita SELECT ni operaciones de clientes.';


COMMENT ON COLUMN public.notifications.metadata IS
'Metadatos internos de la notificación. Limitados a 8 KiB.';


-- ============================================================
-- 17. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_rls BOOLEAN;
    v_trigger_count INTEGER;
    v_constraint_count INTEGER;
    v_bucket_public BOOLEAN;
    v_file_size_limit BIGINT;
    v_allowed_mime_types TEXT[];
BEGIN

    -- --------------------------------------------------------
    -- RLS de la infraestructura
    -- --------------------------------------------------------

    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid =
        'public.worker_write_rate_limits'::regclass;

    IF v_rls IS NOT TRUE THEN
        RAISE EXCEPTION
            '042 failed: worker_write_rate_limits RLS disabled';
    END IF;


    -- --------------------------------------------------------
    -- authenticated no tiene acceso a los contadores
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.worker_write_rate_limits',
        'SELECT'
    )
    OR has_table_privilege(
        'authenticated',
        'public.worker_write_rate_limits',
        'INSERT'
    )
    OR has_table_privilege(
        'authenticated',
        'public.worker_write_rate_limits',
        'UPDATE'
    )
    OR has_table_privilege(
        'authenticated',
        'public.worker_write_rate_limits',
        'DELETE'
    )
    THEN
        RAISE EXCEPTION
            '042 failed: authenticated has privileges on worker rate limits';
    END IF;


    -- --------------------------------------------------------
    -- authenticated no puede ejecutar la función interna
    -- --------------------------------------------------------

    IF has_function_privilege(
        'authenticated',
        'public.consume_worker_write_rate_limit(text,integer,integer)',
        'EXECUTE'
    )
    THEN
        RAISE EXCEPTION
            '042 failed: authenticated can execute worker rate limit function';
    END IF;


    -- --------------------------------------------------------
    -- Deben existir exactamente los 8 triggers de tablas
    -- que esta migración protege.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_trigger_count
    FROM pg_trigger
    WHERE NOT tgisinternal
      AND tgname IN (
        'worker_write_rate_limit_project_milestones',
        'worker_write_rate_limit_project_updates',
        'worker_write_rate_limit_invoices',
        'worker_write_rate_limit_project_documents',
        'worker_write_rate_limit_support_tickets',
        'worker_write_rate_limit_automation_runs',
        'worker_write_rate_limit_quotations',
        'worker_write_rate_limit_maintenance_contracts'
      );

    IF v_trigger_count <> 8 THEN
        RAISE EXCEPTION
            '042 failed: expected 8 worker rate-limit triggers, found %',
            v_trigger_count;
    END IF;


    -- --------------------------------------------------------
    -- notifications.metadata
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_constraint_count
    FROM pg_constraint
    WHERE conrelid = 'public.notifications'::regclass
      AND conname = 'notifications_metadata_size_check';

    IF v_constraint_count <> 1 THEN
        RAISE EXCEPTION
            '042 failed: notifications metadata constraint missing';
    END IF;


    -- --------------------------------------------------------
    -- Storage
    -- --------------------------------------------------------

    SELECT
        public,
        file_size_limit,
        allowed_mime_types
    INTO
        v_bucket_public,
        v_file_size_limit,
        v_allowed_mime_types
    FROM storage.buckets
    WHERE id = 'project-documents';

    IF v_bucket_public IS NOT FALSE THEN
        RAISE EXCEPTION
            '042 failed: project-documents bucket is not private';
    END IF;

    IF v_file_size_limit <> 20971520 THEN
        RAISE EXCEPTION
            '042 failed: project-documents file size limit is not 20 MiB';
    END IF;

    IF NOT (
        'application/pdf' = ANY(v_allowed_mime_types)
    )
    THEN
        RAISE EXCEPTION
            '042 failed: application/pdf is not allowed in project-documents';
    END IF;

END $$;


COMMIT;
