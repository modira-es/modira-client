-- ============================================================
-- MODIRA — 094_company_iva_change_requests.sql
-- ============================================================
--
-- OBJETIVO
--
-- Crear un sistema GENERAL de configuración y solicitud de IVA
-- a nivel de empresa.
--
-- Además, endurecer el sistema de solicitudes de IVA específico
-- de mantenimiento ya existente.
--
-- ============================================================
--
-- IVA GENERAL DE EMPRESA
--
-- Prioridad:
--
--   1. IVA aprobado por solicitud del cliente
--   2. IVA recomendado por worker
--   3. IVA por defecto: 21 %
--
-- El worker puede sobrescribir manualmente el IVA al crear:
--
--   - presupuestos
--   - facturas normales
--
-- El IVA aprobado NO sobrescribe ni elimina el IVA recomendado.
--
-- ============================================================
--
-- MANTENIMIENTO
--
-- El IVA de mantenimiento permanece completamente independiente.
--
-- Esta migración NO modifica:
--
--   - maintenance_contracts.iva_aplicado
--   - maintenance_contracts.iva_porcentaje
--   - maintenance_contracts.iva_source
--   - maintenance_invoices
--   - facturación histórica
--   - Stripe
--
-- Únicamente endurece:
--
--   - maintenance_iva_change_requests
--
-- mediante:
--
--   - límites de tamaño
--   - constraints
--   - comentarios
--   - rate limiting
--
-- ============================================================


BEGIN;


-- ============================================================
-- 0. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- companies
    -- --------------------------------------------------------

    IF to_regclass('public.companies') IS NULL THEN
        RAISE EXCEPTION
            '094 stopped: public.companies does not exist';
    END IF;


    -- --------------------------------------------------------
    -- profiles
    -- --------------------------------------------------------

    IF to_regclass('public.profiles') IS NULL THEN
        RAISE EXCEPTION
            '094 stopped: public.profiles does not exist';
    END IF;


    -- --------------------------------------------------------
    -- workers
    -- --------------------------------------------------------

    IF to_regclass('public.workers') IS NULL THEN
        RAISE EXCEPTION
            '094 stopped: public.workers does not exist';
    END IF;


    -- --------------------------------------------------------
    -- security_rate_limits
    -- --------------------------------------------------------

    IF to_regclass('public.security_rate_limits') IS NULL THEN
        RAISE EXCEPTION
            '094 stopped: public.security_rate_limits does not exist';
    END IF;


    -- --------------------------------------------------------
    -- enforce_security_rate_limit()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'enforce_security_rate_limit'
          AND p.pronargs = 3
          AND p.proargtypes[0] = 'text'::regtype::oid
          AND p.proargtypes[1] = 'integer'::regtype::oid
          AND p.proargtypes[2] = 'integer'::regtype::oid
    ) THEN

        RAISE EXCEPTION
            '094 stopped: enforce_security_rate_limit(text, integer, integer) does not exist';

    END IF;


    -- --------------------------------------------------------
    -- current_user_is_worker()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
          AND p.pronargs = 0
    ) THEN

        RAISE EXCEPTION
            '094 stopped: current_user_is_worker() does not exist';

    END IF;


    -- --------------------------------------------------------
    -- current_user_is_active()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_active'
          AND p.pronargs = 0
    ) THEN

        RAISE EXCEPTION
            '094 stopped: current_user_is_active() does not exist';

    END IF;


    -- --------------------------------------------------------
    -- current_user_company_id()
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_company_id'
          AND p.pronargs = 0
    ) THEN

        RAISE EXCEPTION
            '094 stopped: current_user_company_id() does not exist';

    END IF;


END;
$$;


-- ============================================================
-- 1. IVA GENERAL APROBADO EN companies
-- ============================================================
--
-- IMPORTANTE:
--
-- Estos campos son independientes de:
--
--   iva_recomendado_aplicado
--   iva_recomendado_porcentaje
--   iva_recomendado_por
--   iva_recomendado_updated_at
--
-- La recomendación del worker NO se elimina cuando se aprueba
-- una solicitud del cliente.
--
-- ============================================================

ALTER TABLE public.companies
ADD COLUMN IF NOT EXISTS iva_aprobado_aplicado BOOLEAN
NOT NULL
DEFAULT FALSE;


ALTER TABLE public.companies
ADD COLUMN IF NOT EXISTS iva_aprobado_porcentaje NUMERIC(5,2)
NOT NULL
DEFAULT 0;


ALTER TABLE public.companies
ADD COLUMN IF NOT EXISTS iva_aprobado_por UUID;


ALTER TABLE public.companies
ADD COLUMN IF NOT EXISTS iva_aprobado_at TIMESTAMPTZ;


-- ============================================================
-- 2. FK DEL WORKER QUE APROBÓ EL IVA
-- ============================================================

ALTER TABLE public.companies
DROP CONSTRAINT IF EXISTS companies_iva_aprobado_por_fkey;


ALTER TABLE public.companies
ADD CONSTRAINT companies_iva_aprobado_por_fkey
FOREIGN KEY (iva_aprobado_por)
REFERENCES auth.users(id)
ON DELETE SET NULL;


-- ============================================================
-- 3. CONSTRAINT IVA APROBADO
-- ============================================================

ALTER TABLE public.companies
DROP CONSTRAINT IF EXISTS companies_iva_aprobado_check;


ALTER TABLE public.companies
ADD CONSTRAINT companies_iva_aprobado_check
CHECK (
    (
        iva_aprobado_aplicado = TRUE
        AND iva_aprobado_porcentaje >= 0
        AND iva_aprobado_porcentaje <= 100
    )
    OR
    (
        iva_aprobado_aplicado = FALSE
        AND iva_aprobado_porcentaje = 0
    )
);


-- ============================================================
-- 4. COMENTARIOS — companies
-- ============================================================

COMMENT ON COLUMN public.companies.iva_aprobado_aplicado
IS
'Indica si la empresa tiene actualmente un tratamiento de IVA general aprobado mediante una solicitud del cliente. Es independiente del IVA recomendado por el worker y del IVA de mantenimiento.';


COMMENT ON COLUMN public.companies.iva_aprobado_porcentaje
IS
'Porcentaje de IVA general aprobado actualmente para la empresa. Se utiliza como configuración predeterminada para nuevos presupuestos y facturas normales, pero el worker puede sobrescribirlo manualmente. No modifica registros históricos.';


COMMENT ON COLUMN public.companies.iva_aprobado_por
IS
'Usuario de Auth del worker que aprobó el tratamiento de IVA general actualmente vigente.';


COMMENT ON COLUMN public.companies.iva_aprobado_at
IS
'Fecha y hora de aprobación del tratamiento de IVA general actualmente vigente.';


-- ============================================================
-- 5. TABLA — SOLICITUDES DE IVA GENERAL
-- ============================================================

CREATE TABLE IF NOT EXISTS public.company_iva_change_requests (

    id UUID
        PRIMARY KEY
        DEFAULT gen_random_uuid(),

    company_id UUID
        NOT NULL
        REFERENCES public.companies(id)
        ON DELETE CASCADE,

    user_id UUID
        NOT NULL
        REFERENCES auth.users(id)
        ON DELETE CASCADE,

    requested_iva_aplicado BOOLEAN
        NOT NULL,

    requested_iva_porcentaje NUMERIC(5,2)
        NOT NULL
        DEFAULT 0,

    reason TEXT
        NOT NULL,

    status TEXT
        NOT NULL
        DEFAULT 'pending',

    reviewed_by UUID,

    reviewed_at TIMESTAMPTZ,

    worker_notes TEXT,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ
        NOT NULL
        DEFAULT CURRENT_TIMESTAMP

);


-- ============================================================
-- 6. FOREIGN KEY — WORKER REVISOR
-- ============================================================

ALTER TABLE public.company_iva_change_requests
DROP CONSTRAINT IF EXISTS company_iva_change_requests_reviewed_by_fkey;


ALTER TABLE public.company_iva_change_requests
ADD CONSTRAINT company_iva_change_requests_reviewed_by_fkey
FOREIGN KEY (reviewed_by)
REFERENCES auth.users(id)
ON DELETE SET NULL;


-- ============================================================
-- 7. CONSTRAINT IVA SOLICITADO
-- ============================================================

ALTER TABLE public.company_iva_change_requests
DROP CONSTRAINT IF EXISTS company_iva_change_requests_iva_check;


ALTER TABLE public.company_iva_change_requests
ADD CONSTRAINT company_iva_change_requests_iva_check
CHECK (
    (
        requested_iva_aplicado = TRUE
        AND requested_iva_porcentaje >= 0
        AND requested_iva_porcentaje <= 100
    )
    OR
    (
        requested_iva_aplicado = FALSE
        AND requested_iva_porcentaje = 0
    )
);


-- ============================================================
-- 8. CONSTRAINT — ESTADO
-- ============================================================

ALTER TABLE public.company_iva_change_requests
DROP CONSTRAINT IF EXISTS company_iva_change_requests_status_check;


ALTER TABLE public.company_iva_change_requests
ADD CONSTRAINT company_iva_change_requests_status_check
CHECK (
    status IN (
        'pending',
        'in_review',
        'approved',
        'rejected',
        'cancelled'
    )
);


-- ============================================================
-- 9. LÍMITES DE TAMAÑO — SOLICITUD IVA GENERAL
-- ============================================================
--
-- reason:
--   máximo 2.000 caracteres
--   máximo 16 KiB
--
-- worker_notes:
--   máximo 2.000 caracteres
--   máximo 16 KiB
--
-- El límite por bytes evita abusos utilizando caracteres
-- multibyte aunque el número de caracteres sea válido.
--
-- ============================================================

ALTER TABLE public.company_iva_change_requests
DROP CONSTRAINT IF EXISTS company_iva_change_requests_reason_length_check;


ALTER TABLE public.company_iva_change_requests
ADD CONSTRAINT company_iva_change_requests_reason_length_check
CHECK (
    char_length(reason) BETWEEN 1 AND 2000
    AND pg_column_size(reason) <= 16384
);


ALTER TABLE public.company_iva_change_requests
DROP CONSTRAINT IF EXISTS company_iva_change_requests_worker_notes_length_check;


ALTER TABLE public.company_iva_change_requests
ADD CONSTRAINT company_iva_change_requests_worker_notes_length_check
CHECK (
    worker_notes IS NULL
    OR (
        char_length(worker_notes) <= 2000
        AND pg_column_size(worker_notes) <= 16384
    )
);


-- ============================================================
-- 10. ÍNDICES — IVA GENERAL
-- ============================================================

CREATE INDEX IF NOT EXISTS
idx_company_iva_change_requests_company
ON public.company_iva_change_requests (
    company_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
idx_company_iva_change_requests_user
ON public.company_iva_change_requests (
    user_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
idx_company_iva_change_requests_status
ON public.company_iva_change_requests (
    status,
    created_at DESC
);


-- ============================================================
-- 11. UNA SOLICITUD ACTIVA POR EMPRESA
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
idx_company_iva_change_requests_one_active
ON public.company_iva_change_requests (
    company_id
)
WHERE status IN ('pending', 'in_review');


-- ============================================================
-- 12. UPDATED_AT — IVA GENERAL
-- ============================================================

DROP TRIGGER IF EXISTS
company_iva_change_requests_updated_at
ON public.company_iva_change_requests;


CREATE TRIGGER
company_iva_change_requests_updated_at
BEFORE UPDATE
ON public.company_iva_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 13. RLS — IVA GENERAL
-- ============================================================

ALTER TABLE public.company_iva_change_requests
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS
company_iva_change_requests_client_select
ON public.company_iva_change_requests;


CREATE POLICY
company_iva_change_requests_client_select
ON public.company_iva_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


DROP POLICY IF EXISTS
company_iva_change_requests_worker_select
ON public.company_iva_change_requests;


CREATE POLICY
company_iva_change_requests_worker_select
ON public.company_iva_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 14. ESCRITURA DIRECTA — IVA GENERAL
-- ============================================================

DROP POLICY IF EXISTS
company_iva_change_requests_client_insert
ON public.company_iva_change_requests;


DROP POLICY IF EXISTS
company_iva_change_requests_worker_insert
ON public.company_iva_change_requests;


DROP POLICY IF EXISTS
company_iva_change_requests_client_update
ON public.company_iva_change_requests;


DROP POLICY IF EXISTS
company_iva_change_requests_worker_update
ON public.company_iva_change_requests;


DROP POLICY IF EXISTS
company_iva_change_requests_worker_delete
ON public.company_iva_change_requests;


REVOKE ALL
ON public.company_iva_change_requests
FROM PUBLIC, anon, authenticated;


GRANT SELECT
ON public.company_iva_change_requests
TO authenticated;


-- ============================================================
-- 15. FUNCIÓN — RATE LIMIT IVA GENERAL
-- ============================================================
--
-- Cliente:
--
--   3 solicitudes / 24 horas
--
-- Worker:
--
--   60 resoluciones / hora
--
-- Se reutiliza security_rate_limits.
--
-- La función es SECURITY DEFINER para poder utilizar
-- enforce_security_rate_limit(), cuyo acceso directo está
-- restringido.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.rate_limit_company_iva_change_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_user_id UUID;
    v_is_worker BOOLEAN;

BEGIN

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN NEW;
    END IF;


    v_is_worker := public.current_user_is_worker();


    -- --------------------------------------------------------
    -- CLIENTE CREA SOLICITUD
    -- --------------------------------------------------------

    IF TG_OP = 'INSERT'
       AND NOT v_is_worker
    THEN

        PERFORM public.enforce_security_rate_limit(
            'company_iva_change_request:client:' || v_user_id::TEXT,
            3,
            86400
        );

        RETURN NEW;

    END IF;


    -- --------------------------------------------------------
    -- WORKER RESUELVE SOLICITUD
    -- --------------------------------------------------------

    IF TG_OP = 'UPDATE'
       AND v_is_worker
    THEN

        PERFORM public.enforce_security_rate_limit(
            'company_iva_change_request:worker:' || v_user_id::TEXT,
            60,
            3600
        );

        RETURN NEW;

    END IF;


    RETURN NEW;

END;
$function$;


REVOKE ALL
ON FUNCTION public.rate_limit_company_iva_change_request()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 16. TRIGGER — RATE LIMIT IVA GENERAL
-- ============================================================

DROP TRIGGER IF EXISTS
company_iva_change_requests_rate_limit
ON public.company_iva_change_requests;


CREATE TRIGGER
company_iva_change_requests_rate_limit
BEFORE INSERT OR UPDATE
ON public.company_iva_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.rate_limit_company_iva_change_request();


-- ============================================================
-- 17. RPC — SOLICITAR IVA GENERAL
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_company_iva_change(
    p_requested_iva_aplicado BOOLEAN,
    p_requested_iva_porcentaje NUMERIC,
    p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE

    v_user_id UUID;
    v_company_id UUID;
    v_request_id UUID;
    v_percentage NUMERIC(5,2);
    v_reason TEXT;

BEGIN

    v_user_id := auth.uid();


    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado.';
    END IF;


    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Los trabajadores no pueden crear solicitudes de IVA de cliente.';
    END IF;


    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'El usuario no está activo.';
    END IF;


    v_company_id :=
        public.current_user_company_id();


    IF v_company_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario no está asociado a una empresa.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.companies c
        WHERE c.id = v_company_id
          AND c.is_active = TRUE
    ) THEN
        RAISE EXCEPTION
            'La empresa no existe o está inactiva.';
    END IF;


    -- --------------------------------------------------------
    -- IVA
    -- --------------------------------------------------------

    IF p_requested_iva_aplicado IS NULL THEN
        RAISE EXCEPTION
            'Debes indicar si el IVA se aplica.';
    END IF;


    IF p_requested_iva_aplicado = FALSE THEN

        v_percentage := 0;

    ELSE

        IF p_requested_iva_porcentaje IS NULL THEN
            RAISE EXCEPTION
                'Debes indicar el porcentaje de IVA.';
        END IF;


        v_percentage :=
            ROUND(p_requested_iva_porcentaje, 2);


        IF v_percentage < 0
           OR v_percentage > 100
        THEN
            RAISE EXCEPTION
                'El porcentaje de IVA debe estar entre 0 y 100.';
        END IF;

    END IF;


    -- --------------------------------------------------------
    -- JUSTIFICACIÓN
    -- --------------------------------------------------------

    v_reason :=
        NULLIF(
            BTRIM(COALESCE(p_reason, '')),
            ''
        );


    IF v_reason IS NULL THEN
        RAISE EXCEPTION
            'Debes indicar el motivo de la solicitud.';
    END IF;


    IF char_length(v_reason) > 2000 THEN
        RAISE EXCEPTION
            'El motivo no puede superar 2000 caracteres.';
    END IF;


    IF pg_column_size(v_reason) > 16384 THEN
        RAISE EXCEPTION
            'El motivo supera el tamaño máximo permitido.';
    END IF;


    -- --------------------------------------------------------
    -- SOLICITUD ACTIVA
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.company_iva_change_requests r
        WHERE r.company_id = v_company_id
          AND r.status IN ('pending', 'in_review')
    ) THEN

        RAISE EXCEPTION
            'Ya existe una solicitud de IVA pendiente para esta empresa.';

    END IF;


    -- --------------------------------------------------------
    -- INSERT
    -- El trigger aplica rate limit al cliente.
    -- --------------------------------------------------------

    INSERT INTO public.company_iva_change_requests (
        company_id,
        user_id,
        requested_iva_aplicado,
        requested_iva_porcentaje,
        reason,
        status
    )
    VALUES (
        v_company_id,
        v_user_id,
        p_requested_iva_aplicado,
        v_percentage,
        v_reason,
        'pending'
    )
    RETURNING id
    INTO v_request_id;


    RETURN v_request_id;

END;
$function$;


REVOKE ALL
ON FUNCTION public.request_company_iva_change(
    BOOLEAN,
    NUMERIC,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.request_company_iva_change(
    BOOLEAN,
    NUMERIC,
    TEXT
)
TO authenticated;


ALTER FUNCTION public.request_company_iva_change(
    BOOLEAN,
    NUMERIC,
    TEXT
)
SET search_path = public, pg_temp;

-- ============================================================
-- 18. RPC — RESOLVER IVA GENERAL
-- ============================================================
--
-- Solo un worker activo puede resolver la solicitud.
--
-- Trazabilidad:
--
--   - reviewed_by  = worker que resuelve
--   - reviewed_at  = momento exacto de resolución
--   - worker_notes = notas internas del worker
--   - status       = decisión final
--
-- Si se aprueba:
--
--   companies.iva_aprobado_* se actualiza con los datos
--   solicitados por el cliente.
--
-- IMPORTANTE:
--
--   - NO modifica iva_recomendado_*
--   - NO modifica maintenance_contracts
--   - NO modifica maintenance_invoices
--   - NO modifica facturas históricas
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.resolve_company_iva_change_request(
    p_request_id UUID,
    p_action TEXT,
    p_worker_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE

    v_request public.company_iva_change_requests%ROWTYPE;

    v_user_id UUID := auth.uid();

    v_worker_id UUID;

    v_action TEXT;

    v_notes TEXT;

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado.';
    END IF;


    -- ========================================================
    -- 2. COMPROBAR WORKER ACTIVO
    -- ========================================================
    --
    -- IMPORTANTE:
    --
    -- workers utiliza is_active.
    -- El estado de la cuenta se comprueba además mediante
    -- profiles.status.
    --
    -- Esto mantiene exactamente la misma lógica utilizada por
    -- current_user_is_worker().
    --
    -- ========================================================

    SELECT w.auth_user_id
    INTO v_worker_id
    FROM public.workers w
    JOIN public.profiles p
        ON p.id = w.auth_user_id
    WHERE w.auth_user_id = v_user_id
      AND w.is_active = TRUE
      AND p.status = 'active'
    LIMIT 1;


    IF v_worker_id IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo.';
    END IF;


    -- ========================================================
    -- 3. VALIDAR ACCIÓN
    -- ========================================================

    v_action :=
        LOWER(
            BTRIM(
                COALESCE(p_action, '')
            )
        );


    IF v_action NOT IN (
        'approved',
        'rejected'
    ) THEN
        RAISE EXCEPTION
            'Acción no válida. Debe ser approved o rejected.';
    END IF;


    -- ========================================================
    -- 4. NORMALIZAR NOTAS DEL WORKER
    -- ========================================================

    v_notes :=
        NULLIF(
            BTRIM(
                COALESCE(p_worker_notes, '')
            ),
            ''
        );


    IF v_notes IS NOT NULL
       AND char_length(v_notes) > 2000
    THEN
        RAISE EXCEPTION
            'Las notas del trabajador no pueden superar 2000 caracteres.';
    END IF;


    IF v_notes IS NOT NULL
       AND pg_column_size(v_notes) > 16384
    THEN
        RAISE EXCEPTION
            'Las notas del trabajador superan el tamaño máximo permitido.';
    END IF;


    -- ========================================================
    -- 5. BLOQUEAR LA SOLICITUD
    -- ========================================================
    --
    -- FOR UPDATE evita que dos workers puedan resolver
    -- simultáneamente la misma solicitud.
    --
    -- ========================================================

    SELECT *
    INTO v_request
    FROM public.company_iva_change_requests
    WHERE id = p_request_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La solicitud de IVA no existe.';
    END IF;


    -- ========================================================
    -- 6. SOLO SE PUEDEN RESOLVER SOLICITUDES ACTIVAS
    -- ========================================================

    IF v_request.status NOT IN (
        'pending',
        'in_review'
    ) THEN
        RAISE EXCEPTION
            'La solicitud de IVA ya ha sido resuelta.';
    END IF;


    -- ========================================================
    -- 7. RECHAZO
    -- ========================================================

    IF v_action = 'rejected' THEN

        UPDATE public.company_iva_change_requests
        SET
            status =
                'rejected',

            reviewed_by =
                v_worker_id,

            reviewed_at =
                CURRENT_TIMESTAMP,

            worker_notes =
                v_notes,

            updated_at =
                CURRENT_TIMESTAMP

        WHERE id = v_request.id;


        RETURN TRUE;

    END IF;


    -- ========================================================
    -- 8. APROBACIÓN
    -- ========================================================
    --
    -- Se conserva la recomendación del worker.
    --
    -- La aprobación del cliente se almacena por separado:
    --
    --   iva_aprobado_aplicado
    --   iva_aprobado_porcentaje
    --   iva_aprobado_por
    --   iva_aprobado_at
    --
    -- Esto permite saber:
    --
    --   qué pidió el cliente
    --   quién lo aprobó
    --   cuándo se aprobó
    --   qué tratamiento quedó vigente
    --
    -- ========================================================

    UPDATE public.companies
    SET
        iva_aprobado_aplicado =
            v_request.requested_iva_aplicado,

        iva_aprobado_porcentaje =
            CASE
                WHEN v_request.requested_iva_aplicado = TRUE
                THEN v_request.requested_iva_porcentaje
                ELSE 0
            END,

        iva_aprobado_por =
            v_worker_id,

        iva_aprobado_at =
            CURRENT_TIMESTAMP,

        updated_at =
            CURRENT_TIMESTAMP

    WHERE id = v_request.company_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La empresa asociada a la solicitud no existe.';
    END IF;


    -- ========================================================
    -- 9. CERRAR LA SOLICITUD
    -- ========================================================

    UPDATE public.company_iva_change_requests
    SET
        status =
            'approved',

        reviewed_by =
            v_worker_id,

        reviewed_at =
            CURRENT_TIMESTAMP,

        worker_notes =
            v_notes,

        updated_at =
            CURRENT_TIMESTAMP

    WHERE id = v_request.id;


    RETURN TRUE;

END;
$function$;


REVOKE ALL
ON FUNCTION public.resolve_company_iva_change_request(
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.resolve_company_iva_change_request(
    UUID,
    TEXT,
    TEXT
)
TO authenticated;


ALTER FUNCTION public.resolve_company_iva_change_request(
    UUID,
    TEXT,
    TEXT
)
SET search_path = public, pg_temp;

-- ============================================================
-- 19. RPC — IVA EFECTIVO DE EMPRESA
-- ============================================================
--
-- PRIORIDAD:
--
--   approved
--      ↓
--   recommended
--      ↓
--   default 21
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_company_effective_iva(
    p_company_id UUID
)
RETURNS TABLE (
    iva_aplicado BOOLEAN,
    iva_porcentaje NUMERIC(5,2),
    source TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE

    v_user_company_id UUID;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado.';
    END IF;


    IF NOT public.current_user_is_worker() THEN

        IF NOT public.current_user_is_active() THEN
            RAISE EXCEPTION
                'El usuario no está activo.';
        END IF;


        v_user_company_id :=
            public.current_user_company_id();


        IF v_user_company_id IS DISTINCT FROM p_company_id THEN
            RAISE EXCEPTION
                'No tienes acceso a la configuración fiscal de esta empresa.';
        END IF;

    END IF;


    -- --------------------------------------------------------
    -- APROBADO
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.companies c
        WHERE c.id = p_company_id
          AND c.iva_aprobado_at IS NOT NULL
    ) THEN

        RETURN QUERY
        SELECT
            c.iva_aprobado_aplicado,
            c.iva_aprobado_porcentaje,
            'approved'::TEXT
        FROM public.companies c
        WHERE c.id = p_company_id;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- RECOMENDADO
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.companies c
        WHERE c.id = p_company_id
    ) THEN

        RETURN QUERY
        SELECT
            COALESCE(
                c.iva_recomendado_aplicado,
                TRUE
            ),

            CASE
                WHEN COALESCE(
                    c.iva_recomendado_aplicado,
                    TRUE
                )
                THEN COALESCE(
                    c.iva_recomendado_porcentaje,
                    21
                )
                ELSE 0
            END::NUMERIC(5,2),

            'recommended'::TEXT

        FROM public.companies c
        WHERE c.id = p_company_id;

        RETURN;

    END IF;


    -- --------------------------------------------------------
    -- DEFAULT
    -- --------------------------------------------------------

    RETURN QUERY
    SELECT
        TRUE,
        21::NUMERIC(5,2),
        'default'::TEXT;

END;
$function$;


REVOKE ALL
ON FUNCTION public.get_company_effective_iva(UUID)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.get_company_effective_iva(UUID)
TO authenticated;


ALTER FUNCTION public.get_company_effective_iva(UUID)
SET search_path = public, pg_temp;


-- ============================================================
-- 20. COMENTARIOS — SOLICITUD IVA GENERAL
-- ============================================================

COMMENT ON TABLE public.company_iva_change_requests
IS
'Solicitudes de tratamiento de IVA general realizadas por clientes para su empresa. El sistema es independiente del IVA recomendado por workers y del IVA específico de mantenimiento.';


COMMENT ON COLUMN public.company_iva_change_requests.id
IS
'Identificador único de la solicitud de IVA general.';


COMMENT ON COLUMN public.company_iva_change_requests.company_id
IS
'Empresa para la que se solicita el tratamiento fiscal. Se obtiene de la empresa actual del usuario y no debe ser proporcionada arbitrariamente por el frontend.';


COMMENT ON COLUMN public.company_iva_change_requests.user_id
IS
'Usuario cliente que presentó la solicitud de IVA general.';


COMMENT ON COLUMN public.company_iva_change_requests.requested_iva_aplicado
IS
'Indica si el cliente solicita que se aplique IVA en el tratamiento fiscal general de la empresa.';


COMMENT ON COLUMN public.company_iva_change_requests.requested_iva_porcentaje
IS
'Porcentaje de IVA general solicitado por el cliente. Debe estar entre 0 y 100 cuando el IVA está aplicado y debe ser 0 cuando no está aplicado.';


COMMENT ON COLUMN public.company_iva_change_requests.reason
IS
'Justificación proporcionada por el cliente para solicitar el tratamiento de IVA indicado. Máximo 2.000 caracteres y 16 KiB.';


COMMENT ON COLUMN public.company_iva_change_requests.status
IS
'Estado de la solicitud: pending, in_review, approved, rejected o cancelled.';


COMMENT ON COLUMN public.company_iva_change_requests.reviewed_by
IS
'Usuario de Auth del worker que resolvió la solicitud.';


COMMENT ON COLUMN public.company_iva_change_requests.reviewed_at
IS
'Fecha y hora en que el worker resolvió la solicitud.';


COMMENT ON COLUMN public.company_iva_change_requests.worker_notes
IS
'Notas internas introducidas por el worker al revisar o resolver la solicitud. Máximo 2.000 caracteres y 16 KiB.';


COMMENT ON COLUMN public.company_iva_change_requests.created_at
IS
'Fecha y hora de creación de la solicitud.';


COMMENT ON COLUMN public.company_iva_change_requests.updated_at
IS
'Fecha y hora de la última modificación de la solicitud.';


-- ============================================================
-- ============================================================
-- 21. ENDURECIMIENTO DE maintenance_iva_change_requests
-- ============================================================
-- ============================================================
--
-- ESTA TABLA YA EXISTE DESDE EL SISTEMA DE IVA DE MANTENIMIENTO.
--
-- NO se crea una tabla nueva.
--
-- Solo se endurece la existente.
--
-- ============================================================


DO $$
BEGIN

    IF to_regclass('public.maintenance_iva_change_requests') IS NULL THEN
        RAISE EXCEPTION
            '094 stopped: maintenance_iva_change_requests does not exist';
    END IF;

END;
$$;


-- ============================================================
-- 22. CONSTRAINT — IVA SOLICITADO MANTENIMIENTO
-- ============================================================

ALTER TABLE public.maintenance_iva_change_requests
DROP CONSTRAINT IF EXISTS
maintenance_iva_change_requests_iva_check;


ALTER TABLE public.maintenance_iva_change_requests
ADD CONSTRAINT
maintenance_iva_change_requests_iva_check
CHECK (
    (
        requested_iva_aplicado = TRUE
        AND requested_iva_porcentaje >= 0
        AND requested_iva_porcentaje <= 100
    )
    OR
    (
        requested_iva_aplicado = FALSE
        AND requested_iva_porcentaje = 0
    )
);


-- ============================================================
-- 23. CONSTRAINT — ESTADO MANTENIMIENTO
-- ============================================================

ALTER TABLE public.maintenance_iva_change_requests
DROP CONSTRAINT IF EXISTS
maintenance_iva_change_requests_status_check;


ALTER TABLE public.maintenance_iva_change_requests
ADD CONSTRAINT
maintenance_iva_change_requests_status_check
CHECK (
    status IN (
        'pending',
        'in_review',
        'approved',
        'rejected',
        'cancelled'
    )
);


-- ============================================================
-- 24. LÍMITES DE TEXTO — MANTENIMIENTO
-- ============================================================
--
-- message:
--   máximo 2.000 caracteres
--   máximo 16 KiB
--
-- worker_notes:
--   máximo 2.000 caracteres
--   máximo 16 KiB
--
-- ============================================================

ALTER TABLE public.maintenance_iva_change_requests
DROP CONSTRAINT IF EXISTS
maintenance_iva_change_requests_message_length_check;


ALTER TABLE public.maintenance_iva_change_requests
ADD CONSTRAINT
maintenance_iva_change_requests_message_length_check
CHECK (
    message IS NULL
    OR (
        char_length(message) <= 2000
        AND pg_column_size(message) <= 16384
    )
);


ALTER TABLE public.maintenance_iva_change_requests
DROP CONSTRAINT IF EXISTS
maintenance_iva_change_requests_worker_notes_length_check;


ALTER TABLE public.maintenance_iva_change_requests
ADD CONSTRAINT
maintenance_iva_change_requests_worker_notes_length_check
CHECK (
    worker_notes IS NULL
    OR (
        char_length(worker_notes) <= 2000
        AND pg_column_size(worker_notes) <= 16384
    )
);


-- ============================================================
-- 25. ÍNDICES — MANTENIMIENTO IVA
-- ============================================================

CREATE INDEX IF NOT EXISTS
idx_maintenance_iva_change_requests_company_created
ON public.maintenance_iva_change_requests (
    company_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
idx_maintenance_iva_change_requests_status_created
ON public.maintenance_iva_change_requests (
    status,
    created_at DESC
);


-- ============================================================
-- 26. UNA SOLICITUD ACTIVA DE IVA DE MANTENIMIENTO
-- ============================================================
--
-- Conservamos la regla:
--
--   máximo una pending/in_review por empresa.
--
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
idx_maintenance_iva_change_requests_one_active
ON public.maintenance_iva_change_requests (
    company_id
)
WHERE status IN ('pending', 'in_review');


-- ============================================================
-- 27. UPDATED_AT — MANTENIMIENTO IVA
-- ============================================================

DROP TRIGGER IF EXISTS
maintenance_iva_change_requests_updated_at
ON public.maintenance_iva_change_requests;


CREATE TRIGGER
maintenance_iva_change_requests_updated_at
BEFORE UPDATE
ON public.maintenance_iva_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 28. RATE LIMIT — MANTENIMIENTO IVA
-- ============================================================
--
-- Cliente:
--
--   3 solicitudes / 24 horas
--
-- Worker:
--
--   60 resoluciones / hora
--
-- Se reutiliza security_rate_limits.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.rate_limit_maintenance_iva_change_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_user_id UUID;
    v_is_worker BOOLEAN;

BEGIN

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN NEW;
    END IF;


    v_is_worker :=
        public.current_user_is_worker();


    -- --------------------------------------------------------
    -- CLIENTE CREA SOLICITUD
    -- --------------------------------------------------------

    IF TG_OP = 'INSERT'
       AND NOT v_is_worker
    THEN

        PERFORM public.enforce_security_rate_limit(
            'maintenance_iva_change_request:client:' || v_user_id::TEXT,
            3,
            86400
        );

        RETURN NEW;

    END IF;


    -- --------------------------------------------------------
    -- WORKER RESUELVE SOLICITUD
    -- --------------------------------------------------------

    IF TG_OP = 'UPDATE'
       AND v_is_worker
    THEN

        PERFORM public.enforce_security_rate_limit(
            'maintenance_iva_change_request:worker:' || v_user_id::TEXT,
            60,
            3600
        );

        RETURN NEW;

    END IF;


    RETURN NEW;

END;
$function$;


REVOKE ALL
ON FUNCTION public.rate_limit_maintenance_iva_change_request()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 29. TRIGGER — RATE LIMIT MANTENIMIENTO IVA
-- ============================================================

DROP TRIGGER IF EXISTS
maintenance_iva_change_requests_rate_limit
ON public.maintenance_iva_change_requests;


CREATE TRIGGER
maintenance_iva_change_requests_rate_limit
BEFORE INSERT OR UPDATE
ON public.maintenance_iva_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.rate_limit_maintenance_iva_change_request();


-- ============================================================
-- 30. RLS — MANTENIMIENTO IVA
-- ============================================================

ALTER TABLE public.maintenance_iva_change_requests
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS
maintenance_iva_change_requests_client_select
ON public.maintenance_iva_change_requests;


CREATE POLICY
maintenance_iva_change_requests_client_select
ON public.maintenance_iva_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


DROP POLICY IF EXISTS
maintenance_iva_change_requests_worker_select
ON public.maintenance_iva_change_requests;


CREATE POLICY
maintenance_iva_change_requests_worker_select
ON public.maintenance_iva_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 31. ESCRITURA DIRECTA — MANTENIMIENTO IVA
-- ============================================================

DROP POLICY IF EXISTS
maintenance_iva_change_requests_client_insert
ON public.maintenance_iva_change_requests;


DROP POLICY IF EXISTS
maintenance_iva_change_requests_worker_insert
ON public.maintenance_iva_change_requests;


DROP POLICY IF EXISTS
maintenance_iva_change_requests_client_update
ON public.maintenance_iva_change_requests;


DROP POLICY IF EXISTS
maintenance_iva_change_requests_worker_update
ON public.maintenance_iva_change_requests;


DROP POLICY IF EXISTS
maintenance_iva_change_requests_worker_delete
ON public.maintenance_iva_change_requests;


REVOKE ALL
ON public.maintenance_iva_change_requests
FROM PUBLIC, anon, authenticated;


GRANT SELECT
ON public.maintenance_iva_change_requests
TO authenticated;


-- ============================================================
-- 32. COMENTARIOS — MANTENIMIENTO IVA
-- ============================================================

COMMENT ON TABLE public.maintenance_iva_change_requests
IS
'Solicitudes de cambio del tratamiento de IVA específico de mantenimiento. Este sistema es independiente del IVA general de la empresa, de presupuestos y de facturas normales.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.id
IS
'Identificador único de la solicitud de cambio de IVA de mantenimiento.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.company_id
IS
'Empresa a la que pertenece la solicitud de IVA de mantenimiento.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.user_id
IS
'Usuario cliente que presentó la solicitud de cambio de IVA de mantenimiento.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.maintenance_contract_id
IS
'Contrato de mantenimiento al que se refiere la solicitud cuando existe. Puede ser NULL cuando el cliente solicita el tratamiento de IVA antes de tener un contrato de mantenimiento.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.requested_iva_aplicado
IS
'Indica si el cliente solicita aplicar IVA al tratamiento fiscal del mantenimiento.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.requested_iva_porcentaje
IS
'Porcentaje de IVA de mantenimiento solicitado por el cliente. Debe estar entre 0 y 100 cuando el IVA está aplicado y debe ser 0 cuando no está aplicado.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.message
IS
'Mensaje o justificación aportada por el cliente para solicitar el tratamiento de IVA de mantenimiento. Máximo 2.000 caracteres y 16 KiB.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.status
IS
'Estado de la solicitud de IVA de mantenimiento: pending, in_review, approved, rejected o cancelled.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.reviewed_by
IS
'Usuario de Auth del worker que resolvió la solicitud de IVA de mantenimiento.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.reviewed_at
IS
'Fecha y hora en que el worker resolvió la solicitud de IVA de mantenimiento.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.worker_notes
IS
'Notas internas introducidas por el worker al revisar o resolver la solicitud. Máximo 2.000 caracteres y 16 KiB.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.created_at
IS
'Fecha y hora de creación de la solicitud de IVA de mantenimiento.';


COMMENT ON COLUMN public.maintenance_iva_change_requests.updated_at
IS
'Fecha y hora de la última modificación de la solicitud de IVA de mantenimiento.';


-- ============================================================
-- 33. COMENTARIOS — CAMPOS DE IVA GENERAL EN companies
-- ============================================================

COMMENT ON COLUMN public.companies.iva_recomendado_aplicado
IS
'Indica si el worker recomienda aplicar IVA de forma general a la empresa. Esta recomendación es independiente de cualquier IVA aprobado mediante solicitud del cliente y del IVA de mantenimiento.';


COMMENT ON COLUMN public.companies.iva_recomendado_porcentaje
IS
'Porcentaje de IVA general recomendado por el worker. Se utiliza como valor predeterminado cuando no existe un tratamiento de IVA aprobado por solicitud del cliente.';

-- ============================================================
-- ASEGURAR CONFIGURACIÓN DE IVA RECOMENDADO EN COMPANIES
-- ============================================================

ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS iva_recomendado_aplicado BOOLEAN
        NOT NULL DEFAULT TRUE,

    ADD COLUMN IF NOT EXISTS iva_recomendado_porcentaje NUMERIC(5,2)
        NOT NULL DEFAULT 21,

    ADD COLUMN IF NOT EXISTS iva_recomendado_por UUID,

    ADD COLUMN IF NOT EXISTS iva_recomendado_updated_at TIMESTAMPTZ;


ALTER TABLE public.companies
    DROP CONSTRAINT IF EXISTS companies_iva_recomendado_porcentaje_check;

ALTER TABLE public.companies
    ADD CONSTRAINT companies_iva_recomendado_porcentaje_check
    CHECK (
        (
            iva_recomendado_aplicado = TRUE
            AND iva_recomendado_porcentaje >= 0
            AND iva_recomendado_porcentaje <= 100
        )
        OR
        (
            iva_recomendado_aplicado = FALSE
            AND iva_recomendado_porcentaje = 0
        )
    );


ALTER TABLE public.companies
    DROP CONSTRAINT IF EXISTS companies_iva_recomendado_por_fkey;

ALTER TABLE public.companies
    ADD CONSTRAINT companies_iva_recomendado_por_fkey
    FOREIGN KEY (iva_recomendado_por)
    REFERENCES auth.users(id)
    ON DELETE SET NULL;

COMMENT ON COLUMN public.companies.iva_recomendado_por
IS
'Usuario de Auth del worker que estableció la recomendación de IVA general.';


COMMENT ON COLUMN public.companies.iva_recomendado_updated_at
IS
'Fecha y hora de la última modificación de la recomendación de IVA general del worker.';


-- ============================================================
-- 34. VERIFICACIONES FINALES
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- IVA GENERAL
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'iva_aprobado_aplicado'
    ) THEN
        RAISE EXCEPTION
            '094 failed: iva_aprobado_aplicado missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'iva_aprobado_porcentaje'
    ) THEN
        RAISE EXCEPTION
            '094 failed: iva_aprobado_porcentaje missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'iva_aprobado_por'
    ) THEN
        RAISE EXCEPTION
            '094 failed: iva_aprobado_por missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'iva_aprobado_at'
    ) THEN
        RAISE EXCEPTION
            '094 failed: iva_aprobado_at missing';
    END IF;


    -- --------------------------------------------------------
    -- TABLA IVA GENERAL
    -- --------------------------------------------------------

    IF to_regclass('public.company_iva_change_requests') IS NULL THEN
        RAISE EXCEPTION
            '094 failed: company_iva_change_requests missing';
    END IF;


    -- --------------------------------------------------------
    -- TABLA IVA MANTENIMIENTO
    -- --------------------------------------------------------

    IF to_regclass('public.maintenance_iva_change_requests') IS NULL THEN
        RAISE EXCEPTION
            '094 failed: maintenance_iva_change_requests missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC GENERAL — REQUEST
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'request_company_iva_change'
          AND p.pronargs = 3
    ) THEN
        RAISE EXCEPTION
            '094 failed: request_company_iva_change() missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC GENERAL — RESOLVE
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'resolve_company_iva_change_request'
          AND p.pronargs = 3
    ) THEN
        RAISE EXCEPTION
            '094 failed: resolve_company_iva_change_request() missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC GENERAL — EFFECTIVE IVA
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_company_effective_iva'
          AND p.pronargs = 1
    ) THEN
        RAISE EXCEPTION
            '094 failed: get_company_effective_iva() missing';
    END IF;


    -- --------------------------------------------------------
    -- RATE LIMIT GENERAL
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'rate_limit_company_iva_change_request'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '094 failed: company IVA rate-limit function missing';
    END IF;


    -- --------------------------------------------------------
    -- RATE LIMIT MANTENIMIENTO
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'rate_limit_maintenance_iva_change_request'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '094 failed: maintenance IVA rate-limit function missing';
    END IF;


    -- --------------------------------------------------------
    -- TRIGGER GENERAL
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid =
              'public.company_iva_change_requests'::regclass
          AND tgname =
              'company_iva_change_requests_rate_limit'
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION
            '094 failed: company IVA rate-limit trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- TRIGGER MANTENIMIENTO
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid =
              'public.maintenance_iva_change_requests'::regclass
          AND tgname =
              'maintenance_iva_change_requests_rate_limit'
          AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION
            '094 failed: maintenance IVA rate-limit trigger missing';
    END IF;


END;
$$;



COMMIT;


