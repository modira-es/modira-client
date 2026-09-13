BEGIN;

-- ============================================================
-- MODIRA — 036_ai_conversation_retention.sql
--
-- RETENCIÓN DE CONVERSACIONES DE MODIRA AI
--
-- Las conversaciones de IA se conservarán durante un máximo
-- de 90 días desde su fecha de creación.
--
-- Cuando una conversación supera los 90 días:
--   1. Se elimina la conversación.
--   2. Sus mensajes se eliminan automáticamente mediante
--      ON DELETE CASCADE en ai_messages.conversation_id.
--
-- La limpieza se ejecuta automáticamente una vez al día
-- mediante pg_cron.
--
-- No se modifican las migraciones anteriores.
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
      AND table_name = 'ai_conversations'
  ) THEN
    RAISE EXCEPTION
      '036 stopped: public.ai_conversations does not exist';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'ai_conversations'
      AND column_name = 'created_at'
  ) THEN
    RAISE EXCEPTION
      '036 stopped: ai_conversations.created_at does not exist';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'ai_messages'
  ) THEN
    RAISE EXCEPTION
      '036 stopped: public.ai_messages does not exist';
  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'ai_messages'
      AND column_name = 'conversation_id'
  ) THEN
    RAISE EXCEPTION
      '036 stopped: ai_messages.conversation_id does not exist';
  END IF;

END $$;


-- ============================================================
-- 2. FUNCIÓN DE LIMPIEZA
-- ============================================================

CREATE OR REPLACE FUNCTION public.cleanup_old_ai_conversations()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN

  DELETE FROM public.ai_conversations
  WHERE created_at < (
    clock_timestamp() - INTERVAL '90 days'
  );

  GET DIAGNOSTICS
    v_deleted = ROW_COUNT;

  RETURN v_deleted;

END;
$$;


-- ============================================================
-- 3. PROTEGER LA FUNCIÓN
-- ============================================================

REVOKE ALL
ON FUNCTION public.cleanup_old_ai_conversations()
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.cleanup_old_ai_conversations()
TO service_role;


-- ============================================================
-- 4. ÍNDICE PARA LA LIMPIEZA POR created_at
-- ============================================================

CREATE INDEX IF NOT EXISTS
  idx_ai_conversations_created_at_retention
ON public.ai_conversations (
  created_at
);


-- ============================================================
-- 5. PROGRAMACIÓN AUTOMÁTICA — PG_CRON
-- ============================================================
--
-- Se ejecuta una vez al día.
--
-- La función se ejecuta dentro de PostgreSQL, por lo que no
-- necesita exponer ninguna clave ni crear una ruta HTTP.
--
-- Si ya existiera una tarea con este nombre, se elimina antes
-- de crear la versión correcta.
-- ============================================================

DO $$
DECLARE
  v_job_id BIGINT;
BEGIN

  SELECT jobid
  INTO v_job_id
  FROM cron.job
  WHERE jobname = 'modira-ai-retention';

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;


  PERFORM cron.schedule(
    'modira-ai-retention',
    '15 3 * * *',
    $job$
      SELECT public.cleanup_old_ai_conversations();
    $job$
  );

END $$;


-- ============================================================
-- 6. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
  v_count INTEGER;
BEGIN

  -- Función
  SELECT COUNT(*)
  INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n
    ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'cleanup_old_ai_conversations'
    AND pg_get_function_identity_arguments(p.oid) = '';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '036 failed: cleanup_old_ai_conversations() missing';
  END IF;


  -- Índice
  SELECT COUNT(*)
  INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'ai_conversations'
    AND indexname = 'idx_ai_conversations_created_at_retention';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '036 failed: retention index missing';
  END IF;


  -- Cron
  SELECT COUNT(*)
  INTO v_count
  FROM cron.job
  WHERE jobname = 'modira-ai-retention';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      '036 failed: pg_cron job missing';
  END IF;

END $$;


COMMIT;