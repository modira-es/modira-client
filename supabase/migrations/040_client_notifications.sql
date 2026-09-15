BEGIN;

-- ============================================================
-- MODIRA — 040_client_notifications.sql
--
-- SISTEMA DE NOTIFICACIONES DEL ÁREA CLIENTE
--
-- OBJETIVO
-- ============================================================
--
-- Crear un sistema centralizado de notificaciones para el
-- cliente de Modira.
--
-- Las notificaciones podrán informar, entre otras cosas, de:
--
-- - hitos completados;
-- - información solicitada;
-- - novedades del proyecto;
-- - documentos disponibles;
-- - presupuestos;
-- - facturas/pagos;
-- - solicitudes de cambio;
-- - otros eventos relevantes del proyecto.
--
-- ESTA MIGRACIÓN:
--
-- 1. NO modifica projects.
-- 2. NO modifica project_milestones.
-- 3. NO modifica quotations.
-- 4. NO modifica invoices.
-- 5. NO modifica payments.
-- 6. NO modifica project_documents.
-- 7. NO modifica activity_log.
-- 8. NO modifica ninguna policy existente.
-- 9. NO modifica ninguna RPC existente.
--
-- Únicamente:
--
-- - crea public.notifications;
-- - crea RPCs nuevas;
-- - crea un helper interno para emitir notificaciones;
-- - crea un trigger sobre project_milestones para avisar cuando
--   un hito se completa.
--
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================
--
-- Esta migración depende de:
--
-- - public.projects
-- - public.project_milestones (030)
-- - current_user_is_worker()
-- - current_user_is_active()
--
-- Si falta alguna pieza fundamental, se detiene antes de
-- modificar la base de datos.
--
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- PROJECTS
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'projects'
    ) THEN
        RAISE EXCEPTION
            '040 stopped: public.projects does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECTS.ID
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'id'
    ) THEN
        RAISE EXCEPTION
            '040 stopped: projects.id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECTS.USER_ID
    --
    -- Es el propietario del proyecto para el acceso del cliente.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'user_id'
    ) THEN
        RAISE EXCEPTION
            '040 stopped: projects.user_id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECT_MILESTONES
    --
    -- Debe existir porque la 040 se conecta con los hitos de 030.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'project_milestones'
    ) THEN
        RAISE EXCEPTION
            '040 stopped: public.project_milestones does not exist (030 required)';
    END IF;


    -- --------------------------------------------------------
    -- PROJECT_MILESTONES.ID
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'project_milestones'
          AND column_name = 'id'
    ) THEN
        RAISE EXCEPTION
            '040 stopped: project_milestones.id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECT_MILESTONES.PROJECT_ID
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'project_milestones'
          AND column_name = 'project_id'
    ) THEN
        RAISE EXCEPTION
            '040 stopped: project_milestones.project_id does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECT_MILESTONES.NOMBRE
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'project_milestones'
          AND column_name = 'nombre'
    ) THEN
        RAISE EXCEPTION
            '041 stopped: project_milestones.nombre does not exist';
    END IF;


    -- --------------------------------------------------------
    -- PROJECT_MILESTONES.ESTADO
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'project_milestones'
          AND column_name = 'estado'
    ) THEN
        RAISE EXCEPTION
            '040 stopped: project_milestones.estado does not exist';
    END IF;


    -- --------------------------------------------------------
    -- SECURITY FUNCTIONS
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.current_user_is_worker()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '040 stopped: current_user_is_worker() does not exist';
    END IF;


    IF to_regprocedure(
        'public.current_user_is_active()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '040 stopped: current_user_is_active() does not exist';
    END IF;

END $$;


-- ============================================================
-- 2. TABLA NOTIFICATIONS
-- ============================================================
--
-- Cada fila representa una notificación dirigida a un usuario.
--
-- project_id permite relacionar la notificación con un proyecto.
--
-- Puede ser NULL para notificaciones generales del sistema.
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.notifications (

    id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    user_id UUID NOT NULL
        REFERENCES auth.users(id)
        ON DELETE CASCADE,

    project_id UUID
        REFERENCES public.projects(id)
        ON DELETE CASCADE,

    tipo TEXT NOT NULL,

    titulo TEXT NOT NULL,

    mensaje TEXT NOT NULL,

    metadata JSONB,

    read_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT notifications_tipo_check
        CHECK (
            tipo IN (
                'milestone_completed',
                'information_requested',
                'project_update',
                'document_available',
                'quotation',
                'invoice',
                'project_change_request',
                'system'
            )
        ),

    CONSTRAINT notifications_titulo_check
        CHECK (
            LENGTH(BTRIM(titulo)) > 0
            AND LENGTH(titulo) <= 200
        ),

    CONSTRAINT notifications_mensaje_check
        CHECK (
            LENGTH(BTRIM(mensaje)) > 0
            AND LENGTH(mensaje) <= 2000
        )
);


-- ============================================================
-- 3. ÍNDICES
-- ============================================================
--
-- Consultas principales del dashboard:
--
-- usuario → notificaciones recientes
-- usuario → no leídas
-- proyecto → notificaciones
--
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_notifications_user_created_at
ON public.notifications (
    user_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_notifications_user_unread
ON public.notifications (
    user_id,
    created_at DESC
)
WHERE read_at IS NULL;


CREATE INDEX IF NOT EXISTS
    idx_notifications_project_id
ON public.notifications (
    project_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_notifications_type
ON public.notifications (
    tipo,
    created_at DESC
);


-- ============================================================
-- 4. RLS
-- ============================================================

ALTER TABLE public.notifications
ENABLE ROW LEVEL SECURITY;


-- ------------------------------------------------------------
-- SELECT
--
-- Un usuario activo solo puede consultar sus propias
-- notificaciones.
--
-- Un worker activo NO necesita consultar esta tabla mediante
-- SELECT para gestionar notificaciones de clientes.
--
-- ------------------------------------------------------------

DROP POLICY IF EXISTS
    notifications_client_select
ON public.notifications;


CREATE POLICY
    notifications_client_select
ON public.notifications
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND user_id = auth.uid()
);


-- ============================================================
-- 5. PRIVILEGIOS DIRECTOS
-- ============================================================
--
-- El cliente:
--
-- SELECT → sí
-- INSERT  → no
-- UPDATE  → no
-- DELETE  → no
--
-- Las escrituras se realizan mediante RPC.
--
-- ============================================================

REVOKE ALL
ON public.notifications
FROM PUBLIC, anon, authenticated;


GRANT SELECT
ON public.notifications
TO authenticated;


-- ============================================================
-- 6. HELPER INTERNO — EMITIR NOTIFICACIÓN
-- ============================================================
--
-- Esta función NO se expone al cliente.
--
-- Su finalidad es centralizar la creación de notificaciones.
--
-- Recibe project_id y obtiene automáticamente:
--
-- projects.user_id
--
-- Esto es MUY importante.
--
-- No permitimos que el caller diga:
--
-- "proyecto X → notificar al usuario Y"
--
-- porque podría producir una notificación para otro usuario.
--
-- En cambio:
--
-- project_id
--     ↓
-- projects.user_id
--     ↓
-- propietario real del proyecto
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.emit_project_client_notification(
    p_project_id UUID,
    p_tipo TEXT,
    p_titulo TEXT,
    p_mensaje TEXT,
    p_metadata JSONB DEFAULT NULL
)
RETURNS public.notifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

    v_client_user_id UUID;

    v_notification public.notifications;

BEGIN

    -- --------------------------------------------------------
    -- VALIDAR PROYECTO
    -- --------------------------------------------------------

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto es obligatorio';
    END IF;


    SELECT p.user_id
    INTO v_client_user_id
    FROM public.projects p
    WHERE p.id = p_project_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El proyecto indicado no existe';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR USUARIO DEL PROYECTO
    -- --------------------------------------------------------

    IF v_client_user_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto no tiene un usuario cliente asociado';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR TIPO
    -- --------------------------------------------------------

    IF p_tipo IS NULL
       OR p_tipo NOT IN (
            'milestone_completed',
            'information_requested',
            'project_update',
            'document_available',
            'quotation',
            'invoice',
            'project_change_request',
            'system'
       )
    THEN
        RAISE EXCEPTION
            'Tipo de notificación no válido';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR TÍTULO
    -- --------------------------------------------------------

    IF p_titulo IS NULL
       OR LENGTH(BTRIM(p_titulo)) = 0
       OR LENGTH(p_titulo) > 200
    THEN
        RAISE EXCEPTION
            'El título de la notificación no es válido';
    END IF;


    -- --------------------------------------------------------
    -- VALIDAR MENSAJE
    -- --------------------------------------------------------

    IF p_mensaje IS NULL
       OR LENGTH(BTRIM(p_mensaje)) = 0
       OR LENGTH(p_mensaje) > 2000
    THEN
        RAISE EXCEPTION
            'El mensaje de la notificación no es válido';
    END IF;


    -- --------------------------------------------------------
    -- INSERTAR
    -- --------------------------------------------------------

    INSERT INTO public.notifications (
        user_id,
        project_id,
        tipo,
        titulo,
        mensaje,
        metadata
    )
    VALUES (
        v_client_user_id,
        p_project_id,
        p_tipo,
        BTRIM(p_titulo),
        BTRIM(p_mensaje),
        p_metadata
    )
    RETURNING *
    INTO v_notification;


    RETURN v_notification;

END;
$$;


-- ------------------------------------------------------------
-- IMPORTANTE:
--
-- No se concede EXECUTE al cliente directamente.
--
-- Esta función será utilizada por:
--
-- - triggers internos;
-- - RPCs de trabajador que validen previamente su identidad.
--
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.emit_project_client_notification(
    UUID,
    TEXT,
    TEXT,
    TEXT,
    JSONB
)
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 7. RPC — CREAR NOTIFICACIÓN PARA EL CLIENTE
-- ============================================================
--
-- Permite a un WORKER ACTIVO generar una notificación para el
-- cliente propietario del proyecto.
--
-- Ejemplo futuro:
--
-- El worker pulsa:
--
-- "He enviado un correo solicitando información"
--
-- y el frontend llama:
--
-- create_client_notification(
--     project_id,
--     'information_requested',
--     'Información solicitada',
--     'Hemos enviado un correo...'
-- )
--
-- El user_id NO lo proporciona el frontend.
--
-- Se obtiene desde projects.user_id.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.create_client_notification(
    p_project_id UUID,
    p_tipo TEXT,
    p_titulo TEXT,
    p_mensaje TEXT,
    p_metadata JSONB DEFAULT NULL
)
RETURNS public.notifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- WORKER ACTIVO
    -- --------------------------------------------------------

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- --------------------------------------------------------
    -- CREAR NOTIFICACIÓN
    -- --------------------------------------------------------

    RETURN public.emit_project_client_notification(
        p_project_id,
        p_tipo,
        p_titulo,
        p_mensaje,
        p_metadata
    );

END;
$$;


-- ------------------------------------------------------------
-- PERMISOS
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.create_client_notification(
    UUID,
    TEXT,
    TEXT,
    TEXT,
    JSONB
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.create_client_notification(
    UUID,
    TEXT,
    TEXT,
    TEXT,
    JSONB
)
TO authenticated;


-- ============================================================
-- 8. RPC — MARCAR UNA NOTIFICACIÓN COMO LEÍDA
-- ============================================================
--
-- El cliente NO recibe UPDATE directo sobre notifications.
--
-- En su lugar:
--
-- mark_notification_read(notification_id)
--
-- La RPC verifica:
--
-- 1. usuario autenticado;
-- 2. cuenta activa;
-- 3. la notificación pertenece al usuario autenticado.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.mark_notification_read(
    p_notification_id UUID
)
RETURNS public.notifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

    v_notification public.notifications;

BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- CUENTA ACTIVA
    -- --------------------------------------------------------

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'Acceso denegado: la cuenta está bloqueada';
    END IF;


    -- --------------------------------------------------------
    -- NOTIFICACIÓN PROPIA
    -- --------------------------------------------------------

    SELECT *
    INTO v_notification
    FROM public.notifications
    WHERE id = p_notification_id
      AND user_id = auth.uid()
    FOR UPDATE;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Notificación no encontrada';
    END IF;


    -- --------------------------------------------------------
    -- MARCAR COMO LEÍDA
    --
    -- Si ya estaba leída, conservamos el timestamp original.
    -- --------------------------------------------------------

    IF v_notification.read_at IS NULL THEN

        UPDATE public.notifications
        SET read_at = CURRENT_TIMESTAMP
        WHERE id = p_notification_id
        RETURNING *
        INTO v_notification;

    END IF;


    RETURN v_notification;

END;
$$;


-- ------------------------------------------------------------
-- PERMISOS
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.mark_notification_read(
    UUID
)
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.mark_notification_read(
    UUID
)
TO authenticated;


-- ============================================================
-- 9. RPC — MARCAR TODAS COMO LEÍDAS
-- ============================================================
--
-- Para el botón:
--
-- "Marcar todas como leídas"
--
-- Solo afecta a las notificaciones del usuario autenticado.
--
-- ============================================================

CREATE OR REPLACE FUNCTION
public.mark_all_notifications_read()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE

    v_updated_count INTEGER;

BEGIN

    -- --------------------------------------------------------
    -- AUTENTICACIÓN
    -- --------------------------------------------------------

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Usuario no autenticado';
    END IF;


    -- --------------------------------------------------------
    -- CUENTA ACTIVA
    -- --------------------------------------------------------

    IF NOT public.current_user_is_active() THEN
        RAISE EXCEPTION
            'Acceso denegado: la cuenta está bloqueada';
    END IF;


    -- --------------------------------------------------------
    -- ACTUALIZAR SOLO LAS PROPIAS
    -- --------------------------------------------------------

    UPDATE public.notifications
    SET read_at = CURRENT_TIMESTAMP
    WHERE user_id = auth.uid()
      AND read_at IS NULL;


    GET DIAGNOSTICS
        v_updated_count = ROW_COUNT;


    RETURN v_updated_count;

END;
$$;


-- ------------------------------------------------------------
-- PERMISOS
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.mark_all_notifications_read()
FROM PUBLIC, anon;


GRANT EXECUTE
ON FUNCTION public.mark_all_notifications_read()
TO authenticated;


-- ============================================================
-- 10. TRIGGER — HITO COMPLETADO → NOTIFICACIÓN
-- ============================================================
--
-- Esta es la primera automatización real del sistema.
--
-- Cuando:
--
-- project_milestones.estado
--
-- cambia a:
--
-- 'completado'
--
-- se genera automáticamente una notificación para el cliente.
--
-- NO se genera otra notificación si el hito ya estaba
-- completado y simplemente se modifica otra propiedad.
--
-- ============================================================


CREATE OR REPLACE FUNCTION
public.notify_client_when_milestone_completed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

    -- --------------------------------------------------------
    -- SOLO CUANDO SE PRODUCE LA TRANSICIÓN A COMPLETADO
    -- --------------------------------------------------------

    IF NEW.estado = 'completado'
       AND (
            TG_OP = 'INSERT'
            OR OLD.estado IS DISTINCT FROM 'completado'
       )
    THEN

        PERFORM public.emit_project_client_notification(
            NEW.project_id,
            'milestone_completed',
            'Hito completado',
            'El hito "' ||
            LEFT(BTRIM(NEW.nombre), 180) ||
            '" ha sido completado.',
            jsonb_build_object(
                'milestone_id', NEW.id,
                'event', 'milestone_completed'
            )
        );

    END IF;


    RETURN NEW;

END;
$$;


-- ------------------------------------------------------------
-- REEMPLAZAR SOLO EL TRIGGER DE ESTA NUEVA FUNCIONALIDAD
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS
    project_milestone_completed_notification
ON public.project_milestones;


CREATE TRIGGER
    project_milestone_completed_notification
AFTER INSERT OR UPDATE OF estado
ON public.project_milestones
FOR EACH ROW
EXECUTE FUNCTION
    public.notify_client_when_milestone_completed();


-- ------------------------------------------------------------
-- El helper del trigger tampoco debe ser ejecutable
-- directamente por usuarios.
-- ------------------------------------------------------------

REVOKE ALL
ON FUNCTION public.notify_client_when_milestone_completed()
FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 11. DOCUMENTACIÓN
-- ============================================================

COMMENT ON TABLE public.notifications
IS
'Notificaciones dirigidas a usuarios de Modira. El cliente solo puede consultar sus propias notificaciones y marcarlas como leídas mediante RPC. Las notificaciones de proyecto se relacionan con el propietario definido en projects.user_id.';


COMMENT ON COLUMN public.notifications.user_id
IS
'Usuario destinatario de la notificación. Para notificaciones de proyecto se obtiene automáticamente desde projects.user_id.';


COMMENT ON COLUMN public.notifications.project_id
IS
'Proyecto relacionado con la notificación. Puede ser NULL para notificaciones generales del sistema.';


COMMENT ON COLUMN public.notifications.tipo
IS
'Tipo controlado de notificación: milestone_completed, information_requested, project_update, document_available, quotation, invoice, project_change_request o system.';


COMMENT ON COLUMN public.notifications.read_at
IS
'Momento en que el usuario marcó la notificación como leída. NULL significa no leída.';


COMMENT ON FUNCTION public.create_client_notification(
    UUID,
    TEXT,
    TEXT,
    TEXT,
    JSONB
)
IS
'Permite a un trabajador activo crear una notificación para el cliente propietario de un proyecto. El destinatario se obtiene automáticamente desde projects.user_id.';


COMMENT ON FUNCTION public.mark_notification_read(
    UUID
)
IS
'Marca como leída una notificación perteneciente al usuario autenticado y activo.';


COMMENT ON FUNCTION public.mark_all_notifications_read()
IS
'Marca como leídas todas las notificaciones no leídas del usuario autenticado y activo.';


-- ============================================================
-- 12. VALIDACIONES FINALES
-- ============================================================

DO $$
DECLARE

    v_count INTEGER;

    v_rls_enabled BOOLEAN;

BEGIN

    -- --------------------------------------------------------
    -- TABLA
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'notifications';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '040 failed: notifications table missing';
    END IF;


    -- --------------------------------------------------------
    -- COLUMNAS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'notifications'
      AND column_name IN (
          'id',
          'user_id',
          'project_id',
          'tipo',
          'titulo',
          'mensaje',
          'metadata',
          'read_at',
          'created_at'
      );

    IF v_count <> 9 THEN
        RAISE EXCEPTION
            '040 failed: notifications columns are incomplete';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    SELECT relrowsecurity
    INTO v_rls_enabled
    FROM pg_class
    WHERE oid = 'public.notifications'::regclass;

    IF v_rls_enabled IS NOT TRUE THEN
        RAISE EXCEPTION
            '040 failed: RLS is not enabled on notifications';
    END IF;


    -- --------------------------------------------------------
    -- SELECT POLICY
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'notifications'
      AND policyname = 'notifications_client_select';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '040 failed: notifications_client_select policy missing';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT INSERT
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'notifications'
      AND cmd = 'INSERT';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '040 failed: direct INSERT policy exists';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT UPDATE
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'notifications'
      AND cmd = 'UPDATE';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '040 failed: direct UPDATE policy exists';
    END IF;


    -- --------------------------------------------------------
    -- NO DIRECT DELETE
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'notifications'
      AND cmd = 'DELETE';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '040 failed: direct DELETE policy exists';
    END IF;


    -- --------------------------------------------------------
    -- RPC — CREATE
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.create_client_notification(uuid,text,text,text,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '040 failed: create_client_notification() missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC — MARK ONE
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.mark_notification_read(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '040 failed: mark_notification_read() missing';
    END IF;


    -- --------------------------------------------------------
    -- RPC — MARK ALL
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.mark_all_notifications_read()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '040 failed: mark_all_notifications_read() missing';
    END IF;


    -- --------------------------------------------------------
    -- INTERNAL HELPER
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.emit_project_client_notification(uuid,text,text,text,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '040 failed: internal notification helper missing';
    END IF;


    -- --------------------------------------------------------
    -- MILESTONE TRIGGER FUNCTION
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.notify_client_when_milestone_completed()'
    ) IS NULL THEN
        RAISE EXCEPTION
            '040 failed: milestone notification trigger function missing';
    END IF;


    -- --------------------------------------------------------
    -- MILESTONE TRIGGER
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_trigger
    WHERE tgname = 'project_milestone_completed_notification'
      AND tgrelid = 'public.project_milestones'::regclass
      AND NOT tgisinternal;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '040 failed: milestone notification trigger missing';
    END IF;


    -- --------------------------------------------------------
    -- DIRECT TABLE PRIVILEGES
    -- --------------------------------------------------------

    IF has_table_privilege(
        'authenticated',
        'public.notifications',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            '040 failed: authenticated has direct INSERT privilege';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.notifications',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            '040 failed: authenticated has direct UPDATE privilege';
    END IF;


    IF has_table_privilege(
        'authenticated',
        'public.notifications',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            '040 failed: authenticated has direct DELETE privilege';
    END IF;


    -- --------------------------------------------------------
    -- CLIENT RPC PRIVILEGES
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.mark_notification_read(uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '040 failed: authenticated cannot execute mark_notification_read';
    END IF;


    IF NOT has_function_privilege(
        'authenticated',
        'public.mark_all_notifications_read()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '040 failed: authenticated cannot execute mark_all_notifications_read';
    END IF;


    -- --------------------------------------------------------
    -- WORKER RPC PRIVILEGE
    -- --------------------------------------------------------

    IF NOT has_function_privilege(
        'authenticated',
        'public.create_client_notification(uuid,text,text,text,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '040 failed: authenticated cannot execute create_client_notification';
    END IF;


    -- --------------------------------------------------------
    -- INTERNAL HELPER NO EXPOSITION
    -- --------------------------------------------------------

    IF has_function_privilege(
        'authenticated',
        'public.emit_project_client_notification(uuid,text,text,text,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            '040 failed: internal notification helper is directly executable';
    END IF;


END $$;


-- ============================================================
-- FIN 040
-- ============================================================

COMMIT;