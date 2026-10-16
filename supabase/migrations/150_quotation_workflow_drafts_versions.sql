BEGIN;

-- ============================================================================
-- MIGRACIÓN 150 — FLUJO DE BORRADORES, VERSIONES OFICIALES Y SOLICITUDES DE CAMBIO
-- Modira / Supabase PostgreSQL
--
-- Diseño:
--   * Los borradores internos no crean ni modifican public.quotations.
--   * Publicar crea/actualiza la fila de quotations y registra una versión
--     oficial inmutable del contenido publicado.
--   * Las versiones oficiales anteriores permanecen disponibles para historial.
--   * Las solicitudes de cambio bloquean la respuesta del cliente hasta publicar
--     una nueva versión.
--   * Se conservan los RPC/controles actuales de aceptación contractual.
--   * Cada campo editable tiene su propio rate limit por trabajador y, además,
--     se limita la frecuencia general de guardado/publicación.
--   * Los documentos versionados se registran en esta migración; la Edge Function
--     se adaptará posteriormente para generar/subirlos y llamar al RPC nuevo.
--
-- No se migran ni reparan presupuestos históricos de prueba.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Preflight: fallar pronto si el esquema real no coincide.
-- ---------------------------------------------------------------------------
DO $preflight$
BEGIN
  IF to_regclass('public.quotations') IS NULL
     OR to_regclass('public.projects') IS NULL
     OR to_regclass('public.clients') IS NULL
     OR to_regclass('public.notifications') IS NULL
     OR to_regclass('public.security_rate_limits') IS NULL THEN
    RAISE EXCEPTION 'Migración 150 detenida: falta una tabla requerida';
  END IF;

  IF to_regprocedure('public.enforce_security_rate_limit(text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Migración 150 detenida: falta enforce_security_rate_limit(text, integer, integer)';
  END IF;

  IF to_regprocedure('public.require_current_worker_permission(text)') IS NULL THEN
    RAISE EXCEPTION 'Migración 150 detenida: falta require_current_worker_permission(text)';
  END IF;

  IF to_regprocedure('public.current_worker_has_permission(text)') IS NULL
     OR to_regprocedure('public.current_user_is_worker()') IS NULL
     OR to_regprocedure('public.current_user_is_active()') IS NULL THEN
    RAISE EXCEPTION 'Migración 150 detenida: faltan helpers de autorización existentes';
  END IF;

  IF to_regprocedure('public.create_quotation_by_worker(uuid,uuid,text,text,jsonb,numeric,boolean,numeric,text,timestamp with time zone,timestamp with time zone,text)') IS NULL
     OR to_regprocedure('public.update_quotation_by_worker(uuid,uuid,text,text,jsonb,numeric,boolean,numeric,text,timestamp with time zone,timestamp with time zone,text)') IS NULL
     OR to_regprocedure('public.respond_to_quotation__legacy_113(text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Migración 150 detenida: no están disponibles los RPC de presupuestos esperados';
  END IF;
END;
$preflight$;

-- ---------------------------------------------------------------------------
-- 1. Tablas nuevas. No se cambia el CHECK de quotations.estado.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.quotation_workflow_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  quotation_id uuid NULL REFERENCES public.quotations(id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  draft_kind text NOT NULL CHECK (draft_kind IN ('initial', 'correction', 'requested_change')),
  draft_status text NOT NULL DEFAULT 'draft' CHECK (draft_status IN ('draft', 'published', 'discarded')),
  content jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(content) = 'object'),
  based_on_version_id uuid NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz NULL,
  published_version_id uuid NULL,
  CONSTRAINT quotation_workflow_drafts_content_size_check
    CHECK (pg_column_size(content) <= 262144)
);

CREATE INDEX IF NOT EXISTS idx_quotation_workflow_drafts_project_status
  ON public.quotation_workflow_drafts(project_id, draft_status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_quotation_workflow_drafts_quotation_status
  ON public.quotation_workflow_drafts(quotation_id, draft_status, updated_at DESC);

-- Solo un borrador activo por presupuesto ya publicado. Para el primer borrador,
-- quotation_id es NULL y se permiten varios presupuestos en preparación.
CREATE UNIQUE INDEX IF NOT EXISTS uq_quotation_workflow_one_active_draft_per_quotation
  ON public.quotation_workflow_drafts(quotation_id)
  WHERE quotation_id IS NOT NULL AND draft_status = 'draft';

CREATE TABLE IF NOT EXISTS public.quotation_official_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id uuid NOT NULL REFERENCES public.quotations(id) ON DELETE CASCADE,
  version_major integer NOT NULL CHECK (version_major >= 1),
  version_minor integer NOT NULL DEFAULT 0 CHECK (version_minor >= 0),
  version_label text NOT NULL,
  content_snapshot jsonb NOT NULL CHECK (jsonb_typeof(content_snapshot) = 'object'),
  document_path text NULL CHECK (document_path IS NULL OR length(document_path) <= 500),
  document_sha256 text NULL CHECK (document_sha256 IS NULL OR document_sha256 ~ '^[0-9a-fA-F]{64}$'),
  is_current boolean NOT NULL DEFAULT true,
  published_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  published_at timestamptz NOT NULL DEFAULT now(),
  client_notified_at timestamptz NULL,
  client_response text NULL CHECK (client_response IS NULL OR client_response IN ('Aceptado', 'Rechazado')),
  responded_by uuid NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  responded_at timestamptz NULL,
  CONSTRAINT quotation_official_versions_label_check
    CHECK (version_label ~ '^V[1-9][0-9]*(\.[1-9][0-9]*)?$'),
  CONSTRAINT quotation_official_versions_response_consistency_check
    CHECK ((client_response IS NULL AND responded_by IS NULL AND responded_at IS NULL)
        OR (client_response IS NOT NULL AND responded_by IS NOT NULL AND responded_at IS NOT NULL)),
  CONSTRAINT quotation_official_versions_quotation_major_minor_unique
    UNIQUE (quotation_id, version_major, version_minor)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_quotation_official_versions_one_current
  ON public.quotation_official_versions(quotation_id)
  WHERE is_current = true;
CREATE INDEX IF NOT EXISTS idx_quotation_official_versions_history
  ON public.quotation_official_versions(quotation_id, version_major DESC, version_minor DESC);

CREATE TABLE IF NOT EXISTS public.quotation_workflow_state (
  quotation_id uuid PRIMARY KEY REFERENCES public.quotations(id) ON DELETE CASCADE,
  current_version_id uuid NULL REFERENCES public.quotation_official_versions(id) ON DELETE SET NULL,
  workflow_status text NOT NULL CHECK (workflow_status IN ('presented', 'in_review', 'accepted', 'rejected')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NULL REFERENCES auth.users(id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS public.quotation_change_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id uuid NOT NULL REFERENCES public.quotations(id) ON DELETE CASCADE,
  official_version_id uuid NOT NULL REFERENCES public.quotation_official_versions(id) ON DELETE CASCADE,
  requested_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_text text NOT NULL CHECK (length(btrim(request_text)) BETWEEN 1 AND 5000),
  request_status text NOT NULL DEFAULT 'open' CHECK (request_status IN ('open', 'resolved', 'cancelled')),
  requested_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz NULL,
  resolved_by uuid NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  resolved_version_id uuid NULL REFERENCES public.quotation_official_versions(id) ON DELETE SET NULL,
  CONSTRAINT quotation_change_requests_resolution_check
    CHECK ((request_status = 'open' AND resolved_at IS NULL AND resolved_by IS NULL AND resolved_version_id IS NULL)
        OR (request_status <> 'open' AND resolved_at IS NOT NULL AND resolved_by IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_quotation_change_requests_quotation
  ON public.quotation_change_requests(quotation_id, requested_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_quotation_change_request_one_open_per_quotation
  ON public.quotation_change_requests(quotation_id)
  WHERE request_status = 'open';

-- Añadir FK circular después de crear ambas tablas.
DO $fk$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'quotation_workflow_drafts_based_on_version_fkey'
      AND conrelid = 'public.quotation_workflow_drafts'::regclass
  ) THEN
    ALTER TABLE public.quotation_workflow_drafts
      ADD CONSTRAINT quotation_workflow_drafts_based_on_version_fkey
      FOREIGN KEY (based_on_version_id)
      REFERENCES public.quotation_official_versions(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'quotation_workflow_drafts_published_version_fkey'
      AND conrelid = 'public.quotation_workflow_drafts'::regclass
  ) THEN
    ALTER TABLE public.quotation_workflow_drafts
      ADD CONSTRAINT quotation_workflow_drafts_published_version_fkey
      FOREIGN KEY (published_version_id)
      REFERENCES public.quotation_official_versions(id) ON DELETE SET NULL;
  END IF;
END;
$fk$;

-- ---------------------------------------------------------------------------
-- 2. RLS y permisos: lectura explícita; escritura solo mediante RPC.
-- ---------------------------------------------------------------------------
ALTER TABLE public.quotation_workflow_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quotation_official_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quotation_workflow_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quotation_change_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.quotation_workflow_drafts FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.quotation_official_versions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.quotation_workflow_state FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.quotation_change_requests FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.quotation_workflow_drafts TO authenticated;
GRANT SELECT ON public.quotation_official_versions TO authenticated;
GRANT SELECT ON public.quotation_workflow_state TO authenticated;
GRANT SELECT ON public.quotation_change_requests TO authenticated;

DROP POLICY IF EXISTS quotation_workflow_drafts_worker_select ON public.quotation_workflow_drafts;
CREATE POLICY quotation_workflow_drafts_worker_select
ON public.quotation_workflow_drafts FOR SELECT TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission('quotations.read')
  AND EXISTS (
    SELECT 1 FROM public.projects p
    WHERE p.id = quotation_workflow_drafts.project_id
      AND p.company_id = quotation_workflow_drafts.company_id
  )
);

DROP POLICY IF EXISTS quotation_official_versions_worker_select ON public.quotation_official_versions;
CREATE POLICY quotation_official_versions_worker_select
ON public.quotation_official_versions FOR SELECT TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission('quotations.read')
  AND EXISTS (
    SELECT 1 FROM public.quotations q
    WHERE q.id = quotation_official_versions.quotation_id
  )
);

DROP POLICY IF EXISTS quotation_official_versions_client_select ON public.quotation_official_versions;
CREATE POLICY quotation_official_versions_client_select
ON public.quotation_official_versions FOR SELECT TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND EXISTS (
    SELECT 1
    FROM public.quotations q
    WHERE q.id = quotation_official_versions.quotation_id
      AND (
        q.user_id = auth.uid()
        OR EXISTS (
          SELECT 1 FROM public.clients c
          WHERE c.id = q.client_id AND c.profile_id = auth.uid()
        )
      )
  )
);

DROP POLICY IF EXISTS quotation_workflow_state_worker_select ON public.quotation_workflow_state;
CREATE POLICY quotation_workflow_state_worker_select
ON public.quotation_workflow_state FOR SELECT TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission('quotations.read')
);

DROP POLICY IF EXISTS quotation_workflow_state_client_select ON public.quotation_workflow_state;
CREATE POLICY quotation_workflow_state_client_select
ON public.quotation_workflow_state FOR SELECT TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND EXISTS (
    SELECT 1 FROM public.quotations q
    WHERE q.id = quotation_workflow_state.quotation_id
      AND (q.user_id = auth.uid() OR EXISTS (
        SELECT 1 FROM public.clients c
        WHERE c.id = q.client_id AND c.profile_id = auth.uid()
      ))
  )
);

DROP POLICY IF EXISTS quotation_change_requests_worker_select ON public.quotation_change_requests;
CREATE POLICY quotation_change_requests_worker_select
ON public.quotation_change_requests FOR SELECT TO authenticated
USING (
  public.current_user_is_worker()
  AND public.current_worker_has_permission('quotations.read')
);

DROP POLICY IF EXISTS quotation_change_requests_client_select ON public.quotation_change_requests;
CREATE POLICY quotation_change_requests_client_select
ON public.quotation_change_requests FOR SELECT TO authenticated
USING (
  public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND requested_by = auth.uid()
  AND EXISTS (
    SELECT 1 FROM public.quotations q
    WHERE q.id = quotation_change_requests.quotation_id
      AND (q.user_id = auth.uid() OR EXISTS (
        SELECT 1 FROM public.clients c
        WHERE c.id = q.client_id AND c.profile_id = auth.uid()
      ))
  )
);

-- ---------------------------------------------------------------------------
-- 3. Rate limit por cada campo editable y validación del JSON de borrador.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_quotation_workflow_content(p_content jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
  v_key text;
  v_result jsonb;
  v_number numeric;
BEGIN
  IF p_content IS NULL OR jsonb_typeof(p_content) <> 'object' THEN
    RAISE EXCEPTION 'El contenido del borrador debe ser un objeto JSON';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_content)
  LOOP
    IF v_key NOT IN (
      'titulo', 'descripcion_detallada', 'servicios_incluidos',
      'iva_porcentaje', 'irpf_aplicado', 'irpf_porcentaje',
      'fecha_validez', 'notas'
    ) THEN
      RAISE EXCEPTION 'El campo % no es editable en el borrador', v_key;
    END IF;
  END LOOP;

  v_result := jsonb_build_object(
    'titulo', '',
    'descripcion_detallada', NULL,
    'servicios_incluidos', '[]'::jsonb,
    'iva_porcentaje', 21,
    'irpf_aplicado', false,
    'irpf_porcentaje', 0,
    'fecha_validez', NULL,
    'notas', NULL
  ) || p_content;

  -- Normalizar campos opcionales vacíos que suelen llegar así desde formularios web.
  IF jsonb_typeof(v_result->'descripcion_detallada') = 'string'
     AND btrim(v_result->>'descripcion_detallada') = '' THEN
    v_result := jsonb_set(v_result, '{descripcion_detallada}', 'null'::jsonb, true);
  END IF;
  IF jsonb_typeof(v_result->'fecha_validez') = 'string'
     AND btrim(v_result->>'fecha_validez') = '' THEN
    v_result := jsonb_set(v_result, '{fecha_validez}', 'null'::jsonb, true);
  END IF;
  IF jsonb_typeof(v_result->'notas') = 'string'
     AND btrim(v_result->>'notas') = '' THEN
    v_result := jsonb_set(v_result, '{notas}', 'null'::jsonb, true);
  END IF;

  IF jsonb_typeof(v_result->'titulo') <> 'string'
     OR length(v_result->>'titulo') > 200 THEN
    RAISE EXCEPTION 'El título debe ser texto y no superar 200 caracteres';
  END IF;

  IF v_result->'descripcion_detallada' <> 'null'::jsonb THEN
    IF jsonb_typeof(v_result->'descripcion_detallada') <> 'string'
       OR length(v_result->>'descripcion_detallada') > 10000 THEN
      RAISE EXCEPTION 'La descripción no puede superar 10000 caracteres';
    END IF;
  END IF;

  IF jsonb_typeof(v_result->'servicios_incluidos') <> 'array' THEN
    RAISE EXCEPTION 'Los servicios deben ser un array de hasta 100 elementos';
  END IF;
  IF jsonb_array_length(v_result->'servicios_incluidos') > 100 THEN
    RAISE EXCEPTION 'Los servicios deben ser un array de hasta 100 elementos';
  END IF;

  IF jsonb_typeof(v_result->'irpf_aplicado') <> 'boolean' THEN
    RAISE EXCEPTION 'irpf_aplicado debe ser booleano';
  END IF;

  BEGIN
    v_number := (v_result->>'iva_porcentaje')::numeric;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'El porcentaje de IVA no es válido';
  END;
  IF v_number < 0 OR v_number > 100 THEN
    RAISE EXCEPTION 'El porcentaje de IVA debe estar entre 0 y 100';
  END IF;
  v_result := jsonb_set(v_result, '{iva_porcentaje}', to_jsonb(round(v_number, 2)), true);

  BEGIN
    v_number := (v_result->>'irpf_porcentaje')::numeric;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'El porcentaje de IRPF no es válido';
  END;
  IF v_number < 0 OR v_number > 100 THEN
    RAISE EXCEPTION 'El porcentaje de IRPF debe estar entre 0 y 100';
  END IF;
  IF (v_result->>'irpf_aplicado')::boolean = false AND v_number <> 0 THEN
    RAISE EXCEPTION 'Si el IRPF no se aplica, su porcentaje debe ser 0';
  END IF;
  IF (v_result->>'irpf_aplicado')::boolean = true AND v_number <= 0 THEN
    RAISE EXCEPTION 'Si el IRPF se aplica, su porcentaje debe ser mayor que 0';
  END IF;
  v_result := jsonb_set(v_result, '{irpf_porcentaje}', to_jsonb(round(v_number, 2)), true);

  IF v_result->'notas' <> 'null'::jsonb THEN
    IF jsonb_typeof(v_result->'notas') <> 'string'
       OR length(v_result->>'notas') > 5000 THEN
      RAISE EXCEPTION 'Las notas no pueden superar 5000 caracteres';
    END IF;
  END IF;

  IF v_result->'fecha_validez' <> 'null'::jsonb THEN
    IF jsonb_typeof(v_result->'fecha_validez') <> 'string' THEN
      RAISE EXCEPTION 'La fecha de validez debe ser texto ISO o null';
    END IF;
    BEGIN
      PERFORM (v_result->>'fecha_validez')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'La fecha de validez no es válida';
    END;
  END IF;

  RETURN v_result;
END;
$function$;
REVOKE ALL ON FUNCTION public.validate_quotation_workflow_content(jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rate_limit_quotation_workflow_field_changes(
  p_user_id uuid,
  p_old_content jsonb,
  p_new_content jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_field text;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  -- Límite general: 60 guardados por usuario/hora (se consume por operación).
  PERFORM public.enforce_security_rate_limit(
    'quotation_draft:save:' || p_user_id::text, 60, 3600
  );

  -- Cada campo editable dispone de su propio límite: 30 cambios por usuario/hora.
  -- Solo consume el límite de un campo si su valor cambia realmente.
  FOREACH v_field IN ARRAY ARRAY[
    'titulo', 'descripcion_detallada', 'servicios_incluidos',
    'iva_porcentaje', 'irpf_aplicado', 'irpf_porcentaje',
    'fecha_validez', 'notas'
  ]
  LOOP
    IF (p_old_content->v_field) IS DISTINCT FROM (p_new_content->v_field) THEN
      PERFORM public.enforce_security_rate_limit(
        'quotation_draft:field:' || v_field || ':' || p_user_id::text,
        30,
        3600
      );
    END IF;
  END LOOP;
END;
$function$;
REVOKE ALL ON FUNCTION public.rate_limit_quotation_workflow_field_changes(uuid,jsonb,jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Iniciar borrador nuevo o revisión. No modifica quotations.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_quotation_workflow_draft(
  p_project_id uuid,
  p_quotation_id uuid DEFAULT NULL,
  p_draft_kind text DEFAULT 'initial'
)
RETURNS public.quotation_workflow_drafts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_project public.projects%ROWTYPE;
  v_quotation public.quotations%ROWTYPE;
  v_state public.quotation_workflow_state%ROWTYPE;
  v_version public.quotation_official_versions%ROWTYPE;
  v_draft public.quotation_workflow_drafts%ROWTYPE;
  v_content jsonb;
  v_permission text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador autenticado';
  END IF;

  IF p_draft_kind IS NULL OR p_draft_kind NOT IN ('initial', 'correction', 'requested_change') THEN
    RAISE EXCEPTION 'Tipo de borrador no válido';
  END IF;

  IF p_draft_kind = 'initial' THEN
    IF p_quotation_id IS NOT NULL OR p_project_id IS NULL THEN
      RAISE EXCEPTION 'Un borrador inicial requiere proyecto y no puede tener presupuesto publicado';
    END IF;
    v_permission := 'quotations.create';
  ELSE
    IF p_quotation_id IS NULL THEN
      RAISE EXCEPTION 'La revisión requiere un presupuesto existente';
    END IF;
    v_permission := 'quotations.update';
  END IF;
  PERFORM public.require_current_worker_permission(v_permission);

  PERFORM public.enforce_security_rate_limit(
    'quotation_draft:start:' || auth.uid()::text, 20, 3600
  );

  IF p_draft_kind = 'initial' THEN
    SELECT * INTO v_project
    FROM public.projects
    WHERE id = p_project_id
    FOR SHARE;

    IF NOT FOUND OR v_project.company_id IS NULL OR v_project.user_id IS NULL THEN
      RAISE EXCEPTION 'El proyecto no existe o no tiene empresa/cliente válido';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_project.user_id) THEN
      RAISE EXCEPTION 'El cliente del proyecto no existe';
    END IF;

    v_content := public.validate_quotation_workflow_content('{}'::jsonb);
  ELSE
    SELECT * INTO v_quotation
    FROM public.quotations
    WHERE id = p_quotation_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Presupuesto no encontrado';
    END IF;

    IF p_project_id IS NOT NULL AND p_project_id <> v_quotation.project_id THEN
      RAISE EXCEPTION 'El proyecto no corresponde al presupuesto';
    END IF;

    SELECT * INTO v_project
    FROM public.projects
    WHERE id = v_quotation.project_id
    FOR SHARE;
    IF NOT FOUND OR v_project.company_id IS DISTINCT FROM v_quotation.company_id THEN
      RAISE EXCEPTION 'El proyecto no corresponde a la empresa del presupuesto';
    END IF;

    SELECT * INTO v_state
    FROM public.quotation_workflow_state
    WHERE quotation_id = p_quotation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El presupuesto todavía no utiliza el nuevo flujo de versiones';
    END IF;

    IF p_draft_kind = 'correction' AND v_state.workflow_status <> 'presented' THEN
      RAISE EXCEPTION 'Solo se puede preparar una corrección antes de la respuesta del cliente';
    END IF;
    IF p_draft_kind = 'requested_change' AND v_state.workflow_status <> 'in_review' THEN
      RAISE EXCEPTION 'No existe una solicitud de cambio pendiente de atender';
    END IF;

    SELECT * INTO v_version
    FROM public.quotation_official_versions
    WHERE id = v_state.current_version_id AND quotation_id = p_quotation_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No se encuentra la versión oficial actual';
    END IF;

    v_content := public.validate_quotation_workflow_content(
      jsonb_build_object(
        'titulo', COALESCE(v_version.content_snapshot->'titulo', '""'::jsonb),
        'descripcion_detallada', COALESCE(v_version.content_snapshot->'descripcion_detallada', 'null'::jsonb),
        'servicios_incluidos', COALESCE(v_version.content_snapshot->'servicios_incluidos', '[]'::jsonb),
        'iva_porcentaje', COALESCE(v_version.content_snapshot->'iva_porcentaje', '21'::jsonb),
        'irpf_aplicado', COALESCE(v_version.content_snapshot->'irpf_aplicado', 'false'::jsonb),
        'irpf_porcentaje', COALESCE(v_version.content_snapshot->'irpf_porcentaje', '0'::jsonb),
        'fecha_validez', COALESCE(v_version.content_snapshot->'fecha_validez', 'null'::jsonb),
        'notas', COALESCE(v_version.content_snapshot->'notas', 'null'::jsonb)
      )
    );
  END IF;

  IF p_quotation_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.quotation_workflow_drafts d
    WHERE d.quotation_id = p_quotation_id AND d.draft_status = 'draft'
  ) THEN
    RAISE EXCEPTION 'Ya existe un borrador activo para este presupuesto; recupera ese borrador';
  END IF;

  INSERT INTO public.quotation_workflow_drafts (
    company_id, project_id, quotation_id, created_by, draft_kind,
    draft_status, content, based_on_version_id
  )
  VALUES (
    v_project.company_id, v_project.id, p_quotation_id, auth.uid(), p_draft_kind,
    'draft', v_content, CASE WHEN p_quotation_id IS NOT NULL THEN v_version.id ELSE NULL END
  )
  RETURNING * INTO v_draft;

  RETURN v_draft;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Guardar borrador. Todos los campos editables pasan por rate limit propio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_quotation_workflow_draft(
  p_draft_id uuid,
  p_content jsonb
)
RETURNS public.quotation_workflow_drafts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_draft public.quotation_workflow_drafts%ROWTYPE;
  v_new_content jsonb;
  v_permission text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador autenticado';
  END IF;

  IF p_draft_id IS NULL THEN
    RAISE EXCEPTION 'El borrador es obligatorio';
  END IF;

  SELECT * INTO v_draft
  FROM public.quotation_workflow_drafts
  WHERE id = p_draft_id
  FOR UPDATE;

  IF NOT FOUND OR v_draft.draft_status <> 'draft' THEN
    RAISE EXCEPTION 'El borrador no existe o ya no se puede editar';
  END IF;

  v_permission := CASE WHEN v_draft.quotation_id IS NULL THEN 'quotations.create' ELSE 'quotations.update' END;
  PERFORM public.require_current_worker_permission(v_permission);

  v_new_content := public.validate_quotation_workflow_content(v_draft.content || COALESCE(p_content, '{}'::jsonb));
  PERFORM public.rate_limit_quotation_workflow_field_changes(auth.uid(), v_draft.content, v_new_content);

  UPDATE public.quotation_workflow_drafts
  SET content = v_new_content,
      updated_at = now()
  WHERE id = p_draft_id
  RETURNING * INTO v_draft;

  RETURN v_draft;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5b. Descartar un borrador interno que ya no se vaya a publicar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discard_quotation_workflow_draft(p_draft_id uuid)
RETURNS public.quotation_workflow_drafts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_draft public.quotation_workflow_drafts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador autenticado';
  END IF;

  SELECT * INTO v_draft
  FROM public.quotation_workflow_drafts
  WHERE id = p_draft_id
  FOR UPDATE;
  IF NOT FOUND OR v_draft.draft_status <> 'draft' THEN
    RAISE EXCEPTION 'El borrador no existe o ya no se puede descartar';
  END IF;

  IF v_draft.quotation_id IS NULL THEN
    PERFORM public.require_current_worker_permission('quotations.create');
  ELSE
    PERFORM public.require_current_worker_permission('quotations.update');
  END IF;

  PERFORM public.enforce_security_rate_limit(
    'quotation_draft:discard:' || auth.uid()::text, 20, 3600
  );

  UPDATE public.quotation_workflow_drafts
  SET draft_status = 'discarded', updated_at = now()
  WHERE id = p_draft_id
  RETURNING * INTO v_draft;

  RETURN v_draft;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Publicar borrador como nueva versión oficial.
--    p_publish_mode: initial | correction | requested_change
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.publish_quotation_workflow_draft(
  p_draft_id uuid,
  p_publish_mode text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_draft public.quotation_workflow_drafts%ROWTYPE;
  v_project public.projects%ROWTYPE;
  v_quotation public.quotations%ROWTYPE;
  v_state public.quotation_workflow_state%ROWTYPE;
  v_latest public.quotation_official_versions%ROWTYPE;
  v_version public.quotation_official_versions%ROWTYPE;
  v_content jsonb;
  v_major integer;
  v_minor integer;
  v_label text;
  v_permission text;
  v_fecha_validez timestamptz;
  v_fecha_emision timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT public.current_user_is_worker() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere un trabajador autenticado';
  END IF;
  IF p_publish_mode IS NULL OR p_publish_mode NOT IN ('initial', 'correction', 'requested_change') THEN
    RAISE EXCEPTION 'Modo de publicación no válido';
  END IF;

  SELECT * INTO v_draft
  FROM public.quotation_workflow_drafts
  WHERE id = p_draft_id
  FOR UPDATE;
  IF NOT FOUND OR v_draft.draft_status <> 'draft' THEN
    RAISE EXCEPTION 'El borrador no existe o ya ha sido publicado';
  END IF;
  IF v_draft.draft_kind <> p_publish_mode THEN
    RAISE EXCEPTION 'El modo de publicación no coincide con el tipo de borrador';
  END IF;

  v_permission := CASE WHEN p_publish_mode = 'initial' THEN 'quotations.create' ELSE 'quotations.update' END;
  PERFORM public.require_current_worker_permission(v_permission);
  PERFORM public.enforce_security_rate_limit(
    'quotation_workflow:publish:' || auth.uid()::text, 12, 3600
  );

  v_content := public.validate_quotation_workflow_content(v_draft.content);
  SELECT * INTO v_project FROM public.projects WHERE id = v_draft.project_id FOR SHARE;
  IF NOT FOUND OR v_project.company_id IS DISTINCT FROM v_draft.company_id THEN
    RAISE EXCEPTION 'El proyecto del borrador ya no es válido';
  END IF;

  IF NULLIF(btrim(v_content->>'titulo'), '') IS NULL THEN
    RAISE EXCEPTION 'El título es obligatorio para publicar';
  END IF;
  IF jsonb_typeof(v_content->'servicios_incluidos') <> 'array'
     OR jsonb_array_length(v_content->'servicios_incluidos') = 0 THEN
    RAISE EXCEPTION 'Debe existir al menos un servicio para publicar';
  END IF;

  IF v_content->'fecha_validez' IS NULL OR v_content->'fecha_validez' = 'null'::jsonb THEN
    v_fecha_validez := NULL;
  ELSE
    v_fecha_validez := (v_content->>'fecha_validez')::timestamptz;
  END IF;

  IF p_publish_mode = 'initial' THEN
    IF v_draft.quotation_id IS NOT NULL THEN
      RAISE EXCEPTION 'Un borrador inicial no puede estar vinculado a un presupuesto existente';
    END IF;

    v_quotation := public.create_quotation_by_worker(
      v_draft.company_id,
      v_draft.project_id,
      v_content->>'titulo',
      NULLIF(v_content->>'descripcion_detallada', ''),
      v_content->'servicios_incluidos',
      (v_content->>'iva_porcentaje')::numeric,
      (v_content->>'irpf_aplicado')::boolean,
      (v_content->>'irpf_porcentaje')::numeric,
      'Pendiente',
      now(),
      v_fecha_validez,
      NULLIF(v_content->>'notas', '')
    );

    v_major := 1;
    v_minor := 0;
  ELSE
    IF v_draft.quotation_id IS NULL THEN
      RAISE EXCEPTION 'El borrador no está vinculado a un presupuesto';
    END IF;

    SELECT * INTO v_quotation
    FROM public.quotations
    WHERE id = v_draft.quotation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Presupuesto no encontrado';
    END IF;
    IF v_quotation.estado <> 'Pendiente' THEN
      RAISE EXCEPTION 'Solo se puede publicar una versión de un presupuesto pendiente';
    END IF;

    SELECT * INTO v_state
    FROM public.quotation_workflow_state
    WHERE quotation_id = v_quotation.id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El presupuesto no dispone de estado de flujo';
    END IF;

    SELECT * INTO v_latest
    FROM public.quotation_official_versions
    WHERE id = v_state.current_version_id AND quotation_id = v_quotation.id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No se encuentra la versión oficial actual';
    END IF;

    IF p_publish_mode = 'correction' AND v_state.workflow_status <> 'presented' THEN
      RAISE EXCEPTION 'Una corrección solo puede publicarse mientras se espera la respuesta del cliente';
    ELSIF p_publish_mode = 'requested_change' AND v_state.workflow_status <> 'in_review' THEN
      RAISE EXCEPTION 'Solo se puede publicar una nueva versión si hay una solicitud de cambio pendiente';
    END IF;

    v_fecha_emision := v_quotation.fecha_emision;
    v_quotation := public.update_quotation_by_worker(
      v_quotation.id,
      v_draft.project_id,
      v_content->>'titulo',
      NULLIF(v_content->>'descripcion_detallada', ''),
      v_content->'servicios_incluidos',
      (v_content->>'iva_porcentaje')::numeric,
      (v_content->>'irpf_aplicado')::boolean,
      (v_content->>'irpf_porcentaje')::numeric,
      'Pendiente',
      v_fecha_emision,
      v_fecha_validez,
      NULLIF(v_content->>'notas', '')
    );

    IF p_publish_mode = 'requested_change' THEN
      v_major := v_latest.version_major + 1;
      v_minor := 0;
    ELSE
      v_major := v_latest.version_major;
      v_minor := v_latest.version_minor + 1;
    END IF;
  END IF;

  v_label := 'V' || v_major::text || CASE WHEN v_minor > 0 THEN '.' || v_minor::text ELSE '' END;

  UPDATE public.quotation_official_versions
  SET is_current = false
  WHERE quotation_id = v_quotation.id AND is_current = true;

  INSERT INTO public.quotation_official_versions (
    quotation_id, version_major, version_minor, version_label,
    content_snapshot, is_current, published_by, published_at
  )
  VALUES (
    v_quotation.id, v_major, v_minor, v_label,
    to_jsonb(v_quotation), true, auth.uid(), now()
  )
  RETURNING * INTO v_version;

  INSERT INTO public.quotation_workflow_state (
    quotation_id, current_version_id, workflow_status, updated_at, updated_by
  )
  VALUES (v_quotation.id, v_version.id, 'presented', now(), auth.uid())
  ON CONFLICT (quotation_id) DO UPDATE
    SET current_version_id = EXCLUDED.current_version_id,
        workflow_status = 'presented',
        updated_at = now(),
        updated_by = auth.uid();

  IF p_publish_mode = 'requested_change' THEN
    UPDATE public.quotation_change_requests
    SET request_status = 'resolved',
        resolved_at = now(),
        resolved_by = auth.uid(),
        resolved_version_id = v_version.id
    WHERE quotation_id = v_quotation.id AND request_status = 'open';
  END IF;

  UPDATE public.quotation_workflow_drafts
  SET quotation_id = v_quotation.id,
      draft_status = 'published',
      published_at = now(),
      published_version_id = v_version.id,
      updated_at = now()
  WHERE id = v_draft.id;

  RETURN jsonb_build_object(
    'quotation_id', v_quotation.id,
    'numero_presupuesto', v_quotation.numero_presupuesto,
    'version_id', v_version.id,
    'version_label', v_label,
    'workflow_status', 'presented',
    'quotation', to_jsonb(v_quotation)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. Adjuntar documento a una versión oficial. La Edge Function se actualizará
--    después para subir <company>/<numero>/<version_label>.pdf y llamar a este RPC.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_quotation_official_version_document(
  p_version_id uuid,
  p_document_path text,
  p_document_sha256 text
)
RETURNS public.quotation_official_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_version public.quotation_official_versions%ROWTYPE;
  v_quotation public.quotations%ROWTYPE;
  v_object storage.objects%ROWTYPE;
  v_expected_path text;
BEGIN
  IF public.current_worker_has_permission('quotations.update') THEN
    PERFORM public.require_current_worker_permission('quotations.update');
  ELSE
    PERFORM public.require_current_worker_permission('quotations.create');
  END IF;
  PERFORM public.enforce_security_rate_limit(
    'quotation_workflow:document:' || auth.uid()::text, 20, 3600
  );

  IF p_version_id IS NULL OR p_document_path IS NULL OR btrim(p_document_path) = '' THEN
    RAISE EXCEPTION 'La versión y la ruta del documento son obligatorias';
  END IF;
  IF p_document_sha256 IS NULL OR p_document_sha256 !~* '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'El SHA-256 del documento no es válido';
  END IF;

  SELECT * INTO v_version
  FROM public.quotation_official_versions
  WHERE id = p_version_id
  FOR UPDATE;
  IF NOT FOUND OR NOT v_version.is_current THEN
    RAISE EXCEPTION 'Solo se puede adjuntar el PDF a la versión oficial actual';
  END IF;

  SELECT * INTO v_quotation
  FROM public.quotations
  WHERE id = v_version.quotation_id
  FOR UPDATE;
  IF NOT FOUND OR v_quotation.estado <> 'Pendiente' THEN
    RAISE EXCEPTION 'El presupuesto no está disponible para adjuntar una versión documental';
  END IF;

  v_expected_path := v_quotation.company_id::text || '/' || v_quotation.numero_presupuesto || '/' || v_version.version_label || '.pdf';
  IF p_document_path <> v_expected_path THEN
    RAISE EXCEPTION 'La ruta del PDF no corresponde a la versión oficial indicada';
  END IF;

  SELECT * INTO v_object
  FROM storage.objects
  WHERE bucket_id = 'quotations' AND name = p_document_path;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El PDF no existe en el bucket quotations';
  END IF;
  IF lower(COALESCE(v_object.metadata->>'mimetype', '')) <> 'application/pdf' THEN
    RAISE EXCEPTION 'El documento debe ser un PDF';
  END IF;
  IF v_object.metadata ? 'size' AND (v_object.metadata->>'size') ~ '^[0-9]+$'
     AND (v_object.metadata->>'size')::bigint > 10485760 THEN
    RAISE EXCEPTION 'El PDF no puede superar 10 MiB';
  END IF;

  IF v_version.document_path IS NOT NULL
     AND (v_version.document_path IS DISTINCT FROM p_document_path
       OR v_version.document_sha256 IS DISTINCT FROM lower(p_document_sha256)) THEN
    RAISE EXCEPTION 'El documento de una versión oficial publicada es inmutable';
  END IF;

  UPDATE public.quotation_official_versions
  SET document_path = p_document_path,
      document_sha256 = lower(p_document_sha256)
  WHERE id = p_version_id
  RETURNING * INTO v_version;

  -- Mantener el documento actual de quotations alineado con la versión publicada.
  UPDATE public.quotations
  SET document_path = p_document_path,
      document_sha256 = lower(p_document_sha256),
      updated_at = now()
  WHERE id = v_quotation.id;

  -- Notificar solo cuando el PDF y su SHA-256 ya están registrados.
  -- client_notified_at evita duplicados si la Edge Function reintenta.
  IF v_version.client_notified_at IS NULL THEN
    PERFORM public.emit_project_client_notification(
      v_quotation.project_id,
      'quotation',
      'Nuevo presupuesto disponible',
      'Se ha publicado la versión ' || v_version.version_label || ' del presupuesto ' || COALESCE(v_quotation.numero_presupuesto, '') || '.',
      jsonb_build_object(
        'event', 'quotation_published',
        'quotation_id', v_quotation.id,
        'version_id', v_version.id,
        'version_label', v_version.version_label
      )
    );
    UPDATE public.quotation_official_versions
    SET client_notified_at = now()
    WHERE id = v_version.id
    RETURNING * INTO v_version;
  END IF;

  RETURN v_version;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. Solicitud formal de cambios del cliente: pasa a in_review y bloquea aceptar/
--    rechazar. La solicitud requiere texto y tiene rate limit propio.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_quotation_changes(
  p_quotation_id uuid,
  p_request_text text
)
RETURNS public.quotation_change_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_quotation public.quotations%ROWTYPE;
  v_state public.quotation_workflow_state%ROWTYPE;
  v_version public.quotation_official_versions%ROWTYPE;
  v_request public.quotation_change_requests%ROWTYPE;
  v_text text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Usuario no autenticado'; END IF;
  IF public.current_user_is_worker() THEN RAISE EXCEPTION 'Solo el cliente puede solicitar cambios'; END IF;
  IF NOT public.current_user_is_active() THEN RAISE EXCEPTION 'La cuenta no está activa'; END IF;

  v_text := btrim(COALESCE(p_request_text, ''));
  IF length(v_text) < 1 OR length(v_text) > 5000 THEN
    RAISE EXCEPTION 'Explica los cambios solicitados (máximo 5000 caracteres)';
  END IF;

  PERFORM public.enforce_security_rate_limit(
    'quotation_change_request:user:' || auth.uid()::text, 5, 3600
  );
  PERFORM public.enforce_security_rate_limit(
    'quotation_change_request:quotation:' || COALESCE(p_quotation_id::text, 'null') || ':' || auth.uid()::text,
    3,
    86400
  );

  SELECT * INTO v_quotation
  FROM public.quotations
  WHERE id = p_quotation_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Presupuesto no encontrado'; END IF;

  IF NOT (
    v_quotation.user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.clients c
      WHERE c.id = v_quotation.client_id AND c.profile_id = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'No tienes acceso a este presupuesto';
  END IF;

  SELECT * INTO v_state
  FROM public.quotation_workflow_state
  WHERE quotation_id = p_quotation_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Este presupuesto todavía no utiliza el nuevo flujo'; END IF;
  IF v_state.workflow_status <> 'presented' THEN
    RAISE EXCEPTION 'Solo se pueden solicitar cambios a una versión pendiente de respuesta';
  END IF;
  IF v_quotation.estado <> 'Pendiente' THEN
    RAISE EXCEPTION 'El presupuesto ya no admite solicitudes de cambio';
  END IF;

  SELECT * INTO v_version
  FROM public.quotation_official_versions
  WHERE id = v_state.current_version_id AND quotation_id = p_quotation_id AND is_current = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se encuentra la versión oficial actual'; END IF;
  IF v_version.document_path IS NULL OR v_version.document_sha256 IS NULL
     OR v_quotation.document_path IS DISTINCT FROM v_version.document_path
     OR lower(COALESCE(v_quotation.document_sha256, '')) IS DISTINCT FROM lower(COALESCE(v_version.document_sha256, '')) THEN
    RAISE EXCEPTION 'El PDF de la versión oficial no está generado o no coincide con su huella digital';
  END IF;

  INSERT INTO public.quotation_change_requests (
    quotation_id, official_version_id, requested_by, request_text
  ) VALUES (
    p_quotation_id, v_version.id, auth.uid(), v_text
  ) RETURNING * INTO v_request;

  UPDATE public.quotation_workflow_state
  SET workflow_status = 'in_review', updated_at = now(), updated_by = auth.uid()
  WHERE quotation_id = p_quotation_id;

  -- Si ya había una corrección interna en curso, conservar su contenido pero
  -- convertirla en el borrador que atenderá formalmente esta solicitud (V2, V3...).
  UPDATE public.quotation_workflow_drafts
  SET draft_kind = 'requested_change', updated_at = now()
  WHERE quotation_id = p_quotation_id
    AND draft_status = 'draft'
    AND draft_kind = 'correction';

  -- Notificar al trabajador que publicó la versión vigente.
  INSERT INTO public.notifications (user_id, project_id, tipo, titulo, mensaje, metadata)
  VALUES (
    v_version.published_by,
    v_quotation.project_id,
    'quotation',
    'Solicitud de cambios en presupuesto',
    'El cliente ha solicitado cambios en el presupuesto ' || COALESCE(v_quotation.numero_presupuesto, '') || '.',
    jsonb_build_object(
      'event', 'quotation_change_requested',
      'quotation_id', v_quotation.id,
      'version_id', v_version.id,
      'version_label', v_version.version_label,
      'change_request_id', v_request.id
    )
  );

  RETURN v_request;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 9. Respuesta cliente: preservar el RPC legal legacy, pero impedir respuestas
--    sobre una versión que esté en revisión. Los registros antiguos siguen usando
--    el flujo legacy sin necesidad de reconstruir su historial de prueba.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.respond_to_quotation(
  p_estado text,
  p_quotation_id uuid
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
DECLARE
  v_state public.quotation_workflow_state%ROWTYPE;
  v_version public.quotation_official_versions%ROWTYPE;
  v_quotation public.quotations%ROWTYPE;
  v_result public.quotations%ROWTYPE;
  v_action text;
BEGIN
  v_action := initcap(lower(btrim(COALESCE(p_estado, ''))));
  IF v_action NOT IN ('Aceptado', 'Rechazado') THEN
    RAISE EXCEPTION 'Respuesta no válida';
  END IF;

  -- Bloquear primero quotations y después el estado, en el mismo orden que
  -- request_quotation_changes/publish para reducir el riesgo de deadlocks.
  SELECT * INTO v_quotation
  FROM public.quotations
  WHERE id = p_quotation_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Presupuesto no encontrado'; END IF;

  -- Compatibilidad con presupuestos antiguos/no migrados.
  SELECT * INTO v_state
  FROM public.quotation_workflow_state
  WHERE quotation_id = p_quotation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    IF public.current_user_is_worker() THEN
      PERFORM public.require_current_worker_permission('quotations.update');
    END IF;
    RETURN public.respond_to_quotation__legacy_113(v_action, p_quotation_id);
  END IF;

  IF auth.uid() IS NULL OR public.current_user_is_worker() THEN
    RAISE EXCEPTION 'La respuesta formal debe realizarla el cliente autenticado';
  END IF;
  IF NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'La cuenta no está activa';
  END IF;
  IF v_state.workflow_status <> 'presented' THEN
    RAISE EXCEPTION 'No puedes responder mientras el presupuesto está en revisión o ya ha sido resuelto';
  END IF;

  IF NOT (
    v_quotation.user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.clients c
      WHERE c.id = v_quotation.client_id AND c.profile_id = auth.uid()
    )
  ) THEN
    RAISE EXCEPTION 'No tienes acceso a este presupuesto';
  END IF;

  SELECT * INTO v_version
  FROM public.quotation_official_versions
  WHERE id = v_state.current_version_id
    AND quotation_id = p_quotation_id
    AND is_current = true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se encuentra la versión oficial actual'; END IF;

  IF v_version.document_path IS NULL OR v_version.document_sha256 IS NULL
     OR v_quotation.document_path IS DISTINCT FROM v_version.document_path
     OR lower(COALESCE(v_quotation.document_sha256, '')) IS DISTINCT FROM lower(COALESCE(v_version.document_sha256, '')) THEN
    RAISE EXCEPTION 'El PDF de la versión oficial no está generado o no coincide con su huella digital';
  END IF;

  PERFORM public.enforce_security_rate_limit(
    'quotation_response:' || v_action || ':' || auth.uid()::text, 10, 3600
  );

  -- Mantiene las validaciones, el acuse PDF, la instantánea y la aceptación
  -- contractual de la función legacy actual.
  v_result := public.respond_to_quotation__legacy_113(v_action, p_quotation_id);

  UPDATE public.quotation_workflow_state
  SET workflow_status = CASE WHEN v_action = 'Aceptado' THEN 'accepted' ELSE 'rejected' END,
      updated_at = now(),
      updated_by = auth.uid()
  WHERE quotation_id = p_quotation_id;

  UPDATE public.quotation_official_versions
  SET client_response = v_action,
      responded_by = auth.uid(),
      responded_at = now()
  WHERE id = v_version.id;

  -- Notificación al trabajador que publicó la versión vigente.
  INSERT INTO public.notifications (user_id, project_id, tipo, titulo, mensaje, metadata)
  VALUES (
    v_version.published_by,
    v_quotation.project_id,
    'quotation',
    CASE WHEN v_action = 'Aceptado' THEN 'Presupuesto aceptado' ELSE 'Presupuesto rechazado' END,
    'El cliente ha ' || CASE WHEN v_action = 'Aceptado' THEN 'aceptado' ELSE 'rechazado' END
      || ' el presupuesto ' || COALESCE(v_quotation.numero_presupuesto, '')
      || ' (' || v_version.version_label || ').',
    jsonb_build_object(
      'event', CASE WHEN v_action = 'Aceptado' THEN 'quotation_accepted' ELSE 'quotation_rejected' END,
      'quotation_id', v_quotation.id,
      'version_id', v_version.id,
      'version_label', v_version.version_label
    )
  );

  RETURN v_result;
END;
$function$;

-- La función legacy solo debe invocarse internamente desde el wrapper protegido.
REVOKE ALL ON FUNCTION public.respond_to_quotation__legacy_113(text, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 10. Protección de inmutabilidad de las versiones oficiales.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_quotation_official_version_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF OLD.quotation_id IS DISTINCT FROM NEW.quotation_id
     OR OLD.version_major IS DISTINCT FROM NEW.version_major
     OR OLD.version_minor IS DISTINCT FROM NEW.version_minor
     OR OLD.version_label IS DISTINCT FROM NEW.version_label
     OR OLD.content_snapshot IS DISTINCT FROM NEW.content_snapshot
     OR OLD.published_by IS DISTINCT FROM NEW.published_by
     OR OLD.published_at IS DISTINCT FROM NEW.published_at THEN
    RAISE EXCEPTION 'El contenido y la identidad de una versión oficial son inmutables';
  END IF;

  IF OLD.document_path IS NOT NULL
     AND (OLD.document_path IS DISTINCT FROM NEW.document_path
       OR OLD.document_sha256 IS DISTINCT FROM NEW.document_sha256) THEN
    RAISE EXCEPTION 'El PDF y el hash de una versión oficial publicada son inmutables';
  END IF;

  IF OLD.client_response IS NOT NULL
     AND (OLD.client_response IS DISTINCT FROM NEW.client_response
       OR OLD.responded_by IS DISTINCT FROM NEW.responded_by
       OR OLD.responded_at IS DISTINCT FROM NEW.responded_at) THEN
    RAISE EXCEPTION 'La respuesta del cliente sobre una versión oficial es inmutable';
  END IF;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.protect_quotation_official_version_immutability() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS quotation_official_versions_immutable ON public.quotation_official_versions;
CREATE TRIGGER quotation_official_versions_immutable
BEFORE UPDATE ON public.quotation_official_versions
FOR EACH ROW EXECUTE FUNCTION public.protect_quotation_official_version_immutability();

-- ---------------------------------------------------------------------------
-- 11. Storage: admitir rutas versionadas sin dejar de admitir las antiguas.
--     El path versionado solo se autoriza si la versión existe en BD.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.worker_can_write_quotation_storage_path(p_storage_path text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
  v_allowed boolean := false;
BEGIN
  IF auth.uid() IS NULL OR NOT public.current_user_is_worker() OR p_storage_path IS NULL THEN
    RETURN false;
  END IF;

  -- Ruta histórica: <company_uuid>/<numero_presupuesto>.pdf
  IF p_storage_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]+\.pdf$' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.quotations q
      WHERE q.company_id::text || '/' || q.numero_presupuesto || '.pdf' = p_storage_path
    ) INTO v_allowed;
    IF v_allowed THEN RETURN true; END IF;
  END IF;

  -- Ruta nueva: <company_uuid>/<numero_presupuesto>/Vn[.m].pdf
  IF p_storage_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]+/v[1-9][0-9]*(\.[1-9][0-9]*)?\.pdf$' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.quotation_official_versions ov
      JOIN public.quotations q ON q.id = ov.quotation_id
      WHERE lower(q.company_id::text || '/' || q.numero_presupuesto || '/' || ov.version_label || '.pdf') = lower(p_storage_path)
        AND (
          public.current_worker_has_permission('quotations.update')
          OR public.current_worker_has_permission('quotations.create')
        )
    ) INTO v_allowed;
    IF v_allowed THEN RETURN true; END IF;
  END IF;

  RETURN false;
END;
$function$;

-- El cliente puede leer PDFs históricos oficiales además del documento actual.
DROP POLICY IF EXISTS quotation_version_documents_client_select ON storage.objects;
CREATE POLICY quotation_version_documents_client_select
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'quotations'
  AND public.current_user_is_active()
  AND NOT public.current_user_is_worker()
  AND EXISTS (
    SELECT 1
    FROM public.quotation_official_versions ov
    JOIN public.quotations q ON q.id = ov.quotation_id
    WHERE ov.document_path = storage.objects.name
      AND ov.document_sha256 IS NOT NULL
      AND (
        q.user_id = auth.uid()
        OR EXISTS (
          SELECT 1 FROM public.clients c
          WHERE c.id = q.client_id AND c.profile_id = auth.uid()
        )
      )
  )
);

-- ---------------------------------------------------------------------------
-- 12. Privilegios de RPC: solo authenticated. El helper de validación/rate-limit
--     permanece interno. Las escrituras de tablas se realizan mediante SECURITY DEFINER.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.start_quotation_workflow_draft(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_quotation_workflow_draft(uuid, uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.save_quotation_workflow_draft(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_quotation_workflow_draft(uuid, jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.publish_quotation_workflow_draft(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_quotation_workflow_draft(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.discard_quotation_workflow_draft(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.discard_quotation_workflow_draft(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.set_quotation_official_version_document(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_quotation_official_version_document(uuid, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.request_quotation_changes(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_quotation_changes(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.respond_to_quotation(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_quotation(text, uuid) TO authenticated;

-- No se concede INSERT/UPDATE/DELETE directo sobre las tablas de workflow.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON public.quotation_workflow_drafts,
   public.quotation_official_versions,
   public.quotation_workflow_state,
   public.quotation_change_requests
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.quotation_workflow_drafts,
                public.quotation_official_versions,
                public.quotation_workflow_state,
                public.quotation_change_requests
TO authenticated;


GRANT SELECT
ON TABLE public.quotation_official_versions
TO authenticated;


GRANT SELECT ON TABLE
    public.quotation_official_versions,
    public.quotation_workflow_state,
    public.quotation_workflow_drafts,
    public.quotation_change_requests
TO authenticated;

GRANT SELECT ON TABLE public.quotation_official_versions
TO service_role;

COMMIT;

-- ============================================================================
-- FIN MIGRACIÓN 150
-- ============================================================================
