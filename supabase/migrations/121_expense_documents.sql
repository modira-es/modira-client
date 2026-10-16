BEGIN;


-- ============================================================
-- MIGRACIÓN 121 — DOCUMENTOS DE GASTOS
-- ============================================================
--
-- Documentación asociada a los gastos internos de Modira.
--
-- IMPORTANTE:
--   - Estos documentos pertenecen exclusivamente a la
--     contabilidad interna de Modira.
--   - Los clientes de Modira no tienen acceso.
--   - El bucket será PRIVADO.
--   - La escritura y lectura controlada se implementará
--     mediante RPC/backend en migraciones posteriores.
--
-- Esta migración NO crea todavía el sistema completo de RLS/RBAC.
-- Eso corresponde a la migración 076.
--
-- ============================================================


-- ============================================================
-- 1. PRECHECKS
-- ============================================================

DO $$
BEGIN

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expenses'
  ) THEN

    RAISE EXCEPTION
      '121_expense_documents: no existe public.expenses. Ejecuta primero 120_expenses_tax.';

  END IF;


  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_tax_lines'
  ) THEN

    RAISE EXCEPTION
      '121_expense_documents: no existe public.expense_tax_lines. Ejecuta primero 120_expenses_tax.';

  END IF;


END;
$$;


-- ============================================================
-- 2. STORAGE — BUCKET PRIVADO DE DOCUMENTOS
-- ============================================================
--
-- Máximo:
--   20 MiB = 20 * 1024 * 1024 = 20.971.520 bytes
--
-- Formato permitido:
--   application/pdf
--
-- El bucket es privado.
--
-- No se crean aquí políticas de acceso de usuario.
-- El acceso controlado se implementará posteriormente.
--
-- ============================================================

INSERT INTO storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
VALUES (
  'expense-documents',
  'expense-documents',
  FALSE,
  20971520,
  ARRAY['application/pdf']::text[]
)
ON CONFLICT (id)
DO UPDATE SET
  public = FALSE,
  file_size_limit = 20971520,
  allowed_mime_types = ARRAY['application/pdf']::text[];


-- ============================================================
-- 3. TABLA expense_documents
-- ============================================================

CREATE TABLE IF NOT EXISTS public.expense_documents (

  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),


  -- ----------------------------------------------------------
  -- Gasto al que pertenece el documento
  -- ----------------------------------------------------------

  expense_id UUID NOT NULL
    REFERENCES public.expenses(id)
    ON DELETE CASCADE,


  -- ----------------------------------------------------------
  -- Clasificación del documento
  -- ----------------------------------------------------------

  document_type TEXT NOT NULL,


  -- ----------------------------------------------------------
  -- Nombre original del archivo
  -- ----------------------------------------------------------

  file_name TEXT NOT NULL,


  -- ----------------------------------------------------------
  -- Ruta dentro de Supabase Storage
  -- ----------------------------------------------------------

  storage_path TEXT NOT NULL,


  -- ----------------------------------------------------------
  -- Información técnica
  -- ----------------------------------------------------------

  mime_type TEXT NOT NULL DEFAULT 'application/pdf',

  file_size BIGINT NOT NULL,


  -- ----------------------------------------------------------
  -- Hash SHA-256 del contenido REAL del documento
  -- ----------------------------------------------------------
  --
  -- Debe ser calculado por el backend sobre los bytes reales
  -- del archivo.
  --
  -- Formato:
  --   64 caracteres hexadecimales
  --
  -- ----------------------------------------------------------

  document_sha256 TEXT NOT NULL,


  -- ----------------------------------------------------------
  -- Usuario que realizó la subida
  -- ----------------------------------------------------------

  uploaded_by UUID
    REFERENCES auth.users(id)
    ON DELETE SET NULL,


  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,


  -- ==========================================================
  -- CONSTRAINTS
  -- ==========================================================

  CONSTRAINT expense_documents_type_check
    CHECK (
      document_type IN (
        'invoice',
        'receipt',
        'payment_proof',
        'delivery_note',
        'other'
      )
    ),


  CONSTRAINT expense_documents_file_name_check
    CHECK (
      LENGTH(BTRIM(file_name)) BETWEEN 1 AND 255
    ),


  CONSTRAINT expense_documents_storage_path_check
    CHECK (
      LENGTH(BTRIM(storage_path)) BETWEEN 1 AND 1024
    ),


  CONSTRAINT expense_documents_mime_type_check
    CHECK (
      mime_type = 'application/pdf'
    ),


  CONSTRAINT expense_documents_file_size_check
    CHECK (
      file_size > 0
      AND file_size <= 20971520
    ),


  CONSTRAINT expense_documents_sha256_check
    CHECK (
      document_sha256 ~ '^[0-9A-Fa-f]{64}$'
    )


);


-- ============================================================
-- 4. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
  idx_expense_documents_expense
ON public.expense_documents (expense_id);


CREATE INDEX IF NOT EXISTS
  idx_expense_documents_type
ON public.expense_documents (document_type);


CREATE INDEX IF NOT EXISTS
  idx_expense_documents_uploaded_by
ON public.expense_documents (uploaded_by);


CREATE INDEX IF NOT EXISTS
  idx_expense_documents_uploaded_at
ON public.expense_documents (uploaded_at DESC);


-- ============================================================
-- 5. STORAGE PATH ÚNICO
-- ============================================================
--
-- Evita que dos registros de documentos apunten al mismo
-- objeto físico de Storage.
--
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
  idx_expense_documents_storage_path_unique
ON public.expense_documents (storage_path);


-- ============================================================
-- 6. VALIDACIÓN DE RUTA DEL STORAGE
-- ============================================================
--
-- El formato esperado será:
--
--   <expense_id>/<uuid>.pdf
--
-- Ejemplo:
--
--   550e8400-e29b-41d4-a716-446655440000/
--   3d8d1c2a-....pdf
--
-- El primer segmento debe coincidir con expense_id.
--
-- La validación completa del objeto existente en Storage se
-- realizará en el flujo controlado de la migración 075.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_expense_document_storage_path()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_first_segment TEXT;
BEGIN

  v_first_segment :=
    split_part(
      TRIM(BOTH '/' FROM NEW.storage_path),
      '/',
      1
    );


  IF v_first_segment <> NEW.expense_id::TEXT THEN

    RAISE EXCEPTION
      'La ruta del documento no pertenece al gasto indicado';

  END IF;


  IF NEW.storage_path !~* '\.pdf$' THEN

    RAISE EXCEPTION
      'Los documentos de gastos deben ser archivos PDF';

  END IF;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 7. TRIGGER DE VALIDACIÓN DE STORAGE PATH
-- ============================================================

DROP TRIGGER IF EXISTS
  expense_documents_validate_storage_path
ON public.expense_documents;


CREATE TRIGGER
  expense_documents_validate_storage_path

BEFORE INSERT OR UPDATE

ON public.expense_documents

FOR EACH ROW

EXECUTE FUNCTION public.validate_expense_document_storage_path();


-- ============================================================
-- 8. TRIGGER updated_at
-- ============================================================

DO $$
BEGIN

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE proname = 'update_updated_at_column'
      AND pronamespace = 'public'::regnamespace
  ) THEN

    RAISE EXCEPTION
      '121_expense_documents: no existe public.update_updated_at_column().';

  END IF;

END;
$$;


DROP TRIGGER IF EXISTS
  expense_documents_set_updated_at
ON public.expense_documents;


CREATE TRIGGER
  expense_documents_set_updated_at

BEFORE UPDATE

ON public.expense_documents

FOR EACH ROW

EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 9. PROTECCIÓN DE LA INTEGRIDAD DEL DOCUMENTO
-- ============================================================
--
-- Una vez registrado un documento:
--
--   storage_path
--   mime_type
--   file_size
--   document_sha256
--   uploaded_by
--   uploaded_at
--
-- no deben poder cambiarse mediante un UPDATE arbitrario.
--
-- Si hay que sustituir un documento:
--
--   1. se elimina el documento anterior mediante el flujo
--      controlado;
--   2. se sube el nuevo;
--   3. se registra como un nuevo documento.
--
-- Esto evita que un registro histórico termine apuntando
-- silenciosamente a otro contenido.
--
-- ============================================================

CREATE OR REPLACE FUNCTION public.protect_expense_document_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN

  IF TG_OP = 'UPDATE' THEN

    IF NEW.storage_path IS DISTINCT FROM OLD.storage_path THEN

      RAISE EXCEPTION
        'No se puede modificar storage_path de un documento existente';

    END IF;


    IF NEW.mime_type IS DISTINCT FROM OLD.mime_type THEN

      RAISE EXCEPTION
        'No se puede modificar mime_type de un documento existente';

    END IF;


    IF NEW.file_size IS DISTINCT FROM OLD.file_size THEN

      RAISE EXCEPTION
        'No se puede modificar file_size de un documento existente';

    END IF;


    IF NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256 THEN

      RAISE EXCEPTION
        'No se puede modificar document_sha256 de un documento existente';

    END IF;


    IF NEW.uploaded_by IS DISTINCT FROM OLD.uploaded_by THEN

      RAISE EXCEPTION
        'No se puede modificar uploaded_by de un documento existente';

    END IF;


    IF NEW.uploaded_at IS DISTINCT FROM OLD.uploaded_at THEN

      RAISE EXCEPTION
        'No se puede modificar uploaded_at de un documento existente';

    END IF;

  END IF;


  RETURN NEW;

END;
$$;


-- ============================================================
-- 10. TRIGGER DE INTEGRIDAD
-- ============================================================

DROP TRIGGER IF EXISTS
  expense_documents_protect_integrity
ON public.expense_documents;


CREATE TRIGGER
  expense_documents_protect_integrity

BEFORE UPDATE

ON public.expense_documents

FOR EACH ROW

EXECUTE FUNCTION public.protect_expense_document_integrity();


-- ============================================================
-- 11. PERMISOS DE FUNCIONES INTERNAS
-- ============================================================
--
-- Estas funciones no deben ser invocadas directamente por
-- anon/authenticated.
--
-- Los flujos controlados se implementarán en migraciones
-- posteriores.
--
-- ============================================================

REVOKE EXECUTE
ON FUNCTION public.validate_expense_document_storage_path()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_document_storage_path()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.validate_expense_document_storage_path()
FROM authenticated;


REVOKE EXECUTE
ON FUNCTION public.protect_expense_document_integrity()
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.protect_expense_document_integrity()
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.protect_expense_document_integrity()
FROM authenticated;


-- ============================================================
-- 12. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.expense_documents IS
  'Documentos privados asociados a gastos internos de Modira. Los clientes de Modira no tienen acceso.';


COMMENT ON COLUMN public.expense_documents.expense_id IS
  'Gasto interno de Modira al que pertenece el documento.';


COMMENT ON COLUMN public.expense_documents.document_type IS
  'Tipo de documento: invoice, receipt, payment_proof, delivery_note u other.';


COMMENT ON COLUMN public.expense_documents.storage_path IS
  'Ruta privada del documento dentro del bucket expense-documents.';


COMMENT ON COLUMN public.expense_documents.document_sha256 IS
  'Hash SHA-256 del contenido real del documento, calculado por el backend.';


COMMENT ON COLUMN public.expense_documents.file_size IS
  'Tamaño del archivo en bytes. Máximo 20 MiB.';


-- ============================================================
-- 13. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE

  v_table_exists BOOLEAN;

  v_bucket_exists BOOLEAN;

  v_trigger_exists BOOLEAN;

  v_required_columns INTEGER;

BEGIN

  -- ----------------------------------------------------------
  -- Tabla
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_documents'
  )
  INTO v_table_exists;


  IF NOT v_table_exists THEN

    RAISE EXCEPTION
      '121_expense_documents: no existe expense_documents';

  END IF;


  -- ----------------------------------------------------------
  -- Bucket
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'expense-documents'
      AND name = 'expense-documents'
      AND public = FALSE
  )
  INTO v_bucket_exists;


  IF NOT v_bucket_exists THEN

    RAISE EXCEPTION
      '121_expense_documents: bucket expense-documents no existe o no es privado';

  END IF;


  -- ----------------------------------------------------------
  -- Columnas obligatorias
  -- ----------------------------------------------------------

  SELECT COUNT(*)
  INTO v_required_columns

  FROM (
    VALUES
      ('expense_id'),
      ('document_type'),
      ('file_name'),
      ('storage_path'),
      ('mime_type'),
      ('file_size'),
      ('document_sha256'),
      ('uploaded_by'),
      ('uploaded_at')
  ) AS required_columns(column_name)

  WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'expense_documents'
      AND c.column_name = required_columns.column_name
  );


  IF v_required_columns > 0 THEN

    RAISE EXCEPTION
      '121_expense_documents: faltan % columnas obligatorias',
      v_required_columns;

  END IF;


  -- ----------------------------------------------------------
  -- Trigger de integridad
  -- ----------------------------------------------------------

  SELECT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'expense_documents_protect_integrity'
      AND tgrelid = 'public.expense_documents'::regclass
      AND NOT tgisinternal
  )
  INTO v_trigger_exists;


  IF NOT v_trigger_exists THEN

    RAISE EXCEPTION
      '121_expense_documents: falta el trigger de integridad';

  END IF;


  RAISE NOTICE
    '121_expense_documents: migración completada correctamente.';

END;
$$;


COMMIT;