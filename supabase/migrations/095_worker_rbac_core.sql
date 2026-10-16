BEGIN;

-- ============================================================
-- MODIRA — 095 WORKER RBAC CORE
-- ============================================================
--
-- OBJETIVO
--
-- Crear exclusivamente la infraestructura base del sistema RBAC
-- para trabajadores internos de MODIRA.
--
-- ESTA MIGRACIÓN:
--
--   - NO modifica ninguna tabla existente.
--   - NO modifica profiles.
--   - NO modifica workers.
--   - NO modifica current_user_is_worker().
--   - NO modifica ninguna policy existente.
--   - NO modifica ninguna RPC existente.
--   - NO modifica Storage.
--   - NO cambia todavía los permisos efectivos de ningún worker.
--
-- Crea únicamente:
--
--   1. worker_roles
--   2. worker_permissions
--   3. worker_role_permissions
--   4. worker_role_assignments
--
-- La asignación de permisos y los roles iniciales se realizarán
-- en migraciones posteriores.
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================
--
-- Antes de crear nada comprobamos que la arquitectura existente
-- contiene workers y que workers.auth_user_id tiene la estructura
-- esperada.
--
-- Esto evita crear un RBAC incompatible con la base actual.
-- ============================================================

DO $$
DECLARE
    v_exists BOOLEAN;
BEGIN

    -- --------------------------------------------------------
    -- workers debe existir
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC migration stopped: public.workers does not exist';
    END IF;


    -- --------------------------------------------------------
    -- workers.auth_user_id debe existir
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'workers'
          AND column_name = 'auth_user_id'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC migration stopped: public.workers.auth_user_id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- workers.is_active debe existir
    -- --------------------------------------------------------

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'workers'
          AND column_name = 'is_active'
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION
            'RBAC migration stopped: public.workers.is_active does not exist';
    END IF;


    -- --------------------------------------------------------
    -- auth_user_id debe ser UUID
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'workers'
          AND column_name = 'auth_user_id'
          AND udt_name = 'uuid'
    ) THEN
        RAISE EXCEPTION
            'RBAC migration stopped: workers.auth_user_id must be UUID';
    END IF;


    -- --------------------------------------------------------
    -- auth_user_id debe ser UNIQUE o PRIMARY KEY.
    --
    -- El modelo actual de MODIRA establece que un usuario de Auth
    -- solo puede tener un registro de worker.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t
            ON t.oid = c.conrelid
        JOIN pg_namespace n
            ON n.oid = t.relnamespace
        WHERE n.nspname = 'public'
          AND t.relname = 'workers'
          AND c.contype IN ('p', 'u')
          AND (
              pg_get_constraintdef(c.oid) ILIKE '%auth_user_id%'
          )
    )
    AND NOT EXISTS (
        SELECT 1
        FROM pg_index i
        JOIN pg_class t
            ON t.oid = i.indrelid
        JOIN pg_namespace n
            ON n.oid = t.relnamespace
        JOIN pg_attribute a
            ON a.attrelid = t.oid
           AND a.attnum = ANY(i.indkey)
        WHERE n.nspname = 'public'
          AND t.relname = 'workers'
          AND i.indisunique = TRUE
          AND a.attname = 'auth_user_id'
    ) THEN
        RAISE EXCEPTION
            'RBAC migration stopped: workers.auth_user_id must be UNIQUE';
    END IF;

END;
$$;


-- ============================================================
-- 2. TABLA worker_roles
-- ============================================================
--
-- Contiene los roles funcionales de los trabajadores.
--
-- Ejemplos que se introducirán posteriormente:
--
--   direction
--   commercial
--   developer
--   support
--   accounting
--
-- IMPORTANTE:
-- Los roles NO sustituyen profiles.rol.
--
-- profiles.rol continúa siendo parte del sistema actual de
-- autenticación/autorización.
--
-- worker_roles representa únicamente la autorización interna
-- específica de trabajadores.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.worker_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    code TEXT NOT NULL,

    name TEXT NOT NULL,

    description TEXT,

    is_system_role BOOLEAN NOT NULL DEFAULT TRUE,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT worker_roles_code_not_empty
        CHECK (length(btrim(code)) > 0),

    CONSTRAINT worker_roles_code_length
        CHECK (length(code) <= 100),

    CONSTRAINT worker_roles_name_not_empty
        CHECK (length(btrim(name)) > 0),

    CONSTRAINT worker_roles_name_length
        CHECK (length(name) <= 200),

    CONSTRAINT worker_roles_description_length
        CHECK (
            description IS NULL
            OR length(description) <= 2000
        ),

    CONSTRAINT worker_roles_code_unique
        UNIQUE (code)
);


-- ============================================================
-- 3. TABLA worker_permissions
-- ============================================================
--
-- Catálogo central de permisos.
--
-- Ejemplos que se introducirán posteriormente:
--
--   clients.read
--   clients.create
--   clients.update
--   quotations.read
--   quotations.create
--   billing.read
--   projects.update
--   support.read
--   system.roles.manage
--
-- El campo code será el identificador estable que utilizarán
-- RLS, RPC y frontend.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.worker_permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    code TEXT NOT NULL,

    resource TEXT NOT NULL,

    action TEXT NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT worker_permissions_code_not_empty
        CHECK (length(btrim(code)) > 0),

    CONSTRAINT worker_permissions_code_length
        CHECK (length(code) <= 150),

    CONSTRAINT worker_permissions_resource_not_empty
        CHECK (length(btrim(resource)) > 0),

    CONSTRAINT worker_permissions_resource_length
        CHECK (length(resource) <= 100),

    CONSTRAINT worker_permissions_action_not_empty
        CHECK (length(btrim(action)) > 0),

    CONSTRAINT worker_permissions_action_length
        CHECK (length(action) <= 100),

    CONSTRAINT worker_permissions_description_length
        CHECK (
            description IS NULL
            OR length(description) <= 2000
        ),

    CONSTRAINT worker_permissions_code_unique
        UNIQUE (code),

    CONSTRAINT worker_permissions_resource_action_unique
        UNIQUE (resource, action)
);


-- ============================================================
-- 4. TABLA worker_role_permissions
-- ============================================================
--
-- Relación:
--
--   ROLE
--     ↓
--   PERMISSIONS
--
-- Permite que un mismo permiso pertenezca a varios roles.
-- Permite también que un rol tenga muchos permisos.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.worker_role_permissions (
    role_id UUID NOT NULL,

    permission_id UUID NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (role_id, permission_id),

    CONSTRAINT worker_role_permissions_role_fk
        FOREIGN KEY (role_id)
        REFERENCES public.worker_roles(id)
        ON DELETE CASCADE,

    CONSTRAINT worker_role_permissions_permission_fk
        FOREIGN KEY (permission_id)
        REFERENCES public.worker_permissions(id)
        ON DELETE CASCADE
);


-- ============================================================
-- 5. TABLA worker_role_assignments
-- ============================================================
--
-- Relación:
--
--   WORKER
--      ↓
--   ROLE
--
-- Un worker puede tener uno o varios roles.
--
-- El worker se identifica mediante workers.auth_user_id porque
-- ese es el identificador que representa su usuario de Supabase
-- Auth en la arquitectura actual.
--
-- Si el usuario Auth se elimina:
--
--   auth.users
--        ↓
--   workers
--        ↓
--   worker_role_assignments
--
-- se elimina automáticamente la asignación.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.worker_role_assignments (
    worker_auth_user_id UUID NOT NULL,

    role_id UUID NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (worker_auth_user_id, role_id),

    CONSTRAINT worker_role_assignments_worker_fk
        FOREIGN KEY (worker_auth_user_id)
        REFERENCES public.workers(auth_user_id)
        ON DELETE CASCADE,

    CONSTRAINT worker_role_assignments_role_fk
        FOREIGN KEY (role_id)
        REFERENCES public.worker_roles(id)
        ON DELETE CASCADE
);


-- ============================================================
-- 6. ÍNDICES
-- ============================================================
--
-- Las PK/UNIQUE ya crean índices para las relaciones principales.
-- Añadimos índices orientados a las consultas que utilizarán las
-- futuras funciones RBAC.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_worker_roles_active
    ON public.worker_roles (is_active);


CREATE INDEX IF NOT EXISTS idx_worker_permissions_resource
    ON public.worker_permissions (resource);


CREATE INDEX IF NOT EXISTS idx_worker_role_permissions_permission
    ON public.worker_role_permissions (permission_id);


CREATE INDEX IF NOT EXISTS idx_worker_role_assignments_role
    ON public.worker_role_assignments (role_id);


-- ============================================================
-- 7. RLS
-- ============================================================
--
-- Las tablas RBAC contienen información de autorización.
--
-- En esta migración NO se concede acceso directo a:
--
--   anon
--   authenticated
--   PUBLIC
--
-- Las futuras operaciones de lectura/escritura se realizarán
-- mediante funciones controladas.
--
-- Esto es deliberado.
--
-- No queremos que un usuario pueda ejecutar:
--
--   INSERT INTO worker_role_assignments ...
--
-- directamente desde el navegador.
--
-- Tampoco queremos que pueda modificar:
--
--   worker_roles
--   worker_permissions
--   worker_role_permissions
--
-- directamente.
-- ============================================================

ALTER TABLE public.worker_roles ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.worker_permissions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.worker_role_permissions ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.worker_role_assignments ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 8. REVOKE DE PRIVILEGIOS DIRECTOS
-- ============================================================
--
-- Dejamos explícitamente cerradas las tablas para los roles
-- frontend.
--
-- La migración 096 creará las funciones seguras necesarias para
-- consultar el contexto RBAC.
-- ============================================================

REVOKE ALL
ON TABLE public.worker_roles
FROM PUBLIC, anon, authenticated;


REVOKE ALL
ON TABLE public.worker_permissions
FROM PUBLIC, anon, authenticated;


REVOKE ALL
ON TABLE public.worker_role_permissions
FROM PUBLIC, anon, authenticated;


REVOKE ALL
ON TABLE public.worker_role_assignments
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 9. COMENTARIOS DE DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.worker_roles IS
'MODIRA RBAC: roles funcionales de trabajadores internos. No sustituye profiles.rol.';


COMMENT ON TABLE public.worker_permissions IS
'MODIRA RBAC: catálogo central de permisos de trabajadores.';


COMMENT ON TABLE public.worker_role_permissions IS
'MODIRA RBAC: relación entre roles y permisos.';


COMMENT ON TABLE public.worker_role_assignments IS
'MODIRA RBAC: relación entre usuarios worker y roles. El worker se identifica por workers.auth_user_id.';


COMMENT ON COLUMN public.worker_roles.code IS
'Identificador estable del rol utilizado por la capa RBAC.';


COMMENT ON COLUMN public.worker_permissions.code IS
'Identificador estable del permiso utilizado por RLS, RPC y frontend.';


COMMENT ON COLUMN public.worker_role_assignments.worker_auth_user_id IS
'auth.users.id del trabajador, correspondiente a workers.auth_user_id.';


-- ============================================================
-- 10. VERIFICACIONES FINALES
-- ============================================================
--
-- La migración no termina correctamente si alguna de las
-- estructuras fundamentales no existe después de su creación.
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- worker_roles
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'worker_roles';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: worker_roles was not created';
    END IF;


    -- --------------------------------------------------------
    -- worker_permissions
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'worker_permissions';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: worker_permissions was not created';
    END IF;


    -- --------------------------------------------------------
    -- worker_role_permissions
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'worker_role_permissions';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: worker_role_permissions was not created';
    END IF;


    -- --------------------------------------------------------
    -- worker_role_assignments
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'worker_role_assignments';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: worker_role_assignments was not created';
    END IF;


    -- --------------------------------------------------------
    -- RLS worker_roles
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_class c
    JOIN pg_namespace n
        ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'worker_roles'
      AND c.relrowsecurity = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: RLS is not enabled on worker_roles';
    END IF;


    -- --------------------------------------------------------
    -- RLS worker_permissions
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_class c
    JOIN pg_namespace n
        ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'worker_permissions'
      AND c.relrowsecurity = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: RLS is not enabled on worker_permissions';
    END IF;


    -- --------------------------------------------------------
    -- RLS worker_role_permissions
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_class c
    JOIN pg_namespace n
        ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'worker_role_permissions'
      AND c.relrowsecurity = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: RLS is not enabled on worker_role_permissions';
    END IF;


    -- --------------------------------------------------------
    -- RLS worker_role_assignments
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_class c
    JOIN pg_namespace n
        ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'worker_role_assignments'
      AND c.relrowsecurity = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: RLS is not enabled on worker_role_assignments';
    END IF;


    -- --------------------------------------------------------
    -- Verificar que workers.auth_user_id sigue siendo único.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_constraint c
    JOIN pg_class t
        ON t.oid = c.conrelid
    JOIN pg_namespace n
        ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'workers'
      AND c.contype IN ('p', 'u')
      AND pg_get_constraintdef(c.oid) ILIKE '%auth_user_id%';

    IF v_count = 0 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: workers.auth_user_id uniqueness was not found';
    END IF;


    -- --------------------------------------------------------
    -- Verificar que todavía NO existen permisos directos para
    -- authenticated sobre las tablas RBAC.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name IN (
          'worker_roles',
          'worker_permissions',
          'worker_role_permissions',
          'worker_role_assignments'
      )
      AND grantee = 'authenticated';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: authenticated has direct privileges on RBAC tables';
    END IF;


    -- --------------------------------------------------------
    -- Verificar que tampoco existen privilegios para anon.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name IN (
          'worker_roles',
          'worker_permissions',
          'worker_role_permissions',
          'worker_role_assignments'
      )
      AND grantee = 'anon';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: anon has direct privileges on RBAC tables';
    END IF;


    -- --------------------------------------------------------
    -- Verificación final:
    -- esta migración NO debe haber creado policies RBAC.
    --
    -- El acceso real se introducirá de forma controlada en
    -- migraciones posteriores.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (
          'worker_roles',
          'worker_permissions',
          'worker_role_permissions',
          'worker_role_assignments'
      );

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'RBAC migration verification failed: unexpected RLS policies exist on RBAC tables';
    END IF;

END;
$$;


-- ============================================================
-- 11. COMMIT
-- ============================================================

COMMIT;