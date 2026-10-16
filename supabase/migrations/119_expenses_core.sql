BEGIN;

-- ============================================================
-- MODIRA — 119_expenses_core.sql
-- ============================================================
--
-- OBJETIVO
-- --------
-- Crear el núcleo del módulo interno de gastos de MODIRA.
--
-- IMPORTANTE
-- ----------
-- Este módulo pertenece EXCLUSIVAMENTE al Employee Area de MODIRA.
--
-- Los gastos NO pertenecen a las empresas clientes.
-- Por tanto:
--
--   expenses
--   suppliers
--   expense_categories
--
-- NO utilizan company_id.
--
-- Los proyectos podrán relacionarse posteriormente con gastos
-- mediante project_id / expense_allocations, pero el gasto
-- continúa siendo un gasto interno de MODIRA.
--
-- Esta migración NO crea todavía:
--
--   - expense_tax_lines
--   - expense_documents
--   - expense_payments
--   - expense_allocations
--   - expense_templates
--   - RPCs de escritura
--   - RLS definitiva
--
-- Esas piezas se incorporarán en migraciones posteriores.
--
-- ============================================================


-- ============================================================
-- 0. VALIDACIONES PREVIAS
-- ============================================================

DO $$
BEGIN

    -- --------------------------------------------------------
    -- companies NO es necesaria para el núcleo de gastos.
    -- El módulo es interno de MODIRA.
    -- --------------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'workers'
    ) THEN
        RAISE EXCEPTION
            '119 stopped: public.workers does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_worker'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '119 stopped: public.current_user_is_worker() does not exist';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'current_user_is_active'
          AND p.pronargs = 0
    ) THEN
        RAISE EXCEPTION
            '119 stopped: public.current_user_is_active() does not exist';
    END IF;

END;
$$;


-- ============================================================
-- 1. SECUENCIA DE NUMERACIÓN DE GASTOS
-- ============================================================
--
-- La numeración se genera exclusivamente en backend.
--
-- Formato:
--
--   G-000001
--   G-000002
--   G-000003
--
-- La secuencia es global para el módulo interno de MODIRA.
--
-- ============================================================

CREATE SEQUENCE IF NOT EXISTS public.expense_number_seq
    AS BIGINT
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    NO CYCLE;


-- ============================================================
-- 2. FUNCIÓN DE NUMERACIÓN
-- ============================================================

CREATE OR REPLACE FUNCTION public.generate_expense_number()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$

DECLARE
    v_number BIGINT;
BEGIN

    v_number := nextval('public.expense_number_seq');

    RETURN 'G-' || LPAD(
        v_number::TEXT,
        6,
        '0'
    );

END;
$function$;


REVOKE ALL
ON FUNCTION public.generate_expense_number()
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE
ON FUNCTION public.generate_expense_number()
TO authenticated;


COMMENT ON FUNCTION public.generate_expense_number()
IS
'Genera el número interno único de un gasto de MODIRA. El frontend no proporciona el número.';


-- ============================================================
-- 3. PROVEEDORES
-- ============================================================
--
-- Los proveedores pertenecen al sistema contable interno de
-- MODIRA y no a las empresas clientes.
--
-- Un proveedor puede tener:
--
--   factura
--   recibo
--   servicio recurrente
--   gasto puntual
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.suppliers (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    legal_name TEXT NOT NULL,

    commercial_name TEXT,

    cif_vat TEXT,

    email TEXT,

    phone TEXT,

    address TEXT,

    postal_code TEXT,

    city TEXT,

    province TEXT,

    country TEXT NOT NULL DEFAULT 'ES',

    iban TEXT,

    payment_terms TEXT,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP

);


-- ============================================================
-- 4. CONSTRAINTS — PROVEEDORES
-- ============================================================

ALTER TABLE public.suppliers
    DROP CONSTRAINT IF EXISTS suppliers_legal_name_check;

ALTER TABLE public.suppliers
    ADD CONSTRAINT suppliers_legal_name_check
    CHECK (
        length(btrim(legal_name)) > 0
        AND length(legal_name) <= 300
    );


ALTER TABLE public.suppliers
    DROP CONSTRAINT IF EXISTS suppliers_commercial_name_check;

ALTER TABLE public.suppliers
    ADD CONSTRAINT suppliers_commercial_name_check
    CHECK (
        commercial_name IS NULL
        OR length(commercial_name) <= 300
    );


ALTER TABLE public.suppliers
    DROP CONSTRAINT IF EXISTS suppliers_cif_vat_check;

ALTER TABLE public.suppliers
    ADD CONSTRAINT suppliers_cif_vat_check
    CHECK (
        cif_vat IS NULL
        OR (
            length(btrim(cif_vat)) > 0
            AND length(cif_vat) <= 32
        )
    );


ALTER TABLE public.suppliers
    DROP CONSTRAINT IF EXISTS suppliers_email_check;

ALTER TABLE public.suppliers
    ADD CONSTRAINT suppliers_email_check
    CHECK (
        email IS NULL
        OR length(email) <= 320
    );


ALTER TABLE public.suppliers
    DROP CONSTRAINT IF EXISTS suppliers_country_check;

ALTER TABLE public.suppliers
    ADD CONSTRAINT suppliers_country_check
    CHECK (
        length(btrim(country)) BETWEEN 2 AND 100
    );


-- ============================================================
-- 5. ÍNDICES — PROVEEDORES
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_suppliers_legal_name
ON public.suppliers (
    lower(legal_name)
);


CREATE INDEX IF NOT EXISTS
    idx_suppliers_cif_vat
ON public.suppliers (
    lower(cif_vat)
)
WHERE cif_vat IS NOT NULL;


CREATE INDEX IF NOT EXISTS
    idx_suppliers_active
ON public.suppliers (
    is_active,
    legal_name
);


-- ============================================================
-- 6. CATEGORÍAS DE GASTOS
-- ============================================================
--
-- Las categorías son internas de MODIRA.
--
-- No dependen de company_id.
--
-- Ejemplos:
--
--   software
--   hardware
--   telecommunications
--   professional_services
--   transport
--   fuel
--   accommodation
--   meals
--   advertising
--   training
--   rent
--   insurance
--   utilities
--   office
--   taxes
--   other
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.expense_categories (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    code TEXT NOT NULL,

    name TEXT NOT NULL,

    description TEXT,

    sort_order INTEGER NOT NULL DEFAULT 0,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT expense_categories_code_unique
        UNIQUE (code)

);


-- ============================================================
-- 7. CONSTRAINTS — CATEGORÍAS
-- ============================================================

ALTER TABLE public.expense_categories
    DROP CONSTRAINT IF EXISTS expense_categories_code_check;

ALTER TABLE public.expense_categories
    ADD CONSTRAINT expense_categories_code_check
    CHECK (
        length(btrim(code)) BETWEEN 1 AND 100
    );


ALTER TABLE public.expense_categories
    DROP CONSTRAINT IF EXISTS expense_categories_name_check;

ALTER TABLE public.expense_categories
    ADD CONSTRAINT expense_categories_name_check
    CHECK (
        length(btrim(name)) BETWEEN 1 AND 200
    );


ALTER TABLE public.expense_categories
    DROP CONSTRAINT IF EXISTS expense_categories_description_check;

ALTER TABLE public.expense_categories
    ADD CONSTRAINT expense_categories_description_check
    CHECK (
        description IS NULL
        OR length(description) <= 5000
    );


-- ============================================================
-- 8. ÍNDICES — CATEGORÍAS
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_expense_categories_active_order
ON public.expense_categories (
    is_active,
    sort_order,
    name
);


-- ============================================================
-- 9. CATEGORÍAS INICIALES
-- ============================================================
--
-- Se insertan únicamente si no existen.
--
-- Las categorías podrán ampliarse posteriormente desde
-- migraciones o desde un sistema administrativo.
--
-- ============================================================

INSERT INTO public.expense_categories (
    code,
    name,
    description,
    sort_order,
    is_active
)
VALUES
(
    'software',
    'Software',
    'Licencias, aplicaciones, SaaS y herramientas digitales.',
    10,
    TRUE
),
(
    'hardware',
    'Hardware',
    'Ordenadores, periféricos, dispositivos y equipamiento informático.',
    20,
    TRUE
),
(
    'telecommunications',
    'Telecomunicaciones',
    'Telefonía, internet y otros servicios de telecomunicaciones.',
    30,
    TRUE
),
(
    'professional_services',
    'Servicios profesionales',
    'Servicios prestados por profesionales y empresas externas.',
    40,
    TRUE
),
(
    'materials',
    'Materiales',
    'Material, componentes y consumibles utilizados por MODIRA.',
    50,
    TRUE
),
(
    'transport',
    'Transporte',
    'Transporte público, taxis, VTC, desplazamientos y otros transportes.',
    60,
    TRUE
),
(
    'fuel',
    'Combustible',
    'Combustible y gastos relacionados con desplazamientos.',
    70,
    TRUE
),
(
    'accommodation',
    'Alojamiento',
    'Hoteles y otros gastos de alojamiento.',
    80,
    TRUE
),
(
    'meals',
    'Restauración',
    'Comidas, dietas y gastos de restauración.',
    90,
    TRUE
),
(
    'advertising',
    'Publicidad y marketing',
    'Publicidad, campañas, eventos y acciones de marketing.',
    100,
    TRUE
),
(
    'training',
    'Formación',
    'Cursos, certificaciones, formación y capacitación.',
    110,
    TRUE
),
(
    'rent',
    'Alquiler',
    'Alquileres de oficinas, espacios, equipos u otros activos.',
    120,
    TRUE
),
(
    'insurance',
    'Seguros',
    'Pólizas y servicios de seguros.',
    130,
    TRUE
),
(
    'utilities',
    'Suministros',
    'Electricidad, agua y otros suministros.',
    140,
    TRUE
),
(
    'office',
    'Oficina',
    'Material de oficina, mobiliario y consumibles administrativos.',
    150,
    TRUE
),
(
    'taxes',
    'Impuestos y tasas',
    'Impuestos, tasas y otros pagos de naturaleza tributaria.',
    160,
    TRUE
),
(
    'banking',
    'Servicios bancarios',
    'Comisiones bancarias y servicios financieros.',
    170,
    TRUE
),
(
    'other',
    'Otros',
    'Gastos que no encajan en ninguna de las categorías anteriores.',
    999,
    TRUE
)
ON CONFLICT (code) DO NOTHING;


-- ============================================================
-- 10. TABLA PRINCIPAL DE GASTOS
-- ============================================================
--
-- Esta tabla representa el gasto económico interno de MODIRA.
--
-- Todavía NO contiene la parte fiscal detallada.
-- Eso se incorporará en 071.
--
-- ============================================================

CREATE TABLE IF NOT EXISTS public.expenses (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    expense_number TEXT NOT NULL
        DEFAULT public.generate_expense_number(),

    expense_date DATE NOT NULL
        DEFAULT CURRENT_DATE,

    description TEXT NOT NULL,

    expense_type TEXT NOT NULL,

    category_id UUID NOT NULL
        REFERENCES public.expense_categories(id)
        ON DELETE RESTRICT,

    supplier_id UUID
        REFERENCES public.suppliers(id)
        ON DELETE RESTRICT,

    project_id UUID
        REFERENCES public.projects(id)
        ON DELETE RESTRICT,

    status TEXT NOT NULL DEFAULT 'draft',

    currency VARCHAR(3) NOT NULL DEFAULT 'EUR',

    created_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    updated_by UUID
        REFERENCES auth.users(id)
        ON DELETE SET NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP

);


-- ============================================================
-- 11. CONSTRAINT — NÚMERO DE GASTO
-- ============================================================

ALTER TABLE public.expenses
    DROP CONSTRAINT IF EXISTS expenses_number_check;

ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_number_check
    CHECK (
        length(btrim(expense_number)) BETWEEN 1 AND 50
    );


-- ============================================================
-- 12. CONSTRAINT — DESCRIPCIÓN
-- ============================================================

ALTER TABLE public.expenses
    DROP CONSTRAINT IF EXISTS expenses_description_check;

ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_description_check
    CHECK (
        length(btrim(description)) BETWEEN 1 AND 5000
    );


-- ============================================================
-- 13. CONSTRAINT — TIPO DE GASTO
-- ============================================================
--
-- El tipo describe la naturaleza del gasto.
--
-- La categoría describe su clasificación.
--
-- ============================================================

ALTER TABLE public.expenses
    DROP CONSTRAINT IF EXISTS expenses_type_check;

ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_type_check
    CHECK (
        expense_type IN (
            'supplier_invoice',
            'employee_expense',
            'travel',
            'meals',
            'corporate_card',
            'subscription',
            'tax',
            'other'
        )
    );


-- ============================================================
-- 14. CONSTRAINT — ESTADO
-- ============================================================

ALTER TABLE public.expenses
    DROP CONSTRAINT IF EXISTS expenses_status_check;

ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_status_check
    CHECK (
        status IN (
            'draft',
            'pending_review',
            'approved',
            'rejected',
            'pending_payment',
            'partially_paid',
            'paid',
            'cancelled'
        )
    );


-- ============================================================
-- 15. CONSTRAINT — MONEDA
-- ============================================================

ALTER TABLE public.expenses
    DROP CONSTRAINT IF EXISTS expenses_currency_check;

ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_currency_check
    CHECK (
        currency ~ '^[A-Z]{3}$'
    );


-- ============================================================
-- 16. ÍNDICE ÚNICO — NÚMERO
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS
    idx_expenses_expense_number_unique
ON public.expenses (
    expense_number
);


-- ============================================================
-- 17. ÍNDICES — GASTOS
-- ============================================================

CREATE INDEX IF NOT EXISTS
    idx_expenses_date
ON public.expenses (
    expense_date DESC
);


CREATE INDEX IF NOT EXISTS
    idx_expenses_status
ON public.expenses (
    status,
    expense_date DESC
);


CREATE INDEX IF NOT EXISTS
    idx_expenses_category
ON public.expenses (
    category_id,
    expense_date DESC
);


CREATE INDEX IF NOT EXISTS
    idx_expenses_supplier
ON public.expenses (
    supplier_id,
    expense_date DESC
)
WHERE supplier_id IS NOT NULL;


CREATE INDEX IF NOT EXISTS
    idx_expenses_project
ON public.expenses (
    project_id,
    expense_date DESC
)
WHERE project_id IS NOT NULL;


CREATE INDEX IF NOT EXISTS
    idx_expenses_type
ON public.expenses (
    expense_type,
    expense_date DESC
);


CREATE INDEX IF NOT EXISTS
    idx_expenses_created_by
ON public.expenses (
    created_by,
    created_at DESC
)
WHERE created_by IS NOT NULL;


-- ============================================================
-- 18. UPDATED_AT — SUPPLIERS
-- ============================================================
--
-- Reutilizamos la función global existente de MODIRA.
--
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'update_updated_at_column'
    ) THEN
        RAISE EXCEPTION
            '119 stopped: public.update_updated_at_column() does not exist';
    END IF;

END;
$$;


DROP TRIGGER IF EXISTS suppliers_updated_at
ON public.suppliers;


CREATE TRIGGER suppliers_updated_at
BEFORE UPDATE ON public.suppliers
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 19. UPDATED_AT — CATEGORÍAS
-- ============================================================

DROP TRIGGER IF EXISTS expense_categories_updated_at
ON public.expense_categories;


CREATE TRIGGER expense_categories_updated_at
BEFORE UPDATE ON public.expense_categories
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 20. UPDATED_AT — GASTOS
-- ============================================================

DROP TRIGGER IF EXISTS expenses_updated_at
ON public.expenses;


CREATE TRIGGER expenses_updated_at
BEFORE UPDATE ON public.expenses
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================
-- 21. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.expenses
IS
'Gastos internos de MODIRA. No representan gastos de empresas clientes y únicamente son gestionados desde el Employee Area.';


COMMENT ON TABLE public.suppliers
IS
'Proveedores utilizados por la contabilidad interna de MODIRA.';


COMMENT ON TABLE public.expense_categories
IS
'Categorías internas utilizadas para clasificar los gastos de MODIRA.';


COMMENT ON COLUMN public.expenses.expense_number
IS
'Número interno único del gasto. Generado automáticamente por backend.';


COMMENT ON COLUMN public.expenses.expense_type
IS
'Naturaleza del gasto: supplier_invoice, employee_expense, travel, meals, corporate_card, subscription, tax u other.';


COMMENT ON COLUMN public.expenses.category_id
IS
'Categoría interna del gasto.';


COMMENT ON COLUMN public.expenses.supplier_id
IS
'Proveedor asociado al gasto, cuando exista.';


COMMENT ON COLUMN public.expenses.project_id
IS
'Proyecto de MODIRA al que se imputa directamente el gasto, cuando corresponda.';


-- ============================================================
-- 22. VERIFICACIONES FINALES
-- ============================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN

    -- --------------------------------------------------------
    -- expenses
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expenses';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '119 failed: public.expenses was not created';
    END IF;


    -- --------------------------------------------------------
    -- suppliers
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'suppliers';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '119 failed: public.suppliers was not created';
    END IF;


    -- --------------------------------------------------------
    -- categories
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'expense_categories';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '119 failed: public.expense_categories was not created';
    END IF;


    -- --------------------------------------------------------
    -- sequence
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_class
    WHERE relkind = 'S'
      AND relnamespace = 'public'::regnamespace
      AND relname = 'expense_number_seq';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '119 failed: expense_number_seq was not created';
    END IF;


    -- --------------------------------------------------------
    -- numbering function
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'generate_expense_number'
      AND p.pronargs = 0;

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            '119 failed: generate_expense_number() was not created';
    END IF;


    -- --------------------------------------------------------
    -- initial categories
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM public.expense_categories;

    IF v_count < 1 THEN
        RAISE EXCEPTION
            '119 failed: no initial expense categories were created';
    END IF;


    -- --------------------------------------------------------
    -- expenses must NOT contain company_id
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'expenses'
      AND column_name = 'company_id';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '119 failed: expenses must not contain company_id because Expenses is an internal MODIRA module';
    END IF;


    -- --------------------------------------------------------
    -- suppliers must NOT contain company_id
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'suppliers'
      AND column_name = 'company_id';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '119 failed: suppliers must not contain company_id because Suppliers is an internal MODIRA module';
    END IF;


    -- --------------------------------------------------------
    -- categories must NOT contain company_id
    -- --------------------------------------------------------

    SELECT COUNT(*)
    INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'expense_categories'
      AND column_name = 'company_id';

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            '119 failed: expense_categories must not contain company_id because categories are internal to MODIRA';
    END IF;

END;
$$;


COMMIT;