-- ============================================================
-- MODIRA — WORKER RBAC
-- 099_rbac_clients_companies.sql
-- ============================================================
--
-- OBJETIVO
-- ------------------------------------------------------------
-- Aplicar el RBAC de workers sobre:
--
--   public.clients
--   public.companies
--
-- ROLES
-- ------------------------------------------------------------
--
-- DIRECTION
--   clients   -> CRUD
--   companies -> CRUD
--
-- COMMERCIAL
--   clients   -> SELECT + UPDATE
--   companies -> SELECT + UPDATE
--
-- DEVELOPER
--   clients   -> SELECT
--   companies -> SIN ACCESO
--
-- SUPPORT
--   clients   -> SELECT
--   companies -> SIN ACCESO
--
-- ACCOUNTING
--   clients   -> SELECT
--   companies -> SIN ACCESO
--
-- IMPORTANTE
-- ------------------------------------------------------------
-- Esta migración NO modifica el acceso de clientes normales.
-- Las policies de cliente existentes permanecen.
--
-- Solo sustituye el acceso transversal de WORKERS.
--
-- Dependencias:
--   095_worker_rbac_core.sql
--   096_worker_rbac_permission_functions.sql
--   097_seed_worker_roles_and_permissions.sql
--   098_worker_role_assignments.sql
--
-- ============================================================

BEGIN;


-- ============================================================
-- 0. PRE-CHECKS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- Tablas
    -- --------------------------------------------------------

    IF to_regclass('public.clients') IS NULL THEN
        RAISE EXCEPTION
            '099: public.clients no existe.';
    END IF;

    IF to_regclass('public.companies') IS NULL THEN
        RAISE EXCEPTION
            '099: public.companies no existe.';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
            ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'clients'
          AND c.relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '099: RLS no está activado sobre public.clients.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
            ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'companies'
          AND c.relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '099: RLS no está activado sobre public.companies.';
    END IF;


    -- --------------------------------------------------------
    -- Funciones RBAC
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_user_is_worker()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '099: falta current_user_is_worker().';
    END IF;


    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '099: falta current_worker_has_permission(text).';
    END IF;


    -- --------------------------------------------------------
    -- Permisos críticos del catálogo
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'clients.read'
    ) THEN
        RAISE EXCEPTION
            '099: falta permiso clients.read.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'clients.update'
    ) THEN
        RAISE EXCEPTION
            '099: falta permiso clients.update.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'clients.create'
    ) THEN
        RAISE EXCEPTION
            '099: falta permiso clients.create.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'clients.delete'
    ) THEN
        RAISE EXCEPTION
            '099: falta permiso clients.delete.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'companies.read'
    ) THEN
        RAISE EXCEPTION
            '099: falta permiso companies.read.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'companies.update'
    ) THEN
        RAISE EXCEPTION
            '099: falta permiso companies.update.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'companies.create'
    ) THEN
        RAISE EXCEPTION
            '099: falta permiso companies.create.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'companies.delete'
    ) THEN
        RAISE EXCEPTION
            '099: falta permiso companies.delete.';
    END IF;

END;
$$;


-- ============================================================
-- 1. CLIENTS — ELIMINAR POLICIES WORKER ANTIGUAS
-- ============================================================
--
-- La policy histórica:
--
--   clients_worker_select
--
-- permitía SELECT transversal a cualquier worker activo.
--
-- Se elimina porque a partir de esta migración el acceso debe
-- depender de worker_permissions.
--
-- ============================================================

DROP POLICY IF EXISTS clients_worker_select
ON public.clients;

DROP POLICY IF EXISTS clients_worker_insert
ON public.clients;

DROP POLICY IF EXISTS clients_worker_update
ON public.clients;

DROP POLICY IF EXISTS clients_worker_delete
ON public.clients;


-- ============================================================
-- 2. CLIENTS — SELECT RBAC
-- ============================================================
--
-- Permisos:
--
--   direction
--   commercial
--   developer
--   support
--   accounting
--
-- Todos ellos poseen clients.read.
--
-- El resto de workers no puede consultar clients.
-- ============================================================

DROP POLICY IF EXISTS clients_rbac_select
ON public.clients;

CREATE POLICY clients_rbac_select
ON public.clients
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'clients.read'
    )
);


-- ============================================================
-- 3. CLIENTS — INSERT RBAC
-- ============================================================
--
-- Únicamente Dirección posee clients.create.
--
-- Comercial NO recibe clients.create en 097.
-- ============================================================

DROP POLICY IF EXISTS clients_rbac_insert
ON public.clients;

CREATE POLICY clients_rbac_insert
ON public.clients
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'clients.create'
    )
);


-- ============================================================
-- 4. CLIENTS — UPDATE RBAC
-- ============================================================
--
-- Dirección + Comercial.
--
-- USING:
--   controla qué filas existentes puede modificar.
--
-- WITH CHECK:
--   controla el estado resultante de la fila.
-- ============================================================

DROP POLICY IF EXISTS clients_rbac_update
ON public.clients;

CREATE POLICY clients_rbac_update
ON public.clients
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'clients.update'
    )
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'clients.update'
    )
);


-- ============================================================
-- 5. CLIENTS — DELETE RBAC
-- ============================================================
--
-- Únicamente Dirección posee clients.delete.
-- ============================================================

DROP POLICY IF EXISTS clients_rbac_delete
ON public.clients;

CREATE POLICY clients_rbac_delete
ON public.clients
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'clients.delete'
    )
);


-- ============================================================
-- 6. COMPANIES — ELIMINAR POLICIES WORKER ANTIGUAS
-- ============================================================
--
-- La policy histórica:
--
--   companies_worker_select
--
-- daba SELECT transversal a cualquier worker.
--
-- Se sustituye por RBAC.
-- ============================================================

DROP POLICY IF EXISTS companies_worker_select
ON public.companies;

DROP POLICY IF EXISTS companies_worker_insert
ON public.companies;

DROP POLICY IF EXISTS companies_worker_update
ON public.companies;

DROP POLICY IF EXISTS companies_worker_delete
ON public.companies;


-- ============================================================
-- 7. COMPANIES — SELECT RBAC
-- ============================================================
--
-- Direction + Commercial.
--
-- Developer / Support / Accounting no tienen companies.read.
-- ============================================================

DROP POLICY IF EXISTS companies_rbac_select
ON public.companies;

CREATE POLICY companies_rbac_select
ON public.companies
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'companies.read'
    )
);


-- ============================================================
-- 8. COMPANIES — INSERT RBAC
-- ============================================================
--
-- Únicamente Dirección posee companies.create.
-- ============================================================

DROP POLICY IF EXISTS companies_rbac_insert
ON public.companies;

CREATE POLICY companies_rbac_insert
ON public.companies
FOR INSERT
TO authenticated
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'companies.create'
    )
);


-- ============================================================
-- 9. COMPANIES — UPDATE RBAC
-- ============================================================
--
-- Direction + Commercial.
--
-- Esto sustituye el antiguo modelo en el que el worker tenía
-- acceso genérico y el cliente normal tenía bloqueado UPDATE.
--
-- El cliente normal continúa sin acceso porque esta policy
-- exige current_user_is_worker().
-- ============================================================

DROP POLICY IF EXISTS companies_rbac_update
ON public.companies;

CREATE POLICY companies_rbac_update
ON public.companies
FOR UPDATE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'companies.update'
    )
)
WITH CHECK (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'companies.update'
    )
);


-- ============================================================
-- 10. COMPANIES — DELETE RBAC
-- ============================================================
--
-- Únicamente Dirección posee companies.delete.
-- ============================================================

DROP POLICY IF EXISTS companies_rbac_delete
ON public.companies;

CREATE POLICY companies_rbac_delete
ON public.companies
FOR DELETE
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission(
        'companies.delete'
    )
);


-- ============================================================
-- 11. PRIVILEGIOS SQL — CLIENTS
-- ============================================================
--
-- RLS decide QUÉ filas puede tocar cada worker.
--
-- El privilegio SQL permite la operación a authenticated,
-- mientras que la policy limita quién puede realizarla.
--
-- Los clientes normales continúan limitados por sus policies.
--
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.clients
TO authenticated;


-- ============================================================
-- 12. PRIVILEGIOS SQL — COMPANIES
-- ============================================================
--
-- IMPORTANTE:
--
-- Una migración anterior revocó UPDATE sobre companies para
-- authenticated porque los clientes no debían modificar
-- directamente la empresa.
--
-- Ahora debemos conceder el privilegio SQL necesario para que
-- los workers con companies.update puedan hacerlo.
--
-- La RLS sigue siendo la barrera que impide que un cliente
-- normal utilice ese privilegio.
--
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.companies
TO authenticated;


-- ============================================================
-- 13. VERIFICAR QUE RLS SIGUE ACTIVO
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
            ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'clients'
          AND c.relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '099: clients perdió RLS.';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
            ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'companies'
          AND c.relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION
            '099: companies perdió RLS.';
    END IF;

END;
$$;


-- ============================================================
-- 14. VERIFICAR POLICIES RBAC DE CLIENTS
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'clients'
      AND policyname IN (
          'clients_rbac_select',
          'clients_rbac_insert',
          'clients_rbac_update',
          'clients_rbac_delete'
      );


    IF v_count <> 4 THEN
        RAISE EXCEPTION
            '099: se esperaban 4 policies RBAC sobre clients y se encontraron %.',
            v_count;
    END IF;

END;
$$;


-- ============================================================
-- 15. VERIFICAR POLICIES RBAC DE COMPANIES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'companies'
      AND policyname IN (
          'companies_rbac_select',
          'companies_rbac_insert',
          'companies_rbac_update',
          'companies_rbac_delete'
      );


    IF v_count <> 4 THEN
        RAISE EXCEPTION
            '099: se esperaban 4 policies RBAC sobre companies y se encontraron %.',
            v_count;
    END IF;

END;
$$;


-- ============================================================
-- 16. VERIFICAR QUE NO QUEDA EL SELECT WORKER ANTIGUO
-- ============================================================

DO $$
BEGIN

    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'clients'
          AND policyname = 'clients_worker_select'
    ) THEN

        RAISE EXCEPTION
            '099: clients_worker_select antigua sigue existiendo.';

    END IF;


    IF EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'companies'
          AND policyname = 'companies_worker_select'
    ) THEN

        RAISE EXCEPTION
            '099: companies_worker_select antigua sigue existiendo.';

    END IF;

END;
$$;


-- ============================================================
-- 17. VERIFICACIÓN DEL CATÁLOGO DE PERMISOS
-- ============================================================
--
-- Dirección debe tener los 8 permisos CRUD:
--
-- clients:
--   read/create/update/delete
--
-- companies:
--   read/create/update/delete
--
-- Comercial:
--   clients.read
--   clients.update
--   companies.read
--   companies.update
--
-- ============================================================

DO $$
DECLARE
    v_missing INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Dirección
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_missing
    FROM public.worker_permissions p
    WHERE p.code IN (
        'clients.read',
        'clients.create',
        'clients.update',
        'clients.delete',
        'companies.read',
        'companies.create',
        'companies.update',
        'companies.delete'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        WHERE r.code = 'direction'
          AND rp.permission_id = p.id
    );


    IF v_missing <> 0 THEN
        RAISE EXCEPTION
            '099: Dirección no tiene % permisos requeridos de Clients/Companies.',
            v_missing;
    END IF;


    -- --------------------------------------------------------
    -- Comercial
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_missing
    FROM public.worker_permissions p
    WHERE p.code IN (
        'clients.read',
        'clients.update',
        'companies.read',
        'companies.update'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        WHERE r.code = 'commercial'
          AND rp.permission_id = p.id
    );


    IF v_missing <> 0 THEN
        RAISE EXCEPTION
            '099: Comercial no tiene % permisos requeridos de Clients/Companies.',
            v_missing;
    END IF;


    -- --------------------------------------------------------
    -- Developer NO debe tener companies.read
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'developer'
          AND p.code = 'companies.read'
    ) THEN

        RAISE EXCEPTION
            '099: Developer no debe tener companies.read.';

    END IF;


    -- --------------------------------------------------------
    -- Support NO debe tener companies.read
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'support'
          AND p.code = 'companies.read'
    ) THEN

        RAISE EXCEPTION
            '099: Support no debe tener companies.read.';

    END IF;


    -- --------------------------------------------------------
    -- Accounting NO debe tener companies.read
    -- --------------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'accounting'
          AND p.code = 'companies.read'
    ) THEN

        RAISE EXCEPTION
            '099: Accounting no debe tener companies.read.';

    END IF;

END;
$$;


-- ============================================================
-- 18. COMPROBAR POLICIES WORKER EXISTENTES SOBRE CLIENTS/
--     COMPANIES
-- ============================================================
--
-- No debe quedar una policy antigua que utilice únicamente
-- current_user_is_worker() para conceder acceso transversal.
--
-- Las policies nuevas deben comprobar además:
--
--   current_worker_has_permission(...)
--
-- ============================================================

DO $$
DECLARE
    v_bad INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_bad
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (
          'clients',
          'companies'
      )
      AND (
          COALESCE(qual, '') ILIKE '%current_user_is_worker()%'
          OR
          COALESCE(with_check, '') ILIKE '%current_user_is_worker()%'
      )
      AND (
          COALESCE(qual, '') NOT ILIKE '%current_worker_has_permission%'
          AND
          COALESCE(with_check, '') NOT ILIKE '%current_worker_has_permission%'
      )
      AND policyname NOT IN (
          -- Las policies de cliente normal contienen NOT current_user_is_worker()
          -- y por tanto no entran en este filtro.
          'clients_company_access',
          'companies_select_own'
      );


    IF v_bad <> 0 THEN
        RAISE EXCEPTION
            '099: existen % policies de Clients/Companies con acceso worker sin RBAC.',
            v_bad;
    END IF;

END;
$$;


-- ============================================================
-- 19. COMPROBACIÓN DE PRIVILEGIOS SQL
-- ============================================================

DO $$
BEGIN

    IF NOT has_table_privilege(
        'authenticated',
        'public.clients',
        'SELECT'
    ) THEN
        RAISE EXCEPTION
            '099: authenticated no tiene SELECT sobre clients.';
    END IF;


    IF NOT has_table_privilege(
        'authenticated',
        'public.clients',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '099: authenticated no tiene UPDATE sobre clients.';
    END IF;


    IF NOT has_table_privilege(
        'authenticated',
        'public.companies',
        'SELECT'
    ) THEN
        RAISE EXCEPTION
            '099: authenticated no tiene SELECT sobre companies.';
    END IF;


    IF NOT has_table_privilege(
        'authenticated',
        'public.companies',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '099: authenticated no tiene UPDATE sobre companies.';
    END IF;

END;
$$;


-- ============================================================
-- 20. COMENTARIOS
-- ============================================================

COMMENT ON POLICY clients_rbac_select
ON public.clients
IS
'RBAC: lectura de clientes según clients.read.';


COMMENT ON POLICY clients_rbac_insert
ON public.clients
IS
'RBAC: creación de clientes según clients.create.';


COMMENT ON POLICY clients_rbac_update
ON public.clients
IS
'RBAC: modificación de clientes según clients.update.';


COMMENT ON POLICY clients_rbac_delete
ON public.clients
IS
'RBAC: eliminación de clientes según clients.delete.';


COMMENT ON POLICY companies_rbac_select
ON public.companies
IS
'RBAC: lectura de empresas según companies.read.';


COMMENT ON POLICY companies_rbac_insert
ON public.companies
IS
'RBAC: creación de empresas según companies.create.';


COMMENT ON POLICY companies_rbac_update
ON public.companies
IS
'RBAC: modificación de empresas según companies.update.';


COMMENT ON POLICY companies_rbac_delete
ON public.companies
IS
'RBAC: eliminación de empresas según companies.delete.';


-- ============================================================
-- FIN 099
-- ============================================================

COMMIT;