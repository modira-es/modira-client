BEGIN;

-- ============================================================
-- MIGRACIÓN 171
-- Firmas electrónicas y documentos firmados de presupuestos.
--
-- Objetivos:
-- 1. Conservar el PDF original sin modificarlo.
-- 2. Registrar el PDF firmado en una ruta independiente.
-- 3. Conservar el nombre del firmante como instantánea.
-- 4. Registrar las huellas SHA-256 de los documentos.
-- 5. Vincular la firma a una versión oficial concreta.
-- 6. Impedir modificaciones y borrados de los registros.
-- 7. Restringir el acceso según los permisos existentes.
--
-- Esta migración prepara la estructura de datos.
-- La integración con el proceso de aceptación se realizará
-- posteriormente, junto con la Edge Function y el frontend.
-- ============================================================


-- ============================================================
-- 1. TABLA DE FIRMAS ELECTRÓNICAS
-- ============================================================

CREATE TABLE IF NOT EXISTS public.quotation_signed_documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Presupuesto al que corresponde la firma.
    quotation_id uuid NOT NULL,

    -- Versión oficial exacta que se ha firmado.
    official_version_id uuid NOT NULL,

    -- Usuario autenticado que firma.
    signer_user_id uuid NOT NULL,

    -- Nombre completo conservado en el momento de la firma.
    signer_name_snapshot text NOT NULL,

    -- Ruta del PDF original que se ha firmado.
    source_document_path text NOT NULL,

    -- SHA-256 del PDF original.
    source_document_sha256 text NOT NULL,

    -- Ruta del PDF firmado en Supabase Storage.
    signed_document_path text NOT NULL,

    -- SHA-256 del PDF firmado.
    signed_document_sha256 text NOT NULL,

    -- SHA-256 de la imagen de firma utilizada para generar
    -- el PDF firmado.
    signature_image_sha256 text NOT NULL,

    -- Fecha y hora de registro de la firma.
    signed_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    -- Información técnica adicional para auditoría.
    user_agent text,

    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    -- Una firma por presupuesto.
    CONSTRAINT quotation_signed_documents_quotation_unique
        UNIQUE (quotation_id),

    -- Evita reutilizar la misma ruta para varios documentos.
    CONSTRAINT quotation_signed_documents_path_unique
        UNIQUE (signed_document_path),

    -- Integridad referencial con el presupuesto.
    CONSTRAINT quotation_signed_documents_quotation_fk
        FOREIGN KEY (quotation_id)
        REFERENCES public.quotations (id)
        ON DELETE RESTRICT,

    -- La firma debe corresponder a una versión oficial existente.
    CONSTRAINT quotation_signed_documents_version_fk
        FOREIGN KEY (official_version_id)
        REFERENCES public.quotation_official_versions (id)
        ON DELETE RESTRICT,

    -- Conserva la referencia al usuario que firmó.
    CONSTRAINT quotation_signed_documents_signer_fk
        FOREIGN KEY (signer_user_id)
        REFERENCES auth.users (id)
        ON DELETE RESTRICT,

    -- Validaciones del nombre del firmante.
    CONSTRAINT quotation_signed_documents_signer_name_check
        CHECK (
            length(btrim(signer_name_snapshot)) BETWEEN 1 AND 200
        ),

    -- Validaciones de las rutas de almacenamiento.
    CONSTRAINT quotation_signed_documents_source_path_check
        CHECK (
            length(btrim(source_document_path)) BETWEEN 1 AND 500
        ),

    CONSTRAINT quotation_signed_documents_signed_path_check
        CHECK (
            length(btrim(signed_document_path)) BETWEEN 1 AND 500
        ),

    -- Las tres huellas deben tener formato SHA-256 hexadecimal.
    CONSTRAINT quotation_signed_documents_source_hash_check
        CHECK (
            source_document_sha256 ~ '^[0-9a-fA-F]{64}$'
        ),

    CONSTRAINT quotation_signed_documents_signed_hash_check
        CHECK (
            signed_document_sha256 ~ '^[0-9a-fA-F]{64}$'
        ),

    CONSTRAINT quotation_signed_documents_signature_hash_check
        CHECK (
            signature_image_sha256 ~ '^[0-9a-fA-F]{64}$'
        ),

    -- Limita el tamaño del user agent.
    CONSTRAINT quotation_signed_documents_user_agent_check
        CHECK (
            user_agent IS NULL OR length(user_agent) <= 2000
        ),

    -- El documento firmado debe tener una ruta distinta
    -- de la del PDF original.
    CONSTRAINT quotation_signed_documents_different_paths_check
        CHECK (
            source_document_path <> signed_document_path
        )
);


COMMENT ON TABLE public.quotation_signed_documents IS
'Registro de documentos PDF firmados electrónicamente para presupuestos. Conserva la identidad del firmante, la versión oficial, las rutas y las huellas digitales de los documentos. No sustituye el registro de aceptación contractual.';


COMMENT ON COLUMN public.quotation_signed_documents.signer_name_snapshot IS
'Nombre del usuario que firmó, conservado como instantánea para que futuros cambios en su perfil no alteren el registro histórico.';


COMMENT ON COLUMN public.quotation_signed_documents.source_document_path IS
'Ruta del PDF original previo a la firma. Este documento debe conservarse sin modificaciones.';


COMMENT ON COLUMN public.quotation_signed_documents.signed_document_path IS
'Ruta independiente del PDF que contiene el nombre del firmante y su firma manuscrita.';


COMMENT ON COLUMN public.quotation_signed_documents.source_document_sha256 IS
'Huella SHA-256 del PDF original utilizado para generar el documento firmado.';


COMMENT ON COLUMN public.quotation_signed_documents.signed_document_sha256 IS
'Huella SHA-256 del PDF firmado almacenado en Supabase Storage.';


COMMENT ON COLUMN public.quotation_signed_documents.signature_image_sha256 IS
'Huella SHA-256 de la imagen de firma utilizada para generar el PDF firmado.';


-- ============================================================
-- 2. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_quotation_signed_documents_signer
    ON public.quotation_signed_documents (signer_user_id);

CREATE INDEX IF NOT EXISTS idx_quotation_signed_documents_version
    ON public.quotation_signed_documents (official_version_id);

CREATE INDEX IF NOT EXISTS idx_quotation_signed_documents_signed_at
    ON public.quotation_signed_documents (signed_at DESC);


-- ============================================================
-- 3. PROTECCIÓN CONTRA MODIFICACIONES Y BORRADOS
-- ============================================================

CREATE OR REPLACE FUNCTION
public.protect_quotation_signed_document_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION
        'El registro de firma del presupuesto es inmutable';

    RETURN NULL;
END;
$$;


COMMENT ON FUNCTION
public.protect_quotation_signed_document_immutability()
IS
'Impide modificar o eliminar un registro de firma electrónica una vez insertado.';


DROP TRIGGER IF EXISTS quotation_signed_documents_immutable
    ON public.quotation_signed_documents;


CREATE TRIGGER quotation_signed_documents_immutable
BEFORE UPDATE OR DELETE
ON public.quotation_signed_documents
FOR EACH ROW
EXECUTE FUNCTION
public.protect_quotation_signed_document_immutability();


-- ============================================================
-- 4. SEGURIDAD RLS
-- ============================================================

ALTER TABLE public.quotation_signed_documents
    ENABLE ROW LEVEL SECURITY;


-- Los clientes solo pueden consultar sus propios registros
-- de firma si su cuenta está activa y no son trabajadores.
DROP POLICY IF EXISTS quotation_signed_documents_client_select
    ON public.quotation_signed_documents;


CREATE POLICY quotation_signed_documents_client_select
ON public.quotation_signed_documents
FOR SELECT
TO authenticated
USING (
    public.current_user_is_active()
    AND NOT public.current_user_is_worker()
    AND signer_user_id = auth.uid()
    AND EXISTS (
        SELECT 1
        FROM public.quotations q
        WHERE q.id = quotation_signed_documents.quotation_id
          AND (
              q.user_id = auth.uid()
              OR EXISTS (
                  SELECT 1
                  FROM public.clients c
                  WHERE c.id = q.client_id
                    AND c.profile_id = auth.uid()
              )
          )
    )
);


-- Los trabajadores solo pueden consultar los registros
-- si disponen del permiso de lectura de presupuestos.
DROP POLICY IF EXISTS quotation_signed_documents_worker_select
    ON public.quotation_signed_documents;


CREATE POLICY quotation_signed_documents_worker_select
ON public.quotation_signed_documents
FOR SELECT
TO authenticated
USING (
    public.current_user_is_worker()
    AND public.current_worker_has_permission('quotations.read')
);


-- ============================================================
-- 5. PERMISOS DE TABLA
-- ============================================================

-- No se concede escritura directa a usuarios autenticados.
-- La futura Edge Function registrará la firma mediante
-- el contexto seguro del servidor.
REVOKE ALL ON TABLE public.quotation_signed_documents
    FROM PUBLIC, anon, authenticated;


-- Se permite lectura a través de las políticas RLS.
GRANT SELECT ON TABLE public.quotation_signed_documents
    TO authenticated;


COMMIT;