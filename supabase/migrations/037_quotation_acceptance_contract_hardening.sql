BEGIN;
-- ============================================================
-- MODIRA — 037_quotation_acceptance_contract_hardening.sql
--
-- Aceptación contractual y trazabilidad de presupuestos.
--
-- Refuerza el flujo existente sin sustituir quotations ni
-- respond_to_quotation().
--
-- IMPORTANTE:
-- - La aceptación contractual se registra en quotation_acceptances.
-- - El presupuesto aceptado queda congelado a nivel de BD.
-- - quotation_version aumenta únicamente mientras el presupuesto
--   siga pendiente y sea modificado.
-- - La aceptación obtiene los términos contractuales vigentes
--   de public.legal_documents, creada por la migración 030.
-- - Para mantener el orden numérico 029 -> 030, la función usa
--   SQL dinámico: la migración 029 puede instalarse antes, pero
--   ninguna aceptación podrá completarse hasta que 030 haya
--   desplegado y exista un documento contract_terms vigente.
-- - No se inventa ni se siembra el contenido jurídico de MODIRA:
--   los documentos legales deben cargarse con su texto real.
-- ============================================================

-- ============================================================
-- 0. VALIDACIONES PREVIAS
-- ============================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'quotations'
    ) THEN
        RAISE EXCEPTION '029 stopped: public.quotations does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'id'
    ) THEN
        RAISE EXCEPTION '029 stopped: quotations.id does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'company_id'
    ) THEN
        RAISE EXCEPTION '029 stopped: quotations.company_id does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'user_id'
    ) THEN
        RAISE EXCEPTION '029 stopped: quotations.user_id does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'estado'
    ) THEN
        RAISE EXCEPTION '029 stopped: quotations.estado does not exist';
    END IF;

    IF to_regprocedure('public.current_user_is_worker()') IS NULL THEN
        RAISE EXCEPTION '029 stopped: current_user_is_worker() does not exist';
    END IF;

    IF to_regprocedure('public.current_user_company_id()') IS NULL THEN
        RAISE EXCEPTION '029 stopped: current_user_company_id() does not exist';
    END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- 1. VERSIONADO DEL PRESUPUESTO
-- ============================================================
ALTER TABLE public.quotations
    ADD COLUMN IF NOT EXISTS quotation_version INTEGER NOT NULL DEFAULT 1;

ALTER TABLE public.quotations
    DROP CONSTRAINT IF EXISTS quotations_version_check;

ALTER TABLE public.quotations
    ADD CONSTRAINT quotations_version_check
    CHECK (quotation_version >= 1);

-- ============================================================
-- 2. INCREMENTAR VERSIÓN ANTES DE ACEPTACIÓN
-- ============================================================
--
-- Pendiente -> Pendiente:
--   cualquier modificación contractual incrementa la versión.
--
-- Pendiente -> Aceptado/Rechazado:
--   se conserva la versión que se estaba aceptando/respondiendo.
--
-- Aceptado:
--   no se permite ninguna modificación.
--
-- Rechazado:
--   sigue pudiendo modificarse por el flujo interno existente;
--   cualquier modificación incrementa su versión.
-- ============================================================
CREATE OR REPLACE FUNCTION public.version_quotation_before_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF OLD.estado = 'Aceptado' THEN
        RAISE EXCEPTION
            'El presupuesto aceptado está contractualmente congelado y no puede modificarse';
    END IF;

    IF OLD.estado = 'Pendiente'
       AND NEW.estado = 'Pendiente' THEN
        NEW.quotation_version := OLD.quotation_version + 1;
    ELSE
        NEW.quotation_version := OLD.quotation_version;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS quotations_version_before_update
ON public.quotations;

CREATE TRIGGER quotations_version_before_update
BEFORE UPDATE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.version_quotation_before_update();

-- ============================================================
-- 3. IMPEDIR ELIMINACIÓN DE PRESUPUESTOS ACEPTADOS
-- ============================================================
CREATE OR REPLACE FUNCTION public.protect_accepted_quotation_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF OLD.estado = 'Aceptado' THEN
        RAISE EXCEPTION
            'El presupuesto aceptado está contractualmente congelado y no puede eliminarse';
    END IF;

    RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS quotations_protect_accepted_delete
ON public.quotations;

CREATE TRIGGER quotations_protect_accepted_delete
BEFORE DELETE
ON public.quotations
FOR EACH ROW
EXECUTE FUNCTION public.protect_accepted_quotation_delete();

-- ============================================================
-- 4. TABLA DE ACEPTACIÓN CONTRACTUAL
-- ============================================================
CREATE TABLE IF NOT EXISTS public.quotation_acceptances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    quotation_id UUID NOT NULL
        REFERENCES public.quotations(id)
        ON DELETE RESTRICT,

    user_id UUID NOT NULL,

    company_id UUID NOT NULL
        REFERENCES public.companies(id)
        ON DELETE RESTRICT,

    accepted_at TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    previous_state TEXT NOT NULL,
    resulting_state TEXT NOT NULL DEFAULT 'Aceptado',

    quotation_version INTEGER NOT NULL,

    quotation_snapshot JSONB NOT NULL,
    quotation_snapshot_hash TEXT NOT NULL,

    contract_terms_document_id UUID,
    contract_terms_version TEXT NOT NULL,
    contract_terms_snapshot TEXT NOT NULL,
    contract_terms_hash TEXT NOT NULL,

    observed_ip TEXT,
    user_agent TEXT,

    CONSTRAINT quotation_acceptances_previous_state_check
        CHECK (previous_state = 'Pendiente'),

    CONSTRAINT quotation_acceptances_resulting_state_check
        CHECK (resulting_state = 'Aceptado'),

    CONSTRAINT quotation_acceptances_version_check
        CHECK (quotation_version >= 1),

    CONSTRAINT quotation_acceptances_ip_length_check
        CHECK (observed_ip IS NULL OR length(observed_ip) <= 200),

    CONSTRAINT quotation_acceptances_user_agent_length_check
        CHECK (user_agent IS NULL OR length(user_agent) <= 2000)
);

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_quotation_acceptances_quotation_unique
ON public.quotation_acceptances(quotation_id);

CREATE INDEX IF NOT EXISTS
    idx_quotation_acceptances_user_id
ON public.quotation_acceptances(user_id);

CREATE INDEX IF NOT EXISTS
    idx_quotation_acceptances_company_id
ON public.quotation_acceptances(company_id);

CREATE INDEX IF NOT EXISTS
    idx_quotation_acceptances_accepted_at
ON public.quotation_acceptances(accepted_at DESC);

-- ============================================================
-- 5. INTEGRIDAD DEL REGISTRO DE ACEPTACIÓN
-- ============================================================
--
-- La aceptación es un registro probatorio: no se modifica ni
-- elimina mediante SQL normal.
-- ============================================================
CREATE OR REPLACE FUNCTION public.protect_quotation_acceptance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    RAISE EXCEPTION
        'El registro de aceptación contractual es inmutable';
END;
$function$;

DROP TRIGGER IF EXISTS quotation_acceptances_immutable
ON public.quotation_acceptances;

CREATE TRIGGER quotation_acceptances_immutable
BEFORE UPDATE OR DELETE
ON public.quotation_acceptances
FOR EACH ROW
EXECUTE FUNCTION public.protect_quotation_acceptance();

ALTER TABLE public.quotation_acceptances
ENABLE ROW LEVEL SECURITY;

REVOKE ALL
ON public.quotation_acceptances
FROM PUBLIC, anon, authenticated;

GRANT SELECT
ON public.quotation_acceptances
TO authenticated;

DROP POLICY IF EXISTS quotation_acceptances_client_select
ON public.quotation_acceptances;

CREATE POLICY quotation_acceptances_client_select
ON public.quotation_acceptances
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
);

DROP POLICY IF EXISTS quotation_acceptances_worker_select
ON public.quotation_acceptances;

CREATE POLICY quotation_acceptances_worker_select
ON public.quotation_acceptances
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);

-- ============================================================
-- 6. RESPONDER A UN PRESUPUESTO — VERSIÓN CONTRACTUAL
-- ============================================================
--
-- Se conserva la firma existente de 011:
--   respond_to_quotation(TEXT, UUID)
--
-- Pendiente -> Rechazado:
--   se mantiene como respuesta no contractual.
--
-- Pendiente -> Aceptado:
--   1. autenticar;
--   2. exigir cuenta activa;
--   3. bloquear la fila FOR UPDATE;
--   4. comprobar pertenencia;
--   5. comprobar que no existe aceptación;
--   6. obtener términos contractuales vigentes desde 030;
--   7. obtener IP/user-agent de cabeceras observadas por el proxy;
--   8. crear snapshot y hashes;
--   9. insertar aceptación;
--   10. cambiar quotation a Aceptado.
--
-- El INSERT y el UPDATE forman parte de la misma transacción de
-- la RPC.
-- ============================================================
CREATE OR REPLACE FUNCTION public.respond_to_quotation(
    p_estado TEXT,
    p_quotation_id UUID
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_quotation public.quotations;
    v_normalized_state TEXT;
    v_headers JSONB := '{}'::JSONB;
    v_ip TEXT;
    v_user_agent TEXT;

    v_terms_document_id UUID;
    v_terms_version TEXT;
    v_terms_snapshot TEXT;
    v_terms_hash TEXT;

    v_snapshot JSONB;
    v_snapshot_hash TEXT;
BEGIN
    -- --------------------------------------------------------
    -- 1. AUTENTICACIÓN
    -- --------------------------------------------------------
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION 'Acceso denegado: la cuenta no está activa';
    END IF;

    -- --------------------------------------------------------
    -- 2. VALIDAR ESTADO
    -- --------------------------------------------------------
    v_normalized_state :=
        INITCAP(
            LOWER(
                TRIM(
                    COALESCE(p_estado, '')
                )
            )
        );

    IF v_normalized_state NOT IN ('Aceptado', 'Rechazado') THEN
        RAISE EXCEPTION
            'Estado de respuesta no válido. Debe ser Aceptado o Rechazado';
    END IF;

    -- --------------------------------------------------------
    -- 3. BLOQUEAR PRESUPUESTO
    -- --------------------------------------------------------
    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Presupuesto no encontrado';
    END IF;

    IF LOWER(TRIM(v_quotation.estado)) <> 'pendiente' THEN
        RAISE EXCEPTION
            'Este presupuesto ya ha sido respondido y no puede modificarse';
    END IF;

    -- --------------------------------------------------------
    -- 4. COMPROBAR ACCESO
    -- --------------------------------------------------------
    IF NOT public.current_user_is_worker() THEN
        IF v_quotation.company_id IS DISTINCT FROM
           public.current_user_company_id()
        THEN
            RAISE EXCEPTION 'Acceso denegado al presupuesto';
        END IF;
    END IF;

    -- --------------------------------------------------------
    -- 5. RECHAZADO — SIN PERFECCIONAMIENTO CONTRACTUAL
    -- --------------------------------------------------------
    IF v_normalized_state = 'Rechazado' THEN
        UPDATE public.quotations
        SET
            estado = 'Rechazado',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_quotation.id
        RETURNING * INTO v_quotation;

        RETURN v_quotation;
    END IF;

    -- --------------------------------------------------------
    -- 6. ACEPTACIÓN — EVITAR DUPLICADO
    -- --------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM public.quotation_acceptances qa
        WHERE qa.quotation_id = v_quotation.id
    ) THEN
        RAISE EXCEPTION
            'Este presupuesto ya tiene una aceptación contractual registrada';
    END IF;

    -- --------------------------------------------------------
    -- 7. OBTENER TÉRMINOS CONTRACTUALES VIGENTES
    -- --------------------------------------------------------
    --
    -- 030 crea legal_documents. SQL dinámico permite que 029 se
    -- instale antes de 030 sin inventar una tabla intermedia.
    --
    IF to_regclass('public.legal_documents') IS NULL THEN
        RAISE EXCEPTION
            'La infraestructura de documentos legales no está instalada';
    END IF;

    EXECUTE $sql$
        SELECT id, version, content, content_hash
        FROM public.legal_documents
        WHERE document_type = 'contract_terms'
          AND is_current = TRUE
          AND effective_from <= clock_timestamp()
          AND (
              effective_until IS NULL
              OR effective_until > clock_timestamp()
          )
        ORDER BY effective_from DESC, created_at DESC
        LIMIT 1
    $sql$
    INTO v_terms_document_id, v_terms_version,
         v_terms_snapshot, v_terms_hash;

    IF v_terms_document_id IS NULL THEN
        RAISE EXCEPTION
            'No existen Condiciones Generales de Contratación vigentes';
    END IF;

    IF v_terms_snapshot IS NULL OR v_terms_hash IS NULL THEN
        RAISE EXCEPTION
            'Las Condiciones Generales vigentes no tienen contenido íntegro y hash';
    END IF;

    -- --------------------------------------------------------
    -- 8. CABECERAS OBSERVADAS POR EL BACKEND/PROXY
    -- --------------------------------------------------------
    BEGIN
        v_headers := COALESCE(
            NULLIF(
                current_setting('request.headers', TRUE),
                ''
            )::JSONB,
            '{}'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        v_headers := '{}'::JSONB;
    END;

    v_ip :=
        COALESCE(
            NULLIF(TRIM(v_headers->>'cf-connecting-ip'), ''),
            NULLIF(TRIM(v_headers->>'x-real-ip'), ''),
            NULLIF(
                TRIM(
                    SPLIT_PART(
                        COALESCE(v_headers->>'x-forwarded-for', ''),
                        ',',
                        1
                    )
                ),
                ''
            )
        );

    v_user_agent :=
        NULLIF(
            LEFT(TRIM(COALESCE(v_headers->>'user-agent', '')), 2000),
            ''
        );

    -- --------------------------------------------------------
    -- 9. SNAPSHOT + HASH DEL PRESUPUESTO
    -- --------------------------------------------------------
    v_snapshot := to_jsonb(v_quotation);
    v_snapshot_hash :=
        encode(
            digest(
                convert_to(v_snapshot::TEXT, 'UTF8'),
                'sha256'
            ),
            'hex'
        );

    -- --------------------------------------------------------
    -- 10. REGISTRAR ACEPTACIÓN
    -- --------------------------------------------------------
    INSERT INTO public.quotation_acceptances (
        quotation_id,
        user_id,
        company_id,
        accepted_at,
        previous_state,
        resulting_state,
        quotation_version,
        quotation_snapshot,
        quotation_snapshot_hash,
        contract_terms_document_id,
        contract_terms_version,
        contract_terms_snapshot,
        contract_terms_hash,
        observed_ip,
        user_agent
    )
    VALUES (
        v_quotation.id,
        auth.uid(),
        v_quotation.company_id,
        clock_timestamp(),
        v_quotation.estado,
        'Aceptado',
        v_quotation.quotation_version,
        v_snapshot,
        v_snapshot_hash,
        v_terms_document_id,
        v_terms_version,
        v_terms_snapshot,
        v_terms_hash,
        v_ip,
        v_user_agent
    );

    -- --------------------------------------------------------
    -- 11. CAMBIAR ESTADO
    -- --------------------------------------------------------
    UPDATE public.quotations
    SET
        estado = 'Aceptado',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_quotation.id
    RETURNING * INTO v_quotation;

    RETURN v_quotation;
END;
$function$;

REVOKE ALL
ON FUNCTION public.respond_to_quotation(TEXT, UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.respond_to_quotation(TEXT, UUID)
TO authenticated;

ALTER FUNCTION public.respond_to_quotation(TEXT, UUID)
SET search_path = public, pg_temp;

COMMENT ON TABLE public.quotation_acceptances IS
'Registro inmutable de la aceptación electrónica de un presupuesto, incluyendo versión, snapshot, hashes y condiciones contractuales vigentes.';

COMMENT ON COLUMN public.quotations.quotation_version IS
'Versión contractual del presupuesto. Se incrementa cuando un presupuesto pendiente es modificado y queda congelada al aceptar.';

COMMENT ON FUNCTION public.respond_to_quotation(TEXT, UUID) IS
'Permite responder un presupuesto. Pendiente->Rechazado mantiene el flujo existente; Pendiente->Aceptado registra una aceptación contractual inmutable y congela el presupuesto.';

-- ============================================================
-- 7. VALIDACIONES FINALES
-- ============================================================
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'quotation_version'
    ) THEN
        RAISE EXCEPTION '029 failed: quotations.quotation_version missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'quotation_acceptances'
    ) THEN
        RAISE EXCEPTION '029 failed: quotation_acceptances missing';
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM pg_constraint
    WHERE conrelid = 'public.quotation_acceptances'::regclass
      AND conname IN (
          'quotation_acceptances_previous_state_check',
          'quotation_acceptances_resulting_state_check',
          'quotation_acceptances_version_check'
      );

    IF v_count <> 3 THEN
        RAISE EXCEPTION
            '029 failed: acceptance constraints incomplete';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'public.quotation_acceptances'::regclass
          AND relrowsecurity = TRUE
    ) THEN
        RAISE EXCEPTION '029 failed: quotation_acceptances RLS is disabled';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc
        WHERE pronamespace = 'public'::regnamespace
          AND proname = 'respond_to_quotation'
    ) THEN
        RAISE EXCEPTION '029 failed: respond_to_quotation() missing';
    END IF;

    IF NOT has_function_privilege(
        'authenticated',
        'public.respond_to_quotation(text,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '029 failed: authenticated cannot execute respond_to_quotation()';
    END IF;

    IF has_table_privilege(
        'authenticated',
        'public.quotation_acceptances',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '029 failed: authenticated retains INSERT on quotation_acceptances';
    END IF;

    IF has_table_privilege(
        'authenticated',
        'public.quotation_acceptances',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '029 failed: authenticated retains UPDATE on quotation_acceptances';
    END IF;

    IF has_table_privilege(
        'authenticated',
        'public.quotation_acceptances',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '029 failed: authenticated retains DELETE on quotation_acceptances';
    END IF;
END $$;

COMMIT;
