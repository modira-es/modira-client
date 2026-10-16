BEGIN;

-- ============================================================
-- 113 — WORKER RBAC FINAL HARDENING
-- ============================================================
--
-- OBJETIVO:
--   Aplicar el modelo de permisos por departamento sin modificar
--   la lógica funcional existente de las RPC.
--
-- IMPORTANTE:
--   - NO toca Storage.
--   - NO modifica las migraciones anteriores.
--   - NO utiliza REPLACE() sobre pg_get_functiondef().
--   - NO reescribe los cuerpos originales de las RPC.
--   - Conserva las funciones originales y coloca wrappers RBAC.
-- ============================================================


-- ============================================================
-- 1. PRECONDICIONES
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code = 'direction'
          AND is_active = TRUE
    ) THEN
        RAISE EXCEPTION
            '113 failed: role direction does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'projects.create'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission projects.create does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'projects.update'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission projects.update does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'project_milestones.create'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission project_milestones.create does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'project_milestones.update'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission project_milestones.update does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'project_milestones.delete'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission project_milestones.delete does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'project_updates.create'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission project_updates.create does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'project_updates.update'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission project_updates.update does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'project_updates.delete'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission project_updates.delete does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'companies.update'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission companies.update does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'system.workers.manage'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission system.workers.manage does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'quotations.update'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission quotations.update does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance.update'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission maintenance.update does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'support.update'
    ) THEN
        RAISE EXCEPTION
            '113 failed: permission support.update does not exist';
    END IF;

END;
$$;


-- ============================================================
-- 2. CORREGIR PERMISOS DEL ROL DEVELOPER
-- ============================================================
--
-- Developer:
--   support.read
--
-- NO:
--   support.create
--   support.update
--   support.delete
-- ============================================================

DELETE FROM public.worker_role_permissions wrp
USING public.worker_roles wr,
      public.worker_permissions wp
WHERE wrp.role_id = wr.id
  AND wrp.permission_id = wp.id
  AND wr.code = 'developer'
  AND wp.code IN (
      'support.create',
      'support.update',
      'support.delete'
  );


-- ============================================================
-- 3. CORREGIR PERMISOS DEL ROL ACCOUNTING
-- ============================================================
--
-- Accounting:
--   payments.read
--
-- NO:
--   payments.create
--   payments.update
--   payments.delete
-- ============================================================

DELETE FROM public.worker_role_permissions wrp
USING public.worker_roles wr,
      public.worker_permissions wp
WHERE wrp.role_id = wr.id
  AND wrp.permission_id = wp.id
  AND wr.code = 'accounting'
  AND wp.code IN (
      'payments.create',
      'payments.update',
      'payments.delete'
  );


-- ============================================================
-- 5. CORREGIR BYPASS DE SELECT EN INVOICES
-- ============================================================
--
-- La política anterior:
--
--   current_user_is_worker()
--   OR company_id = current_user_company_id()
--
-- permitía que CUALQUIER worker leyera invoices.
--
-- Ahora:
--   CLIENTE -> su empresa
--   WORKER  -> invoices.read mediante invoices_rbac_select
-- ============================================================

DROP POLICY IF EXISTS invoices_company_select
ON public.invoices;

CREATE POLICY invoices_company_select
ON public.invoices
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


-- ============================================================
-- 6. CORREGIR BYPASS DE SELECT EN QUOTATIONS
-- ============================================================
--
-- La política anterior permitía:
--
--   current_user_is_worker()
--
-- independientemente de quotations.read.
--
-- Ahora los workers entran exclusivamente por:
--
--   quotations_rbac_select
--
-- ============================================================

DROP POLICY IF EXISTS quotations_company_select
ON public.quotations;

CREATE POLICY quotations_company_select
ON public.quotations
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


-- ============================================================
-- 7. RPC — CREATE PROJECT
-- ============================================================
--
-- Renombramos la implementación original y dejamos el nombre
-- público para un wrapper RBAC.
-- ============================================================

ALTER FUNCTION public.create_project_by_worker(
    uuid,
    text,
    timestamptz,
    timestamptz
)
RENAME TO create_project_by_worker__legacy_113;


CREATE OR REPLACE FUNCTION public.create_project_by_worker(
    p_client_id uuid,
    p_descripcion text,
    p_fecha_inicio timestamptz DEFAULT CURRENT_TIMESTAMP,
    p_fecha_fin timestamptz DEFAULT NULL
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'projects.create'
    );

    RETURN public.create_project_by_worker__legacy_113(
        p_client_id,
        p_descripcion,
        p_fecha_inicio,
        p_fecha_fin
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.create_project_by_worker(
    uuid,
    text,
    timestamptz,
    timestamptz
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_project_by_worker(
    uuid,
    text,
    timestamptz,
    timestamptz
)
TO authenticated;


REVOKE ALL
ON FUNCTION public.create_project_by_worker__legacy_113(
    uuid,
    text,
    timestamptz,
    timestamptz
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 8. RPC — UPDATE PROJECT
-- ============================================================

ALTER FUNCTION public.update_project_by_worker(
    uuid,
    text,
    text
)
RENAME TO update_project_by_worker__legacy_113;


CREATE OR REPLACE FUNCTION public.update_project_by_worker(
    p_project_id uuid,
    p_nombre text DEFAULT NULL,
    p_estado text DEFAULT NULL
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'projects.update'
    );

    RETURN public.update_project_by_worker__legacy_113(
        p_project_id,
        p_nombre,
        p_estado
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.update_project_by_worker(
    uuid,
    text,
    text
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_project_by_worker(
    uuid,
    text,
    text
)
TO authenticated;

REVOKE ALL
ON FUNCTION public.update_project_by_worker__legacy_113(
    uuid,
    text,
    text
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 9. RPC — CREATE MILESTONE
-- ============================================================

ALTER FUNCTION public.create_project_milestone(
    uuid,
    text,
    text,
    timestamptz
)
RENAME TO create_project_milestone__legacy_113;


CREATE OR REPLACE FUNCTION public.create_project_milestone(
    p_project_id uuid,
    p_nombre text,
    p_descripcion text DEFAULT NULL,
    p_fecha_prevista timestamptz DEFAULT NULL
)
RETURNS public.project_milestones
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'project_milestones.create'
    );

    RETURN public.create_project_milestone__legacy_113(
        p_project_id,
        p_nombre,
        p_descripcion,
        p_fecha_prevista
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.create_project_milestone(
    uuid,
    text,
    text,
    timestamptz
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_project_milestone(
    uuid,
    text,
    text,
    timestamptz
)
TO authenticated;

REVOKE ALL
ON FUNCTION public.create_project_milestone__legacy_113(
    uuid,
    text,
    text,
    timestamptz
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 10. RPC — UPDATE MILESTONE
-- ============================================================

ALTER FUNCTION public.update_project_milestone(
    uuid,
    text,
    text,
    timestamptz,
    integer,
    text
)
RENAME TO update_project_milestone__legacy_113;


CREATE OR REPLACE FUNCTION public.update_project_milestone(
    p_milestone_id uuid,
    p_nombre text,
    p_descripcion text DEFAULT NULL,
    p_fecha_prevista timestamptz DEFAULT NULL,
    p_orden integer DEFAULT NULL,
    p_estado text DEFAULT NULL
)
RETURNS public.project_milestones
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'project_milestones.update'
    );

    RETURN public.update_project_milestone__legacy_113(
        p_milestone_id,
        p_nombre,
        p_descripcion,
        p_fecha_prevista,
        p_orden,
        p_estado
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.update_project_milestone(
    uuid,
    text,
    text,
    timestamptz,
    integer,
    text
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_project_milestone(
    uuid,
    text,
    text,
    timestamptz,
    integer,
    text
)
TO authenticated;

REVOKE ALL
ON FUNCTION public.update_project_milestone__legacy_113(
    uuid,
    text,
    text,
    timestamptz,
    integer,
    text
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 11. RPC — DELETE MILESTONE
-- ============================================================

ALTER FUNCTION public.delete_project_milestone(uuid)
RENAME TO delete_project_milestone__legacy_113;


CREATE OR REPLACE FUNCTION public.delete_project_milestone(
    p_milestone_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'project_milestones.delete'
    );

    PERFORM public.delete_project_milestone__legacy_113(
        p_milestone_id
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.delete_project_milestone(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_project_milestone(uuid)
TO authenticated;

REVOKE ALL
ON FUNCTION public.delete_project_milestone__legacy_113(uuid)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 12. RPC — CREATE PROJECT UPDATE
-- ============================================================

ALTER FUNCTION public.create_project_update(
    uuid,
    text,
    text
)
RENAME TO create_project_update__legacy_113;


CREATE OR REPLACE FUNCTION public.create_project_update(
    p_project_id uuid,
    p_titulo text,
    p_contenido text
)
RETURNS public.project_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'project_updates.create'
    );

    RETURN public.create_project_update__legacy_113(
        p_project_id,
        p_titulo,
        p_contenido
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.create_project_update(uuid, text, text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_project_update(uuid, text, text)
TO authenticated;

REVOKE ALL
ON FUNCTION public.create_project_update__legacy_113(
    uuid,
    text,
    text
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 13. RPC — UPDATE PROJECT UPDATE
-- ============================================================

ALTER FUNCTION public.update_project_update(
    uuid,
    text,
    text
)
RENAME TO update_project_update__legacy_113;


CREATE OR REPLACE FUNCTION public.update_project_update(
    p_update_id uuid,
    p_titulo text,
    p_contenido text
)
RETURNS public.project_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'project_updates.update'
    );

    RETURN public.update_project_update__legacy_113(
        p_update_id,
        p_titulo,
        p_contenido
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.update_project_update(uuid, text, text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_project_update(uuid, text, text)
TO authenticated;

REVOKE ALL
ON FUNCTION public.update_project_update__legacy_113(
    uuid,
    text,
    text
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 14. RPC — DELETE PROJECT UPDATE
-- ============================================================

ALTER FUNCTION public.delete_project_update(uuid)
RENAME TO delete_project_update__legacy_113;


CREATE OR REPLACE FUNCTION public.delete_project_update(
    p_update_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'project_updates.delete'
    );

    PERFORM public.delete_project_update__legacy_113(
        p_update_id
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.delete_project_update(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.delete_project_update(uuid)
TO authenticated;

REVOKE ALL
ON FUNCTION public.delete_project_update__legacy_113(uuid)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 15. RPC — ADMIN UPDATE PROFILE COMPANY
-- ============================================================
--
-- Cambiar la empresa de un cliente requiere companies.update.
-- ============================================================

ALTER FUNCTION public.admin_update_profile_company(
    uuid,
    uuid
)
RENAME TO admin_update_profile_company__legacy_113;


CREATE OR REPLACE FUNCTION public.admin_update_profile_company(
    p_user_id uuid,
    p_company_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'companies.update'
    );

    RETURN public.admin_update_profile_company__legacy_113(
        p_user_id,
        p_company_id
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.admin_update_profile_company(uuid, uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.admin_update_profile_company(uuid, uuid)
TO authenticated;

REVOKE ALL
ON FUNCTION public.admin_update_profile_company__legacy_113(
    uuid,
    uuid
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 16. RPC — RESOLVE COMPANY CHANGE REQUEST
-- ============================================================

ALTER FUNCTION public.resolve_company_change_request(
    uuid,
    text
)
RENAME TO resolve_company_change_request__legacy_113;


CREATE OR REPLACE FUNCTION public.resolve_company_change_request(
    p_request_id uuid,
    p_action text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'companies.update'
    );

    RETURN public.resolve_company_change_request__legacy_113(
        p_request_id,
        p_action
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.resolve_company_change_request(uuid, text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.resolve_company_change_request(uuid, text)
TO authenticated;

REVOKE ALL
ON FUNCTION public.resolve_company_change_request__legacy_113(
    uuid,
    text
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 17. RPC — SET PROFILE STATUS
-- ============================================================
--
-- Bloquear/desbloquear cuentas es una función de administración
-- de workers.
-- ============================================================

ALTER FUNCTION public.set_profile_status(
    uuid,
    text
)
RENAME TO set_profile_status__legacy_113;


CREATE OR REPLACE FUNCTION public.set_profile_status(
    p_user_id uuid,
    p_status text
)
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'system.workers.manage'
    );

    RETURN public.set_profile_status__legacy_113(
        p_user_id,
        p_status
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.set_profile_status(uuid, text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.set_profile_status(uuid, text)
TO authenticated;

REVOKE ALL
ON FUNCTION public.set_profile_status__legacy_113(
    uuid,
    text
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 18. RPC — RESPOND TO QUOTATION
-- ============================================================
--
-- IMPORTANTE:
-- Esta RPC NO se hace worker-only.
--
-- CLIENTE:
--   sigue pudiendo aceptar/rechazar su presupuesto.
--
-- WORKER:
--   solo puede responder si tiene quotations.update.
--
-- Esto conserva exactamente el flujo contractual existente.
-- ============================================================

ALTER FUNCTION public.respond_to_quotation(
    text,
    uuid
)
RENAME TO respond_to_quotation__legacy_113;


CREATE OR REPLACE FUNCTION public.respond_to_quotation(
    p_estado text,
    p_quotation_id uuid
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN

    IF public.current_user_is_worker() THEN

        PERFORM public.require_current_worker_permission(
            'quotations.update'
        );

    END IF;

    RETURN public.respond_to_quotation__legacy_113(
        p_estado,
        p_quotation_id
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.respond_to_quotation(text, uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.respond_to_quotation(text, uuid)
TO authenticated;

REVOKE ALL
ON FUNCTION public.respond_to_quotation__legacy_113(
    text,
    uuid
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 19. RPC — APPROVE MAINTENANCE CONTRACT PROJECT CHANGE
-- ============================================================

ALTER FUNCTION public.approve_maintenance_contract_project_change(uuid)
RENAME TO approve_maintenance_contract_project_change__legacy_113;


CREATE OR REPLACE FUNCTION public.approve_maintenance_contract_project_change(
    p_request_id uuid
)
RETURNS public.maintenance_contract_project_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance.update'
    );

    RETURN public.approve_maintenance_contract_project_change__legacy_113(
        p_request_id
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.approve_maintenance_contract_project_change(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.approve_maintenance_contract_project_change(uuid)
TO authenticated;

REVOKE ALL
ON FUNCTION public.approve_maintenance_contract_project_change__legacy_113(uuid)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 20. RPC — REJECT MAINTENANCE CONTRACT PROJECT CHANGE
-- ============================================================

ALTER FUNCTION public.reject_maintenance_contract_project_change(
    uuid,
    text
)
RENAME TO reject_maintenance_contract_project_change__legacy_113;


CREATE OR REPLACE FUNCTION public.reject_maintenance_contract_project_change(
    p_request_id uuid,
    p_reason text
)
RETURNS public.maintenance_contract_project_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance.update'
    );

    RETURN public.reject_maintenance_contract_project_change__legacy_113(
        p_request_id,
        p_reason
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.reject_maintenance_contract_project_change(uuid, text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.reject_maintenance_contract_project_change(uuid, text)
TO authenticated;

REVOKE ALL
ON FUNCTION public.reject_maintenance_contract_project_change__legacy_113(
    uuid,
    text
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 21. RPC — UPDATE MAINTENANCE CONTRACT IVA
-- ============================================================

ALTER FUNCTION public.update_maintenance_contract_iva(
    uuid,
    boolean,
    numeric
)
RENAME TO update_maintenance_contract_iva__legacy_113;


CREATE OR REPLACE FUNCTION public.update_maintenance_contract_iva(
    p_contract_id uuid,
    p_iva_aplicado boolean,
    p_iva_porcentaje numeric
)
RETURNS public.maintenance_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'maintenance.update'
    );

    RETURN public.update_maintenance_contract_iva__legacy_113(
        p_contract_id,
        p_iva_aplicado,
        p_iva_porcentaje
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.update_maintenance_contract_iva(
    uuid,
    boolean,
    numeric
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.update_maintenance_contract_iva(
    uuid,
    boolean,
    numeric
)
TO authenticated;

REVOKE ALL
ON FUNCTION public.update_maintenance_contract_iva__legacy_113(
    uuid,
    boolean,
    numeric
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 22. RPC — SET COMPANY IVA RECOMMENDATION
-- ============================================================

ALTER FUNCTION public.set_company_iva_recommendation(
    uuid,
    boolean,
    numeric
)
RENAME TO set_company_iva_recommendation__legacy_113;


CREATE OR REPLACE FUNCTION public.set_company_iva_recommendation(
    p_company_id uuid,
    p_iva_aplicado boolean,
    p_iva_porcentaje numeric
)
RETURNS public.companies
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'companies.update'
    );

    RETURN public.set_company_iva_recommendation__legacy_113(
        p_company_id,
        p_iva_aplicado,
        p_iva_porcentaje
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.set_company_iva_recommendation(
    uuid,
    boolean,
    numeric
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.set_company_iva_recommendation(
    uuid,
    boolean,
    numeric
)
TO authenticated;

REVOKE ALL
ON FUNCTION public.set_company_iva_recommendation__legacy_113(
    uuid,
    boolean,
    numeric
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 23. RPC — CLOSE SUPPORT TICKET
-- ============================================================

ALTER FUNCTION public.close_support_ticket(uuid)
RENAME TO close_support_ticket__legacy_113;


CREATE OR REPLACE FUNCTION public.close_support_ticket(
    p_ticket_id uuid
)
RETURNS public.support_tickets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'support.update'
    );

    RETURN public.close_support_ticket__legacy_113(
        p_ticket_id
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.close_support_ticket(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.close_support_ticket(uuid)
TO authenticated;

REVOKE ALL
ON FUNCTION public.close_support_ticket__legacy_113(uuid)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 24. ASEGURAR SEARCH_PATH DE TODOS LOS WRAPPERS
-- ============================================================

ALTER FUNCTION public.create_project_by_worker(
    uuid, text, timestamptz, timestamptz
)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.update_project_by_worker(
    uuid, text, text
)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.create_project_milestone(
    uuid, text, text, timestamptz
)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.update_project_milestone(
    uuid, text, text, timestamptz, integer, text
)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.delete_project_milestone(uuid)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.create_project_update(
    uuid, text, text
)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.update_project_update(
    uuid, text, text
)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.delete_project_update(uuid)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.admin_update_profile_company(uuid, uuid)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.resolve_company_change_request(uuid, text)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.set_profile_status(uuid, text)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.respond_to_quotation(text, uuid)
SET search_path TO 'public', 'extensions', 'pg_temp';

ALTER FUNCTION public.approve_maintenance_contract_project_change(uuid)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.reject_maintenance_contract_project_change(uuid, text)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.update_maintenance_contract_iva(uuid, boolean, numeric)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.set_company_iva_recommendation(uuid, boolean, numeric)
SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.close_support_ticket(uuid)
SET search_path TO 'public', 'pg_temp';


-- ============================================================
-- 25. VALIDACIONES FINALES
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- Debe existir al menos un worker activo con direction.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_assignments wra
        JOIN public.workers w
            ON w.auth_user_id = wra.worker_auth_user_id
        JOIN public.worker_roles wr
            ON wr.id = wra.role_id
        WHERE w.is_active = TRUE
          AND wr.code = 'direction'
          AND wr.is_active = TRUE
    ) THEN
        RAISE EXCEPTION
            '113 failed: no active worker has direction role';
    END IF;


    -- --------------------------------------------------------
    -- Developer no debe conservar escritura de soporte.
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
            ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
            ON wp.id = wrp.permission_id
        WHERE wr.code = 'developer'
          AND wp.code IN (
              'support.create',
              'support.update',
              'support.delete'
          )
    ) THEN
        RAISE EXCEPTION
            '113 failed: developer still has support write permissions';
    END IF;


    -- --------------------------------------------------------
    -- Accounting no debe conservar escritura de payments.
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions wrp
        JOIN public.worker_roles wr
            ON wr.id = wrp.role_id
        JOIN public.worker_permissions wp
            ON wp.id = wrp.permission_id
        WHERE wr.code = 'accounting'
          AND wp.code IN (
              'payments.create',
              'payments.update',
              'payments.delete'
          )
    ) THEN
        RAISE EXCEPTION
            '113 failed: accounting still has payment write permissions';
    END IF;


    -- --------------------------------------------------------
    -- Los wrappers deben ser SECURITY DEFINER.
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname IN (
              'create_project_by_worker',
              'update_project_by_worker',
              'create_project_milestone',
              'update_project_milestone',
              'delete_project_milestone',
              'create_project_update',
              'update_project_update',
              'delete_project_update',
              'admin_update_profile_company',
              'resolve_company_change_request',
              'set_profile_status',
              'respond_to_quotation',
              'approve_maintenance_contract_project_change',
              'reject_maintenance_contract_project_change',
              'update_maintenance_contract_iva',
              'set_company_iva_recommendation',
              'close_support_ticket'
          )
          AND p.prosecdef = FALSE
    ) THEN
        RAISE EXCEPTION
            '113 failed: one or more RBAC wrappers are not SECURITY DEFINER';
    END IF;

END;
$$;


-- ============================================================
-- 26. RECARGAR SCHEMA DE POSTGREST
-- ============================================================

NOTIFY pgrst, 'reload schema';


COMMIT;