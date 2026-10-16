BEGIN;

-- ============================================================
-- MODIRA — 045_quotations_worker_write_hardening.sql
--
-- OBJETIVO
-- ------------------------------------------------------------
-- Sustituir la escritura directa de quotations por una única
-- RPC SECURITY DEFINER para trabajadores activos.
--
-- PRINCIPIOS:
-- 1. El frontend NO puede insertar/editar/eliminar quotations
--    directamente.
-- 2. La identidad del trabajador se obtiene exclusivamente de
--    auth.uid().
-- 3. company_id, user_id y client_id NO se confían al cliente:
--    company_id se valida contra el proyecto, user_id y client_id
--    se derivan del proyecto.
-- 4. numero_presupuesto lo genera el DEFAULT existente
--    generate_quotation_number().
-- 5. Los importes se calculan en backend a partir de
--    servicios_incluidos, IVA e IRPF.
-- 6. La RPC queda disponible únicamente para authenticated.
-- 7. Se mantienen las operaciones de lectura y las RPC existentes
--    de respuesta/documentación.
--
-- IMPORTANTE:
-- Esta migración NO modifica diseño ni frontend.
-- El frontend debe llamar a create_quotation_by_worker()
-- para crear presupuestos.
-- ============================================================


-- ============================================================
-- 1. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: public.quotations does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'projects'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: public.projects does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'clients'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: public.clients does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: public.workers does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'numero_presupuesto'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: quotations.numero_presupuesto does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'irpf_aplicado'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: quotations.irpf_aplicado does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'irpf_porcentaje'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: quotations.irpf_porcentaje does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'quotations'
          AND column_name = 'irpf_importe'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: quotations.irpf_importe does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'company_id'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: projects.company_id does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'user_id'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: projects.user_id does not exist';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'projects'
          AND column_name = 'client_id'
    ) THEN
        RAISE EXCEPTION
            '045 stopped: projects.client_id does not exist';
    END IF;

    IF to_regprocedure('public.current_user_is_worker()') IS NULL THEN
        RAISE EXCEPTION
            '045 stopped: current_user_is_worker() does not exist';
    END IF;

    IF to_regprocedure('public.generate_quotation_number()') IS NULL THEN
        RAISE EXCEPTION
            '045 stopped: generate_quotation_number() does not exist';
    END IF;
END $$;


-- ============================================================
-- 2. FUNCIÓN DE CREACIÓN SEGURA
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_quotation_by_worker(
    p_company_id UUID,
    p_project_id UUID,
    p_titulo TEXT,
    p_descripcion_detallada TEXT,
    p_servicios_incluidos JSONB,
    p_iva_porcentaje NUMERIC,
    p_irpf_aplicado BOOLEAN,
    p_irpf_porcentaje NUMERIC,
    p_estado TEXT,
    p_fecha_emision TIMESTAMPTZ,
    p_fecha_validez TIMESTAMPTZ,
    p_notas TEXT
)
RETURNS public.quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_quotation public.quotations;
    v_project public.projects%ROWTYPE;

    v_title TEXT;
    v_description TEXT;
    v_notes TEXT;
    v_state TEXT;

    v_iva NUMERIC(5,2);
    v_irpf NUMERIC(5,2);
    v_irpf_applied BOOLEAN;

    v_subtotal NUMERIC(12,2);
    v_iva_importe NUMERIC(12,2);
    v_irpf_importe NUMERIC(12,2);
    v_total NUMERIC(12,2);

    v_service JSONB;
    v_service_description TEXT;
    v_quantity NUMERIC;
    v_price NUMERIC;

    v_fecha_emision TIMESTAMPTZ;
    v_fecha_validez TIMESTAMPTZ;
BEGIN

    -- ========================================================
    -- 1. AUTENTICACIÓN + WORKER ACTIVO
    -- ========================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado';
    END IF;

    IF NOT public.current_user_is_worker() THEN
        RAISE EXCEPTION
            'Acceso denegado: se requiere un trabajador activo';
    END IF;


    -- ========================================================
    -- 2. VALIDAR IDENTIFICADORES
    -- ========================================================

    IF p_company_id IS NULL THEN
        RAISE EXCEPTION
            'La empresa es obligatoria';
    END IF;

    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto es obligatorio';
    END IF;


    -- ========================================================
    -- 3. OBTENER PROYECTO Y DERIVAR RELACIONES
    --
    -- Nunca confiamos en user_id/client_id enviados por frontend.
    -- ========================================================

    SELECT *
    INTO v_project
    FROM public.projects
    WHERE id = p_project_id
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El proyecto seleccionado no existe';
    END IF;

    IF v_project.company_id IS NULL
       OR v_project.company_id <> p_company_id THEN
        RAISE EXCEPTION
            'El proyecto no pertenece a la empresa seleccionada';
    END IF;

    IF v_project.user_id IS NULL THEN
        RAISE EXCEPTION
            'El proyecto no tiene un usuario propietario válido';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM auth.users u
        WHERE u.id = v_project.user_id
    ) THEN
        RAISE EXCEPTION
            'El propietario del proyecto no existe';
    END IF;



    IF v_project.client_id IS NOT NULL
       AND NOT EXISTS (
            SELECT 1
            FROM public.clients c
            WHERE c.id = v_project.client_id
              AND c.company_id = v_project.company_id
       ) THEN
        RAISE EXCEPTION
            'El cliente del proyecto no pertenece a la empresa';
    END IF;


    -- ========================================================
    -- 4. VALIDAR TEXTO
    -- ========================================================

    v_title := NULLIF(BTRIM(p_titulo), '');

    IF v_title IS NULL THEN
        RAISE EXCEPTION
            'El título del presupuesto es obligatorio';
    END IF;

    IF LENGTH(v_title) > 300 THEN
        RAISE EXCEPTION
            'El título no puede superar 300 caracteres';
    END IF;

    v_description := NULLIF(BTRIM(COALESCE(p_descripcion_detallada, '')), '');

    IF v_description IS NOT NULL
       AND LENGTH(v_description) > 10000 THEN
        RAISE EXCEPTION
            'La descripción del presupuesto no puede superar 10000 caracteres';
    END IF;

    v_notes := NULLIF(BTRIM(COALESCE(p_notas, '')), '');

    IF v_notes IS NOT NULL
       AND LENGTH(v_notes) > 10000 THEN
        RAISE EXCEPTION
            'Las notas del presupuesto no pueden superar 10000 caracteres';
    END IF;


    -- ========================================================
    -- 5. VALIDAR ESTADO
    -- ========================================================

    v_state :=
        INITCAP(
            LOWER(
                BTRIM(
                    COALESCE(p_estado, 'Pendiente')
                )
            )
        );

    IF v_state NOT IN (
        'Pendiente',
        'Aceptado',
        'Rechazado'
    ) THEN
        RAISE EXCEPTION
            'Estado de presupuesto no válido';
    END IF;


    -- ========================================================
    -- 6. VALIDAR IVA / IRPF
    -- ========================================================

    v_iva := ROUND(COALESCE(p_iva_porcentaje, 0), 2);

    IF v_iva < 0 OR v_iva > 100 THEN
        RAISE EXCEPTION
            'El porcentaje de IVA debe estar entre 0 y 100';
    END IF;

    v_irpf_applied := COALESCE(p_irpf_aplicado, FALSE);
    v_irpf := ROUND(COALESCE(p_irpf_porcentaje, 0), 2);

    IF NOT v_irpf_applied THEN
        IF v_irpf <> 0 THEN
            RAISE EXCEPTION
                'Si el IRPF no se aplica, el porcentaje debe ser 0';
        END IF;
        v_irpf := 0;
    ELSE
        IF v_irpf <= 0 OR v_irpf > 100 THEN
            RAISE EXCEPTION
                'El porcentaje de IRPF debe ser mayor que 0 y menor o igual que 100';
        END IF;
    END IF;


    -- ========================================================
    -- 7. VALIDAR SERVICIOS
    --
    -- Se recalcula el subtotal en backend.
    -- Nunca se confía en precio_base/precio_total del cliente.
    -- ========================================================

    IF p_servicios_incluidos IS NULL
       OR jsonb_typeof(p_servicios_incluidos) <> 'array' THEN
        RAISE EXCEPTION
            'Los servicios incluidos deben ser un array JSON';
    END IF;

    IF jsonb_array_length(p_servicios_incluidos) = 0 THEN
        RAISE EXCEPTION
            'Debe existir al menos un servicio';
    END IF;

    IF jsonb_array_length(p_servicios_incluidos) > 100 THEN
        RAISE EXCEPTION
            'El presupuesto no puede contener más de 100 servicios';
    END IF;

    v_subtotal := 0;

    FOR v_service IN
        SELECT value
        FROM jsonb_array_elements(p_servicios_incluidos)
    LOOP

        IF jsonb_typeof(v_service) <> 'object' THEN
            RAISE EXCEPTION
                'Cada servicio debe ser un objeto JSON';
        END IF;

        v_service_description :=
            NULLIF(
                BTRIM(
                    COALESCE(
                        v_service->>'descripcion',
                        ''
                    )
                ),
                ''
            );

        IF v_service_description IS NULL THEN
            RAISE EXCEPTION
                'Todos los servicios deben tener una descripción';
        END IF;

        IF LENGTH(v_service_description) > 2000 THEN
            RAISE EXCEPTION
                'La descripción de un servicio no puede superar 2000 caracteres';
        END IF;

        IF NOT (v_service ? 'cantidad')
           OR NOT (v_service ? 'precio') THEN
            RAISE EXCEPTION
                'Cada servicio debe contener cantidad y precio';
        END IF;

        BEGIN
            v_quantity := (v_service->>'cantidad')::NUMERIC;
            v_price := (v_service->>'precio')::NUMERIC;
        EXCEPTION
            WHEN invalid_text_representation
              OR numeric_value_out_of_range THEN
                RAISE EXCEPTION
                    'Cantidad o precio de servicio no válidos';
        END;

        IF v_quantity IS NULL
           OR v_quantity <= 0
           OR v_quantity > 1000000 THEN
            RAISE EXCEPTION
                'La cantidad de un servicio debe ser mayor que 0';
        END IF;

        IF v_price IS NULL
           OR v_price < 0
           OR v_price > 100000000 THEN
            RAISE EXCEPTION
                'El precio de un servicio no puede ser negativo';
        END IF;

        v_subtotal :=
            v_subtotal
            + ROUND(v_quantity * v_price, 2);

        IF v_subtotal > 1000000000 THEN
            RAISE EXCEPTION
                'El importe total del presupuesto supera el límite permitido';
        END IF;

    END LOOP;

    v_subtotal := ROUND(v_subtotal, 2);


    -- ========================================================
    -- 8. CALCULAR IMPORTES FISCALES EN BACKEND
    -- ========================================================

    v_iva_importe :=
        ROUND(
            v_subtotal * (v_iva / 100),
            2
        );

    IF v_irpf_applied THEN
        v_irpf_importe :=
            ROUND(
                v_subtotal * (v_irpf / 100),
                2
            );
    ELSE
        v_irpf_importe := 0;
    END IF;

    v_total :=
        ROUND(
            v_subtotal
            + v_iva_importe
            - v_irpf_importe,
            2
        );

    IF v_total < 0 THEN
        RAISE EXCEPTION
            'El total del presupuesto no puede ser negativo';
    END IF;


    -- ========================================================
    -- 9. FECHAS
    -- ========================================================

    v_fecha_emision :=
        COALESCE(
            p_fecha_emision,
            CURRENT_TIMESTAMP
        );

    v_fecha_validez :=
        p_fecha_validez;


    -- ========================================================
    -- 10. INSERT
    --
    -- NO recibimos:
    --   id
    --   user_id
    --   client_id
    --   numero_presupuesto
    --   precio_base
    --   precio_total
    --
    -- user_id/client_id se derivan del proyecto.
    -- numero_presupuesto lo genera su DEFAULT.
    -- importes se calculan aquí.
    -- ========================================================

    INSERT INTO public.quotations (
        company_id,
        user_id,
        project_id,
        client_id,
        titulo,
        descripcion_detallada,
        servicios_incluidos,
        precio_base,
        iva_porcentaje,
        precio_total,
        irpf_aplicado,
        irpf_porcentaje,
        irpf_importe,
        estado,
        fecha_emision,
        fecha_validez,
        notas
    )
    VALUES (
        v_project.company_id,
        v_project.user_id,
        v_project.id,
        v_project.client_id,
        v_title,
        v_description,
        p_servicios_incluidos,
        v_subtotal,
        v_iva,
        v_total,
        v_irpf_applied,
        v_irpf,
        v_irpf_importe,
        v_state,
        v_fecha_emision,
        v_fecha_validez,
        v_notes
    )
    RETURNING *
    INTO v_quotation;


    RETURN v_quotation;

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION
            'No se pudo generar el presupuesto por un conflicto de unicidad';
END;
$function$;


-- ============================================================
-- 3. ENDURECER PERMISOS DE LA RPC
-- ============================================================

REVOKE ALL
ON FUNCTION public.create_quotation_by_worker(
    UUID,
    UUID,
    TEXT,
    TEXT,
    JSONB,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    TEXT,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT
)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.create_quotation_by_worker(
    UUID,
    UUID,
    TEXT,
    TEXT,
    JSONB,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    TEXT,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT
)
TO authenticated;

ALTER FUNCTION public.create_quotation_by_worker(
    UUID,
    UUID,
    TEXT,
    TEXT,
    JSONB,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    TEXT,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT
)
SET search_path = public, pg_temp;


-- ============================================================
-- 4. ELIMINAR ESCRITURA DIRECTA SOBRE QUOTATIONS
-- ============================================================

DROP POLICY IF EXISTS quotations_worker_insert
ON public.quotations;

DROP POLICY IF EXISTS quotations_worker_update
ON public.quotations;

DROP POLICY IF EXISTS quotations_worker_delete
ON public.quotations;

REVOKE INSERT, UPDATE, DELETE
ON public.quotations
FROM anon, authenticated;


-- ============================================================
-- 5. ASEGURAR QUE EL CLIENTE SOLO PUEDE LEER SU EMPRESA
-- ============================================================

DROP POLICY IF EXISTS quotations_company_select
ON public.quotations;

DROP POLICY IF EXISTS quotations_company_access
ON public.quotations;

DROP POLICY IF EXISTS quotations_company_access
ON public.quotations;

CREATE POLICY quotations_company_access
ON public.quotations
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND user_id = auth.uid()
);


-- ============================================================
-- 6. ASEGURAR SELECT PARA WORKERS ACTIVOS
-- ============================================================

DROP POLICY IF EXISTS quotations_worker_select
ON public.quotations;

CREATE POLICY quotations_worker_select
ON public.quotations
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
);


-- ============================================================
-- 7. PERMISOS DE TABLA
-- ============================================================

GRANT SELECT
ON public.quotations
TO authenticated;

REVOKE INSERT, UPDATE, DELETE
ON public.quotations
FROM authenticated, anon;


-- ============================================================
-- 8. COMPROBACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
    v_has_insert BOOLEAN;
    v_has_update BOOLEAN;
    v_has_delete BOOLEAN;
BEGIN

    -- --------------------------------------------------------
    -- RPC
    -- --------------------------------------------------------

    IF to_regprocedure(
        'public.create_quotation_by_worker(uuid,uuid,text,text,jsonb,numeric,boolean,numeric,text,timestamptz,timestamptz,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            '045 failed: create_quotation_by_worker() is missing';
    END IF;


    -- --------------------------------------------------------
    -- RLS
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_class
    WHERE oid = 'public.quotations'::regclass
      AND relrowsecurity = TRUE;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '045 failed: RLS is not enabled on quotations';
    END IF;


    -- --------------------------------------------------------
    -- No direct INSERT policy
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'quotations'
      AND policyname = 'quotations_worker_insert';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '045 failed: direct worker INSERT policy still exists';
    END IF;


    -- --------------------------------------------------------
    -- No direct UPDATE policy
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'quotations'
      AND policyname = 'quotations_worker_update';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '045 failed: direct worker UPDATE policy still exists';
    END IF;


    -- --------------------------------------------------------
    -- No direct DELETE policy
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'quotations'
      AND policyname = 'quotations_worker_delete';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '045 failed: direct worker DELETE policy still exists';
    END IF;


    -- --------------------------------------------------------
    -- authenticated no conserva escrituras directas
    -- --------------------------------------------------------

    v_has_insert :=
        has_table_privilege(
            'authenticated',
            'public.quotations',
            'INSERT'
        );

    v_has_update :=
        has_table_privilege(
            'authenticated',
            'public.quotations',
            'UPDATE'
        );

    v_has_delete :=
        has_table_privilege(
            'authenticated',
            'public.quotations',
            'DELETE'
        );

    IF v_has_insert OR v_has_update OR v_has_delete THEN
        RAISE EXCEPTION
            '045 failed: authenticated conserva privilegios directos de escritura sobre quotations';
    END IF;


    -- --------------------------------------------------------
    -- SELECT sí debe existir
    -- --------------------------------------------------------

    IF NOT has_table_privilege(
        'authenticated',
        'public.quotations',
        'SELECT'
    ) THEN
        RAISE EXCEPTION
            '045 failed: authenticated perdió SELECT sobre quotations';
    END IF;


    -- --------------------------------------------------------
    -- Policies SELECT
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'quotations'
      AND policyname IN (
          'quotations_company_access',
          'quotations_worker_select'
      );

    IF v_count <> 2 THEN
        RAISE EXCEPTION
            '045 failed: SELECT policies de quotations incompletas';
    END IF;

END $$;


-- ============================================================
-- 9. DOCUMENTACIÓN
-- ============================================================

COMMENT ON FUNCTION public.create_quotation_by_worker(
    UUID,
    UUID,
    TEXT,
    TEXT,
    JSONB,
    NUMERIC,
    BOOLEAN,
    NUMERIC,
    TEXT,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT
)
IS
'Permite a un trabajador activo crear un presupuesto. La identidad del usuario y el cliente se derivan del proyecto; el numero_presupuesto lo genera el DEFAULT existente; los importes se recalculan en backend.';


COMMIT;
