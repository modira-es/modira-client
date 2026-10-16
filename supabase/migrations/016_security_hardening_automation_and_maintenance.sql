BEGIN;

-- ============================================================
-- MODIRA — 016_auth_account_status_and_session_revocation.sql
--
-- H-05 — BLOQUEO EFECTIVO DE CUENTAS Y REVOCACIÓN DE SESIONES
--
-- OBJETIVO
--
-- 1. Crear una única fuente de verdad para el estado de cuenta:
--
--      public.profiles.status
--
--      active
--      blocked
--
-- 2. Impedir que un usuario autenticado pueda modificar su
--    propio estado.
--
-- 3. Hacer que una cuenta bloqueada pierda inmediatamente el
--    acceso a las operaciones protegidas por RLS.
--
-- 4. Hacer que current_user_company_id(), current_user_is_admin()
--    y current_user_is_worker() respeten el estado de la cuenta.
--
-- 5. Mantener la regla arquitectónica:
--
--      WORKER = trabajador interno de MODIRA
--
--    Los workers NO pertenecen a las empresas cliente.
--
-- 6. Proporcionar una RPC exclusiva para workers activos de
--    MODIRA para bloquear/desbloquear cuentas.
--
-- 7. Al bloquear una cuenta, eliminar sus sesiones de Supabase
--    para impedir la renovación mediante refresh tokens.
--
-- 8. Impedir que una cuenta bloqueada pueda consultar sus
--    facturas, crear checkout o utilizar recursos protegidos
--    mediante las políticas RLS.
--
-- 9. No modificar las migraciones anteriores.
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
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
            '016 stopped: public.profiles does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    ) THEN
        RAISE EXCEPTION
            '016 stopped: public.workers does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'companies'
    ) THEN
        RAISE EXCEPTION
            '016 stopped: public.companies does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_company_id'
    ) THEN
        RAISE EXCEPTION
            '016 stopped: current_user_company_id() does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
    ) THEN
        RAISE EXCEPTION
            '016 stopped: current_user_is_worker() does not exist';
    END IF;

END $$;


-- ============================================================
-- 2. ESTADO DE CUENTA
-- ============================================================
--
-- 001 no tenía profiles.status.
--
-- H-05 exige una fuente de verdad explícita para poder bloquear
-- una cuenta independientemente de lo que muestre el frontend.
--
-- ============================================================

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS status TEXT
NOT NULL
DEFAULT 'active';


-- ============================================================
-- 3. CONSTRAINT DEL ESTADO
-- ============================================================

ALTER TABLE public.profiles
DROP CONSTRAINT IF EXISTS profiles_status_check;

ALTER TABLE public.profiles
ADD CONSTRAINT profiles_status_check
CHECK (
    status IN (
        'active',
        'blocked'
    )
);


-- ============================================================
-- 4. ÍNDICE
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_profiles_status
ON public.profiles (
    status
);


-- ============================================================
-- 5. FUNCIÓN: CURRENT USER IS ACTIVE
-- ============================================================
--
-- Esta función se convierte en la comprobación transversal
-- del estado de la cuenta.
--
-- IMPORTANTE:
--
-- SECURITY DEFINER:
-- evita depender de la propia RLS de profiles.
--
-- Un usuario solo está activo si:
--
--   auth.uid() existe
--       +
--   profile existe
--       +
--   status = active
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_user_is_active()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE p.id = auth.uid()
          AND p.status = 'active'
    );
$$;


-- ============================================================
-- 6. FUNCIÓN: CURRENT USER IS BLOCKED
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_user_is_blocked()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE p.id = auth.uid()
          AND p.status = 'blocked'
    );
$$;


-- ============================================================
-- 7. CORREGIR CURRENT_USER_COMPANY_ID()
-- ============================================================
--
-- Un usuario bloqueado NO debe conservar una empresa operativa
-- desde el punto de vista de las policies.
--
-- Por tanto:
--
-- active  -> company_id
-- blocked -> NULL
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_user_company_id()
RETURNS UUID
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p.company_id
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.status = 'active'
    LIMIT 1;
$$;


-- ============================================================
-- 8. CORREGIR CURRENT_USER_IS_ADMIN()
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_user_is_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE p.id = auth.uid()
          AND p.rol = 'admin'
          AND p.status = 'active'
    );
$$;


-- ============================================================
-- 9. CORREGIR CURRENT_USER_IS_WORKER()
-- ============================================================
--
-- Un worker:
--
--   1. Debe existir en workers.
--   2. Debe estar activo.
--   3. Su profile, si existe, debe estar activo.
--
-- El worker sigue siendo exclusivamente interno de MODIRA.
--
-- NO se utiliza company_id para determinar si es worker.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_user_is_worker()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.workers w
        JOIN public.profiles p
            ON p.id = w.auth_user_id
        WHERE w.auth_user_id = auth.uid()
          AND w.is_active = TRUE
          AND p.status = 'active'
    );
$$;


-- ============================================================
-- 10. CORREGIR CURRENT_USER_IS_WORKER_ACCOUNT()
-- ============================================================
--
-- Esta función continúa permitiendo distinguir una cuenta
-- worker activa/inactiva para el frontend.
--
-- No se utiliza para autorizar operaciones sensibles.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_user_is_worker_account()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.workers w
        WHERE w.auth_user_id = auth.uid()
    );
$$;


-- ============================================================
-- 11. PERMISOS DE LAS FUNCIONES
-- ============================================================

REVOKE ALL
ON FUNCTION public.current_user_is_active()
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.current_user_is_blocked()
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.current_user_company_id()
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.current_user_is_admin()
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.current_user_is_worker()
FROM PUBLIC, anon;

REVOKE ALL
ON FUNCTION public.current_user_is_worker_account()
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.current_user_is_active()
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.current_user_is_blocked()
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.current_user_company_id()
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.current_user_is_admin()
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.current_user_is_worker()
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.current_user_is_worker_account()
TO authenticated;


-- ============================================================
-- 12. PROTEGER STATUS CONTRA EL CLIENTE
-- ============================================================
--
-- El cliente NO puede:
--
--   status = active
--   status = blocked
--
-- desde un UPDATE directo.
--
-- El cambio se realizará mediante RPC autorizada.
--
-- ============================================================

REVOKE UPDATE (
    status
)
ON public.profiles
FROM authenticated;


-- ============================================================
-- 13. FUNCIÓN PARA REVOCAR SESIONES
-- ============================================================
--
-- Al bloquear una cuenta eliminamos sus sesiones Auth.
--
-- Esto evita que los refresh tokens asociados continúen
-- renovando sesiones.
--
-- El JWT de acceso ya emitido no puede ser borrado porque es
-- stateless; por eso H-05 se completa conjuntamente con las
-- comprobaciones RLS de current_user_is_active().
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.revoke_user_sessions(
    p_user_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
BEGIN

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION
            'Usuario obligatorio';
    END IF;


    DELETE FROM auth.sessions
    WHERE user_id = p_user_id;

END;
$$;


REVOKE ALL
ON FUNCTION public.revoke_user_sessions(UUID)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 14. RPC — CAMBIAR ESTADO DE CUENTA
-- ============================================================
--
-- SOLO WORKERS ACTIVOS DE MODIRA.
--
-- p_status:
--
--   active
--   blocked
--
-- Al bloquear:
--
--   1. cambia profiles.status
--   2. revoca las sesiones Auth
--
-- Al desbloquear:
--
--   1. cambia profiles.status
--   2. NO crea ninguna sesión automáticamente
--
-- El usuario deberá autenticarse nuevamente.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_profile_status(
    p_user_id UUID,
    p_status TEXT
)
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    v_profile public.profiles;
BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- SOLO WORKERS ACTIVOS DE MODIRA
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo de MODIRA';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR USER ID
    -- --------------------------------------------------------

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario objetivo es obligatorio';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR ESTADO
    -- --------------------------------------------------------

    IF p_status NOT IN (
        'active',
        'blocked'
    ) THEN
        RAISE EXCEPTION
            'Estado de cuenta no válido';
    END IF;


    -- --------------------------------------------------------
    -- NO PERMITIR QUE UN WORKER BLOQUEE SU PROPIA CUENTA
    -- MEDIANTE ESTA RPC.
    --
    -- La gestión administrativa de workers continúa separada
    -- mediante workers.is_active.
    -- --------------------------------------------------------

    IF p_user_id = auth.uid() THEN
        RAISE EXCEPTION
            'Un trabajador no puede modificar el estado de su propia cuenta';
    END IF;


    -- --------------------------------------------------------
    -- ACTUALIZAR PERFIL
    -- --------------------------------------------------------

    UPDATE public.profiles
    SET
        status = p_status,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_user_id
    RETURNING *
    INTO v_profile;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El perfil indicado no existe';
    END IF;


    -- --------------------------------------------------------
    -- BLOQUEO → REVOCAR SESIONES
    -- --------------------------------------------------------

    IF p_status = 'blocked' THEN

        PERFORM public.revoke_user_sessions(
            p_user_id
        );

    END IF;


    RETURN v_profile;

END;
$$;


REVOKE ALL
ON FUNCTION public.set_profile_status(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.set_profile_status(UUID, TEXT)
TO authenticated;

-- ============================================================
-- 15. SOLICITUD Y GESTIÓN DE ELIMINACIÓN DE CUENTA
-- ============================================================
--
-- CLIENTE:
--
--   Puede solicitar la eliminación de su propia cuenta.
--
-- WORKER:
--
--   Puede aprobar o rechazar la solicitud.
--
-- ESTADOS:
--
--   pending   = solicitud pendiente de revisión
--   approved  = aprobada por un worker
--   rejected  = rechazada por un worker
--   blocked   = aprobada pero bloqueada por reglas de negocio
--   completed = eliminación completada
--   failed    = error técnico durante la eliminación
--
-- IMPORTANTE:
--
-- Esta migración NO concede DELETE sobre auth.users.
--
-- La eliminación física de la cuenta de Auth se realizará
-- posteriormente desde una Edge Function/backend utilizando
-- privilegios administrativos.
--
-- ============================================================


-- ============================================================
-- 15.1 TABLA DE SOLICITUDES
-- ============================================================

CREATE TABLE IF NOT EXISTS public.account_deletion_requests (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    user_id UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    status TEXT NOT NULL DEFAULT 'pending',

    requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    reviewed_at TIMESTAMPTZ,

    reviewed_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    rejection_reason TEXT,

    CONSTRAINT account_deletion_requests_status_check
    CHECK (
        status IN (
            'pending',
            'approved',
            'rejected',
            'blocked',
            'completed',
            'failed'
        )
    ),

    CONSTRAINT account_deletion_requests_rejection_reason_check
    CHECK (
        rejection_reason IS NULL
        OR LENGTH(TRIM(rejection_reason)) <= 1000
    )
);


-- ============================================================
-- 15.2 ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_account_deletion_requests_user_id
ON public.account_deletion_requests (
    user_id
);


CREATE INDEX IF NOT EXISTS
    idx_account_deletion_requests_status
ON public.account_deletion_requests (
    status
);


CREATE INDEX IF NOT EXISTS
    idx_account_deletion_requests_requested_at
ON public.account_deletion_requests (
    requested_at DESC
);


-- ============================================================
-- 15.3 UNA SOLICITUD PENDING POR CLIENTE
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_account_deletion_requests_one_pending_per_user
ON public.account_deletion_requests (
    user_id
)
WHERE status = 'pending'
  AND user_id IS NOT NULL;


-- ============================================================
-- 15.4 RLS
-- ============================================================

ALTER TABLE public.account_deletion_requests
ENABLE ROW LEVEL SECURITY;


-- ------------------------------------------------------------
-- El cliente NO tiene INSERT / UPDATE / DELETE directo.
-- ------------------------------------------------------------

REVOKE INSERT, UPDATE, DELETE
ON public.account_deletion_requests
FROM anon, authenticated;


-- ------------------------------------------------------------
-- Cliente:
-- únicamente puede consultar sus propias solicitudes.
-- ------------------------------------------------------------

DROP POLICY IF EXISTS
    account_deletion_requests_client_select
ON public.account_deletion_requests;


CREATE POLICY
    account_deletion_requests_client_select
ON public.account_deletion_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
);


-- ------------------------------------------------------------
-- Worker:
-- puede consultar solicitudes de eliminación.
-- ------------------------------------------------------------

DROP POLICY IF EXISTS
    account_deletion_requests_worker_select
ON public.account_deletion_requests;


CREATE POLICY
    account_deletion_requests_worker_select
ON public.account_deletion_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


GRANT SELECT
ON public.account_deletion_requests
TO authenticated;


-- ============================================================
-- 15.5 RPC — CLIENTE SOLICITA ELIMINACIÓN
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_account_deletion()
RETURNS public.account_deletion_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_request public.account_deletion_requests;
BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- CUENTA ACTIVA
    -- --------------------------------------------------------

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'La cuenta no está activa';
    END IF;


    -- --------------------------------------------------------
    -- SOLO CLIENTES
    -- --------------------------------------------------------

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Los trabajadores no pueden solicitar la eliminación mediante esta función';
    END IF;


    -- --------------------------------------------------------
    -- EL PERFIL DEBE EXISTIR
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE id = auth.uid()
    ) THEN
        RAISE EXCEPTION
            'Perfil de usuario no encontrado';
    END IF;


    -- --------------------------------------------------------
    -- NO PERMITIR SOLICITUD DUPLICADA
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.account_deletion_requests
        WHERE user_id = auth.uid()
          AND status = 'pending'
    ) THEN
        RAISE EXCEPTION
            'Ya existe una solicitud de eliminación pendiente';
    END IF;


    -- --------------------------------------------------------
    -- CREAR SOLICITUD
    -- --------------------------------------------------------

    INSERT INTO public.account_deletion_requests (
        user_id,
        status
    )
    VALUES (
        auth.uid(),
        'pending'
    )
    RETURNING *
    INTO v_request;


    RETURN v_request;

END;
$$;


REVOKE ALL
ON FUNCTION public.request_account_deletion()
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.request_account_deletion()
TO authenticated;


-- ============================================================
-- 15.6 RPC — WORKER APRUEBA / RECHAZA
-- ============================================================

CREATE OR REPLACE FUNCTION public.resolve_account_deletion(
    p_request_id UUID,
    p_decision TEXT,
    p_rejection_reason TEXT DEFAULT NULL
)
RETURNS public.account_deletion_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_request public.account_deletion_requests;
    v_target_profile public.profiles;
BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- SOLO WORKER ACTIVO DE MODIRA
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo de MODIRA';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR REQUEST
    -- --------------------------------------------------------

    IF p_request_id IS NULL THEN
        RAISE EXCEPTION
            'La solicitud es obligatoria';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR DECISIÓN
    -- --------------------------------------------------------

    IF p_decision NOT IN (
        'approved',
        'rejected'
    ) THEN
        RAISE EXCEPTION
            'Decisión no válida';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR MOTIVO DE RECHAZO
    -- --------------------------------------------------------

    IF p_decision = 'rejected'
       AND p_rejection_reason IS NOT NULL
       AND LENGTH(TRIM(p_rejection_reason)) > 1000
    THEN
        RAISE EXCEPTION
            'El motivo de rechazo no puede superar los 1000 caracteres';
    END IF;


    -- --------------------------------------------------------
    -- OBTENER SOLICITUD Y BLOQUEARLA
    -- --------------------------------------------------------

    SELECT *
    INTO v_request
    FROM public.account_deletion_requests
    WHERE id = p_request_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Solicitud de eliminación no encontrada';
    END IF;


    -- --------------------------------------------------------
    -- SOLO SE PUEDE RESOLVER UNA SOLICITUD PENDING
    -- --------------------------------------------------------

    IF v_request.status <> 'pending' THEN
        RAISE EXCEPTION
            'La solicitud ya ha sido resuelta';
    END IF;


    -- --------------------------------------------------------
    -- EL USUARIO DEBE SEGUIR ASOCIADO
    -- --------------------------------------------------------

    IF v_request.user_id IS NULL THEN
        RAISE EXCEPTION
            'La solicitud no tiene un usuario asociado';
    END IF;


    -- --------------------------------------------------------
    -- OBTENER PERFIL
    -- --------------------------------------------------------

    SELECT *
    INTO v_target_profile
    FROM public.profiles
    WHERE id = v_request.user_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Perfil del usuario solicitado no encontrado';
    END IF;


    -- --------------------------------------------------------
    -- SOLO CUENTAS DE CLIENTE
    -- --------------------------------------------------------

    IF v_target_profile.rol <> 'user' THEN
        RAISE EXCEPTION
            'La solicitud no corresponde a una cuenta de cliente';
    END IF;


    -- Protección adicional frente a cuentas worker.
    IF EXISTS (
        SELECT 1
        FROM public.workers
        WHERE auth_user_id = v_request.user_id
    ) THEN
        RAISE EXCEPTION
            'No se puede eliminar una cuenta de trabajador mediante esta solicitud';
    END IF;


    -- ========================================================
    -- RECHAZAR
    -- ========================================================

    IF p_decision = 'rejected' THEN

        UPDATE public.account_deletion_requests
        SET
            status = 'rejected',
            reviewed_at = CURRENT_TIMESTAMP,
            reviewed_by = auth.uid(),
            rejection_reason =
                NULLIF(BTRIM(p_rejection_reason), '')
        WHERE id = p_request_id
        RETURNING *
        INTO v_request;


        RETURN v_request;

    END IF;


    -- ========================================================
    -- APROBAR
    -- ========================================================
    --
    -- IMPORTANTE:
    --
    -- Aquí NO se elimina auth.users.
    --
    -- La Edge Function será responsable de realizar las
    -- comprobaciones definitivas y ejecutar el borrado real.
    --
    -- ========================================================

    UPDATE public.account_deletion_requests
    SET
        status = 'approved',
        reviewed_at = CURRENT_TIMESTAMP,
        reviewed_by = auth.uid(),
        rejection_reason = NULL
    WHERE id = p_request_id
    RETURNING *
    INTO v_request;


    RETURN v_request;

END;
$$;


REVOKE ALL
ON FUNCTION public.resolve_account_deletion(
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.resolve_account_deletion(
    UUID,
    TEXT,
    TEXT
)
TO authenticated;


-- ============================================================
-- 15.7 DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.account_deletion_requests
IS
'Solicitudes de eliminación de cuentas de clientes. El cliente solicita la eliminación y un trabajador activo de MODIRA puede aprobarla o rechazarla.';


COMMENT ON COLUMN public.account_deletion_requests.status
IS
'pending=pendiente; approved=aprobada por worker; rejected=rechazada por worker; blocked=bloqueada por reglas de negocio; completed=eliminación completada; failed=fallo técnico durante el proceso.';


COMMENT ON FUNCTION public.request_account_deletion()
IS
'Permite a un cliente activo solicitar la eliminación de su propia cuenta.';


COMMENT ON FUNCTION public.resolve_account_deletion(UUID, TEXT, TEXT)
IS
'Permite a un trabajador activo de MODIRA aprobar o rechazar una solicitud de eliminación. La aprobación permite al backend iniciar el proceso definitivo de eliminación.';


-- ============================================================
-- 15.8 VALIDACIONES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- TABLA
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'account_deletion_requests'
    ) THEN
        RAISE EXCEPTION
            '016 failed: account_deletion_requests table missing';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'public.account_deletion_requests'::regclass
          AND relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '016 failed: account_deletion_requests RLS missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC CLIENTE
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.request_account_deletion()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '016 failed: request_account_deletion() missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC WORKER
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.resolve_account_deletion(uuid,text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '016 failed: resolve_account_deletion(uuid,text,text) missing';
    END IF;


    -- --------------------------------------------------------
    -- POLICIES
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'account_deletion_requests'
      AND policyname IN (
          'account_deletion_requests_client_select',
          'account_deletion_requests_worker_select'
      );


    IF v_count <> 2 THEN
        RAISE EXCEPTION
            '016 failed: account deletion policies incomplete';
    END IF;


    -- --------------------------------------------------------
    -- CONSTRAINT DE ESTADOS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_constraint
    WHERE conrelid =
        'public.account_deletion_requests'::regclass
      AND conname =
        'account_deletion_requests_status_check';


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '016 failed: account deletion status constraint missing';
    END IF;

END $$;
-- ============================================================
-- 15. PROTEGER PROFILES CONTRA AUTO-DESBLOQUEO
-- ============================================================
--
-- Sustituimos las policies de perfil para que:
--
-- CLIENTE:
--   solo pueda consultar/modificar su perfil si está activo.
--
-- WORKER:
--   pueda consultar perfiles si es worker activo.
--
-- status NO puede modificarse directamente.
--
-- ============================================================

DROP POLICY IF EXISTS profiles_select_own
ON public.profiles;

DROP POLICY IF EXISTS profiles_update_own
ON public.profiles;

DROP POLICY IF EXISTS profiles_worker_select
ON public.profiles;

DROP POLICY IF EXISTS profiles_worker_update
ON public.profiles;


CREATE POLICY profiles_select_own
ON public.profiles
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = auth.uid()
);


CREATE POLICY profiles_update_own
ON public.profiles
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = auth.uid()
)
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = auth.uid()
);


CREATE POLICY profiles_worker_select
ON public.profiles
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


CREATE POLICY profiles_worker_update
ON public.profiles
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
)
WITH CHECK (
    public.current_user_is_worker()
);


-- ============================================================
-- 16. AUTOMATIONS
-- ============================================================
--
-- Una cuenta bloqueada no puede:
--
--   SELECT
--   INSERT
--   UPDATE
--
-- ============================================================

DROP POLICY IF EXISTS automations_client_select
ON public.automations;

DROP POLICY IF EXISTS automations_client_insert
ON public.automations;

DROP POLICY IF EXISTS automations_client_update
ON public.automations;

DROP POLICY IF EXISTS automations_worker_select
ON public.automations;


CREATE POLICY automations_client_select
ON public.automations
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


CREATE POLICY automations_client_insert
ON public.automations
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
    AND company_id = public.current_user_company_id()
);


CREATE POLICY automations_client_update
ON public.automations
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
)
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
    AND user_id = auth.uid()
);


CREATE POLICY automations_worker_select
ON public.automations
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 17. AUTOMATION RUNS
-- ============================================================
--
-- Cliente activo:
--   solo sus ejecuciones.
--
-- Worker activo MODIRA:
--   todas.
--
-- Cuenta bloqueada:
--   ninguna.
--
-- ============================================================

ALTER TABLE public.automation_runs
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS automation_runs_client_select
ON public.automation_runs;

DROP POLICY IF EXISTS automation_runs_worker_select
ON public.automation_runs;


CREATE POLICY automation_runs_client_select
ON public.automation_runs
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
    AND EXISTS (
        SELECT 1
        FROM public.automations a
        WHERE a.id = automation_runs.automation_id
          AND a.user_id = auth.uid()
    )
);


CREATE POLICY automation_runs_worker_select
ON public.automation_runs
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 18. MAINTENANCE CONTRACTS
-- ============================================================
--
-- Cuenta bloqueada:
--   ninguna lectura
--   ninguna creación
--
-- Worker activo:
--   lectura interna.
--
-- ============================================================

DROP POLICY IF EXISTS maintenance_contracts_client_select
ON public.maintenance_contracts;

DROP POLICY IF EXISTS maintenance_contracts_client_insert
ON public.maintenance_contracts;

DROP POLICY IF EXISTS maintenance_contracts_worker_select
ON public.maintenance_contracts;


CREATE POLICY maintenance_contracts_client_select
ON public.maintenance_contracts
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND (
        (
            company_id IS NOT NULL
            AND company_id = public.current_user_company_id()
        )
        OR
        (
            company_id IS NULL
            AND user_id = auth.uid()
        )
    )
);


CREATE POLICY maintenance_contracts_client_insert
ON public.maintenance_contracts
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
    AND (
        company_id IS NULL
        OR company_id = public.current_user_company_id()
    )
);


CREATE POLICY maintenance_contracts_worker_select
ON public.maintenance_contracts
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 19. INVOICES
-- ============================================================
--
-- H-05 es especialmente importante aquí.
--
-- El checkout Edge Function utiliza el usuario autenticado
-- para localizar la factura.
--
-- Si la cuenta está bloqueada:
--
--   current_user_company_id() = NULL
--
-- por lo que la factura deja de ser visible mediante RLS.
--
-- ============================================================

DROP POLICY IF EXISTS invoices_client_select
ON public.invoices;

DROP POLICY IF EXISTS invoices_worker_select
ON public.invoices;


CREATE POLICY invoices_client_select
ON public.invoices
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


CREATE POLICY invoices_worker_select
ON public.invoices
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 20. COMPANIES
-- ============================================================
--
-- Cuenta bloqueada:
--   no puede consultar ni modificar su empresa.
--
-- ============================================================

DROP POLICY IF EXISTS companies_select_own
ON public.companies;

DROP POLICY IF EXISTS companies_update_own
ON public.companies;

DROP POLICY IF EXISTS companies_worker_select
ON public.companies;


CREATE POLICY companies_select_own
ON public.companies
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = public.current_user_company_id()
);


CREATE POLICY companies_update_own
ON public.companies
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = public.current_user_company_id()
)
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = public.current_user_company_id()
);


CREATE POLICY companies_worker_select
ON public.companies
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 21. CLIENTS
-- ============================================================

DROP POLICY IF EXISTS clients_company_access
ON public.clients;


CREATE POLICY clients_company_access
ON public.clients
FOR ALL
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
)
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


-- ============================================================
-- 22. PAYMENTS
-- ============================================================

DROP POLICY IF EXISTS payments_company_access
ON public.payments;


CREATE POLICY payments_company_access
ON public.payments
FOR ALL
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
)
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


-- ============================================================
-- 23. BUDGETS
-- ============================================================

DROP POLICY IF EXISTS budgets_company_access
ON public.budgets;


CREATE POLICY budgets_company_access
ON public.budgets
FOR ALL
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
)
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


-- ============================================================
-- 24. COMPANY CHANGE REQUESTS
-- ============================================================
--
-- Una cuenta bloqueada no puede solicitar cambios de empresa
-- ni consultar solicitudes propias.
--
-- Workers activos de MODIRA mantienen el acceso interno.
--
-- ============================================================

DROP POLICY IF EXISTS company_change_requests_client_insert
ON public.company_change_requests;

DROP POLICY IF EXISTS company_change_requests_client_select
ON public.company_change_requests;

DROP POLICY IF EXISTS company_change_requests_worker_select
ON public.company_change_requests;

DROP POLICY IF EXISTS company_change_requests_worker_update
ON public.company_change_requests;

DROP POLICY IF EXISTS company_change_requests_worker_delete
ON public.company_change_requests;


CREATE POLICY company_change_requests_client_insert
ON public.company_change_requests
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
    AND current_company_id IS NOT DISTINCT FROM
        public.current_user_company_id()
    AND status = 'pending'
);


CREATE POLICY company_change_requests_client_select
ON public.company_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
);


CREATE POLICY company_change_requests_worker_select
ON public.company_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


CREATE POLICY company_change_requests_worker_update
ON public.company_change_requests
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
)
WITH CHECK (
    public.current_user_is_worker()
);


CREATE POLICY company_change_requests_worker_delete
ON public.company_change_requests
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 25. VALIDACIÓN DE EMPRESA ACTIVA
-- ============================================================
--
-- Una cuenta activa con una empresa desactivada tampoco debe
-- poder operar sobre ella.
--
-- current_user_company_id() continúa devolviendo el company_id,
-- pero la policy de companies/resources deberá comprobar
-- company.is_active cuando corresponda.
--
-- ============================================================

DROP POLICY IF EXISTS companies_select_own
ON public.companies;

CREATE POLICY companies_select_own
ON public.companies
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = public.current_user_company_id()
    AND is_active = TRUE
);


DROP POLICY IF EXISTS companies_update_own
ON public.companies;

CREATE POLICY companies_update_own
ON public.companies
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = public.current_user_company_id()
    AND is_active = TRUE
)
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND id = public.current_user_company_id()
);


-- ============================================================
-- 26. COMENTARIOS
-- ============================================================

COMMENT ON COLUMN public.profiles.status
IS
'Estado de acceso de la cuenta. active permite operar; blocked bloquea el acceso a las operaciones protegidas.';


COMMENT ON FUNCTION public.current_user_is_active()
IS
'Indica si la cuenta autenticada tiene un perfil con status active.';


COMMENT ON FUNCTION public.current_user_is_blocked()
IS
'Indica si la cuenta autenticada tiene status blocked.';


COMMENT ON FUNCTION public.set_profile_status(UUID, TEXT)
IS
'Permite a un trabajador activo de MODIRA bloquear o desbloquear una cuenta de usuario. El bloqueo revoca las sesiones Auth existentes.';


COMMENT ON FUNCTION public.revoke_user_sessions(UUID)
IS
'Revoca las sesiones Auth almacenadas para un usuario bloqueado.';


-- ============================================================
-- 27. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- profiles.status
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'profiles'
          AND column_name = 'status'
    ) THEN
        RAISE EXCEPTION
            '016 failed: profiles.status missing';
    END IF;


    -- --------------------------------------------------------
    -- status constraint
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_constraint
    WHERE conrelid = 'public.profiles'::regclass
      AND conname = 'profiles_status_check';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '016 failed: profiles_status_check missing';
    END IF;


    -- --------------------------------------------------------
    -- current_user_is_active
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_user_is_active()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '016 failed: current_user_is_active() missing';
    END IF;


    -- --------------------------------------------------------
    -- current_user_is_blocked
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_user_is_blocked()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '016 failed: current_user_is_blocked() missing';
    END IF;


    -- --------------------------------------------------------
    -- set_profile_status
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.set_profile_status(uuid,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '016 failed: set_profile_status(uuid,text) missing';
    END IF;


    -- --------------------------------------------------------
    -- revoke_user_sessions
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.revoke_user_sessions(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '016 failed: revoke_user_sessions(uuid) missing';
    END IF;


    -- --------------------------------------------------------
    -- profiles policies
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'profiles'
      AND policyname IN (
          'profiles_select_own',
          'profiles_update_own',
          'profiles_worker_select',
          'profiles_worker_update'
      );

    IF v_count <> 4 THEN
        RAISE EXCEPTION
            '016 failed: profiles policies incomplete';
    END IF;


    -- --------------------------------------------------------
    -- invoices policies
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'invoices'
      AND policyname IN (
          'invoices_client_select',
          'invoices_worker_select'
      );

    IF v_count <> 2 THEN
        RAISE EXCEPTION
            '016 failed: invoices policies incomplete';
    END IF;


    -- --------------------------------------------------------
    -- automations policies
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'automations'
      AND policyname IN (
          'automations_client_select',
          'automations_client_insert',
          'automations_client_update',
          'automations_worker_select'
      );

    IF v_count <> 4 THEN
        RAISE EXCEPTION
            '016 failed: automations policies incomplete';
    END IF;


    -- --------------------------------------------------------
    -- maintenance policies
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'maintenance_contracts'
      AND policyname IN (
          'maintenance_contracts_client_select',
          'maintenance_contracts_client_insert',
          'maintenance_contracts_worker_select'
      );

    IF v_count <> 3 THEN
        RAISE EXCEPTION
            '016 failed: maintenance policies incomplete';
    END IF;


END $$;


-- ============================================================
-- 28. CIERRE DE RUTAS RESIDUALES DE CUENTAS BLOQUEADAS
-- ============================================================
--
-- Las migraciones 003, 006, 013 y 014 conservaban algunas rutas
-- basadas exclusivamente en user_id. Aunque current_user_company_id()
-- ya devuelve NULL para cuentas bloqueadas, esas rutas no dependen de
-- company_id y, por tanto, requieren una comprobación explícita del
-- estado de la cuenta.
--
-- Esta sección completa el objetivo transversal de 016: una cuenta
-- bloqueada no puede consultar ni crear recursos protegidos, incluso
-- cuando el recurso histórico pertenezca directamente a auth.uid().
-- ============================================================


-- ------------------------------------------------------------
-- 28.1 PROYECTOS
-- ------------------------------------------------------------

DROP POLICY IF EXISTS projects_select_policy
ON public.projects;

CREATE POLICY projects_select_policy
ON public.projects
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR (
        public.current_user_is_active()
        AND NOT public.current_user_is_worker()
        AND user_id = auth.uid()
    )
);


DROP POLICY IF EXISTS projects_insert_policy
ON public.projects;

CREATE POLICY projects_insert_policy
ON public.projects
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
    AND (
        (
            public.current_user_company_id() IS NOT NULL
            AND company_id = public.current_user_company_id()
        )
        OR (
            public.current_user_company_id() IS NULL
            AND company_id IS NULL
        )
    )
    AND estado IN (
        'Pendiente',
        'Activo',
        'Pausado',
        'Entregado',
        'Completado'
    )
);


CREATE OR REPLACE FUNCTION public.create_project(
    p_descripcion TEXT,
    p_fecha_inicio TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    p_fecha_fin TIMESTAMPTZ DEFAULT NULL
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_project public.projects;
    v_company_id UUID;
    v_fecha_inicio TIMESTAMPTZ;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION 'Acceso denegado: la cuenta está bloqueada';
    END IF;

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Los trabajadores no pueden crear proyectos mediante create_project()';
    END IF;

    IF p_descripcion IS NULL OR TRIM(p_descripcion) = '' THEN
        RAISE EXCEPTION 'La descripción del proyecto es obligatoria';
    END IF;

    v_fecha_inicio := COALESCE(p_fecha_inicio, CURRENT_TIMESTAMP);

    IF p_fecha_fin IS NOT NULL AND p_fecha_fin < v_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha de fin no puede ser anterior a la fecha de inicio';
    END IF;

    v_company_id := public.current_user_company_id();

    INSERT INTO public.projects (
        user_id,
        company_id,
        nombre,
        descripcion,
        estado,
        fecha_inicio,
        fecha_fin
    )
    VALUES (
        auth.uid(),
        v_company_id,
        'Proyecto sin título',
        TRIM(p_descripcion),
        'Pendiente',
        v_fecha_inicio,
        p_fecha_fin
    )
    RETURNING * INTO v_project;

    RETURN v_project;
END;
$$;

REVOKE ALL
ON FUNCTION public.create_project(TEXT, TIMESTAMPTZ, TIMESTAMPTZ)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_project(TEXT, TIMESTAMPTZ, TIMESTAMPTZ)
TO authenticated;


-- ------------------------------------------------------------
-- 28.2 SOLICITUDES Y DOCUMENTOS DE PROYECTO
-- ------------------------------------------------------------

DROP POLICY IF EXISTS project_change_requests_select
ON public.project_change_requests;

CREATE POLICY project_change_requests_select
ON public.project_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR (
        public.current_user_is_active()
        AND NOT public.current_user_is_worker()
        AND EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_change_requests.project_id
              AND p.user_id = auth.uid()
        )
    )
);


CREATE OR REPLACE FUNCTION public.request_project_change(
    p_project_id UUID,
    p_description TEXT
)
RETURNS public.project_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_project public.projects;
    v_request public.project_change_requests;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION 'Acceso denegado: la cuenta está bloqueada';
    END IF;

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Los trabajadores no pueden crear solicitudes de cambio de cliente';
    END IF;

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION 'El proyecto es obligatorio';
    END IF;

    IF p_description IS NULL OR btrim(p_description) = '' THEN
        RAISE EXCEPTION 'La descripción del cambio es obligatoria';
    END IF;

    IF length(p_description) > 5000 THEN
        RAISE EXCEPTION 'La descripción del cambio no puede superar 5000 caracteres';
    END IF;

    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = p_project_id
      AND user_id = auth.uid()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El proyecto no existe o no pertenece al usuario autenticado';
    END IF;

    IF v_project.change_requests_enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'Las solicitudes de cambio no están habilitadas para este proyecto';
    END IF;

    IF v_project.change_requests_deadline IS NULL THEN
        RAISE EXCEPTION 'El proyecto no tiene una fecha límite de solicitudes configurada';
    END IF;

    IF CURRENT_TIMESTAMP > v_project.change_requests_deadline THEN
        RAISE EXCEPTION 'El periodo para solicitar cambios ha finalizado';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.project_change_requests r
        WHERE r.project_id = v_project.id
          AND r.status IN ('pending', 'in_review', 'accepted')
    ) THEN
        RAISE EXCEPTION 'Este proyecto ya tiene una solicitud de cambio en curso';
    END IF;

    INSERT INTO public.project_change_requests (
        project_id,
        user_id,
        company_id,
        client_id,
        description,
        status
    )
    VALUES (
        v_project.id,
        auth.uid(),
        v_project.company_id,
        v_project.client_id,
        btrim(p_description),
        'pending'
    )
    RETURNING * INTO v_request;

    INSERT INTO public.activity_log (
        user_id,
        company_id,
        action,
        resource_type,
        resource_id,
        description,
        metadata
    )
    VALUES (
        auth.uid(),
        v_project.company_id,
        'project.change_request_created',
        'project_change_request',
        v_request.id,
        'El cliente ha solicitado un cambio en el proyecto',
        jsonb_build_object(
            'project_id', v_project.id,
            'description', v_request.description
        )
    );

    RETURN v_request;
END;
$$;

REVOKE ALL
ON FUNCTION public.request_project_change(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.request_project_change(UUID, TEXT)
TO authenticated;


DROP POLICY IF EXISTS project_documents_select
ON public.project_documents;

CREATE POLICY project_documents_select
ON public.project_documents
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR (
        public.current_user_is_active()
        AND NOT public.current_user_is_worker()
        AND EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_documents.project_id
              AND p.user_id = auth.uid()
        )
    )
);


DROP POLICY IF EXISTS project_documents_storage_client_select
ON storage.objects;

CREATE POLICY project_documents_storage_client_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'project-documents'
    AND public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.project_documents d
        JOIN public.projects p
          ON p.id = d.project_id
        WHERE d.storage_path = storage.objects.name
          AND p.user_id = auth.uid()
    )
);


-- ------------------------------------------------------------
-- 28.3 SOPORTE Y REGISTRO DE ACTIVIDAD
-- ------------------------------------------------------------

DROP POLICY IF EXISTS support_tickets_client_select
ON public.support_tickets;

CREATE POLICY support_tickets_client_select
ON public.support_tickets
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND (
        (
            company_id IS NOT NULL
            AND company_id = public.current_user_company_id()
        )
        OR (
            company_id IS NULL
            AND user_id = auth.uid()
        )
    )
);


DROP POLICY IF EXISTS support_tickets_client_insert
ON public.support_tickets;

CREATE POLICY support_tickets_client_insert
ON public.support_tickets
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
    AND (
        company_id IS NULL
        OR company_id = public.current_user_company_id()
    )
);


DROP POLICY IF EXISTS activity_log_client_select
ON public.activity_log;

CREATE POLICY activity_log_client_select
ON public.activity_log
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND (
        (
            company_id IS NOT NULL
            AND company_id = public.current_user_company_id()
        )
        OR (
            company_id IS NULL
            AND user_id = auth.uid()
        )
    )
);


CREATE OR REPLACE FUNCTION public.log_activity(
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id UUID DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT NULL
)
RETURNS public.activity_log
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID;
    v_company_id UUID;
    v_activity public.activity_log;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION 'Acceso denegado: la cuenta está bloqueada';
    END IF;

    IF public.current_user_is_worker() THEN
        v_company_id := NULL;
    ELSE
        v_company_id := public.current_user_company_id();
    END IF;

    IF p_action IS NULL OR TRIM(p_action) = '' THEN
        RAISE EXCEPTION 'La acción es obligatoria';
    END IF;

    IF p_resource_type IS NULL OR TRIM(p_resource_type) = '' THEN
        RAISE EXCEPTION 'El tipo de recurso es obligatorio';
    END IF;

    INSERT INTO public.activity_log (
        user_id,
        company_id,
        action,
        resource_type,
        resource_id,
        description,
        metadata
    )
    VALUES (
        v_user_id,
        v_company_id,
        TRIM(p_action),
        TRIM(p_resource_type),
        p_resource_id,
        p_description,
        p_metadata
    )
    RETURNING * INTO v_activity;

    RETURN v_activity;
END;
$$;

REVOKE ALL
ON FUNCTION public.log_activity(TEXT, TEXT, UUID, TEXT, JSONB)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.log_activity(TEXT, TEXT, UUID, TEXT, JSONB)
TO authenticated;


-- ------------------------------------------------------------
-- 28.4 VALIDACIONES ADICIONALES
-- ------------------------------------------------------------

DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND (
          (tablename = 'projects' AND policyname IN (
              'projects_select_policy',
              'projects_insert_policy'
          ))
          OR
          (tablename = 'project_change_requests' AND policyname =
              'project_change_requests_select')
          OR
          (tablename = 'project_documents' AND policyname =
              'project_documents_select')
          OR
          (tablename = 'support_tickets' AND policyname IN (
              'support_tickets_client_select',
              'support_tickets_client_insert'
          ))
          OR
          (tablename = 'activity_log' AND policyname =
              'activity_log_client_select')
      );

    IF v_count <> 7 THEN
        RAISE EXCEPTION
            '016 failed: account-status hardening policies incomplete';
    END IF;

    IF to_regprocedure(
        'public.create_project(text,timestamp with time zone,timestamp with time zone)'
    ) IS NULL THEN
        RAISE EXCEPTION '016 failed: create_project() missing';
    END IF;

    IF to_regprocedure(
        'public.request_project_change(uuid,text)'
    ) IS NULL THEN
        RAISE EXCEPTION '016 failed: request_project_change() missing';
    END IF;

    IF to_regprocedure(
        'public.log_activity(text,text,uuid,text,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION '016 failed: log_activity() missing';
    END IF;
END $$;


COMMIT;
