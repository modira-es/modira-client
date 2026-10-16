-- ============================================================
-- 140_invoices_fiscal_snapshot_and_rectifications.sql
-- ============================================================
--
-- OBJETIVO
-- ------------------------------------------------------------
-- Prepara public.invoices para:
--
-- 1. Snapshot fiscal inmutable de emisor y cliente.
-- 2. Facturas rectificadoras.
-- 3. Relación factura rectificadora -> factura original.
-- 4. Motivo de rectificación.
--
-- IMPORTANTE
-- ------------------------------------------------------------
-- Esta migración NO:
--   - genera PDFs;
--   - modifica Edge Functions;
--   - modifica Stripe;
--   - modifica invoices antiguas;
--   - elimina document_path;
--   - elimina document_sha256;
--   - modifica el flujo de aceptación documental.
--
-- Las columnas nuevas son NULLABLE para mantener compatibilidad
-- absoluta con las facturas existentes.
--
-- ============================================================


BEGIN;


-- ============================================================
-- 1. COMPROBACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- invoices debe existir
    -- --------------------------------------------------------

    IF to_regclass('public.invoices') IS NULL THEN
        RAISE EXCEPTION
            '140 stopped: public.invoices does not exist';
    END IF;


    -- --------------------------------------------------------
    -- companies debe existir
    -- --------------------------------------------------------

    IF to_regclass('public.companies') IS NULL THEN
        RAISE EXCEPTION
            '140 stopped: public.companies does not exist';
    END IF;


    -- --------------------------------------------------------
    -- clients debe existir
    -- --------------------------------------------------------

    IF to_regclass('public.clients') IS NULL THEN
        RAISE EXCEPTION
            '140 stopped: public.clients does not exist';
    END IF;


    -- --------------------------------------------------------
    -- Campos necesarios de companies
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'legal_name'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: companies.legal_name is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'cif_vat'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: companies.cif_vat is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'address'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: companies.address is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'postal_code'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: companies.postal_code is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'city'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: companies.city is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'province'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: companies.province is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'companies'
          AND column_name = 'country'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: companies.country is missing';
    END IF;


    -- --------------------------------------------------------
    -- Campos necesarios de clients
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'nombre'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: clients.nombre is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'empresa'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: clients.empresa is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'cif_vat'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: clients.cif_vat is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'direccion'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: clients.direccion is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'codigo_postal'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: clients.codigo_postal is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'ciudad'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: clients.ciudad is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'provincia'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: clients.provincia is missing';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'clients'
          AND column_name = 'pais'
    ) THEN
        RAISE EXCEPTION
            '140 stopped: clients.pais is missing';
    END IF;

END $$;


-- ============================================================
-- 2. SNAPSHOT FISCAL DEL EMISOR
-- ============================================================
--
-- Se guarda la información fiscal de companies en el momento
-- de emisión de la factura.
--
-- Las columnas son NULLABLE porque las invoices existentes
-- no contienen actualmente este snapshot.
--
-- ============================================================

ALTER TABLE public.invoices
    ADD COLUMN IF NOT EXISTS issuer_legal_name TEXT,
    ADD COLUMN IF NOT EXISTS issuer_tax_id TEXT,
    ADD COLUMN IF NOT EXISTS issuer_address TEXT,
    ADD COLUMN IF NOT EXISTS issuer_postal_code TEXT,
    ADD COLUMN IF NOT EXISTS issuer_city TEXT,
    ADD COLUMN IF NOT EXISTS issuer_province TEXT,
    ADD COLUMN IF NOT EXISTS issuer_country TEXT;


-- ============================================================
-- 3. SNAPSHOT FISCAL DEL CLIENTE
-- ============================================================
--
-- Los datos proceden de public.clients.
--
-- customer_legal_name:
--   clients.empresa cuando exista.
--   Si no existe, se podrá utilizar clients.nombre en la
--   lógica de creación de la factura.
--
-- customer_contact_name:
--   Persona/contacto asociado al cliente.
--
-- ============================================================

ALTER TABLE public.invoices
    ADD COLUMN IF NOT EXISTS customer_legal_name TEXT,
    ADD COLUMN IF NOT EXISTS customer_tax_id TEXT,
    ADD COLUMN IF NOT EXISTS customer_address TEXT,
    ADD COLUMN IF NOT EXISTS customer_postal_code TEXT,
    ADD COLUMN IF NOT EXISTS customer_city TEXT,
    ADD COLUMN IF NOT EXISTS customer_province TEXT,
    ADD COLUMN IF NOT EXISTS customer_country TEXT,
    ADD COLUMN IF NOT EXISTS customer_contact_name TEXT;


-- ============================================================
-- 4. RECTIFICACIÓN
-- ============================================================
--
-- Una factura rectificadora es una nueva invoice.
--
-- rectifies_invoice_id:
--   apunta a la factura original que se rectifica.
--
-- La factura original NO se modifica para realizar la
-- rectificación.
--
-- ============================================================

ALTER TABLE public.invoices
    ADD COLUMN IF NOT EXISTS rectifies_invoice_id UUID,
    ADD COLUMN IF NOT EXISTS rectification_reason TEXT;


-- ============================================================
-- 5. FOREIGN KEY DE RECTIFICACIÓN
-- ============================================================
--
-- La FK es autorreferenciada:
--
-- invoices.id
--     ↑
--     |
-- rectifies_invoice_id
--
-- ON DELETE RESTRICT:
--
-- No se debe poder eliminar una factura original que esté
-- siendo referenciada por una rectificadora.
--
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.invoices'::regclass
          AND conname = 'invoices_rectifies_invoice_id_fkey'
    ) THEN

        ALTER TABLE public.invoices
            ADD CONSTRAINT invoices_rectifies_invoice_id_fkey
            FOREIGN KEY (rectifies_invoice_id)
            REFERENCES public.invoices(id)
            ON DELETE RESTRICT;

    END IF;

END $$;


-- ============================================================
-- 6. CONSTRAINT — UNA FACTURA NO PUEDE RECTIFICARSE A SÍ MISMA
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.invoices'::regclass
          AND conname = 'invoices_not_self_rectifying_check'
    ) THEN

        ALTER TABLE public.invoices
            ADD CONSTRAINT invoices_not_self_rectifying_check
            CHECK (
                rectifies_invoice_id IS NULL
                OR rectifies_invoice_id <> id
            );

    END IF;

END $$;


-- ============================================================
-- 7. CONSTRAINT — MOTIVO DE RECTIFICACIÓN
-- ============================================================
--
-- Si una invoice es rectificadora, debe existir un motivo.
--
-- Si NO es rectificadora, el motivo debe ser NULL.
--
-- Esto evita estados incoherentes como:
--
-- rectifies_invoice_id = NULL
-- rectification_reason = 'error de IVA'
--
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.invoices'::regclass
          AND conname = 'invoices_rectification_reason_consistency'
    ) THEN

        ALTER TABLE public.invoices
            ADD CONSTRAINT invoices_rectification_reason_consistency
            CHECK (
                (
                    rectifies_invoice_id IS NULL
                    AND rectification_reason IS NULL
                )
                OR
                (
                    rectifies_invoice_id IS NOT NULL
                    AND rectification_reason IS NOT NULL
                    AND length(btrim(rectification_reason)) > 0
                    AND length(rectification_reason) <= 2000
                )
            );

    END IF;

END $$;


-- ============================================================
-- 8. ÍNDICE PARA LOCALIZAR RECTIFICADORAS
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_invoices_rectifies_invoice_id
ON public.invoices (rectifies_invoice_id);


-- ============================================================
-- 9. COMENTARIOS DE DOCUMENTACIÓN
-- ============================================================

COMMENT ON COLUMN public.invoices.issuer_legal_name IS
    'Snapshot de la razón social del emisor en el momento de emisión.';

COMMENT ON COLUMN public.invoices.issuer_tax_id IS
    'Snapshot del NIF/CIF/VAT del emisor en el momento de emisión.';

COMMENT ON COLUMN public.invoices.issuer_address IS
    'Snapshot de la dirección fiscal del emisor.';

COMMENT ON COLUMN public.invoices.issuer_postal_code IS
    'Snapshot del código postal fiscal del emisor.';

COMMENT ON COLUMN public.invoices.issuer_city IS
    'Snapshot de la ciudad fiscal del emisor.';

COMMENT ON COLUMN public.invoices.issuer_province IS
    'Snapshot de la provincia fiscal del emisor.';

COMMENT ON COLUMN public.invoices.issuer_country IS
    'Snapshot del país fiscal del emisor.';


COMMENT ON COLUMN public.invoices.customer_legal_name IS
    'Snapshot del nombre o razón social del cliente en el momento de emisión.';

COMMENT ON COLUMN public.invoices.customer_tax_id IS
    'Snapshot del NIF/CIF/VAT del cliente en el momento de emisión.';

COMMENT ON COLUMN public.invoices.customer_address IS
    'Snapshot de la dirección fiscal del cliente.';

COMMENT ON COLUMN public.invoices.customer_postal_code IS
    'Snapshot del código postal del cliente.';

COMMENT ON COLUMN public.invoices.customer_city IS
    'Snapshot de la ciudad del cliente.';

COMMENT ON COLUMN public.invoices.customer_province IS
    'Snapshot de la provincia del cliente.';

COMMENT ON COLUMN public.invoices.customer_country IS
    'Snapshot del país del cliente.';

COMMENT ON COLUMN public.invoices.customer_contact_name IS
    'Snapshot del nombre de contacto del cliente en el momento de emisión.';


COMMENT ON COLUMN public.invoices.rectifies_invoice_id IS
    'Factura original que esta factura rectifica. NULL para facturas ordinarias.';

COMMENT ON COLUMN public.invoices.rectification_reason IS
    'Motivo de la rectificación. Obligatorio para facturas rectificadoras.';


-- ============================================================
-- 10. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_missing INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_missing
    FROM (
        VALUES
            ('issuer_legal_name'),
            ('issuer_tax_id'),
            ('issuer_address'),
            ('issuer_postal_code'),
            ('issuer_city'),
            ('issuer_province'),
            ('issuer_country'),
            ('customer_legal_name'),
            ('customer_tax_id'),
            ('customer_address'),
            ('customer_postal_code'),
            ('customer_city'),
            ('customer_province'),
            ('customer_country'),
            ('customer_contact_name'),
            ('rectifies_invoice_id'),
            ('rectification_reason')
    ) AS required(column_name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name = 'invoices'
          AND c.column_name = required.column_name
    );


    IF v_missing <> 0 THEN
        RAISE EXCEPTION
            '140 verification failed: % required invoice columns are missing',
            v_missing;
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.invoices'::regclass
          AND conname = 'invoices_rectifies_invoice_id_fkey'
          AND convalidated = TRUE
    ) THEN
        RAISE EXCEPTION
            '140 verification failed: rectification foreign key is missing or not validated';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.invoices'::regclass
          AND conname = 'invoices_not_self_rectifying_check'
          AND convalidated = TRUE
    ) THEN
        RAISE EXCEPTION
            '140 verification failed: self-rectification constraint is missing or not validated';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.invoices'::regclass
          AND conname = 'invoices_rectification_reason_consistency'
          AND convalidated = TRUE
    ) THEN
        RAISE EXCEPTION
            '140 verification failed: rectification reason constraint is missing or not validated';
    END IF;


    RAISE NOTICE
        '140 completed successfully: invoice fiscal snapshots and rectification structure are ready.';

END $$;


COMMIT;