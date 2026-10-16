BEGIN;

-- ============================================================
-- MODIRA — 069_custom_maintenance_proposals.sql
-- ============================================================
--
-- OBJETIVO
--
-- Crear el sistema de propuestas personalizadas de Modira Care.
--
-- Flujo:
--
-- CLIENTE
--   ↓
-- propuesta personalizada
--   ↓
-- MODIRA
--   ↓
-- revisión / cotización
--   ↓
-- precio mensual
--   ↓
-- CLIENTE ACEPTA
--   ↓
-- backend / Stripe
--   ↓
-- maintenance_contracts
--
-- IMPORTANTE:
--
-- Stripe NO se ejecuta desde SQL.
-- Esta migración prepara toda la persistencia e integridad.
-- La creación de Price/Subscription de Stripe se realizará
-- posteriormente desde la Edge Function.
-- ============================================================


-- ============================================================
-- 1. TABLA DE PROPUESTAS PERSONALIZADAS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.maintenance_custom_proposals (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- --------------------------------------------------------
    -- IDENTIDAD
    -- --------------------------------------------------------

    user_id UUID NOT NULL
        REFERENCES auth.users(id)
        ON DELETE RESTRICT,

    company_id UUID NOT NULL
        REFERENCES public.companies(id)
        ON DELETE RESTRICT,

    plan_id UUID NOT NULL
        REFERENCES public.maintenance_plans(id)
        ON DELETE RESTRICT,

    -- --------------------------------------------------------
    -- ESTADO
    -- --------------------------------------------------------

    status TEXT NOT NULL DEFAULT 'draft',

    -- --------------------------------------------------------
    -- INFORMACIÓN SOLICITADA POR EL CLIENTE
    -- --------------------------------------------------------

    titulo TEXT NOT NULL,

    descripcion_necesidad TEXT,

    objetivos TEXT,

    prioridades TEXT,

    soluciones_actuales TEXT,

    proyectos_relacionados TEXT,

    automatizaciones_actuales TEXT,

    integraciones_actuales TEXT,

    tecnologias TEXT,

    sistemas_criticos TEXT,

    alcance_tecnico_solicitado TEXT,

    horas_mensuales_solicitadas NUMERIC(8,2),

    tipo_trabajo TEXT,

    nivel_soporte_solicitado TEXT,

    tiempo_respuesta_deseado TEXT,

    horario_soporte TEXT,

    soporte_fuera_horario BOOLEAN NOT NULL DEFAULT FALSE,

    sla_solicitado TEXT,

    nivel_criticidad TEXT,

    impacto_incidencia TEXT,

    necesidad_monitorizacion BOOLEAN NOT NULL DEFAULT FALSE,

    requisitos_seguridad TEXT,

    informacion_adicional TEXT,

    -- --------------------------------------------------------
    -- INFORMACIÓN FLEXIBLE
    -- --------------------------------------------------------
    --
    -- Permite añadir posteriormente nuevos campos al formulario
    -- sin modificar la estructura principal de la tabla.
    --

    request_data JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- --------------------------------------------------------
    -- RESPUESTA / COTIZACIÓN DE MODIRA
    -- --------------------------------------------------------

    quoted_monthly_price NUMERIC(12,2),

    quoted_currency TEXT NOT NULL DEFAULT 'EUR',

    quoted_hours_monthly NUMERIC(8,2),

    quoted_scope_level TEXT,

    quoted_service_level TEXT,

    quoted_sla TEXT,

    quoted_response_time TEXT,

    quoted_support_hours TEXT,

    quoted_description TEXT,

    quoted_terms TEXT,

    quoted_valid_until DATE,

    -- --------------------------------------------------------
    -- SNAPSHOT DE LA PROPUESTA COTIZADA
    -- --------------------------------------------------------

    quote_snapshot JSONB,

    -- --------------------------------------------------------
    -- ACEPTACIÓN
    -- --------------------------------------------------------

    accepted_at TIMESTAMPTZ,

    accepted_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    -- --------------------------------------------------------
    -- RECHAZO
    -- --------------------------------------------------------

    rejected_at TIMESTAMPTZ,

    rejected_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    rejection_reason TEXT,

    -- --------------------------------------------------------
    -- CONTRATO GENERADO
    -- --------------------------------------------------------

    maintenance_contract_id UUID
        REFERENCES public.maintenance_contracts(id)
        ON DELETE SET NULL,

    -- --------------------------------------------------------
    -- STRIPE
    -- --------------------------------------------------------
    --
    -- Estos campos se rellenarán cuando la Edge Function cree
    -- el precio/suscripción personalizada.
    --

    stripe_product_id TEXT,

    stripe_price_id TEXT,

    stripe_customer_id TEXT,

    stripe_subscription_id TEXT,

    stripe_subscription_item_id TEXT,

    -- --------------------------------------------------------
    -- TIMESTAMPS
    -- --------------------------------------------------------

    submitted_at TIMESTAMPTZ,

    reviewed_at TIMESTAMPTZ,

    quoted_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,


    -- ========================================================
    -- CONSTRAINTS
    -- ========================================================

    CONSTRAINT maintenance_custom_proposals_status_check
    CHECK (
        status IN (
            'draft',
            'submitted',
            'in_review',
            'quoted',
            'accepted',
            'rejected',
            'cancelled',
            'expired'
        )
    ),

    CONSTRAINT maintenance_custom_proposals_price_check
    CHECK (
        quoted_monthly_price IS NULL
        OR quoted_monthly_price >= 0
    ),

    CONSTRAINT maintenance_custom_proposals_currency_check
    CHECK (
        quoted_currency ~ '^[A-Z]{3}$'
    ),

    CONSTRAINT maintenance_custom_proposals_hours_check
    CHECK (
        horas_mensuales_solicitadas IS NULL
        OR horas_mensuales_solicitadas > 0
    ),

    CONSTRAINT maintenance_custom_proposals_quoted_hours_check
    CHECK (
        quoted_hours_monthly IS NULL
        OR quoted_hours_monthly > 0
    ),

    CONSTRAINT maintenance_custom_proposals_request_data_object_check
    CHECK (
        jsonb_typeof(request_data) = 'object'
    ),

    CONSTRAINT maintenance_custom_proposals_quote_snapshot_object_check
    CHECK (
        quote_snapshot IS NULL
        OR jsonb_typeof(quote_snapshot) = 'object'
    )
);


-- ============================================================
-- 2. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_user
ON public.maintenance_custom_proposals (
    user_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_company
ON public.maintenance_custom_proposals (
    company_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_status
ON public.maintenance_custom_proposals (
    status,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_contract
ON public.maintenance_custom_proposals (
    maintenance_contract_id
)
WHERE maintenance_contract_id IS NOT NULL;


CREATE UNIQUE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_stripe_subscription
ON public.maintenance_custom_proposals (
    stripe_subscription_id
)
WHERE stripe_subscription_id IS NOT NULL;


-- ============================================================
-- 3. UNA SOLA PROPUESTA ABIERTA POR EMPRESA
-- ============================================================
--
-- No impedimos conservar histórico.
--
-- Sí impedimos que una misma empresa tenga simultáneamente
-- varias propuestas activas que puedan convertirse en contrato.
--

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_one_open_per_company
ON public.maintenance_custom_proposals (
    company_id
)
WHERE status IN (
    'draft',
    'submitted',
    'in_review',
    'quoted'
);


-- ============================================================
-- 4. updated_at
-- ============================================================

DROP TRIGGER IF EXISTS
    maintenance_custom_proposals_updated_at
ON public.maintenance_custom_proposals;


CREATE TRIGGER
    maintenance_custom_proposals_updated_at
BEFORE UPDATE
ON public.maintenance_custom_proposals
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 5. RLS
-- ============================================================

ALTER TABLE public.maintenance_custom_proposals
ENABLE ROW LEVEL SECURITY;


-- ------------------------------------------------------------
-- CLIENTE — SELECT
-- ------------------------------------------------------------

DROP POLICY IF EXISTS
    maintenance_custom_proposals_client_select
ON public.maintenance_custom_proposals;


CREATE POLICY
    maintenance_custom_proposals_client_select
ON public.maintenance_custom_proposals
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
    AND company_id = public.current_user_company_id()
);


-- ------------------------------------------------------------
-- WORKER — SELECT
-- ------------------------------------------------------------

DROP POLICY IF EXISTS
    maintenance_custom_proposals_worker_select
ON public.maintenance_custom_proposals;


CREATE POLICY
    maintenance_custom_proposals_worker_select
ON public.maintenance_custom_proposals
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ------------------------------------------------------------
-- No escritura directa
-- ------------------------------------------------------------

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_custom_proposals
FROM authenticated, anon;


GRANT SELECT
ON public.maintenance_custom_proposals
TO authenticated;


-- ============================================================
-- 6. RPC — CLIENTE CREA PROPUESTA
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_custom_maintenance_proposal(
    p_titulo TEXT,
    p_descripcion_necesidad TEXT DEFAULT NULL,
    p_objetivos TEXT DEFAULT NULL,
    p_prioridades TEXT DEFAULT NULL,
    p_soluciones_actuales TEXT DEFAULT NULL,
    p_proyectos_relacionados TEXT DEFAULT NULL,
    p_automatizaciones_actuales TEXT DEFAULT NULL,
    p_integraciones_actuales TEXT DEFAULT NULL,
    p_tecnologias TEXT DEFAULT NULL,
    p_sistemas_criticos TEXT DEFAULT NULL,
    p_alcance_tecnico_solicitado TEXT DEFAULT NULL,
    p_horas_mensuales_solicitadas NUMERIC DEFAULT NULL,
    p_tipo_trabajo TEXT DEFAULT NULL,
    p_nivel_soporte_solicitado TEXT DEFAULT NULL,
    p_tiempo_respuesta_deseado TEXT DEFAULT NULL,
    p_horario_soporte TEXT DEFAULT NULL,
    p_soporte_fuera_horario BOOLEAN DEFAULT FALSE,
    p_sla_solicitado TEXT DEFAULT NULL,
    p_nivel_criticidad TEXT DEFAULT NULL,
    p_impacto_incidencia TEXT DEFAULT NULL,
    p_necesidad_monitorizacion BOOLEAN DEFAULT FALSE,
    p_requisitos_seguridad TEXT DEFAULT NULL,
    p_informacion_adicional TEXT DEFAULT NULL,
    p_request_data JSONB DEFAULT '{}'::jsonb
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_user_id UUID;
    v_company_id UUID;
    v_plan_id UUID;
    v_proposal public.maintenance_custom_proposals;

BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión para crear una propuesta';
    END IF;


    -- --------------------------------------------------------
    -- SOLO CLIENTES
    -- --------------------------------------------------------

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Los trabajadores no utilizan esta vía para crear propuestas de cliente';
    END IF;


    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'El usuario no está activo';
    END IF;


    -- --------------------------------------------------------
    -- EMPRESA
    -- --------------------------------------------------------

    v_company_id := public.current_user_company_id();

    IF v_company_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario no pertenece a ninguna empresa';
    END IF;


    -- --------------------------------------------------------
    -- PLAN CUSTOM
    -- --------------------------------------------------------

    SELECT id
    INTO v_plan_id
    FROM public.maintenance_plans
    WHERE code = 'custom'
      AND es_personalizado = TRUE
      AND activo = TRUE
    LIMIT 1;


    IF v_plan_id IS NULL THEN
        RAISE EXCEPTION
            'El plan personalizado no está disponible';
    END IF;


    -- --------------------------------------------------------
    -- EVITAR VARIAS PROPUESTAS ABIERTAS
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposals
        WHERE company_id = v_company_id
          AND status IN (
              'draft',
              'submitted',
              'in_review',
              'quoted'
          )
    ) THEN
        RAISE EXCEPTION
            'Ya existe una propuesta personalizada abierta para esta empresa';
    END IF;


    -- --------------------------------------------------------
    -- VALIDACIONES
    -- --------------------------------------------------------

    IF NULLIF(BTRIM(p_titulo), '') IS NULL THEN
        RAISE EXCEPTION
            'El título de la propuesta es obligatorio';
    END IF;


    IF LENGTH(BTRIM(p_titulo)) > 300 THEN
        RAISE EXCEPTION
            'El título no puede superar 300 caracteres';
    END IF;


    IF p_horas_mensuales_solicitadas IS NOT NULL
       AND p_horas_mensuales_solicitadas <= 0
    THEN
        RAISE EXCEPTION
            'Las horas mensuales solicitadas deben ser mayores que 0';
    END IF;


    IF p_request_data IS NULL
       OR jsonb_typeof(p_request_data) <> 'object'
    THEN
        RAISE EXCEPTION
            'request_data debe ser un objeto JSON';
    END IF;


    -- --------------------------------------------------------
    -- CREACIÓN
    -- --------------------------------------------------------

    INSERT INTO public.maintenance_custom_proposals (
        user_id,
        company_id,
        plan_id,
        status,
        titulo,
        descripcion_necesidad,
        objetivos,
        prioridades,
        soluciones_actuales,
        proyectos_relacionados,
        automatizaciones_actuales,
        integraciones_actuales,
        tecnologias,
        sistemas_criticos,
        alcance_tecnico_solicitado,
        horas_mensuales_solicitadas,
        tipo_trabajo,
        nivel_soporte_solicitado,
        tiempo_respuesta_deseado,
        horario_soporte,
        soporte_fuera_horario,
        sla_solicitado,
        nivel_criticidad,
        impacto_incidencia,
        necesidad_monitorizacion,
        requisitos_seguridad,
        informacion_adicional,
        request_data
    )
    VALUES (
        v_user_id,
        v_company_id,
        v_plan_id,
        'draft',
        BTRIM(p_titulo),
        NULLIF(BTRIM(p_descripcion_necesidad), ''),
        NULLIF(BTRIM(p_objetivos), ''),
        NULLIF(BTRIM(p_prioridades), ''),
        NULLIF(BTRIM(p_soluciones_actuales), ''),
        NULLIF(BTRIM(p_proyectos_relacionados), ''),
        NULLIF(BTRIM(p_automatizaciones_actuales), ''),
        NULLIF(BTRIM(p_integraciones_actuales), ''),
        NULLIF(BTRIM(p_tecnologias), ''),
        NULLIF(BTRIM(p_sistemas_criticos), ''),
        NULLIF(BTRIM(p_alcance_tecnico_solicitado), ''),
        p_horas_mensuales_solicitadas,
        NULLIF(BTRIM(p_tipo_trabajo), ''),
        NULLIF(BTRIM(p_nivel_soporte_solicitado), ''),
        NULLIF(BTRIM(p_tiempo_respuesta_deseado), ''),
        NULLIF(BTRIM(p_horario_soporte), ''),
        COALESCE(p_soporte_fuera_horario, FALSE),
        NULLIF(BTRIM(p_sla_solicitado), ''),
        NULLIF(BTRIM(p_nivel_criticidad), ''),
        NULLIF(BTRIM(p_impacto_incidencia), ''),
        COALESCE(p_necesidad_monitorizacion, FALSE),
        NULLIF(BTRIM(p_requisitos_seguridad), ''),
        NULLIF(BTRIM(p_informacion_adicional), ''),
        p_request_data
    )
    RETURNING *
    INTO v_proposal;


    RETURN v_proposal;

END;
$function$;


REVOKE ALL
ON FUNCTION public.create_custom_maintenance_proposal(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    NUMERIC,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN,
    TEXT,
    TEXT,
    JSONB
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.create_custom_maintenance_proposal(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    NUMERIC,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN,
    TEXT,
    TEXT,
    TEXT,
    BOOLEAN,
    TEXT,
    TEXT,
    JSONB
)
TO authenticated;


-- ============================================================
-- 7. RPC — CLIENTE ENVÍA PROPUESTA
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_custom_maintenance_proposal(
    p_proposal_id UUID
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Debes iniciar sesión';
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


    IF v_proposal.status <> 'draft' THEN
        RAISE EXCEPTION
            'La propuesta no se encuentra en estado borrador';
    END IF;


    UPDATE public.maintenance_custom_proposals
    SET
        status = 'submitted',
        submitted_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_proposal.id
    RETURNING *
    INTO v_proposal;


    RETURN v_proposal;

END;
$function$;


REVOKE ALL
ON FUNCTION public.submit_custom_maintenance_proposal(UUID)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.submit_custom_maintenance_proposal(UUID)
TO authenticated;


-- ============================================================
-- 8. RPC — WORKER RESPONDE A PROPUESTA
-- ============================================================

CREATE OR REPLACE FUNCTION public.respond_to_custom_maintenance_proposal(
    p_proposal_id UUID,
    p_status TEXT,
    p_quoted_monthly_price NUMERIC DEFAULT NULL,
    p_quoted_hours_monthly NUMERIC DEFAULT NULL,
    p_quoted_scope_level TEXT DEFAULT NULL,
    p_quoted_service_level TEXT DEFAULT NULL,
    p_quoted_sla TEXT DEFAULT NULL,
    p_quoted_response_time TEXT DEFAULT NULL,
    p_quoted_support_hours TEXT DEFAULT NULL,
    p_quoted_description TEXT DEFAULT NULL,
    p_quoted_terms TEXT DEFAULT NULL,
    p_quoted_valid_until DATE DEFAULT NULL
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_proposal public.maintenance_custom_proposals;
    v_status TEXT;

BEGIN

    IF auth.uid() IS NULL
       OR NOT public.current_user_is_worker()
    THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    v_status := LOWER(BTRIM(COALESCE(p_status, '')));


    IF v_status NOT IN ('in_review', 'quoted', 'rejected') THEN
        RAISE EXCEPTION
            'Estado de respuesta no válido';
    END IF;


    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Propuesta no encontrada';
    END IF;


    IF v_status = 'quoted' THEN

        IF p_quoted_monthly_price IS NULL
           OR p_quoted_monthly_price <= 0
        THEN
            RAISE EXCEPTION
                'El precio mensual propuesto debe ser mayor que 0';
        END IF;

        IF p_quoted_valid_until IS NULL THEN
            RAISE EXCEPTION
                'La propuesta cotizada debe tener fecha de validez';
        END IF;

    END IF;


    UPDATE public.maintenance_custom_proposals
    SET
        status = v_status,

        quoted_monthly_price =
            CASE
                WHEN v_status = 'quoted'
                THEN ROUND(p_quoted_monthly_price, 2)
                ELSE quoted_monthly_price
            END,

        quoted_hours_monthly =
            CASE
                WHEN v_status = 'quoted'
                THEN p_quoted_hours_monthly
                ELSE quoted_hours_monthly
            END,

        quoted_scope_level =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(BTRIM(p_quoted_scope_level), '')
                ELSE quoted_scope_level
            END,

        quoted_service_level =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(BTRIM(p_quoted_service_level), '')
                ELSE quoted_service_level
            END,

        quoted_sla =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(BTRIM(p_quoted_sla), '')
                ELSE quoted_sla
            END,

        quoted_response_time =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(BTRIM(p_quoted_response_time), '')
                ELSE quoted_response_time
            END,

        quoted_support_hours =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(BTRIM(p_quoted_support_hours), '')
                ELSE quoted_support_hours
            END,

        quoted_description =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(BTRIM(p_quoted_description), '')
                ELSE quoted_description
            END,

        quoted_terms =
            CASE
                WHEN v_status = 'quoted'
                THEN NULLIF(BTRIM(p_quoted_terms), '')
                ELSE quoted_terms
            END,

        quoted_valid_until =
            CASE
                WHEN v_status = 'quoted'
                THEN p_quoted_valid_until
                ELSE quoted_valid_until
            END,

        quote_snapshot =
            CASE
                WHEN v_status = 'quoted'
                THEN jsonb_build_object(
                    'monthly_price',
                        ROUND(p_quoted_monthly_price, 2),
                    'currency',
                        quoted_currency,
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
                    'captured_at',
                        CURRENT_TIMESTAMP
                )
                ELSE quote_snapshot
            END,

        reviewed_at =
            CASE
                WHEN reviewed_at IS NULL
                THEN CURRENT_TIMESTAMP
                ELSE reviewed_at
            END,

        quoted_at =
            CASE
                WHEN v_status = 'quoted'
                THEN CURRENT_TIMESTAMP
                ELSE quoted_at
            END,

        updated_at = CURRENT_TIMESTAMP

    WHERE id = v_proposal.id

    RETURNING *
    INTO v_proposal;


    RETURN v_proposal;

END;
$function$;


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
FROM PUBLIC, anon;


GRANT EXECUTE
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
TO authenticated;


-- ============================================================
-- 9. RPC — CLIENTE ACEPTA LA PROPUESTA
-- ============================================================

CREATE OR REPLACE FUNCTION public.accept_custom_maintenance_proposal(
    p_proposal_id UUID
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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


-- ============================================================
-- 10. RELACIÓN PROPUESTA → CONTRATO
-- ============================================================

ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS maintenance_custom_proposal_id UUID;


ALTER TABLE public.maintenance_contracts
    DROP CONSTRAINT IF EXISTS
        maintenance_contracts_custom_proposal_id_fkey;


ALTER TABLE public.maintenance_contracts
    ADD CONSTRAINT
        maintenance_contracts_custom_proposal_id_fkey
    FOREIGN KEY (maintenance_custom_proposal_id)
    REFERENCES public.maintenance_custom_proposals(id)
    ON DELETE RESTRICT;


CREATE UNIQUE INDEX IF NOT EXISTS
    idx_maintenance_contracts_custom_proposal
ON public.maintenance_contracts (
    maintenance_custom_proposal_id
)
WHERE maintenance_custom_proposal_id IS NOT NULL;


-- ============================================================
-- 11. PRECIO CONTRATADO REAL
-- ============================================================
--
-- maintenance_contracts.precio ya existe.
--
-- Añadimos una columna explícita para conservar el precio
-- acordado procedente de una propuesta personalizada.
--
-- NO sustituye precio.
-- precio continúa siendo el snapshot comercial utilizado
-- por el contrato.
--

ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS agreed_monthly_price NUMERIC(12,2);


ALTER TABLE public.maintenance_contracts
    DROP CONSTRAINT IF EXISTS
        maintenance_contracts_agreed_monthly_price_check;


ALTER TABLE public.maintenance_contracts
    ADD CONSTRAINT
        maintenance_contracts_agreed_monthly_price_check
    CHECK (
        agreed_monthly_price IS NULL
        OR agreed_monthly_price > 0
    );


-- ============================================================
-- 12. DATOS DEL ALCANCE PERSONALIZADO EN EL CONTRATO
-- ============================================================

ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS scope_snapshot JSONB;


ALTER TABLE public.maintenance_contracts
    DROP CONSTRAINT IF EXISTS
        maintenance_contracts_scope_snapshot_check;


ALTER TABLE public.maintenance_contracts
    ADD CONSTRAINT
        maintenance_contracts_scope_snapshot_check
    CHECK (
        scope_snapshot IS NULL
        OR jsonb_typeof(scope_snapshot) = 'object'
    );


-- ============================================================
-- 13. VALIDACIÓN DE CONTRATO CUSTOM
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_custom_maintenance_contract()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_plan public.maintenance_plans;
    v_proposal public.maintenance_custom_proposals;

BEGIN

    SELECT *
    INTO v_plan
    FROM public.maintenance_plans
    WHERE id = NEW.plan_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El plan de mantenimiento no existe';
    END IF;


    IF v_plan.es_personalizado = TRUE THEN

        IF NEW.agreed_monthly_price IS NULL
           OR NEW.agreed_monthly_price <= 0
        THEN
            RAISE EXCEPTION
                'Un contrato personalizado debe tener un precio mensual acordado';
        END IF;


        IF NEW.maintenance_custom_proposal_id IS NULL THEN
            RAISE EXCEPTION
                'Un contrato personalizado debe estar vinculado a una propuesta';
        END IF;


        SELECT *
        INTO v_proposal
        FROM public.maintenance_custom_proposals
        WHERE id = NEW.maintenance_custom_proposal_id;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'La propuesta personalizada no existe';
        END IF;


        IF v_proposal.status <> 'accepted' THEN
            RAISE EXCEPTION
                'La propuesta personalizada todavía no ha sido aceptada';
        END IF;


        IF v_proposal.company_id IS DISTINCT FROM NEW.company_id THEN
            RAISE EXCEPTION
                'La propuesta no pertenece a la empresa del contrato';
        END IF;


        IF v_proposal.user_id IS DISTINCT FROM NEW.user_id THEN
            RAISE EXCEPTION
                'La propuesta no pertenece al usuario del contrato';
        END IF;


        IF v_proposal.quoted_monthly_price IS DISTINCT FROM NEW.agreed_monthly_price THEN
            RAISE EXCEPTION
                'El precio del contrato no coincide con el precio aceptado de la propuesta';
        END IF;

    END IF;


    RETURN NEW;

END;
$function$;


DROP TRIGGER IF EXISTS
    maintenance_contracts_validate_custom
ON public.maintenance_contracts;


CREATE TRIGGER
    maintenance_contracts_validate_custom
BEFORE INSERT OR UPDATE
ON public.maintenance_contracts
FOR EACH ROW
EXECUTE FUNCTION public.validate_custom_maintenance_contract();


-- ============================================================
-- 14. GARANTIZAR QUE SOLO CUSTOM USE PROPUESTAS CUSTOM
-- ============================================================

ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_plan_custom_check;


ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_plan_custom_check
    CHECK (
        plan_id IS NOT NULL
    );


-- ============================================================
-- 15. VALIDACIÓN FINAL
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM public.maintenance_plans
        WHERE code = 'custom'
          AND es_personalizado = TRUE
    ) THEN
        RAISE EXCEPTION
            '069 failed: el plan custom no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_custom_proposals'
    ) THEN
        RAISE EXCEPTION
            '069 failed: maintenance_custom_proposals no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_contracts'
          AND column_name = 'maintenance_custom_proposal_id'
    ) THEN
        RAISE EXCEPTION
            '069 failed: maintenance_contracts.maintenance_custom_proposal_id missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_contracts'
          AND column_name = 'agreed_monthly_price'
    ) THEN
        RAISE EXCEPTION
            '069 failed: maintenance_contracts.agreed_monthly_price missing';
    END IF;

END $$;


COMMIT;