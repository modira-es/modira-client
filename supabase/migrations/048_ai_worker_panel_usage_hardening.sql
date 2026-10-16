BEGIN;

-- ============================================================
-- MODIRA — 048_ai_worker_panel_usage_hardening.sql
--
-- Objetivo
-- --------
-- Exponer al Employee Area, exclusivamente mediante RPCs
-- SECURITY DEFINER con comprobación de worker activo, toda la
-- información operativa de Modira AI que actualmente vive en:
--
--   ai_quota_config
--   ai_usage_periods
--   ai_usage_reservations
--   ai_anonymous_quota_periods
--   ai_rate_limits
--
-- Además, añade trazabilidad por conversación a las reservas de
-- uso existentes. Esto permite calcular por conversación:
--   - requests
--   - input tokens
--   - output tokens
--   - total tokens
--   - coste real
--   - coste estimado/reservado
--   - modelo (cuando la Edge Function lo informe)
--
-- IMPORTANTE
-- -----------
-- Las tablas de infraestructura siguen SIN ser accesibles desde
-- authenticated. El Employee Area no recibe SELECT directo sobre
-- ellas. Solo puede obtener una proyección controlada mediante las
-- RPCs de lectura siguientes.
--
-- La Edge Function modira-ai debe llamar a
-- link_ai_usage_reservation_context() inmediatamente después de
-- obtener una reservation_id y antes de llamar a OpenAI. La función
-- de finalize_ai_quota() ya existente seguirá escribiendo los tokens
-- y coste reales en esa misma reserva.
-- ============================================================


-- ============================================================
-- 1. TRAZABILIDAD DE RESERVA -> CONVERSACIÓN / MODELO
-- ============================================================

ALTER TABLE public.ai_usage_reservations
ADD COLUMN IF NOT EXISTS conversation_id UUID
REFERENCES public.ai_conversations(id)
ON DELETE SET NULL;

ALTER TABLE public.ai_usage_reservations
ADD COLUMN IF NOT EXISTS model TEXT;

ALTER TABLE public.ai_usage_reservations
DROP CONSTRAINT IF EXISTS ai_usage_reservations_model_check;

ALTER TABLE public.ai_usage_reservations
ADD CONSTRAINT ai_usage_reservations_model_check
CHECK (
    model IS NULL
    OR (
        length(btrim(model)) > 0
        AND length(model) <= 100
    )
);

CREATE INDEX IF NOT EXISTS idx_ai_usage_reservations_conversation
ON public.ai_usage_reservations (
    conversation_id,
    created_at DESC
);

CREATE INDEX IF NOT EXISTS idx_ai_usage_reservations_model
ON public.ai_usage_reservations (
    model,
    created_at DESC
)
WHERE model IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ai_usage_reservations_created_at
ON public.ai_usage_reservations (created_at DESC);


-- ============================================================
-- 2. RPC INTERNA PARA LA EDGE FUNCTION
-- ============================================================
--
-- La Edge Function utiliza service_role. No se concede EXECUTE a
-- authenticated/anon. La RPC no modifica cuotas: únicamente enlaza
-- el reservation_id que ya fue creado por reserve_ai_quota_* con la
-- conversación y el modelo usados en esa petición.
--
-- La operación es idempotente para el mismo reservation_id.
-- ============================================================

CREATE OR REPLACE FUNCTION public.link_ai_usage_reservation_context(
    p_reservation_id UUID,
    p_conversation_id UUID,
    p_model TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_updated INTEGER;
BEGIN
    IF p_reservation_id IS NULL THEN
        RAISE EXCEPTION 'reservation_id is required';
    END IF;

    IF p_conversation_id IS NULL THEN
        RAISE EXCEPTION 'conversation_id is required';
    END IF;

    IF p_model IS NOT NULL
       AND (
            length(btrim(p_model)) = 0
            OR length(p_model) > 100
       )
    THEN
        RAISE EXCEPTION 'Invalid AI model';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.ai_conversations c
        WHERE c.id = p_conversation_id
    ) THEN
        RAISE EXCEPTION 'AI conversation not found';
    END IF;

    UPDATE public.ai_usage_reservations r
    SET
        conversation_id = p_conversation_id,
        model = CASE
            WHEN p_model IS NULL THEN r.model
            ELSE btrim(p_model)
        END
    WHERE r.id = p_reservation_id
      AND r.status = 'reserved';

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated <> 1 THEN
        RAISE EXCEPTION
            'AI reservation not found or is no longer reserved';
    END IF;

    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.link_ai_usage_reservation_context(
    UUID,
    UUID,
    TEXT
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.link_ai_usage_reservation_context(
    UUID,
    UUID,
    TEXT
) TO service_role;

COMMENT ON FUNCTION public.link_ai_usage_reservation_context(UUID, UUID, TEXT)
IS 'Internal service-role RPC used by modira-ai to associate a quota reservation with its conversation and model.';


-- ============================================================
-- 3. RPC — PANEL DE CONTROL IA PARA WORKERS
-- ============================================================
--
-- Devuelve únicamente JSONB de lectura. No concede SELECT sobre las
-- tablas internas. Todas las ramas exigen worker activo.
--
-- Incluye:
--   config
--   authenticated_usage
--   anonymous_usage
--   reservations
--   rate_limits
--   summary
--
-- Se excluyen claves de rate limit completas para no exponer una
-- identidad técnica potencialmente sensible. Se devuelve una forma
-- enmascarada + contadores/fechas operativas.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_ai_worker_panel_data()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_result JSONB;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador activo de MODIRA';
    END IF;

    SELECT jsonb_build_object(
        'config', COALESCE((
            SELECT to_jsonb(c)
            FROM public.ai_quota_config c
            WHERE c.config_key = 'modira-ai'
        ), '{}'::jsonb),

        'authenticated_usage', COALESCE((
            SELECT jsonb_agg(to_jsonb(u) ORDER BY u.period_ends_at DESC)
            FROM public.ai_usage_periods u
        ), '[]'::jsonb),

        'anonymous_usage', COALESCE((
            SELECT jsonb_agg(to_jsonb(a) ORDER BY a.period_ends_at DESC)
            FROM public.ai_anonymous_quota_periods a
        ), '[]'::jsonb),

        'reservations', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id', r.id,
                    'user_id', r.user_id,
                    'company_id', r.company_id,
                    'scope_key', r.scope_key,
                    'conversation_id', r.conversation_id,
                    'model', r.model,
                    'estimated_input_tokens', r.estimated_input_tokens,
                    'estimated_output_tokens', r.estimated_output_tokens,
                    'estimated_total_tokens',
                        r.estimated_input_tokens + r.estimated_output_tokens,
                    'estimated_cost_cents', r.estimated_cost_cents,
                    'actual_input_tokens', r.actual_input_tokens,
                    'actual_output_tokens', r.actual_output_tokens,
                    'actual_total_tokens',
                        COALESCE(r.actual_input_tokens, 0)
                        + COALESCE(r.actual_output_tokens, 0),
                    'actual_cost_cents', r.actual_cost_cents,
                    'status', r.status,
                    'expires_at', r.expires_at,
                    'created_at', r.created_at,
                    'finalized_at', r.finalized_at
                )
                ORDER BY r.created_at DESC
            )
            FROM public.ai_usage_reservations r
        ), '[]'::jsonb),

        'rate_limits', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'key_masked',
                        CASE
                            WHEN length(r.rate_key) <= 10 THEN '••••••••'
                            ELSE left(r.rate_key, 4)
                                 || '••••••••'
                                 || right(r.rate_key, 4)
                        END,
                    'window_started_at', r.window_started_at,
                    'request_count', r.request_count,
                    'created_at', r.created_at,
                    'updated_at', r.updated_at
                )
                ORDER BY r.updated_at DESC
            )
            FROM public.ai_rate_limits r
        ), '[]'::jsonb),

        'summary', jsonb_build_object(
            'conversation_linked_reservations', (
                SELECT count(*)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id IS NOT NULL
            ),
            'unlinked_reservations', (
                SELECT count(*)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id IS NULL
            ),
            'reservation_count', (
                SELECT count(*)
                FROM public.ai_usage_reservations
            ),
            'active_reservations', (
                SELECT count(*)
                FROM public.ai_usage_reservations r
                WHERE r.status = 'reserved'
            ),
            'consumed_reservations', (
                SELECT count(*)
                FROM public.ai_usage_reservations r
                WHERE r.status = 'consumed'
            ),
            'released_reservations', (
                SELECT count(*)
                FROM public.ai_usage_reservations r
                WHERE r.status = 'released'
            ),
            'expired_reservations', (
                SELECT count(*)
                FROM public.ai_usage_reservations r
                WHERE r.status = 'expired'
            ),
            'total_actual_input_tokens', (
                SELECT COALESCE(sum(r.actual_input_tokens), 0)
                FROM public.ai_usage_reservations r
                WHERE r.status = 'consumed'
            ),
            'total_actual_output_tokens', (
                SELECT COALESCE(sum(r.actual_output_tokens), 0)
                FROM public.ai_usage_reservations r
                WHERE r.status = 'consumed'
            ),
            'total_actual_cost_cents', (
                SELECT COALESCE(sum(r.actual_cost_cents), 0)
                FROM public.ai_usage_reservations r
                WHERE r.status = 'consumed'
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_ai_worker_panel_data()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_ai_worker_panel_data()
TO authenticated;

COMMENT ON FUNCTION public.get_ai_worker_panel_data()
IS 'Read-only AI operations projection for active Modira workers. Sensitive AI infrastructure tables remain inaccessible directly from frontend.';


-- ============================================================
-- 4. RPC — USO DE UNA CONVERSACIÓN PARA WORKERS
-- ============================================================
--
-- La proyección se basa en ai_usage_reservations enlazadas a
-- conversation_id. Los valores reales proceden de finalize_ai_quota().
-- Las reservas legacy que no tengan conversation_id no se inventan ni
-- se atribuyen a ninguna conversación.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_ai_worker_conversation_usage(
    p_conversation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_result JSONB;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador activo de MODIRA';
    END IF;

    IF p_conversation_id IS NULL THEN
        RAISE EXCEPTION 'conversation_id is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.ai_conversations c
        WHERE c.id = p_conversation_id
    ) THEN
        RAISE EXCEPTION 'AI conversation not found';
    END IF;

    SELECT jsonb_build_object(
        'summary', jsonb_build_object(
            'request_count', (
                SELECT count(*)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'consumed'
            ),
            'input_tokens', (
                SELECT COALESCE(sum(r.actual_input_tokens), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'consumed'
            ),
            'output_tokens', (
                SELECT COALESCE(sum(r.actual_output_tokens), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'consumed'
            ),
            'total_tokens', (
                SELECT COALESCE(sum(
                    COALESCE(r.actual_input_tokens, 0)
                    + COALESCE(r.actual_output_tokens, 0)
                ), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'consumed'
            ),
            'actual_cost_cents', (
                SELECT COALESCE(sum(r.actual_cost_cents), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'consumed'
            ),
            'estimated_input_tokens', (
                SELECT COALESCE(sum(r.estimated_input_tokens), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
            ),
            'estimated_output_tokens', (
                SELECT COALESCE(sum(r.estimated_output_tokens), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
            ),
            'estimated_total_tokens', (
                SELECT COALESCE(sum(
                    r.estimated_input_tokens
                    + r.estimated_output_tokens
                ), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
            ),
            'estimated_cost_cents', (
                SELECT COALESCE(sum(r.estimated_cost_cents), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
            ),
            'reserved_input_tokens', (
                SELECT COALESCE(sum(r.estimated_input_tokens), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'reserved'
            ),
            'reserved_output_tokens', (
                SELECT COALESCE(sum(r.estimated_output_tokens), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'reserved'
            ),
            'reserved_total_tokens', (
                SELECT COALESCE(sum(
                    r.estimated_input_tokens
                    + r.estimated_output_tokens
                ), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'reserved'
            ),
            'reserved_cost_cents', (
                SELECT COALESCE(sum(r.estimated_cost_cents), 0)
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
                  AND r.status = 'reserved'
            ),
            'has_usage_data', (
                SELECT count(*) > 0
                FROM public.ai_usage_reservations r
                WHERE r.conversation_id = p_conversation_id
            )
        ),
        'events', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id', r.id,
                    'user_id', r.user_id,
                    'company_id', r.company_id,
                    'scope_key', r.scope_key,
                    'conversation_id', r.conversation_id,
                    'model', r.model,
                    'estimated_input_tokens', r.estimated_input_tokens,
                    'estimated_output_tokens', r.estimated_output_tokens,
                    'estimated_total_tokens',
                        r.estimated_input_tokens + r.estimated_output_tokens,
                    'estimated_cost_cents', r.estimated_cost_cents,
                    'actual_input_tokens', r.actual_input_tokens,
                    'actual_output_tokens', r.actual_output_tokens,
                    'actual_total_tokens',
                        COALESCE(r.actual_input_tokens, 0)
                        + COALESCE(r.actual_output_tokens, 0),
                    'actual_cost_cents', r.actual_cost_cents,
                    'status', r.status,
                    'expires_at', r.expires_at,
                    'created_at', r.created_at,
                    'finalized_at', r.finalized_at
                )
                ORDER BY r.created_at ASC
            )
            FROM public.ai_usage_reservations r
            WHERE r.conversation_id = p_conversation_id
        ), '[]'::jsonb)
    )
    INTO v_result;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_ai_worker_conversation_usage(UUID)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_ai_worker_conversation_usage(UUID)
TO authenticated;

COMMENT ON FUNCTION public.get_ai_worker_conversation_usage(UUID)
IS 'Read-only AI usage projection for one conversation, available only to active Modira workers.';


-- ============================================================
-- 5. VALIDACIONES FINALES
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'ai_usage_reservations'
          AND column_name = 'conversation_id'
    ) THEN
        RAISE EXCEPTION '048 failed: conversation_id is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'ai_usage_reservations'
          AND column_name = 'model'
    ) THEN
        RAISE EXCEPTION '048 failed: model is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_ai_worker_panel_data'
    ) THEN
        RAISE EXCEPTION '048 failed: get_ai_worker_panel_data is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_ai_worker_conversation_usage'
    ) THEN
        RAISE EXCEPTION '048 failed: get_ai_worker_conversation_usage is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'link_ai_usage_reservation_context'
    ) THEN
        RAISE EXCEPTION '048 failed: link_ai_usage_reservation_context is missing';
    END IF;
END $$;

COMMIT;
