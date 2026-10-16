-- ============================================================
-- 083_company_storage_visibility.sql
-- ============================================================

BEGIN;


-- ============================================================
-- PROJECT DOCUMENTS
-- ============================================================

DROP POLICY IF EXISTS
"project_documents_client_select"
ON storage.objects;

DROP POLICY IF EXISTS
"project_documents_client_read"
ON storage.objects;

CREATE POLICY
"project_documents_company_select"
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'project-documents'
    AND EXISTS (
        SELECT 1
        FROM public.project_documents pd
        JOIN public.projects p
          ON p.id = pd.project_id
        WHERE pd.storage_path = storage.objects.name
          AND p.company_id = public.current_user_company_id()
    )
);


-- ============================================================
-- INVOICES
-- ============================================================

DROP POLICY IF EXISTS
"invoices_client_select"
ON storage.objects;

DROP POLICY IF EXISTS
"invoice_documents_client_select"
ON storage.objects;

CREATE POLICY
"invoices_company_select"
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'invoices'
    AND EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE i.document_path = storage.objects.name
          AND i.company_id = public.current_user_company_id()
    )
);


COMMIT;