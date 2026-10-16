BEGIN;

-- =========================================================
-- 1. VALIDACIONES PREVIAS
-- =========================================================

DO $$
BEGIN
    IF to_regclass('public.audit_requests') IS NULL THEN
        RAISE EXCEPTION
            '134 failed: public.audit_requests does not exist';
    END IF;

    IF to_regclass('public.worker_permissions') IS NULL
       OR to_regclass('public.worker_roles') IS NULL
       OR to_regclass('public.worker_role_permissions') IS NULL THEN
        RAISE EXCEPTION
            '134 failed: worker RBAC tables are missing';
    END IF;

    IF to_regprocedure('public.current_user_is_worker()') IS NULL THEN
        RAISE EXCEPTION
            '134 failed: current_user_is_worker() does not exist';
    END IF;

    IF to_regprocedure(
        'public.current_worker_has_permission(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '134 failed: current_worker_has_permission(text) does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'audit_requests'
          AND column_name = 'estado'
    ) OR NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'audit_requests'
          AND column_name = 'notas_internas'
    ) OR NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'audit_requests'
          AND column_name = 'updated_at'
    ) THEN
        RAISE EXCEPTION
            '134 failed: audit_requests required columns are missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'audit_requests'
          AND t.tgname = 'audit_requests_updated_at'
          AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION
            '134 failed: audit_requests_updated_at trigger is missing';
    END IF;
END;
$$;


-- =========================================================
-- 2. NUEVO PERMISO DE GESTIÓN
-- =========================================================

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
VALUES (
    'system.audit.update',
    'system',
    'audit_update',
    'Gestionar solicitudes de auditoría: cambiar estado y notas internas.'
)
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 3. PERMISOS DE DIRECCIÓN Y COMERCIAL
-- =========================================================

DO $$
DECLARE
    v_direction_role_id uuid;
    v_commercial_role_id uuid;
    v_read_permission_id uuid;
    v_update_permission_id uuid;
BEGIN
    SELECT id
    INTO v_direction_role_id
    FROM public.worker_roles
    WHERE code = 'direction';

    SELECT id
    INTO v_commercial_role_id
    FROM public.worker_roles
    WHERE code = 'commercial';

    SELECT id
    INTO v_read_permission_id
    FROM public.worker_permissions
    WHERE code = 'system.audit.read';

    SELECT id
    INTO v_update_permission_id
    FROM public.worker_permissions
    WHERE code = 'system.audit.update';

    IF v_direction_role_id IS NULL THEN
        RAISE EXCEPTION
            '134 failed: direction role does not exist';
    END IF;

    IF v_commercial_role_id IS NULL THEN
        RAISE EXCEPTION
            '134 failed: commercial role does not exist';
    END IF;

    IF v_read_permission_id IS NULL THEN
        RAISE EXCEPTION
            '134 failed: system.audit.read permission does not exist';
    END IF;

    IF v_update_permission_id IS NULL THEN
        RAISE EXCEPTION
            '134 failed: system.audit.update permission does not exist';
    END IF;

    -- Dirección: lectura y gestión.
    INSERT INTO public.worker_role_permissions (
        role_id,
        permission_id
    )
    VALUES
        (v_direction_role_id, v_read_permission_id),
        (v_direction_role_id, v_update_permission_id)
    ON CONFLICT DO NOTHING;

    -- Comercial: lectura y gestión.
    INSERT INTO public.worker_role_permissions (
        role_id,
        permission_id
    )
    VALUES
        (v_commercial_role_id, v_read_permission_id),
        (v_commercial_role_id, v_update_permission_id)
    ON CONFLICT DO NOTHING;
END;
$$;


-- =========================================================
-- 4. ESTADOS PERMITIDOS
-- =========================================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.audit_requests
        WHERE estado IS NULL
           OR estado NOT IN (
               'nuevo',
               'en_revision',
               'en_seguimiento',
               'completado',
               'descartado'
           )
    ) THEN
        RAISE EXCEPTION
            '134 failed: audit_requests contains unsupported states';
    END IF;
END;
$$;

ALTER TABLE public.audit_requests
    DROP CONSTRAINT IF EXISTS audit_requests_estado_check;

ALTER TABLE public.audit_requests
    ADD CONSTRAINT audit_requests_estado_check
    CHECK (
        estado IN (
            'nuevo',
            'en_revision',
            'en_seguimiento',
            'completado',
            'descartado'
        )
    );


-- =========================================================
-- 5. RPC PARA ACTUALIZAR UNA SOLICITUD
-- =========================================================

CREATE OR REPLACE FUNCTION public.update_audit_request(
    p_request_id uuid,
    p_estado text,
    p_notas_internas text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_request public.audit_requests%ROWTYPE;
BEGIN
    -- Autenticación obligatoria.
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required'
            USING ERRCODE = '42501';
    END IF;

    -- Debe ser un trabajador.
    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION 'Worker access required'
            USING ERRCODE = '42501';
    END IF;

    -- El permiso se comprueba en el servidor.
    IF NOT public.current_worker_has_permission(
        'system.audit.update'
    ) THEN
        RAISE EXCEPTION 'Missing permission: system.audit.update'
            USING ERRCODE = '42501';
    END IF;

    -- Identificador obligatorio.
    IF p_request_id IS NULL THEN
        RAISE EXCEPTION 'Request ID is required'
            USING ERRCODE = '22023';
    END IF;

    -- Solo se admiten los cinco estados acordados.
    IF p_estado IS NULL
       OR p_estado NOT IN (
           'nuevo',
           'en_revision',
           'en_seguimiento',
           'completado',
           'descartado'
       ) THEN
        RAISE EXCEPTION 'Invalid audit request status'
            USING ERRCODE = '22023';
    END IF;

    -- Límite de tamaño de las notas internas.
    IF p_notas_internas IS NOT NULL
       AND length(p_notas_internas) > 5000 THEN
        RAISE EXCEPTION
            'Internal notes cannot exceed 5000 characters'
            USING ERRCODE = '22023';
    END IF;

    -- Actualiza exclusivamente estado y notas.
    -- updated_at lo gestiona el trigger existente.
    UPDATE public.audit_requests
    SET
        estado = p_estado,
        notas_internas = NULLIF(
            btrim(p_notas_internas),
            ''
        )
    WHERE id = p_request_id
    RETURNING *
    INTO v_request;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Audit request not found'
            USING ERRCODE = 'P0002';
    END IF;

    RETURN to_jsonb(v_request);
END;
$$;


-- =========================================================
-- 6. PERMISOS DE EJECUCIÓN DE LA RPC
-- =========================================================

REVOKE ALL ON FUNCTION public.update_audit_request(
    uuid,
    text,
    text
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.update_audit_request(
    uuid,
    text,
    text
) FROM anon;

GRANT EXECUTE ON FUNCTION public.update_audit_request(
    uuid,
    text,
    text
) TO authenticated;


-- =========================================================
-- 7. VERIFICACIONES FINALES
-- =========================================================

DO $$
DECLARE
    v_count integer;
BEGIN
    -- Permiso de gestión creado.
    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_permissions
        WHERE code = 'system.audit.update'
    ) THEN
        RAISE EXCEPTION
            '134 failed: update permission missing';
    END IF;

    -- Dirección y comercial tienen ambos permisos.
    SELECT count(*)
    INTO v_count
    FROM public.worker_roles wr
    JOIN public.worker_role_permissions wrp
      ON wrp.role_id = wr.id
    JOIN public.worker_permissions wp
      ON wp.id = wrp.permission_id
    WHERE wr.code IN ('direction', 'commercial')
      AND wp.code IN (
          'system.audit.read',
          'system.audit.update'
      );

    IF v_count <> 4 THEN
        RAISE EXCEPTION
            '134 failed: direction/commercial permissions incomplete';
    END IF;

    -- La RPC debe existir.
    IF to_regprocedure(
        'public.update_audit_request(uuid,text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '134 failed: update_audit_request RPC missing';
    END IF;

    -- Se conserva el trigger original.
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = 'audit_requests'
          AND t.tgname = 'audit_requests_updated_at'
          AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION
            '134 failed: updated_at trigger missing after migration';
    END IF;
END;
$$;

COMMIT;