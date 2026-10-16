BEGIN;

-- ============================================================================
-- MODIRA — 153_payroll_module.sql
--
-- Módulo interno de nóminas.
-- - Datos visibles exclusivamente para Direction y Accounting mediante RBAC/RLS.
-- - PDFs privados en el bucket payroll-documents.
-- - Coste empresarial calculado como bruto + SS empresarial + otros costes.
-- - Las nóminas no se insertan en expenses, invoices ni maintenance_invoices.
-- - No se automatizan cálculos de nómina, pagos ni generación de nóminas futuras.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. PRECONDICIONES: no continuar si faltan roles o funciones de seguridad.
-- ---------------------------------------------------------------------------
DO $preflight$
DECLARE
    v_roles integer;
BEGIN
    SELECT count(*)
      INTO v_roles
      FROM public.worker_roles
     WHERE code IN ('direction', 'accounting')
       AND is_active IS TRUE;

    IF v_roles <> 2 THEN
        RAISE EXCEPTION
          'Migración 153 cancelada: deben existir los roles activos direction y accounting (encontrados: %).',
          v_roles;
    END IF;

    IF to_regprocedure('public.current_user_is_worker()') IS NULL
       OR to_regprocedure('public.current_worker_has_permission(text)') IS NULL THEN
        RAISE EXCEPTION
          'Migración 153 cancelada: faltan las funciones requeridas current_user_is_worker() o current_worker_has_permission(text).';
    END IF;
END;
$preflight$;

-- ---------------------------------------------------------------------------
-- 1. PERMISOS RBAC
-- ---------------------------------------------------------------------------
INSERT INTO public.worker_permissions (code, resource, action, description)
VALUES
    ('payroll.read',   'payroll', 'read',   'Consultar nóminas, importes y documentos'),
    ('payroll.create', 'payroll', 'create', 'Crear nóminas y plantillas'),
    ('payroll.update', 'payroll', 'update', 'Modificar nóminas y plantillas'),
    ('payroll.delete', 'payroll', 'delete', 'Eliminar nóminas en las condiciones permitidas')
ON CONFLICT (code) DO NOTHING;

-- No reutilizar silenciosamente un código existente con otro recurso/acción.
DO $permission_validation$
DECLARE
    v_bad integer;
BEGIN
    SELECT count(*)
      INTO v_bad
      FROM (VALUES
          ('payroll.read',   'payroll', 'read'),
          ('payroll.create', 'payroll', 'create'),
          ('payroll.update', 'payroll', 'update'),
          ('payroll.delete', 'payroll', 'delete')
      ) AS expected(code, resource, action)
      LEFT JOIN public.worker_permissions wp ON wp.code = expected.code
     WHERE wp.id IS NULL
        OR wp.resource <> expected.resource
        OR wp.action <> expected.action;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION
          'Migración 153 cancelada: existe una definición incompatible de permisos payroll.';
    END IF;
END;
$permission_validation$;

INSERT INTO public.worker_role_permissions (role_id, permission_id)
SELECT wr.id, wp.id
  FROM public.worker_roles wr
  CROSS JOIN public.worker_permissions wp
 WHERE wr.code IN ('direction', 'accounting')
   AND wr.is_active IS TRUE
   AND wp.code IN ('payroll.read', 'payroll.create', 'payroll.update', 'payroll.delete')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. NÓMINAS
-- ---------------------------------------------------------------------------
CREATE TABLE public.payroll_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_id uuid NOT NULL
        REFERENCES public.workers(id) ON DELETE RESTRICT,

    period_year smallint NOT NULL,
    period_month smallint NOT NULL,

    gross_salary numeric(12,2) NOT NULL,
    employee_deductions numeric(12,2) NOT NULL DEFAULT 0,
    net_salary numeric(12,2) NOT NULL,
    employer_social_security numeric(12,2) NOT NULL DEFAULT 0,
    other_employer_costs numeric(12,2) NOT NULL DEFAULT 0,
    total_employer_cost numeric(12,2)
        GENERATED ALWAYS AS (
            gross_salary + employer_social_security + other_employer_costs
        ) STORED,

    status text NOT NULL DEFAULT 'draft',
    payment_date date,
    notes text,

    created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT payroll_records_valid_period
        CHECK (period_year BETWEEN 2000 AND 2200 AND period_month BETWEEN 1 AND 12),
    CONSTRAINT payroll_records_nonnegative_amounts
        CHECK (
            gross_salary >= 0
            AND employee_deductions >= 0
            AND net_salary >= 0
            AND employer_social_security >= 0
            AND other_employer_costs >= 0
        ),
    CONSTRAINT payroll_records_valid_status
        CHECK (status IN ('draft', 'approved', 'paid', 'cancelled')),
    CONSTRAINT payroll_records_payment_date_matches_status
        CHECK ((status = 'paid') = (payment_date IS NOT NULL)),
    CONSTRAINT payroll_records_one_per_worker_period
        UNIQUE (worker_id, period_year, period_month)
);

CREATE INDEX payroll_records_period_idx
    ON public.payroll_records (period_year DESC, period_month DESC);
CREATE INDEX payroll_records_worker_period_idx
    ON public.payroll_records (worker_id, period_year DESC, period_month DESC);
CREATE INDEX payroll_records_status_idx
    ON public.payroll_records (status);

ALTER TABLE public.payroll_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_records FORCE ROW LEVEL SECURITY;

CREATE POLICY payroll_records_select
ON public.payroll_records
FOR SELECT TO authenticated
USING (public.current_worker_has_permission('payroll.read'));

CREATE POLICY payroll_records_insert
ON public.payroll_records
FOR INSERT TO authenticated
WITH CHECK (
    public.current_worker_has_permission('payroll.create')
    AND (created_by IS NULL OR created_by = auth.uid())
    AND (updated_by IS NULL OR updated_by = auth.uid())
);

CREATE POLICY payroll_records_update
ON public.payroll_records
FOR UPDATE TO authenticated
USING (public.current_worker_has_permission('payroll.update'))
WITH CHECK (public.current_worker_has_permission('payroll.update'));

CREATE POLICY payroll_records_delete
ON public.payroll_records
FOR DELETE TO authenticated
USING (public.current_worker_has_permission('payroll.delete'));

REVOKE ALL ON public.payroll_records FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.payroll_records TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. PLANTILLAS DE VALORES HABITUALES
-- Son valores de referencia; no generan nóminas ni pagos automáticamente.
-- ---------------------------------------------------------------------------
CREATE TABLE public.payroll_templates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_id uuid NOT NULL UNIQUE
        REFERENCES public.workers(id) ON DELETE RESTRICT,

    gross_salary numeric(12,2) NOT NULL,
    employee_deductions numeric(12,2) NOT NULL DEFAULT 0,
    net_salary numeric(12,2) NOT NULL,
    employer_social_security numeric(12,2) NOT NULL DEFAULT 0,
    other_employer_costs numeric(12,2) NOT NULL DEFAULT 0,
    total_employer_cost numeric(12,2)
        GENERATED ALWAYS AS (
            gross_salary + employer_social_security + other_employer_costs
        ) STORED,

    notes text,
    is_active boolean NOT NULL DEFAULT true,
    created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT payroll_templates_nonnegative_amounts
        CHECK (
            gross_salary >= 0
            AND employee_deductions >= 0
            AND net_salary >= 0
            AND employer_social_security >= 0
            AND other_employer_costs >= 0
        )
);

ALTER TABLE public.payroll_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_templates FORCE ROW LEVEL SECURITY;

CREATE POLICY payroll_templates_select
ON public.payroll_templates
FOR SELECT TO authenticated
USING (public.current_worker_has_permission('payroll.read'));

CREATE POLICY payroll_templates_insert
ON public.payroll_templates
FOR INSERT TO authenticated
WITH CHECK (
    public.current_worker_has_permission('payroll.create')
    AND (created_by IS NULL OR created_by = auth.uid())
    AND (updated_by IS NULL OR updated_by = auth.uid())
);

CREATE POLICY payroll_templates_update
ON public.payroll_templates
FOR UPDATE TO authenticated
USING (public.current_worker_has_permission('payroll.update'))
WITH CHECK (public.current_worker_has_permission('payroll.update'));

CREATE POLICY payroll_templates_delete
ON public.payroll_templates
FOR DELETE TO authenticated
USING (public.current_worker_has_permission('payroll.delete'));

REVOKE ALL ON public.payroll_templates FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.payroll_templates TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. DOCUMENTOS PDF DE NÓMINA
-- Ruta obligatoria: <payroll_uuid>/<document_uuid>.pdf
-- ---------------------------------------------------------------------------
CREATE TABLE public.payroll_documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_id uuid NOT NULL
        REFERENCES public.payroll_records(id) ON DELETE RESTRICT,
    file_name text NOT NULL,
    storage_path text NOT NULL UNIQUE,
    mime_type text NOT NULL DEFAULT 'application/pdf',
    file_size bigint NOT NULL,
    sha256 text,
    uploaded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT payroll_documents_pdf_mime
        CHECK (mime_type = 'application/pdf'),
    CONSTRAINT payroll_documents_size_limit
        CHECK (file_size BETWEEN 1 AND 20971520),
    CONSTRAINT payroll_documents_valid_sha256
        CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-fA-F]{64}$'),
    CONSTRAINT payroll_documents_path_matches_payroll
        CHECK (
            storage_path ~* (
                '^' || payroll_id::text ||
                '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$'
            )
        ),
    CONSTRAINT payroll_documents_file_name_nonempty
        CHECK (length(btrim(file_name)) BETWEEN 1 AND 255)
);

CREATE INDEX payroll_documents_payroll_id_idx
    ON public.payroll_documents (payroll_id);

ALTER TABLE public.payroll_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_documents FORCE ROW LEVEL SECURITY;

CREATE POLICY payroll_documents_select
ON public.payroll_documents
FOR SELECT TO authenticated
USING (public.current_worker_has_permission('payroll.read'));

CREATE POLICY payroll_documents_insert
ON public.payroll_documents
FOR INSERT TO authenticated
WITH CHECK (
    (
        public.current_worker_has_permission('payroll.create')
        OR public.current_worker_has_permission('payroll.update')
    )
    AND uploaded_by = auth.uid()
);

CREATE POLICY payroll_documents_update
ON public.payroll_documents
FOR UPDATE TO authenticated
USING (public.current_worker_has_permission('payroll.update'))
WITH CHECK (public.current_worker_has_permission('payroll.update'));

CREATE POLICY payroll_documents_delete
ON public.payroll_documents
FOR DELETE TO authenticated
USING (public.current_worker_has_permission('payroll.delete'));

REVOKE ALL ON public.payroll_documents FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.payroll_documents TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. AUDITORÍA DE CAMBIOS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_payroll_audit_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := CURRENT_TIMESTAMP;
        NEW.updated_at := CURRENT_TIMESTAMP;
        IF auth.uid() IS NOT NULL THEN
            NEW.created_by := auth.uid();
            NEW.updated_by := auth.uid();
        END IF;
    ELSE
        NEW.created_at := OLD.created_at;
        NEW.created_by := OLD.created_by;
        NEW.updated_at := CURRENT_TIMESTAMP;
        IF auth.uid() IS NOT NULL THEN
            NEW.updated_by := auth.uid();
        ELSE
            NEW.updated_by := OLD.updated_by;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_payroll_audit_fields() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_payroll_document_audit_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, auth, pg_temp
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := CURRENT_TIMESTAMP;
        IF auth.uid() IS NOT NULL THEN
            NEW.uploaded_by := auth.uid();
        END IF;
    ELSE
        NEW.created_at := OLD.created_at;
        NEW.uploaded_by := OLD.uploaded_by;
    END IF;
    RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_payroll_document_audit_fields() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER payroll_documents_audit_fields
BEFORE INSERT OR UPDATE ON public.payroll_documents
FOR EACH ROW EXECUTE FUNCTION public.set_payroll_document_audit_fields();

CREATE TRIGGER payroll_records_audit_fields
BEFORE INSERT OR UPDATE ON public.payroll_records
FOR EACH ROW EXECUTE FUNCTION public.set_payroll_audit_fields();

CREATE TRIGGER payroll_templates_audit_fields
BEFORE INSERT OR UPDATE ON public.payroll_templates
FOR EACH ROW EXECUTE FUNCTION public.set_payroll_audit_fields();

-- ---------------------------------------------------------------------------
-- 6. ACCESO CONTROLADO A LA TABLA DE TRABAJADORES
-- La política existente workers_select_own se conserva.
-- Esta política añade lectura de trabajadores solo a usuarios con payroll.read.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS workers_select_payroll_admin ON public.workers;
CREATE POLICY workers_select_payroll_admin
ON public.workers
FOR SELECT TO authenticated
USING (public.current_worker_has_permission('payroll.read'));

-- ---------------------------------------------------------------------------
-- 7. BUCKET PRIVADO PARA PDF
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('payroll-documents', 'payroll-documents', false, 20971520, ARRAY['application/pdf']::text[])
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    public = false,
    file_size_limit = 20971520,
    allowed_mime_types = ARRAY['application/pdf']::text[];

-- Las políticas permisivas de este bucket exigen RBAC y que el objeto
-- tenga metadatos válidos en payroll_documents. Los metadatos se insertan
-- antes de subir el objeto; si falla la subida, la aplicación debe limpiar
-- el registro de metadatos que haya quedado sin objeto.
DROP POLICY IF EXISTS payroll_documents_storage_select ON storage.objects;
CREATE POLICY payroll_documents_storage_select
ON storage.objects
FOR SELECT TO authenticated
USING (
    bucket_id = 'payroll-documents'
    AND public.current_worker_has_permission('payroll.read')
    AND EXISTS (
        SELECT 1
          FROM public.payroll_documents pd
         WHERE pd.storage_path = storage.objects.name
           AND pd.payroll_id::text = split_part(storage.objects.name, '/', 1)
    )
);

DROP POLICY IF EXISTS payroll_documents_storage_insert ON storage.objects;
CREATE POLICY payroll_documents_storage_insert
ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
    bucket_id = 'payroll-documents'
    AND (
        public.current_worker_has_permission('payroll.create')
        OR public.current_worker_has_permission('payroll.update')
    )
    AND storage.objects.name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$'
    AND EXISTS (
        SELECT 1
          FROM public.payroll_documents pd
         WHERE pd.storage_path = storage.objects.name
           AND pd.payroll_id::text = split_part(storage.objects.name, '/', 1)
    )
);

DROP POLICY IF EXISTS payroll_documents_storage_update ON storage.objects;
CREATE POLICY payroll_documents_storage_update
ON storage.objects
FOR UPDATE TO authenticated
USING (
    bucket_id = 'payroll-documents'
    AND public.current_worker_has_permission('payroll.update')
    AND EXISTS (
        SELECT 1
          FROM public.payroll_documents pd
         WHERE pd.storage_path = storage.objects.name
           AND pd.payroll_id::text = split_part(storage.objects.name, '/', 1)
    )
)
WITH CHECK (
    bucket_id = 'payroll-documents'
    AND public.current_worker_has_permission('payroll.update')
    AND storage.objects.name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$'
    AND EXISTS (
        SELECT 1
          FROM public.payroll_documents pd
         WHERE pd.storage_path = storage.objects.name
           AND pd.payroll_id::text = split_part(storage.objects.name, '/', 1)
    )
);

DROP POLICY IF EXISTS payroll_documents_storage_delete ON storage.objects;
CREATE POLICY payroll_documents_storage_delete
ON storage.objects
FOR DELETE TO authenticated
USING (
    bucket_id = 'payroll-documents'
    AND public.current_worker_has_permission('payroll.delete')
    AND EXISTS (
        SELECT 1
          FROM public.payroll_documents pd
         WHERE pd.storage_path = storage.objects.name
           AND pd.payroll_id::text = split_part(storage.objects.name, '/', 1)
    )
);

-- ---------------------------------------------------------------------------
-- 8. CORREGIR EL ALCANCE DE LAS 20 POLÍTICAS RESTRICTIVAS EXISTENTES
-- Cada política conserva su expresión original en su propio bucket y deja
-- de bloquear accesos a otros buckets. No se relajan los permisos propios.
-- ---------------------------------------------------------------------------

ALTER POLICY invoices_storage_rbac_delete ON storage.objects
USING (bucket_id <> 'invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('invoices.delete'));
ALTER POLICY invoices_storage_rbac_insert ON storage.objects
WITH CHECK (bucket_id <> 'invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('invoices.create'));
ALTER POLICY invoices_storage_rbac_select ON storage.objects
USING (bucket_id <> 'invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('invoices.read'));
ALTER POLICY invoices_storage_rbac_update ON storage.objects
USING (bucket_id <> 'invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('invoices.update'))
WITH CHECK (bucket_id <> 'invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('invoices.update'));

ALTER POLICY maintenance_invoices_storage_rbac_delete ON storage.objects
USING (bucket_id <> 'maintenance-invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance.delete'));
ALTER POLICY maintenance_invoices_storage_rbac_insert ON storage.objects
WITH CHECK (bucket_id <> 'maintenance-invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance.create'));
ALTER POLICY maintenance_invoices_storage_rbac_select ON storage.objects
USING (bucket_id <> 'maintenance-invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance.read'));
ALTER POLICY maintenance_invoices_storage_rbac_update ON storage.objects
USING (bucket_id <> 'maintenance-invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance.update'))
WITH CHECK (bucket_id <> 'maintenance-invoices' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance.update'));

ALTER POLICY maintenance_proposals_storage_rbac_delete ON storage.objects
USING (bucket_id <> 'maintenance-proposals' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance_proposals.delete'));
ALTER POLICY maintenance_proposals_storage_rbac_insert ON storage.objects
WITH CHECK (bucket_id <> 'maintenance-proposals' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance_proposals.create'));
ALTER POLICY maintenance_proposals_storage_rbac_select ON storage.objects
USING (bucket_id <> 'maintenance-proposals' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance_proposals.read'));
ALTER POLICY maintenance_proposals_storage_rbac_update ON storage.objects
USING (bucket_id <> 'maintenance-proposals' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance_proposals.update'))
WITH CHECK (bucket_id <> 'maintenance-proposals' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('maintenance_proposals.update'));

ALTER POLICY project_documents_storage_rbac_delete ON storage.objects
USING (bucket_id <> 'project-documents' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('projects.delete'));
ALTER POLICY project_documents_storage_rbac_insert ON storage.objects
WITH CHECK (bucket_id <> 'project-documents' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('projects.create'));
ALTER POLICY project_documents_storage_rbac_select ON storage.objects
USING (bucket_id <> 'project-documents' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('projects.read'));
ALTER POLICY project_documents_storage_rbac_update ON storage.objects
USING (bucket_id <> 'project-documents' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('projects.update'))
WITH CHECK (bucket_id <> 'project-documents' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('projects.update'));

ALTER POLICY quotations_storage_rbac_delete ON storage.objects
USING (bucket_id <> 'quotations' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('quotations.delete'));
ALTER POLICY quotations_storage_rbac_insert ON storage.objects
WITH CHECK (bucket_id <> 'quotations' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('quotations.create'));
ALTER POLICY quotations_storage_rbac_select ON storage.objects
USING (bucket_id <> 'quotations' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('quotations.read'));
ALTER POLICY quotations_storage_rbac_update ON storage.objects
USING (bucket_id <> 'quotations' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('quotations.update'))
WITH CHECK (bucket_id <> 'quotations' OR (NOT public.current_user_is_worker()) OR public.current_worker_has_permission('quotations.update'));

-- ---------------------------------------------------------------------------
-- 9. VISTA MENSUAL PARA INTEGRACIÓN EN ANÁLISIS FINANCIERO
-- Solo suma nóminas aprobadas o pagadas; los borradores y cancelados quedan
-- fuera del coste consolidado. security_invoker hace que se respete RLS.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.payroll_financial_summary
WITH (security_invoker = true)
AS
SELECT
    pr.period_year,
    pr.period_month,
    count(*)::bigint AS payroll_count,
    sum(pr.gross_salary)::numeric(14,2) AS gross_salary_total,
    sum(pr.employer_social_security)::numeric(14,2) AS employer_social_security_total,
    sum(pr.other_employer_costs)::numeric(14,2) AS other_employer_costs_total,
    sum(pr.total_employer_cost)::numeric(14,2) AS total_employer_cost
FROM public.payroll_records pr
WHERE pr.status IN ('approved', 'paid')
GROUP BY pr.period_year, pr.period_month;

REVOKE ALL ON public.payroll_financial_summary FROM PUBLIC, anon;
GRANT SELECT ON public.payroll_financial_summary TO authenticated;

-- ---------------------------------------------------------------------------
-- 10. VALIDACIONES FINALES: fallar y revertir toda la migración si algo falta.
-- ---------------------------------------------------------------------------
DO $final_validation$
DECLARE
    v_permissions integer;
    v_policies integer;
    v_bucket_count integer;
BEGIN
    SELECT count(*) INTO v_permissions
      FROM public.worker_permissions
     WHERE code IN ('payroll.read', 'payroll.create', 'payroll.update', 'payroll.delete');
    IF v_permissions <> 4 THEN
        RAISE EXCEPTION 'Migración 153 cancelada: no se han registrado los cuatro permisos payroll.';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.worker_role_permissions wrp
          JOIN public.worker_permissions wp ON wp.id = wrp.permission_id
          JOIN public.worker_roles wr ON wr.id = wrp.role_id
         WHERE wp.code IN ('payroll.read', 'payroll.create', 'payroll.update', 'payroll.delete')
           AND wr.code NOT IN ('direction', 'accounting')
    ) THEN
        RAISE EXCEPTION 'Migración 153 cancelada: se detectaron permisos payroll asignados a roles distintos de direction/accounting.';
    END IF;

    IF (
        SELECT count(*)
          FROM public.worker_role_permissions wrp
          JOIN public.worker_permissions wp ON wp.id = wrp.permission_id
          JOIN public.worker_roles wr ON wr.id = wrp.role_id
         WHERE wr.code IN ('direction', 'accounting')
           AND wp.code IN ('payroll.read', 'payroll.create', 'payroll.update', 'payroll.delete')
    ) <> 8 THEN
        RAISE EXCEPTION 'Migración 153 cancelada: direction y accounting deben tener asignados los cuatro permisos payroll.';
    END IF;

    SELECT count(*) INTO v_policies
      FROM pg_policies
     WHERE schemaname = 'storage'
       AND tablename = 'objects'
       AND policyname IN (
           'invoices_storage_rbac_delete', 'invoices_storage_rbac_insert',
           'invoices_storage_rbac_select', 'invoices_storage_rbac_update',
           'maintenance_invoices_storage_rbac_delete', 'maintenance_invoices_storage_rbac_insert',
           'maintenance_invoices_storage_rbac_select', 'maintenance_invoices_storage_rbac_update',
           'maintenance_proposals_storage_rbac_delete', 'maintenance_proposals_storage_rbac_insert',
           'maintenance_proposals_storage_rbac_select', 'maintenance_proposals_storage_rbac_update',
           'project_documents_storage_rbac_delete', 'project_documents_storage_rbac_insert',
           'project_documents_storage_rbac_select', 'project_documents_storage_rbac_update',
           'quotations_storage_rbac_delete', 'quotations_storage_rbac_insert',
           'quotations_storage_rbac_select', 'quotations_storage_rbac_update'
       );
    IF v_policies <> 20 THEN
        RAISE EXCEPTION 'Migración 153 cancelada: se esperaban 20 políticas restrictivas RBAC existentes; encontradas %.', v_policies;
    END IF;

    SELECT count(*) INTO v_bucket_count
      FROM storage.buckets
     WHERE id = 'payroll-documents'
       AND public IS FALSE
       AND file_size_limit = 20971520
       AND allowed_mime_types = ARRAY['application/pdf']::text[];
    IF v_bucket_count <> 1 THEN
        RAISE EXCEPTION 'Migración 153 cancelada: configuración inesperada del bucket payroll-documents.';
    END IF;
END;
$final_validation$;

COMMIT;
