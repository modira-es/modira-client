BEGIN;

-- ============================================================
-- MODIRA — 039_project_milestones_and_progress.sql
--
-- OBJETIVO
-- ============================================================
--
-- Añadir un sistema de hitos para los proyectos de Modira.
--
-- Los hitos permitirán:
--
-- 1. Que un WORKER ACTIVO pueda:
--    - crear hitos;
--    - modificar hitos;
--    - cambiar su estado;
--    - cambiar su fecha prevista;
--    - cambiar su orden;
--    - eliminar hitos.
--
-- 2. Que un CLIENTE ACTIVO pueda:
--    - consultar los hitos de sus propios proyectos.
--
-- 3. Utilizar los hitos como fuente de verdad para:
--    - porcentaje de progreso;
--    - línea temporal del proyecto;
--    - calendario del proyecto.
--
-- IMPORTANTE
-- ============================================================
--
-- NO se modifica:
-- - public.projects
-- - public.activity_log
-- - public.project_documents
-- - public.project_change_requests
-- - quotations
-- - invoices
-- - payments
-- - ninguna RPC existente
--
-- El porcentaje NO se almacena físicamente en projects.
--
-- El progreso se obtiene de:
--
--   hitos completados / hitos totales * 100
--
-- De esta forma no existen dos fuentes de verdad.
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================
--
-- La migración depende de la arquitectura ya existente.
-- Si alguna pieza fundamental no existe, se detiene antes
-- de crear la nueva funcionalidad.
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
            '039 stopped: public.projects does not exist';
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
            '039 stopped: projects.id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECTS.USER_ID
    --
    -- El modelo definitivo de Modira utiliza user_id como
    -- propietario del proyecto para determinar el acceso
    -- del cliente.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'user_id'
    ) THEN
        RAISE EXCEPTION
            '039 stopped: projects.user_id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- CURRENT_USER_IS_WORKER()
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_user_is_worker()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '039 stopped: current_user_is_worker() does not exist';
    END IF;


    -- --------------------------------------------------------
    -- CURRENT_USER_IS_ACTIVE()
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_user_is_active()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '039 stopped: current_user_is_active() does not exist';
    END IF;

END $$;


-- ============================================================
-- 2. TABLA PROJECT_MILESTONES
-- ============================================================
--
-- Un proyecto puede tener:
--
-- 0 hitos
-- 1 hito
-- N hitos
--
-- Cada hito representa una meta concreta del proyecto.
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.project_milestones (

    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    project_id UUID NOT NULL
        REFERENCES public.projects(id)
        ON DELETE CASCADE,

    nombre TEXT NOT NULL,

    descripcion TEXT,

    fecha_prevista TIMESTAMPTZ NOT NULL,

    orden INTEGER NOT NULL
        DEFAULT 1,

    estado TEXT NOT NULL
        DEFAULT 'pendiente',

    completed_at TIMESTAMPTZ,

    created_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT project_milestones_nombre_check
        CHECK (
            LENGTH(BTRIM(nombre)) > 0
            AND LENGTH(nombre) <= 200
        ),

    CONSTRAINT project_milestones_descripcion_check
        CHECK (
            descripcion IS NULL
            OR LENGTH(descripcion) <= 2000
        ),

    CONSTRAINT project_milestones_orden_check
        CHECK (
            orden >= 1
            AND orden <= 10000
        ),

    CONSTRAINT project_milestones_estado_check
        CHECK (
            estado IN (
                'pendiente',
                'en_curso',
                'completado'
            )
        ),

    CONSTRAINT project_milestones_completed_at_check
        CHECK (
            (
                estado = 'completado'
                AND completed_at IS NOT NULL
            )
            OR
            (
                estado <> 'completado'
                AND completed_at IS NULL
            )
        )
);


-- ============================================================
-- 3. ÍNDICES
-- ============================================================
--
-- Se optimizan principalmente las consultas del dashboard:
--
-- proyecto → hitos ordenados
-- proyecto → hitos por estado
-- calendario → hitos por fecha
--
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_project_milestones_project_id
ON public.project_milestones (
    project_id
);


CREATE INDEX IF NOT EXISTS
    idx_project_milestones_project_order
ON public.project_milestones (
    project_id,
    orden,
    created_at
);


CREATE INDEX IF NOT EXISTS
    idx_project_milestones_project_date
ON public.project_milestones (
    project_id,
    fecha_prevista
);


CREATE INDEX IF NOT EXISTS
    idx_project_milestones_project_status
ON public.project_milestones (
    project_id,
    estado
);


-- ============================================================
-- 4. TRIGGER — UPDATED_AT + COMPLETED_AT
-- ============================================================
--
-- Mantiene automáticamente:
--
-- updated_at
--
-- y garantiza la coherencia de:
--
-- estado = completado
--          ↓
-- completed_at = timestamp
--
-- estado != completado
--          ↓
-- completed_at = NULL
--
-- No depende del frontend.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.sync_project_milestone_timestamps()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    -- --------------------------------------------------------
    -- UPDATED_AT
    -- --------------------------------------------------------

    NEW.updated_at := CURRENT_TIMESTAMP;


    -- --------------------------------------------------------
    -- COMPLETED_AT
    -- --------------------------------------------------------

    IF NEW.estado = 'completado' THEN

        IF OLD.estado IS DISTINCT FROM 'completado'
           OR NEW.completed_at IS NULL
        THEN
            NEW.completed_at := CURRENT_TIMESTAMP;
        END IF;

    ELSE

        NEW.completed_at := NULL;

    END IF;


    RETURN NEW;

END;
$$;


DROP TRIGGER IF EXISTS
    project_milestones_sync_timestamps
ON public.project_milestones;


CREATE TRIGGER
    project_milestones_sync_timestamps
BEFORE INSERT OR UPDATE
ON public.project_milestones
FOR EACH ROW
EXECUTE FUNCTION
    public.sync_project_milestone_timestamps();


-- ============================================================
-- 5. RLS
-- ============================================================
--
-- CLIENTE:
--   SELECT únicamente de sus proyectos.
--
-- WORKER ACTIVO:
--   SELECT de todos los hitos.
--
-- NO se crean policies de INSERT / UPDATE / DELETE.
--
-- Las modificaciones se realizan exclusivamente mediante
-- RPC SECURITY DEFINER.
--
-- Esto sigue el patrón utilizado por Modira en las
-- operaciones sensibles de documentos y otros recursos.
--
-- ============================================================

ALTER TABLE public.project_milestones
ENABLE ROW LEVEL SECURITY;


-- ------------------------------------------------------------
-- Eliminar únicamente policies de esta nueva tabla.
-- ------------------------------------------------------------

DROP POLICY IF EXISTS
    project_milestones_select
ON public.project_milestones;


-- ------------------------------------------------------------
-- SELECT
--
-- WORKER ACTIVO:
--   puede consultar todos los hitos.
--
-- CLIENTE ACTIVO:
--   únicamente los hitos cuyo proyecto le pertenece.
-- ------------------------------------------------------------

CREATE POLICY
    project_milestones_select
ON public.project_milestones
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
            WHERE p.id = project_milestones.project_id
              AND p.user_id = auth.uid()
        )
    )

);


-- ============================================================
-- 6. PRIVILEGIOS DIRECTOS DE TABLA
-- ============================================================
--
-- El frontend puede consultar mediante SELECT + RLS.
--
-- No se conceden:
--
-- INSERT
-- UPDATE
-- DELETE
--
-- Las escrituras se realizan mediante RPC protegidas.
--
-- ============================================================

REVOKE ALL
ON public.project_milestones
FROM PUBLIC, anon, authenticated;


GRANT SELECT
ON public.project_milestones
TO authenticated;


-- ============================================================
-- 7. RPC — CREAR HITO
-- ============================================================
--
-- Únicamente un WORKER ACTIVO puede crear hitos.
--
-- El project_id se valida contra projects.
--
-- El orden se calcula automáticamente como:
--
-- MAX(orden) + 1
--
-- Por tanto el frontend no puede manipular el orden inicial
-- de forma arbitraria.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.create_project_milestone(
    p_project_id UUID,
    p_nombre TEXT,
    p_descripcion TEXT DEFAULT NULL,
    p_fecha_prevista TIMESTAMPTZ DEFAULT NULL
)
RETURNS public.project_milestones
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

    v_milestone public.project_milestones;

    v_next_order INTEGER;

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
    -- NOMBRE
    -- --------------------------------------------------------

    IF p_nombre IS NULL
       OR LENGTH(BTRIM(p_nombre)) = 0
       OR LENGTH(p_nombre) > 200
    THEN
        RAISE EXCEPTION
            'El nombre del hito no es válido';
    END IF;


    -- --------------------------------------------------------
    -- DESCRIPCIÓN
    -- --------------------------------------------------------

    IF p_descripcion IS NOT NULL
       AND LENGTH(p_descripcion) > 2000
    THEN
        RAISE EXCEPTION
            'La descripción del hito no puede superar 2000 caracteres';
    END IF;


    -- --------------------------------------------------------
    -- FECHA
    -- --------------------------------------------------------

    IF p_fecha_prevista IS NULL THEN
        RAISE EXCEPTION
            'La fecha prevista del hito es obligatoria';
    END IF;


    -- --------------------------------------------------------
    -- PROYECTO
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
    -- SIGUIENTE ORDEN
    -- --------------------------------------------------------

    SELECT
        COALESCE(MAX(orden), 0) + 1
    INTO
        v_next_order
    FROM public.project_milestones
    WHERE project_id = p_project_id;


    -- --------------------------------------------------------
    -- CREAR HITO
    -- --------------------------------------------------------

    INSERT INTO public.project_milestones (
        project_id,
        nombre,
        descripcion,
        fecha_prevista,
        orden,
        estado,
        created_by
    )
    VALUES (
        p_project_id,
        BTRIM(p_nombre),
        NULLIF(BTRIM(p_descripcion), ''),
        p_fecha_prevista,
        v_next_order,
        'pendiente',
        auth.uid()
    )
    RETURNING *
    INTO v_milestone;


    RETURN v_milestone;

END;
$$;


-- ------------------------------------------------------------
-- PROTEGER RPC
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.create_project_milestone(
    UUID,
    TEXT,
    TEXT,
    TIMESTAMPTZ
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.create_project_milestone(
    UUID,
    TEXT,
    TEXT,
    TIMESTAMPTZ
)
TO authenticated;


-- ============================================================
-- 8. RPC — ACTUALIZAR HITO
-- ============================================================
--
-- Permite al WORKER ACTIVO modificar:
--
-- - nombre
-- - descripción
-- - fecha prevista
-- - orden
-- - estado
--
-- El trigger se encarga de mantener completed_at coherente.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.update_project_milestone(
    p_milestone_id UUID,
    p_nombre TEXT,
    p_descripcion TEXT DEFAULT NULL,
    p_fecha_prevista TIMESTAMPTZ DEFAULT NULL,
    p_orden INTEGER DEFAULT NULL,
    p_estado TEXT DEFAULT NULL
)
RETURNS public.project_milestones
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

    v_milestone public.project_milestones;

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

    IF p_milestone_id IS NULL THEN
        RAISE EXCEPTION
            'El hito es obligatorio';
    END IF;


    -- --------------------------------------------------------
    -- NOMBRE
    -- --------------------------------------------------------

    IF p_nombre IS NULL
       OR LENGTH(BTRIM(p_nombre)) = 0
       OR LENGTH(p_nombre) > 200
    THEN
        RAISE EXCEPTION
            'El nombre del hito no es válido';
    END IF;


    -- --------------------------------------------------------
    -- DESCRIPCIÓN
    -- --------------------------------------------------------

    IF p_descripcion IS NOT NULL
       AND LENGTH(p_descripcion) > 2000
    THEN
        RAISE EXCEPTION
            'La descripción del hito no puede superar 2000 caracteres';
    END IF;


    -- --------------------------------------------------------
    -- FECHA
    -- --------------------------------------------------------

    IF p_fecha_prevista IS NULL THEN
        RAISE EXCEPTION
            'La fecha prevista del hito es obligatoria';
    END IF;


    -- --------------------------------------------------------
    -- ORDEN
    -- --------------------------------------------------------

    IF p_orden IS NOT NULL
       AND (
            p_orden < 1
            OR p_orden > 10000
       )
    THEN
        RAISE EXCEPTION
            'El orden del hito no es válido';
    END IF;


    -- --------------------------------------------------------
    -- ESTADO
    -- --------------------------------------------------------

    IF p_estado IS NULL
       OR p_estado NOT IN (
            'pendiente',
            'en_curso',
            'completado'
       )
    THEN
        RAISE EXCEPTION
            'El estado del hito no es válido';
    END IF;


    -- --------------------------------------------------------
    -- OBTENER HITO
    -- --------------------------------------------------------

    SELECT *
    INTO v_milestone
    FROM public.project_milestones
    WHERE id = p_milestone_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El hito indicado no existe';
    END IF;


    -- --------------------------------------------------------
    -- ACTUALIZAR
    -- --------------------------------------------------------

    UPDATE public.project_milestones
    SET
        nombre = BTRIM(p_nombre),

        descripcion =
            NULLIF(BTRIM(p_descripcion), ''),

        fecha_prevista =
            p_fecha_prevista,

        orden =
            COALESCE(p_orden, orden),

        estado =
            p_estado

    WHERE id = p_milestone_id

    RETURNING *
    INTO v_milestone;


    RETURN v_milestone;

END;
$$;


-- ------------------------------------------------------------
-- PROTEGER RPC
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.update_project_milestone(
    UUID,
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    INTEGER,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.update_project_milestone(
    UUID,
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    INTEGER,
    TEXT
)
TO authenticated;


-- ============================================================
-- 9. RPC — ELIMINAR HITO
-- ============================================================
--
-- Únicamente WORKER ACTIVO.
--
-- Eliminar un hito modifica naturalmente el porcentaje de
-- progreso porque el número total de hitos cambia.
--
-- Esto es intencionado: los hitos son la fuente de verdad.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.delete_project_milestone(
    p_milestone_id UUID
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

    IF p_milestone_id IS NULL THEN
        RAISE EXCEPTION
            'El hito es obligatorio';
    END IF;


    -- --------------------------------------------------------
    -- ELIMINAR
    -- --------------------------------------------------------

    DELETE FROM public.project_milestones
    WHERE id = p_milestone_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El hito indicado no existe';
    END IF;

END;
$$;


-- ------------------------------------------------------------
-- PROTEGER RPC
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.delete_project_milestone(
    UUID
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.delete_project_milestone(
    UUID
)
TO authenticated;


-- ============================================================
-- 10. RPC — MARCAR HITO COMPLETADO / CAMBIAR ESTADO
-- ============================================================
--
-- Esta RPC simplifica la operación más habitual del worker:
--
--   pendiente
--       ↓
--   en_curso
--       ↓
--   completado
--
-- El trigger asignará automáticamente completed_at.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.set_project_milestone_status(
    p_milestone_id UUID,
    p_estado TEXT
)
RETURNS public.project_milestones
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

    v_milestone public.project_milestones;

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
    -- ESTADO
    -- --------------------------------------------------------

    IF p_estado IS NULL
       OR p_estado NOT IN (
            'pendiente',
            'en_curso',
            'completado'
       )
    THEN
        RAISE EXCEPTION
            'El estado del hito no es válido';
    END IF;


    -- --------------------------------------------------------
    -- OBTENER HITO
    -- --------------------------------------------------------

    SELECT *
    INTO v_milestone
    FROM public.project_milestones
    WHERE id = p_milestone_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El hito indicado no existe';
    END IF;


    -- --------------------------------------------------------
    -- ACTUALIZAR ESTADO
    -- --------------------------------------------------------

    UPDATE public.project_milestones
    SET
        estado = p_estado
    WHERE id = p_milestone_id
    RETURNING *
    INTO v_milestone;


    RETURN v_milestone;

END;
$$;


-- ------------------------------------------------------------
-- PROTEGER RPC
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.set_project_milestone_status(
    UUID,
    TEXT
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.set_project_milestone_status(
    UUID,
    TEXT
)
TO authenticated;


-- ============================================================
-- 11. VISTA DE PROGRESO
-- ============================================================
--
-- El porcentaje NO se almacena.
--
-- Esta vista calcula:
--
-- total_milestones
-- completed_milestones
-- progress_percentage
--
-- Ejemplo:
--
-- 5 hitos
-- 3 completados
--
-- 3 / 5 * 100 = 60%
--
-- La vista utiliza security_invoker para que el acceso quede
-- sujeto a las RLS de project_milestones.
--
-- ============================================================

CREATE OR REPLACE VIEW public.project_progress
WITH (security_invoker = true)
AS
SELECT

    p.id AS project_id,

    COUNT(pm.id)::INTEGER
        AS total_milestones,

    COUNT(pm.id)
        FILTER (
            WHERE pm.estado = 'completado'
        )::INTEGER
        AS completed_milestones,

    CASE
        WHEN COUNT(pm.id) = 0 THEN 0
        ELSE ROUND(
            (
                COUNT(pm.id)
                FILTER (
                    WHERE pm.estado = 'completado'
                )::NUMERIC
                /
                COUNT(pm.id)::NUMERIC
            ) * 100
        )::INTEGER
    END AS progress_percentage

FROM public.projects p

LEFT JOIN public.project_milestones pm
    ON pm.project_id = p.id

GROUP BY
    p.id;


-- ============================================================
-- 12. PRIVILEGIOS DE LA VISTA
-- ============================================================
--
-- El cliente/worker puede consultar la vista.
--
-- El acceso efectivo queda limitado por security_invoker
-- + RLS de project_milestones.
--
-- ============================================================

REVOKE ALL
ON public.project_progress
FROM PUBLIC, anon;


GRANT SELECT
ON public.project_progress
TO authenticated;


-- ============================================================
-- 13. DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.project_milestones
IS
'Metas e hitos de los proyectos de Modira. Los trabajadores activos los gestionan mediante RPC y los clientes activos únicamente pueden consultar los hitos de sus propios proyectos.';


COMMENT ON COLUMN public.project_milestones.fecha_prevista
IS
'Fecha y hora prevista para alcanzar el hito. Se utiliza también como fuente de datos para el calendario del proyecto.';


COMMENT ON COLUMN public.project_milestones.orden
IS
'Orden visual del hito dentro de la línea temporal del proyecto.';


COMMENT ON COLUMN public.project_milestones.estado
IS
'Estado del hito: pendiente, en_curso o completado.';


COMMENT ON COLUMN public.project_milestones.completed_at
IS
'Momento en el que el hito pasó a estado completado. Se mantiene automáticamente mediante trigger.';


COMMENT ON VIEW public.project_progress
IS
'Progreso calculado de cada proyecto a partir de sus hitos completados. No almacena un porcentaje físico en projects.';


-- ============================================================
-- 14. VALIDACIONES FINALES
-- ============================================================
--
-- La migración debe terminar únicamente si toda la
-- infraestructura esperada existe.
--
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
      AND table_name = 'project_milestones';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '039 failed: project_milestones table missing';
    END IF;


    -- --------------------------------------------------------
    -- COLUMNAS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'project_milestones'
      AND column_name IN (
          'id',
          'project_id',
          'nombre',
          'descripcion',
          'fecha_prevista',
          'orden',
          'estado',
          'completed_at',
          'created_by',
          'created_at',
          'updated_at'
      );

    IF v_count <> 11 THEN
        RAISE EXCEPTION
            '039 failed: project_milestones columns are incomplete';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    SELECT relrowsecurity
    INTO v_rls_enabled
    FROM pg_class
    WHERE oid = 'public.project_milestones'::regclass;

    IF v_rls_enabled IS NOT TRUE THEN
        RAISE EXCEPTION
            '039 failed: RLS is not enabled on project_milestones';
    END IF;


    -- --------------------------------------------------------
    -- SELECT POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_milestones'
      AND policyname = 'project_milestones_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '039 failed: project_milestones_select policy missing';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT INSERT POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_milestones'
      AND cmd = 'INSERT';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '039 failed: direct INSERT policy exists';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT UPDATE POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_milestones'
      AND cmd = 'UPDATE';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '039 failed: direct UPDATE policy exists';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT DELETE POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'project_milestones'
      AND cmd = 'DELETE';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '039 failed: direct DELETE policy exists';
    END IF;


    -- --------------------------------------------------------
    -- RPC CREATE
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.create_project_milestone(uuid,text,text,timestamp with time zone)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '039 failed: create_project_milestone() missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC UPDATE
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.update_project_milestone(uuid,text,text,timestamp with time zone,integer,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '039 failed: update_project_milestone() missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC DELETE
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.delete_project_milestone(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '039 failed: delete_project_milestone() missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC STATUS
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.set_project_milestone_status(uuid,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '039 failed: set_project_milestone_status() missing';
    END IF;


    -- --------------------------------------------------------
    -- VIEW
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.views
        WHERE table_schema = 'public'
          AND table_name = 'project_progress'
    ) THEN
        RAISE EXCEPTION
            '039 failed: project_progress view missing';
    END IF;


    -- --------------------------------------------------------
    -- FUNCIÓN DEL TRIGGER
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.sync_project_milestone_timestamps()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '039 failed: milestone timestamp trigger function missing';
    END IF;


    -- --------------------------------------------------------
    -- TRIGGER
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgname = 'project_milestones_sync_timestamps'
      AND tgrelid = 'public.project_milestones'::regclass
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '039 failed: milestone timestamp trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- PRIVILEGIOS DIRECTOS
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.project_milestones',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '039 failed: authenticated has direct INSERT privilege';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.project_milestones',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '039 failed: authenticated has direct UPDATE privilege';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.project_milestones',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '039 failed: authenticated has direct DELETE privilege';
    END IF;


    -- --------------------------------------------------------
    -- EXECUTE PRIVILEGES
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.create_project_milestone(uuid,text,text,timestamp with time zone)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '039 failed: authenticated cannot execute create_project_milestone';
    END IF;


    IF NOT has_function_privilege(
        'authenticated',
        'public.update_project_milestone(uuid,text,text,timestamp with time zone,integer,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '039 failed: authenticated cannot execute update_project_milestone';
    END IF;


    IF NOT has_function_privilege(
        'authenticated',
        'public.delete_project_milestone(uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '039 failed: authenticated cannot execute delete_project_milestone';
    END IF;


    IF NOT has_function_privilege(
        'authenticated',
        'public.set_project_milestone_status(uuid,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '039 failed: authenticated cannot execute set_project_milestone_status';
    END IF;

END $$;


-- ============================================================
-- FIN 039
-- ============================================================

COMMIT;