-- ============================================================
-- 145 - QUOTATIONS: BACKEND-ONLY OFFICIAL DOCUMENT
-- ============================================================
--
-- A partir de esta migración:
--
--   1. Los workers NO pueden subir PDFs directamente.
--   2. Los workers NO pueden sustituir PDFs directamente.
--   3. Los workers NO pueden borrar PDFs directamente.
--   4. Se elimina el acceso EXECUTE a las RPC legacy que
--      permitían asociar/hashificar documentos manuales.
--   5. Se mantiene la lectura de documentos.
--   6. El backend (service_role) sigue pudiendo generar y
--      almacenar el PDF oficial.
--
-- El PDF oficial debe seguir el flujo:
--
--   Edge Function
--        ↓
--   genera PDF
--        ↓
--   calcula SHA-256
--        ↓
--   Storage
--        ↓
--   finalize_quotation_backend_document()
--
-- ============================================================


-- ============================================================
-- 1. STORAGE — ELIMINAR SUBIDA DIRECTA DEL WORKER
-- ============================================================

DROP POLICY IF EXISTS quotation_documents_worker_insert
ON storage.objects;


-- ============================================================
-- 2. STORAGE — ELIMINAR MODIFICACIÓN DIRECTA DEL WORKER
-- ============================================================

DROP POLICY IF EXISTS quotation_documents_worker_update
ON storage.objects;


-- ============================================================
-- 3. STORAGE — ELIMINAR BORRADO DIRECTO DEL WORKER
-- ============================================================

DROP POLICY IF EXISTS quotation_documents_worker_delete
ON storage.objects;


-- ============================================================
-- 4. MANTENER LECTURA DEL WORKER
-- ============================================================
--
-- NO eliminamos:
--
--   quotation_documents_worker_select
--
-- El worker puede seguir consultando/leyendo el documento.
--
-- ============================================================


-- ============================================================
-- 5. ELIMINAR EJECUCIÓN DE RPC LEGACY:
--    attach_quotation_document()
-- ============================================================
--
-- Esta función permitía asociar a quotations un PDF que ya
-- hubiese sido subido previamente a Storage.
--
-- Ya no forma parte del flujo oficial.
--
-- ============================================================

REVOKE EXECUTE
ON FUNCTION public.attach_quotation_document(UUID, TEXT)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.attach_quotation_document(UUID, TEXT)
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.attach_quotation_document(UUID, TEXT)
FROM authenticated;


-- ============================================================
-- 6. ELIMINAR EJECUCIÓN DE RPC LEGACY:
--    set_quotation_document_hash()
-- ============================================================
--
-- Esta función permitía calcular/registrar el hash de un PDF
-- que ya existía en Storage.
--
-- El hash del documento oficial debe generarse dentro del
-- flujo backend de generación.
--
-- ============================================================

REVOKE EXECUTE
ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
FROM PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
FROM anon;

REVOKE EXECUTE
ON FUNCTION public.set_quotation_document_hash(UUID, TEXT, TEXT)
FROM authenticated;




-- ============================================================
-- 8. VALIDACIONES
-- ============================================================

DO $$
DECLARE
    v_policy_count INTEGER;
    v_function_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- No debe quedar INSERT/UPDATE/DELETE worker directo
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_policy_count
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname IN (
          'quotation_documents_worker_insert',
          'quotation_documents_worker_update',
          'quotation_documents_worker_delete'
      );

    IF v_policy_count <> 0 THEN
        RAISE EXCEPTION
            '145 failed: siguen existiendo policies de escritura directa de quotations';
    END IF;


 

    -- --------------------------------------------------------
    -- La política de lectura del worker debe mantenerse
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'quotation_documents_worker_select'
    ) THEN
        RAISE EXCEPTION
            '145 failed: quotation_documents_worker_select no existe';
    END IF;


    -- --------------------------------------------------------
    -- La política de lectura del cliente debe mantenerse
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'quotation_documents_client_select'
    ) THEN
        RAISE EXCEPTION
            '145 failed: quotation_documents_client_select no existe';
    END IF;

END $$;