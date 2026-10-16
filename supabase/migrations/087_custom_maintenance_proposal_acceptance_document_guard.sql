BEGIN;

-- ============================================================
-- MODIRA — 087 CUSTOM MAINTENANCE PROPOSAL ACCEPTANCE GUARD
-- ============================================================
--
-- OBJETIVO
--
-- Garantizar que una propuesta Custom de mantenimiento no pueda
-- pasar a "accepted" sin que el cliente haya registrado previamente
-- la aceptación documental del PDF actualmente publicado.
--
-- Flujo:
--
--   1. Cliente ve el PDF.
--   2. Cliente marca el checkbox.
--   3. Frontend ejecuta:
--
--        record_maintenance_custom_proposal_document_acknowledgement()
--
--   4. Se registra el acknowledgement del PDF concreto.
--   5. Cliente inicia la contratación.
--   6. accept_custom_maintenance_proposal() comprueba server-side
--      que existe ese acknowledgement.
--   7. Solo entonces:
--
--        status = 'accepted'
--
-- ============================================================


-- ============================================================
-- 1. ASEGURAR QUE LA TABLA DE ACKNOWLEDGEMENT EXISTE
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'maintenance_custom_proposal_document_acknowledgements'
    ) THEN

        RAISE EXCEPTION
            '087 failed: maintenance_custom_proposal_document_acknowledgements no existe';

    END IF;

END
$$;


-- ============================================================
-- 2. ASEGURAR COLUMNAS NECESARIAS
-- ============================================================

DO $$
DECLARE
    v_missing TEXT;
BEGIN

    SELECT string_agg(column_name, ', ' ORDER BY column_name)
    INTO v_missing
    FROM (
        VALUES
            ('proposal_id'),
            ('document_id'),
            ('user_id'),
            ('company_id'),
            ('document_path'),
            ('document_sha256'),
            ('acknowledgement_text_version'),
            ('accepted_at')
    ) AS required(column_name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name =
              'maintenance_custom_proposal_document_acknowledgements'
          AND c.column_name = required.column_name
    );

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION
            '087 failed: faltan columnas en maintenance_custom_proposal_document_acknowledgements: %',
            v_missing;
    END IF;

END
$$;


-- ============================================================
-- 3. ÍNDICES PARA LA COMPROBACIÓN DE ACKNOWLEDGEMENT
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_document_ack_proposal_document
ON public.maintenance_custom_proposal_document_acknowledgements (
    proposal_id,
    document_id
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_document_ack_proposal_user
ON public.maintenance_custom_proposal_document_acknowledgements (
    proposal_id,
    user_id
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposal_document_ack_document_hash
ON public.maintenance_custom_proposal_document_acknowledgements (
    document_id,
    document_sha256
);


-- ============================================================
-- 4. REDEFINIR LA ACEPTACIÓN CONTRACTUAL
-- ============================================================
--
-- IMPORTANTE:
--
-- No confiamos en que el frontend haya marcado el checkbox.
--
-- La aceptación contractual solamente puede producirse si existe
-- en BD un acknowledgement válido para:
--
--   - la misma propuesta
--   - el mismo documento actual
--   - el mismo usuario
--   - la misma empresa
--   - el mismo document_path
--   - el mismo SHA-256
--
-- Esto evita aceptar una propuesta utilizando un acknowledgement
-- correspondiente a una versión anterior del PDF.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.accept_custom_maintenance_proposal(
    p_proposal_id UUID
)
RETURNS public.maintenance_custom_proposals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE

    v_proposal public.maintenance_custom_proposals;

    v_document public.maintenance_custom_proposal_documents;

    v_ack_count INTEGER := 0;

BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN
    -- ========================================================

    IF auth.uid() IS NULL THEN

        RAISE EXCEPTION
            'Debes iniciar sesión';

    END IF;


    -- ========================================================
    -- 2. SOLO CLIENTES
    -- ========================================================

    IF public.current_user_is_worker() THEN

        RAISE EXCEPTION
            'Un trabajador no puede aceptar una propuesta como cliente';

    END IF;


    IF NOT public.current_user_is_active() THEN

        RAISE EXCEPTION
            'El usuario no está activo';

    END IF;


    -- ========================================================
    -- 3. OBTENER PROPUESTA
    -- ========================================================

    SELECT *
    INTO v_proposal
    FROM public.maintenance_custom_proposals
    WHERE id = p_proposal_id
      AND user_id = auth.uid()
      AND company_id = public.current_user_company_id()
    FOR UPDATE;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'La propuesta no existe o no tienes acceso a ella';

    END IF;


    -- ========================================================
    -- 4. COMPROBAR ESTADO
    -- ========================================================

    IF v_proposal.status <> 'quoted' THEN

        RAISE EXCEPTION
            'La propuesta todavía no puede aceptarse';

    END IF;


    -- ========================================================
    -- 5. PRECIO OBLIGATORIO
    -- ========================================================

    IF v_proposal.quoted_monthly_price IS NULL
       OR v_proposal.quoted_monthly_price <= 0
    THEN

        RAISE EXCEPTION
            'La propuesta no tiene un precio válido';

    END IF;


    -- ========================================================
    -- 6. VALIDEZ DE LA PROPUESTA
    -- ========================================================

    IF v_proposal.quoted_valid_until IS NOT NULL
       AND v_proposal.quoted_valid_until < CURRENT_DATE
    THEN

        UPDATE public.maintenance_custom_proposals
        SET
            status = 'expired',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_proposal.id;

        RAISE EXCEPTION
            'La propuesta ha caducado';

    END IF;


    -- ========================================================
    -- 7. PDF ACTUAL OBLIGATORIO
    -- ========================================================

    IF v_proposal.current_document_id IS NULL THEN

        RAISE EXCEPTION
            'La propuesta no tiene un PDF publicado que pueda ser aceptado';

    END IF;


    -- ========================================================
    -- 8. OBTENER EL DOCUMENTO ACTUAL
    -- ========================================================

    SELECT *
    INTO v_document
    FROM public.maintenance_custom_proposal_documents
    WHERE id = v_proposal.current_document_id
      AND proposal_id = v_proposal.id
      AND published_at IS NOT NULL;


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'El PDF actual de la propuesta no está publicado o no existe';

    END IF;


    -- ========================================================
    -- 9. PDF DEBE TENER SHA-256
    -- ========================================================

    IF v_document.document_sha256 IS NULL
       OR BTRIM(v_document.document_sha256) = ''
    THEN

        RAISE EXCEPTION
            'El PDF de la propuesta todavía no está validado';

    END IF;


    IF LOWER(BTRIM(v_document.document_sha256))
       !~ '^[0-9a-f]{64}$'
    THEN

        RAISE EXCEPTION
            'El SHA-256 del PDF de la propuesta no es válido';

    END IF;


    -- ========================================================
    -- 10. COMPROBAR ACKNOWLEDGEMENT DEL PDF ACTUAL
    -- ========================================================
    --
    -- El acknowledgement debe corresponder exactamente al PDF
    -- que actualmente está publicado.
    --
    -- No basta con que el usuario haya aceptado un PDF anterior.
    --
    -- ========================================================

    SELECT COUNT(*)
    INTO v_ack_count
    FROM public.maintenance_custom_proposal_document_acknowledgements a
    WHERE a.proposal_id = v_proposal.id
      AND a.document_id = v_document.id
      AND a.user_id = auth.uid()
      AND a.company_id = public.current_user_company_id()
      AND BTRIM(a.document_path) = BTRIM(v_document.document_path)
      AND LOWER(BTRIM(a.document_sha256))
          = LOWER(BTRIM(v_document.document_sha256));


    IF v_ack_count = 0 THEN

        RAISE EXCEPTION
            'No se puede aceptar la propuesta sin haber aceptado previamente el PDF actualmente publicado';

    END IF;


    -- ========================================================
    -- 11. ACEPTAR PROPUESTA
    -- ========================================================

    UPDATE public.maintenance_custom_proposals
    SET
        status = 'accepted',
        accepted_at = CURRENT_TIMESTAMP,
        accepted_by = auth.uid(),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_proposal.id
    RETURNING *
    INTO v_proposal;


    -- ========================================================
    -- 12. COMPROBACIÓN FINAL
    -- ========================================================

    IF v_proposal.id IS NULL THEN

        RAISE EXCEPTION
            'No se ha podido aceptar la propuesta';

    END IF;


    RETURN v_proposal;

END;
$function$;


-- ============================================================
-- 5. PERMISOS DE LA RPC
-- ============================================================

REVOKE ALL
ON FUNCTION public.accept_custom_maintenance_proposal(UUID)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.accept_custom_maintenance_proposal(UUID)
FROM anon;

GRANT EXECUTE
ON FUNCTION public.accept_custom_maintenance_proposal(UUID)
TO authenticated;


ALTER FUNCTION public.accept_custom_maintenance_proposal(UUID)
SET search_path = public, pg_temp;


-- ============================================================
-- 6. PROTECCIÓN ADICIONAL
-- ============================================================
--
-- Nadie debe poder escribir directamente en la tabla de
-- acknowledgements.
--
-- El registro debe pasar siempre por la RPC existente:
--
-- record_maintenance_custom_proposal_document_acknowledgement()
--
-- ============================================================

REVOKE INSERT
ON public.maintenance_custom_proposal_document_acknowledgements
FROM authenticated;

REVOKE UPDATE
ON public.maintenance_custom_proposal_document_acknowledgements
FROM authenticated;

REVOKE DELETE
ON public.maintenance_custom_proposal_document_acknowledgements
FROM authenticated;


-- ============================================================
-- 7. COMENTARIOS
-- ============================================================

COMMENT ON FUNCTION public.accept_custom_maintenance_proposal(UUID)
IS
'Acepta una propuesta Custom de mantenimiento únicamente después de verificar server-side que el cliente ha registrado la aceptación del PDF actualmente publicado, incluyendo document_id, document_path y SHA-256.';


-- ============================================================
-- 8. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- La RPC debe existir.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'accept_custom_maintenance_proposal'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_proposal_id uuid';

    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '087 failed: accept_custom_maintenance_proposal(uuid) missing';

    END IF;


    -- --------------------------------------------------------
    -- Debe ser SECURITY DEFINER.
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'accept_custom_maintenance_proposal'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_proposal_id uuid'
      AND p.prosecdef = TRUE;

    IF v_count <> 1 THEN

        RAISE EXCEPTION
            '087 failed: acceptance RPC must be SECURITY DEFINER';

    END IF;


    -- --------------------------------------------------------
    -- authenticated debe tener EXECUTE.
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.accept_custom_maintenance_proposal(uuid)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '087 failed: authenticated must have EXECUTE';

    END IF;


    -- --------------------------------------------------------
    -- anon NO debe tener EXECUTE.
    -- --------------------------------------------------------

    IF has_function_privilege(
        'anon',
        'public.accept_custom_maintenance_proposal(uuid)',
        'EXECUTE'
    ) THEN

        RAISE EXCEPTION
            '087 failed: anon must not have EXECUTE';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO debe insertar acknowledgements directamente.
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.maintenance_custom_proposal_document_acknowledgements',
        'INSERT'
    ) THEN

        RAISE EXCEPTION
            '087 failed: authenticated must not have direct INSERT permission';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO debe actualizar acknowledgements directamente.
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.maintenance_custom_proposal_document_acknowledgements',
        'UPDATE'
    ) THEN

        RAISE EXCEPTION
            '087 failed: authenticated must not have direct UPDATE permission';

    END IF;


    -- --------------------------------------------------------
    -- authenticated NO debe eliminar acknowledgements directamente.
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.maintenance_custom_proposal_document_acknowledgements',
        'DELETE'
    ) THEN

        RAISE EXCEPTION
            '087 failed: authenticated must not have direct DELETE permission';

    END IF;

END
$$;
GRANT SELECT ON TABLE public.maintenance_custom_proposals TO service_role;


COMMIT;