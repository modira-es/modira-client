BEGIN;

-- ============================================================
-- MODIRA — 071_harden_worker_rpcs_rbac.sql
-- ============================================================
--
-- OBJETIVO
-- --------
-- Completar el hardening RBAC de las RPC SECURITY DEFINER
-- accesibles por workers.
--
-- Las funciones corregidas son:
--
--   1. get_ai_worker_conversation_usage()
--        -> ai.read
--
--   2. get_ai_worker_panel_data()
--        -> ai.read
--
--   3. get_worker_projects()
--        -> projects.read
--
--   4. get_worker_project_change_requests()
--        -> projects.read
--
--   5. approve_project_ownership_transfer()
--        -> projects.update
--
--   6. configure_project_change_requests()
--        -> projects.update
--
--   7. attach_maintenance_invoice_document()
--        -> maintenance.update
--
-- IMPORTANTE
-- ----------
-- Esta migración NO:
--
-- - modifica migraciones anteriores;
-- - modifica current_user_is_worker();
-- - modifica funciones __legacy_113;
-- - modifica triggers;
-- - modifica helpers internos;
-- - modifica funciones exclusivas de clientes;
-- - modifica Storage policies;
-- - modifica get_company_effective_iva();
-- - modifica create_automation_run(), que ya fue endurecida
--   mediante la migración anterior.
--
-- ============================================================


-- ============================================================
-- 0. VALIDACIONES PREVIAS
-- ============================================================

DO $$
DECLARE
    v_missing TEXT := '';
BEGIN

    -- --------------------------------------------------------
    -- Funciones necesarias
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.get_ai_worker_conversation_usage(uuid)'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- get_ai_worker_conversation_usage(uuid)';
    END IF;


    IF to_regprocedure(
        'public.get_ai_worker_panel_data()'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- get_ai_worker_panel_data()';
    END IF;


    IF to_regprocedure(
        'public.get_worker_projects()'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- get_worker_projects()';
    END IF;


    IF to_regprocedure(
        'public.get_worker_project_change_requests()'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- get_worker_project_change_requests()';
    END IF;


    IF to_regprocedure(
        'public.approve_project_ownership_transfer(uuid)'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- approve_project_ownership_transfer(uuid)';
    END IF;


    IF to_regprocedure(
        'public.configure_project_change_requests(uuid,boolean,timestamptz)'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- configure_project_change_requests(uuid,boolean,timestamptz)';
    END IF;


    IF to_regprocedure(
        'public.attach_maintenance_invoice_document(uuid,text)'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- attach_maintenance_invoice_document(uuid,text)';
    END IF;


    -- --------------------------------------------------------
    -- Helper RBAC
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- current_worker_has_permission(text)';
    END IF;


    IF to_regprocedure(
        'public.current_user_is_worker()'
    ) IS NULL THEN
        v_missing := v_missing || E'\n- current_user_is_worker()';
    END IF;


    -- --------------------------------------------------------
    -- Permisos necesarios
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'ai.read'
    ) THEN
        v_missing := v_missing || E'\n- worker_permissions: ai.read';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'projects.read'
    ) THEN
        v_missing := v_missing || E'\n- worker_permissions: projects.read';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'projects.update'
    ) THEN
        v_missing := v_missing || E'\n- worker_permissions: projects.update';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'maintenance.update'
    ) THEN
        v_missing := v_missing || E'\n- worker_permissions: maintenance.update';
    END IF;


    IF v_missing <> '' THEN
        RAISE EXCEPTION
            '071 stopped. Faltan objetos o permisos:%',
            v_missing;
    END IF;

END;
$$;


-- ============================================================
-- 1. get_ai_worker_conversation_usage()
-- ============================================================
--
-- Antes:
--   cualquier worker activo podía consultar cualquier
--   conversación AI.
--
-- Ahora:
--   worker activo + ai.read
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_ai_worker_conversation_usage(
    p_conversation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
    v_result JSONB;
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo de MODIRA';
    END IF;


    IF NOT public.current_worker_has_permission(
        'ai.read'
    ) THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere el permiso ai.read';
    END IF;


    IF p_conversation_id IS NULL THEN
        RAISE EXCEPTION
            'conversation_id is required';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM public.ai_conversations c
        WHERE c.id = p_conversation_id
    ) THEN
        RAISE EXCEPTION
            'AI conversation not found';
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
$function$;


-- ============================================================
-- 2. get_ai_worker_panel_data()
-- ============================================================
--
-- Acceso:
--   worker activo + ai.read
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_ai_worker_panel_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
    v_result JSONB;
BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo de MODIRA';
    END IF;


    IF NOT public.current_worker_has_permission(
        'ai.read'
    ) THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere el permiso ai.read';
    END IF;


    SELECT jsonb_build_object(

        'config', COALESCE((
            SELECT to_jsonb(c)
            FROM public.ai_quota_config c
            WHERE c.config_key = 'modira-ai'
        ), '{}'::jsonb),

        'authenticated_usage', COALESCE((
            SELECT jsonb_agg(
                to_jsonb(u)
                ORDER BY u.period_ends_at DESC
            )
            FROM public.ai_usage_periods u
        ), '[]'::jsonb),

        'anonymous_usage', COALESCE((
            SELECT jsonb_agg(
                to_jsonb(a)
                ORDER BY a.period_ends_at DESC
            )
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
                            WHEN length(r.rate_key) <= 10
                                THEN '••••••••'
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
$function$;


-- ============================================================
-- 3. get_worker_projects()
-- ============================================================
--
-- Acceso:
--   worker activo + projects.read
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_worker_projects()
RETURNS TABLE(
    id uuid,
    nombre text,
    descripcion text,
    estado text,
    fecha_inicio timestamp with time zone,
    fecha_fin timestamp with time zone,
    company_id uuid,
    user_id uuid,
    created_at timestamp with time zone,
    cliente_nombre text,
    cliente_email text,
    empresa_nombre text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
BEGIN

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere rol de trabajador activo';
    END IF;


    IF NOT public.current_worker_has_permission(
        'projects.read'
    ) THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere el permiso projects.read';
    END IF;


    RETURN QUERY

    SELECT
        p.id,
        p.nombre,
        p.descripcion,
        p.estado,
        p.fecha_inicio,
        p.fecha_fin,
        p.company_id,
        p.user_id,
        p.created_at,
        COALESCE(
            pr.nombre,
            'Sin nombre'
        ) AS cliente_nombre,
        u.email::TEXT AS cliente_email,
        c.company_name AS empresa_nombre

    FROM public.projects p

    LEFT JOIN public.profiles pr
        ON p.user_id = pr.id

    LEFT JOIN public.companies c
        ON p.company_id = c.id

    LEFT JOIN auth.users u
        ON p.user_id = u.id

    ORDER BY p.created_at DESC;

END;
$function$;


-- ============================================================
-- 4. get_worker_project_change_requests()
-- ============================================================
--
-- Acceso:
--   worker activo + projects.read
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_worker_project_change_requests()
RETURNS TABLE(
    id uuid,
    project_id uuid,
    project_nombre text,
    user_id uuid,
    cliente_nombre text,
    cliente_email text,
    company_id uuid,
    client_id uuid,
    description text,
    status text,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    review_notes text,
    accepted_at timestamp with time zone,
    completed_by uuid,
    completed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    change_requests_enabled boolean,
    change_requests_deadline timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
BEGIN

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    IF NOT public.current_worker_has_permission(
        'projects.read'
    ) THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere el permiso projects.read';
    END IF;


    RETURN QUERY

    SELECT
        r.id,
        r.project_id,
        p.nombre AS project_nombre,
        r.user_id,
        COALESCE(
            pr.nombre,
            'Sin nombre'
        ) AS cliente_nombre,
        u.email::TEXT AS cliente_email,
        r.company_id,
        r.client_id,
        r.description,
        r.status,
        r.reviewed_by,
        r.reviewed_at,
        r.review_notes,
        r.accepted_at,
        r.completed_by,
        r.completed_at,
        r.created_at,
        r.updated_at,
        p.change_requests_enabled,
        p.change_requests_deadline

    FROM public.project_change_requests r

    INNER JOIN public.projects p
        ON p.id = r.project_id

    LEFT JOIN public.profiles pr
        ON pr.id = r.user_id

    LEFT JOIN auth.users u
        ON u.id = r.user_id

    ORDER BY
        CASE
            WHEN r.status = 'pending'
                THEN 1
            WHEN r.status = 'in_review'
                THEN 2
            WHEN r.status = 'accepted'
                THEN 3
            WHEN r.status = 'completed'
                THEN 4
            WHEN r.status = 'rejected'
                THEN 5
            ELSE 6
        END,
        r.created_at DESC;

END;
$function$;


-- ============================================================
-- 5. approve_project_ownership_transfer()
-- ============================================================
--
-- Acceso:
--   worker activo + projects.update
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.approve_project_ownership_transfer(
    p_transfer_id uuid
)
RETURNS public.project_ownership_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_transfer public.project_ownership_transfers;

BEGIN

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Solo un trabajador autorizado puede aprobar la transferencia';
    END IF;


    IF NOT public.current_worker_has_permission(
        'projects.update'
    ) THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere el permiso projects.update';
    END IF;


    SELECT *
    INTO v_transfer
    FROM public.project_ownership_transfers
    WHERE id = p_transfer_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Transferencia no encontrada';
    END IF;


    IF v_transfer.status <> 'pending_approval' THEN
        RAISE EXCEPTION
            'La transferencia no está pendiente de aprobación';
    END IF;


    UPDATE public.project_ownership_transfers
    SET
        status = 'pending_acceptance',
        approved_by = auth.uid(),
        approved_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_transfer_id
    RETURNING *
    INTO v_transfer;


    RETURN v_transfer;

END;
$function$;


-- ============================================================
-- 6. configure_project_change_requests()
-- ============================================================
--
-- Acceso:
--   worker activo + projects.update
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.configure_project_change_requests(
    p_project_id uuid,
    p_enabled boolean,
    p_deadline timestamp with time zone DEFAULT NULL
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_project public.projects;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    IF NOT public.current_worker_has_permission(
        'projects.update'
    ) THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere el permiso projects.update';
    END IF;


    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto es obligatorio';
    END IF;


    IF p_enabled IS NULL THEN
        RAISE EXCEPTION
            'La configuración de solicitudes es obligatoria';
    END IF;


    IF p_enabled = TRUE
       AND p_deadline IS NULL
    THEN
        RAISE EXCEPTION
            'Debe establecerse una fecha límite cuando las solicitudes están habilitadas';
    END IF;


    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = p_project_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Proyecto no encontrado';
    END IF;


    UPDATE public.projects
    SET
        change_requests_enabled = p_enabled,
        change_requests_deadline =
            CASE
                WHEN p_enabled = FALSE
                    THEN p_deadline
                ELSE
                    p_deadline
            END,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_project_id
    RETURNING *
    INTO v_project;


    INSERT INTO public.activity_log (
        user_id,
        company_id,
        action,
        resource_type,
        resource_id,
        description,
        metadata
    )
    VALUES (
        auth.uid(),
        v_project.company_id,
        'project.change_requests_configured',
        'project',
        v_project.id,
        CASE
            WHEN p_enabled = TRUE
                THEN 'Periodo de solicitudes de cambio habilitado'
            ELSE
                'Solicitudes de cambio deshabilitadas'
        END,
        jsonb_build_object(
            'enabled', p_enabled,
            'deadline', p_deadline
        )
    );


    RETURN v_project;

END;
$function$;


-- ============================================================
-- 7. attach_maintenance_invoice_document()
-- ============================================================
--
-- Acceso:
--   worker activo + maintenance.update
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.attach_maintenance_invoice_document(
    p_invoice_id uuid,
    p_document_path text
)
RETURNS public.maintenance_invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE
    v_invoice public.maintenance_invoices;
    v_object storage.objects;
    v_path TEXT;

BEGIN

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    IF NOT public.current_worker_has_permission(
        'maintenance.update'
    ) THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere el permiso maintenance.update';
    END IF;


    v_path := BTRIM(
        COALESCE(
            p_document_path,
            ''
        )
    );


    IF v_path = '' THEN
        RAISE EXCEPTION
            'El documento es obligatorio';
    END IF;


    IF v_path !~ (
        '^'
        || p_invoice_id::TEXT
        || '/.+\.pdf$'
    ) THEN
        RAISE EXCEPTION
            'La ruta del documento no corresponde a la factura indicada';
    END IF;


    SELECT *
    INTO v_invoice
    FROM public.maintenance_invoices
    WHERE id = p_invoice_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'La factura de mantenimiento no existe';
    END IF;


    SELECT *
    INTO v_object
    FROM storage.objects
    WHERE bucket_id = 'maintenance-invoices'
      AND name = v_path;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El PDF no existe en el bucket maintenance-invoices';
    END IF;


    IF LOWER(
        COALESCE(
            v_object.metadata->>'mimetype',
            ''
        )
    ) <> 'application/pdf' THEN
        RAISE EXCEPTION
            'El documento de factura debe ser un PDF';
    END IF;


    IF v_invoice.document_path IS NOT NULL
       AND v_invoice.document_path <> v_path
    THEN
        RAISE EXCEPTION
            'La factura ya tiene un documento asociado; no se permite sustituirlo desde esta operación';
    END IF;


    UPDATE public.maintenance_invoices
    SET
        document_path = v_path,
        document_mime_type = 'application/pdf',
        document_file_size =
            COALESCE(
                (v_object.metadata->>'size')::BIGINT,
                NULL
            ),
        document_uploaded_at = CURRENT_TIMESTAMP,
        document_uploaded_by = auth.uid(),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_invoice_id
    RETURNING *
    INTO v_invoice;


    RETURN v_invoice;

END;
$function$;


-- ============================================================
-- 8. VERIFICACIÓN AUTOMÁTICA DEL HARDENING
-- ============================================================

DO $$
DECLARE
    v_definition TEXT;
BEGIN

    -- --------------------------------------------------------
    -- 1. AI conversation usage
    -- --------------------------------------------------------

    SELECT pg_get_functiondef(
        'public.get_ai_worker_conversation_usage(uuid)'::regprocedure
    )
    INTO v_definition;

    IF position(
        'current_worker_has_permission' IN v_definition
    ) = 0
    OR position(
        'ai.read' IN v_definition
    ) = 0
    THEN
        RAISE EXCEPTION
            '071 failed: get_ai_worker_conversation_usage() no contiene ai.read';
    END IF;


    -- --------------------------------------------------------
    -- 2. AI panel
    -- --------------------------------------------------------

    SELECT pg_get_functiondef(
        'public.get_ai_worker_panel_data()'::regprocedure
    )
    INTO v_definition;

    IF position(
        'current_worker_has_permission' IN v_definition
    ) = 0
    OR position(
        'ai.read' IN v_definition
    ) = 0
    THEN
        RAISE EXCEPTION
            '071 failed: get_ai_worker_panel_data() no contiene ai.read';
    END IF;


    -- --------------------------------------------------------
    -- 3. Worker projects
    -- --------------------------------------------------------

    SELECT pg_get_functiondef(
        'public.get_worker_projects()'::regprocedure
    )
    INTO v_definition;

    IF position(
        'current_worker_has_permission' IN v_definition
    ) = 0
    OR position(
        'projects.read' IN v_definition
    ) = 0
    THEN
        RAISE EXCEPTION
            '071 failed: get_worker_projects() no contiene projects.read';
    END IF;


    -- --------------------------------------------------------
    -- 4. Project change requests
    -- --------------------------------------------------------

    SELECT pg_get_functiondef(
        'public.get_worker_project_change_requests()'::regprocedure
    )
    INTO v_definition;

    IF position(
        'current_worker_has_permission' IN v_definition
    ) = 0
    OR position(
        'projects.read' IN v_definition
    ) = 0
    THEN
        RAISE EXCEPTION
            '071 failed: get_worker_project_change_requests() no contiene projects.read';
    END IF;


    -- --------------------------------------------------------
    -- 5. Ownership transfer
    -- --------------------------------------------------------

    SELECT pg_get_functiondef(
        'public.approve_project_ownership_transfer(uuid)'::regprocedure
    )
    INTO v_definition;

    IF position(
        'current_worker_has_permission' IN v_definition
    ) = 0
    OR position(
        'projects.update' IN v_definition
    ) = 0
    THEN
        RAISE EXCEPTION
            '071 failed: approve_project_ownership_transfer() no contiene projects.update';
    END IF;


    -- --------------------------------------------------------
    -- 6. Project change configuration
    -- --------------------------------------------------------

    SELECT pg_get_functiondef(
        'public.configure_project_change_requests(uuid,boolean,timestamptz)'::regprocedure
    )
    INTO v_definition;

    IF position(
        'current_worker_has_permission' IN v_definition
    ) = 0
    OR position(
        'projects.update' IN v_definition
    ) = 0
    THEN
        RAISE EXCEPTION
            '071 failed: configure_project_change_requests() no contiene projects.update';
    END IF;


    -- --------------------------------------------------------
    -- 7. Maintenance invoice document
    -- --------------------------------------------------------

    SELECT pg_get_functiondef(
        'public.attach_maintenance_invoice_document(uuid,text)'::regprocedure
    )
    INTO v_definition;

    IF position(
        'current_worker_has_permission' IN v_definition
    ) = 0
    OR position(
        'maintenance.update' IN v_definition
    ) = 0
    THEN
        RAISE EXCEPTION
            '071 failed: attach_maintenance_invoice_document() no contiene maintenance.update';
    END IF;


    -- --------------------------------------------------------
    -- Todo correcto
    -- --------------------------------------------------------

    RAISE NOTICE
        '071 OK: las 7 RPC worker han quedado protegidas mediante permisos granulares';

END;
$$;


COMMIT;