-- ============================================================
-- 053_invoice_document_acknowledgements.sql
-- ============================================================
--
-- OBJETIVO
--
-- Registrar de forma segura que el cliente ha tenido acceso
-- al PDF de una factura y ha aceptado el texto informativo/legal
-- mostrado antes de iniciar el pago.
--
-- ESTA MIGRACIÓN:
--
-- - NO modifica el flujo actual de Stripe.
-- - NO modifica el webhook de Stripe.
-- - NO modifica attach_invoice_document().
-- - NO cambia las políticas actuales de invoices.
-- - NO cambia las políticas actuales de Storage.
--
-- Añade únicamente la infraestructura necesaria para:
--
-- 1. identificar la versión exacta del PDF mediante SHA-256;
-- 2. registrar la aceptación del cliente;
-- 3. impedir duplicados de la misma aceptación.
-- ============================================================


-- ============================================================
-- 1. HASH DEL PDF ACTUAL
-- ============================================================

ALTER TABLE public.invoices
ADD COLUMN IF NOT EXISTS document_sha256 TEXT;


-- ============================================================
-- 2. VALIDACIÓN DEL SHA-256
-- ============================================================
--
-- Un SHA-256 hexadecimal válido tiene exactamente:
--
-- 64 caracteres
-- 0-9 / a-f
--
-- Permitimos NULL porque las facturas existentes todavía
-- no tienen necesariamente hash.
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'invoices_document_sha256_format'
          AND conrelid = 'public.invoices'::regclass
    ) THEN

        ALTER TABLE public.invoices
        ADD CONSTRAINT invoices_document_sha256_format
        CHECK (
            document_sha256 IS NULL
            OR document_sha256 ~ '^[0-9a-fA-F]{64}$'
        );

    END IF;

END
$$;


-- ============================================================
-- 3. TABLA DE ACEPTACIONES
-- ============================================================

CREATE TABLE IF NOT EXISTS public.invoice_document_acknowledgements (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    invoice_id UUID NOT NULL
        REFERENCES public.invoices(id)
        ON DELETE CASCADE,

    user_id UUID NOT NULL
        REFERENCES auth.users(id)
        ON DELETE CASCADE,

    document_path TEXT NOT NULL,

    document_sha256 TEXT NOT NULL,

    acknowledgement_text_version TEXT NOT NULL,

    accepted_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP

);


-- ============================================================
-- 4. VALIDACIONES DE DATOS
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'invoice_ack_document_sha256_format'
          AND conrelid =
              'public.invoice_document_acknowledgements'::regclass
    ) THEN

        ALTER TABLE public.invoice_document_acknowledgements
        ADD CONSTRAINT invoice_ack_document_sha256_format
        CHECK (
            document_sha256 ~ '^[0-9a-fA-F]{64}$'
        );

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'invoice_ack_document_path_not_empty'
          AND conrelid =
              'public.invoice_document_acknowledgements'::regclass
    ) THEN

        ALTER TABLE public.invoice_document_acknowledgements
        ADD CONSTRAINT invoice_ack_document_path_not_empty
        CHECK (
            length(trim(document_path)) > 0
        );

    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'invoice_ack_text_version_not_empty'
          AND conrelid =
              'public.invoice_document_acknowledgements'::regclass
    ) THEN

        ALTER TABLE public.invoice_document_acknowledgements
        ADD CONSTRAINT invoice_ack_text_version_not_empty
        CHECK (
            length(trim(acknowledgement_text_version)) > 0
        );

    END IF;

END
$$;


-- ============================================================
-- 5. ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_invoice_document_ack_invoice
ON public.invoice_document_acknowledgements (
    invoice_id
);


CREATE INDEX IF NOT EXISTS
    idx_invoice_document_ack_user_invoice
ON public.invoice_document_acknowledgements (
    user_id,
    invoice_id
);


CREATE INDEX IF NOT EXISTS
    idx_invoice_document_ack_invoice_hash
ON public.invoice_document_acknowledgements (
    invoice_id,
    document_sha256
);


-- ============================================================
-- 6. EVITAR DUPLICADOS
-- ============================================================
--
-- Una misma persona no necesita registrar infinitas veces
-- exactamente la misma aceptación para exactamente el mismo
-- documento y versión del texto.
--
-- Si posteriormente cambia el PDF:
--
-- document_sha256 cambia
--
-- y por tanto podrá existir una nueva aceptación.
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
    ux_invoice_document_ack_unique
ON public.invoice_document_acknowledgements (
    invoice_id,
    user_id,
    document_sha256,
    acknowledgement_text_version
);


-- ============================================================
-- 7. RLS
-- ============================================================

ALTER TABLE public.invoice_document_acknowledgements
ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- 8. SEGURIDAD
-- ============================================================
--
-- Nadie puede insertar/modificar/eliminar directamente.
--
-- La aceptación se hará mediante RPC SECURITY DEFINER.
-- ============================================================

REVOKE ALL
ON public.invoice_document_acknowledgements
FROM PUBLIC;


REVOKE ALL
ON public.invoice_document_acknowledgements
FROM anon;


REVOKE ALL
ON public.invoice_document_acknowledgements
FROM authenticated;


-- ============================================================
-- 9. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.invoice_document_acknowledgements IS
'Registro de aceptación del documento PDF asociado a una factura antes de iniciar el pago.';


COMMENT ON COLUMN public.invoices.document_sha256 IS
'SHA-256 del contenido del documento PDF actualmente asociado a la factura.';


COMMENT ON COLUMN public.invoice_document_acknowledgements.document_sha256 IS
'SHA-256 exacto del PDF que el usuario aceptó.';


COMMENT ON COLUMN public.invoice_document_acknowledgements.acknowledgement_text_version IS
'Versión del texto mostrado al usuario en el momento de la aceptación.';


COMMENT ON COLUMN public.invoice_document_acknowledgements.accepted_at IS
'Fecha y hora de la aceptación del documento.';