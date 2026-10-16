-- ============================================================
-- MODIRA — WORKER RBAC
-- 097_seed_worker_roles_and_permissions.sql
-- ============================================================
--
-- OBJETIVO
-- ------------------------------------------------------------
-- 1. Crear el catálogo inicial de roles internos.
-- 2. Crear el catálogo granular de permisos.
-- 3. Asociar permisos con cada rol.
--
-- IMPORTANTE
-- ------------------------------------------------------------
-- Esta migración NO:
--   - modifica RLS existentes;
--   - modifica políticas existentes;
--   - modifica workers existentes;
--   - asigna automáticamente roles a workers;
--   - cambia permisos efectivos de ningún usuario.
--
-- Las asignaciones reales de trabajadores se harán posteriormente.
--
-- Dependencias:
--   095_worker_rbac_core.sql
--   096_worker_rbac_permission_functions.sql
--
-- ============================================================

BEGIN;

-- ============================================================
-- 0. PRE-CHECKS
-- ============================================================

DO $$
BEGIN

    IF to_regclass('public.worker_roles') IS NULL THEN
        RAISE EXCEPTION
            '097: falta public.worker_roles. Ejecuta primero 095.';
    END IF;

    IF to_regclass('public.worker_permissions') IS NULL THEN
        RAISE EXCEPTION
            '097: falta public.worker_permissions. Ejecuta primero 095.';
    END IF;

    IF to_regclass('public.worker_role_permissions') IS NULL THEN
        RAISE EXCEPTION
            '097: falta public.worker_role_permissions. Ejecuta primero 095.';
    END IF;

    IF to_regclass('public.worker_role_assignments') IS NULL THEN
        RAISE EXCEPTION
            '097: falta public.worker_role_assignments. Ejecuta primero 095.';
    END IF;

END;
$$;


-- ============================================================
-- 1. ROLES DEL SISTEMA
-- ============================================================

INSERT INTO public.worker_roles (
    code,
    name,
    description,
    is_system_role,
    is_active
)
VALUES

(
    'direction',
    'Dirección / Admin / CEO',
    'Acceso completo al sistema, incluyendo configuración, gestión de roles, trabajadores, salarios, auditoría, errores, webhooks y operaciones administrativas.',
    true,
    true
),

(
    'commercial',
    'Comercial / Ventas',
    'Gestión comercial de clientes, empresas y presupuestos. Consulta de facturación y pagos sin capacidad de modificación.',
    true,
    true
),

(
    'developer',
    'Developer / Automation Specialist',
    'Gestión técnica de proyectos, tareas, soporte, automatizaciones e inteligencia artificial. Acceso de lectura a clientes.',
    true,
    true
),

(
    'support',
    'Technical Support / Customer Success',
    'Gestión completa de soporte, consulta de clientes y consulta de proyectos.',
    true,
    true
),

(
    'accounting',
    'Contabilidad / Administración',
    'Gestión de facturación, pagos, gastos y finanzas. Consulta de clientes y presupuestos.',
    true,
    true
)

ON CONFLICT (code)
DO NOTHING;


-- ============================================================
-- 2. CATÁLOGO DE PERMISOS
-- ============================================================
--
-- Convención:
--
--   recurso.acción
--
-- Ejemplos:
--
--   clients.read
--   clients.update
--   quotations.create
--   billing.read
--   system.roles.manage
--
-- Los permisos representan capacidades funcionales.
-- La aplicación concreta sobre tablas/RLS se hará posteriormente.
-- ============================================================

INSERT INTO public.worker_permissions (
    code,
    resource,
    action,
    description
)
VALUES

-- ============================================================
-- CLIENTES
-- ============================================================

(
    'clients.read',
    'clients',
    'read',
    'Consultar clientes.'
),
(
    'clients.create',
    'clients',
    'create',
    'Crear clientes.'
),
(
    'clients.update',
    'clients',
    'update',
    'Modificar clientes.'
),
(
    'clients.delete',
    'clients',
    'delete',
    'Eliminar clientes.'
),

-- ============================================================
-- EMPRESAS
-- ============================================================

(
    'companies.read',
    'companies',
    'read',
    'Consultar empresas.'
),
(
    'companies.create',
    'companies',
    'create',
    'Crear empresas.'
),
(
    'companies.update',
    'companies',
    'update',
    'Modificar empresas.'
),
(
    'companies.delete',
    'companies',
    'delete',
    'Eliminar empresas.'
),

-- ============================================================
-- PRESUPUESTOS / QUOTATIONS
-- ============================================================

(
    'quotations.read',
    'quotations',
    'read',
    'Consultar presupuestos.'
),
(
    'quotations.create',
    'quotations',
    'create',
    'Crear presupuestos.'
),
(
    'quotations.update',
    'quotations',
    'update',
    'Modificar presupuestos.'
),
(
    'quotations.delete',
    'quotations',
    'delete',
    'Eliminar presupuestos.'
),
(
    'quotations.send',
    'quotations',
    'send',
    'Enviar o publicar presupuestos.'
),

-- ============================================================
-- DOCUMENTOS DE PRESUPUESTOS
-- ============================================================

(
    'quotation_documents.read',
    'quotation_documents',
    'read',
    'Consultar documentos asociados a presupuestos.'
),
(
    'quotation_documents.manage',
    'quotation_documents',
    'manage',
    'Subir, modificar y eliminar documentos de presupuestos.'
),

-- ============================================================
-- FACTURACIÓN
-- ============================================================

(
    'billing.read',
    'billing',
    'read',
    'Consultar facturación.'
),
(
    'billing.create',
    'billing',
    'create',
    'Crear facturas.'
),
(
    'billing.update',
    'billing',
    'update',
    'Modificar facturación.'
),
(
    'billing.delete',
    'billing',
    'delete',
    'Eliminar facturas.'
),

-- ============================================================
-- PAGOS
-- ============================================================

(
    'payments.read',
    'payments',
    'read',
    'Consultar pagos.'
),
(
    'payments.create',
    'payments',
    'create',
    'Registrar pagos.'
),
(
    'payments.update',
    'payments',
    'update',
    'Modificar pagos.'
),
(
    'payments.delete',
    'payments',
    'delete',
    'Eliminar o revertir registros de pagos.'
),

-- ============================================================
-- DOCUMENTOS DE FACTURACIÓN
-- ============================================================

(
    'billing_documents.read',
    'billing_documents',
    'read',
    'Consultar documentos de facturación.'
),
(
    'billing_documents.manage',
    'billing_documents',
    'manage',
    'Gestionar documentos de facturación.'
),

-- ============================================================
-- GASTOS
-- ============================================================

(
    'expenses.read',
    'expenses',
    'read',
    'Consultar gastos.'
),
(
    'expenses.create',
    'expenses',
    'create',
    'Crear gastos.'
),
(
    'expenses.update',
    'expenses',
    'update',
    'Modificar gastos.'
),
(
    'expenses.delete',
    'expenses',
    'delete',
    'Eliminar gastos.'
),

-- ============================================================
-- FINANZAS
-- ============================================================

(
    'finance.read',
    'finance',
    'read',
    'Consultar información financiera.'
),
(
    'finance.create',
    'finance',
    'create',
    'Crear registros financieros.'
),
(
    'finance.update',
    'finance',
    'update',
    'Modificar información financiera.'
),
(
    'finance.delete',
    'finance',
    'delete',
    'Eliminar registros financieros.'
),

-- ============================================================
-- PROYECTOS
-- ============================================================

(
    'projects.read',
    'projects',
    'read',
    'Consultar proyectos.'
),
(
    'projects.create',
    'projects',
    'create',
    'Crear proyectos.'
),
(
    'projects.update',
    'projects',
    'update',
    'Modificar proyectos.'
),
(
    'projects.delete',
    'projects',
    'delete',
    'Eliminar proyectos.'
),

-- ============================================================
-- TAREAS
-- ============================================================

(
    'project_tasks.read',
    'project_tasks',
    'read',
    'Consultar tareas de proyectos.'
),
(
    'project_tasks.create',
    'project_tasks',
    'create',
    'Crear tareas de proyectos.'
),
(
    'project_tasks.update',
    'project_tasks',
    'update',
    'Modificar tareas de proyectos.'
),
(
    'project_tasks.delete',
    'project_tasks',
    'delete',
    'Eliminar tareas de proyectos.'
),

-- ============================================================
-- HITOS / MILESTONES
-- ============================================================

(
    'project_milestones.read',
    'project_milestones',
    'read',
    'Consultar hitos de proyectos.'
),
(
    'project_milestones.create',
    'project_milestones',
    'create',
    'Crear hitos de proyectos.'
),
(
    'project_milestones.update',
    'project_milestones',
    'update',
    'Modificar hitos de proyectos.'
),
(
    'project_milestones.delete',
    'project_milestones',
    'delete',
    'Eliminar hitos de proyectos.'
),

-- ============================================================
-- ACTUALIZACIONES DE PROYECTOS
-- ============================================================

(
    'project_updates.read',
    'project_updates',
    'read',
    'Consultar actualizaciones de proyectos.'
),
(
    'project_updates.create',
    'project_updates',
    'create',
    'Crear actualizaciones de proyectos.'
),
(
    'project_updates.update',
    'project_updates',
    'update',
    'Modificar actualizaciones de proyectos.'
),
(
    'project_updates.delete',
    'project_updates',
    'delete',
    'Eliminar actualizaciones de proyectos.'
),

-- ============================================================
-- SOPORTE
-- ============================================================

(
    'support.read',
    'support',
    'read',
    'Consultar tickets y solicitudes de soporte.'
),
(
    'support.create',
    'support',
    'create',
    'Crear tickets y solicitudes de soporte.'
),
(
    'support.update',
    'support',
    'update',
    'Modificar y gestionar tickets de soporte.'
),
(
    'support.delete',
    'support',
    'delete',
    'Eliminar tickets de soporte.'
),

-- ============================================================
-- MANTENIMIENTO
-- ============================================================

(
    'maintenance.read',
    'maintenance',
    'read',
    'Consultar contratos y operaciones de mantenimiento.'
),
(
    'maintenance.create',
    'maintenance',
    'create',
    'Crear registros de mantenimiento.'
),
(
    'maintenance.update',
    'maintenance',
    'update',
    'Modificar registros de mantenimiento.'
),
(
    'maintenance.delete',
    'maintenance',
    'delete',
    'Eliminar registros de mantenimiento.'
),

-- ============================================================
-- PROPUESTAS DE MANTENIMIENTO
-- ============================================================

(
    'maintenance_proposals.read',
    'maintenance_proposals',
    'read',
    'Consultar propuestas personalizadas de mantenimiento.'
),
(
    'maintenance_proposals.create',
    'maintenance_proposals',
    'create',
    'Crear propuestas personalizadas de mantenimiento.'
),
(
    'maintenance_proposals.update',
    'maintenance_proposals',
    'update',
    'Modificar propuestas personalizadas de mantenimiento.'
),
(
    'maintenance_proposals.delete',
    'maintenance_proposals',
    'delete',
    'Eliminar propuestas personalizadas de mantenimiento.'
),

-- ============================================================
-- AUTOMATIZACIONES
-- ============================================================

(
    'automations.read',
    'automations',
    'read',
    'Consultar automatizaciones.'
),
(
    'automations.create',
    'automations',
    'create',
    'Crear automatizaciones.'
),
(
    'automations.update',
    'automations',
    'update',
    'Modificar automatizaciones.'
),
(
    'automations.delete',
    'automations',
    'delete',
    'Eliminar automatizaciones.'
),
(
    'automations.execute',
    'automations',
    'execute',
    'Ejecutar automatizaciones.'
),

-- ============================================================
-- INTELIGENCIA ARTIFICIAL
-- ============================================================

(
    'ai.read',
    'ai',
    'read',
    'Consultar información y configuración de IA.'
),
(
    'ai.use',
    'ai',
    'use',
    'Utilizar funcionalidades de IA.'
),
(
    'ai.manage',
    'ai',
    'manage',
    'Gestionar configuración y funcionalidades de IA.'
),

-- ============================================================
-- CONFIGURACIÓN DEL SISTEMA
-- ============================================================

(
    'system.settings.read',
    'system',
    'settings_read',
    'Consultar configuración del sistema.'
),
(
    'system.settings.update',
    'system',
    'settings_update',
    'Modificar configuración del sistema.'
),

-- ============================================================
-- ROLES
-- ============================================================

(
    'system.roles.read',
    'system',
    'roles_read',
    'Consultar roles y permisos.'
),
(
    'system.roles.manage',
    'system',
    'roles_manage',
    'Crear, modificar y asignar roles y permisos.'
),

-- ============================================================
-- TRABAJADORES
-- ============================================================

(
    'system.workers.read',
    'system',
    'workers_read',
    'Consultar trabajadores y su información administrativa.'
),
(
    'system.workers.manage',
    'system',
    'workers_manage',
    'Gestionar trabajadores, estados y asignaciones.'
),

-- ============================================================
-- SALARIOS
-- ============================================================

(
    'system.salaries.read',
    'system',
    'salaries_read',
    'Consultar información salarial.'
),
(
    'system.salaries.update',
    'system',
    'salaries_update',
    'Modificar información salarial.'
),

-- ============================================================
-- DATOS / OPERACIONES DESTRUCTIVAS
-- ============================================================

(
    'system.data.delete',
    'system',
    'data_delete',
    'Ejecutar operaciones administrativas de eliminación de datos.'
),

-- ============================================================
-- AUDITORÍA
-- ============================================================

(
    'system.audit.read',
    'system',
    'audit_read',
    'Consultar registros de auditoría.'
),

-- ============================================================
-- ERROR LOGS
-- ============================================================

(
    'system.errors.read',
    'system',
    'errors_read',
    'Consultar registros de errores internos.'
),
(
    'system.errors.manage',
    'system',
    'errors_manage',
    'Gestionar y resolver registros de errores internos.'
),

-- ============================================================
-- WEBHOOK STATUS
-- ============================================================

(
    'system.webhooks.read',
    'system',
    'webhooks_read',
    'Consultar estado, eventos y errores de webhooks.'
),
(
    'system.webhooks.manage',
    'system',
    'webhooks_manage',
    'Gestionar configuración y operaciones de webhooks.'
)

ON CONFLICT (code)
DO NOTHING;


-- ============================================================
-- 3. DIRECCIÓN
-- ============================================================
--
-- Dirección recibe TODOS los permisos existentes.
--
-- Esto incluye:
--   - clientes
--   - empresas
--   - presupuestos
--   - facturación
--   - pagos
--   - gastos
--   - finanzas
--   - proyectos
--   - tareas
--   - soporte
--   - mantenimiento
--   - automatizaciones
--   - IA
--   - configuración
--   - roles
--   - trabajadores
--   - salarios
--   - auditoría
--   - error logs
--   - webhooks
--   - operaciones destructivas
--
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
CROSS JOIN public.worker_permissions p
WHERE r.code = 'direction'
  AND NOT EXISTS (
      SELECT 1
      FROM public.worker_role_permissions rp
      WHERE rp.role_id = r.id
        AND rp.permission_id = p.id
  );


-- ============================================================
-- 4. COMERCIAL / VENTAS
-- ============================================================
--
-- CLIENTES / EMPRESAS:
--   lectura + edición
--
-- PRESUPUESTOS:
--   acceso completo
--
-- FACTURACIÓN / PAGOS:
--   solo lectura
--
-- PROYECTOS / SOPORTE / GASTOS / FINANZAS:
--   sin permisos
--
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
JOIN public.worker_permissions p
    ON p.code IN (

        -- Clientes
        'clients.read',
        'clients.update',

        -- Empresas
        'companies.read',
        'companies.update',

        -- Presupuestos
        'quotations.read',
        'quotations.create',
        'quotations.update',
        'quotations.delete',
        'quotations.send',

        -- Documentos de presupuestos
        'quotation_documents.read',
        'quotation_documents.manage',

        -- Facturación: solo lectura
        'billing.read',

        -- Pagos: solo lectura
        'payments.read'

    )
WHERE r.code = 'commercial'
  AND NOT EXISTS (
      SELECT 1
      FROM public.worker_role_permissions rp
      WHERE rp.role_id = r.id
        AND rp.permission_id = p.id
  );


-- ============================================================
-- 5. DEVELOPER / AUTOMATION SPECIALIST
-- ============================================================
--
-- PROYECTOS:
--   completo
--
-- TAREAS:
--   completo
--
-- MILESTONES / UPDATES:
--   completo
--
-- SOPORTE:
--   completo
--
-- CLIENTES:
--   solo lectura
--
-- AUTOMATIZACIONES:
--   completo
--
-- IA:
--   completo
--
-- QUOTATIONS / BILLING / PAYMENTS / EXPENSES / FINANCE:
--   sin permisos
--
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
JOIN public.worker_permissions p
    ON p.code IN (

        -- Clientes: lectura
        'clients.read',

        -- Proyectos
        'projects.read',
        'projects.create',
        'projects.update',
        'projects.delete',

        -- Tareas
        'project_tasks.read',
        'project_tasks.create',
        'project_tasks.update',
        'project_tasks.delete',

        -- Milestones
        'project_milestones.read',
        'project_milestones.create',
        'project_milestones.update',
        'project_milestones.delete',

        -- Updates
        'project_updates.read',
        'project_updates.create',
        'project_updates.update',
        'project_updates.delete',

        -- Soporte
        'support.read',
        'support.create',
        'support.update',
        'support.delete',


        -- Automatizaciones
        'automations.read',
        'automations.create',
        'automations.update',
        'automations.delete',
        'automations.execute',

        -- IA
        'ai.use',
        'ai.manage'

    )
WHERE r.code = 'developer'
  AND NOT EXISTS (
      SELECT 1
      FROM public.worker_role_permissions rp
      WHERE rp.role_id = r.id
        AND rp.permission_id = p.id
  );


-- ============================================================
-- 6. TECHNICAL SUPPORT / CUSTOMER SUCCESS
-- ============================================================
--
-- SOPORTE:
--   completo
--
-- CLIENTES:
--   solo lectura
--
-- PROYECTOS:
--   solo lectura
--
-- PRESUPUESTOS / FACTURACIÓN / PAGOS / FINANZAS / GASTOS:
--   sin permisos
--
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
JOIN public.worker_permissions p
    ON p.code IN (

        -- Clientes: lectura
        'clients.read',

        -- Proyectos: lectura
        'projects.read',
        'project_milestones.read',
        'project_updates.read',

        -- Soporte: completo
        'support.read',
        'support.create',
        'support.update',
        'support.delete'


    )
WHERE r.code = 'support'
  AND NOT EXISTS (
      SELECT 1
      FROM public.worker_role_permissions rp
      WHERE rp.role_id = r.id
        AND rp.permission_id = p.id
  );


-- ============================================================
-- 7. CONTABILIDAD / ADMINISTRACIÓN
-- ============================================================
--
-- FACTURACIÓN:
--   completo
--
-- PAGOS:
--   completo
--
-- GASTOS:
--   completo
--
-- FINANZAS:
--   completo
--
-- PRESUPUESTOS:
--   solo lectura
--
-- CLIENTES:
--   solo lectura
--
-- PROYECTOS / SOPORTE:
--   sin permisos
--
-- ============================================================

INSERT INTO public.worker_role_permissions (
    role_id,
    permission_id
)
SELECT
    r.id,
    p.id
FROM public.worker_roles r
JOIN public.worker_permissions p
    ON p.code IN (

        -- Clientes
        'clients.read',

        -- Presupuestos
        'quotations.read',

        -- Documentos de presupuestos
        'quotation_documents.read',

        -- Facturación
        'billing.read',
        'billing.create',
        'billing.update',
        'billing.delete',

        -- Pagos
        'payments.read',
        'payments.create',
        'payments.update',
        'payments.delete',

        -- Documentos de facturación
        'billing_documents.read',
        'billing_documents.manage',

        -- Gastos
        'expenses.read',
        'expenses.create',
        'expenses.update',
        'expenses.delete',

        -- Finanzas
        'finance.read',
        'finance.create',
        'finance.update',
        'finance.delete'

    )
WHERE r.code = 'accounting'
  AND NOT EXISTS (
      SELECT 1
      FROM public.worker_role_permissions rp
      WHERE rp.role_id = r.id
        AND rp.permission_id = p.id
  );


-- ============================================================
-- 8. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

DO $$
DECLARE
    v_roles INTEGER;
    v_permissions INTEGER;
    v_role_permissions INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_roles
    FROM public.worker_roles
    WHERE code IN (
        'direction',
        'commercial',
        'developer',
        'support',
        'accounting'
    );

    IF v_roles <> 5 THEN
        RAISE EXCEPTION
            '097: se esperaban 5 roles del sistema y se encontraron %.',
            v_roles;
    END IF;


    SELECT COUNT(*)
    INTO v_permissions
    FROM public.worker_permissions;

    IF v_permissions < 70 THEN
        RAISE EXCEPTION
            '097: catálogo de permisos incompleto. Encontrados: %.',
            v_permissions;
    END IF;


    SELECT COUNT(*)
    INTO v_role_permissions
    FROM public.worker_role_permissions rp
    JOIN public.worker_roles r
        ON r.id = rp.role_id
    WHERE r.code IN (
        'direction',
        'commercial',
        'developer',
        'support',
        'accounting'
    );

    IF v_role_permissions = 0 THEN
        RAISE EXCEPTION
            '097: no se han creado asociaciones role-permission.';
    END IF;


    -- Dirección debe tener todos los permisos existentes.
    IF (
        SELECT COUNT(*)
        FROM public.worker_permissions p
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.worker_role_permissions rp
            JOIN public.worker_roles r
                ON r.id = rp.role_id
            WHERE r.code = 'direction'
              AND rp.permission_id = p.id
        )
    ) <> 0 THEN

        RAISE EXCEPTION
            '097: Dirección no tiene todos los permisos del catálogo.';
    END IF;


    -- Todos los roles deben estar activos.
    IF EXISTS (
        SELECT 1
        FROM public.worker_roles
        WHERE code IN (
            'direction',
            'commercial',
            'developer',
            'support',
            'accounting'
        )
        AND is_active IS NOT TRUE
    ) THEN

        RAISE EXCEPTION
            '097: existe un rol RBAC del sistema desactivado.';
    END IF;

END;
$$;


-- ============================================================
-- 9. VERIFICACIÓN DE PERMISOS CRÍTICOS
-- ============================================================

DO $$
BEGIN

    -- Dirección
    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'direction'
          AND p.code = 'system.data.delete'
    ) THEN
        RAISE EXCEPTION
            '097: Dirección no tiene system.data.delete.';
    END IF;


    -- Comercial
    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'commercial'
          AND p.code = 'quotations.create'
    ) THEN
        RAISE EXCEPTION
            '097: Comercial no tiene quotations.create.';
    END IF;


    -- Developer
    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'developer'
          AND p.code = 'automations.execute'
    ) THEN
        RAISE EXCEPTION
            '097: Developer no tiene automations.execute.';
    END IF;


    -- Support
    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'support'
          AND p.code = 'support.update'
    ) THEN
        RAISE EXCEPTION
            '097: Support no tiene support.update.';
    END IF;


    -- Accounting
    IF NOT EXISTS (
        SELECT 1
        FROM public.worker_role_permissions rp
        JOIN public.worker_roles r
            ON r.id = rp.role_id
        JOIN public.worker_permissions p
            ON p.id = rp.permission_id
        WHERE r.code = 'accounting'
          AND p.code = 'billing.create'
    ) THEN
        RAISE EXCEPTION
            '097: Accounting no tiene billing.create.';
    END IF;

END;
$$;


-- ============================================================
-- 10. COMENTARIOS
-- ============================================================

COMMENT ON TABLE public.worker_roles IS
'Catálogo de roles internos de trabajadores de Modira.';

COMMENT ON TABLE public.worker_permissions IS
'Catálogo granular de permisos RBAC internos de trabajadores.';

COMMENT ON TABLE public.worker_role_permissions IS
'Relación entre roles internos y permisos.';

COMMENT ON TABLE public.worker_role_assignments IS
'Asignación de uno o varios roles internos a trabajadores.';


-- ============================================================
-- 11. RESULTADO DE AUDITORÍA
-- ============================================================
--
-- Se deja esta consulta como comentario para poder ejecutarla
-- manualmente después de la migración:
--
-- SELECT
--     r.code AS role,
--     r.name,
--     COUNT(rp.permission_id) AS permissions
-- FROM public.worker_roles r
-- LEFT JOIN public.worker_role_permissions rp
--     ON rp.role_id = r.id
-- GROUP BY r.id, r.code, r.name
-- ORDER BY r.code;
--
-- ============================================================

COMMIT;

