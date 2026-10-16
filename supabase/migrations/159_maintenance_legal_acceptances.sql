-- ============================================================
-- 092_maintenance_legal_acceptances.sql
-- Modira — aceptación de condiciones legales para checkout
-- de mantenimiento (planes fijos y propuestas personalizadas).
--
-- Diseño:
--   * Reutiliza public.legal_documents y public.legal_acceptances.
--   * No modifica aceptaciones de registro, presupuestos, facturas
--     ni el acuse del PDF de una propuesta personalizada.
--   * Registra las dos aceptaciones en una única transacción RPC.
--   * Solo service_role puede ejecutar la RPC; la Edge Function
--     valida identidad/checkout y llama a esta función.
--   * No publica textos legales inventados: los dos documentos
--     vigentes deben cargarse en legal_documents antes de habilitar
--     el checkout actualizado.
-- ============================================================

BEGIN;

-- 1. Ampliar los tipos permitidos conservando todos los existentes.
ALTER TABLE public.legal_documents
    DROP CONSTRAINT IF EXISTS legal_documents_type_check;

ALTER TABLE public.legal_documents
    ADD CONSTRAINT legal_documents_type_check
    CHECK (
        document_type = ANY (
            ARRAY[
                'terms_of_use'::text,
                'privacy_information'::text,
                'contract_terms'::text,
                'audit_terms'::text,
                'cookie_policy'::text,
                'maintenance_contract_terms'::text,
                'maintenance_specific_conditions'::text
            ]
        )
    );

-- 2. RPC backend: valida los dos checks y guarda las dos evidencias
--    atómicamente. No acepta IDs, versiones ni hashes de documentos
--    proporcionados por el navegador: los resuelve desde documentos
--    vigentes en la base de datos.
CREATE OR REPLACE FUNCTION public.record_maintenance_legal_acceptances(
    p_user_id UUID,
    p_company_id UUID,
    p_checkout_attempt_id UUID,
    p_checkout_session_id TEXT,
    p_plan_id UUID,
    p_proposal_id UUID DEFAULT NULL,
    p_general_accepted BOOLEAN DEFAULT FALSE,
    p_specific_accepted BOOLEAN DEFAULT FALSE,
    p_ip TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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
    v_now TIMESTAMPTZ := clock_timestamp();
    v_ip TEXT;
    v_user_agent TEXT;
BEGIN
    -- La función es exclusiva del backend y aun así valida sus datos.
    IF p_user_id IS NULL OR p_company_id IS NULL
       OR p_checkout_attempt_id IS NULL
       OR NULLIF(BTRIM(p_checkout_session_id), '') IS NULL
       OR p_plan_id IS NULL
    THEN
        RAISE EXCEPTION 'Faltan datos obligatorios del checkout de mantenimiento';
    END IF;

    IF p_general_accepted IS NOT TRUE THEN
        RAISE EXCEPTION 'Debes aceptar las condiciones generales de mantenimiento';
    END IF;

    IF p_specific_accepted IS NOT TRUE THEN
        RAISE EXCEPTION 'Debes aceptar las condiciones particulares de mantenimiento';
    END IF;

    -- Evita que un mismo intento se registre dos veces en paralelo.
    PERFORM pg_advisory_xact_lock(
        hashtextextended('maintenance-legal-checkout:' || p_checkout_attempt_id::TEXT, 0)
    );

    -- Idempotencia segura: si este intento ya quedó registrado, solo
    -- se admite la repetición si están presentes las dos evidencias
    -- asociadas a la misma sesión de Stripe.
    SELECT COUNT(*)
      INTO v_existing_count
      FROM public.legal_acceptances la
     WHERE la.context = 'maintenance_checkout'
       AND la.metadata ->> 'maintenance_checkout_attempt_id' = p_checkout_attempt_id::TEXT;

    IF v_existing_count > 0 THEN
        IF v_existing_count = 2
           AND NOT EXISTS (
               SELECT 1
                 FROM public.legal_acceptances la
                WHERE la.context = 'maintenance_checkout'
                  AND la.metadata ->> 'maintenance_checkout_attempt_id' = p_checkout_attempt_id::TEXT
                  AND la.metadata ->> 'stripe_checkout_session_id' IS DISTINCT FROM p_checkout_session_id
           )
        THEN
            RETURN jsonb_build_object(
                'ok', TRUE,
                'already_recorded', TRUE,
                'checkout_attempt_id', p_checkout_attempt_id,
                'stripe_checkout_session_id', p_checkout_session_id
            );
        END IF;

        RAISE EXCEPTION 'El intento de checkout ya tiene un registro legal incompleto o inconsistente';
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

    -- Obtener las dos versiones legales vigentes desde la fuente oficial.
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

    -- La tabla legal_documents ya valida el formato SHA-256. Se repite
    -- aquí como defensa en profundidad antes de insertar evidencia.
    IF v_general_hash !~ '^[0-9a-f]{64}$'
       OR v_specific_hash !~ '^[0-9a-f]{64}$'
    THEN
        RAISE EXCEPTION 'El hash de uno de los documentos legales no es válido';
    END IF;

    -- Los límites respetan las restricciones actuales de legal_acceptances.
    v_ip := LEFT(NULLIF(BTRIM(p_ip), ''), 200);
    v_user_agent := LEFT(NULLIF(BTRIM(p_user_agent), ''), 2000);

    INSERT INTO public.legal_acceptances (
        user_id,
        company_id,
        document_id,
        action_type,
        accepted_at,
        ip,
        user_agent,
        context,
        source,
        document_hash,
        metadata
    ) VALUES (
        p_user_id,
        p_company_id,
        v_general_id,
        'accepted',
        v_now,
        v_ip,
        v_user_agent,
        'maintenance_checkout',
        'maintenance_checkout',
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
        user_id,
        company_id,
        document_id,
        action_type,
        accepted_at,
        ip,
        user_agent,
        context,
        source,
        document_hash,
        metadata
    ) VALUES (
        p_user_id,
        p_company_id,
        v_specific_id,
        'accepted',
        v_now,
        v_ip,
        v_user_agent,
        'maintenance_checkout',
        'maintenance_checkout',
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

-- La RPC contiene datos de auditoría y acepta identidades explícitas:
-- se reserva exclusivamente a service_role desde la Edge Function.
REVOKE ALL ON FUNCTION public.record_maintenance_legal_acceptances(
    UUID, UUID, UUID, TEXT, UUID, UUID, BOOLEAN, BOOLEAN, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.record_maintenance_legal_acceptances(
    UUID, UUID, UUID, TEXT, UUID, UUID, BOOLEAN, BOOLEAN, TEXT, TEXT
) TO service_role;


CREATE OR REPLACE FUNCTION public.publish_legal_document_version(
    p_document_type TEXT,
    p_version TEXT,
    p_title TEXT,
    p_content TEXT,
    p_effective_from TIMESTAMPTZ DEFAULT NOW()
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
    v_document_id UUID;
BEGIN
    -- Validar el tipo de documento.
    IF p_document_type NOT IN (
        'maintenance_contract_terms',
        'maintenance_specific_conditions'
    ) THEN
        RAISE EXCEPTION
            'Tipo de documento no permitido: %',
            p_document_type;
    END IF;

    -- Validar la versión.
    IF p_version IS NULL OR BTRIM(p_version) = '' THEN
        RAISE EXCEPTION
            'La versión del documento es obligatoria';
    END IF;

    -- Validar el título.
    IF p_title IS NULL OR BTRIM(p_title) = '' THEN
        RAISE EXCEPTION
            'El título del documento es obligatorio';
    END IF;

    -- Validar el contenido.
    IF p_content IS NULL OR BTRIM(p_content) = '' THEN
        RAISE EXCEPTION
            'El contenido del documento es obligatorio';
    END IF;

    IF p_effective_from IS NULL THEN
        RAISE EXCEPTION
            'La fecha de entrada en vigor es obligatoria';
    END IF;

    -- Evitar reutilizar una versión del mismo tipo.
    IF EXISTS (
        SELECT 1
        FROM public.legal_documents
        WHERE document_type = p_document_type
          AND version = p_version
    ) THEN
        RAISE EXCEPTION
            'La versión % ya existe para el documento %',
            p_version,
            p_document_type;
    END IF;

    -- Desactivar la versión actualmente vigente.
    UPDATE public.legal_documents
    SET is_current = FALSE
    WHERE document_type = p_document_type
      AND is_current = TRUE;

    -- Insertar una nueva versión independiente.
    INSERT INTO public.legal_documents (
        document_type,
        version,
        title,
        content,
        effective_from,
        effective_until,
        is_current
    )
    VALUES (
        p_document_type,
        p_version,
        p_title,
        p_content,
        p_effective_from,
        NULL,
        TRUE
    )
    RETURNING id INTO v_document_id;

    RETURN v_document_id;
END;
$function$;

COMMIT;
