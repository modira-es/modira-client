-- ============================================================
-- 161_maintenance_legal_acceptance_expected_versions.sql
-- Modira — validación atómica de versiones aceptadas para checkout
-- de mantenimiento (planes fijos y propuestas personalizadas).
--
-- Conserva el registro de las dos aceptaciones y su auditoría. Añade
-- las versiones que el usuario vio como argumentos obligatorios y las
-- compara con los documentos vigentes DENTRO de la RPC, antes de insertar.
-- También serializa el registro frente a publicaciones concurrentes.
--
-- IMPORTANTE: desplegar la Edge Function que envía:
--   p_expected_general_version
--   p_expected_specific_version
-- antes de volver a habilitar el checkout con esta RPC.
-- ============================================================

BEGIN;

-- Eliminar la firma anterior: no debe quedar una vía de ejecución que
-- permita registrar aceptaciones sin las versiones que el usuario vio.
DROP FUNCTION IF EXISTS public.record_maintenance_legal_acceptances(
    UUID, UUID, UUID, TEXT, UUID, UUID, BOOLEAN, BOOLEAN, TEXT, TEXT
);

CREATE FUNCTION public.record_maintenance_legal_acceptances(
    p_user_id UUID,
    p_company_id UUID,
    p_checkout_attempt_id UUID,
    p_checkout_session_id TEXT,
    p_plan_id UUID,
    p_expected_general_version TEXT,
    p_expected_specific_version TEXT,
    p_proposal_id UUID DEFAULT NULL,
    p_general_accepted BOOLEAN DEFAULT FALSE,
    p_specific_accepted BOOLEAN DEFAULT FALSE,
    p_ip TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
    v_profile_company_id UUID;
    v_profile_status TEXT;

    v_general_id UUID;
    v_general_version TEXT;
    v_general_hash TEXT;

    v_specific_id UUID;
    v_specific_version TEXT;
    v_specific_hash TEXT;

    v_existing_count INTEGER;
    v_existing_general_count INTEGER;
    v_existing_specific_count INTEGER;
    v_existing_general_version TEXT;
    v_existing_specific_version TEXT;
    v_existing_general_id UUID;
    v_existing_specific_id UUID;
    v_existing_general_hash TEXT;
    v_existing_specific_hash TEXT;

    v_now TIMESTAMPTZ;
    v_ip TEXT;
    v_user_agent TEXT;
BEGIN
    -- Validación de los datos obligatorios del checkout.
    IF p_user_id IS NULL
       OR p_company_id IS NULL
       OR p_checkout_attempt_id IS NULL
       OR NULLIF(BTRIM(p_checkout_session_id), '') IS NULL
       OR p_plan_id IS NULL
    THEN
        RAISE EXCEPTION 'Faltan datos obligatorios del checkout de mantenimiento';
    END IF;

    IF NULLIF(BTRIM(p_expected_general_version), '') IS NULL THEN
        RAISE EXCEPTION 'Falta la versión esperada de las condiciones generales';
    END IF;

    IF NULLIF(BTRIM(p_expected_specific_version), '') IS NULL THEN
        RAISE EXCEPTION 'Falta la versión esperada de las condiciones particulares';
    END IF;

    IF p_general_accepted IS NOT TRUE THEN
        RAISE EXCEPTION 'Debes aceptar las condiciones generales de mantenimiento';
    END IF;

    IF p_specific_accepted IS NOT TRUE THEN
        RAISE EXCEPTION 'Debes aceptar las condiciones particulares de mantenimiento';
    END IF;

    -- Un mismo intento se procesa de forma serializada.
    PERFORM pg_advisory_xact_lock(
        hashtextextended('maintenance-legal-checkout:' || p_checkout_attempt_id::TEXT, 0)
    );

    -- Compartir los mismos bloqueos por tipo que la RPC de publicación.
    -- Así una publicación no puede cambiar un documento entre la lectura
    -- de las versiones vigentes y la inserción de las aceptaciones.
    PERFORM pg_advisory_xact_lock(
        hashtextextended('legal-document-publish:maintenance_contract_terms', 0)
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended('legal-document-publish:maintenance_specific_conditions', 0)
    );

    -- Tomar la hora después de adquirir los bloqueos.
    v_now := clock_timestamp();

    -- Idempotencia: un reintento solo puede recuperar las dos evidencias
    -- del mismo intento/sesión y con las mismas versiones esperadas.
    SELECT COUNT(*)
      INTO v_existing_count
      FROM public.legal_acceptances la
     WHERE la.context = 'maintenance_checkout'
       AND la.metadata ->> 'maintenance_checkout_attempt_id' = p_checkout_attempt_id::TEXT;

    IF v_existing_count > 0 THEN
        IF v_existing_count <> 2 THEN
            RAISE EXCEPTION 'El intento de checkout ya tiene un registro legal incompleto o inconsistente';
        END IF;

        IF EXISTS (
            SELECT 1
              FROM public.legal_acceptances la
             WHERE la.context = 'maintenance_checkout'
               AND la.metadata ->> 'maintenance_checkout_attempt_id' = p_checkout_attempt_id::TEXT
               AND (
                   la.metadata ->> 'stripe_checkout_session_id' IS DISTINCT FROM p_checkout_session_id
                   OR la.user_id IS DISTINCT FROM p_user_id
                   OR la.company_id IS DISTINCT FROM p_company_id
                   OR la.metadata ->> 'plan_id' IS DISTINCT FROM p_plan_id::TEXT
                   OR la.metadata ->> 'document_version' IS NULL
               )
        ) THEN
            RAISE EXCEPTION 'El intento de checkout ya tiene un registro legal inconsistente';
        END IF;

        SELECT COUNT(*),
               (ARRAY_AGG(la.document_id) FILTER (
                   WHERE la.metadata ->> 'document_type' = 'maintenance_contract_terms'
               ))[1],
               MAX(la.metadata ->> 'document_version') FILTER (
                   WHERE la.metadata ->> 'document_type' = 'maintenance_contract_terms'
               ),
               MAX(la.document_hash) FILTER (
                   WHERE la.metadata ->> 'document_type' = 'maintenance_contract_terms'
               )
          INTO v_existing_general_count,
               v_existing_general_id,
               v_existing_general_version,
               v_existing_general_hash
          FROM public.legal_acceptances la
         WHERE la.context = 'maintenance_checkout'
           AND la.metadata ->> 'maintenance_checkout_attempt_id' = p_checkout_attempt_id::TEXT
           AND la.metadata ->> 'document_type' = 'maintenance_contract_terms';

        SELECT COUNT(*),
               (ARRAY_AGG(la.document_id) FILTER (
                   WHERE la.metadata ->> 'document_type' = 'maintenance_specific_conditions'
               ))[1],
               MAX(la.metadata ->> 'document_version') FILTER (
                   WHERE la.metadata ->> 'document_type' = 'maintenance_specific_conditions'
               ),
               MAX(la.document_hash) FILTER (
                   WHERE la.metadata ->> 'document_type' = 'maintenance_specific_conditions'
               )
          INTO v_existing_specific_count,
               v_existing_specific_id,
               v_existing_specific_version,
               v_existing_specific_hash
          FROM public.legal_acceptances la
         WHERE la.context = 'maintenance_checkout'
           AND la.metadata ->> 'maintenance_checkout_attempt_id' = p_checkout_attempt_id::TEXT
           AND la.metadata ->> 'document_type' = 'maintenance_specific_conditions';

        IF v_existing_general_count <> 1 OR v_existing_specific_count <> 1 THEN
            RAISE EXCEPTION 'El intento de checkout no contiene exactamente una aceptación por cada documento legal';
        END IF;

        IF v_existing_general_version IS DISTINCT FROM p_expected_general_version
           OR v_existing_specific_version IS DISTINCT FROM p_expected_specific_version
        THEN
            RAISE EXCEPTION 'Las versiones aceptadas no coinciden con las versiones esperadas para este checkout';
        END IF;

        RETURN jsonb_build_object(
            'ok', TRUE,
            'already_recorded', TRUE,
            'checkout_attempt_id', p_checkout_attempt_id,
            'stripe_checkout_session_id', p_checkout_session_id,
            'general_terms', jsonb_build_object(
                'document_id', v_existing_general_id,
                'version', v_existing_general_version,
                'content_hash', v_existing_general_hash
            ),
            'specific_conditions', jsonb_build_object(
                'document_id', v_existing_specific_id,
                'version', v_existing_specific_version,
                'content_hash', v_existing_specific_hash
            )
        );
    END IF;

    -- La persona debe seguir activa y pertenecer a la empresa indicada.
    SELECT p.company_id, p.status
      INTO v_profile_company_id, v_profile_status
      FROM public.profiles p
     WHERE p.id = p_user_id;

    IF NOT FOUND
       OR v_profile_status IS DISTINCT FROM 'active'
       OR v_profile_company_id IS DISTINCT FROM p_company_id
    THEN
        RAISE EXCEPTION 'El usuario no está activo o no pertenece a la empresa del checkout';
    END IF;

    -- Leer las condiciones generales vigentes.
    SELECT ld.id, ld.version, ld.content_hash
      INTO v_general_id, v_general_version, v_general_hash
      FROM public.legal_documents ld
     WHERE ld.document_type = 'maintenance_contract_terms'
       AND ld.is_current = TRUE
       AND ld.effective_from <= v_now
       AND (ld.effective_until IS NULL OR ld.effective_until > v_now)
     ORDER BY ld.effective_from DESC, ld.created_at DESC
     LIMIT 1;

    IF v_general_id IS NULL THEN
        RAISE EXCEPTION 'No existen condiciones generales de mantenimiento vigentes';
    END IF;

    -- Leer las condiciones particulares vigentes.
    SELECT ld.id, ld.version, ld.content_hash
      INTO v_specific_id, v_specific_version, v_specific_hash
      FROM public.legal_documents ld
     WHERE ld.document_type = 'maintenance_specific_conditions'
       AND ld.is_current = TRUE
       AND ld.effective_from <= v_now
       AND (ld.effective_until IS NULL OR ld.effective_until > v_now)
     ORDER BY ld.effective_from DESC, ld.created_at DESC
     LIMIT 1;

    IF v_specific_id IS NULL THEN
        RAISE EXCEPTION 'No existen condiciones particulares de mantenimiento vigentes';
    END IF;

    -- La comprobación sucede antes de crear ninguna evidencia.
    IF v_general_version IS DISTINCT FROM p_expected_general_version THEN
        RAISE EXCEPTION 'Las condiciones generales han cambiado. Recarga y acepta la versión vigente antes de contratar';
    END IF;

    IF v_specific_version IS DISTINCT FROM p_expected_specific_version THEN
        RAISE EXCEPTION 'Las condiciones particulares han cambiado. Recarga y acepta la versión vigente antes de contratar';
    END IF;

    -- Validar hashes, incluidos valores NULL, antes de guardar evidencia.
    IF v_general_hash IS NULL
       OR v_specific_hash IS NULL
       OR v_general_hash !~ '^[0-9a-f]{64}$'
       OR v_specific_hash !~ '^[0-9a-f]{64}$'
    THEN
        RAISE EXCEPTION 'El hash de uno de los documentos legales no es válido';
    END IF;

    v_ip := LEFT(NULLIF(BTRIM(p_ip), ''), 200);
    v_user_agent := LEFT(NULLIF(BTRIM(p_user_agent), ''), 2000);

    -- Las dos inserciones son atómicas: si alguna falla, ninguna queda guardada.
    INSERT INTO public.legal_acceptances (
        user_id, company_id, document_id, action_type, accepted_at,
        ip, user_agent, context, source, document_hash, metadata
    ) VALUES (
        p_user_id, p_company_id, v_general_id, 'accepted', v_now,
        v_ip, v_user_agent, 'maintenance_checkout', 'maintenance_checkout',
        v_general_hash,
        jsonb_build_object(
            'maintenance_checkout_attempt_id', p_checkout_attempt_id,
            'stripe_checkout_session_id', p_checkout_session_id,
            'plan_id', p_plan_id,
            'proposal_id', p_proposal_id,
            'document_type', 'maintenance_contract_terms',
            'document_version', v_general_version
        )
    );

    INSERT INTO public.legal_acceptances (
        user_id, company_id, document_id, action_type, accepted_at,
        ip, user_agent, context, source, document_hash, metadata
    ) VALUES (
        p_user_id, p_company_id, v_specific_id, 'accepted', v_now,
        v_ip, v_user_agent, 'maintenance_checkout', 'maintenance_checkout',
        v_specific_hash,
        jsonb_build_object(
            'maintenance_checkout_attempt_id', p_checkout_attempt_id,
            'stripe_checkout_session_id', p_checkout_session_id,
            'plan_id', p_plan_id,
            'proposal_id', p_proposal_id,
            'document_type', 'maintenance_specific_conditions',
            'document_version', v_specific_version
        )
    );

    RETURN jsonb_build_object(
        'ok', TRUE,
        'already_recorded', FALSE,
        'checkout_attempt_id', p_checkout_attempt_id,
        'stripe_checkout_session_id', p_checkout_session_id,
        'general_terms', jsonb_build_object(
            'document_id', v_general_id,
            'version', v_general_version,
            'content_hash', v_general_hash
        ),
        'specific_conditions', jsonb_build_object(
            'document_id', v_specific_id,
            'version', v_specific_version,
            'content_hash', v_specific_hash
        )
    );
END;
$function$;

-- La RPC contiene datos de auditoría y recibe identidades explícitas:
-- solo la Edge Function con service_role debe poder ejecutarla.
REVOKE ALL ON FUNCTION public.record_maintenance_legal_acceptances(
    UUID, UUID, UUID, TEXT, UUID, TEXT, TEXT, UUID, BOOLEAN, BOOLEAN, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.record_maintenance_legal_acceptances(
    UUID, UUID, UUID, TEXT, UUID, TEXT, TEXT, UUID, BOOLEAN, BOOLEAN, TEXT, TEXT
) TO service_role;

GRANT SELECT ON TABLE public.legal_documents TO service_role;

COMMIT;
