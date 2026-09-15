BEGIN;

-- ============================================================
-- MODIRA — 038_legal_documents_and_consents.sql
-- ============================================================
-- Infraestructura transversal para:
-- - versiones de documentos legales;
-- - aceptación contractual;
-- - acuse de información;
-- - consentimiento;
-- - retirada de consentimiento;
-- - trazabilidad por contexto;
-- - bloqueo backend de operaciones que exijan una acción legal.
--
-- No se inventa el contenido de los documentos legales.
-- La migración crea la infraestructura y exige que las versiones
-- reales vigentes estén cargadas en public.legal_documents.
--
-- IMPORTANTE:
-- La RPC final de registro es ÚNICAMENTE:
--   complete_registration_legal_requirements(boolean, boolean)
--
-- La antigua firma sin parámetros se elimina deliberadamente.
-- La firma antigua de submit_audit_request(...) se conserva como
-- compatibilidad bloqueada, para que una llamada antigua no pueda
-- saltarse los nuevos requisitos legales.
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
          AND table_name = 'profiles'
    ) THEN
        RAISE EXCEPTION
            '038 stopped: public.profiles does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'audit_requests'
    ) THEN
        RAISE EXCEPTION
            '038 stopped: public.audit_requests does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'companies'
    ) THEN
        RAISE EXCEPTION
            '038 stopped: public.companies does not exist';
    END IF;

    IF to_regprocedure('public.current_user_is_worker()') IS NULL THEN
        RAISE EXCEPTION
            '038 stopped: current_user_is_worker() does not exist';
    END IF;

    IF to_regprocedure('public.current_user_is_active()') IS NULL THEN
        RAISE EXCEPTION
            '038 stopped: current_user_is_active() does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'public_form_rate_limits'
    ) THEN
        RAISE EXCEPTION
            '038 stopped: public.public_form_rate_limits does not exist';
    END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ============================================================
-- 1. DOCUMENTOS LEGALES VERSIONADOS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.legal_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    document_type TEXT NOT NULL,
    version TEXT NOT NULL,
    title TEXT NOT NULL,

    content TEXT NOT NULL,
    content_hash TEXT NOT NULL,

    effective_from TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    effective_until TIMESTAMPTZ,

    is_current BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    CONSTRAINT legal_documents_type_check
        CHECK (
            document_type IN (
                'terms_of_use',
                'privacy_information',
                'contract_terms',
                'audit_terms',
                'cookie_policy'
            )
        ),

    CONSTRAINT legal_documents_version_check
        CHECK (
            length(btrim(version)) > 0
            AND length(version) <= 100
        ),

    CONSTRAINT legal_documents_title_check
        CHECK (
            length(btrim(title)) > 0
            AND length(title) <= 300
        ),

    CONSTRAINT legal_documents_hash_check
        CHECK (
            content_hash ~ '^[0-9a-f]{64}$'
        ),

    CONSTRAINT legal_documents_dates_check
        CHECK (
            effective_until IS NULL
            OR effective_until > effective_from
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_legal_documents_type_version_unique
ON public.legal_documents(document_type, version);

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_legal_documents_one_current_per_type
ON public.legal_documents(document_type)
WHERE is_current = TRUE;

CREATE INDEX IF NOT EXISTS
    idx_legal_documents_current
ON public.legal_documents(document_type, is_current);

CREATE INDEX IF NOT EXISTS
    idx_legal_documents_effective_from
ON public.legal_documents(effective_from DESC);


-- ============================================================
-- 2. HASH AUTOMÁTICO DEL CONTENIDO LEGAL
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_legal_document_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF NEW.content IS NULL
       OR btrim(NEW.content) = ''
    THEN
        RAISE EXCEPTION
            'El contenido del documento legal es obligatorio';
    END IF;

    NEW.content_hash :=
    encode(
        extensions.digest(
            convert_to(NEW.content, 'UTF8'),
            'sha256'
        ),
        'hex'
    );

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS legal_documents_sync_hash
ON public.legal_documents;

CREATE TRIGGER legal_documents_sync_hash
BEFORE INSERT OR UPDATE OF content
ON public.legal_documents
FOR EACH ROW
EXECUTE FUNCTION public.sync_legal_document_hash();


-- ============================================================
-- 3. INMUTABILIDAD DEL CONTENIDO Y DE LA IDENTIDAD DE VERSIÓN
-- ============================================================
-- Se permite modificar únicamente:
--   - is_current
--   - effective_until
--
-- Quedan congelados:
--   - document_type
--   - version
--   - title
--   - content
--   - content_hash
--   - effective_from
--   - created_at
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_legal_document_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF OLD.document_type IS DISTINCT FROM NEW.document_type
       OR OLD.version IS DISTINCT FROM NEW.version
       OR OLD.title IS DISTINCT FROM NEW.title
       OR OLD.content IS DISTINCT FROM NEW.content
       OR OLD.content_hash IS DISTINCT FROM NEW.content_hash
       OR OLD.effective_from IS DISTINCT FROM NEW.effective_from
       OR OLD.created_at IS DISTINCT FROM NEW.created_at
    THEN
        RAISE EXCEPTION
            'La identidad y el contenido de una versión legal son inmutables';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS legal_documents_identity_immutable
ON public.legal_documents;

CREATE TRIGGER legal_documents_identity_immutable
BEFORE UPDATE
ON public.legal_documents
FOR EACH ROW
EXECUTE FUNCTION public.protect_legal_document_identity();


-- ============================================================
-- 4. TABLA HISTÓRICA DE ACCIONES LEGALES
-- ============================================================

CREATE TABLE IF NOT EXISTS public.legal_acceptances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    user_id UUID,

    company_id UUID
        REFERENCES public.companies(id)
        ON DELETE SET NULL,

    document_id UUID NOT NULL
        REFERENCES public.legal_documents(id)
        ON DELETE RESTRICT,

    action_type TEXT NOT NULL,

    accepted_at TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    ip TEXT,

    user_agent TEXT,

    context TEXT NOT NULL,

    source TEXT,

    document_hash TEXT NOT NULL,

    identity_key TEXT,

    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,

    CONSTRAINT legal_acceptances_action_check
        CHECK (
            action_type IN (
                'accepted',
                'acknowledged',
                'consented',
                'withdrawn'
            )
        ),

    CONSTRAINT legal_acceptances_context_check
        CHECK (
            length(btrim(context)) > 0
            AND length(context) <= 100
        ),

    CONSTRAINT legal_acceptances_source_check
        CHECK (
            source IS NULL
            OR length(source) <= 100
        ),

    CONSTRAINT legal_acceptances_ip_check
        CHECK (
            ip IS NULL
            OR length(ip) <= 200
        ),

    CONSTRAINT legal_acceptances_user_agent_check
        CHECK (
            user_agent IS NULL
            OR length(user_agent) <= 2000
        ),

    CONSTRAINT legal_acceptances_identity_key_check
        CHECK (
            identity_key IS NULL
            OR length(identity_key) <= 200
        ),

    CONSTRAINT legal_acceptances_hash_check
        CHECK (
            document_hash ~ '^[0-9a-f]{64}$'
        )
);

CREATE INDEX IF NOT EXISTS
    idx_legal_acceptances_user_id
ON public.legal_acceptances(user_id);

CREATE INDEX IF NOT EXISTS
    idx_legal_acceptances_company_id
ON public.legal_acceptances(company_id);

CREATE INDEX IF NOT EXISTS
    idx_legal_acceptances_document_id
ON public.legal_acceptances(document_id);

CREATE INDEX IF NOT EXISTS
    idx_legal_acceptances_context
ON public.legal_acceptances(context);

CREATE INDEX IF NOT EXISTS
    idx_legal_acceptances_accepted_at
ON public.legal_acceptances(accepted_at DESC);

CREATE INDEX IF NOT EXISTS
    idx_legal_acceptances_identity_key
ON public.legal_acceptances(identity_key);


-- ============================================================
-- 5. PROTEGER EL HISTÓRICO
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_legal_acceptance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    RAISE EXCEPTION
        'El histórico de acciones legales es inmutable';
END;
$function$;

DROP TRIGGER IF EXISTS legal_acceptances_immutable
ON public.legal_acceptances;

CREATE TRIGGER legal_acceptances_immutable
BEFORE UPDATE OR DELETE
ON public.legal_acceptances
FOR EACH ROW
EXECUTE FUNCTION public.protect_legal_acceptance();

ALTER TABLE public.legal_acceptances
ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON public.legal_acceptances
FROM PUBLIC, anon, authenticated;

GRANT SELECT
ON public.legal_acceptances
TO authenticated;

DROP POLICY IF EXISTS legal_acceptances_client_select
ON public.legal_acceptances;

CREATE POLICY legal_acceptances_client_select
ON public.legal_acceptances
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
);

DROP POLICY IF EXISTS legal_acceptances_worker_select
ON public.legal_acceptances;

CREATE POLICY legal_acceptances_worker_select
ON public.legal_acceptances
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 6. FUNCIONES AUXILIARES — CABECERAS OBSERVADAS POR BACKEND
-- ============================================================
-- Nunca se recibe IP ni User-Agent desde el frontend como
-- parámetro de negocio.
-- ============================================================

CREATE OR REPLACE FUNCTION public.observed_request_ip()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_headers JSONB := '{}'::JSONB;
BEGIN
    BEGIN
        v_headers := COALESCE(
            NULLIF(
                current_setting('request.headers', TRUE),
                ''
            )::JSONB,
            '{}'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        v_headers := '{}'::JSONB;
    END;

    RETURN COALESCE(
        NULLIF(
            TRIM(v_headers->>'cf-connecting-ip'),
            ''
        ),
        NULLIF(
            TRIM(v_headers->>'x-real-ip'),
            ''
        ),
        NULLIF(
            TRIM(
                SPLIT_PART(
                    COALESCE(v_headers->>'x-forwarded-for', ''),
                    ',',
                    1
                )
            ),
            ''
        )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.observed_request_user_agent()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_headers JSONB := '{}'::JSONB;
BEGIN
    BEGIN
        v_headers := COALESCE(
            NULLIF(
                current_setting('request.headers', TRUE),
                ''
            )::JSONB,
            '{}'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        v_headers := '{}'::JSONB;
    END;

    RETURN NULLIF(
        LEFT(
            TRIM(
                COALESCE(
                    v_headers->>'user-agent',
                    ''
                )
            ),
            2000
        ),
        ''
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.observed_request_ip()
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public.observed_request_user_agent()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 7. ESTADO DE CUENTA Y CREACIÓN DE PERFIL
-- ============================================================
-- El trigger de Auth crea el perfil en pending_legal.
-- La cuenta solo pasa a active mediante la RPC legal final.
-- ============================================================

ALTER TABLE public.profiles
DROP CONSTRAINT IF EXISTS profiles_status_check;

ALTER TABLE public.profiles
ADD CONSTRAINT profiles_status_check
CHECK (
    status IN (
        'pending_legal',
        'active',
        'blocked'
    )
);

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_empresa TEXT;
    v_company_id UUID;
    v_company_code TEXT;
BEGIN
    v_empresa :=
        NULLIF(
            TRIM(
                COALESCE(
                    NEW.raw_user_meta_data->>'empresa',
                    ''
                )
            ),
            ''
        );

    IF v_empresa IS NOT NULL THEN
        v_company_code :=
            'CLI-' ||
            UPPER(
                REPLACE(
                    gen_random_uuid()::TEXT,
                    '-',
                    ''
                )
            );

        INSERT INTO public.companies (
            company_code,
            company_name,
            legal_name,
            created_by
        )
        VALUES (
            v_company_code,
            LEFT(v_empresa, 200),
            LEFT(v_empresa, 200),
            NEW.id
        )
        RETURNING id
        INTO v_company_id;
    END IF;

    INSERT INTO public.profiles (
        id,
        nombre,
        empresa,
        company_id,
        rol,
        email,
        status
    )
    VALUES (
        NEW.id,
        COALESCE(
            NULLIF(
                TRIM(
                    NEW.raw_user_meta_data->>'nombre'
                ),
                ''
            ),
            NULLIF(
                TRIM(
                    NEW.raw_user_meta_data->>'name'
                ),
                ''
            ),
            NEW.email,
            'Usuario'
        ),
        v_empresa,
        v_company_id,
        'user',
        NEW.email,
        'pending_legal'
    )
    ON CONFLICT (id)
    DO UPDATE
    SET
        nombre = EXCLUDED.nombre,
        empresa = EXCLUDED.empresa,
        company_id = EXCLUDED.company_id,
        email = EXCLUDED.email;

    RETURN NEW;
END;
$function$;

REVOKE ALL
ON FUNCTION public.handle_new_user()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 8. RPC — COMPLETAR REQUISITOS LEGALES DEL REGISTRO
-- ============================================================
-- Firma única:
--   complete_registration_legal_requirements(boolean, boolean)
--
-- Requisitos:
--   - usuario autenticado;
--   - ambos parámetros TRUE;
--   - perfil pending_legal;
--   - Condiciones de Uso vigentes;
--   - Información de Privacidad vigente;
--   - trazabilidad IP/User-Agent observados por backend;
--   - registro atómico de ambas acciones;
--   - activación únicamente al finalizar correctamente.
--
-- No se acepta document_id, versión ni hash desde el frontend.
-- ============================================================

DROP FUNCTION IF EXISTS
    public.complete_registration_legal_requirements();

CREATE OR REPLACE FUNCTION public.complete_registration_legal_requirements(
    p_terms_accepted BOOLEAN,
    p_privacy_acknowledged BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
    v_user_id UUID;
    v_profile public.profiles;

    v_terms_id UUID;
    v_terms_hash TEXT;

    v_privacy_id UUID;
    v_privacy_hash TEXT;

    v_ip TEXT;
    v_user_agent TEXT;
BEGIN
    -- --------------------------------------------------------
    -- 1. USUARIO AUTENTICADO
    -- --------------------------------------------------------

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- 2. LAS DOS CASILLAS SON OBLIGATORIAS
    -- --------------------------------------------------------

    IF p_terms_accepted IS NOT TRUE THEN
        RAISE EXCEPTION
            'Las Condiciones de Uso deben ser aceptadas';
    END IF;

    IF p_privacy_acknowledged IS NOT TRUE THEN
        RAISE EXCEPTION
            'La Información de Privacidad debe ser reconocida';
    END IF;


    -- --------------------------------------------------------
    -- 3. BLOQUEAR EL PERFIL DURANTE LA OPERACIÓN
    -- --------------------------------------------------------

    SELECT *
    INTO v_profile
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Perfil no encontrado';
    END IF;

    IF v_profile.status = 'active' THEN
        -- La cuenta ya está finalizada.
        -- No se vuelven a crear aceptaciones.
        RETURN;
    END IF;

    IF v_profile.status <> 'pending_legal' THEN
        RAISE EXCEPTION
            'La cuenta no está pendiente de completar los requisitos legales';
    END IF;


    -- --------------------------------------------------------
    -- 4. OBTENER CONDICIONES DE USO VIGENTES
    -- --------------------------------------------------------

    SELECT
        id,
        content_hash
    INTO
        v_terms_id,
        v_terms_hash
    FROM public.legal_documents
    WHERE document_type = 'terms_of_use'
      AND is_current = TRUE
      AND effective_from <= clock_timestamp()
      AND (
          effective_until IS NULL
          OR effective_until > clock_timestamp()
      )
    ORDER BY
        effective_from DESC,
        created_at DESC
    LIMIT 1;

    IF v_terms_id IS NULL THEN
        RAISE EXCEPTION
            'No existen Condiciones de Uso vigentes';
    END IF;


    -- --------------------------------------------------------
    -- 5. OBTENER INFORMACIÓN DE PRIVACIDAD VIGENTE
    -- --------------------------------------------------------

    SELECT
        id,
        content_hash
    INTO
        v_privacy_id,
        v_privacy_hash
    FROM public.legal_documents
    WHERE document_type = 'privacy_information'
      AND is_current = TRUE
      AND effective_from <= clock_timestamp()
      AND (
          effective_until IS NULL
          OR effective_until > clock_timestamp()
      )
    ORDER BY
        effective_from DESC,
        created_at DESC
    LIMIT 1;

    IF v_privacy_id IS NULL THEN
        RAISE EXCEPTION
            'No existe Información de Privacidad vigente';
    END IF;


    -- --------------------------------------------------------
    -- 6. IDENTIDAD TÉCNICA OBSERVADA POR BACKEND
    -- --------------------------------------------------------

    v_ip := public.observed_request_ip();
    v_user_agent := public.observed_request_user_agent();


    -- --------------------------------------------------------
    -- 7. REGISTRAR ACEPTACIÓN DE CONDICIONES DE USO
    -- --------------------------------------------------------

    INSERT INTO public.legal_acceptances (
        user_id,
        company_id,
        document_id,
        action_type,
        accepted_at,
        ip,
        user_agent,
        context,
        source,
        document_hash
    )
    VALUES (
        v_user_id,
        v_profile.company_id,
        v_terms_id,
        'accepted',
        clock_timestamp(),
        v_ip,
        v_user_agent,
        'registration',
        'account_creation',
        v_terms_hash
    );


    -- --------------------------------------------------------
    -- 8. REGISTRAR ACUSE DE INFORMACIÓN DE PRIVACIDAD
    -- --------------------------------------------------------

    INSERT INTO public.legal_acceptances (
        user_id,
        company_id,
        document_id,
        action_type,
        accepted_at,
        ip,
        user_agent,
        context,
        source,
        document_hash
    )
    VALUES (
        v_user_id,
        v_profile.company_id,
        v_privacy_id,
        'acknowledged',
        clock_timestamp(),
        v_ip,
        v_user_agent,
        'registration',
        'account_creation',
        v_privacy_hash
    );


    -- --------------------------------------------------------
    -- 9. ACTIVAR CUENTA SOLO DESPUÉS DE LAS DOS EVIDENCIAS
    -- --------------------------------------------------------

    UPDATE public.profiles
    SET
        status = 'active',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_user_id
      AND status = 'pending_legal';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No se pudo activar la cuenta';
    END IF;

END;
$function$;

REVOKE ALL
ON FUNCTION public.complete_registration_legal_requirements(
    BOOLEAN,
    BOOLEAN
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.complete_registration_legal_requirements(
    BOOLEAN,
    BOOLEAN
)
TO authenticated;

ALTER FUNCTION public.complete_registration_legal_requirements(
    BOOLEAN,
    BOOLEAN
)
SET search_path = public, auth, pg_temp;


-- ============================================================
-- 9. RPC — COMPROBAR REQUISITO LEGAL VIGENTE
-- ============================================================

CREATE OR REPLACE FUNCTION public.has_current_legal_action(
    p_document_type TEXT,
    p_action_type TEXT,
    p_context TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN FALSE;
    END IF;

    RETURN EXISTS (
        SELECT 1
        FROM public.legal_acceptances la
        JOIN public.legal_documents ld
          ON ld.id = la.document_id
        WHERE la.user_id = auth.uid()
          AND ld.document_type = p_document_type
          AND ld.is_current = TRUE
          AND la.action_type = p_action_type
          AND (
              p_context IS NULL
              OR la.context = p_context
          )
          AND la.document_hash = ld.content_hash
          AND la.accepted_at >= ld.effective_from
          AND (
              ld.effective_until IS NULL
              OR la.accepted_at < ld.effective_until
          )
        ORDER BY la.accepted_at DESC
        LIMIT 1
    );
END;
$function$;

REVOKE ALL
ON FUNCTION public.has_current_legal_action(
    TEXT,
    TEXT,
    TEXT
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.has_current_legal_action(
    TEXT,
    TEXT,
    TEXT
)
TO authenticated;


-- ============================================================
-- 10. RPC — CONSULTAR ESTADO LEGAL DE LA CUENTA
-- ============================================================
-- Se utiliza después de confirmar el correo y antes de acceder
-- a profiles directamente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_current_registration_status()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_status TEXT;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;

    SELECT status
    INTO v_status
    FROM public.profiles
    WHERE id = auth.uid();

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Perfil no encontrado';
    END IF;

    RETURN v_status;
END;
$function$;

REVOKE ALL
ON FUNCTION public.get_current_registration_status()
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.get_current_registration_status()
TO authenticated;

ALTER FUNCTION public.get_current_registration_status()
SET search_path = public, pg_temp;


-- ============================================================
-- 11. RPC — AUDITORÍA GRATUITA
-- ============================================================
-- Se conserva la firma de 028 como compatibilidad deliberadamente
-- bloqueada.
--
-- La firma operativa añade:
--   p_privacy_acknowledged
--   p_audit_terms_accepted
--
-- Se mantienen:
--   - validaciones de entrada;
--   - documentos legales versionados;
--   - identidad derivada del backend/proxy;
--   - rate limit 3 solicitudes/hora por identidad;
--   - bloqueo mediante advisory lock;
--   - inserción atómica;
--   - registro de ambas evidencias legales.
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_audit_request(
    p_nombre TEXT,
    p_email TEXT,
    p_empresa TEXT,
    p_empleados TEXT,
    p_proceso TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    RAISE EXCEPTION
        'La solicitud de auditoría requiere confirmación de la información de privacidad y de las condiciones de la auditoría gratuita';
END;
$function$;


CREATE OR REPLACE FUNCTION public.submit_audit_request(
    p_nombre TEXT,
    p_email TEXT,
    p_empresa TEXT,
    p_empleados TEXT,
    p_proceso TEXT,
    p_privacy_acknowledged BOOLEAN,
    p_audit_terms_accepted BOOLEAN
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_nombre TEXT;
    v_email TEXT;
    v_empresa TEXT;
    v_empleados TEXT;
    v_proceso TEXT;

    v_headers JSONB := '{}'::JSONB;

    v_ip TEXT;
    v_identity_key TEXT;

    v_window_started_at TIMESTAMPTZ;
    v_request_count INTEGER;

    v_now TIMESTAMPTZ := clock_timestamp();

    v_request_id UUID;

    v_privacy_id UUID;
    v_privacy_hash TEXT;

    v_audit_terms_id UUID;
    v_audit_terms_hash TEXT;
BEGIN

    -- --------------------------------------------------------
    -- 1. VALIDACIÓN DE ENTRADA
    -- --------------------------------------------------------

    v_nombre := NULLIF(TRIM(p_nombre), '');
    v_email := NULLIF(TRIM(p_email), '');
    v_empresa := NULLIF(TRIM(p_empresa), '');
    v_empleados := NULLIF(TRIM(p_empleados), '');
    v_proceso := NULLIF(TRIM(p_proceso), '');

    IF v_nombre IS NULL
       OR LENGTH(v_nombre) > 200
    THEN
        RAISE EXCEPTION
            'Datos de la solicitud no válidos.';
    END IF;

    IF v_email IS NULL
       OR LENGTH(v_email) > 320
       OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    THEN
        RAISE EXCEPTION
            'Datos de la solicitud no válidos.';
    END IF;

    IF v_empresa IS NULL
       OR LENGTH(v_empresa) > 200
    THEN
        RAISE EXCEPTION
            'Datos de la solicitud no válidos.';
    END IF;

    IF v_empleados IS NULL
       OR LENGTH(v_empleados) > 50
    THEN
        RAISE EXCEPTION
            'Datos de la solicitud no válidos.';
    END IF;

    IF v_proceso IS NULL
       OR LENGTH(v_proceso) > 4000
    THEN
        RAISE EXCEPTION
            'Datos de la solicitud no válidos.';
    END IF;


    -- --------------------------------------------------------
    -- 2. LAS CASILLAS SON OBLIGATORIAS
    -- --------------------------------------------------------

    IF COALESCE(
        p_privacy_acknowledged,
        FALSE
    ) <> TRUE
    THEN
        RAISE EXCEPTION
            'Debes confirmar que has sido informado/a sobre el tratamiento de tus datos';
    END IF;

    IF COALESCE(
        p_audit_terms_accepted,
        FALSE
    ) <> TRUE
    THEN
        RAISE EXCEPTION
            'Debes aceptar las condiciones de la auditoría gratuita';
    END IF;


    -- --------------------------------------------------------
    -- 3. DOCUMENTO DE PRIVACIDAD VIGENTE
    -- --------------------------------------------------------

    SELECT
        id,
        content_hash
    INTO
        v_privacy_id,
        v_privacy_hash
    FROM public.legal_documents
    WHERE document_type = 'privacy_information'
      AND is_current = TRUE
      AND effective_from <= clock_timestamp()
      AND (
          effective_until IS NULL
          OR effective_until > clock_timestamp()
      )
    ORDER BY
        effective_from DESC,
        created_at DESC
    LIMIT 1;

    IF v_privacy_id IS NULL THEN
        RAISE EXCEPTION
            'No existe Información de Privacidad vigente';
    END IF;


    -- --------------------------------------------------------
    -- 4. DOCUMENTO DE CONDICIONES DE AUDITORÍA VIGENTE
    -- --------------------------------------------------------

    SELECT
        id,
        content_hash
    INTO
        v_audit_terms_id,
        v_audit_terms_hash
    FROM public.legal_documents
    WHERE document_type = 'audit_terms'
      AND is_current = TRUE
      AND effective_from <= clock_timestamp()
      AND (
          effective_until IS NULL
          OR effective_until > clock_timestamp()
      )
    ORDER BY
        effective_from DESC,
        created_at DESC
    LIMIT 1;

    IF v_audit_terms_id IS NULL THEN
        RAISE EXCEPTION
            'No existen Condiciones de la Auditoría Gratuita vigentes';
    END IF;


    -- --------------------------------------------------------
    -- 5. CABECERAS OBSERVADAS POR EL BACKEND
    -- --------------------------------------------------------

    BEGIN
        v_headers := COALESCE(
            NULLIF(
                current_setting(
                    'request.headers',
                    TRUE
                ),
                ''
            )::JSONB,
            '{}'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        v_headers := '{}'::JSONB;
    END;

    v_ip :=
        COALESCE(
            NULLIF(
                TRIM(
                    v_headers->>'cf-connecting-ip'
                ),
                ''
            ),
            NULLIF(
                TRIM(
                    v_headers->>'x-real-ip'
                ),
                ''
            ),
            NULLIF(
                TRIM(
                    SPLIT_PART(
                        COALESCE(
                            v_headers->>'x-forwarded-for',
                            ''
                        ),
                        ',',
                        1
                    )
                ),
                ''
            ),
            'unknown'
        );


    -- --------------------------------------------------------
    -- 6. IDENTIDAD DERIVADA DE LA IP OBSERVADA
    -- --------------------------------------------------------

    v_identity_key :=
    'audit:' ||
    encode(
        extensions.digest(
            convert_to(v_ip, 'UTF8'),
            'sha256'
        ),
        'hex'
    );


    -- --------------------------------------------------------
    -- 7. RATE LIMIT: 3 SOLICITUDES / HORA / IDENTIDAD
    -- --------------------------------------------------------

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_identity_key,
            28
        )
    );

    SELECT
        window_started_at,
        request_count
    INTO
        v_window_started_at,
        v_request_count
    FROM public.public_form_rate_limits
    WHERE identity_key = v_identity_key
      AND form_key = 'audit_request'
    FOR UPDATE;

    IF NOT FOUND THEN

        INSERT INTO public.public_form_rate_limits (
            identity_key,
            form_key,
            window_started_at,
            request_count
        )
        VALUES (
            v_identity_key,
            'audit_request',
            v_now,
            1
        );

    ELSE

        IF EXTRACT(
            EPOCH FROM (
                v_now - v_window_started_at
            )
        ) >= 3600
        THEN

            UPDATE public.public_form_rate_limits
            SET
                window_started_at = v_now,
                request_count = 1,
                updated_at = v_now
            WHERE identity_key = v_identity_key
              AND form_key = 'audit_request';

        ELSIF v_request_count >= 3 THEN

            RAISE EXCEPTION
                'Demasiadas solicitudes. Por favor, inténtalo de nuevo más tarde.';

        ELSE

            UPDATE public.public_form_rate_limits
            SET
                request_count = request_count + 1,
                updated_at = v_now
            WHERE identity_key = v_identity_key
              AND form_key = 'audit_request';

        END IF;

    END IF;


    -- --------------------------------------------------------
    -- 8. INSERTAR SOLICITUD
    -- --------------------------------------------------------

    INSERT INTO public.audit_requests (
        nombre,
        email,
        empresa,
        empleados,
        proceso,
        estado
    )
    VALUES (
        v_nombre,
        v_email,
        v_empresa,
        v_empleados,
        v_proceso,
        'nuevo'
    )
    RETURNING id
    INTO v_request_id;


    -- --------------------------------------------------------
    -- 9. REGISTRAR PRIVACIDAD
    -- --------------------------------------------------------

    INSERT INTO public.legal_acceptances (
        user_id,
        company_id,
        document_id,
        action_type,
        accepted_at,
        ip,
        user_agent,
        context,
        source,
        document_hash,
        identity_key,
        metadata
    )
    VALUES (
        auth.uid(),
        NULL,
        v_privacy_id,
        'acknowledged',
        v_now,
        NULLIF(v_ip, 'unknown'),
        NULLIF(
            LEFT(
                TRIM(
                    COALESCE(
                        v_headers->>'user-agent',
                        ''
                    )
                ),
                2000
            ),
            ''
        ),
        'audit_request',
        'public_form',
        v_privacy_hash,
        v_identity_key,
        jsonb_build_object(
            'audit_request_id',
            v_request_id
        )
    );


    -- --------------------------------------------------------
    -- 10. REGISTRAR CONDICIONES DE AUDITORÍA
    -- --------------------------------------------------------

    INSERT INTO public.legal_acceptances (
        user_id,
        company_id,
        document_id,
        action_type,
        accepted_at,
        ip,
        user_agent,
        context,
        source,
        document_hash,
        identity_key,
        metadata
    )
    VALUES (
        auth.uid(),
        NULL,
        v_audit_terms_id,
        'accepted',
        v_now,
        NULLIF(v_ip, 'unknown'),
        NULLIF(
            LEFT(
                TRIM(
                    COALESCE(
                        v_headers->>'user-agent',
                        ''
                    )
                ),
                2000
            ),
            ''
        ),
        'audit_request',
        'public_form',
        v_audit_terms_hash,
        v_identity_key,
        jsonb_build_object(
            'audit_request_id',
            v_request_id
        )
    );


    RETURN v_request_id;

END;
$function$;


-- ============================================================
-- 12. PERMISOS DE LAS RPC DE AUDITORÍA
-- ============================================================

REVOKE ALL
ON FUNCTION public.submit_audit_request(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT
)
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public.submit_audit_request(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN,
    BOOLEAN
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.submit_audit_request(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN,
    BOOLEAN
)
TO anon, authenticated;


-- ============================================================
-- 13. RLS Y PERMISOS DE DOCUMENTOS LEGALES
-- ============================================================

ALTER TABLE public.legal_documents
ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON public.legal_documents
FROM PUBLIC, anon, authenticated;

GRANT SELECT
ON public.legal_documents
TO authenticated;

DROP POLICY IF EXISTS legal_documents_current_select
ON public.legal_documents;

CREATE POLICY legal_documents_current_select
ON public.legal_documents
FOR SELECT
TO authenticated
USING (
    is_current = TRUE
    AND effective_from <= clock_timestamp()
    AND (
        effective_until IS NULL
        OR effective_until > clock_timestamp()
    )
);

DROP POLICY IF EXISTS legal_documents_worker_select
ON public.legal_documents;

CREATE POLICY legal_documents_worker_select
ON public.legal_documents
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);

REVOKE INSERT, UPDATE, DELETE
ON public.legal_documents
FROM anon, authenticated;


-- ============================================================
-- 14. PERMISOS DE FUNCIONES AUXILIARES
-- ============================================================

REVOKE ALL
ON FUNCTION public.sync_legal_document_hash()
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public.protect_legal_document_identity()
FROM PUBLIC, anon, authenticated;

REVOKE ALL
ON FUNCTION public.protect_legal_acceptance()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 15. DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.legal_documents IS
'Versiones inmutables lógicamente de documentos legales. El contenido se conserva íntegro y content_hash permite verificar su integridad.';

COMMENT ON TABLE public.legal_acceptances IS
'Histórico inmutable de aceptaciones, acuses, consentimientos y retiradas, asociado a una versión concreta de un documento.';

COMMENT ON COLUMN public.legal_acceptances.action_type IS
'accepted = aceptación; acknowledged = acuse de información; consented = consentimiento; withdrawn = retirada de consentimiento.';

COMMENT ON FUNCTION public.complete_registration_legal_requirements(
    BOOLEAN,
    BOOLEAN
) IS
'Completa los requisitos legales del registro: acepta Condiciones de Uso, registra el acuse de Información de Privacidad y activa la cuenta.';

COMMENT ON FUNCTION public.submit_audit_request(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT
) IS
'Firma legacy deliberadamente bloqueada: la solicitud de auditoría requiere las confirmaciones legales de la nueva firma.';

COMMENT ON FUNCTION public.submit_audit_request(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN,
    BOOLEAN
) IS
'Solicitud pública de auditoría gratuita con confirmación obligatoria de Información de Privacidad y Condiciones de la Auditoría Gratuita. Mantiene el rate limit de 028 y registra las evidencias legales versionadas.';


-- ============================================================
-- 16. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- legal_documents
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'legal_documents'
    ) THEN
        RAISE EXCEPTION
            '038 failed: legal_documents missing';
    END IF;


    -- --------------------------------------------------------
    -- legal_acceptances
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'legal_acceptances'
    ) THEN
        RAISE EXCEPTION
            '038 failed: legal_acceptances missing';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_class
    WHERE oid IN (
        'public.legal_documents'::regclass,
        'public.legal_acceptances'::regclass
    )
    AND relrowsecurity = TRUE;

    IF v_count <> 2 THEN
        RAISE EXCEPTION
            '038 failed: legal tables RLS is incomplete';
    END IF;


    -- --------------------------------------------------------
    -- RPC DE REGISTRO FINAL
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.complete_registration_legal_requirements(boolean,boolean)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '038 failed: registration legal RPC missing';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'public.complete_registration_legal_requirements(boolean,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '038 failed: authenticated cannot execute registration legal RPC';
    END IF;


    -- --------------------------------------------------------
    -- LA FIRMA ANTIGUA DE REGISTRO NO DEBE EXISTIR
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.complete_registration_legal_requirements()'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            '038 failed: legacy zero-argument registration RPC remains';
    END IF;


    -- --------------------------------------------------------
    -- RPC DE ESTADO
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.get_current_registration_status()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '038 failed: registration status RPC missing';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'public.get_current_registration_status()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '038 failed: authenticated cannot execute registration status RPC';
    END IF;


    -- --------------------------------------------------------
    -- RPC DE COMPROBACIÓN LEGAL
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.has_current_legal_action(text,text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '038 failed: legal action RPC missing';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'public.has_current_legal_action(text,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '038 failed: authenticated cannot execute legal action RPC';
    END IF;


    -- --------------------------------------------------------
    -- FIRMA ANTIGUA DE AUDITORÍA BLOQUEADA
    -- --------------------------------------------------------

    IF has_function_privilege(
        'anon',
        'public.submit_audit_request(text,text,text,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '038 failed: legacy audit RPC remains executable';
    END IF;


    -- --------------------------------------------------------
    -- FIRMA NUEVA DE AUDITORÍA EJECUTABLE
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'anon',
        'public.submit_audit_request(text,text,text,text,text,boolean,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '038 failed: legal audit RPC is not executable by anon';
    END IF;


    -- --------------------------------------------------------
    -- SIN ESCRITURA DIRECTA EN legal_documents
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.legal_documents',
        'INSERT'
    )
    OR has_table_privilege(
        'authenticated',
        'public.legal_documents',
        'UPDATE'
    )
    OR has_table_privilege(
        'authenticated',
        'public.legal_documents',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '038 failed: authenticated retains write access to legal_documents';
    END IF;


    -- --------------------------------------------------------
    -- SIN ESCRITURA DIRECTA EN legal_acceptances
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.legal_acceptances',
        'INSERT'
    )
    OR has_table_privilege(
        'authenticated',
        'public.legal_acceptances',
        'UPDATE'
    )
    OR has_table_privilege(
        'authenticated',
        'public.legal_acceptances',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '038 failed: authenticated retains write access to legal_acceptances';
    END IF;

END $$;


-- ============================================================
-- FIN
-- ============================================================

COMMIT;
