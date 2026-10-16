-- ============================================================================
-- 089_maintenance_contract_project_integrity.sql
-- ============================================================================
--
-- OBJETIVO
-- ----------------------------------------------------------------------------
-- Endurece la relación entre maintenance_contracts y projects.
--
-- REGLAS DEL MODELO:
--
-- 1. Un contrato de mantenimiento activo/pausado puede cubrir COMO MÁXIMO
--    un proyecto.
--
-- 2. Un proyecto puede tener COMO MÁXIMO un contrato activo/pausado.
--
-- 3. Los contratos históricos (cancelados, etc.) pueden seguir conservando
--    sus relaciones con proyectos.
--
-- 4. Un proyecto puede volver a contratar mantenimiento después de cancelar
--    su contrato anterior.
--
-- 5. Una empresa puede tener múltiples contratos de mantenimiento.
--
-- 6. La protección se realiza en PostgreSQL y no depende del frontend.
--
-- 7. Se utilizan advisory locks transaccionales para evitar carreras entre
--    dos operaciones concurrentes.
--
-- 8. No se elimina ni modifica automáticamente ningún dato existente.
--    Si existen datos que violan las nuevas reglas, la migración se detiene.
--
-- ============================================================================


BEGIN;


-- ============================================================================
-- 1. COMPROBACIONES PREVIAS
-- ============================================================================

DO $$
BEGIN

    IF to_regclass('public.maintenance_contracts') IS NULL THEN
        RAISE EXCEPTION
            '089 stopped: public.maintenance_contracts no existe';
    END IF;


    IF to_regclass('public.maintenance_contract_projects') IS NULL THEN
        RAISE EXCEPTION
            '089 stopped: public.maintenance_contract_projects no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_contracts'
          AND column_name = 'estado'
    ) THEN
        RAISE EXCEPTION
            '089 stopped: maintenance_contracts.estado no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_contract_projects'
          AND column_name = 'maintenance_contract_id'
    ) THEN
        RAISE EXCEPTION
            '089 stopped: maintenance_contract_projects.maintenance_contract_id no existe';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_contract_projects'
          AND column_name = 'project_id'
    ) THEN
        RAISE EXCEPTION
            '089 stopped: maintenance_contract_projects.project_id no existe';
    END IF;

END;
$$;


-- ============================================================================
-- 2. DETECTAR DATOS EXISTENTES INCOMPATIBLES
-- ============================================================================
--
-- No modificamos datos automáticamente.
--
-- Si actualmente existe:
--
--   CONTRATO ACTIVO
--       ├── PROYECTO A
--       └── PROYECTO B
--
-- la migración se detiene.
--
-- Lo mismo ocurre si:
--
--   PROYECTO A
--       ├── CONTRATO ACTIVO 1
--       └── CONTRATO ACTIVO 2
--
-- Esto evita que una migración de seguridad borre datos de producción
-- sin que el administrador haya decidido cuál debe conservarse.
-- ============================================================================


DO $$
DECLARE
    v_contract_id UUID;
    v_project_count INTEGER;
BEGIN

    SELECT
        mcp.maintenance_contract_id
    INTO
        v_contract_id
    FROM public.maintenance_contract_projects mcp
    JOIN public.maintenance_contracts mc
      ON mc.id = mcp.maintenance_contract_id
    WHERE mc.estado IN ('activo', 'pausado')
    GROUP BY mcp.maintenance_contract_id
    HAVING COUNT(*) > 1
    ORDER BY mcp.maintenance_contract_id
    LIMIT 1;


    IF v_contract_id IS NOT NULL THEN

        SELECT COUNT(*)
        INTO v_project_count
        FROM public.maintenance_contract_projects
        WHERE maintenance_contract_id = v_contract_id;


        RAISE EXCEPTION
            '089 stopped: el contrato % tiene % proyectos asociados mientras está activo/pausado. Debe existir como máximo un proyecto por contrato activo.',
            v_contract_id,
            v_project_count;

    END IF;

END;
$$;


DO $$
DECLARE
    v_project_id UUID;
    v_contract_count INTEGER;
BEGIN

    SELECT
        mcp.project_id
    INTO
        v_project_id
    FROM public.maintenance_contract_projects mcp
    JOIN public.maintenance_contracts mc
      ON mc.id = mcp.maintenance_contract_id
    WHERE mc.estado IN ('activo', 'pausado')
    GROUP BY mcp.project_id
    HAVING COUNT(DISTINCT mcp.maintenance_contract_id) > 1
    ORDER BY mcp.project_id
    LIMIT 1;


    IF v_project_id IS NOT NULL THEN

        SELECT COUNT(DISTINCT mcp.maintenance_contract_id)
        INTO v_contract_count
        FROM public.maintenance_contract_projects mcp
        JOIN public.maintenance_contracts mc
          ON mc.id = mcp.maintenance_contract_id
        WHERE mcp.project_id = v_project_id
          AND mc.estado IN ('activo', 'pausado');


        RAISE EXCEPTION
            '089 stopped: el proyecto % tiene % contratos activos/pausados. Debe existir como máximo un contrato activo por proyecto.',
            v_project_id,
            v_contract_count;

    END IF;

END;
$$;


-- ============================================================================
-- 3. FUNCIÓN AUXILIAR — CONTRATO ACTIVO
-- ============================================================================
--
-- "activo" y "pausado" se consideran contratos vivos dentro del modelo
-- actual de ClientMaintenance.
--
-- Un contrato "cancelado" deja de ocupar el proyecto y permite una nueva
-- contratación futura.
-- ============================================================================


CREATE OR REPLACE FUNCTION public.is_live_maintenance_contract_status(
    p_status TEXT
)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
STRICT
AS $function$

    SELECT LOWER(TRIM(p_status)) IN (
        'activo',
        'pausado'
    );

$function$;


REVOKE ALL
ON FUNCTION public.is_live_maintenance_contract_status(TEXT)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.is_live_maintenance_contract_status(TEXT)
TO service_role;


COMMENT ON FUNCTION public.is_live_maintenance_contract_status(TEXT)
IS
'Indica si un contrato de mantenimiento ocupa actualmente su proyecto. Activo y pausado se consideran contratos vivos; los contratos cancelados/liberados no.';


-- ============================================================================
-- 4. FUNCIÓN — VALIDAR RELACIÓN CONTRATO ↔ PROYECTO
-- ============================================================================
--
-- Esta es la protección principal.
--
-- Se ejecuta antes de INSERT/UPDATE en maintenance_contract_projects.
--
-- Garantiza:
--
-- A) Un contrato vivo solo puede tener un proyecto.
--
-- B) Un proyecto solo puede tener un contrato vivo.
--
-- C) Las operaciones concurrentes quedan serializadas mediante advisory locks.
--
-- D) La regla se aplica independientemente de que la escritura venga de:
--
--      Edge Function
--      RPC
--      service_role
--      worker backend
--      otro proceso futuro
--
-- E) No se limita a authenticated.
--    Es una regla real de integridad de base de datos.
-- ============================================================================


CREATE OR REPLACE FUNCTION public.validate_maintenance_contract_project_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_contract_status TEXT;
    v_contract_is_live BOOLEAN;

    v_existing_project_id UUID;
    v_existing_contract_id UUID;

BEGIN

    -- ========================================================
    -- 1. OBTENER ESTADO DEL CONTRATO
    -- ========================================================

    SELECT mc.estado
    INTO v_contract_status
    FROM public.maintenance_contracts mc
    WHERE mc.id = NEW.maintenance_contract_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El contrato de mantenimiento indicado no existe';
    END IF;


    v_contract_is_live :=
        public.is_live_maintenance_contract_status(
            v_contract_status
        );


    -- ========================================================
    -- 2. LOCK DEL CONTRATO
    -- ========================================================
    --
    -- Siempre bloqueamos primero el contrato y después el proyecto.
    -- Esto mantiene un orden consistente y reduce el riesgo de deadlocks
    -- cuando existen operaciones concurrentes.
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'maintenance-contract:' ||
            NEW.maintenance_contract_id::TEXT,
            0
        )
    );


    -- ========================================================
    -- 3. LOCK DEL PROYECTO
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'maintenance-project:' ||
            NEW.project_id::TEXT,
            0
        )
    );


    -- ========================================================
    -- 4. SI EL CONTRATO NO ESTÁ VIVO
    -- ========================================================
    --
    -- Los contratos históricos pueden conservar relaciones.
    --
    -- Por tanto:
    --
    -- CANCELADO + PROYECTO
    --
    -- sigue siendo válido.
    -- ========================================================

    IF NOT v_contract_is_live THEN

        RETURN NEW;

    END IF;


    -- ========================================================
    -- 5. UN CONTRATO VIVO → COMO MÁXIMO UN PROYECTO
    -- ========================================================

    SELECT mcp.project_id
    INTO v_existing_project_id
    FROM public.maintenance_contract_projects mcp
    WHERE mcp.maintenance_contract_id =
          NEW.maintenance_contract_id
      AND mcp.id IS DISTINCT FROM NEW.id
    LIMIT 1;


    IF v_existing_project_id IS NOT NULL THEN

        RAISE EXCEPTION
            'El contrato de mantenimiento % ya está asociado al proyecto %. Un contrato activo o pausado solo puede cubrir un proyecto.',
            NEW.maintenance_contract_id,
            v_existing_project_id;

    END IF;


    -- ========================================================
    -- 6. UN PROYECTO VIVO → COMO MÁXIMO UN CONTRATO VIVO
    -- ========================================================

    SELECT mcp.maintenance_contract_id
    INTO v_existing_contract_id
    FROM public.maintenance_contract_projects mcp
    JOIN public.maintenance_contracts mc
      ON mc.id = mcp.maintenance_contract_id
    WHERE mcp.project_id = NEW.project_id
      AND mcp.id IS DISTINCT FROM NEW.id
      AND public.is_live_maintenance_contract_status(
          mc.estado
      )
    LIMIT 1;


    IF v_existing_contract_id IS NOT NULL THEN

        RAISE EXCEPTION
            'El proyecto % ya está asociado al contrato de mantenimiento activo/pausado %. No puede existir más de un contrato de mantenimiento activo por proyecto.',
            NEW.project_id,
            v_existing_contract_id;

    END IF;


    RETURN NEW;

END;
$function$;


REVOKE ALL
ON FUNCTION public.validate_maintenance_contract_project_integrity()
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.validate_maintenance_contract_project_integrity()
TO service_role;


-- ============================================================================
-- 5. TRIGGER DE LA RELACIÓN CONTRATO ↔ PROYECTO
-- ============================================================================


DROP TRIGGER IF EXISTS
    maintenance_contract_projects_integrity
ON public.maintenance_contract_projects;


CREATE TRIGGER
    maintenance_contract_projects_integrity
BEFORE INSERT OR UPDATE
ON public.maintenance_contract_projects
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_contract_project_integrity();


-- ============================================================================
-- 6. FUNCIÓN — VALIDAR ACTIVACIÓN DEL CONTRATO
-- ============================================================================
--
-- La protección anterior cubre:
--
--      INSERT/UPDATE maintenance_contract_projects
--
-- pero también necesitamos cubrir:
--
--      UPDATE maintenance_contracts
--      SET estado = 'activo'
--
-- porque un contrato podría tener una relación mientras está cancelado
-- y posteriormente intentar pasar a activo.
--
-- Esta función comprueba que, cuando un contrato está vivo:
--
-- A) tiene como máximo un proyecto;
--
-- B) ninguno de sus proyectos pertenece ya a otro contrato vivo.
-- ============================================================================


CREATE OR REPLACE FUNCTION public.validate_maintenance_contract_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_project_id UUID;
    v_other_contract_id UUID;
BEGIN

    -- ========================================================
    -- 1. LOCK DEL CONTRATO
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'maintenance-contract:' ||
            NEW.id::TEXT,
            0
        )
    );


    -- ========================================================
    -- 2. SI EL CONTRATO NO ESTÁ VIVO
    -- ========================================================

    IF NOT public.is_live_maintenance_contract_status(
        NEW.estado
    ) THEN

        RETURN NEW;

    END IF;


    -- ========================================================
    -- 3. UN CONTRATO VIVO → COMO MÁXIMO UN PROYECTO
    -- ========================================================

    SELECT mcp.project_id
    INTO v_project_id
    FROM public.maintenance_contract_projects mcp
    WHERE mcp.maintenance_contract_id = NEW.id
    ORDER BY mcp.created_at, mcp.id
    OFFSET 1
    LIMIT 1;


    IF v_project_id IS NOT NULL THEN

        RAISE EXCEPTION
            'El contrato de mantenimiento % tiene más de un proyecto asociado y no puede permanecer activo/pausado.',
            NEW.id;

    END IF;


    -- ========================================================
    -- 4. COMPROBAR CONFLICTO DE PROYECTO
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.maintenance_contract_projects mcp
        JOIN public.maintenance_contracts other_mc
          ON other_mc.id = mcp.maintenance_contract_id
        WHERE mcp.maintenance_contract_id = NEW.id
          AND mcp.project_id IS NOT NULL
          AND other_mc.id <> NEW.id
        LIMIT 1
    ) THEN

        SELECT other_mc.id
        INTO v_other_contract_id
        FROM public.maintenance_contract_projects mcp
        JOIN public.maintenance_contracts other_mc
          ON other_mc.id = mcp.maintenance_contract_id
        WHERE mcp.project_id IN (
            SELECT mcp2.project_id
            FROM public.maintenance_contract_projects mcp2
            WHERE mcp2.maintenance_contract_id = NEW.id
        )
          AND other_mc.id <> NEW.id
          AND public.is_live_maintenance_contract_status(
              other_mc.estado
          )
        LIMIT 1;


        IF v_other_contract_id IS NOT NULL THEN

            RAISE EXCEPTION
                'El contrato de mantenimiento % intenta quedar activo/pausado sobre un proyecto que ya pertenece al contrato activo/pausado %.',
                NEW.id,
                v_other_contract_id;

        END IF;

    END IF;


    -- ========================================================
    -- 5. LOCK DE LOS PROYECTOS ASOCIADOS
    -- ========================================================
    --
    -- Se hace después del lock del contrato para mantener el mismo
    -- orden de bloqueo que utiliza la función de relaciones.
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'maintenance-project:' ||
            mcp.project_id::TEXT,
            0
        )
    )
    FROM public.maintenance_contract_projects mcp
    WHERE mcp.maintenance_contract_id = NEW.id;


    -- ========================================================
    -- 6. COMPROBACIÓN DEFINITIVA TRAS LOS LOCKS
    -- ========================================================

    SELECT other_mc.id
    INTO v_other_contract_id
    FROM public.maintenance_contract_projects mcp
    JOIN public.maintenance_contracts other_mc
      ON other_mc.id = mcp.maintenance_contract_id
    WHERE mcp.maintenance_contract_id = NEW.id
      AND public.is_live_maintenance_contract_status(
          other_mc.estado
      )
      AND EXISTS (
          SELECT 1
          FROM public.maintenance_contract_projects other_mcp
          WHERE other_mcp.project_id = mcp.project_id
            AND other_mcp.maintenance_contract_id <> NEW.id
      )
    LIMIT 1;


    IF v_other_contract_id IS NOT NULL THEN

        RAISE EXCEPTION
            'El proyecto asociado al contrato % ya está cubierto por el contrato activo/pausado %.',
            NEW.id,
            v_other_contract_id;

    END IF;


    RETURN NEW;

END;
$function$;


REVOKE ALL
ON FUNCTION public.validate_maintenance_contract_integrity()
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.validate_maintenance_contract_integrity()
TO service_role;


-- ============================================================================
-- 7. TRIGGER SOBRE MAINTENANCE_CONTRACTS
-- ============================================================================


DROP TRIGGER IF EXISTS
    maintenance_contracts_project_integrity
ON public.maintenance_contracts;


CREATE TRIGGER
    maintenance_contracts_project_integrity
BEFORE INSERT OR UPDATE OF
    estado,
    company_id
ON public.maintenance_contracts
FOR EACH ROW
EXECUTE FUNCTION public.validate_maintenance_contract_integrity();


-- ============================================================================
-- 8. ÍNDICES DE APOYO
-- ============================================================================
--
-- No son restricciones únicas porque la regla depende del estado del
-- contrato, que vive en otra tabla.
--
-- Estos índices aceleran las comprobaciones de integridad.
-- ============================================================================


CREATE INDEX IF NOT EXISTS
    idx_maintenance_contract_projects_contract_project
ON public.maintenance_contract_projects (
    maintenance_contract_id,
    project_id
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_contract_projects_project_contract
ON public.maintenance_contract_projects (
    project_id,
    maintenance_contract_id
);


-- ============================================================================
-- 9. COMENTARIOS
-- ============================================================================


COMMENT ON TABLE public.maintenance_contract_projects
IS
'Relación entre contratos de mantenimiento y proyectos. Los contratos activos o pausados solo pueden cubrir un proyecto y un proyecto solo puede tener un contrato activo o pausado. Los contratos históricos pueden conservar sus relaciones.';


COMMENT ON FUNCTION public.validate_maintenance_contract_project_integrity()
IS
'Protección de integridad contrato-proyecto: un contrato activo/pausado solo puede cubrir un proyecto y un proyecto solo puede tener un contrato activo/pausado. Incluye advisory locks para evitar carreras concurrentes.';


COMMENT ON FUNCTION public.validate_maintenance_contract_integrity()
IS
'Protege la activación/pausa de contratos de mantenimiento para impedir que un contrato vivo tenga múltiples proyectos o que comparta proyecto con otro contrato vivo.';


-- ============================================================================
-- 10. VERIFICACIONES FINALES
-- ============================================================================


DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Tabla relación

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'maintenance_contract_projects';


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '089 failed: maintenance_contract_projects no existe';
    END IF;


    -- Función de estado

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'is_live_maintenance_contract_status'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_status text';


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '089 failed: is_live_maintenance_contract_status(text) no existe';
    END IF;


    -- Trigger relación

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger t
    JOIN pg_class c
      ON c.oid = t.tgrelid
    JOIN pg_namespace n
      ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'maintenance_contract_projects'
      AND t.tgname = 'maintenance_contract_projects_integrity'
      AND NOT t.tgisinternal;


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '089 failed: trigger maintenance_contract_projects_integrity no existe';
    END IF;


    -- Trigger contrato

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger t
    JOIN pg_class c
      ON c.oid = t.tgrelid
    JOIN pg_namespace n
      ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'maintenance_contracts'
      AND t.tgname = 'maintenance_contracts_project_integrity'
      AND NOT t.tgisinternal;


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '089 failed: trigger maintenance_contracts_project_integrity no existe';
    END IF;


    -- Índice contrato/proyecto

    SELECT COUNT(*)
    INTO v_count
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'idx_maintenance_contract_projects_contract_project';


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '089 failed: índice contrato/proyecto no existe';
    END IF;


    -- Índice proyecto/contrato

    SELECT COUNT(*)
    INTO v_count
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'idx_maintenance_contract_projects_project_contract';


    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '089 failed: índice proyecto/contrato no existe';
    END IF;

END;
$$;


NOTIFY pgrst, 'reload schema';

GRANT USAGE, SELECT
ON SEQUENCE public.maintenance_invoice_number_seq
TO service_role;
COMMIT;