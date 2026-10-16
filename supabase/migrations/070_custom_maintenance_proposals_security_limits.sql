BEGIN;

-- ============================================================
-- MODIRA — 070_custom_maintenance_proposals_security_limits.sql
-- ============================================================
--
-- Refuerza la seguridad de 069_custom_maintenance_proposals.sql
-- sin modificar su flujo funcional.
--
-- CAPAS:
-- 1. Límite de longitud por campo.
-- 2. Límite total de palabras de la solicitud.
-- 3. Límite de tamaño de request_data.
-- 4. Límite de horas mensuales solicitadas.
-- 5. Máximo de 3 propuestas creadas por empresa en 24 horas.
-- 6. Máximo de 3 envíos de propuestas por empresa en 24 horas.
-- 7. Mantiene la restricción existente de una propuesta abierta.
--
-- IMPORTANTE:
-- Esta migración es un parche posterior a 069.
-- NO modifica ni recrea las RPC de 069.
-- ============================================================


-- ============================================================
-- 1. CONSTANTES DE SEGURIDAD
-- ============================================================

-- Máximo de propuestas nuevas por empresa en una ventana de 24 h.
-- La ventana es móvil, no por día natural.
CREATE OR REPLACE FUNCTION public.maintenance_custom_proposal_security_limits()
RETURNS TABLE (
    max_creations_24h INTEGER,
    max_submissions_24h INTEGER,
    max_total_words INTEGER,
    max_request_data_bytes INTEGER,
    max_hours_monthly NUMERIC
)
LANGUAGE SQL
IMMUTABLE
AS $function$
    SELECT
        3,
        3,
        15000,
        65536,
        744::NUMERIC;
$function$;


-- ============================================================
-- 2. FUNCIÓN DE VALIDACIÓN DE CONTENIDO
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_custom_maintenance_proposal_content()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_limits RECORD;
    v_total_words INTEGER := 0;
    v_request_data_bytes INTEGER := 0;
    v_text TEXT;
BEGIN

    SELECT *
    INTO v_limits
    FROM public.maintenance_custom_proposal_security_limits();

    -- --------------------------------------------------------
    -- TÍTULO
    -- --------------------------------------------------------

    IF NEW.titulo IS NULL
       OR LENGTH(BTRIM(NEW.titulo)) = 0
    THEN
        RAISE EXCEPTION
            'El título de la propuesta es obligatorio';
    END IF;

    IF LENGTH(NEW.titulo) > 300 THEN
        RAISE EXCEPTION
            'El título no puede superar 300 caracteres';
    END IF;


    -- --------------------------------------------------------
    -- CAMPOS DE TEXTO DEL CLIENTE
    -- --------------------------------------------------------

    IF NEW.descripcion_necesidad IS NOT NULL
       AND LENGTH(NEW.descripcion_necesidad) > 6000
    THEN
        RAISE EXCEPTION
            'La descripción de la necesidad no puede superar 6000 caracteres';
    END IF;

    IF NEW.objetivos IS NOT NULL
       AND LENGTH(NEW.objetivos) > 5000
    THEN
        RAISE EXCEPTION
            'Los objetivos no pueden superar 5000 caracteres';
    END IF;

    IF NEW.prioridades IS NOT NULL
       AND LENGTH(NEW.prioridades) > 4000
    THEN
        RAISE EXCEPTION
            'Las prioridades no pueden superar 4000 caracteres';
    END IF;

    IF NEW.soluciones_actuales IS NOT NULL
       AND LENGTH(NEW.soluciones_actuales) > 6000
    THEN
        RAISE EXCEPTION
            'Las soluciones actuales no pueden superar 6000 caracteres';
    END IF;

    IF NEW.proyectos_relacionados IS NOT NULL
       AND LENGTH(NEW.proyectos_relacionados) > 5000
    THEN
        RAISE EXCEPTION
            'Los proyectos relacionados no pueden superar 5000 caracteres';
    END IF;

    IF NEW.automatizaciones_actuales IS NOT NULL
       AND LENGTH(NEW.automatizaciones_actuales) > 6000
    THEN
        RAISE EXCEPTION
            'Las automatizaciones actuales no pueden superar 6000 caracteres';
    END IF;

    IF NEW.integraciones_actuales IS NOT NULL
       AND LENGTH(NEW.integraciones_actuales) > 6000
    THEN
        RAISE EXCEPTION
            'Las integraciones actuales no pueden superar 6000 caracteres';
    END IF;

    IF NEW.tecnologias IS NOT NULL
       AND LENGTH(NEW.tecnologias) > 4000
    THEN
        RAISE EXCEPTION
            'Las tecnologías no pueden superar 4000 caracteres';
    END IF;

    IF NEW.sistemas_criticos IS NOT NULL
       AND LENGTH(NEW.sistemas_criticos) > 6000
    THEN
        RAISE EXCEPTION
            'Los sistemas críticos no pueden superar 6000 caracteres';
    END IF;

    IF NEW.alcance_tecnico_solicitado IS NOT NULL
       AND LENGTH(NEW.alcance_tecnico_solicitado) > 8000
    THEN
        RAISE EXCEPTION
            'El alcance técnico no puede superar 8000 caracteres';
    END IF;

    IF NEW.tipo_trabajo IS NOT NULL
       AND LENGTH(NEW.tipo_trabajo) > 500
    THEN
        RAISE EXCEPTION
            'El tipo de trabajo no puede superar 500 caracteres';
    END IF;

    IF NEW.nivel_soporte_solicitado IS NOT NULL
       AND LENGTH(NEW.nivel_soporte_solicitado) > 1000
    THEN
        RAISE EXCEPTION
            'El nivel de soporte no puede superar 1000 caracteres';
    END IF;

    IF NEW.tiempo_respuesta_deseado IS NOT NULL
       AND LENGTH(NEW.tiempo_respuesta_deseado) > 1000
    THEN
        RAISE EXCEPTION
            'El tiempo de respuesta no puede superar 1000 caracteres';
    END IF;

    IF NEW.horario_soporte IS NOT NULL
       AND LENGTH(NEW.horario_soporte) > 1500
    THEN
        RAISE EXCEPTION
            'El horario de soporte no puede superar 1500 caracteres';
    END IF;

    IF NEW.sla_solicitado IS NOT NULL
       AND LENGTH(NEW.sla_solicitado) > 2000
    THEN
        RAISE EXCEPTION
            'El SLA solicitado no puede superar 2000 caracteres';
    END IF;

    IF NEW.nivel_criticidad IS NOT NULL
       AND LENGTH(NEW.nivel_criticidad) > 1000
    THEN
        RAISE EXCEPTION
            'El nivel de criticidad no puede superar 1000 caracteres';
    END IF;

    IF NEW.impacto_incidencia IS NOT NULL
       AND LENGTH(NEW.impacto_incidencia) > 3000
    THEN
        RAISE EXCEPTION
            'El impacto de una incidencia no puede superar 3000 caracteres';
    END IF;

    IF NEW.requisitos_seguridad IS NOT NULL
       AND LENGTH(NEW.requisitos_seguridad) > 6000
    THEN
        RAISE EXCEPTION
            'Los requisitos de seguridad no pueden superar 6000 caracteres';
    END IF;

    IF NEW.informacion_adicional IS NOT NULL
       AND LENGTH(NEW.informacion_adicional) > 6000
    THEN
        RAISE EXCEPTION
            'La información adicional no puede superar 6000 caracteres';
    END IF;


    -- --------------------------------------------------------
    -- HORAS MENSUALES
    -- --------------------------------------------------------

    IF NEW.horas_mensuales_solicitadas IS NOT NULL THEN

        IF NEW.horas_mensuales_solicitadas <= 0 THEN
            RAISE EXCEPTION
                'Las horas mensuales solicitadas deben ser mayores que 0';
        END IF;

        IF NEW.horas_mensuales_solicitadas > v_limits.max_hours_monthly THEN
            RAISE EXCEPTION
                'Las horas mensuales solicitadas no pueden superar % horas',
                v_limits.max_hours_monthly;
        END IF;

    END IF;


    -- --------------------------------------------------------
    -- REQUEST_DATA
    -- --------------------------------------------------------

    IF NEW.request_data IS NULL
       OR jsonb_typeof(NEW.request_data) <> 'object'
    THEN
        RAISE EXCEPTION
            'request_data debe ser un objeto JSON';
    END IF;

    v_request_data_bytes := pg_column_size(NEW.request_data);

    IF v_request_data_bytes > v_limits.max_request_data_bytes THEN
        RAISE EXCEPTION
            'Los datos adicionales de la propuesta superan el límite permitido de % KB',
            ROUND(v_limits.max_request_data_bytes / 1024.0, 0);
    END IF;


    -- --------------------------------------------------------
    -- LÍMITE TOTAL DE PALABRAS
    -- --------------------------------------------------------
    --
    -- Se cuentan las palabras de los campos descriptivos.
    -- Los campos cortos/categóricos también quedan protegidos
    -- por sus límites de caracteres anteriores.
    --

    FOREACH v_text IN ARRAY ARRAY[
        NEW.titulo,
        NEW.descripcion_necesidad,
        NEW.objetivos,
        NEW.prioridades,
        NEW.soluciones_actuales,
        NEW.proyectos_relacionados,
        NEW.automatizaciones_actuales,
        NEW.integraciones_actuales,
        NEW.tecnologias,
        NEW.sistemas_criticos,
        NEW.alcance_tecnico_solicitado,
        NEW.tipo_trabajo,
        NEW.nivel_soporte_solicitado,
        NEW.tiempo_respuesta_deseado,
        NEW.horario_soporte,
        NEW.sla_solicitado,
        NEW.nivel_criticidad,
        NEW.impacto_incidencia,
        NEW.requisitos_seguridad,
        NEW.informacion_adicional
    ]
    LOOP
        IF v_text IS NOT NULL AND BTRIM(v_text) <> '' THEN
            v_total_words :=
                v_total_words
                + COALESCE(
                    array_length(
                        regexp_split_to_array(
                            BTRIM(v_text),
                            '\s+'
                        ),
                        1
                    ),
                    0
                );
        END IF;
    END LOOP;


    IF v_total_words > v_limits.max_total_words THEN
        RAISE EXCEPTION
            'La propuesta supera el límite total de % palabras',
            v_limits.max_total_words;
    END IF;


    -- --------------------------------------------------------
    -- LIMITAR CAMPOS DE COTIZACIÓN DE MODIRA
    -- --------------------------------------------------------
    --
    -- También protegemos el contenido introducido por trabajadores
    -- para evitar que request/response termine almacenando cantidades
    -- arbitrarias de texto.
    --

    IF NEW.quoted_scope_level IS NOT NULL
       AND LENGTH(NEW.quoted_scope_level) > 1000
    THEN
        RAISE EXCEPTION
            'El nivel de alcance cotizado no puede superar 1000 caracteres';
    END IF;

    IF NEW.quoted_service_level IS NOT NULL
       AND LENGTH(NEW.quoted_service_level) > 1500
    THEN
        RAISE EXCEPTION
            'El nivel de servicio cotizado no puede superar 1500 caracteres';
    END IF;

    IF NEW.quoted_sla IS NOT NULL
       AND LENGTH(NEW.quoted_sla) > 2500
    THEN
        RAISE EXCEPTION
            'El SLA cotizado no puede superar 2500 caracteres';
    END IF;

    IF NEW.quoted_response_time IS NOT NULL
       AND LENGTH(NEW.quoted_response_time) > 1000
    THEN
        RAISE EXCEPTION
            'El tiempo de respuesta cotizado no puede superar 1000 caracteres';
    END IF;

    IF NEW.quoted_support_hours IS NOT NULL
       AND LENGTH(NEW.quoted_support_hours) > 1500
    THEN
        RAISE EXCEPTION
            'El horario de soporte cotizado no puede superar 1500 caracteres';
    END IF;

    IF NEW.quoted_description IS NOT NULL
       AND LENGTH(NEW.quoted_description) > 8000
    THEN
        RAISE EXCEPTION
            'La descripción de la cotización no puede superar 8000 caracteres';
    END IF;

    IF NEW.quoted_terms IS NOT NULL
       AND LENGTH(NEW.quoted_terms) > 12000
    THEN
        RAISE EXCEPTION
            'Los términos de la cotización no pueden superar 12000 caracteres';
    END IF;


    -- --------------------------------------------------------
    -- PRECIO COTIZADO
    -- --------------------------------------------------------

    IF NEW.quoted_monthly_price IS NOT NULL THEN
        IF NEW.quoted_monthly_price < 0
           OR NEW.quoted_monthly_price > 1000000
        THEN
            RAISE EXCEPTION
                'El precio mensual cotizado está fuera del rango permitido';
        END IF;
    END IF;


    -- --------------------------------------------------------
    -- HORAS COTIZADAS
    -- --------------------------------------------------------

    IF NEW.quoted_hours_monthly IS NOT NULL THEN

        IF NEW.quoted_hours_monthly <= 0 THEN
            RAISE EXCEPTION
                'Las horas mensuales cotizadas deben ser mayores que 0';
        END IF;

        IF NEW.quoted_hours_monthly > v_limits.max_hours_monthly THEN
            RAISE EXCEPTION
                'Las horas mensuales cotizadas no pueden superar % horas',
                v_limits.max_hours_monthly;
        END IF;

    END IF;


    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS
    maintenance_custom_proposals_security_limits
ON public.maintenance_custom_proposals;


CREATE TRIGGER
    maintenance_custom_proposals_security_limits
BEFORE INSERT OR UPDATE
ON public.maintenance_custom_proposals
FOR EACH ROW
EXECUTE FUNCTION public.validate_custom_maintenance_proposal_content();


-- ============================================================
-- 3. RATE LIMIT — CREACIÓN DE PROPUESTAS
-- ============================================================
--
-- Máximo 3 nuevas propuestas por empresa en cualquier ventana
-- móvil de 24 horas.
--
-- La restricción de 069 de "una propuesta abierta" continúa
-- aplicándose adicionalmente.
--

CREATE OR REPLACE FUNCTION public.enforce_custom_maintenance_proposal_creation_rate_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_limit INTEGER;
    v_count INTEGER;
BEGIN

    SELECT max_creations_24h
    INTO v_limit
    FROM public.maintenance_custom_proposal_security_limits();

    SELECT COUNT(*)
    INTO v_count
    FROM public.maintenance_custom_proposals
    WHERE company_id = NEW.company_id
      AND created_at >= CURRENT_TIMESTAMP - INTERVAL '24 hours';

    IF v_count >= v_limit THEN
        RAISE EXCEPTION
            'Se ha alcanzado el límite de % propuestas creadas en 24 horas para esta empresa. Inténtalo de nuevo más tarde.',
            v_limit;
    END IF;

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS
    maintenance_custom_proposals_creation_rate_limit
ON public.maintenance_custom_proposals;


CREATE TRIGGER
    maintenance_custom_proposals_creation_rate_limit
BEFORE INSERT
ON public.maintenance_custom_proposals
FOR EACH ROW
EXECUTE FUNCTION public.enforce_custom_maintenance_proposal_creation_rate_limit();


-- ============================================================
-- 4. RATE LIMIT — ENVÍO DE PROPUESTAS
-- ============================================================
--
-- Máximo 3 envíos en 24 horas por empresa.
--
-- Solo cuenta una transición real hacia "submitted".
-- Un UPDATE cualquiera no consume cuota.
--

CREATE OR REPLACE FUNCTION public.enforce_custom_maintenance_proposal_submission_rate_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_limit INTEGER;
    v_count INTEGER;
BEGIN

    IF NEW.status = 'submitted'
       AND OLD.status IS DISTINCT FROM 'submitted'
    THEN

        SELECT max_submissions_24h
        INTO v_limit
        FROM public.maintenance_custom_proposal_security_limits();

        SELECT COUNT(*)
        INTO v_count
        FROM public.maintenance_custom_proposals
        WHERE company_id = NEW.company_id
          AND submitted_at IS NOT NULL
          AND submitted_at >= CURRENT_TIMESTAMP - INTERVAL '24 hours';

        IF v_count >= v_limit THEN
            RAISE EXCEPTION
                'Se ha alcanzado el límite de % propuestas enviadas en 24 horas para esta empresa. Inténtalo de nuevo más tarde.',
                v_limit;
        END IF;

    END IF;

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS
    maintenance_custom_proposals_submission_rate_limit
ON public.maintenance_custom_proposals;


CREATE TRIGGER
    maintenance_custom_proposals_submission_rate_limit
BEFORE UPDATE
ON public.maintenance_custom_proposals
FOR EACH ROW
EXECUTE FUNCTION public.enforce_custom_maintenance_proposal_submission_rate_limit();


-- ============================================================
-- 5. SEGURIDAD DE LOS CAMPOS DE COTIZACIÓN EXISTENTES
-- ============================================================
--
-- Refuerza límites mediante CHECK para que sigan siendo efectivos
-- incluso si en el futuro se elimina o cambia el trigger.
--

ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_quoted_price_upper_bound_check;

ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_quoted_price_upper_bound_check
    CHECK (
        quoted_monthly_price IS NULL
        OR (
            quoted_monthly_price >= 0
            AND quoted_monthly_price <= 1000000
        )
    );


ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_hours_upper_bound_check;

ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_hours_upper_bound_check
    CHECK (
        horas_mensuales_solicitadas IS NULL
        OR (
            horas_mensuales_solicitadas > 0
            AND horas_mensuales_solicitadas <= 744
        )
    );


ALTER TABLE public.maintenance_custom_proposals
    DROP CONSTRAINT IF EXISTS
        maintenance_custom_proposals_quoted_hours_upper_bound_check;

ALTER TABLE public.maintenance_custom_proposals
    ADD CONSTRAINT
        maintenance_custom_proposals_quoted_hours_upper_bound_check
    CHECK (
        quoted_hours_monthly IS NULL
        OR (
            quoted_hours_monthly > 0
            AND quoted_hours_monthly <= 744
        )
    );


-- ============================================================
-- 6. ÍNDICES PARA RATE LIMIT
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_company_created_rate
ON public.maintenance_custom_proposals (
    company_id,
    created_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_maintenance_custom_proposals_company_submitted_rate
ON public.maintenance_custom_proposals (
    company_id,
    submitted_at DESC
)
WHERE submitted_at IS NOT NULL;


-- ============================================================
-- 7. VALIDACIÓN FINAL
-- ============================================================

DO $$
DECLARE
    v_trigger_count INTEGER;
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'validate_custom_maintenance_proposal_content'
    ) THEN
        RAISE EXCEPTION
            '070 failed: falta validate_custom_maintenance_proposal_content()';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'enforce_custom_maintenance_proposal_creation_rate_limit'
    ) THEN
        RAISE EXCEPTION
            '070 failed: falta enforce_custom_maintenance_proposal_creation_rate_limit()';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'enforce_custom_maintenance_proposal_submission_rate_limit'
    ) THEN
        RAISE EXCEPTION
            '070 failed: falta enforce_custom_maintenance_proposal_submission_rate_limit()';
    END IF;


    SELECT COUNT(*)
    INTO v_trigger_count
    FROM pg_trigger t
    JOIN pg_class c
      ON c.oid = t.tgrelid
    JOIN pg_namespace n
      ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'maintenance_custom_proposals'
      AND NOT t.tgisinternal
      AND t.tgname IN (
          'maintenance_custom_proposals_security_limits',
          'maintenance_custom_proposals_creation_rate_limit',
          'maintenance_custom_proposals_submission_rate_limit'
      );

    IF v_trigger_count <> 3 THEN
        RAISE EXCEPTION
            '070 failed: no se pudieron instalar los 3 triggers de seguridad esperados';
    END IF;

END $$;

COMMIT;
