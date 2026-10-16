BEGIN;

-- ============================================================
-- 1. AÑADIR LA VINCULACIÓN AL ALCANCE EN QUOTATIONS
-- ============================================================

ALTER TABLE public.quotations
    ADD COLUMN IF NOT EXISTS project_scope_version_id uuid,
    ADD COLUMN IF NOT EXISTS project_scope_acceptance_id uuid,
    ADD COLUMN IF NOT EXISTS project_scope_version_number integer,
    ADD COLUMN IF NOT EXISTS project_scope_accepted_at timestamptz,
    ADD COLUMN IF NOT EXISTS project_scope_snapshot jsonb,
    ADD COLUMN IF NOT EXISTS project_scope_snapshot_sha256 text,
    ADD COLUMN IF NOT EXISTS project_scope_pdf_sha256 text;


-- ============================================================
-- 2. RESTRICCIONES DE INTEGRIDAD
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.quotations'::regclass
          AND conname = 'quotations_project_scope_version_fk'
    ) THEN
        ALTER TABLE public.quotations
            ADD CONSTRAINT quotations_project_scope_version_fk
            FOREIGN KEY (project_scope_version_id)
            REFERENCES public.project_scope_versions(id)
            ON DELETE RESTRICT;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.quotations'::regclass
          AND conname = 'quotations_project_scope_acceptance_fk'
    ) THEN
        ALTER TABLE public.quotations
            ADD CONSTRAINT quotations_project_scope_acceptance_fk
            FOREIGN KEY (project_scope_acceptance_id)
            REFERENCES public.project_scope_acceptances(id)
            ON DELETE RESTRICT;
    END IF;
END;
$$;


-- ============================================================
-- 3. FUNCIÓN: CAPTURAR LA ÚLTIMA ACEPTACIÓN DEL PROYECTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_accepted_scope_to_quotation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_acceptance public.project_scope_acceptances%ROWTYPE;
    v_version_number integer;
BEGIN
    -- El proyecto es obligatorio para vincular un alcance.
    IF NEW.project_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Buscar la última aceptación registrada para el proyecto.
    -- No filtramos por is_current ni por el estado actual de la
    -- versión: interesa el historial real de aceptaciones.
      SELECT
        a.*
    INTO
        v_acceptance
    FROM public.project_scope_acceptances AS a
    INNER JOIN public.project_scope_versions AS sv
        ON sv.id = a.scope_version_id
       AND sv.project_id = a.project_id
    WHERE a.project_id = NEW.project_id
      AND a.acknowledged IS TRUE
    ORDER BY
        a.accepted_at DESC,
        sv.version_number DESC,
        a.id DESC
    LIMIT 1;

    IF FOUND THEN
        SELECT sv.version_number
        INTO v_version_number
        FROM public.project_scope_versions AS sv
        WHERE sv.id = v_acceptance.scope_version_id
          AND sv.project_id = NEW.project_id;
    END IF;

    -- Si no existe ninguna aceptación, mantener el presupuesto
    -- sin alcance vinculado y permitir que siga el flujo actual.
    IF NOT FOUND THEN
        NEW.project_scope_version_id := NULL;
        NEW.project_scope_acceptance_id := NULL;
        NEW.project_scope_version_number := NULL;
        NEW.project_scope_accepted_at := NULL;
        NEW.project_scope_snapshot := NULL;
        NEW.project_scope_snapshot_sha256 := NULL;
        NEW.project_scope_pdf_sha256 := NULL;

        RETURN NEW;
    END IF;

    -- Copiar los identificadores y los datos inmutables
    -- de la aceptación seleccionada.
    NEW.project_scope_version_id :=
        v_acceptance.scope_version_id;

    NEW.project_scope_acceptance_id :=
        v_acceptance.id;

    NEW.project_scope_version_number :=
        v_version_number;

    NEW.project_scope_accepted_at :=
        v_acceptance.accepted_at;

    NEW.project_scope_snapshot :=
        v_acceptance.content_snapshot;

    NEW.project_scope_snapshot_sha256 :=
        v_acceptance.content_snapshot_sha256;

    NEW.project_scope_pdf_sha256 :=
        v_acceptance.pdf_sha256;

    RETURN NEW;
END;
$function$;


-- ============================================================
-- 4. TRIGGER DE CREACIÓN
-- ============================================================

DROP TRIGGER IF EXISTS
    trg_attach_accepted_scope_to_quotation
ON public.quotations;

CREATE TRIGGER trg_attach_accepted_scope_to_quotation
BEFORE INSERT ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.attach_accepted_scope_to_quotation();


-- ============================================================
-- 5. PROTEGER EL ALCANCE VINCULADO EN LAS ACTUALIZACIONES
-- ============================================================

CREATE OR REPLACE FUNCTION public.preserve_quotation_scope_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
BEGIN
    -- La vinculación y su snapshot no se pueden sustituir
    -- al corregir o revisar un presupuesto existente.
    NEW.project_scope_version_id :=
        OLD.project_scope_version_id;

    NEW.project_scope_acceptance_id :=
        OLD.project_scope_acceptance_id;

    NEW.project_scope_version_number :=
        OLD.project_scope_version_number;

    NEW.project_scope_accepted_at :=
        OLD.project_scope_accepted_at;

    NEW.project_scope_snapshot :=
        OLD.project_scope_snapshot;

    NEW.project_scope_snapshot_sha256 :=
        OLD.project_scope_snapshot_sha256;

    NEW.project_scope_pdf_sha256 :=
        OLD.project_scope_pdf_sha256;

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS
    trg_preserve_quotation_scope_snapshot
ON public.quotations;

CREATE TRIGGER trg_preserve_quotation_scope_snapshot
BEFORE UPDATE ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.preserve_quotation_scope_snapshot();


-- ============================================================
-- 6. ÍNDICE PARA CONSULTAR PRESUPUESTOS POR ACEPTACIÓN
-- ============================================================

CREATE INDEX IF NOT EXISTS
    quotations_project_scope_acceptance_idx
ON public.quotations (project_scope_acceptance_id)
WHERE project_scope_acceptance_id IS NOT NULL;


-- ============================================================
-- 7. DOCUMENTACIÓN DE LAS COLUMNAS
-- ============================================================

COMMENT ON COLUMN public.quotations.project_scope_version_id IS
'Versión del alcance del proyecto vinculada al crear el presupuesto.';

COMMENT ON COLUMN public.quotations.project_scope_acceptance_id IS
'Registro de aceptación que se utilizó para vincular el alcance al presupuesto.';

COMMENT ON COLUMN public.quotations.project_scope_version_number IS
'Número de versión del alcance aceptado vinculado al presupuesto.';

COMMENT ON COLUMN public.quotations.project_scope_accepted_at IS
'Fecha de aceptación del alcance vinculado al presupuesto.';

COMMENT ON COLUMN public.quotations.project_scope_snapshot IS
'Copia inmutable del contenido del alcance aceptado al crear el presupuesto.';

COMMENT ON COLUMN public.quotations.project_scope_snapshot_sha256 IS
'Hash SHA-256 del contenido del alcance aceptado.';

COMMENT ON COLUMN public.quotations.project_scope_pdf_sha256 IS
'Hash SHA-256 del PDF oficial del alcance aceptado.';

COMMIT;