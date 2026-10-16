BEGIN;

-- ============================================================
-- MODIRA — 093_company_iva_recommendation_and_maintenance_iva.sql
-- ============================================================
--
-- OBJETIVO
--
-- 1. Permitir que un worker establezca un IVA recomendado
--    para cada empresa.
--
-- 2. Si una empresa no tiene IVA recomendado:
--       → mantenimiento = 21 %
--
-- 3. Mostrar posteriormente ese IVA como recomendación
--    informativa en presupuestos y facturas.
--
-- 4. Guardar el IVA fiscal del contrato de mantenimiento como
--    snapshot, evitando que cambios posteriores en la empresa
--    alteren contratos históricos.
--
-- 5. Permitir al cliente solicitar un cambio de IVA para
--    mantenimiento mediante una solicitud con mensaje.
--
-- 6. Permitir a workers revisar y resolver esas solicitudes.
--
-- 7. Permitir a workers modificar el IVA de contratos de
--    mantenimiento, incluidos contratos personalizados.
--
-- IMPORTANTE:
-- Esta migración NO modifica Stripe.
-- La sincronización con Stripe se realizará posteriormente
-- desde maintenance-stripe.
--
-- ============================================================


-- ============================================================
-- 1. IVA RECOMENDADO POR EMPRESA
-- ============================================================

ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS iva_recomendado_aplicado BOOLEAN
        NOT NULL DEFAULT TRUE;

ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS iva_recomendado_porcentaje NUMERIC(5,2)
        NOT NULL DEFAULT 21;

ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS iva_recomendado_updated_by UUID;

ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS iva_recomendado_updated_at TIMESTAMPTZ;


-- ============================================================
-- 2. VALIDACIÓN DEL IVA RECOMENDADO
-- ============================================================

ALTER TABLE public.companies
    DROP CONSTRAINT IF EXISTS companies_iva_recomendado_porcentaje_check;

ALTER TABLE public.companies
    ADD CONSTRAINT companies_iva_recomendado_porcentaje_check
    CHECK (
        iva_recomendado_porcentaje >= 0
        AND iva_recomendado_porcentaje <= 100
    );


-- ============================================================
-- 3. FK DEL WORKER QUE ESTABLECIÓ EL IVA
-- ============================================================

ALTER TABLE public.companies
    DROP CONSTRAINT IF EXISTS companies_iva_recomendado_updated_by_fkey;

ALTER TABLE public.companies
    ADD CONSTRAINT companies_iva_recomendado_updated_by_fkey
    FOREIGN KEY (iva_recomendado_updated_by)
    REFERENCES auth.users(id)
    ON DELETE SET NULL;


-- ============================================================
-- 4. NORMALIZACIÓN DE DATOS EXISTENTES
-- ============================================================
--
-- Las empresas existentes parten de 21 %.
--
-- Esto NO significa que el worker haya configurado manualmente
-- el 21 %. Es simplemente el valor predeterminado del sistema.
--
-- Por eso updated_by permanece NULL.
--

UPDATE public.companies
SET
    iva_recomendado_aplicado = TRUE,
    iva_recomendado_porcentaje = 21
WHERE
    iva_recomendado_porcentaje IS NULL
    OR iva_recomendado_porcentaje < 0
    OR iva_recomendado_porcentaje > 100;


-- ============================================================
-- 5. IVA EN MAINTENANCE_CONTRACTS
-- ============================================================
--
-- El contrato conserva su propio snapshot fiscal.
--
-- Si la empresa cambia posteriormente su IVA recomendado,
-- NO se modifica automáticamente un contrato existente.
--

ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS iva_aplicado BOOLEAN
        NOT NULL DEFAULT TRUE;

ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS iva_porcentaje NUMERIC(5,2)
        NOT NULL DEFAULT 21;

ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS iva_source TEXT
        NOT NULL DEFAULT 'company_default';

ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS iva_configured_by UUID;

ALTER TABLE public.maintenance_contracts
    ADD COLUMN IF NOT EXISTS iva_configured_at TIMESTAMPTZ;


-- ============================================================
-- 6. VALIDACIONES DEL IVA DEL CONTRATO
-- ============================================================

ALTER TABLE public.maintenance_contracts
    DROP CONSTRAINT IF EXISTS maintenance_contracts_iva_porcentaje_check;

ALTER TABLE public.maintenance_contracts
    ADD CONSTRAINT maintenance_contracts_iva_porcentaje_check
    CHECK (
        iva_porcentaje >= 0
        AND iva_porcentaje <= 100
    );


ALTER TABLE public.maintenance_contracts
    DROP CONSTRAINT IF EXISTS maintenance_contracts_iva_source_check;

ALTER TABLE public.maintenance_contracts
    ADD CONSTRAINT maintenance_contracts_iva_source_check
    CHECK (
        iva_source IN (
            'company_default',
            'worker',
            'client_request'
        )
    );


ALTER TABLE public.maintenance_contracts
    DROP CONSTRAINT IF EXISTS maintenance_contracts_iva_configured_by_fkey;

ALTER TABLE public.maintenance_contracts
    ADD CONSTRAINT maintenance_contracts_iva_configured_by_fkey
    FOREIGN KEY (iva_configured_by)
    REFERENCES auth.users(id)
    ON DELETE SET NULL;


-- ============================================================
-- 7. TABLA DE SOLICITUDES DE CAMBIO DE IVA
-- ============================================================
--
-- Permite que un cliente diga:
--
-- "El IVA propuesto no corresponde a mi empresa.
--  Necesito que se revise porque ..."
--
-- La solicitud puede existir antes de que exista el contrato,
-- por eso maintenance_contract_id es NULLABLE.
--

CREATE TABLE IF NOT EXISTS public.maintenance_iva_change_requests (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    company_id UUID NOT NULL,

    user_id UUID NOT NULL,

    maintenance_contract_id UUID NULL,

    requested_iva_aplicado BOOLEAN NOT NULL DEFAULT TRUE,

    requested_iva_porcentaje NUMERIC(5,2) NOT NULL,

    message TEXT NOT NULL,

    status TEXT NOT NULL DEFAULT 'pending',

    reviewed_by UUID NULL,

    reviewed_at TIMESTAMPTZ NULL,

    worker_notes TEXT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,


    CONSTRAINT maintenance_iva_request_percentage_check
    CHECK (
        requested_iva_porcentaje >= 0
        AND requested_iva_porcentaje <= 100
    ),


    CONSTRAINT maintenance_iva_request_status_check
    CHECK (
        status IN (
            'pending',
            'in_review',
            'approved',
            'rejected',
            'cancelled'
        )
    ),


    CONSTRAINT maintenance_iva_request_message_check
    CHECK (
        LENGTH(BTRIM(message)) BETWEEN 1 AND 2000
    ),


    CONSTRAINT maintenance_iva_request_company_fkey
    FOREIGN KEY (company_id)
    REFERENCES public.companies(id)
    ON DELETE RESTRICT,


    CONSTRAINT maintenance_iva_request_user_fkey
    FOREIGN KEY (user_id)
    REFERENCES auth.users(id)
    ON DELETE RESTRICT,


    CONSTRAINT maintenance_iva_request_contract_fkey
    FOREIGN KEY (maintenance_contract_id)
    REFERENCES public.maintenance_contracts(id)
    ON DELETE SET NULL,


    CONSTRAINT maintenance_iva_request_reviewer_fkey
    FOREIGN KEY (reviewed_by)
    REFERENCES auth.users(id)
    ON DELETE SET NULL

);


-- ============================================================
-- 8. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_maintenance_iva_requests_company
ON public.maintenance_iva_change_requests (
    company_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_iva_requests_status
ON public.maintenance_iva_change_requests (
    status,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_iva_requests_user
ON public.maintenance_iva_change_requests (
    user_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_iva_requests_contract
ON public.maintenance_iva_change_requests (
    maintenance_contract_id
)
WHERE maintenance_contract_id IS NOT NULL;


-- ============================================================
-- 9. SOLO UNA SOLICITUD PENDIENTE POR EMPRESA
-- ============================================================
--
-- Evita que un cliente pueda generar 20 solicitudes idénticas.
--

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_maintenance_iva_one_pending_per_company
ON public.maintenance_iva_change_requests (
    company_id
)
WHERE status IN (
    'pending',
    'in_review'
);


-- ============================================================
-- 10. UPDATED_AT
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
-- 11. RLS — SOLICITUDES IVA
-- ============================================================

ALTER TABLE public.maintenance_iva_change_requests
ENABLE ROW LEVEL SECURITY;


-- ------------------------------------------------------------
-- CLIENTE — SELECT
-- ------------------------------------------------------------

DROP POLICY IF EXISTS
    maintenance_iva_requests_client_select
ON public.maintenance_iva_change_requests;


CREATE POLICY
    maintenance_iva_requests_client_select
ON public.maintenance_iva_change_requests
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
    maintenance_iva_requests_worker_select
ON public.maintenance_iva_change_requests;


CREATE POLICY
    maintenance_iva_requests_worker_select
ON public.maintenance_iva_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ------------------------------------------------------------
-- NO escritura directa
-- ------------------------------------------------------------

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_iva_change_requests
FROM authenticated, anon;


GRANT SELECT
ON public.maintenance_iva_change_requests
TO authenticated;


-- ============================================================
-- 12. RPC — WORKER ESTABLECE IVA RECOMENDADO DE EMPRESA
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_company_iva_recommendation(
    p_company_id UUID,
    p_iva_aplicado BOOLEAN,
    p_iva_porcentaje NUMERIC
)
RETURNS public.companies
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_company public.companies;

BEGIN

    -- --------------------------------------------------------
    -- WORKER
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR PORCENTAJE
    -- --------------------------------------------------------

    IF p_iva_porcentaje IS NULL
       OR p_iva_porcentaje < 0
       OR p_iva_porcentaje > 100
    THEN
        RAISE EXCEPTION
            'El porcentaje de IVA debe estar entre 0 y 100';
    END IF;


    -- --------------------------------------------------------
    -- EMPRESA
    -- --------------------------------------------------------

    SELECT *
    INTO v_company
    FROM public.companies
    WHERE id = p_company_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La empresa no existe';
    END IF;


    -- --------------------------------------------------------
    -- ACTUALIZAR
    -- --------------------------------------------------------

    UPDATE public.companies
    SET
        iva_recomendado_aplicado = COALESCE(p_iva_aplicado, TRUE),
        iva_recomendado_porcentaje =
            ROUND(p_iva_porcentaje, 2),
        iva_recomendado_updated_by =
            auth.uid(),
        iva_recomendado_updated_at =
            CURRENT_TIMESTAMP,
        updated_at =
            CURRENT_TIMESTAMP
    WHERE id = p_company_id
    RETURNING *
    INTO v_company;


    RETURN v_company;

END;
$function$;


REVOKE EXECUTE
ON FUNCTION public.set_company_iva_recommendation(UUID, BOOLEAN, NUMERIC)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.set_company_iva_recommendation(UUID, BOOLEAN, NUMERIC)
TO authenticated;


-- ============================================================
-- 13. RPC — CLIENTE SOLICITA CAMBIO DE IVA
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_maintenance_iva_change(
    p_requested_iva_aplicado BOOLEAN,
    p_requested_iva_porcentaje NUMERIC,
    p_message TEXT,
    p_maintenance_contract_id UUID DEFAULT NULL
)
RETURNS public.maintenance_iva_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_company_id UUID;
    v_request public.maintenance_iva_change_requests;
    v_contract public.maintenance_contracts;
BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'La cuenta no está activa';
    END IF;


    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Los trabajadores no pueden crear solicitudes de cliente';
    END IF;


    -- --------------------------------------------------------
    -- EMPRESA
    -- --------------------------------------------------------

    v_company_id :=
        public.current_user_company_id();


    IF v_company_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario no tiene una empresa asociada';
    END IF;


    -- --------------------------------------------------------
    -- IVA
    -- --------------------------------------------------------

    IF p_requested_iva_porcentaje IS NULL
       OR p_requested_iva_porcentaje < 0
       OR p_requested_iva_porcentaje > 100
    THEN
        RAISE EXCEPTION
            'El porcentaje de IVA solicitado debe estar entre 0 y 100';
    END IF;


    IF p_message IS NULL
       OR LENGTH(BTRIM(p_message)) = 0
    THEN
        RAISE EXCEPTION
            'Debes indicar el motivo de la solicitud';
    END IF;


    IF LENGTH(BTRIM(p_message)) > 2000 THEN
        RAISE EXCEPTION
            'El mensaje no puede superar 2000 caracteres';
    END IF;


    -- --------------------------------------------------------
    -- CONTRATO OPCIONAL
    -- --------------------------------------------------------

    IF p_maintenance_contract_id IS NOT NULL THEN

        SELECT *
        INTO v_contract
        FROM public.maintenance_contracts
        WHERE id = p_maintenance_contract_id
          AND company_id = v_company_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'El contrato de mantenimiento no pertenece a tu empresa';
        END IF;

    END IF;


    -- --------------------------------------------------------
    -- EVITAR DUPLICADOS
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.maintenance_iva_change_requests
        WHERE company_id = v_company_id
          AND status IN ('pending', 'in_review')
    ) THEN
        RAISE EXCEPTION
            'Ya existe una solicitud de cambio de IVA pendiente para esta empresa';
    END IF;


    -- --------------------------------------------------------
    -- CREAR SOLICITUD
    -- --------------------------------------------------------

    INSERT INTO public.maintenance_iva_change_requests (
        company_id,
        user_id,
        maintenance_contract_id,
        requested_iva_aplicado,
        requested_iva_porcentaje,
        message,
        status
    )
    VALUES (
        v_company_id,
        auth.uid(),
        p_maintenance_contract_id,
        COALESCE(p_requested_iva_aplicado, TRUE),
        ROUND(p_requested_iva_porcentaje, 2),
        BTRIM(p_message),
        'pending'
    )
    RETURNING *
    INTO v_request;


    RETURN v_request;

END;
$function$;


REVOKE EXECUTE
ON FUNCTION public.request_maintenance_iva_change(
    BOOLEAN,
    NUMERIC,
    TEXT,
    UUID
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.request_maintenance_iva_change(
    BOOLEAN,
    NUMERIC,
    TEXT,
    UUID
)
TO authenticated;


-- ============================================================
-- 14. RPC — WORKER RESUELVE SOLICITUD DE IVA
-- ============================================================
--
-- Acciones:
--
--   in_review
--   approved
--   rejected
--
-- Si se aprueba:
--
--   1. se registra el worker;
--   2. se registra la fecha;
--   3. se guarda la nota;
--   4. se actualiza el IVA recomendado de la empresa;
--   5. si existe contrato, se actualiza también su IVA.
--
-- Esto permite que una solicitud aprobada por un worker pueda
-- convertirse realmente en la nueva configuración fiscal.
--

CREATE OR REPLACE FUNCTION public.resolve_maintenance_iva_change_request(
    p_request_id UUID,
    p_action TEXT,
    p_worker_notes TEXT DEFAULT NULL
)
RETURNS public.maintenance_iva_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_request public.maintenance_iva_change_requests;
    v_action TEXT;
BEGIN

    -- --------------------------------------------------------
    -- WORKER
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    v_action :=
        LOWER(BTRIM(COALESCE(p_action, '')));


    IF v_action NOT IN (
        'in_review',
        'approved',
        'rejected'
    ) THEN
        RAISE EXCEPTION
            'Acción no válida';
    END IF;


    -- --------------------------------------------------------
    -- BLOQUEAR SOLICITUD
    -- --------------------------------------------------------

    SELECT *
    INTO v_request
    FROM public.maintenance_iva_change_requests
    WHERE id = p_request_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Solicitud de cambio de IVA no encontrada';
    END IF;


    IF v_request.status IN (
        'approved',
        'rejected',
        'cancelled'
    ) THEN
        RAISE EXCEPTION
            'La solicitud ya está cerrada';
    END IF;


    -- --------------------------------------------------------
    -- EN REVISIÓN
    -- --------------------------------------------------------

    IF v_action = 'in_review' THEN

        UPDATE public.maintenance_iva_change_requests
        SET
            status = 'in_review',
            reviewed_by = auth.uid(),
            reviewed_at = CURRENT_TIMESTAMP,
            worker_notes = NULLIF(BTRIM(p_worker_notes), ''),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_request_id
        RETURNING *
        INTO v_request;

        RETURN v_request;

    END IF;


    -- --------------------------------------------------------
    -- RECHAZADA
    -- --------------------------------------------------------

    IF v_action = 'rejected' THEN

        UPDATE public.maintenance_iva_change_requests
        SET
            status = 'rejected',
            reviewed_by = auth.uid(),
            reviewed_at = CURRENT_TIMESTAMP,
            worker_notes = NULLIF(BTRIM(p_worker_notes), ''),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_request_id
        RETURNING *
        INTO v_request;

        RETURN v_request;

    END IF;


    -- --------------------------------------------------------
    -- APROBADA
    -- --------------------------------------------------------

    IF v_action = 'approved' THEN

        -- ----------------------------------------------------
        -- 1. ACTUALIZAR RECOMENDACIÓN DE EMPRESA
        -- ----------------------------------------------------

        UPDATE public.companies
        SET
            iva_recomendado_aplicado =
                v_request.requested_iva_aplicado,

            iva_recomendado_porcentaje =
                v_request.requested_iva_porcentaje,

            iva_recomendado_updated_by =
                auth.uid(),

            iva_recomendado_updated_at =
                CURRENT_TIMESTAMP,

            updated_at =
                CURRENT_TIMESTAMP

        WHERE id = v_request.company_id;


        -- ----------------------------------------------------
        -- 2. SI HAY CONTRATO, ACTUALIZAR SU IVA
        -- ----------------------------------------------------

        IF v_request.maintenance_contract_id IS NOT NULL THEN

            UPDATE public.maintenance_contracts
            SET
                iva_aplicado =
                    v_request.requested_iva_aplicado,

                iva_porcentaje =
                    v_request.requested_iva_porcentaje,

                iva_source =
                    'client_request',

                iva_configured_by =
                    auth.uid(),

                iva_configured_at =
                    CURRENT_TIMESTAMP,

                updated_at =
                    CURRENT_TIMESTAMP

            WHERE id =
                v_request.maintenance_contract_id
              AND company_id =
                v_request.company_id;

        END IF;


        -- ----------------------------------------------------
        -- 3. CERRAR SOLICITUD
        -- ----------------------------------------------------

        UPDATE public.maintenance_iva_change_requests
        SET
            status = 'approved',
            reviewed_by = auth.uid(),
            reviewed_at = CURRENT_TIMESTAMP,
            worker_notes = NULLIF(BTRIM(p_worker_notes), ''),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_request_id
        RETURNING *
        INTO v_request;


        RETURN v_request;

    END IF;


    RAISE EXCEPTION
        'No se pudo resolver la solicitud';

END;
$function$;


REVOKE EXECUTE
ON FUNCTION public.resolve_maintenance_iva_change_request(
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.resolve_maintenance_iva_change_request(
    UUID,
    TEXT,
    TEXT
)
TO authenticated;


-- ============================================================
-- 15. RPC — WORKER MODIFICA IVA DE CONTRATO
-- ============================================================
--
-- Sirve tanto para:
--
--   - Essential
--   - Growth
--   - Business
--   - Custom
--
-- No cambia el precio comercial del contrato.
-- Solo cambia su tratamiento fiscal.
--

CREATE OR REPLACE FUNCTION public.update_maintenance_contract_iva(
    p_contract_id UUID,
    p_iva_aplicado BOOLEAN,
    p_iva_porcentaje NUMERIC
)
RETURNS public.maintenance_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_contract public.maintenance_contracts;
BEGIN

    -- --------------------------------------------------------
    -- WORKER
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- --------------------------------------------------------
    -- IVA
    -- --------------------------------------------------------

    IF p_iva_porcentaje IS NULL
       OR p_iva_porcentaje < 0
       OR p_iva_porcentaje > 100
    THEN
        RAISE EXCEPTION
            'El porcentaje de IVA debe estar entre 0 y 100';
    END IF;


    -- --------------------------------------------------------
    -- BLOQUEAR CONTRATO
    -- --------------------------------------------------------

    SELECT *
    INTO v_contract
    FROM public.maintenance_contracts
    WHERE id = p_contract_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Contrato de mantenimiento no encontrado';
    END IF;


    -- --------------------------------------------------------
    -- ACTUALIZAR
    -- --------------------------------------------------------

    UPDATE public.maintenance_contracts
    SET
        iva_aplicado =
            COALESCE(p_iva_aplicado, TRUE),

        iva_porcentaje =
            ROUND(p_iva_porcentaje, 2),

        iva_source =
            'worker',

        iva_configured_by =
            auth.uid(),

        iva_configured_at =
            CURRENT_TIMESTAMP,

        updated_at =
            CURRENT_TIMESTAMP

    WHERE id = p_contract_id
    RETURNING *
    INTO v_contract;


    RETURN v_contract;

END;
$function$;


REVOKE EXECUTE
ON FUNCTION public.update_maintenance_contract_iva(
    UUID,
    BOOLEAN,
    NUMERIC
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.update_maintenance_contract_iva(
    UUID,
    BOOLEAN,
    NUMERIC
)
TO authenticated;


-- ============================================================
-- 16. FUNCIÓN AUXILIAR — OBTENER IVA RECOMENDADO
-- ============================================================
--
-- Facilita que frontend/backend puedan obtener de forma
-- consistente la recomendación de una empresa.
--
-- Si la empresa no tiene una configuración explícita:
--       21 %
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_company_recommended_iva(
    p_company_id UUID
)
RETURNS TABLE (
    iva_aplicado BOOLEAN,
    iva_porcentaje NUMERIC,
    configured_by UUID,
    configured_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

    SELECT
        COALESCE(c.iva_recomendado_aplicado, TRUE),
        COALESCE(c.iva_recomendado_porcentaje, 21),
        c.iva_recomendado_updated_by,
        c.iva_recomendado_updated_at
    FROM public.companies c
    WHERE c.id = p_company_id;

$function$;


REVOKE EXECUTE
ON FUNCTION public.get_company_recommended_iva(UUID)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.get_company_recommended_iva(UUID)
TO authenticated;


-- ============================================================
-- 17. COMENTARIOS
-- ============================================================

COMMENT ON COLUMN public.companies.iva_recomendado_aplicado IS
'Indica si existe IVA recomendado para la empresa. Se utiliza como recomendación fiscal informativa y como valor inicial para mantenimiento.';

COMMENT ON COLUMN public.companies.iva_recomendado_porcentaje IS
'Porcentaje de IVA recomendado para la empresa. Por defecto 21 %. No sustituye la selección manual del IVA en presupuestos o facturas.';

COMMENT ON COLUMN public.companies.iva_recomendado_updated_by IS
'Worker que estableció o modificó el IVA recomendado de la empresa.';

COMMENT ON COLUMN public.maintenance_contracts.iva_aplicado IS
'IVA aplicado al contrato de mantenimiento. Se conserva como snapshot contractual.';

COMMENT ON COLUMN public.maintenance_contracts.iva_porcentaje IS
'Porcentaje de IVA del contrato de mantenimiento. No se recalcula automáticamente cuando cambia la recomendación de la empresa.';

COMMENT ON COLUMN public.maintenance_contracts.iva_source IS
'Origen del IVA del contrato: company_default, worker o client_request.';

COMMENT ON TABLE public.maintenance_iva_change_requests IS
'Solicitudes de clientes para revisar el tratamiento de IVA de un mantenimiento.';


-- ============================================================
-- 18. VALIDACIONES FINALES
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'iva_recomendado_porcentaje'
    ) THEN
        RAISE EXCEPTION
            '093 failed: companies.iva_recomendado_porcentaje missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_contracts'
          AND column_name = 'iva_porcentaje'
    ) THEN
        RAISE EXCEPTION
            '093 failed: maintenance_contracts.iva_porcentaje missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_iva_change_requests'
    ) THEN
        RAISE EXCEPTION
            '093 failed: maintenance_iva_change_requests missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'set_company_iva_recommendation'
    ) THEN
        RAISE EXCEPTION
            '093 failed: set_company_iva_recommendation() missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'request_maintenance_iva_change'
    ) THEN
        RAISE EXCEPTION
            '093 failed: request_maintenance_iva_change() missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'resolve_maintenance_iva_change_request'
    ) THEN
        RAISE EXCEPTION
            '093 failed: resolve_maintenance_iva_change_request() missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'update_maintenance_contract_iva'
    ) THEN
        RAISE EXCEPTION
            '093 failed: update_maintenance_contract_iva() missing';
    END IF;

END $$;


COMMIT;