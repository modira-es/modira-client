-- ============================================================
-- MODIRA — 056 QUOTATION DOCUMENT ACKNOWLEDGEMENT
-- ============================================================
--
-- OBJETIVO
--
-- Añadir una segunda barrera de seguridad a la aceptación
-- contractual de presupuestos:
--
--   1. El cliente debe consultar el PDF.
--   2. El cliente debe marcar expresamente el checkbox.
--   3. Esa aceptación del documento queda registrada en BD.
--   4. Solo después puede ejecutar:
--
--        respond_to_quotation('Aceptado', quotation_id)
--
-- La aceptación contractual final continúa registrándose en:
--
--        public.quotation_acceptances
--
-- Esta migración NO sustituye quotation_acceptances.
--
-- ============================================================
--
-- SEGURIDAD
--
-- - El cliente no puede insertar directamente en la tabla.
-- - La identidad se obtiene mediante auth.uid().
-- - document_path se obtiene desde quotations.
-- - document_sha256 se obtiene desde quotations.
-- - La versión del texto se fija en backend.
-- - accepted_at se genera en backend.
-- - Los workers no pueden utilizar esta RPC para registrar
--   aceptaciones de documentos de clientes.
-- - respond_to_quotation() comprueba server-side que exista
--   un acknowledgement válido antes de aceptar.
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. HASH DEL PDF EN QUOTATIONS
-- ============================================================
--
-- El quotation_version protege el contenido de la fila
-- quotations, pero el PDF vive en Storage.
--
-- Por tanto necesitamos identificar criptográficamente
-- el PDF exacto que el cliente ha aceptado.
--
-- ============================================================

ALTER TABLE public.quotations
ADD COLUMN IF NOT EXISTS document_sha256 TEXT;


-- ============================================================
-- 2. VALIDACIÓN DEL HASH
-- ============================================================

ALTER TABLE public.quotations
DROP CONSTRAINT IF EXISTS quotations_document_sha256_check;

ALTER TABLE public.quotations
ADD CONSTRAINT quotations_document_sha256_check
CHECK (
    document_sha256 IS NULL
    OR document_sha256 ~ '^[0-9a-fA-F]{64}$'
);


-- ============================================================
-- 3. TABLA DE ACKNOWLEDGEMENT DEL PDF
-- ============================================================
--
-- Este registro NO es la aceptación contractual definitiva.
--
-- Representa:
--
-- "El cliente ha declarado haber leído/revisado este PDF
-- concreto antes de aceptar el presupuesto."
--
-- La aceptación contractual definitiva sigue en:
--
-- quotation_acceptances
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.quotation_document_acknowledgements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    quotation_id UUID NOT NULL
        REFERENCES public.quotations(id)
        ON DELETE RESTRICT,

    user_id UUID NOT NULL
        REFERENCES auth.users(id)
        ON DELETE RESTRICT,

    company_id UUID NOT NULL
        REFERENCES public.companies(id)
        ON DELETE RESTRICT,

    document_path TEXT NOT NULL,

    document_sha256 TEXT NOT NULL,

    acknowledgement_text_version TEXT NOT NULL,

    accepted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT quotation_document_ack_document_sha256_check
    CHECK (
        document_sha256 ~ '^[0-9a-fA-F]{64}$'
    ),

    CONSTRAINT quotation_document_ack_path_check
    CHECK (
        TRIM(document_path) <> ''
    ),

    CONSTRAINT quotation_document_ack_version_check
    CHECK (
        TRIM(acknowledgement_text_version) <> ''
    )
);


-- ============================================================
-- 4. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_quotation_document_ack_quotation
ON public.quotation_document_acknowledgements
    (quotation_id);

CREATE INDEX IF NOT EXISTS
    idx_quotation_document_ack_user
ON public.quotation_document_acknowledgements
    (user_id);

CREATE INDEX IF NOT EXISTS
    idx_quotation_document_ack_company
ON public.quotation_document_acknowledgements
    (company_id);

CREATE INDEX IF NOT EXISTS
    idx_quotation_document_ack_accepted_at
ON public.quotation_document_acknowledgements
    (accepted_at);


-- ============================================================
-- 5. ÍNDICE ÚNICO
-- ============================================================
--
-- Un mismo usuario puede volver a registrar la lectura si
-- cambia el PDF, cambia la versión del texto o ambas cosas.
--
-- Para el mismo:
--
-- quotation + user + PDF + versión del texto
--
-- solo existe un registro lógico.
--
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_quotation_document_ack_unique
ON public.quotation_document_acknowledgements (
    quotation_id,
    user_id,
    document_sha256,
    acknowledgement_text_version
);


-- ============================================================
-- 6. RLS
-- ============================================================

ALTER TABLE public.quotation_document_acknowledgements
ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 7. PRIVILEGIOS DIRECTOS
-- ============================================================
--
-- No permitimos INSERT/UPDATE/DELETE directo desde frontend.
-- La escritura se realizará exclusivamente mediante RPC.
--
-- ============================================================

REVOKE ALL
ON TABLE public.quotation_document_acknowledgements
FROM PUBLIC;

REVOKE ALL
ON TABLE public.quotation_document_acknowledgements
FROM anon;

REVOKE ALL
ON TABLE public.quotation_document_acknowledgements
FROM authenticated;


-- ============================================================
-- 8. SELECT PARA EL CLIENTE
-- ============================================================
--
-- El cliente puede consultar únicamente sus propios
-- acknowledgements y siempre que:
--
-- - esté autenticado;
-- - tenga cuenta activa;
-- - no sea worker;
-- - el acknowledgement corresponda a su compañía actual.
--
-- ============================================================

DROP POLICY IF EXISTS
    quotation_document_ack_client_select
ON public.quotation_document_acknowledgements;

CREATE POLICY
    quotation_document_ack_client_select
ON public.quotation_document_acknowledgements
FOR SELECT
TO authenticated
USING (
    user_id = auth.uid()
    AND public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND company_id = public.current_user_company_id()
);


-- ============================================================
-- 9. SELECT PARA WORKERS
-- ============================================================

DROP POLICY IF EXISTS
    quotation_document_ack_worker_select
ON public.quotation_document_acknowledgements;

CREATE POLICY
    quotation_document_ack_worker_select
ON public.quotation_document_acknowledgements
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 10. FUNCIÓN PARA GUARDAR EL HASH DEL PDF
-- ============================================================
--
-- Esta RPC será utilizada por el backend/Edge Function.
--
-- El cliente NO proporciona el hash.
--
-- Solo un worker puede establecerlo.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_quotation_document_hash(
    p_quotation_id UUID,
    p_document_path TEXT,
    p_document_sha256 TEXT
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_quotation public.quotations;
    v_expected_path TEXT;
    v_hash TEXT;

BEGIN

    -- ========================================================
    -- 1. AUTORIZACIÓN
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- ========================================================
    -- 2. VALIDAR HASH
    -- ========================================================

    v_hash := LOWER(TRIM(COALESCE(p_document_sha256, '')));

    IF v_hash = '' THEN
        RAISE EXCEPTION
            'El SHA-256 del documento es obligatorio';
    END IF;

    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION
            'El SHA-256 del documento no es válido';
    END IF;


    -- ========================================================
    -- 3. OBTENER PRESUPUESTO
    -- ========================================================

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Presupuesto no encontrado';
    END IF;


    -- ========================================================
    -- 4. CALCULAR RUTA ESPERADA
    -- ========================================================

    v_expected_path :=
        v_quotation.company_id::TEXT
        || '/'
        || v_quotation.numero_presupuesto
        || '.pdf';


    -- ========================================================
    -- 5. VALIDAR RUTA
    -- ========================================================

    IF p_document_path IS NULL
       OR TRIM(p_document_path) = '' THEN
        RAISE EXCEPTION
            'La ruta del documento es obligatoria';
    END IF;

    IF TRIM(p_document_path) <> v_expected_path THEN
        RAISE EXCEPTION
            'La ruta del documento no coincide con el presupuesto';
    END IF;


    -- ========================================================
    -- 6. EL PDF DEBE EXISTIR EN STORAGE
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'quotations'
          AND name = v_expected_path
    ) THEN
        RAISE EXCEPTION
            'El documento no existe en el bucket de presupuestos';
    END IF;


    -- ========================================================
    -- 7. EL DOCUMENT_PATH DEBE COINCIDIR
    -- ========================================================

    IF v_quotation.document_path IS DISTINCT FROM v_expected_path THEN
        RAISE EXCEPTION
            'El documento no está asociado al presupuesto';
    END IF;


    -- ========================================================
    -- 8. GUARDAR HASH
    -- ========================================================

    UPDATE public.quotations
    SET
        document_sha256 = v_hash,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_quotation.id
    RETURNING *
    INTO v_quotation;


    RETURN v_quotation;

END;
$function$;


-- ============================================================
-- 11. PERMISOS set_quotation_document_hash
-- ============================================================

REVOKE ALL
ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
TO authenticated;


ALTER FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
SET search_path = public, pg_temp;


-- ============================================================
-- 12. REDEFINIR attach_quotation_document()
-- ============================================================
--
-- IMPORTANTE:
--
-- Cada vez que se asocia/sustituye el PDF:
--
--     document_sha256 = NULL
--
-- Por tanto, cualquier acknowledgement anterior deja de ser
-- válido para el nuevo contenido.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_quotation_document(
    p_quotation_id UUID,
    p_document_path TEXT
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_quotation public.quotations;
    v_expected_path TEXT;

BEGIN

    -- ========================================================
    -- 1. WORKER
    -- ========================================================

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- ========================================================
    -- 2. OBTENER PRESUPUESTO
    -- ========================================================

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Presupuesto no encontrado';
    END IF;


    -- ========================================================
    -- 3. RUTA ESPERADA
    -- ========================================================

    v_expected_path :=
        v_quotation.company_id::TEXT
        || '/'
        || v_quotation.numero_presupuesto
        || '.pdf';


    -- ========================================================
    -- 4. VALIDAR RUTA
    -- ========================================================

    IF p_document_path IS NULL
       OR TRIM(p_document_path) = '' THEN
        RAISE EXCEPTION
            'El documento del presupuesto es obligatorio';
    END IF;

    IF p_document_path <> v_expected_path THEN
        RAISE EXCEPTION
            'La ruta del documento no coincide con el presupuesto';
    END IF;


    -- ========================================================
    -- 5. COMPROBAR EXISTENCIA FÍSICA
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM storage.objects
        WHERE bucket_id = 'quotations'
          AND name = p_document_path
    ) THEN
        RAISE EXCEPTION
            'El documento no existe en el bucket de presupuestos';
    END IF;


    -- ========================================================
    -- 6. ACTUALIZAR DOCUMENTO
    -- ========================================================
    --
    -- Al cambiar/asociar el PDF, el hash anterior deja de ser
    -- válido.
    --
    -- El nuevo PDF deberá volver a ser procesado por la Edge
    -- Function de hash.
    --
    -- ========================================================

    UPDATE public.quotations
    SET
        document_path = TRIM(p_document_path),
        document_sha256 = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_quotation_id
    RETURNING *
    INTO v_quotation;


    RETURN v_quotation;

END;
$function$;


-- ============================================================
-- 13. PERMISOS attach_quotation_document
-- ============================================================

REVOKE ALL
ON FUNCTION public.attach_quotation_document(UUID, TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.attach_quotation_document(UUID, TEXT)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.attach_quotation_document(UUID, TEXT)
TO authenticated;


ALTER FUNCTION public.attach_quotation_document(UUID, TEXT)
SET search_path = public, pg_temp;


-- ============================================================
-- 14. RPC PARA REGISTRAR LA LECTURA/ACEPTACIÓN DEL PDF
-- ============================================================
--
-- El cliente solo proporciona:
--
--     quotation_id
--
-- La función obtiene internamente:
--
--     auth.uid()
--     company_id
--     document_path
--     document_sha256
--
-- Por tanto el frontend NO puede elegir qué PDF dice haber
-- aceptado.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_quotation_document_acknowledgement(
    p_quotation_id UUID
)
RETURNS public.quotation_document_acknowledgements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_user_id UUID;
    v_quotation public.quotations;
    v_acknowledgement
        public.quotation_document_acknowledgements;

    v_acknowledgement_text_version TEXT :=
        'quotation_document_acknowledgement_v1';

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- ========================================================
    -- 2. SOLO CLIENTES
    -- ========================================================

    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Los trabajadores no pueden registrar la aceptación documental de un cliente';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'Acceso denegado: la cuenta no está activa';
    END IF;


    -- ========================================================
    -- 3. OBTENER PRESUPUESTO
    -- ========================================================

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Presupuesto no encontrado';
    END IF;


    -- ========================================================
    -- 4. COMPROBAR EMPRESA
    -- ========================================================

    IF v_quotation.company_id IS DISTINCT FROM
       public.current_user_company_id()
    THEN
        RAISE EXCEPTION
            'Acceso denegado al presupuesto';
    END IF;


    -- ========================================================
    -- 5. SOLO PRESUPUESTOS PENDIENTES
    -- ========================================================

    IF LOWER(TRIM(v_quotation.estado)) <> 'pendiente' THEN
        RAISE EXCEPTION
            'Solo se puede registrar la aceptación documental de un presupuesto pendiente';
    END IF;


    -- ========================================================
    -- 6. EL PRESUPUESTO DEBE TENER PDF
    -- ========================================================

    IF v_quotation.document_path IS NULL
       OR TRIM(v_quotation.document_path) = '' THEN
        RAISE EXCEPTION
            'Este presupuesto no tiene un PDF asociado';
    END IF;


    -- ========================================================
    -- 7. EL PRESUPUESTO DEBE TENER HASH
    -- ========================================================

    IF v_quotation.document_sha256 IS NULL
       OR TRIM(v_quotation.document_sha256) = '' THEN
        RAISE EXCEPTION
            'El PDF del presupuesto todavía no está preparado para su aceptación';
    END IF;

    IF LOWER(TRIM(v_quotation.document_sha256))
       !~ '^[0-9a-f]{64}$'
    THEN
        RAISE EXCEPTION
            'El hash del PDF del presupuesto no es válido';
    END IF;


    -- ========================================================
    -- 8. REGISTRAR ACKNOWLEDGEMENT
    -- ========================================================

    INSERT INTO public.quotation_document_acknowledgements (
        quotation_id,
        user_id,
        company_id,
        document_path,
        document_sha256,
        acknowledgement_text_version,
        accepted_at
    )
    VALUES (
        v_quotation.id,
        v_user_id,
        v_quotation.company_id,
        TRIM(v_quotation.document_path),
        LOWER(TRIM(v_quotation.document_sha256)),
        v_acknowledgement_text_version,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (
        quotation_id,
        user_id,
        document_sha256,
        acknowledgement_text_version
    )
    DO UPDATE
    SET
        document_path = EXCLUDED.document_path,
        accepted_at = EXCLUDED.accepted_at
    RETURNING *
    INTO v_acknowledgement;


    -- ========================================================
    -- 9. COMPROBACIÓN FINAL
    -- ========================================================

    IF v_acknowledgement.id IS NULL THEN
        RAISE EXCEPTION
            'No se ha podido registrar la aceptación del documento';
    END IF;


    RETURN v_acknowledgement;

END;
$function$;


-- ============================================================
-- 15. PERMISOS DE LA RPC
-- ============================================================

REVOKE ALL
ON FUNCTION public.record_quotation_document_acknowledgement(UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.record_quotation_document_acknowledgement(UUID)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.record_quotation_document_acknowledgement(UUID)
TO authenticated;


ALTER FUNCTION public.record_quotation_document_acknowledgement(UUID)
SET search_path = public, pg_temp;


-- ============================================================
-- 16. REDEFINIR respond_to_quotation()
-- ============================================================
--
-- Se mantiene la arquitectura contractual existente.
--
-- La única modificación funcional importante es:
--
-- Antes de crear quotation_acceptances y cambiar el estado
-- a Aceptado, se exige un acknowledgement válido del PDF
-- actualmente asociado al presupuesto.
--
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

    v_acknowledgement_text_version TEXT :=
        'quotation_document_acknowledgement_v1';

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'Acceso denegado: la cuenta no está activa';
    END IF;


    -- ========================================================
    -- 2. VALIDAR ESTADO
    -- ========================================================

    v_normalized_state :=
        INITCAP(
            LOWER(
                TRIM(
                    COALESCE(p_estado, '')
                )
            )
        );


    IF v_normalized_state NOT IN (
        'Aceptado',
        'Rechazado'
    ) THEN

        RAISE EXCEPTION
            'Estado de respuesta no válido. Debe ser Aceptado o Rechazado';

    END IF;


    -- ========================================================
    -- 3. BLOQUEAR PRESUPUESTO
    -- ========================================================

    SELECT *
    INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Presupuesto no encontrado';
    END IF;


    -- ========================================================
    -- 4. SOLO PENDIENTE
    -- ========================================================

    IF LOWER(TRIM(v_quotation.estado)) <> 'pendiente' THEN

        RAISE EXCEPTION
            'Este presupuesto ya ha sido respondido y no puede modificarse';

    END IF;


    -- ========================================================
    -- 5. COMPROBAR ACCESO
    -- ========================================================

    IF NOT public.current_user_is_worker() THEN

        IF v_quotation.company_id IS DISTINCT FROM
           public.current_user_company_id()
        THEN

            RAISE EXCEPTION
                'Acceso denegado al presupuesto';

        END IF;

    END IF;


    -- ========================================================
    -- 6. RECHAZADO
    -- ========================================================
    --
    -- El rechazo no requiere aceptar el PDF.
    --
    -- No existe perfeccionamiento contractual en este caso.
    --
    -- ========================================================

    IF v_normalized_state = 'Rechazado' THEN

        UPDATE public.quotations
        SET
            estado = 'Rechazado',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_quotation.id
        RETURNING *
        INTO v_quotation;

        RETURN v_quotation;

    END IF;


    -- ========================================================
    -- 7. ACEPTACIÓN — DEBE EXISTIR ACKNOWLEDGEMENT DEL PDF
    -- ========================================================
    --
    -- El acknowledgement debe corresponder exactamente a:
    --
    --   quotation
    --   usuario
    --   empresa
    --   document_path actual
    --   document_sha256 actual
    --   versión actual del texto
    --
    -- Esto impide reutilizar una aceptación correspondiente
    -- a otro PDF.
    --
    -- ========================================================

    IF v_quotation.document_path IS NULL
       OR TRIM(v_quotation.document_path) = ''
    THEN

        RAISE EXCEPTION
            'No se puede aceptar el presupuesto porque no tiene un PDF asociado';

    END IF;


    IF v_quotation.document_sha256 IS NULL
       OR TRIM(v_quotation.document_sha256) = ''
    THEN

        RAISE EXCEPTION
            'No se puede aceptar el presupuesto porque el PDF todavía no está preparado para su aceptación';

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.quotation_document_acknowledgements qa
        WHERE qa.quotation_id = v_quotation.id
          AND qa.user_id = auth.uid()
          AND qa.company_id = v_quotation.company_id
          AND qa.document_path =
              TRIM(v_quotation.document_path)
          AND qa.document_sha256 =
              LOWER(TRIM(v_quotation.document_sha256))
          AND qa.acknowledgement_text_version =
              v_acknowledgement_text_version
    ) THEN

        RAISE EXCEPTION
            'Debe leer y aceptar el PDF del presupuesto antes de aceptarlo';

    END IF;


    -- ========================================================
    -- 8. EVITAR DUPLICADO CONTRACTUAL
    -- ========================================================

    IF EXISTS (
        SELECT 1
        FROM public.quotation_acceptances qa
        WHERE qa.quotation_id = v_quotation.id
    ) THEN

        RAISE EXCEPTION
            'Este presupuesto ya tiene una aceptación contractual registrada';

    END IF;


    -- ========================================================
    -- 9. OBTENER TÉRMINOS CONTRACTUALES VIGENTES
    -- ========================================================

    IF to_regclass('public.legal_documents') IS NULL THEN

        RAISE EXCEPTION
            'La infraestructura de documentos legales no está instalada';

    END IF;


    EXECUTE $sql$

        SELECT
            id,
            version,
            content,
            content_hash

        FROM public.legal_documents

        WHERE document_type = 'contract_terms'

          AND is_current = TRUE

          AND effective_from <= clock_timestamp()

          AND (
              effective_until IS NULL
              OR effective_until > clock_timestamp()
          )

        ORDER BY
            effective_from DESC,
            created_at DESC

        LIMIT 1

    $sql$

    INTO
        v_terms_document_id,
        v_terms_version,
        v_terms_snapshot,
        v_terms_hash;


    IF v_terms_document_id IS NULL THEN

        RAISE EXCEPTION
            'No existen Condiciones Generales de Contratación vigentes';

    END IF;


    IF v_terms_snapshot IS NULL
       OR v_terms_hash IS NULL
    THEN

        RAISE EXCEPTION
            'Las Condiciones Generales vigentes no tienen contenido íntegro y hash';

    END IF;


    -- ========================================================
    -- 10. CABECERAS
    -- ========================================================

    BEGIN

        v_headers := COALESCE(
            NULLIF(
                current_setting(
                    'request.headers',
                    TRUE
                ),
                ''
            )::JSONB,
            '{}'::JSONB
        );

    EXCEPTION WHEN OTHERS THEN

        v_headers := '{}'::JSONB;

    END;


    v_ip :=
        COALESCE(

            NULLIF(
                TRIM(
                    v_headers->>'cf-connecting-ip'
                ),
                ''
            ),

            NULLIF(
                TRIM(
                    v_headers->>'x-real-ip'
                ),
                ''
            ),

            NULLIF(
                TRIM(
                    SPLIT_PART(
                        COALESCE(
                            v_headers->>'x-forwarded-for',
                            ''
                        ),
                        ',',
                        1
                    )
                ),
                ''
            )

        );


    v_user_agent :=
        NULLIF(
            LEFT(
                TRIM(
                    COALESCE(
                        v_headers->>'user-agent',
                        ''
                    )
                ),
                2000
            ),
            ''
        );


    -- ========================================================
    -- 11. SNAPSHOT + HASH DEL PRESUPUESTO
    -- ========================================================

    v_snapshot :=
        to_jsonb(v_quotation);


    v_snapshot_hash :=
        encode(
            digest(
                convert_to(
                    v_snapshot::TEXT,
                    'UTF8'
                ),
                'sha256'
            ),
            'hex'
        );


    -- ========================================================
    -- 12. REGISTRAR ACEPTACIÓN CONTRACTUAL
    -- ========================================================

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


    -- ========================================================
    -- 13. CAMBIAR ESTADO
    -- ========================================================

    UPDATE public.quotations

    SET

        estado = 'Aceptado',

        updated_at = CURRENT_TIMESTAMP

    WHERE id = v_quotation.id

    RETURNING *
    INTO v_quotation;


    RETURN v_quotation;

END;
$function$;


-- ============================================================
-- 17. PERMISOS respond_to_quotation
-- ============================================================

REVOKE ALL
ON FUNCTION public.respond_to_quotation(TEXT, UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.respond_to_quotation(TEXT, UUID)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.respond_to_quotation(TEXT, UUID)
TO authenticated;


ALTER FUNCTION public.respond_to_quotation(TEXT, UUID)
SET search_path = public, pg_temp;


-- ============================================================
-- 18. COMENTARIOS
-- ============================================================

COMMENT ON COLUMN public.quotations.document_sha256
IS
'SHA-256 del PDF actualmente asociado al presupuesto. Se invalida cuando se sustituye el documento y debe ser regenerado por backend antes de aceptar el presupuesto.';


COMMENT ON TABLE public.quotation_document_acknowledgements
IS
'Registro de la aceptación previa del PDF de un presupuesto por parte del cliente. No sustituye quotation_acceptances, que conserva la aceptación contractual definitiva.';


COMMENT ON FUNCTION public.record_quotation_document_acknowledgement(UUID)
IS
'Registra que el cliente ha aceptado documentalmente el PDF actualmente asociado a un presupuesto. El documento, empresa, usuario y SHA-256 se obtienen desde backend/BD y no son elegibles por el frontend.';


COMMENT ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
IS
'Establece el SHA-256 del PDF actualmente asociado a un presupuesto. Solo puede ejecutarla un worker activo.';


-- ============================================================
-- 19. VERIFICACIONES FINALES
-- ============================================================

DO $$

DECLARE

    v_count INTEGER;

BEGIN

    -- --------------------------------------------------------
    -- quotations.document_sha256
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'quotations'
      AND column_name = 'document_sha256';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '056 failed: quotations.document_sha256 missing';

    END IF;


    -- --------------------------------------------------------
    -- quotation_document_acknowledgements
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name =
          'quotation_document_acknowledgements';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '056 failed: quotation_document_acknowledgements table missing';

    END IF;


    -- --------------------------------------------------------
    -- RPC acknowledgement
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname =
          'record_quotation_document_acknowledgement'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_quotation_id uuid';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '056 failed: record_quotation_document_acknowledgement(uuid) missing';

    END IF;


    -- --------------------------------------------------------
    -- RPC hash
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname =
          'set_quotation_document_hash'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_quotation_id uuid, p_document_path text, p_document_sha256 text';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '056 failed: set_quotation_document_hash(uuid,text,text) missing';

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
      AND p.proname =
          'respond_to_quotation'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_estado text, p_quotation_id uuid';


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '056 failed: respond_to_quotation(text,uuid) missing';

    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename =
          'quotation_document_acknowledgements'
      AND rowsecurity = TRUE;


    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '056 failed: quotation_document_acknowledgements RLS missing';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO tiene INSERT directo
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.quotation_document_acknowledgements',
        'INSERT'
    ) THEN

        RAISE EXCEPTION
            '056 failed: authenticated must not have INSERT on quotation_document_acknowledgements';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO tiene UPDATE directo
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.quotation_document_acknowledgements',
        'UPDATE'
    ) THEN

        RAISE EXCEPTION
            '056 failed: authenticated must not have UPDATE on quotation_document_acknowledgements';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO tiene DELETE directo
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.quotation_document_acknowledgements',
        'DELETE'
    ) THEN

        RAISE EXCEPTION
            '056 failed: authenticated must not have DELETE on quotation_document_acknowledgements';

    END IF;


END;
$$;


COMMIT;