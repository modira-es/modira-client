-- ============================================================
-- 079_project_ownership_transfers.sql
--
-- Propietario actual + transferencia formal + historial.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. TABLA DE HISTORIAL DE PROPIETARIOS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.project_ownership_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    project_id UUID NOT NULL
        REFERENCES public.projects(id)
        ON DELETE CASCADE,

    owner_user_id UUID NOT NULL
        REFERENCES public.profiles(id),

    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMPTZ,

    reason TEXT NOT NULL DEFAULT 'creation',

    transfer_id UUID,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT project_ownership_history_dates_check
        CHECK (
            ended_at IS NULL
            OR ended_at >= started_at
        )
);

CREATE INDEX IF NOT EXISTS
    idx_project_ownership_history_project
ON public.project_ownership_history(project_id);

CREATE INDEX IF NOT EXISTS
    idx_project_ownership_history_owner
ON public.project_ownership_history(owner_user_id);

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_project_ownership_history_one_current
ON public.project_ownership_history(project_id)
WHERE ended_at IS NULL;


-- ============================================================
-- 2. TRANSFERENCIAS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.project_ownership_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    project_id UUID NOT NULL
        REFERENCES public.projects(id)
        ON DELETE CASCADE,

    company_id UUID NOT NULL
        REFERENCES public.companies(id),

    previous_owner_id UUID NOT NULL
        REFERENCES public.profiles(id),

    requested_new_owner_id UUID NOT NULL
        REFERENCES public.profiles(id),

    requested_by UUID NOT NULL
        REFERENCES public.profiles(id),

    requested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    approved_by UUID
        REFERENCES public.profiles(id),

    approved_at TIMESTAMPTZ,

    accepted_by UUID
        REFERENCES public.profiles(id),

    accepted_at TIMESTAMPTZ,

    status TEXT NOT NULL DEFAULT 'pending_approval',

    reason TEXT,

    acknowledgement_text_version TEXT,

    terms_snapshot JSONB,

    terms_hash TEXT,

    project_snapshot JSONB,

    project_snapshot_hash TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT project_ownership_transfers_status_check
        CHECK (
            status IN (
                'pending_approval',
                'pending_acceptance',
                'accepted',
                'rejected',
                'cancelled'
            )
        ),

    CONSTRAINT project_ownership_transfers_hash_check
        CHECK (
            terms_hash IS NULL
            OR terms_hash ~ '^[0-9a-f]{64}$'
        ),

    CONSTRAINT project_ownership_transfers_project_hash_check
        CHECK (
            project_snapshot_hash IS NULL
            OR project_snapshot_hash ~ '^[0-9a-f]{64}$'
        )
);

CREATE INDEX IF NOT EXISTS
    idx_project_ownership_transfers_project
ON public.project_ownership_transfers(project_id);

CREATE INDEX IF NOT EXISTS
    idx_project_ownership_transfers_company
ON public.project_ownership_transfers(company_id);

CREATE INDEX IF NOT EXISTS
    idx_project_ownership_transfers_new_owner
ON public.project_ownership_transfers(requested_new_owner_id);

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_project_ownership_transfers_pending
ON public.project_ownership_transfers(project_id)
WHERE status IN (
    'pending_approval',
    'pending_acceptance'
);


-- ============================================================
-- 3. RLS
-- ============================================================

ALTER TABLE public.project_ownership_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_ownership_transfers ENABLE ROW LEVEL SECURITY;


-- Toda la empresa puede consultar el historial.

DROP POLICY IF EXISTS project_ownership_history_company_select
ON public.project_ownership_history;

CREATE POLICY project_ownership_history_company_select
ON public.project_ownership_history
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.projects p
        WHERE p.id = project_ownership_history.project_id
          AND p.company_id = public.current_user_company_id()
    )
);


-- Toda la empresa puede consultar transferencias.

DROP POLICY IF EXISTS project_ownership_transfers_company_select
ON public.project_ownership_transfers;

CREATE POLICY project_ownership_transfers_company_select
ON public.project_ownership_transfers
FOR SELECT
TO authenticated
USING (
    company_id = public.current_user_company_id()
);


-- No escrituras directas.

REVOKE INSERT, UPDATE, DELETE
ON public.project_ownership_history
FROM anon, authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.project_ownership_transfers
FROM anon, authenticated;


-- ============================================================
-- 4. INICIALIZAR HISTORIAL CON LOS PROPIETARIOS ACTUALES
-- ============================================================

INSERT INTO public.project_ownership_history (
    project_id,
    owner_user_id,
    started_at,
    reason
)
SELECT
    p.id,
    p.user_id,
    COALESCE(p.created_at, CURRENT_TIMESTAMP),
    'creation'
FROM public.projects p
WHERE p.user_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM public.project_ownership_history h
      WHERE h.project_id = p.id
  );


-- ============================================================
-- 5. SOLICITAR TRANSFERENCIA
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_project_ownership_transfer(
    p_project_id UUID,
    p_new_owner_id UUID,
    p_reason TEXT DEFAULT NULL
)
RETURNS public.project_ownership_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$

DECLARE
    v_project public.projects;
    v_new_owner public.profiles;
    v_transfer public.project_ownership_transfers;
    v_snapshot JSONB;
    v_hash TEXT;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION 'La cuenta no está activa';
    END IF;


    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = p_project_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Proyecto no encontrado';
    END IF;


    -- Solo el propietario actual puede solicitar la transferencia.

    IF v_project.user_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION
            'Solo el propietario actual puede solicitar la transferencia';
    END IF;


    IF p_new_owner_id IS NULL THEN
        RAISE EXCEPTION 'El nuevo propietario es obligatorio';
    END IF;


    IF p_new_owner_id = auth.uid() THEN
        RAISE EXCEPTION
            'El nuevo propietario debe ser diferente al propietario actual';
    END IF;


    SELECT *
    INTO v_new_owner
    FROM public.profiles
    WHERE id = p_new_owner_id
      AND status = 'active'
      AND company_id = v_project.company_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El nuevo propietario debe ser un usuario activo de la misma empresa';
    END IF;


    IF EXISTS (
        SELECT 1
        FROM public.project_ownership_transfers t
        WHERE t.project_id = v_project.id
          AND t.status IN (
              'pending_approval',
              'pending_acceptance'
          )
    ) THEN
        RAISE EXCEPTION
            'Ya existe una transferencia pendiente para este proyecto';
    END IF;


    v_snapshot := jsonb_build_object(
        'project_id', v_project.id,
        'company_id', v_project.company_id,
        'previous_owner_id', v_project.user_id,
        'new_owner_id', p_new_owner_id,
        'project_state', v_project.state,
        'project_client_id', v_project.client_id,
        'created_at', v_project.created_at,
        'captured_at', CURRENT_TIMESTAMP
    );

    v_hash := encode(
        extensions.digest(
            v_snapshot::text,
            'sha256'
        ),
        'hex'
    );


    INSERT INTO public.project_ownership_transfers (
        project_id,
        company_id,
        previous_owner_id,
        requested_new_owner_id,
        requested_by,
        reason,
        status,
        project_snapshot,
        project_snapshot_hash,
        acknowledgement_text_version
    )
    VALUES (
        v_project.id,
        v_project.company_id,
        v_project.user_id,
        p_new_owner_id,
        auth.uid(),
        p_reason,
        'pending_approval',
        v_snapshot,
        v_hash,
        'project_ownership_transfer_v1'
    )
    RETURNING *
    INTO v_transfer;


    RETURN v_transfer;

END;
$function$;


-- ============================================================
-- 6. APROBAR TRANSFERENCIA
-- ============================================================

CREATE OR REPLACE FUNCTION public.approve_project_ownership_transfer(
    p_transfer_id UUID
)
RETURNS public.project_ownership_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_transfer public.project_ownership_transfers;

BEGIN

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Solo un trabajador autorizado puede aprobar la transferencia';
    END IF;


    SELECT *
    INTO v_transfer
    FROM public.project_ownership_transfers
    WHERE id = p_transfer_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transferencia no encontrada';
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
-- 7. ACEPTAR TRANSFERENCIA
-- ============================================================

CREATE OR REPLACE FUNCTION public.accept_project_ownership_transfer(
    p_transfer_id UUID
)
RETURNS public.project_ownership_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$

DECLARE
    v_transfer public.project_ownership_transfers;
    v_project public.projects;
    v_snapshot JSONB;
    v_hash TEXT;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION 'La cuenta no está activa';
    END IF;


    SELECT *
    INTO v_transfer
    FROM public.project_ownership_transfers
    WHERE id = p_transfer_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transferencia no encontrada';
    END IF;


    IF v_transfer.status <> 'pending_acceptance' THEN
        RAISE EXCEPTION
            'La transferencia no está pendiente de aceptación';
    END IF;


    IF v_transfer.requested_new_owner_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION
            'Solo el nuevo propietario puede aceptar esta transferencia';
    END IF;


    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = v_transfer.project_id
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION 'Proyecto no encontrado';
    END IF;


    IF v_project.user_id IS DISTINCT FROM v_transfer.previous_owner_id THEN
        RAISE EXCEPTION
            'El propietario actual del proyecto ya no coincide con la transferencia';
    END IF;


    v_snapshot := jsonb_build_object(
        'transfer_id', v_transfer.id,
        'project_id', v_project.id,
        'company_id', v_project.company_id,
        'previous_owner_id', v_transfer.previous_owner_id,
        'new_owner_id', auth.uid(),
        'project_state', v_project.state,
        'project_client_id', v_project.client_id,
        'transfer_project_snapshot',
            v_transfer.project_snapshot,
        'accepted_at', CURRENT_TIMESTAMP
    );

    v_hash := encode(
        extensions.digest(
            v_snapshot::text,
            'sha256'
        ),
        'hex'
    );


    -- Cerrar propietario anterior.

    UPDATE public.project_ownership_history
    SET ended_at = CURRENT_TIMESTAMP
    WHERE project_id = v_project.id
      AND ended_at IS NULL;


    -- Crear nuevo periodo de propiedad.

    INSERT INTO public.project_ownership_history (
        project_id,
        owner_user_id,
        started_at,
        reason
    )
    VALUES (
        v_project.id,
        auth.uid(),
        CURRENT_TIMESTAMP,
        'ownership_transfer'
    );


    -- El cambio real de propietario ocurre SOLO aquí.

    UPDATE public.projects
    SET
        user_id = auth.uid(),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_project.id;


    UPDATE public.project_ownership_transfers
    SET
        status = 'accepted',
        accepted_by = auth.uid(),
        accepted_at = CURRENT_TIMESTAMP,
        terms_snapshot = v_snapshot,
        terms_hash = v_hash,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_transfer_id
    RETURNING *
    INTO v_transfer;


    RETURN v_transfer;

END;
$function$;


-- ============================================================
-- 8. RECHAZAR
-- ============================================================

CREATE OR REPLACE FUNCTION public.reject_project_ownership_transfer(
    p_transfer_id UUID
)
RETURNS public.project_ownership_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_transfer public.project_ownership_transfers;

BEGIN

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    SELECT *
    INTO v_transfer
    FROM public.project_ownership_transfers
    WHERE id = p_transfer_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transferencia no encontrada';
    END IF;

    IF v_transfer.requested_new_owner_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION
            'Solo el nuevo propietario puede rechazar la transferencia';
    END IF;

    IF v_transfer.status <> 'pending_acceptance' THEN
        RAISE EXCEPTION
            'La transferencia no está pendiente de aceptación';
    END IF;

    UPDATE public.project_ownership_transfers
    SET
        status = 'rejected',
        accepted_by = auth.uid(),
        accepted_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_transfer_id
    RETURNING *
    INTO v_transfer;

    RETURN v_transfer;

END;
$function$;


-- ============================================================
-- 9. PERMISOS
-- ============================================================

REVOKE ALL
ON FUNCTION public.request_project_ownership_transfer(UUID, UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.request_project_ownership_transfer(UUID, UUID, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION public.approve_project_ownership_transfer(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.approve_project_ownership_transfer(UUID)
TO authenticated;


REVOKE ALL
ON FUNCTION public.accept_project_ownership_transfer(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.accept_project_ownership_transfer(UUID)
TO authenticated;


REVOKE ALL
ON FUNCTION public.reject_project_ownership_transfer(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.reject_project_ownership_transfer(UUID)
TO authenticated;


COMMIT;