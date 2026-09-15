BEGIN;

-- ============================================================
-- MODIRA — 041_project_updates.sql
--
-- ÚLTIMAS NOVEDADES VISIBLES PARA EL CLIENTE
-- ============================================================
--
-- OBJETIVO
-- ============================================================
--
-- Crear un sistema específico de actualizaciones/novedades
-- visibles para el cliente dentro del Área Cliente.
--
-- Ejemplos:
--
--   "Proyecto iniciado"
--   "Diseño aprobado"
--   "Desarrollo comenzado"
--   "Primera fase completada"
--   "Entrega preparada"
--
--
-- IMPORTANTE
-- ============================================================
--
-- Esta tabla NO sustituye:
--
--   public.activity_log
--
-- activity_log continúa siendo el registro general de
-- actividad existente en Modira.
--
-- project_updates tiene otra finalidad:
--
--   ACTUALIZACIÓN PUBLICADA DELIBERADAMENTE AL CLIENTE
--
--
-- Esta migración:
--
-- 1. NO modifica projects.
-- 2. NO modifica project_milestones.
-- 3. NO modifica notifications.
-- 4. NO modifica activity_log.
-- 5. NO modifica project_documents.
-- 6. NO modifica quotations.
-- 7. NO modifica invoices.
-- 8. NO modifica payments.
-- 9. NO modifica Stripe.
-- 10. NO modifica ninguna RPC existente.
--
-- Depende de:
--
--   030 → project_milestones
--   031 → notifications
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================
--
-- No queremos crear parcialmente la infraestructura si las
-- migraciones anteriores necesarias no están presentes.
--
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- PROJECTS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'projects'
    ) THEN
        RAISE EXCEPTION
            '041 stopped: public.projects does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECTS.ID
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'id'
    ) THEN
        RAISE EXCEPTION
            '041 stopped: projects.id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECTS.USER_ID
    --
    -- Propietario del proyecto para el acceso del cliente.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'user_id'
    ) THEN
        RAISE EXCEPTION
            '041 stopped: projects.user_id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECT_MILESTONES
    --
    -- Se exige 030 porque el sistema de novedades forma parte
    -- del nuevo sistema de proyecto.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'project_milestones'
    ) THEN
        RAISE EXCEPTION
            '041 stopped: public.project_milestones does not exist (030 required)';
    END IF;


    -- --------------------------------------------------------
    -- NOTIFICATIONS
    --
    -- Se exige 031 porque las novedades generarán una
    -- notificación para el cliente.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'notifications'
    ) THEN
        RAISE EXCEPTION
            '041 stopped: public.notifications does not exist (031 required)';
    END IF;


    -- --------------------------------------------------------
    -- SECURITY FUNCTIONS
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_user_is_worker()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '041 stopped: current_user_is_worker() does not exist';
    END IF;


    IF to_regprocedure(
        'public.current_user_is_active()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '041 stopped: current_user_is_active() does not exist';
    END IF;


    -- --------------------------------------------------------
    -- NOTIFICATION HELPER
    --
    -- Esta función fue creada en 031.
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.emit_project_client_notification(uuid,text,text,text,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '041 stopped: notification helper from 031 does not exist';
    END IF;

END $$;


-- ============================================================
-- 2. TABLA PROJECT_UPDATES
-- ============================================================
--
-- Una actualización pertenece a un único proyecto.
--
-- El worker puede publicar tantas novedades como necesite.
--
-- Ejemplo:
--
-- project
--   │
--   ├── Proyecto iniciado
--   ├── Diseño aprobado
--   ├── Desarrollo iniciado
--   └── Primera fase completada
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.project_updates (

    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    project_id UUID NOT NULL
        REFERENCES public.projects(id)
        ON DELETE CASCADE,

    titulo TEXT NOT NULL,

    contenido TEXT NOT NULL,

    created_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT project_updates_titulo_check
        CHECK (
            LENGTH(BTRIM(titulo)) > 0
            AND LENGTH(titulo) <= 200
        ),

    CONSTRAINT project_updates_contenido_check
        CHECK (
            LENGTH(BTRIM(contenido)) > 0
            AND LENGTH(contenido) <= 5000
        )
);


-- ============================================================
-- 3. ÍNDICES
-- ============================================================
--
-- El dashboard necesitará principalmente:
--
--   proyecto → novedades más recientes
--
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_project_updates_project_created_at
ON public.project_updates (
    project_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_project_updates_created_at
ON public.project_updates (
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_project_updates_created_by
ON public.project_updates (
    created_by
);


-- ============================================================
-- 4. TRIGGER — UPDATED_AT
-- ============================================================
--
-- Mantiene updated_at automáticamente.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.sync_project_update_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    NEW.updated_at := CURRENT_TIMESTAMP;

    RETURN NEW;

END;
$$;


DROP TRIGGER IF EXISTS
    project_updates_sync_updated_at
ON public.project_updates;


CREATE TRIGGER
    project_updates_sync_updated_at
BEFORE UPDATE
ON public.project_updates
FOR EACH ROW
EXECUTE FUNCTION
    public.sync_project_update_updated_at();


-- ============================================================
-- 5. RLS
-- ============================================================
--
-- CLIENTE:
--
--   SELECT únicamente de sus propios proyectos.
--
-- WORKER ACTIVO:
--
--   SELECT de todas las novedades.
--
-- No existen policies directas de:
--
--   INSERT
--   UPDATE
--   DELETE
--
-- Las modificaciones se realizan mediante RPC.
--
-- ============================================================

ALTER TABLE public.project_updates
ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS
    project_updates_select
ON public.project_updates;


CREATE POLICY
    project_updates_select
ON public.project_updates
FOR SELECT
TO authenticated
USING (

    public.current_user_is_worker()

    OR

    (
        public.current_user_is_active()
        AND NOT public.current_user_is_worker()

        AND EXISTS (
            SELECT 1
            FROM public.projects p
            WHERE p.id = project_updates.project_id
              AND p.user_id = auth.uid()
        )
    )

);


-- ============================================================
-- 6. PRIVILEGIOS DIRECTOS
-- ============================================================
--
-- El cliente solo necesita SELECT.
--
-- No puede modificar directamente una novedad.
--
-- ============================================================

REVOKE ALL
ON public.project_updates
FROM PUBLIC, anon, authenticated;


GRANT SELECT
ON public.project_updates
TO authenticated;


-- ============================================================
-- 7. RPC — CREAR NOVEDAD
-- ============================================================
--
-- Únicamente un WORKER ACTIVO puede publicar una novedad.
--
-- Al crearla:
--
--   project_updates
--          │
--          ├── se guarda la novedad
--          │
--          └── se genera una notificación
--               para el cliente del proyecto.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.create_project_update(
    p_project_id UUID,
    p_titulo TEXT,
    p_contenido TEXT
)
RETURNS public.project_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

    v_update public.project_updates;

BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- WORKER ACTIVO
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- --------------------------------------------------------
    -- PROJECT ID
    -- --------------------------------------------------------

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto es obligatorio';
    END IF;


    -- --------------------------------------------------------
    -- TÍTULO
    -- --------------------------------------------------------

    IF p_titulo IS NULL
       OR LENGTH(BTRIM(p_titulo)) = 0
       OR LENGTH(p_titulo) > 200
    THEN
        RAISE EXCEPTION
            'El título de la novedad no es válido';
    END IF;


    -- --------------------------------------------------------
    -- CONTENIDO
    -- --------------------------------------------------------

    IF p_contenido IS NULL
       OR LENGTH(BTRIM(p_contenido)) = 0
       OR LENGTH(p_contenido) > 5000
    THEN
        RAISE EXCEPTION
            'El contenido de la novedad no es válido';
    END IF;


    -- --------------------------------------------------------
    -- COMPROBAR PROYECTO
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.projects
        WHERE id = p_project_id
    ) THEN
        RAISE EXCEPTION
            'El proyecto indicado no existe';
    END IF;


    -- --------------------------------------------------------
    -- CREAR NOVEDAD
    -- --------------------------------------------------------

    INSERT INTO public.project_updates (
        project_id,
        titulo,
        contenido,
        created_by
    )
    VALUES (
        p_project_id,
        BTRIM(p_titulo),
        BTRIM(p_contenido),
        auth.uid()
    )
    RETURNING *
    INTO v_update;


    -- --------------------------------------------------------
    -- NOTIFICAR AL CLIENTE
    --
    -- El destinatario se obtiene internamente a partir de:
    --
    -- project_id
    --     ↓
    -- projects.user_id
    --
    -- El worker nunca proporciona el user_id del destinatario.
    -- --------------------------------------------------------

    PERFORM public.emit_project_client_notification(
        p_project_id,
        'project_update',
        v_update.titulo,
        'Hay una nueva actualización en tu proyecto.',
        jsonb_build_object(
            'project_update_id', v_update.id,
            'event', 'project_update_created'
        )
    );


    RETURN v_update;

END;
$$;


-- ------------------------------------------------------------
-- PERMISOS
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.create_project_update(
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.create_project_update(
    UUID,
    TEXT,
    TEXT
)
TO authenticated;


-- ============================================================
-- 8. RPC — ACTUALIZAR NOVEDAD
-- ============================================================
--
-- Permite al worker corregir una novedad ya publicada.
--
-- IMPORTANTE:
--
-- NO genera una segunda notificación.
--
-- Si el worker corrige:
--
-- "Diseño aprobad"
--
-- por:
--
-- "Diseño aprobado"
--
-- no queremos bombardear al cliente con otra notificación.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.update_project_update(
    p_update_id UUID,
    p_titulo TEXT,
    p_contenido TEXT
)
RETURNS public.project_updates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

    v_update public.project_updates;

BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- WORKER ACTIVO
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- --------------------------------------------------------
    -- TÍTULO
    -- --------------------------------------------------------

    IF p_titulo IS NULL
       OR LENGTH(BTRIM(p_titulo)) = 0
       OR LENGTH(p_titulo) > 200
    THEN
        RAISE EXCEPTION
            'El título de la novedad no es válido';
    END IF;


    -- --------------------------------------------------------
    -- CONTENIDO
    -- --------------------------------------------------------

    IF p_contenido IS NULL
       OR LENGTH(BTRIM(p_contenido)) = 0
       OR LENGTH(p_contenido) > 5000
    THEN
        RAISE EXCEPTION
            'El contenido de la novedad no es válido';
    END IF;


    -- --------------------------------------------------------
    -- OBTENER NOVEDAD
    -- --------------------------------------------------------

    SELECT *
    INTO v_update
    FROM public.project_updates
    WHERE id = p_update_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La novedad indicada no existe';
    END IF;


    -- --------------------------------------------------------
    -- ACTUALIZAR
    -- --------------------------------------------------------

    UPDATE public.project_updates
    SET
        titulo = BTRIM(p_titulo),
        contenido = BTRIM(p_contenido)
    WHERE id = p_update_id
    RETURNING *
    INTO v_update;


    RETURN v_update;

END;
$$;


-- ------------------------------------------------------------
-- PERMISOS
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.update_project_update(
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.update_project_update(
    UUID,
    TEXT,
    TEXT
)
TO authenticated;


-- ============================================================
-- 9. RPC — ELIMINAR NOVEDAD
-- ============================================================
--
-- Únicamente WORKER ACTIVO.
--
-- La eliminación de una novedad NO elimina la notificación
-- que ya recibió el cliente.
--
-- Esto es deliberado.
--
-- La notificación representa que el evento ocurrió.
--
-- La publicación representa el contenido actualmente visible.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.delete_project_update(
    p_update_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- WORKER ACTIVO
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- --------------------------------------------------------
    -- ID
    -- --------------------------------------------------------

    IF p_update_id IS NULL THEN
        RAISE EXCEPTION
            'La novedad es obligatoria';
    END IF;


    -- --------------------------------------------------------
    -- ELIMINAR
    -- --------------------------------------------------------

    DELETE FROM public.project_updates
    WHERE id = p_update_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La novedad indicada no existe';
    END IF;

END;
$$;


-- ------------------------------------------------------------
-- PERMISOS
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.delete_project_update(
    UUID
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.delete_project_update(
    UUID
)
TO authenticated;


-- ============================================================
-- 10. DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.project_updates
IS
'Actualizaciones editoriales de proyectos publicadas deliberadamente para el cliente. No sustituye activity_log, que continúa siendo el registro general de actividad de Modira.';


COMMENT ON COLUMN public.project_updates.project_id
IS
'Proyecto al que pertenece la actualización. El cliente accede a las actualizaciones mediante projects.user_id.';


COMMENT ON COLUMN public.project_updates.titulo
IS
'Título breve de la actualización que se mostrará en Últimas novedades del Área Cliente.';


COMMENT ON COLUMN public.project_updates.contenido
IS
'Contenido descriptivo de la actualización visible para el cliente.';


COMMENT ON COLUMN public.project_updates.created_by
IS
'Usuario trabajador que creó la actualización.';


COMMENT ON FUNCTION public.create_project_update(
    UUID,
    TEXT,
    TEXT
)
IS
'Crea una actualización visible para el cliente y genera una notificación asociada al proyecto. Solo puede ejecutarla un trabajador activo.';


COMMENT ON FUNCTION public.update_project_update(
    UUID,
    TEXT,
    TEXT
)
IS
'Modifica una actualización existente. No genera una nueva notificación. Solo puede ejecutarla un trabajador activo.';


COMMENT ON FUNCTION public.delete_project_update(
    UUID
)
IS
'Elimina una actualización del Área Cliente. Las notificaciones previamente generadas no se eliminan. Solo puede ejecutarla un trabajador activo.';


-- ============================================================
-- 11. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE

    v_count INTEGER;

    v_rls_enabled BOOLEAN;

BEGIN

    -- --------------------------------------------------------
    -- TABLA
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'project_updates';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '041 failed: project_updates table missing';
    END IF;


    -- --------------------------------------------------------
    -- COLUMNAS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'project_updates'
      AND column_name IN (
          'id',
          'project_id',
          'titulo',
          'contenido',
          'created_by',
          'created_at',
          'updated_at'
      );

    IF v_count <> 7 THEN
        RAISE EXCEPTION
            '041 failed: project_updates columns are incomplete';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    SELECT relrowsecurity
    INTO v_rls_enabled
    FROM pg_class
    WHERE oid = 'public.project_updates'::regclass;

    IF v_rls_enabled IS NOT TRUE THEN
        RAISE EXCEPTION
            '041 failed: RLS is not enabled on project_updates';
    END IF;


    -- --------------------------------------------------------
    -- SELECT POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_updates'
      AND policyname = 'project_updates_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '041 failed: project_updates_select policy missing';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT INSERT POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_updates'
      AND cmd = 'INSERT';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '041 failed: direct INSERT policy exists';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT UPDATE POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_updates'
      AND cmd = 'UPDATE';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '041 failed: direct UPDATE policy exists';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT DELETE POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_updates'
      AND cmd = 'DELETE';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '041 failed: direct DELETE policy exists';
    END IF;


    -- --------------------------------------------------------
    -- CREATE RPC
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.create_project_update(uuid,text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '041 failed: create_project_update() missing';
    END IF;


    -- --------------------------------------------------------
    -- UPDATE RPC
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.update_project_update(uuid,text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '041 failed: update_project_update() missing';
    END IF;


    -- --------------------------------------------------------
    -- DELETE RPC
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.delete_project_update(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '041 failed: delete_project_update() missing';
    END IF;


    -- --------------------------------------------------------
    -- UPDATED_AT FUNCTION
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.sync_project_update_updated_at()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '041 failed: update timestamp function missing';
    END IF;


    -- --------------------------------------------------------
    -- UPDATED_AT TRIGGER
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgname = 'project_updates_sync_updated_at'
      AND tgrelid = 'public.project_updates'::regclass
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '041 failed: update timestamp trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- CREATE RPC PRIVILEGE
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.create_project_update(uuid,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '041 failed: authenticated cannot execute create_project_update';
    END IF;


    -- --------------------------------------------------------
    -- UPDATE RPC PRIVILEGE
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.update_project_update(uuid,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '041 failed: authenticated cannot execute update_project_update';
    END IF;


    -- --------------------------------------------------------
    -- DELETE RPC PRIVILEGE
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.delete_project_update(uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '041 failed: authenticated cannot execute delete_project_update';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT TABLE INSERT
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.project_updates',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '041 failed: authenticated has direct INSERT privilege';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT TABLE UPDATE
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.project_updates',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '041 failed: authenticated has direct UPDATE privilege';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT TABLE DELETE
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.project_updates',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '041 failed: authenticated has direct DELETE privilege';
    END IF;

END $$;


-- ============================================================
-- FIN 041
-- ============================================================

COMMIT;