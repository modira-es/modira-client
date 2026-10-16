-- ============================================================
-- MODIRA — 105_rbac_maintenance.sql
-- ============================================================
-- RBAC DEL MÓDULO DE MANTENIMIENTO
--
-- Direction:
--   maintenance.* + maintenance_proposals.*
--
-- Commercial:
--   maintenance.* + maintenance_proposals.*
--
-- Developer:
--   sin acceso al módulo
--
-- Support:
--   sin acceso al módulo
--
-- Accounting:
--   maintenance.read
--
-- IMPORTANTE:
-- - No se conceden escrituras directas sobre las tablas.
-- - maintenance_contracts, maintenance_invoices, etc. mantienen
--   su arquitectura backend/service_role.
-- - Solo se sustituye el acceso genérico worker SELECT por RBAC.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

  -- ----------------------------------------------------------
  -- TABLAS PRINCIPALES
  -- ----------------------------------------------------------

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_plans'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_plans no existe';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contracts'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_contracts no existe';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contract_projects'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_contract_projects no existe';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contract_automations'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_contract_automations no existe';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_invoices'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_invoices no existe';
  END IF;


  -- ----------------------------------------------------------
  -- PROPUESTAS PERSONALIZADAS
  -- ----------------------------------------------------------

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_custom_proposals'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_custom_proposals no existe';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_custom_proposal_documents'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_custom_proposal_documents no existe';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_custom_proposal_events'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_custom_proposal_events no existe';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_custom_proposal_document_acknowledgements'
  ) THEN
    RAISE EXCEPTION
      '105 failed: maintenance_custom_proposal_document_acknowledgements no existe';
  END IF;


  -- ----------------------------------------------------------
  -- PERMISOS RBAC
  -- ----------------------------------------------------------

  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'maintenance.read'
  ) THEN
    RAISE EXCEPTION
      '105 failed: falta maintenance.read';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'maintenance.create'
  ) THEN
    RAISE EXCEPTION
      '105 failed: falta maintenance.create';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'maintenance.update'
  ) THEN
    RAISE EXCEPTION
      '105 failed: falta maintenance.update';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'maintenance.delete'
  ) THEN
    RAISE EXCEPTION
      '105 failed: falta maintenance.delete';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'maintenance_proposals.read'
  ) THEN
    RAISE EXCEPTION
      '105 failed: falta maintenance_proposals.read';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'maintenance_proposals.create'
  ) THEN
    RAISE EXCEPTION
      '105 failed: falta maintenance_proposals.create';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'maintenance_proposals.update'
  ) THEN
    RAISE EXCEPTION
      '105 failed: falta maintenance_proposals.update';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_permissions
    WHERE code = 'maintenance_proposals.delete'
  ) THEN
    RAISE EXCEPTION
      '105 failed: falta maintenance_proposals.delete';
  END IF;


  IF to_regprocedure(
    'public.current_worker_has_permission(text)'
  ) IS NULL THEN
    RAISE EXCEPTION
      '105 failed: current_worker_has_permission(text) no existe';
  END IF;

END $$;


-- ============================================================
-- 2. ASIGNACIÓN DE PERMISOS
-- ============================================================
--
-- Direction → mantenimiento completo
-- Commercial → mantenimiento completo
--
-- Accounting → solo lectura
--
-- Developer / Support → sin permisos
-- ============================================================

INSERT INTO public.worker_role_permissions (
  role_id,
  permission_id
)
SELECT
  wr.id,
  wp.id
FROM public.worker_roles wr
CROSS JOIN public.worker_permissions wp
WHERE wr.code IN ('direction', 'commercial')
  AND wp.code IN (
    'maintenance.read',
    'maintenance.create',
    'maintenance.update',
    'maintenance.delete',
    'maintenance_proposals.read',
    'maintenance_proposals.create',
    'maintenance_proposals.update',
    'maintenance_proposals.delete'
  )
ON CONFLICT DO NOTHING;


-- Accounting solo lectura del módulo de mantenimiento.
INSERT INTO public.worker_role_permissions (
  role_id,
  permission_id
)
SELECT
  wr.id,
  wp.id
FROM public.worker_roles wr
CROSS JOIN public.worker_permissions wp
WHERE wr.code = 'accounting'
  AND wp.code = 'maintenance.read'
ON CONFLICT DO NOTHING;


-- ============================================================
-- 3. MAINTENANCE CONTRACTS
-- ============================================================

ALTER TABLE public.maintenance_contracts
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_contracts_worker_select
ON public.maintenance_contracts;


DROP POLICY IF EXISTS maintenance_contracts_rbac_select
ON public.maintenance_contracts;


CREATE POLICY maintenance_contracts_rbac_select
ON public.maintenance_contracts
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance.read'
  )
);


-- ============================================================
-- 4. MAINTENANCE PLANS
-- ============================================================

ALTER TABLE public.maintenance_plans
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_plans_worker_select
ON public.maintenance_plans;


DROP POLICY IF EXISTS maintenance_plans_rbac_select
ON public.maintenance_plans;


CREATE POLICY maintenance_plans_rbac_select
ON public.maintenance_plans
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance.read'
  )
);


-- ============================================================
-- 5. CONTRACT ↔ PROJECTS
-- ============================================================

ALTER TABLE public.maintenance_contract_projects
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_contract_projects_worker_select
ON public.maintenance_contract_projects;


DROP POLICY IF EXISTS maintenance_contract_projects_rbac_select
ON public.maintenance_contract_projects;


CREATE POLICY maintenance_contract_projects_rbac_select
ON public.maintenance_contract_projects
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance.read'
  )
);


-- ============================================================
-- 6. CONTRACT ↔ AUTOMATIONS
-- ============================================================

ALTER TABLE public.maintenance_contract_automations
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_contract_automations_worker_select
ON public.maintenance_contract_automations;


DROP POLICY IF EXISTS maintenance_contract_automations_rbac_select
ON public.maintenance_contract_automations;


CREATE POLICY maintenance_contract_automations_rbac_select
ON public.maintenance_contract_automations
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance.read'
  )
);


-- ============================================================
-- 7. MAINTENANCE INVOICES
-- ============================================================
--
-- Los workers con maintenance.read pueden consultar las
-- facturas de mantenimiento.
--
-- No se conceden INSERT/UPDATE/DELETE.
-- La creación y gestión continúa en backend/service_role.
-- ============================================================

ALTER TABLE public.maintenance_invoices
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_invoices_worker_select
ON public.maintenance_invoices;


DROP POLICY IF EXISTS maintenance_invoices_rbac_select
ON public.maintenance_invoices;


CREATE POLICY maintenance_invoices_rbac_select
ON public.maintenance_invoices
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance.read'
  )
);


-- ============================================================
-- 8. SOLICITUDES DE CAMBIO DE PROYECTO
-- ============================================================

ALTER TABLE public.maintenance_contract_project_change_requests
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_project_change_requests_worker_select
ON public.maintenance_contract_project_change_requests;


DROP POLICY IF EXISTS maintenance_project_change_requests_rbac_select
ON public.maintenance_contract_project_change_requests;


CREATE POLICY maintenance_project_change_requests_rbac_select
ON public.maintenance_contract_project_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance.read'
  )
);


-- ============================================================
-- 9. SOLICITUDES IVA
-- ============================================================

ALTER TABLE public.maintenance_iva_change_requests
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_iva_change_requests_worker_select
ON public.maintenance_iva_change_requests;


DROP POLICY IF EXISTS maintenance_iva_requests_worker_select
ON public.maintenance_iva_change_requests;


DROP POLICY IF EXISTS maintenance_iva_change_requests_rbac_select
ON public.maintenance_iva_change_requests;


CREATE POLICY maintenance_iva_change_requests_rbac_select
ON public.maintenance_iva_change_requests
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance.read'
  )
);


-- ============================================================
-- 10. PROPUESTAS PERSONALIZADAS
-- ============================================================
--
-- Estas utilizan permisos separados:
-- maintenance_proposals.*
--
-- Direction + Commercial → acceso completo
-- ============================================================

ALTER TABLE public.maintenance_custom_proposals
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_custom_proposals_worker_select
ON public.maintenance_custom_proposals;


DROP POLICY IF EXISTS maintenance_custom_proposals_rbac_select
ON public.maintenance_custom_proposals;


CREATE POLICY maintenance_custom_proposals_rbac_select
ON public.maintenance_custom_proposals
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance_proposals.read'
  )
);


-- ============================================================
-- 11. DOCUMENTOS DE PROPUESTAS
-- ============================================================

ALTER TABLE public.maintenance_custom_proposal_documents
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_custom_proposal_documents_worker_select
ON public.maintenance_custom_proposal_documents;


DROP POLICY IF EXISTS maintenance_custom_proposal_documents_rbac_select
ON public.maintenance_custom_proposal_documents;


CREATE POLICY maintenance_custom_proposal_documents_rbac_select
ON public.maintenance_custom_proposal_documents
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance_proposals.read'
  )
);


-- ============================================================
-- 12. EVENTOS DE PROPUESTAS
-- ============================================================

ALTER TABLE public.maintenance_custom_proposal_events
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_custom_proposal_events_worker_select
ON public.maintenance_custom_proposal_events;


DROP POLICY IF EXISTS maintenance_custom_proposal_events_rbac_select
ON public.maintenance_custom_proposal_events;


CREATE POLICY maintenance_custom_proposal_events_rbac_select
ON public.maintenance_custom_proposal_events
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance_proposals.read'
  )
);


-- ============================================================
-- 13. ACKNOWLEDGEMENTS DE DOCUMENTOS
-- ============================================================

ALTER TABLE public.maintenance_custom_proposal_document_acknowledgements
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS maintenance_custom_proposal_ack_worker_select
ON public.maintenance_custom_proposal_document_acknowledgements;


DROP POLICY IF EXISTS maintenance_custom_proposal_ack_rbac_select
ON public.maintenance_custom_proposal_document_acknowledgements;


CREATE POLICY maintenance_custom_proposal_ack_rbac_select
ON public.maintenance_custom_proposal_document_acknowledgements
FOR SELECT
TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission(
    'maintenance_proposals.read'
  )
);


-- ============================================================
-- 14. PRIVILEGIOS DE TABLA
-- ============================================================
--
-- Solo SELECT directo para authenticated.
-- Las escrituras sensibles continúan en backend/service_role.
-- ============================================================

GRANT SELECT
ON TABLE public.maintenance_plans
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_contracts
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_contract_projects
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_contract_automations
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_invoices
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_contract_project_change_requests
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_iva_change_requests
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_custom_proposals
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_custom_proposal_documents
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_custom_proposal_events
TO authenticated;

GRANT SELECT
ON TABLE public.maintenance_custom_proposal_document_acknowledgements
TO authenticated;


-- No damos escrituras directas.
REVOKE INSERT, UPDATE, DELETE
ON TABLE public.maintenance_plans,
           public.maintenance_contracts,
           public.maintenance_contract_projects,
           public.maintenance_contract_automations,
           public.maintenance_invoices,
           public.maintenance_contract_project_change_requests,
           public.maintenance_iva_change_requests,
           public.maintenance_custom_proposals,
           public.maintenance_custom_proposal_documents,
           public.maintenance_custom_proposal_events,
           public.maintenance_custom_proposal_document_acknowledgements
FROM authenticated, anon;


-- ============================================================
-- 15. VERIFICACIONES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN

  -- Deben existir exactamente los 4 permisos de maintenance
  SELECT COUNT(*)
  INTO v_count
  FROM public.worker_permissions
  WHERE code IN (
    'maintenance.read',
    'maintenance.create',
    'maintenance.update',
    'maintenance.delete'
  );

  IF v_count <> 4 THEN
    RAISE EXCEPTION
      '105 failed: permisos maintenance incompletos';
  END IF;


  -- Deben existir los 4 permisos de propuestas
  SELECT COUNT(*)
  INTO v_count
  FROM public.worker_permissions
  WHERE code IN (
    'maintenance_proposals.read',
    'maintenance_proposals.create',
    'maintenance_proposals.update',
    'maintenance_proposals.delete'
  );

  IF v_count <> 4 THEN
    RAISE EXCEPTION
      '105 failed: permisos maintenance_proposals incompletos';
  END IF;


  -- Las políticas genéricas antiguas deben haber desaparecido.
  IF EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND policyname IN (
        'maintenance_contracts_worker_select',
        'maintenance_plans_worker_select',
        'maintenance_contract_projects_worker_select',
        'maintenance_contract_automations_worker_select',
        'maintenance_invoices_worker_select',
        'maintenance_project_change_requests_worker_select',
        'maintenance_iva_change_requests_worker_select',
        'maintenance_iva_requests_worker_select',
        'maintenance_custom_proposals_worker_select',
        'maintenance_custom_proposal_documents_worker_select',
        'maintenance_custom_proposal_events_worker_select',
        'maintenance_custom_proposal_ack_worker_select'
      )
  ) THEN
    RAISE EXCEPTION
      '105 failed: todavía existe alguna policy worker genérica de maintenance';
  END IF;


  -- Policies RBAC principales.
  SELECT COUNT(*)
  INTO v_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND policyname IN (
      'maintenance_contracts_rbac_select',
      'maintenance_plans_rbac_select',
      'maintenance_contract_projects_rbac_select',
      'maintenance_contract_automations_rbac_select',
      'maintenance_invoices_rbac_select',
      'maintenance_project_change_requests_rbac_select',
      'maintenance_iva_change_requests_rbac_select',
      'maintenance_custom_proposals_rbac_select',
      'maintenance_custom_proposal_documents_rbac_select',
      'maintenance_custom_proposal_events_rbac_select',
      'maintenance_custom_proposal_ack_rbac_select'
    );

  IF v_count <> 11 THEN
    RAISE EXCEPTION
      '105 failed: no se han creado todas las policies RBAC de maintenance';
  END IF;


  -- Direction debe tener los 8 permisos.
  SELECT COUNT(*)
  INTO v_count
  FROM public.worker_role_permissions wrp
  JOIN public.worker_roles wr
    ON wr.id = wrp.role_id
  JOIN public.worker_permissions wp
    ON wp.id = wrp.permission_id
  WHERE wr.code = 'direction'
    AND wp.code IN (
      'maintenance.read',
      'maintenance.create',
      'maintenance.update',
      'maintenance.delete',
      'maintenance_proposals.read',
      'maintenance_proposals.create',
      'maintenance_proposals.update',
      'maintenance_proposals.delete'
    );

  IF v_count <> 8 THEN
    RAISE EXCEPTION
      '105 failed: Direction no tiene los 8 permisos de maintenance';
  END IF;


  -- Commercial debe tener los 8 permisos.
  SELECT COUNT(*)
  INTO v_count
  FROM public.worker_role_permissions wrp
  JOIN public.worker_roles wr
    ON wr.id = wrp.role_id
  JOIN public.worker_permissions wp
    ON wp.id = wrp.permission_id
  WHERE wr.code = 'commercial'
    AND wp.code IN (
      'maintenance.read',
      'maintenance.create',
      'maintenance.update',
      'maintenance.delete',
      'maintenance_proposals.read',
      'maintenance_proposals.create',
      'maintenance_proposals.update',
      'maintenance_proposals.delete'
    );

  IF v_count <> 8 THEN
    RAISE EXCEPTION
      '105 failed: Commercial no tiene los 8 permisos de maintenance';
  END IF;


  -- Accounting solo maintenance.read.
  IF NOT EXISTS (
    SELECT 1
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'accounting'
      AND wp.code = 'maintenance.read'
  ) THEN
    RAISE EXCEPTION
      '105 failed: Accounting no tiene maintenance.read';
  END IF;


  -- Developer no debe recibir permisos de maintenance.
  IF EXISTS (
    SELECT 1
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'developer'
      AND wp.code LIKE 'maintenance%'
  ) THEN
    RAISE EXCEPTION
      '105 failed: Developer tiene permisos de maintenance';
  END IF;


  -- Support no debe recibir permisos de maintenance.
  IF EXISTS (
    SELECT 1
    FROM public.worker_role_permissions wrp
    JOIN public.worker_roles wr
      ON wr.id = wrp.role_id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code = 'support'
      AND wp.code LIKE 'maintenance%'
  ) THEN
    RAISE EXCEPTION
      '105 failed: Support tiene permisos de maintenance';
  END IF;

END $$;


COMMIT;
