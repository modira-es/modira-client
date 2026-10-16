-- ============================================================
-- 080_company_wide_read_visibility.sql
-- ============================================================

BEGIN;


-- ============================================================
-- PROJECTS
-- ============================================================

DROP POLICY IF EXISTS projects_select_policy
ON public.projects;

DROP POLICY IF EXISTS projects_client_select
ON public.projects;

CREATE POLICY projects_company_select
ON public.projects
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR (
        company_id IS NOT NULL
        AND company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- PROJECT DOCUMENTS
-- ============================================================

DROP POLICY IF EXISTS project_documents_select_policy
ON public.project_documents;

DROP POLICY IF EXISTS project_documents_client_select
ON public.project_documents;

CREATE POLICY project_documents_company_select
ON public.project_documents
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_documents.project_id
          AND p.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- PROJECT MILESTONES
-- ============================================================

DROP POLICY IF EXISTS project_milestones_select_policy
ON public.project_milestones;

CREATE POLICY project_milestones_company_select
ON public.project_milestones
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_milestones.project_id
          AND p.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- PROJECT UPDATES
-- ============================================================

DROP POLICY IF EXISTS project_updates_select_policy
ON public.project_updates;

CREATE POLICY project_updates_company_select
ON public.project_updates
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_updates.project_id
          AND p.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- PROJECT CHANGE REQUESTS
-- ============================================================

DROP POLICY IF EXISTS project_change_requests_select_policy
ON public.project_change_requests;

CREATE POLICY project_change_requests_company_select
ON public.project_change_requests
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR company_id = public.current_user_company_id()
);


-- ============================================================
-- QUOTATIONS
-- ============================================================

DROP POLICY IF EXISTS quotations_company_access
ON public.quotations;

DROP POLICY IF EXISTS quotations_client_select
ON public.quotations;

CREATE POLICY quotations_company_select
ON public.quotations
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR company_id = public.current_user_company_id()
);


-- ============================================================
-- QUOTATION ACKNOWLEDGEMENTS
-- ============================================================

DROP POLICY IF EXISTS quotation_document_acknowledgements_client_select
ON public.quotation_document_acknowledgements;

CREATE POLICY quotation_document_acknowledgements_company_select
ON public.quotation_document_acknowledgements
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR company_id = public.current_user_company_id()
);


-- ============================================================
-- INVOICES
-- ============================================================

DROP POLICY IF EXISTS invoices_client_select
ON public.invoices;

DROP POLICY IF EXISTS invoices_select_policy
ON public.invoices;

CREATE POLICY invoices_company_select
ON public.invoices
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR company_id = public.current_user_company_id()
);


-- ============================================================
-- INVOICE ACKNOWLEDGEMENTS
-- ============================================================

DROP POLICY IF EXISTS invoice_document_acknowledgements_client_select
ON public.invoice_document_acknowledgements;

CREATE POLICY invoice_document_acknowledgements_company_select
ON public.invoice_document_acknowledgements
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    OR EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE i.id = invoice_document_acknowledgements.invoice_id
          AND i.company_id = public.current_user_company_id()
    )
);


COMMIT;