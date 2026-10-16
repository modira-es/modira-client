BEGIN;

-- ============================================================
-- MODIRA — COMPANY WORKER NOTES
-- ============================================================
--
-- Notas internas de empresa, visibles únicamente para workers.
--
-- - No visibles para clientes.
-- - No forman parte de facturas ni presupuestos.
-- - Se reutiliza el sistema existente de rate limiting.
-- - Límite de tamaño: 5.000 caracteres.
-- - Rate limit: 10 cambios por worker cada 1 hora.
--
-- ============================================================


-- ============================================================
-- 1. COLUMNA DE NOTAS INTERNAS
-- ============================================================

ALTER TABLE public.companies
ADD COLUMN IF NOT EXISTS worker_notes TEXT;


-- ============================================================
-- 2. LÍMITE DE TAMAÑO A NIVEL DE BASE DE DATOS
-- ============================================================
--
-- El CHECK protege también frente a cualquier UPDATE directo
-- que intente escribir más de 5.000 caracteres.
--

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.companies'::regclass
          AND conname = 'companies_worker_notes_max_length'
    ) THEN
        ALTER TABLE public.companies
        ADD CONSTRAINT companies_worker_notes_max_length
        CHECK (
            worker_notes IS NULL
            OR LENGTH(worker_notes) <= 5000
        );
    END IF;
END;
$$;


-- ============================================================
-- 3. CONSULTA GENERAL DE NOTAS PARA WORKERS
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_company_worker_notes(
    p_company_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado.';
    END IF;

    PERFORM public.require_current_worker_permission(
        'companies.read'
    );

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'La empresa es obligatoria.';
    END IF;

    RETURN (
        SELECT c.worker_notes
        FROM public.companies c
        WHERE c.id = p_company_id
    );
END;
$function$;


-- ============================================================
-- 4. CONSULTA DE NOTAS DESDE FACTURAS
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_company_worker_notes_for_invoice(
    p_company_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado.';
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Acceso denegado.';
    END IF;

    IF NOT (
        public.current_worker_has_permission('invoices.create')
        OR
        public.current_worker_has_permission('invoices.update')
    ) THEN
        RAISE EXCEPTION
            'No tienes permisos para consultar las notas de empresa desde facturas.';
    END IF;

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'La empresa es obligatoria.';
    END IF;

    RETURN (
        SELECT c.worker_notes
        FROM public.companies c
        WHERE c.id = p_company_id
    );
END;
$function$;


-- ============================================================
-- 5. CONSULTA DE NOTAS DESDE PRESUPUESTOS
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_company_worker_notes_for_quotation(
    p_company_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado.';
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Acceso denegado.';
    END IF;

    IF NOT (
        public.current_worker_has_permission('quotations.create')
        OR
        public.current_worker_has_permission('quotations.update')
    ) THEN
        RAISE EXCEPTION
            'No tienes permisos para consultar las notas de empresa desde presupuestos.';
    END IF;

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'La empresa es obligatoria.';
    END IF;

    RETURN (
        SELECT c.worker_notes
        FROM public.companies c
        WHERE c.id = p_company_id
    );
END;
$function$;


-- ============================================================
-- 6. RATE LIMIT PARA CAMBIOS DE NOTAS
-- ============================================================
--
-- 10 cambios / worker / 1 hora.
--
-- Se aplica mediante trigger únicamente cuando worker_notes
-- cambia realmente, por lo que actualizar otros campos de
-- companies no consume el límite.
--
-- La clave queda aislada por worker:
--
--   companies:worker_notes:update:<auth.uid>
--
-- Los cambios realizados sin sesión no consumen rate limit;
-- la autorización/RLS existente sigue siendo responsable de
-- impedir operaciones no autorizadas.
--

CREATE OR REPLACE FUNCTION public.rate_limit_company_worker_notes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_user_id UUID;
    v_rate_key TEXT;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RETURN NEW;
    END IF;

    IF NEW.worker_notes IS NOT DISTINCT FROM OLD.worker_notes THEN
        RETURN NEW;
    END IF;

    v_rate_key :=
        'companies:worker_notes:update:' || v_user_id::TEXT;

    PERFORM public.enforce_security_rate_limit(
        v_rate_key,
        10,
        3600
    );

    RETURN NEW;
END;
$function$;

REVOKE ALL
ON FUNCTION public.rate_limit_company_worker_notes()
FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS companies_worker_notes_rate_limit
ON public.companies;

CREATE TRIGGER companies_worker_notes_rate_limit
BEFORE UPDATE
ON public.companies
FOR EACH ROW
EXECUTE FUNCTION public.rate_limit_company_worker_notes();


-- ============================================================
-- 7. ESCRITURA DE NOTAS
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_company_worker_notes(
    p_company_id UUID,
    p_worker_notes TEXT
)
RETURNS public.companies
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_company public.companies;
    v_notes TEXT;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado.';
    END IF;

    PERFORM public.require_current_worker_permission(
        'companies.update'
    );

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'La empresa es obligatoria.';
    END IF;

    v_notes := NULLIF(BTRIM(COALESCE(p_worker_notes, '')), '');

    IF v_notes IS NOT NULL
       AND LENGTH(v_notes) > 5000
    THEN
        RAISE EXCEPTION
            'Las notas de empresa no pueden superar 5000 caracteres.';
    END IF;

    UPDATE public.companies
    SET
        worker_notes = v_notes,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_company_id
    RETURNING *
    INTO v_company;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La empresa no existe.';
    END IF;

    RETURN v_company;
END;
$function$;


-- ============================================================
-- 8. SEGURIDAD DE LAS RPC
-- ============================================================

REVOKE ALL
ON FUNCTION public.get_company_worker_notes(UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.get_company_worker_notes_for_invoice(UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.get_company_worker_notes_for_quotation(UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.set_company_worker_notes(UUID, TEXT)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.get_company_worker_notes(UUID)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.get_company_worker_notes_for_invoice(UUID)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.get_company_worker_notes_for_quotation(UUID)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.set_company_worker_notes(UUID, TEXT)
TO authenticated;


-- ============================================================
-- 9. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- Columna
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'companies'
      AND column_name = 'worker_notes';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Company worker notes migration failed: worker_notes column missing';
    END IF;


    -- CHECK de tamaño
    SELECT COUNT(*)
    INTO v_count
    FROM pg_constraint
    WHERE conrelid = 'public.companies'::regclass
      AND conname = 'companies_worker_notes_max_length';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Company worker notes migration failed: max length constraint missing';
    END IF;


    -- Trigger de rate limit
    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.companies'::regclass
      AND tgname = 'companies_worker_notes_rate_limit'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Company worker notes migration failed: rate limit trigger missing';
    END IF;


    -- Función de rate limit
    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rate_limit_company_worker_notes'
      AND pg_get_function_identity_arguments(p.oid) = '';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Company worker notes migration failed: rate limit function missing';
    END IF;


    -- SECURITY DEFINER de la función de rate limit
    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'rate_limit_company_worker_notes'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Company worker notes migration failed: rate limit function must be SECURITY DEFINER';
    END IF;

END;
$$;


COMMIT;
