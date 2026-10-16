-- ============================================================
-- MODIRA — 071_maintenance_contract_project_assignment.sql
-- ============================================================
--
-- DEPENDENCIAS:
--   049  -> maintenance_contract_projects
--   068  -> billing failure policy
--   069  -> custom maintenance proposals
--   070  -> custom proposal security limits
--
-- OBJETIVO:
--   1. Mantener maintenance_contract_projects como relación N:N.
--   2. Permitir que un contrato tenga 0, 1 o varios proyectos.
--   3. Permitir al cliente asociar/desasociar proyectos de su contrato.
--   4. Permitir al worker asociar/desasociar proyectos de cualquier contrato.
--   5. No hacer obligatoria ninguna asociación.
--   6. Validar siempre que contrato y proyecto pertenecen a la misma empresa.
--   7. No conceder INSERT/UPDATE/DELETE directo sobre la tabla de relación.
--
-- IMPORTANTE:
--   El selector de proyecto durante el checkout NO se resuelve solo con SQL.
--   La Edge Function maintenance-stripe debe:
--     - aceptar project_id opcional;
--     - validar el proyecto;
--     - conservar modira_project_id en los metadatos Stripe;
--     - crear la fila de relación cuando cree el contrato.
--
--   Esto debe aplicarse tanto al flujo de planes fijos como al flujo Custom
--   de las migraciones 069/070.
--
--   Si no se selecciona proyecto, NO se crea ninguna fila.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. PRECONDICIONES
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contracts'
  ) THEN
    RAISE EXCEPTION
      '071 stopped: public.maintenance_contracts does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contract_projects'
  ) THEN
    RAISE EXCEPTION
      '071 stopped: public.maintenance_contract_projects does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'projects'
  ) THEN
    RAISE EXCEPTION
      '071 stopped: public.projects does not exist';
  END IF;
END
$$;


-- ============================================================
-- 2. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contract_projects_contract_project
ON public.maintenance_contract_projects (
  maintenance_contract_id,
  project_id
);

CREATE INDEX IF NOT EXISTS
  idx_maintenance_contract_projects_project_contract
ON public.maintenance_contract_projects (
  project_id,
  maintenance_contract_id
);


-- ============================================================
-- 3. RPC — CLIENTE ASOCIA UN PROYECTO
-- ============================================================
--
-- El cliente:
--   - debe estar autenticado y activo;
--   - no puede ser worker;
--   - solo puede operar sobre contratos de su empresa;
--   - solo puede asociar proyectos de esa misma empresa.
--
-- La asociación es idempotente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.assign_maintenance_contract_project(
  p_contract_id UUID,
  p_project_id UUID
)
RETURNS public.maintenance_contract_projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
  v_contract public.maintenance_contracts;
  v_project public.projects;
  v_row public.maintenance_contract_projects;

BEGIN

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'El usuario no está activo';
  END IF;

  IF public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Un worker debe utilizar la RPC de gestión de mantenimiento';
  END IF;


  -- ----------------------------------------------------------
  -- CONTRATO
  -- ----------------------------------------------------------

  SELECT *
  INTO v_contract
  FROM public.maintenance_contracts
  WHERE id = p_contract_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'El contrato de mantenimiento no existe';
  END IF;

  IF v_contract.company_id IS DISTINCT FROM public.current_user_company_id() THEN
    RAISE EXCEPTION
      'El contrato no pertenece a la empresa del usuario actual';
  END IF;


  -- ----------------------------------------------------------
  -- PROYECTO
  -- ----------------------------------------------------------

  SELECT *
  INTO v_project
  FROM public.projects
  WHERE id = p_project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'El proyecto no existe';
  END IF;

  IF v_project.company_id IS NULL
     OR v_project.company_id IS DISTINCT FROM v_contract.company_id
  THEN
    RAISE EXCEPTION
      'El proyecto no pertenece a la empresa del contrato';
  END IF;


  -- ----------------------------------------------------------
  -- ASOCIACIÓN IDEMPOTENTE
  -- ----------------------------------------------------------

  INSERT INTO public.maintenance_contract_projects (
    maintenance_contract_id,
    project_id
  )
  VALUES (
    p_contract_id,
    p_project_id
  )
  ON CONFLICT (
    maintenance_contract_id,
    project_id
  )
  DO NOTHING
  RETURNING *
  INTO v_row;


  -- Si ya existía, devolvemos la fila existente.
  IF v_row.id IS NULL THEN
    SELECT *
    INTO v_row
    FROM public.maintenance_contract_projects
    WHERE maintenance_contract_id = p_contract_id
      AND project_id = p_project_id;
  END IF;

  RETURN v_row;

END;
$function$;


REVOKE ALL
ON FUNCTION public.assign_maintenance_contract_project(UUID, UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.assign_maintenance_contract_project(UUID, UUID)
TO authenticated;


-- ============================================================
-- 4. RPC — CLIENTE DESASOCIA UN PROYECTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.unassign_maintenance_contract_project(
  p_contract_id UUID,
  p_project_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
  v_company_id UUID;

BEGIN

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'El usuario no está activo';
  END IF;

  IF public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Un worker debe utilizar la RPC de gestión de mantenimiento';
  END IF;


  SELECT company_id
  INTO v_company_id
  FROM public.maintenance_contracts
  WHERE id = p_contract_id;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION
      'El contrato de mantenimiento no existe';
  END IF;

  IF v_company_id IS DISTINCT FROM public.current_user_company_id() THEN
    RAISE EXCEPTION
      'El contrato no pertenece a la empresa del usuario actual';
  END IF;


  DELETE FROM public.maintenance_contract_projects
  WHERE maintenance_contract_id = p_contract_id
    AND project_id = p_project_id;

  RETURN FOUND;

END;
$function$;


REVOKE ALL
ON FUNCTION public.unassign_maintenance_contract_project(UUID, UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.unassign_maintenance_contract_project(UUID, UUID)
TO authenticated;


-- ============================================================
-- 5. RPC — WORKER ASOCIA UN PROYECTO
-- ============================================================
--
-- Los workers pueden gestionar contratos de mantenimiento.
-- La protección importante aquí es la pertenencia del proyecto
-- a la misma empresa del contrato.
-- ============================================================

CREATE OR REPLACE FUNCTION public.worker_assign_maintenance_contract_project(
  p_contract_id UUID,
  p_project_id UUID
)
RETURNS public.maintenance_contract_projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
  v_contract public.maintenance_contracts;
  v_project public.projects;
  v_row public.maintenance_contract_projects;

BEGIN

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'El usuario no está activo';
  END IF;

  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Solo un worker puede utilizar esta operación';
  END IF;


  -- ----------------------------------------------------------
  -- CONTRATO
  -- ----------------------------------------------------------

  SELECT *
  INTO v_contract
  FROM public.maintenance_contracts
  WHERE id = p_contract_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'El contrato de mantenimiento no existe';
  END IF;


  -- ----------------------------------------------------------
  -- PROYECTO
  -- ----------------------------------------------------------

  SELECT *
  INTO v_project
  FROM public.projects
  WHERE id = p_project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'El proyecto no existe';
  END IF;

  IF v_project.company_id IS NULL
     OR v_project.company_id IS DISTINCT FROM v_contract.company_id
  THEN
    RAISE EXCEPTION
      'El proyecto no pertenece a la empresa del contrato';
  END IF;


  -- ----------------------------------------------------------
  -- ASOCIACIÓN IDEMPOTENTE
  -- ----------------------------------------------------------

  INSERT INTO public.maintenance_contract_projects (
    maintenance_contract_id,
    project_id
  )
  VALUES (
    p_contract_id,
    p_project_id
  )
  ON CONFLICT (
    maintenance_contract_id,
    project_id
  )
  DO NOTHING
  RETURNING *
  INTO v_row;


  IF v_row.id IS NULL THEN
    SELECT *
    INTO v_row
    FROM public.maintenance_contract_projects
    WHERE maintenance_contract_id = p_contract_id
      AND project_id = p_project_id;
  END IF;

  RETURN v_row;

END;
$function$;


REVOKE ALL
ON FUNCTION public.worker_assign_maintenance_contract_project(UUID, UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.worker_assign_maintenance_contract_project(UUID, UUID)
TO authenticated;


-- ============================================================
-- 6. RPC — WORKER DESASOCIA UN PROYECTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.worker_unassign_maintenance_contract_project(
  p_contract_id UUID,
  p_project_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

BEGIN

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'El usuario no está activo';
  END IF;

  IF NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION
      'Solo un worker puede utilizar esta operación';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM public.maintenance_contracts
    WHERE id = p_contract_id
  ) THEN
    RAISE EXCEPTION
      'El contrato de mantenimiento no existe';
  END IF;


  DELETE FROM public.maintenance_contract_projects
  WHERE maintenance_contract_id = p_contract_id
    AND project_id = p_project_id;

  RETURN FOUND;

END;
$function$;


REVOKE ALL
ON FUNCTION public.worker_unassign_maintenance_contract_project(UUID, UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.worker_unassign_maintenance_contract_project(UUID, UUID)
TO authenticated;


-- ============================================================
-- 7. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.maintenance_contract_projects IS
'Relación N:N opcional entre contratos de mantenimiento y proyectos. Un contrato puede tener cero, uno o varios proyectos. La escritura se realiza mediante RPC seguras.';

COMMENT ON FUNCTION public.assign_maintenance_contract_project(UUID, UUID) IS
'Permite al cliente activo asociar opcionalmente un proyecto de su empresa a su contrato de mantenimiento.';

COMMENT ON FUNCTION public.unassign_maintenance_contract_project(UUID, UUID) IS
'Permite al cliente activo retirar una asociación proyecto-contrato de su empresa.';

COMMENT ON FUNCTION public.worker_assign_maintenance_contract_project(UUID, UUID) IS
'Permite a un worker asociar un proyecto de la misma empresa a un contrato de mantenimiento.';

COMMENT ON FUNCTION public.worker_unassign_maintenance_contract_project(UUID, UUID) IS
'Permite a un worker retirar una asociación proyecto-contrato.';


-- ============================================================
-- 8. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN

  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_contract_projects'
    AND column_name = 'maintenance_contract_id';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '071 failed: maintenance_contract_projects.maintenance_contract_id missing';
  END IF;


  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'maintenance_contract_projects'
    AND column_name = 'project_id';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '071 failed: maintenance_contract_projects.project_id missing';
  END IF;


  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n
    ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'assign_maintenance_contract_project'
    AND pg_get_function_identity_arguments(p.oid)
        = 'p_contract_id uuid, p_project_id uuid';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '071 failed: client assignment RPC missing';
  END IF;


  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n
    ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'worker_assign_maintenance_contract_project'
    AND pg_get_function_identity_arguments(p.oid)
        = 'p_contract_id uuid, p_project_id uuid';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '071 failed: worker assignment RPC missing';
  END IF;

END
$$;

COMMIT;


-- ============================================================
-- INTEGRACIÓN OBLIGATORIA CON maintenance-stripe
-- ============================================================
--
-- ESTA PARTE NO ES SQL Y NO SE EJECUTA EN SUPABASE.
--
-- La Edge Function maintenance-stripe debe modificarse para que:
--
-- A) PLANES FIJOS — create_checkout_session
--
--    1. Lea body.project_id como UUID opcional.
--    2. Si viene informado:
--         - compruebe que projects.id existe;
--         - compruebe que projects.company_id = companyId;
--         - rechace cualquier proyecto de otra empresa.
--    3. Añada:
--
--         modira_project_id: projectId
--
--       a subscription_data.metadata y metadata de Checkout.
--
--
-- B) PLAN CUSTOM — acceptCustomMaintenanceProposal
--
--    Debe aplicar exactamente la misma validación de project_id.
--
--    También debe conservar:
--
--         modira_project_id: projectId
--
--    junto con modira_custom_proposal_id.
--
--
-- C) CREACIÓN DEL CONTRATO — createOrGetContractFromSubscription
--
--    1. Leer:
--
--         metadata.modira_project_id
--
--    2. Validarlo nuevamente contra maintenance_contracts.company_id
--       y projects.company_id.
--
--    3. Después de crear maintenance_contracts:
--
--         INSERT INTO public.maintenance_contract_projects (
--             maintenance_contract_id,
--             project_id
--         )
--         VALUES (contract.id, projectId)
--         ON CONFLICT DO NOTHING;
--
--    4. Si no existe modira_project_id:
--         no insertar ninguna fila.
--
--    5. Esto debe aplicarse tanto a contratos fijos como Custom.
--
-- La selección del proyecto durante el checkout es, por tanto, opcional.
-- ============================================================
