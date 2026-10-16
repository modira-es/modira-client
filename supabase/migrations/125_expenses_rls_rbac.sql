-- ============================================================
-- MODIRA — 125_expenses_rls_rbac.sql
-- ============================================================
--
-- OBJETIVO
--
-- Aplicar RLS + RBAC al módulo interno de gastos de MODIRA.
--
-- IMPORTANTE:
--
-- expenses NO pertenece a las empresas cliente.
-- Es contabilidad interna de MODIRA.
--
-- Por tanto:
--
-- CLIENTES
--   SELECT  -> NO
--   INSERT  -> NO
--   UPDATE  -> NO
--   DELETE  -> NO
--
-- WORKERS
--   SELECT  -> según expenses.read
--   escrituras directas -> NO
--   escrituras sensibles -> RPC 124
--
-- Las RPC de 124 son las únicas vías de escritura.
--
-- ============================================================

BEGIN;


-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- expenses
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'expenses'
    ) THEN
        RAISE EXCEPTION
            '125 stopped: public.expenses no existe';
    END IF;


    -- --------------------------------------------------------
    -- suppliers
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'suppliers'
    ) THEN
        RAISE EXCEPTION
            '125 stopped: public.suppliers no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_categories
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'expense_categories'
    ) THEN
        RAISE EXCEPTION
            '125 stopped: public.expense_categories no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_tax_lines
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'expense_tax_lines'
    ) THEN
        RAISE EXCEPTION
            '125 stopped: public.expense_tax_lines no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_documents
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'expense_documents'
    ) THEN
        RAISE EXCEPTION
            '125 stopped: public.expense_documents no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_payments
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'expense_payments'
    ) THEN
        RAISE EXCEPTION
            '125 stopped: public.expense_payments no existe';
    END IF;


    -- --------------------------------------------------------
    -- expense_allocations
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'expense_allocations'
    ) THEN
        RAISE EXCEPTION
            '125 stopped: public.expense_allocations no existe';
    END IF;


    -- --------------------------------------------------------
    -- Worker identification
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
          AND pg_get_function_identity_arguments(p.oid) = ''
    ) THEN
        RAISE EXCEPTION
            '125 stopped: current_user_is_worker() no existe';
    END IF;


    -- --------------------------------------------------------
    -- Worker active state
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_active'
          AND pg_get_function_identity_arguments(p.oid) = ''
    ) THEN
        RAISE EXCEPTION
            '125 stopped: current_user_is_active() no existe';
    END IF;


    -- --------------------------------------------------------
    -- Real RBAC permission helper
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_current_worker_permissions'
          AND pg_get_function_identity_arguments(p.oid) = ''
    ) THEN
        RAISE EXCEPTION
            '125 stopped: get_current_worker_permissions() no existe';
    END IF;


    -- --------------------------------------------------------
    -- expenses.read must already exist.
    --
    -- This belongs to the RBAC catalogue introduced previously.
    -- We do NOT create a duplicate permission here.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'expenses.read'
    ) THEN
        RAISE EXCEPTION
            '125 stopped: permission expenses.read no existe';
    END IF;

END;
$$;


-- ============================================================
-- 1. RLS
-- ============================================================

ALTER TABLE public.expenses
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.suppliers
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.expense_categories
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.expense_tax_lines
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.expense_documents
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.expense_payments
ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.expense_allocations
ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 2. EXPENSES — WORKER SELECT
-- ============================================================
--
-- Solo workers activos con:
--
--     expenses.read
--
-- pueden consultar gastos.
--
-- Ninguna policy de cliente.
--
-- ============================================================

DROP POLICY IF EXISTS expenses_worker_select
ON public.expenses;

CREATE POLICY expenses_worker_select
ON public.expenses
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.read'
    )
);


-- ============================================================
-- 3. EXPENSES — NO DIRECT WRITE
-- ============================================================
--
-- Las escrituras se realizan exclusivamente mediante las RPC
-- de 124.
--
-- ============================================================

REVOKE INSERT, UPDATE, DELETE
ON public.expenses
FROM anon, authenticated;


-- ============================================================
-- 4. SUPPLIERS — WORKER SELECT
-- ============================================================
--
-- Los proveedores son información interna de MODIRA.
--
-- No existe acceso de clientes.
--
-- ============================================================

DROP POLICY IF EXISTS suppliers_worker_select
ON public.suppliers;

CREATE POLICY suppliers_worker_select
ON public.suppliers
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.read'
    )
);


REVOKE INSERT, UPDATE, DELETE
ON public.suppliers
FROM anon, authenticated;


-- ============================================================
-- 5. EXPENSE CATEGORIES — WORKER SELECT
-- ============================================================

DROP POLICY IF EXISTS expense_categories_worker_select
ON public.expense_categories;

CREATE POLICY expense_categories_worker_select
ON public.expense_categories
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.read'
    )
);


REVOKE INSERT, UPDATE, DELETE
ON public.expense_categories
FROM anon, authenticated;


-- ============================================================
-- 6. EXPENSE TAX LINES — WORKER SELECT
-- ============================================================

DROP POLICY IF EXISTS expense_tax_lines_worker_select
ON public.expense_tax_lines;

CREATE POLICY expense_tax_lines_worker_select
ON public.expense_tax_lines
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.read'
    )
);


REVOKE INSERT, UPDATE, DELETE
ON public.expense_tax_lines
FROM anon, authenticated;


-- ============================================================
-- 7. EXPENSE DOCUMENTS — WORKER SELECT
-- ============================================================

DROP POLICY IF EXISTS expense_documents_worker_select
ON public.expense_documents;

CREATE POLICY expense_documents_worker_select
ON public.expense_documents
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.read'
    )
);


REVOKE INSERT, UPDATE, DELETE
ON public.expense_documents
FROM anon, authenticated;


-- ============================================================
-- 8. EXPENSE PAYMENTS — WORKER SELECT
-- ============================================================

DROP POLICY IF EXISTS expense_payments_worker_select
ON public.expense_payments;

CREATE POLICY expense_payments_worker_select
ON public.expense_payments
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.read'
    )
);


REVOKE INSERT, UPDATE, DELETE
ON public.expense_payments
FROM anon, authenticated;


-- ============================================================
-- 9. EXPENSE ALLOCATIONS — WORKER SELECT
-- ============================================================

DROP POLICY IF EXISTS expense_allocations_worker_select
ON public.expense_allocations;

CREATE POLICY expense_allocations_worker_select
ON public.expense_allocations
AS PERMISSIVE
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.read'
    )
);


REVOKE INSERT, UPDATE, DELETE
ON public.expense_allocations
FROM anon, authenticated;


-- ============================================================
-- 10. GARANTÍA — NINGÚN ACCESO DIRECTO DE CLIENTE
-- ============================================================
--
-- Aunque en el futuro aparezca alguna policy antigua o heredada,
-- estas tablas no deben disponer de una policy que permita a un
-- cliente acceder a los gastos.
--
-- Las tablas no tienen company_id y son exclusivamente internas.
--
-- ============================================================

DROP POLICY IF EXISTS expenses_client_select
ON public.expenses;

DROP POLICY IF EXISTS suppliers_client_select
ON public.suppliers;

DROP POLICY IF EXISTS expense_categories_client_select
ON public.expense_categories;

DROP POLICY IF EXISTS expense_tax_lines_client_select
ON public.expense_tax_lines;

DROP POLICY IF EXISTS expense_documents_client_select
ON public.expense_documents;

DROP POLICY IF EXISTS expense_payments_client_select
ON public.expense_payments;

DROP POLICY IF EXISTS expense_allocations_client_select
ON public.expense_allocations;


-- ============================================================
-- 11. STORAGE — EXPENSE DOCUMENTS
-- ============================================================
--
-- Bucket privado creado en 072.
--
-- El worker puede:
--
-- SELECT
-- INSERT
-- UPDATE
--
-- siempre que tenga expenses.read.
--
-- La asociación definitiva del documento con el gasto se hace
-- mediante attach_expense_document() de 124.
--
-- No damos DELETE directo.
--
-- ============================================================

DROP POLICY IF EXISTS expense_documents_storage_worker_select
ON storage.objects;

CREATE POLICY expense_documents_storage_worker_select
ON storage.objects
FOR SELECT
TO authenticated
USING (
    bucket_id = 'expense-documents'
    AND public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.read'
    )
);


DROP POLICY IF EXISTS expense_documents_storage_worker_insert
ON storage.objects;

CREATE POLICY expense_documents_storage_worker_insert
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'expense-documents'
    AND public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.create'
    )
    AND name ~ '^.+/.+\.pdf$'
);


DROP POLICY IF EXISTS expense_documents_storage_worker_update
ON storage.objects;

CREATE POLICY expense_documents_storage_worker_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (
    bucket_id = 'expense-documents'
    AND public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.update'
    )
)
WITH CHECK (
    bucket_id = 'expense-documents'
    AND public.current_user_is_active()
    AND public.current_user_is_worker()
    AND EXISTS (
        SELECT 1
        FROM public.get_current_worker_permissions() p
        WHERE p.permission_code = 'expenses.update'
    )
    AND name ~ '^.+/.+\.pdf$'
);


DROP POLICY IF EXISTS expense_documents_storage_worker_delete
ON storage.objects;


-- No DELETE directo para authenticated.
-- La eliminación documental se controla mediante la RPC
-- delete_expense_document().


-- ============================================================
-- 12. STORAGE — CLIENTES
-- ============================================================
--
-- IMPORTANTE:
--
-- Los gastos son internos de MODIRA.
--
-- Un cliente NO puede consultar los documentos de gastos.
--
-- ============================================================

DROP POLICY IF EXISTS expense_documents_storage_client_select
ON storage.objects;

DROP POLICY IF EXISTS expense_documents_storage_client_insert
ON storage.objects;

DROP POLICY IF EXISTS expense_documents_storage_client_update
ON storage.objects;

DROP POLICY IF EXISTS expense_documents_storage_client_delete
ON storage.objects;


-- ============================================================
-- 13. PRIVILEGIOS DE TABLAS
-- ============================================================
--
-- SELECT se concede únicamente para que RLS pueda decidir el
-- acceso de workers.
--
-- No se concede ninguna escritura directa.
--
-- ============================================================

GRANT SELECT
ON public.expenses,
   public.suppliers,
   public.expense_categories,
   public.expense_tax_lines,
   public.expense_documents,
   public.expense_payments,
   public.expense_allocations
TO authenticated;


-- ============================================================
-- 14. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_rls BOOLEAN;
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Todas las tablas deben tener RLS.
    -- --------------------------------------------------------

    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid = 'public.expenses'::regclass;

    IF NOT COALESCE(v_rls, FALSE) THEN
        RAISE EXCEPTION
            '125 failed: expenses no tiene RLS habilitado';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid = 'public.suppliers'::regclass;

    IF NOT COALESCE(v_rls, FALSE) THEN
        RAISE EXCEPTION
            '125 failed: suppliers no tiene RLS habilitado';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid = 'public.expense_categories'::regclass;

    IF NOT COALESCE(v_rls, FALSE) THEN
        RAISE EXCEPTION
            '125 failed: expense_categories no tiene RLS habilitado';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid = 'public.expense_tax_lines'::regclass;

    IF NOT COALESCE(v_rls, FALSE) THEN
        RAISE EXCEPTION
            '125 failed: expense_tax_lines no tiene RLS habilitado';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid = 'public.expense_documents'::regclass;

    IF NOT COALESCE(v_rls, FALSE) THEN
        RAISE EXCEPTION
            '125 failed: expense_documents no tiene RLS habilitado';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid = 'public.expense_payments'::regclass;

    IF NOT COALESCE(v_rls, FALSE) THEN
        RAISE EXCEPTION
            '125 failed: expense_payments no tiene RLS habilitado';
    END IF;


    SELECT relrowsecurity
    INTO v_rls
    FROM pg_class
    WHERE oid = 'public.expense_allocations'::regclass;

    IF NOT COALESCE(v_rls, FALSE) THEN
        RAISE EXCEPTION
            '125 failed: expense_allocations no tiene RLS habilitado';
    END IF;


    -- --------------------------------------------------------
    -- Debe existir exactamente una policy worker SELECT
    -- para cada tabla.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'expenses'
      AND policyname = 'expenses_worker_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '125 failed: expenses_worker_select missing';
    END IF;


    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'suppliers'
      AND policyname = 'suppliers_worker_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '125 failed: suppliers_worker_select missing';
    END IF;


    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'expense_categories'
      AND policyname = 'expense_categories_worker_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '125 failed: expense_categories_worker_select missing';
    END IF;


    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'expense_tax_lines'
      AND policyname = 'expense_tax_lines_worker_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '125 failed: expense_tax_lines_worker_select missing';
    END IF;


    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'expense_documents'
      AND policyname = 'expense_documents_worker_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '125 failed: expense_documents_worker_select missing';
    END IF;


    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'expense_payments'
      AND policyname = 'expense_payments_worker_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '125 failed: expense_payments_worker_select missing';
    END IF;


    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'expense_allocations'
      AND policyname = 'expense_allocations_worker_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '125 failed: expense_allocations_worker_select missing';
    END IF;


    -- --------------------------------------------------------
    -- No direct writes.
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.expenses',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '125 failed: authenticated conserva INSERT sobre expenses';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.expenses',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '125 failed: authenticated conserva UPDATE sobre expenses';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.expenses',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '125 failed: authenticated conserva DELETE sobre expenses';
    END IF;


    -- --------------------------------------------------------
    -- Storage bucket.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'expense-documents'
          AND public = FALSE
    ) THEN
        RAISE EXCEPTION
            '125 failed: expense-documents bucket missing or public';
    END IF;


    -- --------------------------------------------------------
    -- No client policies.
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename IN (
              'expenses',
              'suppliers',
              'expense_categories',
              'expense_tax_lines',
              'expense_documents',
              'expense_payments',
              'expense_allocations'
          )
          AND policyname LIKE '%client%'
    ) THEN
        RAISE EXCEPTION
            '125 failed: existen policies client sobre tablas internas de expenses';
    END IF;

END;
$$;


-- ============================================================
-- 15. DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.expenses IS
'Gastos internos de MODIRA. No pertenecen a empresas cliente. Los workers consultan mediante RBAC y las escrituras se realizan mediante RPCs protegidas.';

COMMENT ON TABLE public.suppliers IS
'Proveedores internos de MODIRA. Sin acceso para clientes.';

COMMENT ON TABLE public.expense_categories IS
'Categorías internas de gastos de MODIRA. Sin acceso para clientes.';

COMMENT ON TABLE public.expense_documents IS
'Documentación interna asociada a gastos de MODIRA.';

COMMENT ON TABLE public.expense_payments IS
'Pagos internos asociados a gastos de MODIRA.';

COMMENT ON TABLE public.expense_allocations IS
'Distribución interna de gastos entre proyectos de MODIRA.';


-- ============================================================
-- 16. POSTGREST
-- ============================================================

NOTIFY pgrst, 'reload schema';


COMMIT;