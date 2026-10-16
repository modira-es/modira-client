-- ============================================================
-- 118_update_project_description_worker.sql
-- ============================================================
-- Permite a trabajadores con projects.update modificar también
-- la descripción de un proyecto desde update_project_by_worker.
--
-- Mantiene:
--   - require_current_worker_permission('projects.update')
--   - current_user_is_worker()
--   - validación del estado
--   - validación del nombre
--   - validación de existencia del proyecto
--
-- Añade:
--   - p_descripcion TEXT
--   - actualización de projects.descripcion
-- ============================================================

BEGIN;


-- ============================================================
-- 1. LEGACY
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_project_by_worker__legacy_113(
    p_project_id uuid,
    p_nombre text DEFAULT NULL,
    p_estado text DEFAULT NULL,
    p_descripcion text DEFAULT NULL
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_project public.projects;
BEGIN

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    IF p_estado IS NOT NULL
       AND p_estado NOT IN (
           'Pendiente',
           'Activo',
           'Pausado',
           'Entregado',
           'Completado'
       )
    THEN
        RAISE EXCEPTION
            'Estado de proyecto no válido: %',
            p_estado;
    END IF;


    IF p_nombre IS NOT NULL
       AND TRIM(p_nombre) = ''
    THEN
        RAISE EXCEPTION
            'El nombre del proyecto no puede estar vacío';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = p_project_id
    ) THEN
        RAISE EXCEPTION
            'Proyecto no encontrado';
    END IF;


    UPDATE public.projects
    SET
        nombre = CASE
            WHEN p_nombre IS NULL THEN nombre
            ELSE TRIM(p_nombre)
        END,

        estado = COALESCE(
            p_estado,
            estado
        ),

        descripcion = CASE
            WHEN p_descripcion IS NULL THEN descripcion
            ELSE NULLIF(
                TRIM(p_descripcion),
                ''
            )
        END,

        updated_at = CURRENT_TIMESTAMP

    WHERE id = p_project_id

    RETURNING *
    INTO v_project;


    RETURN v_project;

END;
$function$;


-- ============================================================
-- 2. WRAPPER PÚBLICO
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_project_by_worker(
    p_project_id uuid,
    p_nombre text DEFAULT NULL,
    p_estado text DEFAULT NULL,
    p_descripcion text DEFAULT NULL
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN

    PERFORM public.require_current_worker_permission(
        'projects.update'
    );


    RETURN public.update_project_by_worker__legacy_113(
        p_project_id,
        p_nombre,
        p_estado,
        p_descripcion
    );

END;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

REVOKE ALL ON FUNCTION public.update_project_by_worker(
    uuid,
    text,
    text,
    text
) FROM PUBLIC;


GRANT EXECUTE ON FUNCTION public.update_project_by_worker(
    uuid,
    text,
    text,
    text
) TO authenticated;


-- ============================================================
-- 4. COMPROBACIONES
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'update_project_by_worker'
          AND pg_get_function_identity_arguments(p.oid)
              = 'p_project_id uuid, p_nombre text, p_estado text, p_descripcion text'
    ) THEN
        RAISE EXCEPTION
            '118 failed: update_project_by_worker was not updated correctly';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
            ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'update_project_by_worker__legacy_113'
          AND pg_get_function_identity_arguments(p.oid)
              = 'p_project_id uuid, p_nombre text, p_estado text, p_descripcion text'
    ) THEN
        RAISE EXCEPTION
            '118 failed: legacy project update function was not updated correctly';
    END IF;


    RAISE NOTICE
        '118 OK: workers with projects.update can update project description';

END;
$$;


COMMIT;