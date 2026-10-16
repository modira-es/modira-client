-- ============================================================
-- 082_maintenance_company_visibility.sql
-- ============================================================

BEGIN;


-- ============================================================
-- MAINTENANCE CONTRACTS
-- ============================================================

DROP POLICY IF EXISTS maintenance_contracts_client_select
ON public.maintenance_contracts;

CREATE POLICY maintenance_contracts_company_select
ON public.maintenance_contracts
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR company_id = public.current_user_company_id()
);


-- ============================================================
-- MAINTENANCE CONTRACT PROJECTS
-- ============================================================

DROP POLICY IF EXISTS maintenance_contract_projects_client_select
ON public.maintenance_contract_projects;

CREATE POLICY maintenance_contract_projects_company_select
ON public.maintenance_contract_projects
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR EXISTS (
        SELECT 1
        FROM public.maintenance_contracts mc
        WHERE mc.id = maintenance_contract_projects.contract_id
          AND mc.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- MAINTENANCE INVOICES
-- ============================================================

DROP POLICY IF EXISTS maintenance_invoices_client_select
ON public.maintenance_invoices;

CREATE POLICY maintenance_invoices_company_select
ON public.maintenance_invoices
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR company_id = public.current_user_company_id()
);


-- ============================================================
-- CUSTOM PROPOSALS
-- ============================================================

DROP POLICY IF EXISTS maintenance_custom_proposals_client_select
ON public.maintenance_custom_proposals;

CREATE POLICY maintenance_custom_proposals_company_select
ON public.maintenance_custom_proposals
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR company_id = public.current_user_company_id()
);


-- ============================================================
-- CUSTOM PROPOSAL DOCUMENTS
-- ============================================================

DROP POLICY IF EXISTS maintenance_custom_proposal_documents_client_select
ON public.maintenance_custom_proposal_documents;

CREATE POLICY maintenance_custom_proposal_documents_company_select
ON public.maintenance_custom_proposal_documents
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposals p
        WHERE p.id = maintenance_custom_proposal_documents.proposal_id
          AND p.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- CUSTOM PROPOSAL EVENTS
-- ============================================================

DROP POLICY IF EXISTS maintenance_custom_proposal_events_client_select
ON public.maintenance_custom_proposal_events;

CREATE POLICY maintenance_custom_proposal_events_company_select
ON public.maintenance_custom_proposal_events
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR EXISTS (
        SELECT 1
        FROM public.maintenance_custom_proposals p
        WHERE p.id = maintenance_custom_proposal_events.proposal_id
          AND p.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- ACKNOWLEDGEMENTS
-- ============================================================

DROP POLICY IF EXISTS
maintenance_custom_proposal_document_acknowledgements_client_select
ON public.maintenance_custom_proposal_document_acknowledgements;

CREATE POLICY
maintenance_custom_proposal_document_acknowledgements_company_select
ON public.maintenance_custom_proposal_document_acknowledgements
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR company_id = public.current_user_company_id()
);


COMMIT;