-- ============================================================
-- 114_worker_rbac_security_hardening.sql
-- Hardening final de RBAC / RLS / SECURITY DEFINER
-- ============================================================

BEGIN;

-- ============================================================
-- 1. PROJECT CHANGE REQUESTS
-- ============================================================

DROP POLICY IF EXISTS project_change_requests_company_select
ON public.project_change_requests;

CREATE POLICY project_change_requests_company_select
ON public.project_change_requests
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('projects.read')
    )
    OR
    (
        public.current_user_is_active()
        AND NOT public.current_user_is_worker()
        AND company_id = public.current_user_company_id()
    )
);


DROP POLICY IF EXISTS project_change_requests_select
ON public.project_change_requests;

CREATE POLICY project_change_requests_select
ON public.project_change_requests
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('projects.read')
    )
    OR
    (
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


-- ============================================================
-- 2. PROJECT DOCUMENTS
-- ============================================================

DROP POLICY IF EXISTS project_documents_company_select
ON public.project_documents;

CREATE POLICY project_documents_company_select
ON public.project_documents
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('projects.read')
    )
    OR
    (
        EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_documents.project_id
              AND p.company_id = public.current_user_company_id()
        )
    )
);


DROP POLICY IF EXISTS project_documents_select
ON public.project_documents;

CREATE POLICY project_documents_select
ON public.project_documents
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('projects.read')
    )
    OR
    (
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


-- ============================================================
-- 3. COMPANY CHANGE REQUESTS
-- ============================================================

DROP POLICY IF EXISTS company_change_requests_worker_select
ON public.company_change_requests;

CREATE POLICY company_change_requests_worker_select
ON public.company_change_requests
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('companies.update')
);


-- ============================================================
-- 4. COMPANY IVA CHANGE REQUESTS
-- ============================================================

DROP POLICY IF EXISTS company_iva_change_requests_worker_select
ON public.company_iva_change_requests;

CREATE POLICY company_iva_change_requests_worker_select
ON public.company_iva_change_requests
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('companies.update')
);


-- ============================================================
-- 5. INVOICE DOCUMENT ACKNOWLEDGEMENTS
-- ============================================================

DROP POLICY IF EXISTS invoice_document_acknowledgements_company_select
ON public.invoice_document_acknowledgements;

CREATE POLICY invoice_document_acknowledgements_company_select
ON public.invoice_document_acknowledgements
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('invoices.read')
    )
    OR
    (
        EXISTS (
            SELECT 1
            FROM public.invoices i
            WHERE i.id = invoice_document_acknowledgements.invoice_id
              AND i.company_id = public.current_user_company_id()
        )
    )
);


-- ============================================================
-- 6. QUOTATION ACCEPTANCES
-- ============================================================

DROP POLICY IF EXISTS quotation_acceptances_worker_select
ON public.quotation_acceptances;

CREATE POLICY quotation_acceptances_worker_select
ON public.quotation_acceptances
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('quotations.read')
);


-- ============================================================
-- 7. QUOTATION DOCUMENT ACKNOWLEDGEMENTS
-- ============================================================

DROP POLICY IF EXISTS quotation_document_ack_worker_select
ON public.quotation_document_acknowledgements;

CREATE POLICY quotation_document_ack_worker_select
ON public.quotation_document_acknowledgements
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('quotations.read')
);


DROP POLICY IF EXISTS quotation_document_acknowledgements_company_select
ON public.quotation_document_acknowledgements;

CREATE POLICY quotation_document_acknowledgements_company_select
ON public.quotation_document_acknowledgements
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    (
        public.current_user_is_worker()
        AND public.current_worker_has_permission('quotations.read')
    )
    OR
    (
        company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- 8. AI CONVERSATIONS
-- ============================================================

DROP POLICY IF EXISTS ai_conversations_worker_select
ON public.ai_conversations;

CREATE POLICY ai_conversations_worker_select
ON public.ai_conversations
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('ai.read')
);


-- ============================================================
-- 9. AI MESSAGES
-- ============================================================

DROP POLICY IF EXISTS ai_messages_worker_select
ON public.ai_messages;

CREATE POLICY ai_messages_worker_select
ON public.ai_messages
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('ai.read')
);


-- ============================================================
-- 10. AUDIT REQUESTS
-- ============================================================

DROP POLICY IF EXISTS audit_requests_worker_select
ON public.audit_requests;

CREATE POLICY audit_requests_worker_select
ON public.audit_requests
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('system.audit.read')
);


-- ============================================================
-- 11. ACCOUNT DELETION REQUESTS
-- ============================================================

DROP POLICY IF EXISTS account_deletion_requests_worker_select
ON public.account_deletion_requests;

CREATE POLICY account_deletion_requests_worker_select
ON public.account_deletion_requests
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('system.workers.manage')
);


-- ============================================================
-- 12. LEGAL ACCEPTANCES
-- ============================================================

DROP POLICY IF EXISTS legal_acceptances_worker_select
ON public.legal_acceptances;

CREATE POLICY legal_acceptances_worker_select
ON public.legal_acceptances
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('system.audit.read')
);


-- ============================================================
-- 13. LEGAL DOCUMENTS
-- ============================================================

DROP POLICY IF EXISTS legal_documents_worker_select
ON public.legal_documents;

CREATE POLICY legal_documents_worker_select
ON public.legal_documents
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('system.audit.read')
);


-- ============================================================
-- 14. HARDEN RPC:
--     resolve_project_change_request
--
--     Conservamos la función existente y añadimos el permiso
--     projects.update al principio de su ejecución.
-- ============================================================

DO $$
DECLARE
    v_definition text;
    v_new_definition text;
BEGIN
    SELECT pg_get_functiondef(p.oid)
    INTO v_definition
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'resolve_project_change_request'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_request_id uuid, p_action text, p_review_notes text';

    IF v_definition IS NULL THEN
        RAISE EXCEPTION
            '114 failed: resolve_project_change_request not found';
    END IF;

    IF v_definition ILIKE '%current_worker_has_permission(''projects.update'')%' THEN
        RETURN;
    END IF;

    v_new_definition :=
        regexp_replace(
            v_definition,
            'BEGIN',
            E'BEGIN\n    PERFORM public.require_current_worker_permission(''projects.update'');',
            1,
            1
        );

    EXECUTE v_new_definition;
END
$$;


-- ============================================================
-- 15. HARDEN RPC:
--     set_project_milestone_status
-- ============================================================

DO $$
DECLARE
    v_definition text;
    v_new_definition text;
BEGIN
    SELECT pg_get_functiondef(p.oid)
    INTO v_definition
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'set_project_milestone_status'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_milestone_id uuid, p_estado text';

    IF v_definition IS NULL THEN
        RAISE EXCEPTION
            '114 failed: set_project_milestone_status not found';
    END IF;

    IF v_definition ILIKE '%current_worker_has_permission(''project_milestones.update'')%' THEN
        RETURN;
    END IF;

    v_new_definition :=
        regexp_replace(
            v_definition,
            'BEGIN',
            E'BEGIN\n    PERFORM public.require_current_worker_permission(''project_milestones.update'');',
            1,
            1
        );

    EXECUTE v_new_definition;
END
$$;


-- ============================================================
-- 16. HARDEN RPC:
--     set_maintenance_invoice_document_hash
-- ============================================================

DO $$
DECLARE
    v_definition text;
    v_new_definition text;
BEGIN
    SELECT pg_get_functiondef(p.oid)
    INTO v_definition
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'set_maintenance_invoice_document_hash'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_invoice_id uuid, p_sha256 text';

    IF v_definition IS NULL THEN
        RAISE EXCEPTION
            '114 failed: set_maintenance_invoice_document_hash not found';
    END IF;

    IF v_definition ILIKE '%current_worker_has_permission(''maintenance.update'')%' THEN
        RETURN;
    END IF;

    v_new_definition :=
        regexp_replace(
            v_definition,
            'BEGIN',
            E'BEGIN\n    PERFORM public.require_current_worker_permission(''maintenance.update'');',
            1,
            1
        );

    EXECUTE v_new_definition;
END
$$;


-- ============================================================
-- 17. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count integer;
BEGIN

    -- Las políticas críticas no deben contener un worker bypass
    -- basado únicamente en current_user_is_worker().
    SELECT count(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND policyname IN (
          'account_deletion_requests_worker_select',
          'ai_conversations_worker_select',
          'ai_messages_worker_select',
          'audit_requests_worker_select',
          'company_change_requests_worker_select',
          'company_iva_change_requests_worker_select',
          'invoice_document_acknowledgements_company_select',
          'legal_acceptances_worker_select',
          'legal_documents_worker_select',
          'project_change_requests_company_select',
          'project_change_requests_select',
          'project_documents_company_select',
          'project_documents_select',
          'quotation_acceptances_worker_select',
          'quotation_document_ack_worker_select',
          'quotation_document_acknowledgements_company_select'
      )
      AND (
          COALESCE(qual, '') ILIKE '%current_user_is_worker()%'
          OR COALESCE(with_check, '') ILIKE '%current_user_is_worker()%'
      )
      AND (
          COALESCE(qual, '') NOT ILIKE '%current_worker_has_permission%'
          AND COALESCE(with_check, '') NOT ILIKE '%current_worker_has_permission%'
      );

    IF v_count > 0 THEN
        RAISE EXCEPTION
            '114 failed: critical worker RLS bypasses remain: %',
            v_count;
    END IF;

END
$$;


COMMIT;