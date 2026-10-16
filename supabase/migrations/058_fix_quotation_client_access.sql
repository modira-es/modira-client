-- ============================================================
-- 058_fix_quotation_client_access.sql
-- Corrige el acceso de clientes a presupuestos
-- ============================================================


-- ============================================================
-- 1. ACKNOWLEDGEMENT DEL PDF
-- ============================================================

CREATE OR REPLACE FUNCTION public.record_quotation_document_acknowledgement(
    p_quotation_id UUID
)
RETURNS public.quotation_document_acknowledgements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_user_id UUID;
    v_quotation public.quotations;
    v_acknowledgement public.quotation_document_acknowledgements;
    v_acknowledgement_text_version TEXT :=
        'quotation_document_acknowledgement_v1';

BEGIN

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    IF public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Los trabajadores no pueden registrar la aceptación documental de un cliente';
    END IF;


    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'Acceso denegado: la cuenta no está activa';
    END IF;


    -- ========================================================
    -- OBTENER PRESUPUESTO
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
    -- COMPROBAR QUE EL USUARIO ES EL CLIENTE DEL PRESUPUESTO
    -- ========================================================
    --
    -- La empresa del presupuesto pertenece a la empresa que
    -- gestiona el proyecto.
    --
    -- El cliente se identifica mediante:
    --
    -- quotations.client_id
    --        ↓
    -- clients.profile_id
    --        ↓
    -- auth.uid()
    --
    -- ========================================================

    IF v_quotation.client_id IS NULL
       OR NOT EXISTS (
            SELECT 1
            FROM public.clients c
            WHERE c.id = v_quotation.client_id
              AND c.profile_id = v_user_id
       )
    THEN
        RAISE EXCEPTION
            'Acceso denegado al presupuesto';
    END IF;


    -- ========================================================
    -- SOLO PRESUPUESTOS PENDIENTES
    -- ========================================================

    IF LOWER(TRIM(v_quotation.estado)) <> 'pendiente' THEN
        RAISE EXCEPTION
            'Solo se puede registrar la aceptación documental de un presupuesto pendiente';
    END IF;


    -- ========================================================
    -- COMPROBAR PDF
    -- ========================================================

    IF v_quotation.document_path IS NULL
       OR TRIM(v_quotation.document_path) = ''
    THEN
        RAISE EXCEPTION
            'Este presupuesto no tiene un PDF asociado';
    END IF;


    IF v_quotation.document_sha256 IS NULL
       OR TRIM(v_quotation.document_sha256) = ''
    THEN
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
    -- REGISTRAR ACKNOWLEDGEMENT
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


    IF v_acknowledgement.id IS NULL THEN
        RAISE EXCEPTION
            'No se ha podido registrar la aceptación del documento';
    END IF;


    RETURN v_acknowledgement;

END;
$function$;


-- ============================================================
-- 2. RESPUESTA CONTRACTUAL DEL PRESUPUESTO
-- ============================================================

CREATE OR REPLACE FUNCTION public.respond_to_quotation(
    p_estado TEXT,
    p_quotation_id UUID
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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
    --
    -- LOS TRABAJADORES:
    --   Mantienen el comportamiento actual.
    --
    -- LOS CLIENTES:
    --   Deben ser exactamente el cliente asociado al presupuesto.
    --
    --   quotations.client_id
    --          ↓
    --   clients.profile_id
    --          ↓
    --   auth.uid()
    --
    -- No se compara quotation.company_id con la empresa
    -- del perfil del cliente porque son empresas diferentes
    -- dentro del modelo actual.
    --
    -- ========================================================

    IF NOT public.current_user_is_worker() THEN

        IF v_quotation.client_id IS NULL
           OR NOT EXISTS (
                SELECT 1
                FROM public.clients c
                WHERE c.id = v_quotation.client_id
                  AND c.profile_id = auth.uid()
           )
        THEN

            RAISE EXCEPTION
                'Acceso denegado al presupuesto';

        END IF;

    END IF;


    -- ========================================================
    -- 6. RECHAZADO
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