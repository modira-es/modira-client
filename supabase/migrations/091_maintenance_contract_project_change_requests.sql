-- ============================================================================
-- MODIRA — 091_maintenance_contract_project_change_requests.sql
-- ============================================================================
-- OBJETIVO
-- 1. Permitir que un cliente solicite cambiar el proyecto asociado a su
--    contrato de mantenimiento sin cancelar el contrato.
-- 2. El cambio queda pendiente de revisión por Modira.
-- 3. Si se aprueba antes de la próxima frontera de facturación, se programa
--    para el siguiente periodo.
-- 4. Si se aprueba después de esa frontera, se programa para la siguiente
--    frontera disponible, sin alterar retroactivamente el periodo ya iniciado.
-- 5. El contrato, Stripe, el ciclo de facturación y las facturas históricas
--    permanecen intactos.
-- 6. Añadir rate limits específicos para cambios de proyecto y de plan.
-- 7. Añadir project_id a maintenance_invoices para conservar el proyecto
--    cubierto por cada periodo como snapshot relacional histórico.
--
-- NOTA:
-- Stripe NO se modifica desde SQL. La Edge Function seguirá siendo responsable
-- de Stripe y de la generación/emisión de nuevas maintenance_invoices.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('public.maintenance_contracts') IS NULL THEN
    RAISE EXCEPTION '091 stopped: public.maintenance_contracts no existe';
  END IF;

  IF to_regclass('public.maintenance_contract_projects') IS NULL THEN
    RAISE EXCEPTION '091 stopped: public.maintenance_contract_projects no existe';
  END IF;

  IF to_regclass('public.maintenance_invoices') IS NULL THEN
    RAISE EXCEPTION '091 stopped: public.maintenance_invoices no existe';
  END IF;

  IF to_regclass('public.projects') IS NULL THEN
    RAISE EXCEPTION '091 stopped: public.projects no existe';
  END IF;

  IF to_regclass('public.security_rate_limits') IS NULL THEN
    RAISE EXCEPTION '091 stopped: public.security_rate_limits no existe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contracts'
      AND column_name = 'current_period_end'
  ) THEN
    RAISE EXCEPTION '091 stopped: maintenance_contracts.current_period_end no existe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contracts'
      AND column_name = 'company_id'
  ) THEN
    RAISE EXCEPTION '091 stopped: maintenance_contracts.company_id no existe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'projects'
      AND column_name = 'company_id'
  ) THEN
    RAISE EXCEPTION '091 stopped: projects.company_id no existe';
  END IF;
END $$;


-- ============================================================================
-- 2. COLUMNAS PENDIENTES EN MAINTENANCE_CONTRACTS
-- ============================================================================

ALTER TABLE public.maintenance_contracts
  ADD COLUMN IF NOT EXISTS pending_project_id UUID,
  ADD COLUMN IF NOT EXISTS pending_project_change_effective_at DATE;

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_pending_project_change_check;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_pending_project_change_check
  CHECK (
    pending_project_change_effective_at IS NULL
    OR pending_project_id IS NOT NULL
  );

ALTER TABLE public.maintenance_contracts
  DROP CONSTRAINT IF EXISTS maintenance_contracts_pending_project_fkey;

ALTER TABLE public.maintenance_contracts
  ADD CONSTRAINT maintenance_contracts_pending_project_fkey
  FOREIGN KEY (pending_project_id)
  REFERENCES public.projects(id)
  ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_pending_project
ON public.maintenance_contracts (pending_project_id)
WHERE pending_project_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contracts_pending_project_effective
ON public.maintenance_contracts (pending_project_change_effective_at)
WHERE pending_project_change_effective_at IS NOT NULL;


-- ============================================================================
-- 3. TABLA DE SOLICITUDES DE CAMBIO DE PROYECTO
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.maintenance_contract_project_change_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  maintenance_contract_id UUID NOT NULL
    REFERENCES public.maintenance_contracts(id)
    ON DELETE CASCADE,

  company_id UUID NOT NULL
    REFERENCES public.companies(id)
    ON DELETE CASCADE,

  requested_by UUID NOT NULL
    REFERENCES auth.users(id)
    ON DELETE RESTRICT,

  current_project_id UUID
    REFERENCES public.projects(id)
    ON DELETE SET NULL,

  requested_project_id UUID NOT NULL
    REFERENCES public.projects(id)
    ON DELETE RESTRICT,

  status TEXT NOT NULL DEFAULT 'pending',

  requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reviewed_at TIMESTAMPTZ,
  reviewed_by UUID
    REFERENCES auth.users(id)
    ON DELETE SET NULL,

  effective_at DATE,

  rejection_reason TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT maintenance_contract_project_change_status_check
    CHECK (
      status IN (
        'pending',
        'approved',
        'rejected',
        'applied',
        'cancelled'
      )
    ),

  CONSTRAINT maintenance_contract_project_change_review_check
    CHECK (
      status IN ('pending', 'cancelled')
      OR reviewed_at IS NOT NULL
    ),

  CONSTRAINT maintenance_contract_project_change_approval_check
    CHECK (
      status NOT IN ('approved', 'applied')
      OR effective_at IS NOT NULL
    ),

  CONSTRAINT maintenance_contract_project_change_rejection_check
    CHECK (
      status <> 'rejected'
      OR NULLIF(BTRIM(rejection_reason), '') IS NOT NULL
    )
);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_project_change_requests_contract
ON public.maintenance_contract_project_change_requests (
  maintenance_contract_id,
  created_at DESC
);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_project_change_requests_company
ON public.maintenance_contract_project_change_requests (
  company_id,
  created_at DESC
);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_project_change_requests_status
ON public.maintenance_contract_project_change_requests (
  status,
  created_at DESC
);

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_maintenance_project_change_one_pending_per_contract
ON public.maintenance_contract_project_change_requests (
  maintenance_contract_id
)
WHERE status = 'pending';


-- ============================================================================
-- 4. INTEGRIDAD DE LA SOLICITUD
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validate_maintenance_project_change_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_contract public.maintenance_contracts;
  v_current_project_id UUID;
  v_requested_company_id UUID;
BEGIN
  SELECT *
  INTO v_contract
  FROM public.maintenance_contracts
  WHERE id = NEW.maintenance_contract_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El contrato de mantenimiento no existe';
  END IF;

  IF NEW.company_id IS DISTINCT FROM v_contract.company_id THEN
    RAISE EXCEPTION 'La solicitud no pertenece a la empresa del contrato';
  END IF;

  IF NOT public.is_live_maintenance_contract_status(v_contract.estado) THEN
    RAISE EXCEPTION 'Solo se puede solicitar un cambio sobre un mantenimiento activo o pausado';
  END IF;

  SELECT mcp.project_id
  INTO v_current_project_id
  FROM public.maintenance_contract_projects mcp
  WHERE mcp.maintenance_contract_id = v_contract.id
  ORDER BY mcp.created_at DESC
  LIMIT 1;

  IF v_current_project_id IS NULL THEN
    RAISE EXCEPTION 'El contrato no tiene un proyecto actual asociado';
  END IF;

  IF NEW.current_project_id IS DISTINCT FROM v_current_project_id THEN
    RAISE EXCEPTION 'El proyecto actual de la solicitud ya no coincide con el proyecto del contrato';
  END IF;

  IF NEW.requested_project_id = v_current_project_id THEN
    RAISE EXCEPTION 'El proyecto solicitado ya es el proyecto actual';
  END IF;

  SELECT p.company_id
  INTO v_requested_company_id
  FROM public.projects p
  WHERE p.id = NEW.requested_project_id;

  IF v_requested_company_id IS NULL THEN
    RAISE EXCEPTION 'El proyecto solicitado no existe o no tiene empresa';
  END IF;

  IF v_requested_company_id IS DISTINCT FROM v_contract.company_id THEN
    RAISE EXCEPTION 'El proyecto solicitado no pertenece a la misma empresa que el contrato';
  END IF;

  -- El proyecto solicitado no puede estar ocupado por otro contrato vivo.
  IF EXISTS (
    SELECT 1
    FROM public.maintenance_contract_projects mcp
    JOIN public.maintenance_contracts other_mc
      ON other_mc.id = mcp.maintenance_contract_id
    WHERE mcp.project_id = NEW.requested_project_id
      AND other_mc.id <> v_contract.id
      AND public.is_live_maintenance_contract_status(other_mc.estado)
  ) THEN
    RAISE EXCEPTION
      'El proyecto solicitado ya está asociado a otro contrato de mantenimiento activo o pausado';
  END IF;

  -- Si ya existe una transición programada distinta, no permitimos
  -- sobrescribirla mediante otra solicitud.
  IF v_contract.pending_project_id IS NOT NULL
     AND v_contract.pending_project_id IS DISTINCT FROM NEW.requested_project_id
  THEN
    RAISE EXCEPTION
      'El contrato ya tiene otro cambio de proyecto pendiente';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL
ON FUNCTION public.validate_maintenance_project_change_request()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.validate_maintenance_project_change_request()
TO service_role;

DROP TRIGGER IF EXISTS
  maintenance_project_change_requests_validate
ON public.maintenance_contract_project_change_requests;

CREATE TRIGGER
  maintenance_project_change_requests_validate
BEFORE INSERT OR UPDATE
ON public.maintenance_contract_project_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_project_change_request();


-- ============================================================================
-- 5. RATE LIMIT ESPECÍFICO PARA CAMBIOS DE MANTENIMIENTO
-- ============================================================================
--
-- Límites elegidos:
--
--   cambio de proyecto: 1 solicitud por empresa cada 7 días
--   cambio de plan:     1 solicitud por empresa cada 7 días
--
-- Además, el cambio de proyecto queda limitado a una solicitud pendiente
-- por contrato mediante el índice UNIQUE parcial anterior.
--
-- La función usa la tabla security_rate_limits existente y advisory locks.
-- Solo service_role puede consumirla; la Edge Function es quien la invocará.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.consume_maintenance_change_rate_limit(
  p_company_id UUID,
  p_action TEXT,
  p_limit INTEGER DEFAULT 1,
  p_window_seconds INTEGER DEFAULT 604800
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_key TEXT;
  v_row public.security_rate_limits;
  v_now TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_remaining INTEGER;
  v_retry_after INTEGER;
BEGIN
  IF p_company_id IS NULL THEN
    RAISE EXCEPTION 'La empresa es obligatoria';
  END IF;

  IF p_action NOT IN (
    'maintenance_project_change',
    'maintenance_plan_change'
  ) THEN
    RAISE EXCEPTION 'Acción de rate limit no válida';
  END IF;

  IF p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'Límite de rate limit no válido';
  END IF;

  IF p_window_seconds < 1 OR p_window_seconds > 2592000 THEN
    RAISE EXCEPTION 'Ventana de rate limit no válida';
  END IF;

  v_key :=
    'maintenance-change:' ||
    p_action ||
    ':company:' ||
    p_company_id::TEXT;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_key, 0)
  );

  SELECT *
  INTO v_row
  FROM public.security_rate_limits
  WHERE rate_key = v_key
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.security_rate_limits (
      rate_key,
      window_started_at,
      request_count,
      updated_at
    )
    VALUES (
      v_key,
      v_now,
      1,
      v_now
    )
    RETURNING *
    INTO v_row;

    RETURN jsonb_build_object(
      'allowed', TRUE,
      'remaining', GREATEST(p_limit - 1, 0),
      'retry_after_seconds', 0
    );
  END IF;

  IF v_row.window_started_at + make_interval(secs => p_window_seconds) <= v_now THEN
    UPDATE public.security_rate_limits
    SET
      window_started_at = v_now,
      request_count = 1,
      updated_at = v_now
    WHERE rate_key = v_key;

    RETURN jsonb_build_object(
      'allowed', TRUE,
      'remaining', GREATEST(p_limit - 1, 0),
      'retry_after_seconds', 0
    );
  END IF;

  IF v_row.request_count >= p_limit THEN
    v_retry_after := GREATEST(
      1,
      CEIL(
        EXTRACT(
          EPOCH FROM (
            v_row.window_started_at
            + make_interval(secs => p_window_seconds)
            - v_now
          )
        )
      )::INTEGER
    );

    RETURN jsonb_build_object(
      'allowed', FALSE,
      'remaining', 0,
      'retry_after_seconds', v_retry_after
    );
  END IF;

  UPDATE public.security_rate_limits
  SET
    request_count = request_count + 1,
    updated_at = v_now
  WHERE rate_key = v_key;

  v_remaining := GREATEST(
    p_limit - (v_row.request_count + 1),
    0
  );

  RETURN jsonb_build_object(
    'allowed', TRUE,
    'remaining', v_remaining,
    'retry_after_seconds', 0
  );
END;
$function$;

REVOKE ALL
ON FUNCTION public.consume_maintenance_change_rate_limit(
  UUID,
  TEXT,
  INTEGER,
  INTEGER
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.consume_maintenance_change_rate_limit(
  UUID,
  TEXT,
  INTEGER,
  INTEGER
)
TO service_role;


-- ============================================================================
-- 6. RPC — CLIENTE SOLICITA CAMBIO DE PROYECTO
-- ============================================================================
--
-- Esta RPC NO aplica el cambio.
-- Solo registra la petición. La Edge Function/Employee Area aprobará después.
-- El rate limit se consume aquí mismo para que el límite no dependa del
-- frontend.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.request_maintenance_contract_project_change(
  p_contract_id UUID,
  p_requested_project_id UUID
)
RETURNS public.maintenance_contract_project_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_user_id UUID := auth.uid();
  v_company_id UUID;
  v_contract public.maintenance_contracts;
  v_current_project_id UUID;
  v_request public.maintenance_contract_project_change_requests;
  v_limit JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión';
  END IF;

  IF public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Los trabajadores no utilizan esta vía';
  END IF;

  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'El usuario no está activo';
  END IF;

  v_company_id := public.current_user_company_id();

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'El usuario no pertenece a ninguna empresa';
  END IF;

  SELECT *
  INTO v_contract
  FROM public.maintenance_contracts
  WHERE id = p_contract_id
    AND company_id = v_company_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El contrato de mantenimiento no existe o no pertenece a tu empresa';
  END IF;

  IF NOT public.is_live_maintenance_contract_status(v_contract.estado) THEN
    RAISE EXCEPTION 'El mantenimiento no está activo o pausado';
  END IF;

  SELECT mcp.project_id
  INTO v_current_project_id
  FROM public.maintenance_contract_projects mcp
  WHERE mcp.maintenance_contract_id = v_contract.id
  ORDER BY mcp.created_at DESC
  LIMIT 1;

  IF v_current_project_id IS NULL THEN
    RAISE EXCEPTION 'El contrato no tiene un proyecto asociado';
  END IF;

  IF p_requested_project_id IS NULL THEN
    RAISE EXCEPTION 'Debes seleccionar un proyecto';
  END IF;

  IF p_requested_project_id = v_current_project_id THEN
    RAISE EXCEPTION 'El proyecto seleccionado ya es el proyecto actual';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.maintenance_contract_project_change_requests
    WHERE maintenance_contract_id = v_contract.id
      AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'Ya existe una solicitud de cambio de proyecto pendiente para este mantenimiento';
  END IF;

  IF v_contract.pending_project_id IS NOT NULL THEN
    RAISE EXCEPTION 'Ya existe un cambio de proyecto programado para este mantenimiento';
  END IF;

  -- El proyecto nuevo debe pertenecer a la empresa y estar disponible.
  PERFORM 1
  FROM public.projects p
  WHERE p.id = p_requested_project_id
    AND p.company_id = v_company_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El proyecto seleccionado no existe o no pertenece a tu empresa';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.maintenance_contract_projects mcp
    JOIN public.maintenance_contracts other_mc
      ON other_mc.id = mcp.maintenance_contract_id
    WHERE mcp.project_id = p_requested_project_id
      AND other_mc.id <> v_contract.id
      AND public.is_live_maintenance_contract_status(other_mc.estado)
  ) THEN
    RAISE EXCEPTION 'El proyecto seleccionado ya tiene un mantenimiento activo o pausado';
  END IF;

  v_limit := public.consume_maintenance_change_rate_limit(
    v_company_id,
    'maintenance_project_change',
    1,
    604800
  );

  IF COALESCE((v_limit ->> 'allowed')::BOOLEAN, FALSE) = FALSE THEN
    RAISE EXCEPTION
      'Has alcanzado el límite de solicitudes de cambio de proyecto. Inténtalo de nuevo cuando finalice el periodo de espera.';
  END IF;

  INSERT INTO public.maintenance_contract_project_change_requests (
    maintenance_contract_id,
    company_id,
    requested_by,
    current_project_id,
    requested_project_id,
    status
  )
  VALUES (
    v_contract.id,
    v_company_id,
    v_user_id,
    v_current_project_id,
    p_requested_project_id,
    'pending'
  )
  RETURNING *
  INTO v_request;

  RETURN v_request;
END;
$function$;

REVOKE ALL
ON FUNCTION public.request_maintenance_contract_project_change(UUID, UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.request_maintenance_contract_project_change(UUID, UUID)
TO authenticated;


-- ============================================================================
-- 7. RPC — EMPLEADO APRUEBA CAMBIO DE PROYECTO
-- ============================================================================
--
-- No cambia todavía maintenance_contract_projects.
-- Programa el cambio para la siguiente frontera de facturación disponible.
--
-- Si CURRENT_DATE < current_period_end:
--     effective_at = current_period_end
--
-- Si CURRENT_DATE >= current_period_end:
--     effective_at = siguiente periodo mensual.
--
-- Esto evita modificar retroactivamente un periodo que ya comenzó.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.approve_maintenance_contract_project_change(
  p_request_id UUID
)
RETURNS public.maintenance_contract_project_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_worker_id UUID := auth.uid();
  v_request public.maintenance_contract_project_change_requests;
  v_contract public.maintenance_contracts;
  v_current_project_id UUID;
  v_effective_at DATE;
BEGIN
  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión';
  END IF;

  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Se requiere un trabajador activo';
  END IF;

  SELECT *
  INTO v_request
  FROM public.maintenance_contract_project_change_requests
  WHERE id = p_request_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud no existe o ya ha sido revisada';
  END IF;

  SELECT *
  INTO v_contract
  FROM public.maintenance_contracts
  WHERE id = v_request.maintenance_contract_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El contrato asociado ya no existe';
  END IF;

  IF v_contract.company_id IS DISTINCT FROM v_request.company_id THEN
    RAISE EXCEPTION 'La solicitud y el contrato no pertenecen a la misma empresa';
  END IF;

  IF NOT public.is_live_maintenance_contract_status(v_contract.estado) THEN
    RAISE EXCEPTION 'El contrato ya no está activo o pausado';
  END IF;

  SELECT mcp.project_id
  INTO v_current_project_id
  FROM public.maintenance_contract_projects mcp
  WHERE mcp.maintenance_contract_id = v_contract.id
  ORDER BY mcp.created_at DESC
  LIMIT 1;

  IF v_current_project_id IS NULL THEN
    RAISE EXCEPTION 'El contrato ya no tiene un proyecto actual';
  END IF;

  IF v_current_project_id IS DISTINCT FROM v_request.current_project_id THEN
    RAISE EXCEPTION 'El proyecto actual del contrato ha cambiado desde que se creó la solicitud';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.maintenance_contract_projects mcp
    JOIN public.maintenance_contracts other_mc
      ON other_mc.id = mcp.maintenance_contract_id
    WHERE mcp.project_id = v_request.requested_project_id
      AND other_mc.id <> v_contract.id
      AND public.is_live_maintenance_contract_status(other_mc.estado)
  ) THEN
    RAISE EXCEPTION 'El proyecto solicitado ya está ocupado por otro mantenimiento activo o pausado';
  END IF;

  IF v_contract.current_period_end IS NULL THEN
    RAISE EXCEPTION 'El contrato no tiene una fecha de fin de periodo válida';
  END IF;

  IF CURRENT_DATE < v_contract.current_period_end THEN
    v_effective_at := v_contract.current_period_end;
  ELSE
    v_effective_at :=
      (
        v_contract.current_period_end
        + INTERVAL '1 month'
      )::DATE;
  END IF;

  UPDATE public.maintenance_contract_project_change_requests
  SET
    status = 'approved',
    reviewed_at = CURRENT_TIMESTAMP,
    reviewed_by = v_worker_id,
    effective_at = v_effective_at,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_request.id
  RETURNING *
  INTO v_request;

  UPDATE public.maintenance_contracts
  SET
    pending_project_id = v_request.requested_project_id,
    pending_project_change_effective_at = v_effective_at,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_contract.id;

  RETURN v_request;
END;
$function$;

REVOKE ALL
ON FUNCTION public.approve_maintenance_contract_project_change(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.approve_maintenance_contract_project_change(UUID)
TO authenticated;


-- ============================================================================
-- 8. RPC — EMPLEADO RECHAZA CAMBIO DE PROYECTO
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reject_maintenance_contract_project_change(
  p_request_id UUID,
  p_reason TEXT
)
RETURNS public.maintenance_contract_project_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_worker_id UUID := auth.uid();
  v_request public.maintenance_contract_project_change_requests;
BEGIN
  IF v_worker_id IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión';
  END IF;

  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Se requiere un trabajador activo';
  END IF;

  IF NULLIF(BTRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Debes indicar el motivo del rechazo';
  END IF;

  SELECT *
  INTO v_request
  FROM public.maintenance_contract_project_change_requests
  WHERE id = p_request_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud no existe o ya ha sido revisada';
  END IF;

  UPDATE public.maintenance_contract_project_change_requests
  SET
    status = 'rejected',
    reviewed_at = CURRENT_TIMESTAMP,
    reviewed_by = v_worker_id,
    rejection_reason = LEFT(BTRIM(p_reason), 2000),
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_request.id
  RETURNING *
  INTO v_request;

  RETURN v_request;
END;
$function$;

REVOKE ALL
ON FUNCTION public.reject_maintenance_contract_project_change(UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.reject_maintenance_contract_project_change(UUID, TEXT)
TO authenticated;


-- ============================================================================
-- 9. RPC — CANCELAR SOLICITUD PENDIENTE POR EL CLIENTE
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cancel_maintenance_contract_project_change(
  p_request_id UUID
)
RETURNS public.maintenance_contract_project_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_user_id UUID := auth.uid();
  v_company_id UUID;
  v_request public.maintenance_contract_project_change_requests;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión';
  END IF;

  IF public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Los trabajadores no utilizan esta vía';
  END IF;

  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'El usuario no está activo';
  END IF;

  v_company_id := public.current_user_company_id();

  SELECT *
  INTO v_request
  FROM public.maintenance_contract_project_change_requests
  WHERE id = p_request_id
    AND company_id = v_company_id
    AND requested_by = v_user_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud no existe o no puede cancelarse';
  END IF;

  UPDATE public.maintenance_contract_project_change_requests
  SET
    status = 'cancelled',
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_request.id
  RETURNING *
  INTO v_request;

  RETURN v_request;
END;
$function$;

REVOKE ALL
ON FUNCTION public.cancel_maintenance_contract_project_change(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.cancel_maintenance_contract_project_change(UUID)
TO authenticated;


-- ============================================================================
-- 10. RPC — APLICAR EL CAMBIO EN LA FRONTERA DE FACTURACIÓN
-- ============================================================================
--
-- Esta función se ejecutará desde backend/service_role ANTES de generar la
-- factura del nuevo periodo.
--
-- Es atómica con el cambio de relación contrato ↔ proyecto:
--   1. bloquea contrato;
--   2. comprueba que el cambio ya es efectivo;
--   3. comprueba disponibilidad del proyecto;
--   4. elimina la relación viva anterior;
--   5. inserta la nueva;
--   6. limpia el pending_* del contrato;
--   7. marca la solicitud como applied.
--
-- No modifica ninguna maintenance_invoice histórica.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.apply_maintenance_contract_project_change(
  p_contract_id UUID
)
RETURNS public.maintenance_contract_project_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_request public.maintenance_contract_project_change_requests;
  v_contract public.maintenance_contracts;
  v_old_project_id UUID;
BEGIN
  SELECT *
  INTO v_contract
  FROM public.maintenance_contracts
  WHERE id = p_contract_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El contrato de mantenimiento no existe';
  END IF;

  IF v_contract.pending_project_id IS NULL
     OR v_contract.pending_project_change_effective_at IS NULL
  THEN
    RAISE EXCEPTION 'El contrato no tiene un cambio de proyecto pendiente';
  END IF;

  IF CURRENT_DATE < v_contract.pending_project_change_effective_at THEN
    RAISE EXCEPTION 'El cambio de proyecto todavía no es efectivo';
  END IF;

  SELECT *
  INTO v_request
  FROM public.maintenance_contract_project_change_requests
  WHERE maintenance_contract_id = v_contract.id
    AND status = 'approved'
    AND requested_project_id = v_contract.pending_project_id
    AND effective_at = v_contract.pending_project_change_effective_at
  ORDER BY reviewed_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe una solicitud aprobada válida para el cambio pendiente';
  END IF;

  -- El nuevo proyecto no puede haber sido ocupado por otro contrato
  -- mientras la solicitud estaba pendiente.
  IF EXISTS (
    SELECT 1
    FROM public.maintenance_contract_projects mcp
    JOIN public.maintenance_contracts other_mc
      ON other_mc.id = mcp.maintenance_contract_id
    WHERE mcp.project_id = v_contract.pending_project_id
      AND other_mc.id <> v_contract.id
      AND public.is_live_maintenance_contract_status(other_mc.estado)
  ) THEN
    RAISE EXCEPTION 'El proyecto solicitado ya está ocupado por otro mantenimiento activo o pausado';
  END IF;

  SELECT mcp.project_id
  INTO v_old_project_id
  FROM public.maintenance_contract_projects mcp
  WHERE mcp.maintenance_contract_id = v_contract.id
  ORDER BY mcp.created_at DESC
  LIMIT 1;

  IF v_old_project_id IS NULL THEN
    RAISE EXCEPTION 'El contrato no tiene un proyecto actual que sustituir';
  END IF;

  IF v_old_project_id = v_contract.pending_project_id THEN
    UPDATE public.maintenance_contracts
    SET
      pending_project_id = NULL,
      pending_project_change_effective_at = NULL,
      updated_at = CURRENT_TIMESTAMP
    WHERE id = v_contract.id;

    UPDATE public.maintenance_contract_project_change_requests
    SET
      status = 'applied',
      updated_at = CURRENT_TIMESTAMP
    WHERE id = v_request.id
    RETURNING *
    INTO v_request;

    RETURN v_request;
  END IF;

  -- Locks compatibles con 089.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'maintenance-contract:' || v_contract.id::TEXT,
      0
    )
  );

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'maintenance-project:' || v_old_project_id::TEXT,
      0
    )
  );

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'maintenance-project:' || v_contract.pending_project_id::TEXT,
      0
    )
  );

  -- Primero se elimina la relación viva anterior. La operación completa
  -- permanece dentro de esta misma transacción.
  DELETE FROM public.maintenance_contract_projects
  WHERE maintenance_contract_id = v_contract.id
    AND project_id = v_old_project_id;

  INSERT INTO public.maintenance_contract_projects (
    maintenance_contract_id,
    project_id
  )
  VALUES (
    v_contract.id,
    v_contract.pending_project_id
  );

  UPDATE public.maintenance_contracts
  SET
    pending_project_id = NULL,
    pending_project_change_effective_at = NULL,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_contract.id;

  UPDATE public.maintenance_contract_project_change_requests
  SET
    status = 'applied',
    updated_at = CURRENT_TIMESTAMP
  WHERE id = v_request.id
  RETURNING *
  INTO v_request;

  RETURN v_request;
END;
$function$;

REVOKE ALL
ON FUNCTION public.apply_maintenance_contract_project_change(UUID)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.apply_maintenance_contract_project_change(UUID)
TO service_role;


-- ============================================================================
-- 11. RLS — SOLICITUDES
-- ============================================================================

ALTER TABLE public.maintenance_contract_project_change_requests
ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS maintenance_project_change_requests_client_select
ON public.maintenance_contract_project_change_requests;

CREATE POLICY maintenance_project_change_requests_client_select
ON public.maintenance_contract_project_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND company_id = public.current_user_company_id()
);

DROP POLICY IF EXISTS maintenance_project_change_requests_client_select
ON public.maintenance_contract_project_change_requests;

CREATE POLICY maintenance_project_change_requests_client_select
ON public.maintenance_contract_project_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND company_id = public.current_user_company_id()
);

DROP POLICY IF EXISTS maintenance_project_change_requests_worker_select
ON public.maintenance_contract_project_change_requests;

CREATE POLICY maintenance_project_change_requests_worker_select
ON public.maintenance_contract_project_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
);

GRANT SELECT
ON public.maintenance_contract_project_change_requests
TO authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.maintenance_contract_project_change_requests
FROM authenticated, anon;


-- ============================================================================
-- 12. INVOICE → PROJECT SNAPSHOT
-- ============================================================================
--
-- Una maintenance_invoice históricamente representa un periodo de un contrato.
-- Añadimos project_id para que el periodo conserve explícitamente qué proyecto
-- estaba cubierto, incluso si el contrato cambia de proyecto posteriormente.
-- ============================================================================

ALTER TABLE public.maintenance_invoices
  ADD COLUMN IF NOT EXISTS project_id UUID;

ALTER TABLE public.maintenance_invoices
  DROP CONSTRAINT IF EXISTS maintenance_invoices_project_id_fkey;

ALTER TABLE public.maintenance_invoices
  ADD CONSTRAINT maintenance_invoices_project_id_fkey
  FOREIGN KEY (project_id)
  REFERENCES public.projects(id)
  ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS
  idx_maintenance_invoices_project
ON public.maintenance_invoices (project_id);

-- No hacemos un backfill ciego de facturas históricas porque 089 permite que
-- contratos históricos conserven relaciones antiguas. Una factura antigua
-- puede no tener una correspondencia inequívoca con una única relación.
-- Las nuevas facturas generadas por la Edge Function deberán guardar
-- maintenance_invoices.project_id explícitamente.


-- ============================================================================
-- 13. VALIDACIÓN DE PROJECT_ID EN MAINTENANCE_INVOICES
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validate_maintenance_invoice_project()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_contract_company_id UUID;
  v_project_company_id UUID;
BEGIN
  IF NEW.project_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.maintenance_contract_id IS NULL THEN
    RAISE EXCEPTION
      'Una factura de mantenimiento con project_id debe tener maintenance_contract_id';
  END IF;

  SELECT company_id
  INTO v_contract_company_id
  FROM public.maintenance_contracts
  WHERE id = NEW.maintenance_contract_id;

  IF v_contract_company_id IS NULL THEN
    RAISE EXCEPTION
      'El contrato de mantenimiento de la factura no existe o no tiene empresa';
  END IF;

  SELECT company_id
  INTO v_project_company_id
  FROM public.projects
  WHERE id = NEW.project_id;

  IF v_project_company_id IS NULL THEN
    RAISE EXCEPTION
      'El proyecto de la factura no existe o no tiene empresa';
  END IF;

  IF v_project_company_id IS DISTINCT FROM v_contract_company_id THEN
    RAISE EXCEPTION
      'El proyecto de la factura no pertenece a la misma empresa que el contrato';
  END IF;

  -- Para una factura de un periodo nuevo exigimos que el proyecto esté
  -- asociado al contrato en el momento de emisión.
  IF NOT EXISTS (
    SELECT 1
    FROM public.maintenance_contract_projects mcp
    WHERE mcp.maintenance_contract_id = NEW.maintenance_contract_id
      AND mcp.project_id = NEW.project_id
  ) THEN
    RAISE EXCEPTION
      'El proyecto de la factura no está asociado al contrato de mantenimiento';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL
ON FUNCTION public.validate_maintenance_invoice_project()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.validate_maintenance_invoice_project()
TO service_role;

DROP TRIGGER IF EXISTS
  maintenance_invoices_validate_project
ON public.maintenance_invoices;

CREATE TRIGGER
  maintenance_invoices_validate_project
BEFORE INSERT OR UPDATE OF project_id, maintenance_contract_id
ON public.maintenance_invoices
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_invoice_project();


-- ============================================================================
-- 14. PROTEGER project_id DE FACTURAS YA EMITIDAS
-- ============================================================================

CREATE OR REPLACE FUNCTION public.protect_maintenance_invoice_project_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF OLD.estado <> 'borrador'
     AND NEW.project_id IS DISTINCT FROM OLD.project_id
  THEN
    RAISE EXCEPTION
      'No se puede modificar el proyecto histórico de una factura de mantenimiento ya emitida';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL
ON FUNCTION public.protect_maintenance_invoice_project_snapshot()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.protect_maintenance_invoice_project_snapshot()
TO service_role;

DROP TRIGGER IF EXISTS
  maintenance_invoices_project_snapshot_protection
ON public.maintenance_invoices;

CREATE TRIGGER
  maintenance_invoices_project_snapshot_protection
BEFORE UPDATE OF project_id
ON public.maintenance_invoices
FOR EACH ROW
EXECUTE FUNCTION public.protect_maintenance_invoice_project_snapshot();


-- ============================================================================
-- 15. RATE LIMIT ESPECÍFICO PARA CAMBIOS DE PLAN — FUNCIÓN AUXILIAR
-- ============================================================================
--
-- La Edge Function request_plan_change debe consumir:
--
--   consume_maintenance_change_rate_limit(
--     company_id,
--     'maintenance_plan_change',
--     1,
--     604800
--   )
--
-- antes de crear/modificar el Stripe Subscription Schedule.
--
-- La migración NO modifica Stripe.
-- ============================================================================


-- ============================================================================
-- 16. UPDATED_AT
-- ============================================================================

DROP TRIGGER IF EXISTS
  maintenance_contract_project_change_requests_updated_at
ON public.maintenance_contract_project_change_requests;

CREATE TRIGGER
  maintenance_contract_project_change_requests_updated_at
BEFORE UPDATE
ON public.maintenance_contract_project_change_requests
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================================
-- 17. PRIVILEGIOS SERVICE_ROLE
-- ============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.maintenance_contract_project_change_requests
TO service_role;


-- ============================================================================
-- 18. VERIFICACIONES FINALES
-- ============================================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_contracts'
    AND column_name = 'pending_project_id';

  IF v_count <> 1 THEN
    RAISE EXCEPTION '091 failed: pending_project_id no existe';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_contracts'
    AND column_name = 'pending_project_change_effective_at';

  IF v_count <> 1 THEN
    RAISE EXCEPTION '091 failed: pending_project_change_effective_at no existe';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_contract_project_change_requests';

  IF v_count <> 1 THEN
    RAISE EXCEPTION '091 failed: tabla de solicitudes no existe';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_invoices'
    AND column_name = 'project_id';

  IF v_count <> 1 THEN
    RAISE EXCEPTION '091 failed: maintenance_invoices.project_id no existe';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname = 'consume_maintenance_change_rate_limit';

  IF v_count <> 1 THEN
    RAISE EXCEPTION '091 failed: rate limit de cambios de mantenimiento no existe';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname = 'request_maintenance_contract_project_change';

  IF v_count <> 1 THEN
    RAISE EXCEPTION '091 failed: RPC de solicitud de cambio de proyecto no existe';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname = 'approve_maintenance_contract_project_change';

  IF v_count <> 1 THEN
    RAISE EXCEPTION '091 failed: RPC de aprobación de cambio de proyecto no existe';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname = 'apply_maintenance_contract_project_change';

  IF v_count <> 1 THEN
    RAISE EXCEPTION '091 failed: RPC de aplicación de cambio de proyecto no existe';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
