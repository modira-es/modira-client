-- ============================================================
-- MODIRA — 059 QUOTATION CONTRACTUAL / CLIENT / DOCUMENT HARDENING
-- ============================================================
--
-- OBJETIVOS
--
-- 1. Garantizar que todo presupuesto Pendiente tenga un cliente
--    válido derivado de su proyecto.
--
-- 2. Corregir presupuestos Pendiente existentes cuyo client_id
--    haya quedado NULL aunque el proyecto tenga cliente.
--
-- 3. Garantizar:
--
--       quotations.client_id
--              ↓
--       clients.id
--              ↓
--       clients.profile_id
--              ↓
--       auth.uid()
--
--    como relación contractual del presupuesto con el cliente.
--
-- 4. Invalidar document_path + document_sha256 cuando cambia
--    el contenido contractual/económico del presupuesto.
--
-- 5. Evitar que un presupuesto pueda pasar directamente a
--    Aceptado sin existir previamente un acknowledgement válido
--    del PDF actualmente asociado.
--
-- 6. Mantener intactas las arquitecturas existentes de:
--
--       037  versionado / inmutabilidad
--       045  creación segura de worker
--       046  actualización/eliminación segura de worker
--       056  acknowledgement + SHA-256
--       057  documentos aceptados inmutables
--       058  acceso del cliente mediante client_id
--
-- 7. NO calcular SHA-256 dentro de PostgreSQL.
--    El SHA-256 continúa siendo generado por el flujo existente
--    de backend/Edge Function.
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- quotations
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'quotations';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: public.quotations does not exist';
    END IF;


    -- projects
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'projects';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: public.projects does not exist';
    END IF;


    -- clients
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'clients';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: public.clients does not exist';
    END IF;


    -- client_id
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'client_id';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations.client_id missing';
    END IF;


    -- project_id
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'project_id';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations.project_id missing';
    END IF;


    -- company_id
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'company_id';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations.company_id missing';
    END IF;


    -- user_id
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'user_id';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations.user_id missing';
    END IF;


    -- estado
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'estado';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations.estado missing';
    END IF;


    -- document_path
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'document_path';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations.document_path missing';
    END IF;


    -- document_sha256
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'document_sha256';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations.document_sha256 missing';
    END IF;


    -- quotation_version
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'quotation_version';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations.quotation_version missing';
    END IF;


    -- acknowledgement table
    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'quotation_document_acknowledgements';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotation_document_acknowledgements missing';
    END IF;

END;
$$;


-- ============================================================
-- 2. REPARAR PRESUPUESTOS PENDIENTES EXISTENTES
-- ============================================================
--
-- Si el proyecto ya tiene cliente y el presupuesto no lo tiene,
-- se recupera automáticamente la relación correcta.
--
-- NO se modifican:
--
--   Aceptados
--   Rechazados
--
-- porque forman parte del histórico contractual.
--
-- ============================================================

UPDATE public.quotations q
SET
    client_id = p.client_id,
    updated_at = CURRENT_TIMESTAMP
FROM public.projects p
WHERE q.project_id = p.id
  AND LOWER(TRIM(q.estado)) = 'pendiente'
  AND q.client_id IS NULL
  AND p.client_id IS NOT NULL;


-- ============================================================
-- 3. VALIDAR LOS PENDIENTES EXISTENTES
-- ============================================================
--
-- No permitimos terminar la migración dejando presupuestos
-- Pendiente sin cliente.
--
-- Si existe alguno, significa que el proyecto tampoco tiene
-- cliente y la migración se detiene de forma segura.
--
-- Así no dejamos el sistema en un estado parcialmente endurecido.
--
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM public.quotations q
    LEFT JOIN public.projects p
        ON p.id = q.project_id
    WHERE LOWER(TRIM(q.estado)) = 'pendiente'
      AND (
          q.client_id IS NULL
          OR p.id IS NULL
          OR p.client_id IS NULL
      );

    IF v_count > 0 THEN
        RAISE EXCEPTION
            '059 failed: existen % presupuestos Pendiente sin un cliente válido en su proyecto',
            v_count;
    END IF;

END;
$$;


-- ============================================================
-- 4. VALIDAR INTEGRIDAD CLIENTE / EMPRESA
-- ============================================================
--
-- Un presupuesto Pendiente debe cumplir:
--
-- quotation.project_id
--      ↓
-- project.client_id
--      ↓
-- quotation.client_id
--
-- y el cliente debe pertenecer a la misma empresa.
--
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM public.quotations q
    JOIN public.projects p
        ON p.id = q.project_id
    LEFT JOIN public.clients c
        ON c.id = q.client_id
    WHERE LOWER(TRIM(q.estado)) = 'pendiente'
      AND (
          q.client_id IS DISTINCT FROM p.client_id
          OR c.id IS NULL
          OR c.company_id IS DISTINCT FROM p.company_id
          OR q.company_id IS DISTINCT FROM p.company_id
      );

    IF v_count > 0 THEN
        RAISE EXCEPTION
            '059 failed: existen % presupuestos Pendiente con relación cliente/proyecto/empresa inconsistente',
            v_count;
    END IF;

END;
$$;


-- ============================================================
-- 5. FUNCIÓN — VALIDAR CLIENTE DEL PRESUPUESTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_pending_quotation_client()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_project public.projects;
    v_client public.clients;
BEGIN

    -- --------------------------------------------------------
    -- Solo aplicamos esta regla a presupuestos Pendiente.
    --
    -- Aceptados/Rechazados conservan su histórico.
    -- --------------------------------------------------------

    IF LOWER(TRIM(COALESCE(NEW.estado, ''))) <> 'pendiente' THEN
        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- Proyecto obligatorio
    -- --------------------------------------------------------

    IF NEW.project_id IS NULL THEN
        RAISE EXCEPTION
            'Un presupuesto Pendiente debe estar asociado a un proyecto';
    END IF;


    -- --------------------------------------------------------
    -- Obtener proyecto real
    -- --------------------------------------------------------

    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = NEW.project_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El proyecto del presupuesto no existe';
    END IF;


    -- --------------------------------------------------------
    -- El proyecto debe tener cliente
    -- --------------------------------------------------------

    IF v_project.client_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto del presupuesto debe tener un cliente antes de publicar el presupuesto';
    END IF;


    -- --------------------------------------------------------
    -- El quotation debe utilizar exactamente ese cliente
    -- --------------------------------------------------------

    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION
            'Un presupuesto Pendiente debe tener cliente';
    END IF;


    IF NEW.client_id IS DISTINCT FROM v_project.client_id THEN
        RAISE EXCEPTION
            'El cliente del presupuesto no coincide con el cliente del proyecto';
    END IF;


    -- --------------------------------------------------------
    -- La empresa también debe derivar del proyecto
    -- --------------------------------------------------------

    IF NEW.company_id IS DISTINCT FROM v_project.company_id THEN
        RAISE EXCEPTION
            'La empresa del presupuesto no coincide con la empresa del proyecto';
    END IF;


    -- --------------------------------------------------------
    -- Validar cliente real
    -- --------------------------------------------------------

    SELECT *
    INTO v_client
    FROM public.clients
    WHERE id = NEW.client_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El cliente del presupuesto no existe';
    END IF;


    IF v_client.company_id IS DISTINCT FROM v_project.company_id THEN
        RAISE EXCEPTION
            'El cliente del presupuesto no pertenece a la empresa del proyecto';
    END IF;


    RETURN NEW;

END;
$function$;


-- ============================================================
-- 6. TRIGGER — CLIENTE OBLIGATORIO EN PENDIENTE
-- ============================================================

DROP TRIGGER IF EXISTS quotations_validate_pending_client
ON public.quotations;

CREATE TRIGGER quotations_validate_pending_client
BEFORE INSERT OR UPDATE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.validate_pending_quotation_client();


-- ============================================================
-- 7. FUNCIÓN — INVALIDAR PDF CUANDO CAMBIA EL CONTENIDO
-- ============================================================
--
-- El PDF representa una versión concreta del presupuesto.
--
-- Si cambia cualquiera de los datos contractuales/económicos,
-- el PDF anterior deja de representar el contenido actual.
--
-- Por tanto:
--
--       document_path   = NULL
--       document_sha256 = NULL
--
-- y el worker deberá subir/regenerar el PDF.
--
-- IMPORTANTE:
--
-- Los cambios hechos exclusivamente sobre document_path o
-- document_sha256 NO provocan esta invalidación.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.invalidate_quotation_document_on_content_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN

    /*
     * Solo necesitamos invalidar el documento si el presupuesto
     * resultante vuelve a estar Pendiente.
     *
     * Esto cubre:
     *
     *   Pendiente  -> Pendiente
     *   Rechazado  -> Pendiente
     *
     * y evita conservar un PDF antiguo cuando cambia el contenido.
     */

    IF LOWER(TRIM(COALESCE(NEW.estado, ''))) = 'pendiente'
       AND (
            OLD.company_id IS DISTINCT FROM NEW.company_id
         OR OLD.user_id IS DISTINCT FROM NEW.user_id
         OR OLD.project_id IS DISTINCT FROM NEW.project_id
         OR OLD.client_id IS DISTINCT FROM NEW.client_id
         OR OLD.titulo IS DISTINCT FROM NEW.titulo
         OR OLD.descripcion_detallada IS DISTINCT FROM NEW.descripcion_detallada
         OR OLD.servicios_incluidos IS DISTINCT FROM NEW.servicios_incluidos
         OR OLD.precio_base IS DISTINCT FROM NEW.precio_base
         OR OLD.iva_porcentaje IS DISTINCT FROM NEW.iva_porcentaje
         OR OLD.iva_importe IS DISTINCT FROM NEW.iva_importe
         OR OLD.irpf_aplicado IS DISTINCT FROM NEW.irpf_aplicado
         OR OLD.irpf_porcentaje IS DISTINCT FROM NEW.irpf_porcentaje
         OR OLD.irpf_importe IS DISTINCT FROM NEW.irpf_importe
         OR OLD.precio_total IS DISTINCT FROM NEW.precio_total
         OR OLD.fecha_emision IS DISTINCT FROM NEW.fecha_emision
         OR OLD.fecha_validez IS DISTINCT FROM NEW.fecha_validez
         OR OLD.notas IS DISTINCT FROM NEW.notas
       )
    THEN

        NEW.document_path := NULL;
        NEW.document_sha256 := NULL;

    END IF;


    RETURN NEW;

END;
$function$;


-- ============================================================
-- 8. TRIGGER — INVALIDAR DOCUMENTO
-- ============================================================

DROP TRIGGER IF EXISTS quotations_invalidate_document_on_content_change
ON public.quotations;

CREATE TRIGGER quotations_invalidate_document_on_content_change
BEFORE UPDATE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.invalidate_quotation_document_on_content_change();


-- ============================================================
-- 9. FUNCIÓN — PROTEGER ACEPTACIÓN CONTRACTUAL
-- ============================================================
--
-- Un UPDATE directo hacia Aceptado NO puede saltarse:
--
--   1. PDF
--   2. SHA-256
--   3. acknowledgement
--
-- La RPC respond_to_quotation() de 056/058:
--
--   a) bloquea el presupuesto
--   b) exige acknowledgement
--   c) crea quotation_acceptances
--   d) cambia el estado a Aceptado
--
-- Por tanto, cuando su UPDATE llegue aquí, el acknowledgement
-- ya existe.
--
-- Si alguien intenta utilizar:
--
--   create_quotation_by_worker(..., 'Aceptado', ...)
--
-- o:
--
--   update_quotation_by_worker(..., 'Aceptado', ...)
--
-- sin pasar por el flujo contractual, será rechazado.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_quotation_direct_acceptance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_ack_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Solo nos interesa una transición hacia Aceptado.
    -- --------------------------------------------------------

    IF LOWER(TRIM(COALESCE(NEW.estado, ''))) <> 'aceptado' THEN
        RETURN NEW;
    END IF;


    -- --------------------------------------------------------
    -- Crear Aceptado directamente desde INSERT tampoco está
    -- permitido.
    -- --------------------------------------------------------

    IF TG_OP = 'INSERT' THEN

        RAISE EXCEPTION
            'Un presupuesto no puede crearse directamente como Aceptado; debe pasar por el proceso de aceptación contractual';

    END IF;


    -- --------------------------------------------------------
    -- Pendiente -> Aceptado requiere acknowledgement del PDF.
    -- --------------------------------------------------------

    IF LOWER(TRIM(COALESCE(OLD.estado, ''))) = 'pendiente' THEN

        SELECT COUNT(*)
        INTO v_ack_count
        FROM public.quotation_document_acknowledgements a
        WHERE a.quotation_id = NEW.id
          AND a.document_path = NEW.document_path
          AND LOWER(TRIM(a.document_sha256))
              = LOWER(TRIM(NEW.document_sha256));


        IF v_ack_count = 0 THEN
            RAISE EXCEPTION
                'No se puede aceptar el presupuesto sin una aceptación previa del PDF actualmente asociado';
        END IF;

    END IF;


    RETURN NEW;

END;
$function$;


-- ============================================================
-- 10. TRIGGER — PROTEGER TRANSICIÓN A ACEPTADO
-- ============================================================

DROP TRIGGER IF EXISTS quotations_protect_direct_acceptance
ON public.quotations;

CREATE TRIGGER quotations_protect_direct_acceptance
BEFORE INSERT OR UPDATE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.protect_quotation_direct_acceptance();


-- ============================================================
-- 11. PERMISOS DE FUNCIONES DE TRIGGER
-- ============================================================

REVOKE ALL
ON FUNCTION public.validate_pending_quotation_client()
FROM PUBLIC, anon, authenticated, service_role;


REVOKE ALL
ON FUNCTION public.invalidate_quotation_document_on_content_change()
FROM PUBLIC, anon, authenticated, service_role;


REVOKE ALL
ON FUNCTION public.protect_quotation_direct_acceptance()
FROM PUBLIC, anon, authenticated, service_role;


-- ============================================================
-- 12. SEARCH_PATH DE LAS FUNCIONES EXISTENTES CRÍTICAS
-- ============================================================

ALTER FUNCTION public.record_quotation_document_acknowledgement(UUID)
SET search_path = public, pg_temp;


ALTER FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
SET search_path = public, pg_temp;


ALTER FUNCTION public.attach_quotation_document(UUID, TEXT)
SET search_path = public, pg_temp;


ALTER FUNCTION public.respond_to_quotation(TEXT, UUID)
SET search_path = public, pg_temp;


-- ============================================================
-- 13. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- Trigger cliente
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.quotations'::regclass
      AND tgname = 'quotations_validate_pending_client'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations_validate_pending_client trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- Trigger documento
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.quotations'::regclass
      AND tgname = 'quotations_invalidate_document_on_content_change'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations_invalidate_document_on_content_change trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- Trigger aceptación
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgrelid = 'public.quotations'::regclass
      AND tgname = 'quotations_protect_direct_acceptance'
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations_protect_direct_acceptance trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- Función cliente
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'validate_pending_quotation_client'
      AND pg_get_function_identity_arguments(p.oid) = '';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: validate_pending_quotation_client missing';
    END IF;


    -- --------------------------------------------------------
    -- Función documento
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'invalidate_quotation_document_on_content_change'
      AND pg_get_function_identity_arguments(p.oid) = '';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: invalidate_quotation_document_on_content_change missing';
    END IF;


    -- --------------------------------------------------------
    -- Función aceptación
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'protect_quotation_direct_acceptance'
      AND pg_get_function_identity_arguments(p.oid) = '';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: protect_quotation_direct_acceptance missing';
    END IF;


    -- --------------------------------------------------------
    -- Ningún Pendiente sin cliente
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM public.quotations q
    WHERE LOWER(TRIM(q.estado)) = 'pendiente'
      AND q.client_id IS NULL;

    IF v_count > 0 THEN
        RAISE EXCEPTION
            '059 failed: quedan % presupuestos Pendiente sin client_id',
            v_count;
    END IF;


    -- --------------------------------------------------------
    -- Ningún Pendiente con relación inconsistente
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM public.quotations q
    JOIN public.projects p
      ON p.id = q.project_id
    LEFT JOIN public.clients c
      ON c.id = q.client_id
    WHERE LOWER(TRIM(q.estado)) = 'pendiente'
      AND (
          q.client_id IS DISTINCT FROM p.client_id
          OR c.id IS NULL
          OR c.company_id IS DISTINCT FROM p.company_id
          OR q.company_id IS DISTINCT FROM p.company_id
      );

    IF v_count > 0 THEN
        RAISE EXCEPTION
            '059 failed: quedan % presupuestos Pendiente con relaciones inconsistentes',
            v_count;
    END IF;


    -- --------------------------------------------------------
    -- document_sha256 debe conservar su constraint
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.table_constraints tc
    WHERE tc.table_schema = 'public'
      AND tc.table_name = 'quotations'
      AND tc.constraint_name = 'quotations_document_sha256_check';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: quotations_document_sha256_check missing';
    END IF;


    -- --------------------------------------------------------
    -- acknowledgement
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'record_quotation_document_acknowledgement'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_quotation_id uuid';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: record_quotation_document_acknowledgement(uuid) missing';
    END IF;


    -- --------------------------------------------------------
    -- hash
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'set_quotation_document_hash'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_quotation_id uuid, p_document_path text, p_document_sha256 text';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: set_quotation_document_hash(uuid,text,text) missing';
    END IF;


    -- --------------------------------------------------------
    -- respond_to_quotation
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'respond_to_quotation'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_estado text, p_quotation_id uuid';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '059 failed: respond_to_quotation(text,uuid) missing';
    END IF;

END;
$$;


-- ============================================================
-- 14. COMENTARIOS
-- ============================================================

COMMENT ON FUNCTION public.validate_pending_quotation_client()
IS
'Garantiza que todo presupuesto Pendiente tenga un cliente válido derivado del proyecto y perteneciente a la misma empresa.';


COMMENT ON FUNCTION public.invalidate_quotation_document_on_content_change()
IS
'Invalida document_path y document_sha256 cuando cambia el contenido contractual/económico de un presupuesto Pendiente.';


COMMENT ON FUNCTION public.protect_quotation_direct_acceptance()
IS
'Impide crear o modificar directamente un presupuesto a Aceptado sin acknowledgement previo del PDF actualmente asociado. La aceptación contractual continúa realizándose mediante respond_to_quotation().';


COMMIT;