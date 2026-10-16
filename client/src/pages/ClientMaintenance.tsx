import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import ClientFloatingActions from "@/components/ClientFloatingActions";
import { Input } from "@/components/ui/input";
import {
  AlertCircle,
  ArrowRight,
  BriefcaseBusiness,
  Check,
  CheckCircle2,
  CircleHelp,
  Clock3,
  CreditCard,
  FileText,
  Home,
  Info,
  Loader2,
  LogOut,
  Menu,
  MonitorCog,
  Receipt,
  RefreshCw,
  ShieldCheck,
  UserRound,
  Wrench,
  X,
} from "lucide-react";

/* ============================================================================
   TIPOS
   ========================================================================== */
type CompanyProject = {
  id: string;
  nombre: string | null;
  company_id: string;
};
type Plan = {
  id: string;
  code: string;
  nombre: string;
  descripcion: string | null;
  precio: number | null;
  moneda: string;
  periodicidad: string;
  es_personalizado: boolean;
  activo: boolean;
  stripe_product_id: string | null;
  stripe_price_id: string | null;
};

const MAINTENANCE_PLAN_COVERAGE: Record<string, {
  hours: string;
  scope: string;
  summary: string;
  benefits: string[];
}> = {
  essential: {
    hours: "Hasta 3 h/mes",
    scope: "Básico",
    summary: "Soporte y mantenimiento esencial.",
    benefits: [
      "Soporte técnico",
      "Resolución de incidencias",
      "Corrección de errores",
      "Consultas técnicas",
    ],
  },
  growth: {
    hours: "Hasta 6 h/mes",
    scope: "Estándar",
    summary: "Soporte y evolución.",
    benefits: [
      "Todo lo de Essential",
      "Soporte prioritario",
      "Optimización",
      "Ajustes de lógica",
      "Mejoras funcionales",
    ],
  },
  business: {
    hours: "Hasta 12 h/mes",
    scope: "Avanzado",
    summary: "Soporte y evolución avanzada.",
    benefits: [
      "Todo lo de Growth",
      "Atención prioritaria",
      "Monitorización avanzada",
      "Incidencias críticas prioritarias",
      "Asesoramiento técnico",
    ],
  },
};

type Contract = Record<string, any> & {
  id: string;
  user_id: string;
  company_id: string;
  plan_id: string | null;
  nombre_plan: string | null;
  descripcion: string | null;
  precio: number | null;
  moneda: string | null;
  periodicidad: string | null;
  estado: string | null;
  fecha_inicio: string | null;
  fecha_fin: string | null;
  current_period_start: string | null;
  current_period_end: string | null;
  renewal_day: number | null;
  cancel_at_period_end: boolean;
  cancel_requested_at: string | null;
  cancel_effective_at: string | null;
  pending_plan_id: string | null;
  pending_change_effective_at: string | null;
  pending_project_id: string | null;
  pending_project_change_effective_at: string | null;
  stripe_customer_id: string | null;
  stripe_subscription_id: string | null;
  stripe_subscription_item_id: string | null;
  stripe_price_id: string | null;
  plan_snapshot: Record<string, any> | null;
  maintenance_custom_proposal_id?: string | null;
  agreed_monthly_price?: number | null;
  scope_snapshot?: Record<string, any> | null;
  stripe_checkout_session_id?: string | null;
  contracted_at?: string | null;
  terms_version?: string | null;
  billing_failure_count?: number | null;
};

type MaintenanceProjectChangeRequest = Record<string, any> & {
  id: string;
  maintenance_contract_id: string;
  company_id: string;
  requested_by: string;
  current_project_id: string;
  requested_project_id: string;
  status: string;
  requested_at: string;
  reviewed_at: string | null;
  reviewed_by: string | null;
  effective_at: string | null;
  rejection_reason: string | null;
};

type MaintenanceInvoice = Record<string, any> & {
  id: string;
  maintenance_contract_id: string | null;
  company_id: string | null;
  user_id: string | null;
  serie: string;
  numero: number;
  estado: string;
  fecha_emision: string;
  fecha_operacion: string;
  fecha_vencimiento: string | null;
  fecha_pago: string | null;
  periodo_inicio: string;
  periodo_fin: string;
  descripcion: string;
  contract_snapshot: Record<string, any> | null;
  subtotal: number;
  iva_aplicado: boolean;
  iva_porcentaje: number;
  iva_importe: number;
  irpf_aplicado: boolean;
  irpf_porcentaje: number;
  irpf_importe: number;
  monto: number;
  importe_a_pagar: number;
  moneda: string;
  customer_legal_name: string;
  customer_tax_id: string;
  customer_address: string | null;
  customer_postal_code: string | null;
  customer_city: string | null;
  customer_province: string | null;
  customer_country: string;
  stripe_invoice_id: string | null;
  stripe_customer_id: string | null;
  electronic_format: string | null;
  electronic_document_storage_path: string | null;
  electronic_document_hash: string | null;
  pdf_storage_path: string | null;
  pdf_sha256: string | null;
  document_path?: string | null;
  document_mime_type?: string | null;
  document_file_size?: number | null;
  document_sha256?: string | null;
  document_uploaded_at?: string | null;
  document_uploaded_by?: string | null;
  stripe_pdf_storage_path?: string | null;
  stripe_pdf_sha256?: string | null;
  created_at: string;
  updated_at: string;
};

type CustomProposal = Record<string, any> & {
  id: string;
  user_id: string;
  company_id: string;
  plan_id: string;
  status: string;
  titulo: string;
  descripcion_necesidad: string | null;
  objetivos: string | null;
  prioridades: string | null;
  soluciones_actuales: string | null;
  proyectos_relacionados: string | null;
  automatizaciones_actuales: string | null;
  integraciones_actuales: string | null;
  tecnologias: string | null;
  sistemas_criticos: string | null;
  alcance_tecnico_solicitado: string | null;
  horas_mensuales_solicitadas: number | null;
  tipo_trabajo: string | null;
  nivel_soporte_solicitado: string | null;
  tiempo_respuesta_deseado: string | null;
  horario_soporte: string | null;
  soporte_fuera_horario: boolean;
  sla_solicitado: string | null;
  nivel_criticidad: string | null;
  impacto_incidencia: string | null;
  necesidad_monitorizacion: boolean;
  requisitos_seguridad: string | null;
  informacion_adicional: string | null;
  request_data: Record<string, any>;
  quoted_monthly_price: number | null;
  quoted_currency: string;
  quoted_hours_monthly: number | null;
  quoted_scope_level: string | null;
  quoted_service_level: string | null;
  quoted_sla: string | null;
  quoted_response_time: string | null;
  quoted_support_hours: string | null;
  quoted_description: string | null;
  quoted_terms: string | null;
  quoted_valid_until: string | null;
  quote_snapshot: Record<string, any> | null;
  accepted_at: string | null;
  accepted_by: string | null;
  rejected_at: string | null;
  rejected_by: string | null;
  rejection_reason: string | null;
  maintenance_contract_id: string | null;
  stripe_product_id: string | null;
  stripe_price_id: string | null;
  stripe_customer_id: string | null;
  stripe_subscription_id: string | null;
  stripe_subscription_item_id: string | null;
  submitted_at: string | null;
  reviewed_at: string | null;
  quoted_at: string | null;
  reviewed_by?: string | null;
  quoted_by?: string | null;
  clarification_requested_at?: string | null;
  clarification_requested_by?: string | null;
  clarification_message?: string | null;
  response_notes?: string | null;
  response_version?: number | null;
  current_document_id?: string | null;
  created_at: string;
  updated_at: string;
};

type CustomProposalDocument = Record<string, any> & {
  id: string;
  proposal_id: string;
  version: number;
  document_path: string;
  document_mime_type?: string | null;
  document_file_size?: number | null;
  document_sha256?: string | null;
  document_uploaded_at?: string | null;
  uploaded_by?: string | null;
  published_at?: string | null;
  created_at?: string | null;
};

type CustomProposalAcknowledgement = Record<string, any> & {
  id: string;
  proposal_id: string;
  document_id: string;
  user_id: string;
  company_id: string;
  document_path: string;
  document_sha256: string;
  acknowledgement_text_version: string;
  accepted_at: string;
};

type CustomProposalEvent = Record<string, any> & {
  id: string;
  proposal_id: string;
  event_type: string;
  status_from?: string | null;
  status_to?: string | null;
  message?: string | null;
  notes?: string | null;
  metadata?: Record<string, any> | null;
  created_at: string;
  created_by?: string | null;
};

type FiscalCompany = Record<string, any> & {
  id: string;
  legal_name?: string | null;
  company_name?: string | null;
  cif_vat?: string | null;
  address?: string | null;
  postal_code?: string | null;
  city?: string | null;
  province?: string | null;
  country?: string | null;
};

type CompanyFiscalRequest = Record<string, any> & {
  id: string;
  status: string;
  requested_at?: string | null;
  created_at?: string | null;
  requested_legal_name?: string | null;
  requested_cif_vat?: string | null;
  requested_billing_email?: string | null;
  requested_address?: string | null;
  requested_postal_code?: string | null;
  requested_city?: string | null;
  requested_province?: string | null;
  requested_country?: string | null;
  reason?: string | null;
  reviewed_at?: string | null;
  rejection_reason?: string | null;
};

const euro = new Intl.NumberFormat("es-ES", {
  style: "currency",
  currency: "EUR",
  minimumFractionDigits: 2,
});

const dateFormatter = new Intl.DateTimeFormat("es-ES", {
  day: "numeric",
  month: "long",
  year: "numeric",
});

const compactDateFormatter = new Intl.DateTimeFormat("es-ES", {
  day: "numeric",
  month: "short",
  year: "numeric",
});

const normalize = (value: unknown) => String(value ?? "").trim().toLowerCase();
const formatCurrency = (value: unknown, currency = "EUR") =>
  new Intl.NumberFormat("es-ES", {
    style: "currency",
    currency: String(currency || "EUR").toUpperCase(),
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
const formatDate = (value?: string | null) =>
  value ? dateFormatter.format(new Date(value)) : "—";
const formatCompactDate = (value?: string | null) =>
  value ? compactDateFormatter.format(new Date(value)) : "—";

const getMonthKey = (value?: string | null) => {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
};

const formatMonthLabel = (monthKey: string) => {
  const [year, month] = monthKey.split("-").map(Number);
  if (!year || !month) return monthKey;
  return new Intl.DateTimeFormat("es-ES", { month: "long", year: "numeric" })
    .format(new Date(year, month - 1, 1))
    .replace(/^./, (character) => character.toUpperCase());
};

const invoiceMatchesMonth = (invoice: MaintenanceInvoice, monthKey: string) => {
  if (!monthKey) return true;
  const start = getMonthKey(invoice.periodo_inicio || invoice.fecha_emision);
  const end = getMonthKey(invoice.periodo_fin || invoice.fecha_emision);
  if (!start || !end) return getMonthKey(invoice.fecha_emision) === monthKey;
  return start <= monthKey && monthKey <= end;
};

const isActiveContract = (contract?: Contract | null) =>
  Boolean(contract && ["activo", "pausado"].includes(normalize(contract.estado)));

const invoiceStatusLabel = (status: string) => {
  const value = normalize(status);
  const labels: Record<string, string> = {
    borrador: "Borrador",
    pendiente: "Pendiente",
    enviada: "Enviada",
    pagada: "Pagada",
    impagada: "Impagada",
    anulada: "Anulada",
    rectificada: "Rectificada",
  };
  return labels[value] || status;
};

const proposalStatusLabel = (status: string) => {
  const value = normalize(status);
  const labels: Record<string, string> = {
    draft: "Borrador",
    submitted: "Enviada",
    in_review: "En revisión",
    clarification_requested: "Información solicitada",
    quoted: "Propuesta disponible",
    accepted: "Aceptada",
    rejected: "Rechazada",
    cancelled: "Cancelada",
    expired: "Caducada",
  };
  return labels[value] || status;
};

const proposalEventLabel = (event: CustomProposalEvent) => {
  const type = normalize(event.event_type || event.status_to || "");
  const labels: Record<string, string> = {
    submitted: "Propuesta enviada",
    in_review: "Propuesta puesta en revisión",
    clarification_requested: "Información adicional solicitada",
    clarification_responded: "Información adicional recibida",
    quoted: "Propuesta económica enviada",
    rejected: "Propuesta rechazada",
    accepted: "Propuesta aceptada",
    document_uploaded: "Documento PDF añadido",
    document_published: "Documento PDF publicado",
    document_available: "Documento PDF disponible",
    document_acknowledged: "Documento PDF revisado y aceptado",
  };
  return labels[type] || event.message || event.notes || event.event_type || "Actualización de la propuesta";
};

const contractStatusLabel = (status: string | null | undefined) => {
  const value = normalize(status);
  if (value === "activo") return "Activo";
  if (value === "pausado") return "Pausado";
  if (value === "cancelado") return "Cancelado";
  return status || "Sin estado";
};

const statusPill = (status: string) => {
  const value = normalize(status);
  if (["activo", "pagada", "accepted"].includes(value)) {
    return "border-[#CDE8D8] bg-[#ECF8F1] text-[#247A49]";
  }
  if (["pausado", "pendiente", "quoted", "submitted", "in_review", "clarification_requested"].includes(value)) {
    return "border-[#DDD7E5] bg-[#F3F0F6] text-[#4B3E57]";
  }
  if (["impagada", "rejected", "expired", "anulada"].includes(value)) {
    return "border-[#E0E5EA] bg-[#F4F6F8] text-[#667386]";
  }
  return "border-[#E0E5EA] bg-[#F7F9FB] text-[#667386]";
};

const SectionTitle = ({
  eyebrow,
  title,
  action,
}: {
  eyebrow?: string;
  title: string;
  action?: ReactNode;
}) => (
  <div className="mb-5 flex items-end justify-between gap-4">
    <div className="min-w-0">
      {eyebrow && (
        <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
          {eyebrow}
        </p>
      )}
      <h2 className="text-xl font-semibold tracking-tight text-[#182A45] sm:text-2xl">
        {title}
      </h2>
    </div>
    {action && <div className="shrink-0">{action}</div>}
  </div>
);

/* ============================================================================
   SIDEBAR — MISMA ESTRUCTURA VISUAL QUE PRESUPUESTOS
   ========================================================================== */

const ClientAreaSidebar = ({
  isOpen,
  onToggle,
  location,
  onNavigate,
  onLogout,
}: {
  isOpen: boolean;
  onToggle: () => void;
  location: string;
  onNavigate: (path: string) => void;
  onLogout: () => void;
}) => {
  const navigationItems = [
    { label: "Inicio", path: "/area-cliente", icon: Home },
    { label: "Mi perfil", path: "#perfil", icon: UserRound },
    {
      label: "Mis proyectos",
      path: "/area-cliente/proyectos",
      icon: BriefcaseBusiness,
    },
    {
      label: "Mantenimiento",
      path: "/area-cliente/mantenimiento",
      icon: Wrench,
    },
    {
      label: "Presupuestos",
      path: "/area-cliente/presupuestos",
      icon: FileText,
    },
    {
      label: "Facturación",
      path: "/area-cliente/facturacion",
      icon: Receipt,
    },
    {
      label: "Documentos",
      path: "/area-cliente/documentos",
      icon: FileText,
    },
    {
      label: "Soporte técnico",
      path: "/area-cliente/soporte",
      icon: Wrench,
    },
    { label: "Ayuda", path: "#ayuda", icon: CircleHelp },
  ];

  const isActive = (path: string) => {
    if (path.startsWith("#")) return false;
    if (path === "/area-cliente") return location === "/area-cliente";
    return location.startsWith(path);
  };

  return (
    <>
      {isOpen && (
        <button
          type="button"
          aria-label="Cerrar menú"
          onClick={onToggle}
          className="fixed inset-0 z-40 bg-[#102A66]/5 lg:hidden"
        />
      )}

      <aside
        className={[
          "fixed left-0 top-0 z-50 flex h-screen flex-col border-r border-[#E3E8EE] bg-white transition-[width] duration-200 ease-out",
          isOpen ? "w-[236px]" : "w-[62px]",
        ].join(" ")}
      >
        <div className="flex h-[72px] shrink-0 items-center border-b border-[#E8ECF2] px-3">
          {isOpen ? (
            <>
              <div className="flex min-w-0 flex-1 items-center px-2">
                <span className="modira-font text-lg tracking-wide text-[#26344A]">
                  MODIRA
                </span>
              </div>

              <button
                type="button"
                onClick={onToggle}
                aria-label="Cerrar menú"
                title="Cerrar menú"
                className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-[#718096] transition-colors hover:bg-[#F2F5F9] hover:text-[#173B8F]"
              >
                <X className="h-4 w-4" strokeWidth={1.8} />
              </button>
            </>
          ) : (
            <button
              type="button"
              onClick={onToggle}
              aria-label="Abrir menú"
              title="Abrir menú"
              className="flex h-8 w-full items-center justify-center rounded-md text-[#718096] transition-colors hover:bg-[#F2F5F9] hover:text-[#173B8F]"
            >
              <Menu className="h-5 w-5" strokeWidth={1.8} />
            </button>
          )}
        </div>

        <nav className="flex-1 overflow-y-auto px-2 py-4">
          <div className="space-y-1">
            {navigationItems.map((item) => {
              const Icon = item.icon;
              const active = isActive(item.path);

              return (
                <button
                  key={item.label}
                  type="button"
                  onClick={() => onNavigate(item.path)}
                  title={!isOpen ? item.label : undefined}
                  className={[
                    "group flex w-full items-center rounded-md text-left transition-colors duration-150",
                    isOpen
                      ? "gap-3 px-3 py-2.5"
                      : "justify-center px-2 py-2.5",
                    active
                      ? "bg-[#173B8F] text-white"
                      : "text-[#647187] hover:bg-[#F3F5F8] hover:text-[#173B8F]",
                  ].join(" ")}
                >
                  <Icon
                    className="h-[17px] w-[17px] shrink-0"
                    strokeWidth={1.75}
                  />

                  {isOpen && (
                    <span className="truncate text-[12px] font-medium">
                      {item.label}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        </nav>

        <div className="shrink-0 border-t border-[#E8ECF2] p-2">
          <button
            type="button"
            onClick={onLogout}
            title={!isOpen ? "Cerrar sesión" : undefined}
            className={[
              "flex w-full items-center rounded-md text-[#718096] transition-colors duration-150 hover:bg-[#F3F5F8] hover:text-[#173B8F]",
              isOpen
                ? "gap-3 px-3 py-2.5"
                : "justify-center px-2 py-2.5",
            ].join(" ")}
          >
            <LogOut
              className="h-[17px] w-[17px] shrink-0"
              strokeWidth={1.75}
            />
            {isOpen && (
              <span className="text-[12px] font-medium">Cerrar sesión</span>
            )}
          </button>
        </div>
      </aside>
    </>
  );
};

/* ============================================================================
   COMPONENTES VISUALES
   ========================================================================== */

const StatCell = ({
  label,
  value,
  detail,
  icon: Icon,
  active,
  onClick,
}: {
  label: string;
  value: string | number;
  detail: string;
  icon: any;
  active?: boolean;
  onClick?: () => void;
}) => {
  const content = (
    <div className="flex h-full items-start justify-between gap-3">
      <div className="min-w-0">
        <p className={["text-[10px] font-semibold uppercase tracking-[0.13em]", active ? "text-white/75" : "text-[#8A95A4]"].join(" ")}>{label}</p>
        <p className={["mt-2 text-2xl font-semibold tracking-tight", active ? "text-white" : "text-[#1E2D43]"].join(" ")}>{value}</p>
        <p className={["mt-0.5 truncate text-xs", active ? "text-white/80" : "text-[#8A95A4]"].join(" ")}>{detail}</p>
      </div>
      <Icon className={["mt-0.5 h-4 w-4 shrink-0", active ? "text-white/80" : "text-[#A1AAB7]"].join(" ")} strokeWidth={1.7} />
    </div>
  );

  const className = [
    "min-h-[116px] px-5 py-5 sm:px-7",
    active ? "bg-[#173B8F] text-white" : "bg-white/50 text-[#1E2D43]",
    onClick ? "w-full text-left cursor-pointer hover:bg-[#F7F9FB] focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[#173B8F]" : "",
  ].join(" ");

  if (onClick) {
    return (
      <button type="button" onClick={onClick} className={className}>
        {content}
      </button>
    );
  }

  return <div className={className}>{content}</div>;
};

const InfoRow = ({ label, value }: { label: string; value: ReactNode }) => (
  <div className="flex flex-col gap-1 border-b border-[#E9EDF2] py-3.5 last:border-b-0 sm:flex-row sm:items-start sm:justify-between sm:gap-12">
    <span className="text-[11px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">{label}</span>
    <span className="text-right text-[13px] font-medium leading-5 text-[#344054]">{value || "—"}</span>
  </div>
);

const DetailBox = ({
  title,
  icon: Icon,
  children,
  action,
}: {
  title: ReactNode;
  icon?: any;
  children: ReactNode;
  action?: ReactNode;
}) => (
  <section className="border border-[#E3E8EE] bg-white">
    <div className="flex items-center justify-between gap-4 border-b border-[#E8ECF1] px-5 py-4 sm:px-6">
      <div className="flex min-w-0 items-center gap-2.5">
        {Icon && <Icon className="h-4 w-4 shrink-0 text-[#173B8F]" strokeWidth={1.8} />}
        <h3 className="text-[13px] font-semibold text-[#26344A]">{title}</h3>
      </div>
      {action}
    </div>
    <div className="px-5 sm:px-6">{children}</div>
  </section>
);

const EmptyState = ({ title, text, icon: Icon = Wrench }: { title: string; text: string; icon?: any }) => (
  <div className="border-y border-[#E7EBF0] py-12 text-center">
    <Icon className="mx-auto mb-4 h-7 w-7 text-[#AAB3BF]" strokeWidth={1.6} />
    <p className="text-[14px] font-semibold text-[#344054]">{title}</p>
    <p className="mx-auto mt-2 max-w-md text-[12px] leading-5 text-[#8792A2]">{text}</p>
  </div>
);

const ErrorState = ({ error, onRetry }: { error: string; onRetry: () => void }) => (
  <div className="border-y border-[#E7EBF0] py-8">
    <div className="flex items-start gap-3">
      <AlertCircle className="mt-0.5 h-5 w-5 shrink-0 text-[#B53A3A]" strokeWidth={1.7} />
      <div className="min-w-0">
        <p className="text-[13px] font-semibold text-[#26344A]">No se pudo cargar el mantenimiento</p>
        <p className="mt-1 text-[12px] leading-5 text-[#718096]">{error}</p>
        <button type="button" onClick={onRetry} className="mt-4 inline-flex items-center gap-2 rounded-lg border border-[#DCE2E9] px-3.5 py-2 text-[12px] font-semibold text-[#173B8F] hover:bg-[#F7F9FB]">
          <RefreshCw className="h-3.5 w-3.5" /> Reintentar
        </button>
      </div>
    </div>
  </div>
);

/* ============================================================================
   FORMULARIO CUSTOM — CAMPOS EXACTOS DE 069 + request_data
   ========================================================================== */

const CustomProposalPage = ({
  proposal,
  plans,
  companyProjects,
  getProjectContract,
  loading,
  onReload,
  onAcknowledgeProposalDocument,
  onAcceptProposal,
  proposalAcknowledged,
  proposalAcknowledging,
  clarificationResponse,
  onClarificationResponseChange,
  clarificationSaving,
  onSubmitClarificationResponse,
  proposalDocuments,
  onOpenProposalDocument,
  sidebarOpen,
  onToggleSidebar,
  location,
  onNavigate,
  onLogout,
}: {
  proposal: CustomProposal | null;
  plans: Plan[];
  companyProjects: CompanyProject[];
  getProjectContract: (projectId: string) => Contract | null;
  loading: boolean;
  onReload: () => Promise<void>;
  onAcknowledgeProposalDocument: () => Promise<boolean>;
  onAcceptProposal: () => Promise<boolean>;
  proposalAcknowledged: boolean;
  proposalAcknowledging: boolean;
  clarificationResponse: string;
  onClarificationResponseChange: (value: string) => void;
  clarificationSaving: boolean;
  onSubmitClarificationResponse: () => Promise<void>;
  proposalDocuments: CustomProposalDocument[];
  onOpenProposalDocument: (document: CustomProposalDocument) => Promise<void>;
  sidebarOpen: boolean;
  onToggleSidebar: () => void;
  location: string;
  onNavigate: (path: string) => void;
  onLogout: () => void;
}) => {
  const [form, setForm] = useState<Record<string, any>>({
    titulo: "",
    descripcion_necesidad: "",
    objetivos: "",
    prioridades: "",
    soluciones_actuales: "",
    proyectos_relacionados: "",
    automatizaciones_actuales: "",
    integraciones_actuales: "",
    tecnologias: "",
    sistemas_criticos: "",
    alcance_tecnico_solicitado: "",
    horas_mensuales_solicitadas: "",
    tipo_trabajo: "",
    nivel_soporte_solicitado: "",
    tiempo_respuesta_deseado: "",
    horario_soporte: "",
    soporte_fuera_horario: false,
    sla_solicitado: "",
    nivel_criticidad: "",
    impacto_incidencia: "",
    necesidad_monitorizacion: false,
    requisitos_seguridad: "",
    informacion_adicional: "",
  });
  const [saving, setSaving] = useState(false);
  const [checkoutLoading, setCheckoutLoading] = useState(false);
  const [customProjectPickerOpen, setCustomProjectPickerOpen] = useState(false);
  const [customProjectId, setCustomProjectId] = useState<string | null>(null);
  const [acceptGeneralConditions, setAcceptGeneralConditions] = useState(false);
const [acceptSpecificConditions, setAcceptSpecificConditions] = useState(false);

  useEffect(() => {
    if (!proposal) return;
    setForm({
      titulo: proposal.titulo || "",
      descripcion_necesidad: proposal.descripcion_necesidad || "",
      objetivos: proposal.objetivos || "",
      prioridades: proposal.prioridades || "",
      soluciones_actuales: proposal.soluciones_actuales || "",
      proyectos_relacionados: proposal.proyectos_relacionados || "",
      automatizaciones_actuales: proposal.automatizaciones_actuales || "",
      integraciones_actuales: proposal.integraciones_actuales || "",
      tecnologias: proposal.tecnologias || "",
      sistemas_criticos: proposal.sistemas_criticos || "",
      alcance_tecnico_solicitado: proposal.alcance_tecnico_solicitado || "",
      horas_mensuales_solicitadas: proposal.horas_mensuales_solicitadas ?? "",
      tipo_trabajo: proposal.tipo_trabajo || "",
      nivel_soporte_solicitado: proposal.nivel_soporte_solicitado || "",
      tiempo_respuesta_deseado: proposal.tiempo_respuesta_deseado || "",
      horario_soporte: proposal.horario_soporte || "",
      soporte_fuera_horario: Boolean(proposal.soporte_fuera_horario),
      sla_solicitado: proposal.sla_solicitado || "",
      nivel_criticidad: proposal.nivel_criticidad || "",
      impacto_incidencia: proposal.impacto_incidencia || "",
      necesidad_monitorizacion: Boolean(proposal.necesidad_monitorizacion),
      requisitos_seguridad: proposal.requisitos_seguridad || "",
      informacion_adicional: proposal.informacion_adicional || "",
    });
  }, [proposal]);

  const setField = (key: string, value: any) => setForm((current) => ({ ...current, [key]: value }));
  const editable = !proposal || normalize(proposal.status) === "draft";
  const customPlan = plans.find((plan) => plan.code === "custom");

  const submit = async () => {
    if (!String(form.titulo || "").trim()) {
      toast.error("Indica un título para la propuesta.");
      return;
    }

    setSaving(true);
    try {
      const payload = {
        p_titulo: String(form.titulo).trim(),
        p_descripcion_necesidad: form.descripcion_necesidad || null,
        p_objetivos: form.objetivos || null,
        p_prioridades: form.prioridades || null,
        p_soluciones_actuales: form.soluciones_actuales || null,
        p_proyectos_relacionados: form.proyectos_relacionados || null,
        p_automatizaciones_actuales: form.automatizaciones_actuales || null,
        p_integraciones_actuales: form.integraciones_actuales || null,
        p_tecnologias: form.tecnologias || null,
        p_sistemas_criticos: form.sistemas_criticos || null,
        p_alcance_tecnico_solicitado: form.alcance_tecnico_solicitado || null,
        p_horas_mensuales_solicitadas:
          form.horas_mensuales_solicitadas === "" ? null : Number(form.horas_mensuales_solicitadas),
        p_tipo_trabajo: form.tipo_trabajo || null,
        p_nivel_soporte_solicitado: form.nivel_soporte_solicitado || null,
        p_tiempo_respuesta_deseado: form.tiempo_respuesta_deseado || null,
        p_horario_soporte: form.horario_soporte || null,
        p_soporte_fuera_horario: Boolean(form.soporte_fuera_horario),
        p_sla_solicitado: form.sla_solicitado || null,
        p_nivel_criticidad: form.nivel_criticidad || null,
        p_impacto_incidencia: form.impacto_incidencia || null,
        p_necesidad_monitorizacion: Boolean(form.necesidad_monitorizacion),
        p_requisitos_seguridad: form.requisitos_seguridad || null,
        p_informacion_adicional: form.informacion_adicional || null,
        p_request_data: {},
      };

      if (proposal) {
        toast.error("La propuesta ya existe. El formulario solo puede crear una nueva propuesta cuando no hay una abierta.");
        return;
      }
const { data, error } = await supabase.rpc(
  "create_custom_maintenance_proposal",
  payload
);


      if (error) throw error;
      toast.success("Propuesta creada. Ahora puedes enviarla a Modira.");
      await onReload();
    } catch (error: any) {
      toast.error(error?.message || "No se pudo crear la propuesta personalizada.");
    } finally {
      setSaving(false);
    }
  };

  const send = async () => {
    if (!proposal) return;
    setSaving(true);
    try {
      const { error } = await supabase.rpc("submit_custom_maintenance_proposal", {
        p_proposal_id: proposal.id,
      });
      if (error) throw error;
      toast.success("Propuesta enviada correctamente a Modira.");
      await onReload();
    } catch (error: any) {
      toast.error(error?.message || "No se pudo enviar la propuesta.");
    } finally {
      setSaving(false);
    }
  };

  const acceptAndCheckout = async (projectId?: string | null) => {
    if (!proposal) return;

    if (!proposal.current_document_id) {
      toast.error("Modira todavía no ha adjuntado el PDF de la propuesta.");
      return;
    }
    if (normalize(proposal.status) !== "accepted") {
      toast.error("Primero debes aceptar la propuesta antes de contratarla.");
      return;
    }
    const availableProjects = companyProjects.filter((project) => !getProjectContract(project.id));

    if (!projectId && availableProjects.length === 0) {
      toast.error("Todos los proyectos de tu empresa ya tienen un mantenimiento activo.");
      return;
    }

    if (!projectId) {
  setCustomProjectId(
    availableProjects.length === 1 ? availableProjects[0].id : null
  );
  setAcceptGeneralConditions(false);
  setAcceptSpecificConditions(false);
  setCustomProjectPickerOpen(true);
  return;
}

    if (!projectId) {
      toast.error("Selecciona un proyecto para continuar.");
      return;
    }

    if (getProjectContract(projectId)) {
      toast.error("El proyecto seleccionado ya tiene un mantenimiento activo.");
      return;
    }
if (!acceptGeneralConditions || !acceptSpecificConditions) {
  toast.error(
    "Debes aceptar las condiciones generales y particulares del mantenimiento."
  );
  return;
}
    setCheckoutLoading(true);
    try {
      const { data, error } = await supabase.functions.invoke("maintenance-stripe", {
        body: {
          action: "accept_custom_maintenance_proposal",
          proposal_id: proposal.id,
          project_id: projectId,
          accept_general_conditions: acceptGeneralConditions,
          accept_specific_conditions: acceptSpecificConditions,
          success_url: `${window.location.origin}/area-cliente/mantenimiento?checkout=success&custom_proposal=${proposal.id}`,
          cancel_url: `${window.location.origin}/area-cliente/mantenimiento/personalizado?checkout=cancelled&custom_proposal=${proposal.id}`,
        },
      });
      if (error) throw error;
      if (!data?.checkout_url) throw new Error("Stripe no ha devuelto una URL de pago.");
      window.location.assign(data.checkout_url);
    } catch (error: any) {
      toast.error(error?.message || "No se pudo iniciar la contratación.");
    } finally {
      setCheckoutLoading(false);
    }
  };

  const field = (key: string, label: string, placeholder: string, options?: { textarea?: boolean; required?: boolean }) => {
    const value = form[key] ?? "";
    return (
      <label className="block">
        <span className="mb-2 block text-[11px] font-semibold uppercase tracking-[0.08em] text-[#7C8797]">
          {label}{options?.required ? " *" : ""}
        </span>
        {options?.textarea ? (
          <textarea
            value={value}
            onChange={(e) => setField(key, e.target.value)}
            disabled={!editable}
            placeholder={placeholder}
            className="min-h-[110px] w-full resize-y rounded-none border border-[#DCE2E9] bg-[#FBFCFE] px-3.5 py-3 text-[13px] text-[#344054] outline-none transition focus:border-[#173B8F] focus:ring-1 focus:ring-[#173B8F] disabled:cursor-not-allowed disabled:bg-[#F6F8FA]"
          />
        ) : (
          <Input
            value={value}
            onChange={(e) => setField(key, e.target.value)}
            disabled={!editable}
            placeholder={placeholder}
            className="h-11 rounded-none border-[#DCE2E9] bg-[#FBFCFE] text-[13px] disabled:bg-[#F6F8FA]"
          />
        )}
      </label>
    );
  };

  return (
    <div className="min-h-screen bg-[#FBFCFE] text-[#26344A]">
      <ClientAreaSidebar
        isOpen={sidebarOpen}
        onToggle={onToggleSidebar}
        location={location}
        onNavigate={onNavigate}
        onLogout={onLogout}
      />

      <main
        className={[
          sidebarOpen ? "ml-[62px] lg:ml-[236px]" : "ml-[62px]",
          "[scrollbar-gutter:stable]",
        ].join(" ")}
      >
        <ClientFloatingActions />

        <div className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
          <section className="mb-8 border-b border-[#E6EAF0] pb-8">
            <button
              type="button"
              onClick={() => onNavigate("/area-cliente/mantenimiento")}
              className="mb-5 inline-flex items-center gap-1.5 text-[11px] font-medium text-[#718096] transition-colors hover:text-[#173B8F]"
            >
              <ArrowRight className="h-3.5 w-3.5 rotate-180" />
              Volver a mantenimiento
            </button>
            <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
              Área de Cliente
            </p>
            <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">
              Solución de mantenimiento personalizada
            </h1>
            <p className="mt-1.5 max-w-3xl text-sm leading-6 text-[#718096]">
              Cuéntanos qué necesitas mantener, qué sistemas intervienen y el nivel de soporte que buscas. Modira revisará la solicitud y, si procede, te devolverá una propuesta económica y de servicio.
            </p>
          </section>

          {proposal && (
            <div className="mb-7 flex flex-wrap items-center justify-between gap-3 border-y border-[#E5E9EF] py-4">
              <div className="flex items-center gap-3">
                <span className={["rounded-full border px-2.5 py-1 text-[10px] font-semibold", statusPill(proposal.status)].join(" ")}>{proposalStatusLabel(proposal.status)}</span>
                <span className="text-[11px] text-[#8A95A5]">Creada {formatCompactDate(proposal.created_at)}</span>
              </div>
              {proposal.submitted_at && <span className="text-[11px] text-[#8A95A5]">Enviada {formatCompactDate(proposal.submitted_at)}</span>}
            </div>
          )}

          {proposal?.status === "quoted" && (
            <section className="mb-8 overflow-hidden border border-[#DDD7E5] bg-[#F8F5FA]">
              <div className="border-b border-[#E5DFE9] px-5 py-5 sm:px-7">
                <p className="text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C6D88]">Propuesta de Modira</p>
                <div className="mt-2 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
                  <div>
                    <h2 className="text-xl font-semibold text-[#332A3B]">Tu mantenimiento personalizado está listo</h2>
                    <p className="mt-1 text-[13px] leading-5 text-[#756A7D]">Revisa todas las condiciones antes de aceptar y continuar con la contratación.</p>
                  </div>
                  <div className="text-left sm:text-right">
                    <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8A7C94]">Cuota mensual</p>
                    <p className="mt-1 text-3xl font-semibold tracking-tight text-[#332A3B]">{formatCurrency(proposal.quoted_monthly_price, proposal.quoted_currency)}</p>
                  </div>
                </div>
              </div>
              <div className="grid gap-0 border-b border-[#E5DFE9] sm:grid-cols-2">
                <div className="border-b border-[#E5DFE9] px-5 py-4 sm:border-b-0 sm:border-r sm:px-7"><InfoRow label="Horas mensuales" value={proposal.quoted_hours_monthly ? `${proposal.quoted_hours_monthly} h/mes` : "A medida"} /></div>
                <div className="px-5 py-4 sm:px-7"><InfoRow label="Alcance" value={proposal.quoted_scope_level || "A medida"} /><InfoRow label="Nivel de servicio" value={proposal.quoted_service_level || "A medida"} /></div>
              </div>
              <div className="grid gap-5 px-5 py-5 sm:grid-cols-2 sm:px-7">
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8A7C94]">Descripción</p>
                  <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#4C4054]">{proposal.quoted_description || "Sin descripción adicional."}</p>
                </div>
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8A7C94]">Condiciones</p>
                  <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#4C4054]">{proposal.quoted_terms || "Sin condiciones adicionales."}</p>
                </div>
              </div>
             <div className="flex flex-col gap-3 border-t border-[#E5DFE9] px-5 py-5 sm:flex-row sm:items-center sm:justify-between sm:px-7">
  <div className="text-[11px] leading-5 text-[#756A7D]">
    {proposal.quoted_valid_until ? <>Propuesta válida hasta <strong>{formatDate(proposal.quoted_valid_until)}</strong>.</> : "Propuesta sin fecha de caducidad indicada."}
  </div>
</div>
            </section>
          )}

          {proposal?.status === "clarification_requested" && (
            <section className="mb-8 overflow-hidden border border-[#DDD7E5] bg-[#F8F5FA]">
              <div className="border-b border-[#E5DFE9] px-5 py-5 sm:px-7">
                <p className="text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C6D88]">Respuesta de Modira</p>
                <h2 className="mt-2 text-xl font-semibold text-[#332A3B]">Necesitamos información adicional</h2>
                <p className="mt-1 text-[13px] leading-5 text-[#756A7D]">
                  Modira ha revisado tu solicitud y necesita que aportes la información indicada antes de poder preparar la propuesta.
                </p>
              </div>
              <div className="px-5 py-5 sm:px-7">
                <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8A7C94]">Solicitud de información</p>
                <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#4C4054]">
                  {proposal.clarification_message || "Modira ha solicitado información adicional sobre tu solicitud."}
                </p>
                <label className="mt-5 block">
                  <span className="mb-2 block text-[11px] font-semibold uppercase tracking-[0.08em] text-[#7C8797]">Tu respuesta</span>
                  <textarea
                    value={clarificationResponse}
                    onChange={(e) => onClarificationResponseChange(e.target.value)}
                    className="min-h-[150px] w-full resize-y border border-[#DCE2E9] bg-white px-3.5 py-3 text-[13px] text-[#344054] outline-none focus:border-[#173B8F] focus:ring-1 focus:ring-[#173B8F]"
                    placeholder="Escribe aquí la información adicional que quieres enviar a Modira."
                  />
                </label>
                <div className="mt-5 flex justify-end">
                  <button type="button" onClick={() => void onSubmitClarificationResponse()} disabled={clarificationSaving} className="inline-flex h-11 items-center justify-center gap-2 rounded-full bg-[#173B8F] px-5 text-[12px] font-semibold text-white hover:bg-[#102F78] disabled:cursor-not-allowed disabled:opacity-60">
                    {clarificationSaving ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowRight className="h-4 w-4" />}
                    Enviar información a Modira
                  </button>
                </div>
              </div>
            </section>
          )}

          {proposal?.status === "quoted" && proposal.current_document_id && (
            <section className="mb-8">
                          </section>
          )}

         

          {proposal?.status === "rejected" && (
            <div className="mb-8 flex items-start gap-3 rounded-xl border border-[#E0E5EA] bg-[#F4F6F8] p-4 text-[#667386]">
              <AlertCircle className="mt-0.5 h-5 w-5 shrink-0" />
              <div><p className="text-[13px] font-semibold">La propuesta ha sido rechazada</p><p className="mt-1 text-[12px] leading-5">{proposal.rejection_reason || "Modira ha indicado que esta propuesta no puede formalizarse en las condiciones solicitadas."}</p></div>
            </div>
          )}

          {!proposal && (
            <>
              <DetailBox title="Necesidad y objetivos" icon={FileText}>
                <div className="grid gap-5 py-5 sm:grid-cols-2">
                  {field("titulo", "Título de la propuesta", "Ej. Mantenimiento integral de plataforma", { required: true })}
                  {field("horas_mensuales_solicitadas", "Horas mensuales estimadas", "Ej. 10")}
                  {field("descripcion_necesidad", "Necesidad", "Describe qué necesitas mantener y por qué.", { textarea: true })}
                  {field("objetivos", "Objetivos", "Qué quieres conseguir con el mantenimiento.", { textarea: true })}
                  {field("prioridades", "Prioridades", "Qué aspectos deben tener prioridad.", { textarea: true })}
                  {field("informacion_adicional", "Información adicional", "Cualquier contexto que debamos conocer.", { textarea: true })}
                </div>
              </DetailBox>

              <div className="mt-5 grid gap-5 lg:grid-cols-2">
                <DetailBox title="Ecosistema actual" icon={MonitorCog}>
                  <div className="space-y-1 py-3">
                    {field("soluciones_actuales", "Soluciones actuales", "Webs, aplicaciones, plataformas o servicios.", { textarea: true })}
                    {field("proyectos_relacionados", "Proyectos relacionados", "Proyectos que deberían quedar cubiertos.", { textarea: true })}
                    {field("automatizaciones_actuales", "Automatizaciones actuales", "Describe automatizaciones existentes.", { textarea: true })}
                    {field("integraciones_actuales", "Integraciones actuales", "APIs, CRM, Stripe, Make, n8n, Zapier, etc.", { textarea: true })}
                    {field("tecnologias", "Tecnologías", "Stack, backend, bases de datos, proveedores, etc.", { textarea: true })}
                  </div>
                </DetailBox>

                <DetailBox title="Alcance técnico" icon={Wrench}>
                  <div className="space-y-1 py-3">
                    {field("alcance_tecnico_solicitado", "Alcance solicitado", "Qué elementos quieres que queden cubiertos.", { textarea: true })}
                    {field("sistemas_criticos", "Sistemas críticos", "Sistemas cuya caída o fallo tenga impacto relevante.", { textarea: true })}
                    {field("tipo_trabajo", "Tipo de trabajo", "Incidencias, soporte, evolución, optimización, etc.")}
                    {field("nivel_soporte_solicitado", "Nivel de soporte", "Nivel de atención esperado.", { textarea: true })}
                  </div>
                </DetailBox>
              </div>

              <div className="mt-5 grid gap-5 lg:grid-cols-2">
                <DetailBox title="Soporte, SLA y criticidad" icon={Clock3}>
                  <div className="space-y-1 py-3">
                    {field("tiempo_respuesta_deseado", "Tiempo de respuesta", "Ej. < 4 horas para incidencias críticas.")}
                    {field("horario_soporte", "Horario de soporte", "Ej. Lunes a viernes, 09:00–18:00.")}
                    {field("sla_solicitado", "SLA solicitado", "Compromisos de servicio deseados.", { textarea: true })}
                    {field("nivel_criticidad", "Nivel de criticidad", "Describe el nivel de criticidad.")}
                    {field("impacto_incidencia", "Impacto de una incidencia", "Qué consecuencias tendría una incidencia.", { textarea: true })}
                    <label className="flex items-center gap-3 border-b border-[#E9EDF2] py-4">
                      <input type="checkbox" checked={Boolean(form.soporte_fuera_horario)} onChange={(e) => setField("soporte_fuera_horario", e.target.checked)} className="h-4 w-4 rounded border-[#C8D0DA] text-[#173B8F]" />
                      <span className="text-[13px] text-[#344054]">Necesito soporte fuera del horario estándar</span>
                    </label>
                    <label className="flex items-center gap-3 py-4">
                      <input type="checkbox" checked={Boolean(form.necesidad_monitorizacion)} onChange={(e) => setField("necesidad_monitorizacion", e.target.checked)} className="h-4 w-4 rounded border-[#C8D0DA] text-[#173B8F]" />
                      <span className="text-[13px] text-[#344054]">Necesito monitorización específica</span>
                    </label>
                  </div>
                </DetailBox>

                <DetailBox title="Seguridad y requisitos" icon={ShieldCheck}>
                  <div className="space-y-1 py-3">
                    {field("requisitos_seguridad", "Requisitos de seguridad", "Requisitos, controles, accesos, compliance, etc.", { textarea: true })}
                    <div className="border border-[#E8ECF1] bg-[#F8FAFC] p-4 text-[11px] leading-5 text-[#718096]">
                      El formulario respeta los límites de seguridad de la migración 070: campos individuales, máximo global de palabras, tamaño de request_data y máximo de 744 horas mensuales. La base de datos es la autoridad final.
                    </div>
                  </div>
                </DetailBox>
              </div>

              <div className="mt-6 flex flex-col gap-3 border-y border-[#E6EAF0] py-5 sm:flex-row sm:items-center sm:justify-between">
                <div className="text-[11px] leading-5 text-[#8792A2]">Plan seleccionado: <strong className="text-[#344054]">{customPlan?.nombre || "Custom"}</strong>. El precio se define después de la revisión de Modira.</div>
                <button type="button" onClick={submit} disabled={saving || loading} className="inline-flex h-11 items-center justify-center gap-2 rounded-full bg-[#173B8F] px-5 text-[12px] font-semibold text-white hover:bg-[#102F78] disabled:cursor-not-allowed disabled:opacity-60">
                  {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowRight className="h-4 w-4" />}
                  Crear propuesta
                </button>
              </div>
            </>
          )}

          {proposal && proposal.status === "draft" && (
            <div className="border border-[#E3E8EE] bg-white p-5 sm:p-7">
              <div className="mb-5"><h2 className="text-lg font-semibold text-[#26344A]">Tu solicitud está guardada como borrador</h2><p className="mt-1 text-[13px] text-[#718096]">La propuesta se ha creado correctamente. En esta versión de seguridad, la edición directa no está habilitada por SQL después de crearla; puedes enviarla a Modira cuando esté lista.</p></div>
              <div className="grid gap-0 border-y border-[#E9EDF2] sm:grid-cols-2">
                <InfoRow label="Título" value={proposal.titulo} />
                <InfoRow label="Horas solicitadas" value={proposal.horas_mensuales_solicitadas ? `${proposal.horas_mensuales_solicitadas} h/mes` : "No especificadas"} />
                <InfoRow label="Nivel de criticidad" value={proposal.nivel_criticidad || "No especificado"} />
                <InfoRow label="Monitorización" value={proposal.necesidad_monitorizacion ? "Sí" : "No"} />
              </div>
              <button type="button" onClick={send} disabled={saving} className="mt-5 inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-[#173B8F] px-5 text-[12px] font-semibold text-white hover:bg-[#102F78] disabled:opacity-60">
                {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowRight className="h-4 w-4" />} Enviar a Modira
              </button>
            </div>
          )}

          {proposal && ["submitted", "in_review", "clarification_requested", "cancelled", "expired"].includes(normalize(proposal.status)) && (
            <DetailBox title="Detalle de la solicitud" icon={FileText}>
              <div className="grid gap-x-8 sm:grid-cols-2">
                <InfoRow label="Título" value={proposal.titulo} />
                <InfoRow label="Estado" value={proposalStatusLabel(proposal.status)} />
                <InfoRow label="Horas solicitadas" value={proposal.horas_mensuales_solicitadas ? `${proposal.horas_mensuales_solicitadas} h/mes` : "No especificadas"} />
                <InfoRow label="Tipo de trabajo" value={proposal.tipo_trabajo || "—"} />
                <InfoRow label="Soporte fuera de horario" value={proposal.soporte_fuera_horario ? "Sí" : "No"} />
                <InfoRow label="Monitorización" value={proposal.necesidad_monitorizacion ? "Sí" : "No"} />
                <InfoRow label="Enviada" value={formatDate(proposal.submitted_at)} />
                <InfoRow label="Revisada" value={formatDate(proposal.reviewed_at)} />
              </div>
            </DetailBox>
          )}
        </div>

        {customProjectPickerOpen && proposal && (
          <div className="fixed inset-0 z-[90] flex items-center justify-center bg-[#172033]/25 p-5 backdrop-blur-[1px]">
            <div className="w-full max-w-[560px] rounded-[20px] border border-[#E1E7EE] bg-white p-6 shadow-[0_24px_70px_rgba(24,42,69,0.18)] sm:p-7">
              <div className="flex items-start justify-between gap-4">
                <div><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Mantenimiento personalizado</p><h2 className="mt-1 text-xl font-semibold text-[#26344A]">Selecciona el proyecto asociado</h2></div>
                <button type="button" onClick={() => setCustomProjectPickerOpen(false)} className="rounded-lg p-2 text-[#7C8797] hover:bg-[#F5F7F9]"><X className="h-4 w-4" /></button>
              </div>
              <p className="mt-3 text-[13px] leading-6 text-[#718096]">La propuesta personalizada se contratará para el proyecto que selecciones. Los proyectos que ya tienen mantenimiento no aparecen aquí.</p>
          <div className="mt-5 space-y-4 rounded-xl border border-[#E1E7EE] bg-[#F8FAFC] p-4">
  <label className="flex cursor-pointer items-start gap-3">
    <input
      type="checkbox"
      checked={acceptGeneralConditions}
      onChange={(e) => setAcceptGeneralConditions(e.target.checked)}
      className="mt-1 h-4 w-4 shrink-0 accent-[#173B8F]"
    />
    <span className="text-[12px] leading-5 text-[#526174]">
      He leído y acepto las condiciones generales de contratación del
      servicio de mantenimiento.
    </span>
  </label>

  <label className="flex cursor-pointer items-start gap-3">
    <input
      type="checkbox"
      checked={acceptSpecificConditions}
      onChange={(e) => setAcceptSpecificConditions(e.target.checked)}
      className="mt-1 h-4 w-4 shrink-0 accent-[#173B8F]"
    />
    <span className="text-[12px] leading-5 text-[#526174]">
      He leído y acepto las condiciones particulares del servicio
      de mantenimiento.
    </span>
  </label>
</div>
              <div className="mt-5 space-y-2">
                {companyProjects.filter((project) => !getProjectContract(project.id)).map((project) => (
                  <button key={project.id} type="button" onClick={() => setCustomProjectId(project.id)} className={["flex w-full items-center justify-between rounded-xl border px-4 py-3 text-left", customProjectId === project.id ? "border-[#173B8F] bg-[#F1F5FC]" : "border-[#E1E7EE] bg-white hover:bg-[#F8FAFC]"].join(" ")}>
                    <span><span className="block text-[13px] font-semibold text-[#344054]">{project.nombre || "Proyecto"}</span><span className="mt-1 block text-[11px] text-[#8A95A5]">Proyecto de tu empresa</span></span>
                    {customProjectId === project.id && <CheckCircle2 className="h-5 w-5 text-[#173B8F]" />}
                  </button>
                ))}
              </div>
              <div className="mt-6 flex gap-3"><button type="button" onClick={() => { setCustomProjectPickerOpen(false); setCustomProjectId(null); }} className="h-11 flex-1 rounded-xl border border-[#DCE2E9] text-[12px] font-semibold text-[#526174]">Cancelar</button><button type="button" disabled={
  !customProjectId ||
  !acceptGeneralConditions ||
  !acceptSpecificConditions ||
  checkoutLoading
}
 onClick={() => { const selected = customProjectId; setCustomProjectPickerOpen(false); setCustomProjectId(null); void acceptAndCheckout(selected); }} className="h-11 flex-1 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white disabled:opacity-50">{checkoutLoading ? "Preparando…" : "Continuar"}</button></div>
            </div>
          </div>
        )}
      </main>
    </div>
  );
};

/* ============================================================================
   PÁGINA DE PLANES — MISMO LENGUAJE VISUAL DEL ÁREA DE MANTENIMIENTO
   ========================================================================== */

const MaintenancePlansPage = ({
  plans,
  activeContracts,
  companyProjects,
  getProjectContract,
  fiscalComplete,
  actionLoading,
  onCheckout,
  onRequestPlanChange,
  onNavigate,
  sidebarOpen,
  onToggleSidebar,
  location,
  onLogout,
}: {
  plans: Plan[];
  activeContracts: Contract[];
  companyProjects: CompanyProject[];
  getProjectContract: (projectId: string) => Contract | null;
  fiscalComplete: boolean;
  actionLoading: string | null;
onCheckout: (
  plan: Plan,
  projectId: string,
  acceptGeneralConditions: boolean,
  acceptSpecificConditions: boolean
) => void;
  onRequestPlanChange: (plan: Plan, projectId?: string | null) => void;
  onNavigate: (path: string) => void;
  sidebarOpen: boolean;
  onToggleSidebar: () => void;
  location: string;
  onLogout: () => void;
}) => {
  const fixedPlans = plans.filter((plan) => !plan.es_personalizado && plan.activo);
  const customPlan = plans.find((plan) => plan.code === "custom" && plan.activo);
  const [checkoutProjectPickerOpen, setCheckoutProjectPickerOpen] = useState(false);
  const [checkoutProjectPickerPlan, setCheckoutProjectPickerPlan] = useState<Plan | null>(null);
  const [checkoutProjectId, setCheckoutProjectId] = useState<string | null>(null);
  const [acceptGeneralConditions, setAcceptGeneralConditions] = useState(false);
const [acceptSpecificConditions, setAcceptSpecificConditions] = useState(false);
  const [planChangePickerOpen, setPlanChangePickerOpen] = useState(false);
  const [planChangePickerPlan, setPlanChangePickerPlan] = useState<Plan | null>(null);
  const [planChangeProjectId, setPlanChangeProjectId] = useState<string | null>(null);
  const availableProjects = companyProjects.filter((project) => !getProjectContract(project.id));
  const maintenanceProjects = companyProjects.filter((project) => Boolean(getProjectContract(project.id)));
  const hasProjectsAvailableForNewContract = availableProjects.length > 0;
  return (
    <div className="min-h-screen bg-[#FBFCFE] text-[#26344A]">
      <ClientAreaSidebar isOpen={sidebarOpen} onToggle={onToggleSidebar} location={location} onNavigate={onNavigate} onLogout={onLogout} />
      <main className={[sidebarOpen ? "ml-[62px] lg:ml-[236px]" : "ml-[62px]", "[scrollbar-gutter:stable]"].join(" ")}>
        <ClientFloatingActions />
        <div className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
          <section className="mb-8 border-b border-[#E6EAF0] pb-8">
            <button type="button" onClick={() => onNavigate("/area-cliente/mantenimiento")} className="mb-5 inline-flex items-center gap-1.5 text-[11px] font-medium text-[#718096] transition-colors hover:text-[#173B8F]">
              <ArrowRight className="h-3.5 w-3.5 rotate-180" /> Volver a mantenimiento
            </button>
            <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">Área de Cliente</p>
            <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">Planes de mantenimiento</h1>
            <p className="mt-1.5 max-w-3xl text-sm leading-6 text-[#718096]">Consulta todos los planes disponibles y amplía o cambia el mantenimiento de tu empresa manteniendo el mismo sistema de contratación.</p>
          </section>

          {activeContracts.length > 0 && (
            <section className="mb-8 border-y border-[#E5E9EF] bg-white/40">
              <div className="px-5 py-5 sm:px-7">
                <p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Contratos actuales</p>
                <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                  {activeContracts.map((contract) => {
                    const projectNames = companyProjects
                      .filter((project) => getProjectContract(project.id)?.id === contract.id)
                      .map((project) => project.nombre || "Proyecto");
                    return (
                      <div key={contract.id} className="border border-[#E1E7EE] bg-white px-4 py-4">
                        <div className="flex items-start justify-between gap-3">
                          <div className="min-w-0">
                            <p className="text-[13px] font-semibold text-[#26344A]">{contract.nombre_plan || "Mantenimiento"}</p>
                            <p className="mt-1 text-[12px] text-[#718096]">{formatCurrency(contract.agreed_monthly_price ?? contract.precio, contract.moneda || "EUR")}/mes</p>
                          </div>
                          <span className={["shrink-0 rounded-full border px-2.5 py-1 text-[10px] font-semibold", statusPill(contract.estado || "")].join(" ")}>{contractStatusLabel(contract.estado)}</span>
                        </div>
                        <p className="mt-3 text-[11px] leading-5 text-[#8A95A5]">Proyecto{projectNames.length === 1 ? "" : "s"}: {projectNames.length ? projectNames.join(", ") : "Asociación pendiente de mostrar"}</p>
                      </div>
                    );
                  })}
                </div>
              </div>
            </section>
          )}

          <SectionTitle eyebrow="Modira Care" title="Planes disponibles" action={<span className="text-[11px] text-[#8A95A5]">Facturación mensual</span>} />
          <div className="grid gap-5 lg:grid-cols-3">
            {fixedPlans.map((plan) => {
              const canRequestChange = maintenanceProjects.some((project) => {
                const contract = getProjectContract(project.id);
                return Boolean(contract && contract.plan_id !== plan.id);
              });
              const isUnavailableForChange = !hasProjectsAvailableForNewContract && !canRequestChange;
             const buttonAction = hasProjectsAvailableForNewContract
  ? () => {
      setCheckoutProjectId(
        availableProjects.length === 1 ? availableProjects[0].id : null
      );
      setAcceptGeneralConditions(false);
      setAcceptSpecificConditions(false);
      setCheckoutProjectPickerPlan(plan);
      setCheckoutProjectPickerOpen(true);
    }
                : () => {
                    setPlanChangePickerPlan(plan);
                    setPlanChangeProjectId(null);
                    setPlanChangePickerOpen(true);
                  };
              return (
                <article key={plan.id} className="rounded-[20px] border border-[#E1E7EE] bg-white p-6 transition-all hover:-translate-y-[1px] hover:border-[#CDD6E0] hover:shadow-[0_14px_34px_rgba(24,42,69,0.07)]">
                  <div className="flex items-start justify-between gap-4"><div><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Modira Care</p><h3 className="mt-1 text-xl font-semibold text-[#1F3048]">{plan.nombre}</h3></div><span className="rounded-full border border-[#DCE2E9] bg-[#F8FAFC] px-2.5 py-1 text-[10px] font-semibold text-[#667386]">{plan.periodicidad}</span></div>
                  <p className="mt-4 min-h-[44px] text-[13px] leading-5 text-[#718096]">{MAINTENANCE_PLAN_COVERAGE[plan.code]?.summary || plan.descripcion}</p>
                  <div className="mt-5"><span className="text-3xl font-semibold tracking-tight text-[#182A45]">{formatCurrency(plan.precio, plan.moneda)}</span><span className="ml-1 text-[12px] text-[#8A95A5]">/mes</span></div>
                  <div className="my-5 border-t border-[#E9EDF2]" />
                  <ul className="space-y-2.5">{(MAINTENANCE_PLAN_COVERAGE[plan.code]?.benefits || []).map((benefit) => <li key={benefit} className="flex items-start gap-2 text-[12px] text-[#526174]"><Check className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#247A49]" strokeWidth={2} />{benefit}</li>)}</ul>
                  <button type="button" onClick={buttonAction} disabled={Boolean(actionLoading) || isUnavailableForChange || !fiscalComplete} className="mt-6 inline-flex h-11 w-full items-center justify-center gap-2 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white hover:bg-[#102F78] disabled:cursor-not-allowed disabled:opacity-60">
                    {actionLoading === `checkout:${plan.code}` || actionLoading === `change-plan` ? <Loader2 className="h-4 w-4 animate-spin" /> : <CreditCard className="h-4 w-4" />}
                    {hasProjectsAvailableForNewContract
                      ? `Contratar ${plan.nombre}`
                      : isUnavailableForChange
                        ? "Plan ya contratado"
                        : `Cambiar a ${plan.nombre}`}
                  </button>
                  <p className="mt-2 text-center text-[10px] leading-4 text-[#8A95A5]">
                    {hasProjectsAvailableForNewContract
                      ? `${availableProjects.length} proyecto${availableProjects.length === 1 ? " disponible" : "s disponibles"} para contratar.`
                      : "El cambio de plan se gestiona desde el contrato del proyecto seleccionado."}
                  </p>
                </article>
              );
            })}
          </div>

          {customPlan && (
            <article className="mt-5 rounded-[20px] border border-[#DDD7E5] bg-[#F8F5FA] p-6 sm:p-7">
              <div className="flex flex-col gap-5 lg:flex-row lg:items-center lg:justify-between">
                <div><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C6D88]">Soluciones personalizadas</p><h3 className="mt-1 text-xl font-semibold text-[#332A3B]">¿Necesitas otro alcance?</h3><p className="mt-2 max-w-2xl text-[13px] leading-6 text-[#756A7D]">Diseñamos un contrato a medida según soluciones, integraciones, dedicación, criticidad, soporte, SLA y necesidades específicas.</p></div>
                <button type="button" onClick={() => onNavigate("/area-cliente/mantenimiento/personalizado")} className="inline-flex h-11 shrink-0 items-center justify-center gap-2 rounded-xl bg-[#4B3E57] px-5 text-[12px] font-semibold text-white hover:bg-[#3E334A]"><ArrowRight className="h-4 w-4" /> Solicitar propuesta personalizada</button>
              </div>
            </article>
          )}

          {companyProjects.length > 0 && <div className="mt-5 border-y border-[#E6EAF0] py-4 text-[11px] leading-5 text-[#8792A2]">Tus proyectos disponibles para asociar al mantenimiento: <strong className="text-[#526174]">{availableProjects.length}</strong>. Los proyectos que ya tienen mantenimiento siguen disponibles desde su contrato para cambiar de plan.</div>}
          {!fiscalComplete && <div className="mt-5 flex items-start gap-3 rounded-xl border border-[#E5DCC0] bg-[#FFFBF1] p-4 text-[#735D2B]"><Info className="mt-0.5 h-5 w-5 shrink-0" /><div><p className="text-[13px] font-semibold">Completa los datos fiscales antes de contratar</p><p className="mt-1 text-[12px] leading-5">La contratación requiere los datos fiscales completos de la empresa.</p></div></div>}

          {planChangePickerOpen && planChangePickerPlan && (
            <div className="fixed inset-0 z-[100] flex items-center justify-center bg-[#172033]/25 p-5 backdrop-blur-[1px]">
              <div className="w-full max-w-[560px] rounded-[20px] border border-[#E1E7EE] bg-white p-6 shadow-[0_24px_70px_rgba(24,42,69,0.18)] sm:p-7">
                <div className="flex items-start justify-between gap-4">
                  <div><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Cambio de plan</p><h2 className="mt-1 text-xl font-semibold text-[#26344A]">Selecciona el proyecto</h2></div>
                  <button type="button" onClick={() => setPlanChangePickerOpen(false)} className="rounded-lg p-2 text-[#7C8797] hover:bg-[#F5F7F9]"><X className="h-4 w-4" /></button>
                </div>
                <p className="mt-3 text-[13px] leading-6 text-[#718096]">Selecciona el proyecto cuyo contrato quieres cambiar al plan {planChangePickerPlan.nombre}.</p>
                <div className="mt-5 space-y-2">
                  {maintenanceProjects.filter((project) => { const contract = getProjectContract(project.id); return Boolean(contract && contract.plan_id !== planChangePickerPlan.id); }).map((project) => (
                    <button key={project.id} type="button" onClick={() => setPlanChangeProjectId(project.id)} className={["flex w-full items-center justify-between rounded-xl border px-4 py-3 text-left", planChangeProjectId === project.id ? "border-[#173B8F] bg-[#F1F5FC]" : "border-[#E1E7EE] bg-white hover:bg-[#F8FAFC]"].join(" ")}>
                      <span><span className="block text-[13px] font-semibold text-[#344054]">{project.nombre || "Proyecto"}</span><span className="mt-1 block text-[11px] text-[#8A95A5]">Contrato de mantenimiento activo</span></span>
                      {planChangeProjectId === project.id && <CheckCircle2 className="h-5 w-5 text-[#173B8F]" />}
                    </button>
                  ))}
                </div>
                <div className="mt-6 flex gap-3">
                  <button type="button" onClick={() => { setPlanChangePickerOpen(false); setPlanChangeProjectId(null); }} className="h-11 flex-1 rounded-xl border border-[#DCE2E9] text-[12px] font-semibold text-[#526174]">Cancelar</button>
                  <button type="button" disabled={!planChangeProjectId || Boolean(actionLoading)} onClick={() => { const selectedProjectId = planChangeProjectId; if (!selectedProjectId) return; setPlanChangePickerOpen(false); setPlanChangeProjectId(null); onRequestPlanChange(planChangePickerPlan, selectedProjectId); }} className="h-11 flex-1 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white disabled:opacity-50">Continuar</button>
                </div>
              </div>
            </div>
          )}

          {checkoutProjectPickerOpen && checkoutProjectPickerPlan && (
            <div className="fixed inset-0 z-[100] flex items-center justify-center bg-[#172033]/25 p-5 backdrop-blur-[1px]">
              <div className="w-full max-w-[560px] rounded-[20px] border border-[#E1E7EE] bg-white p-6 shadow-[0_24px_70px_rgba(24,42,69,0.18)] sm:p-7">
                <div className="flex items-start justify-between gap-4">
                  <div><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Mantenimiento</p><h2 className="mt-1 text-xl font-semibold text-[#26344A]">Selecciona el proyecto asociado</h2></div>
                  <button type="button" onClick={() => setCheckoutProjectPickerOpen(false)} className="rounded-lg p-2 text-[#7C8797] hover:bg-[#F5F7F9]"><X className="h-4 w-4" /></button>
                </div>
                <p className="mt-3 text-[13px] leading-6 text-[#718096]">Selecciona el proyecto que quedará asociado al plan {checkoutProjectPickerPlan.nombre}. Después continuarás a la pasarela segura de Stripe.</p>
                <div className="mt-5 space-y-4 rounded-xl border border-[#E1E7EE] bg-[#F8FAFC] p-4">
  <label className="flex cursor-pointer items-start gap-3">
    <input
      type="checkbox"
      checked={acceptGeneralConditions}
      onChange={(e) => setAcceptGeneralConditions(e.target.checked)}
      className="mt-1 h-4 w-4 shrink-0 accent-[#173B8F]"
    />

    <span className="text-[12px] leading-5 text-[#526174]">
      He leído y acepto las condiciones generales de contratación del
      servicio de mantenimiento.
    </span>
  </label>

  <label className="flex cursor-pointer items-start gap-3">
    <input
      type="checkbox"
      checked={acceptSpecificConditions}
      onChange={(e) => setAcceptSpecificConditions(e.target.checked)}
      className="mt-1 h-4 w-4 shrink-0 accent-[#173B8F]"
    />

    <span className="text-[12px] leading-5 text-[#526174]">
      He leído y acepto las condiciones particulares del servicio
      de mantenimiento.
    </span>
  </label>
</div>
                <div className="mt-5 space-y-2">
                  {availableProjects.map((project) => (
                    <button key={project.id} type="button" onClick={() => setCheckoutProjectId(project.id)} className={["flex w-full items-center justify-between rounded-xl border px-4 py-3 text-left", checkoutProjectId === project.id ? "border-[#173B8F] bg-[#F1F5FC]" : "border-[#E1E7EE] bg-white hover:bg-[#F8FAFC]"].join(" ")}>
                      <span><span className="block text-[13px] font-semibold text-[#344054]">{project.nombre || "Proyecto"}</span><span className="mt-1 block text-[11px] text-[#8A95A5]">Disponible para asociar al mantenimiento</span></span>
                      {checkoutProjectId === project.id && <CheckCircle2 className="h-5 w-5 text-[#173B8F]" />}
                    </button>
                  ))}
                </div>
                <div className="mt-6 flex gap-3">
                  <button type="button" onClick={() => { setCheckoutProjectPickerOpen(false); setCheckoutProjectId(null); }} className="h-11 flex-1 rounded-xl border border-[#DCE2E9] text-[12px] font-semibold text-[#526174]">Cancelar</button>
                  <button type="button" disabled={
  !checkoutProjectId ||
  !acceptGeneralConditions ||
  !acceptSpecificConditions ||
  Boolean(actionLoading)
}
 onClick={() => { const selectedProjectId = checkoutProjectId; if (!selectedProjectId) return; setCheckoutProjectPickerOpen(false); setCheckoutProjectId(null); onCheckout(
  checkoutProjectPickerPlan,
  selectedProjectId,
  acceptGeneralConditions,
  acceptSpecificConditions
);
 }} className="h-11 flex-1 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white disabled:opacity-50">
                    {actionLoading === `checkout:${checkoutProjectPickerPlan.code}` ? "Preparando…" : "Continuar"}
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>
      </main>
    </div>
  );
}

/* ============================================================================
   COMPONENTE PRINCIPAL
   ========================================================================== */

export default function ClientMaintenance() {
  const { user, loading: authLoading, signOut } = useAuth();
  const [location, setLocation] = useLocation();
  const [sidebarOpen, setSidebarOpen] = useState(false);

  const [plans, setPlans] = useState<Plan[]>([]);
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [invoices, setInvoices] = useState<MaintenanceInvoice[]>([]);
  const [contractProjects, setContractProjects] = useState<Record<string, any>[]>([]);
  const [projectChangeRequests, setProjectChangeRequests] = useState<MaintenanceProjectChangeRequest[]>([]);
  const [proposal, setProposal] = useState<CustomProposal | null>(null);
  const [proposalDocuments, setProposalDocuments] = useState<CustomProposalDocument[]>([]);
  const [proposalAcknowledgements, setProposalAcknowledgements] = useState<CustomProposalAcknowledgement[]>([]);
  const [proposalEvents, setProposalEvents] = useState<CustomProposalEvent[]>([]);
  const [clarificationResponse, setClarificationResponse] = useState("");
  const [clarificationSaving, setClarificationSaving] = useState(false);
  const [proposalAcknowledging, setProposalAcknowledging] = useState(false);
  const [proposalAcknowledged, setProposalAcknowledged] = useState(false);
  const [company, setCompany] = useState<FiscalCompany | null>(null);
  const [fiscalRequest, setFiscalRequest] = useState<CompanyFiscalRequest | null>(null);
  const [payments, setPayments] = useState<Record<string, any>[]>([]);
  const [ivaRequestOpen, setIvaRequestOpen] = useState(false);
const [ivaRequestApplied, setIvaRequestApplied] = useState(true);
const [ivaRequestPercentage, setIvaRequestPercentage] = useState("21");
const [ivaRequestMessage, setIvaRequestMessage] = useState("");
const [ivaRequestLoading, setIvaRequestLoading] = useState(false);
const [maintenanceIvaRequest, setMaintenanceIvaRequest] = useState<Record<string, any> | null>(null);
  const [selectedBillingMonth, setSelectedBillingMonth] = useState("");
  const [maintenanceSection, setMaintenanceSection] = useState<"overview" | "billing" | "fiscal">("overview");
const [companyProjects, setCompanyProjects] = useState<CompanyProject[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionLoading, setActionLoading] = useState<string | null>(null);
  const [selectedPlan, setSelectedPlan] = useState<string | null>(null);
  const [customCheckoutLoading, setCustomCheckoutLoading] = useState(false);
const [customCheckoutProjectPickerOpen, setCustomCheckoutProjectPickerOpen] = useState(false);
const [customCheckoutProjectId, setCustomCheckoutProjectId] = useState<string | null>(null);
const [acceptGeneralConditions, setAcceptGeneralConditions] = useState(false);
const [acceptSpecificConditions, setAcceptSpecificConditions] = useState(false);
  const [planChangeContractId, setPlanChangeContractId] = useState<string | null>(null);
  const [showPlanChange, setShowPlanChange] = useState(false);
  const [projectChangeContractId, setProjectChangeContractId] = useState<string | null>(null);
  const [showProjectChange, setShowProjectChange] = useState(false);
  const [projectChangeProjectId, setProjectChangeProjectId] = useState<string | null>(null);
  const [showCancelConfirm, setShowCancelConfirm] = useState(false);
  const [cancelContractId, setCancelContractId] = useState<string | null>(null);

  const customRoute = location === "/area-cliente/mantenimiento/personalizado" || location.startsWith("/area-cliente/mantenimiento/personalizado?");
  const plansRoute = location === "/area-cliente/mantenimiento/planes" || location.startsWith("/area-cliente/mantenimiento/planes?");
const activeContracts = useMemo(
  () => contracts.filter(isActiveContract),
  [contracts]
);

const customPlan = useMemo(
  () => plans.find((plan) => plan.code === "custom"),
  [plans]
);

const fixedPlans = useMemo(
  () => plans.filter((plan) => !plan.es_personalizado && plan.activo),
  [plans]
);
  const navigate = useCallback((path: string) => {
    setLocation(path);
  }, [setLocation]);

  const handleLogout = async () => {
    try {
      await signOut();
      navigate("/login");
    } catch (error: any) {
      toast.error(error?.message || "No se pudo cerrar sesión.");
    }
  };

  const loadData = useCallback(async () => {
    if (!user) return;
    setLoading(true);
    setError(null);

    try {
      const { data: companyId, error: companyIdError } = await supabase.rpc("current_user_company_id");
      if (companyIdError) throw companyIdError;
      if (!companyId) throw new Error("Tu usuario no está asociado a una empresa.");

      const [plansResult, contractsResult, invoicesResult, proposalResult, companyResult, fiscalResult, projectsResult, projectChangeRequestsResult, maintenanceIvaRequestResult] = await Promise.all([
  supabase.from("maintenance_plans").select("*").eq("activo", true).order("precio", { ascending: true, nullsFirst: false }),
  supabase.from("maintenance_contracts").select("*").order("created_at", { ascending: false }),
  supabase.from("maintenance_invoices").select("*").order("fecha_emision", { ascending: false }),
  supabase.from("maintenance_custom_proposals").select("*").eq("company_id", companyId).order("created_at", { ascending: false }).limit(1).maybeSingle(),
  supabase.from("companies").select("*").eq("id", companyId).maybeSingle(),

// solicitudes de cambio de empresa y datos fiscales
supabase
  .from("company_change_requests")
  .select("*")
  .eq("current_company_id", companyId)
  .limit(50),
  
  // proyectos
  supabase
    .from("projects")
    .select("id,nombre,company_id")
    .eq("company_id", companyId)
    .order("nombre", { ascending: true }),

  // solicitudes de cambio de proyecto
  supabase
    .from("maintenance_contract_project_change_requests")
    .select("*")
    .eq("company_id", companyId)
    .order("requested_at", { ascending: false }),

  // solicitudes de cambio de IVA
  supabase
    .from("maintenance_iva_change_requests")
    .select("*")
    .eq("company_id", companyId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle(),
]);

      if (plansResult.error) throw plansResult.error;
      if (contractsResult.error) throw contractsResult.error;
      if (invoicesResult.error) throw invoicesResult.error;
      if (proposalResult.error) throw proposalResult.error;
      if (companyResult.error) throw companyResult.error;
      if (projectsResult.error) throw projectsResult.error;
      if (projectChangeRequestsResult.error) throw projectChangeRequestsResult.error;

      // La información fiscal es secundaria para la carga del área.
      // Si la tabla unificada cambia o sus RLS impiden consultar solicitudes,
      // no debe caer toda la página de Mantenimiento.
      if (fiscalResult.error) {
        console.warn(
          "[ClientMaintenance] No se pudieron cargar las solicitudes de cambio fiscal:",
          fiscalResult.error,
        );
      }

      const loadedPlans = (plansResult.data || []) as Plan[];
      const loadedContracts = (contractsResult.data || []) as Contract[];
      const loadedInvoices = (invoicesResult.data || []) as MaintenanceInvoice[];

      const fiscalRows = Array.isArray(fiscalResult.data)
        ? (fiscalResult.data as CompanyFiscalRequest[])
        : [];

      const latestFiscalRequest =
        fiscalRows
          .slice()
          .sort((a, b) => {
            const dateA = new Date(
              a.requested_at || a.created_at || 0,
            ).getTime();
            const dateB = new Date(
              b.requested_at || b.created_at || 0,
            ).getTime();
            return dateB - dateA;
          })[0] || null;

      setPlans(loadedPlans);
      setContracts(loadedContracts);
      setInvoices(loadedInvoices);
      setCompany((companyResult.data as FiscalCompany | null) || null);
      setFiscalRequest(latestFiscalRequest);
      setCompanyProjects((projectsResult.data || []) as CompanyProject[]);
      setProjectChangeRequests((projectChangeRequestsResult.data || []) as MaintenanceProjectChangeRequest[]);
      setMaintenanceIvaRequest(
  maintenanceIvaRequestResult.error
    ? null
    : maintenanceIvaRequestResult.data || null
);

      const loadedProposal = (proposalResult.data as CustomProposal | null) || null;
      setProposal(loadedProposal);

      if (loadedProposal) {
        const [documentsResult, acknowledgementsResult, eventsResult] = await Promise.all([
          supabase
            .from("maintenance_custom_proposal_documents")
            .select("*")
            .eq("proposal_id", loadedProposal.id)
            .order("version", { ascending: false }),
          supabase
            .from("maintenance_custom_proposal_document_acknowledgements")
            .select("*")
            .eq("proposal_id", loadedProposal.id)
            .order("accepted_at", { ascending: false }),
          supabase
            .from("maintenance_custom_proposal_events")
            .select("*")
            .eq("proposal_id", loadedProposal.id)
            .order("created_at", { ascending: false }),
        ]);

        if (documentsResult.error) throw documentsResult.error;
        if (acknowledgementsResult.error) throw acknowledgementsResult.error;
        if (eventsResult.error) throw eventsResult.error;

        setProposalDocuments((documentsResult.data || []) as CustomProposalDocument[]);
        setProposalAcknowledgements((acknowledgementsResult.data || []) as CustomProposalAcknowledgement[]);
        setProposalEvents((eventsResult.data || []) as CustomProposalEvent[]);
        const currentDocument = (documentsResult.data || []).find(
  (document: any) =>
    document.id === loadedProposal.current_document_id &&
    document.proposal_id === loadedProposal.id &&
    document.published_at !== null,
);

setProposalAcknowledged(
  Boolean(
    currentDocument &&
      (acknowledgementsResult.data || []).some(
        (row: any) =>
          row.proposal_id === loadedProposal.id &&
          row.user_id === user.id &&
          row.company_id === loadedProposal.company_id &&
          row.document_id === currentDocument.id &&
          row.document_path === currentDocument.document_path &&
          typeof row.document_sha256 === "string" &&
          typeof currentDocument.document_sha256 === "string" &&
          row.document_sha256.toLowerCase() ===
            currentDocument.document_sha256.toLowerCase(),
      ),
  ),
);
        setClarificationResponse(loadedProposal.response_notes || "");
      } else {
        setProposalDocuments([]);
        setProposalAcknowledgements([]);
        setProposalEvents([]);
        setProposalAcknowledged(false);
        setClarificationResponse("");
      }


      const companyContractIds = loadedContracts.map((contract) => contract.id);

      if (companyContractIds.length > 0) {
        // Cargamos las relaciones de TODOS los contratos de la empresa, no solo
        // los activos. Así los contratos históricos siguen pudiendo asociarse
        // a su proyecto y la UI no pierde trazabilidad al cancelar un contrato.
        const projectResult = await supabase
          .from("maintenance_contract_projects")
          .select("*, projects(id,nombre,company_id)")
          .in("maintenance_contract_id", companyContractIds);

        if (projectResult.error) throw projectResult.error;

        const invoiceIds = loadedInvoices
          .filter((invoice) =>
            invoice.maintenance_contract_id &&
            companyContractIds.includes(invoice.maintenance_contract_id)
          )
          .map((invoice) => invoice.id);

        let paymentRows: Record<string, any>[] = [];

        if (invoiceIds.length > 0) {
          const paymentResult = await supabase
            .from("payments")
            .select("*")
            .in("maintenance_invoice_id", invoiceIds);

          if (paymentResult.error) throw paymentResult.error;

          paymentRows = (paymentResult.data || []) as Record<string, any>[];
        }

        setContractProjects((projectResult.data || []) as Record<string, any>[]);
        setPayments(paymentRows);
      } else {
        setContractProjects([]);
        setPayments([]);
      }

    } catch (loadError: any) {
      console.error(loadError);
      setError(loadError?.message || "No se pudo cargar el área de mantenimiento.");
    } finally {
      setLoading(false);
    }
  }, [user]);

  useEffect(() => {
    if (!user || authLoading) return;
    void loadData();
  }, [user, authLoading, loadData]);

  const invokeMaintenance = useCallback(async (body: Record<string, unknown>) => {
    const { data, error } = await supabase.functions.invoke("maintenance-stripe", { body });
    if (error) throw error;
    if (data?.error) throw new Error(data.error);
    return data;
  }, []);

  const startCheckout = async (
  plan: Plan,
  projectId?: string | null,
  acceptGeneralConditions = false,
  acceptSpecificConditions = false
) => {
    if (!fiscalComplete) {
      toast.error("Completa los datos fiscales de la empresa antes de contratar un plan de mantenimiento.");
      return;
    }
if (!acceptGeneralConditions || !acceptSpecificConditions) {
  toast.error(
    "Debes aceptar las condiciones generales y particulares del mantenimiento."
  );
  return;
}
    const availableProjects = companyProjects.filter((project) => !getProjectContract(project.id));

    if (!projectId && availableProjects.length === 0) {
      toast.error("Todos los proyectos de tu empresa ya tienen un mantenimiento activo.");
      return;
    }
if (!projectId) {
  if (availableProjects.length === 0) {
    toast.error(
      "Todos los proyectos de tu empresa ya tienen un mantenimiento activo."
    );
    return;
  }

  return;
}

    if (getProjectContract(projectId)) {
      toast.error("El proyecto seleccionado ya tiene un mantenimiento activo.");
      return;
    }

    setActionLoading(`checkout:${plan.code}`);
    try {
    const data = await invokeMaintenance({
  action: "create_checkout_session",
  plan_id: plan.id,
  plan_code: plan.code,
  ...(projectId ? { project_id: projectId } : {}),
  accept_general_conditions: acceptGeneralConditions,
  accept_specific_conditions: acceptSpecificConditions,
  success_url: `${window.location.origin}/area-cliente/mantenimiento?checkout=success`,
  cancel_url: `${window.location.origin}/area-cliente/mantenimiento?checkout=cancelled`,
});
      if (!data?.checkout_url) throw new Error("No se ha recibido la URL de contratación.");
      window.location.assign(data.checkout_url);
    } catch (error: any) {
      toast.error(error?.message || "No se pudo iniciar la contratación.");
    } finally {
      setActionLoading(null);
    }
  };

 const changePlan = async (
  contractId: string,
  planCode: string
) => {
  if (!contractId || !planCode) return;

  setActionLoading("change-plan");

  try {
    const data = await invokeMaintenance({
      action: "request_plan_change",
      contract_id: contractId,
      plan_code: planCode,
    });

    toast.success(
      data?.effective_at
        ? `Cambio programado para ${formatDate(data.effective_at)}.`
        : "Cambio de plan programado."
    );

    setShowPlanChange(false);
    setSelectedPlan(null);

    await loadData();
  } catch (error: any) {
    toast.error(
      error?.message || "No se pudo solicitar el cambio de plan."
    );
  } finally {
    setActionLoading(null);
  }
};

  const requestProjectChange = async (contractId: string, requestedProjectId: string) => {
    const selectedContract = contracts.find((contract) => contract.id === contractId);
    if (!selectedContract || !isActiveContract(selectedContract)) {
      toast.error("El contrato seleccionado ya no está activo.");
      return;
    }

    if (!requestedProjectId) {
      toast.error("Selecciona el proyecto al que quieres trasladar el mantenimiento.");
      return;
    }

    setActionLoading("change-project");
    try {
      const data = await invokeMaintenance({
        action: "request_maintenance_project_change",
        contract_id: selectedContract.id,
        project_id: requestedProjectId,
      });

      toast.success(
        data?.effective_at
          ? `Solicitud aprobada y programada para ${formatDate(data.effective_at)}.`
          : "Solicitud de cambio de proyecto enviada para revisión.",
      );

      setShowProjectChange(false);
      setProjectChangeContractId(null);
      setProjectChangeProjectId(null);
      await loadData();
    } catch (error: any) {
      toast.error(error?.message || "No se pudo solicitar el cambio de proyecto.");
    } finally {
      setActionLoading(null);
    }
  };

  const cancelProjectChange = async (requestId: string) => {
    if (!requestId) return;

    setActionLoading("cancel-project-change");
    try {
      await invokeMaintenance({
        action: "cancel_maintenance_project_change",
        request_id: requestId,
      });
      toast.success("Solicitud de cambio de proyecto cancelada.");
      await loadData();
    } catch (error: any) {
      toast.error(error?.message || "No se pudo cancelar la solicitud de cambio de proyecto.");
    } finally {
      setActionLoading(null);
    }
  };

  const cancelContract = async (contractId: string) => {
    const selectedContract = contracts.find((contract) => contract.id === contractId);
    if (!selectedContract || !isActiveContract(selectedContract)) {
      toast.error("El contrato seleccionado ya no está activo.");
      return;
    }

    setActionLoading("cancel");
    try {
      const data = await invokeMaintenance({
        action: "request_cancellation",
        contract_id: selectedContract.id,
      });
      toast.success(data?.cancel_effective_at ? `Cancelación programada para ${formatDate(data.cancel_effective_at)}.` : "Cancelación programada.");
      setShowCancelConfirm(false);
      setCancelContractId(null);
      await loadData();
    } catch (error: any) {
      toast.error(error?.message || "No se pudo solicitar la cancelación.");
    } finally {
      setActionLoading(null);
    }
  };

  const fiscalComplete = Boolean(
    company &&
      String(company.cif_vat || "").trim() &&
      String(company.legal_name || company.company_name || "").trim() &&
      String(company.address || "").trim() &&
      String(company.postal_code || "").trim() &&
      String(company.city || "").trim() &&
      String(company.country || "").trim(),
  );

  const companyContractIds = useMemo(
    () => new Set(contracts.map((contract) => contract.id)),
    [contracts],
  );

  const contractInvoices = useMemo(
    () => invoices.filter((invoice) => invoice.maintenance_contract_id && companyContractIds.has(invoice.maintenance_contract_id)),
    [companyContractIds, invoices],
  );

  const totalPaid = useMemo(
    () => contractInvoices.filter((invoice) => normalize(invoice.estado) === "pagada").reduce((sum, invoice) => sum + Number(invoice.importe_a_pagar || invoice.monto || 0), 0),
    [contractInvoices],
  );

  const pendingInvoices = useMemo(
    () => contractInvoices.filter((invoice) => ["pendiente", "enviada", "impagada"].includes(normalize(invoice.estado))),
    [contractInvoices],
  );

  const invoiceDocuments = useMemo(
    () =>
      contractInvoices.flatMap((invoice) => {
        const documents: Array<{
          invoice: MaintenanceInvoice;
          path: string;
          label: string;
          source: "modira" | "stripe";
          uploadedAt?: string | null;
        }> = [];
        const seen = new Set<string>();

        const addDocument = (
          path: string | null | undefined,
          label: string,
          source: "modira" | "stripe",
          uploadedAt?: string | null,
        ) => {
          const normalizedPath = String(path || "").trim();
          if (!normalizedPath || seen.has(normalizedPath)) return;
          seen.add(normalizedPath);
          documents.push({
            invoice,
            path: normalizedPath,
            label,
            source,
            uploadedAt: uploadedAt ?? null,
          });
        };

        // 050 mantiene separados el documento de Modira, el documento
        // electrónico estructurado, el PDF legacy y el PDF de Stripe.
        // El cliente puede leer cualquiera de los documentos que la RLS
        // de Storage autoriza para su empresa.
        addDocument(
          invoice.document_path,
          "PDF de factura",
          "modira",
          invoice.document_uploaded_at,
        );
        addDocument(
          invoice.pdf_storage_path,
          "PDF de Stripe (legacy)",
          "stripe",
          null,
        );
        addDocument(
          invoice.electronic_document_storage_path,
          "Documento electrónico",
          "modira",
          null,
        );
        addDocument(
          invoice.stripe_pdf_storage_path,
          "PDF de Stripe",
          "stripe",
          null,
        );

        return documents;
      }),
    [contractInvoices],
  );

  const invoiceOnlyDocuments = useMemo(
    () => invoiceDocuments.filter((document) => document.source === "modira" && document.label === "PDF de factura"),
    [invoiceDocuments],
  );

  const stripeDocuments = useMemo(
    () => invoiceDocuments.filter((document) => document.source === "stripe"),
    [invoiceDocuments],
  );

  const availableBillingMonths = useMemo(() => {
    const months = new Set<string>();

    contractInvoices.forEach((invoice) => {
      const start = getMonthKey(invoice.periodo_inicio || invoice.fecha_emision);
      const end = getMonthKey(invoice.periodo_fin || invoice.fecha_emision);
      if (!start || !end) return;

      const [startYear, startMonth] = start.split("-").map(Number);
      const [endYear, endMonth] = end.split("-").map(Number);
      const cursor = new Date(startYear, startMonth - 1, 1);
      const limit = new Date(endYear, endMonth - 1, 1);

      while (cursor <= limit) {
        months.add(`${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, "0")}`);
        cursor.setMonth(cursor.getMonth() + 1);
      }
    });

    payments.forEach((payment) => {
      const month = getMonthKey(payment.paid_at || payment.created_at);
      if (month) months.add(month);
    });

    return Array.from(months).sort((a, b) => b.localeCompare(a));
  }, [contractInvoices, payments]);

  const filteredContractInvoices = useMemo(
    () =>
      contractInvoices
        .filter((invoice) => invoiceMatchesMonth(invoice, selectedBillingMonth))
        .sort((a, b) => {
          const dateA = new Date(a.periodo_fin || a.fecha_emision || 0).getTime();
          const dateB = new Date(b.periodo_fin || b.fecha_emision || 0).getTime();
          return dateB - dateA;
        }),
    [contractInvoices, selectedBillingMonth],
  );

  const filteredInvoiceOnlyDocuments = useMemo(
    () =>
      invoiceOnlyDocuments
        .filter((document) => invoiceMatchesMonth(document.invoice, selectedBillingMonth))
        .sort((a, b) => {
          const dateA = new Date(a.invoice.periodo_fin || a.invoice.fecha_emision || 0).getTime();
          const dateB = new Date(b.invoice.periodo_fin || b.invoice.fecha_emision || 0).getTime();
          return dateB - dateA;
        }),
    [invoiceOnlyDocuments, selectedBillingMonth],
  );

  const filteredStripeDocuments = useMemo(
    () =>
      stripeDocuments
        .filter((document) => invoiceMatchesMonth(document.invoice, selectedBillingMonth))
        .sort((a, b) => {
          const dateA = new Date(a.invoice.periodo_fin || a.invoice.fecha_emision || 0).getTime();
          const dateB = new Date(b.invoice.periodo_fin || b.invoice.fecha_emision || 0).getTime();
          return dateB - dateA;
        }),
    [stripeDocuments, selectedBillingMonth],
  );

  const filteredPayments = useMemo(
    () =>
      payments
        .filter((payment) => !selectedBillingMonth || getMonthKey(payment.paid_at || payment.created_at) === selectedBillingMonth)
        .sort((a, b) => {
          const dateA = new Date(a.paid_at || a.created_at || 0).getTime();
          const dateB = new Date(b.paid_at || b.created_at || 0).getTime();
          return dateB - dateA;
        }),
    [payments, selectedBillingMonth],
  );
const getProjectContract = useCallback(
  (projectId: string) => {
    const relation = contractProjects.find(
      (row) => row.project_id === projectId
    );

    if (!relation) return null;

    return contracts.find(
      (contract) =>
        contract.id === relation.maintenance_contract_id &&
        isActiveContract(contract)
    ) || null;
  },
  [contractProjects, contracts]
);

const projectsWithMaintenance = useMemo(
  () =>
    companyProjects.map((project) => ({
      ...project,
      contract: getProjectContract(project.id),
    })),
  [companyProjects, getProjectContract]
);
  const getProjectChangeRequest = useCallback(
    (contractId: string) =>
      projectChangeRequests.find(
        (request) =>
          request.maintenance_contract_id === contractId &&
          ["pending", "approved"].includes(normalize(request.status)),
      ) || null,
    [projectChangeRequests],
  );

  const getProjectChangeRequestProjectName = useCallback(
    (projectId: string | null | undefined) =>
      companyProjects.find((project) => project.id === projectId)?.nombre || "Proyecto",
    [companyProjects],
  );

  const openCustomProposalDocument = async (document: CustomProposalDocument) => {
    try {
      const { data, error } = await supabase.storage
        .from("maintenance-proposals")
        .createSignedUrl(document.document_path, 60 * 5);

      if (error) throw error;
      if (!data?.signedUrl) {
        throw new Error("No se pudo generar el enlace seguro del documento.");
      }

      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    } catch (error: any) {
      toast.error(error?.message || "No se pudo abrir el PDF de la propuesta.");
    }
  };

  const downloadCustomProposalDocument = async (document: CustomProposalDocument) => {
    try {
      const { data, error } = await supabase.storage
        .from("maintenance-proposals")
        .createSignedUrl(document.document_path, 60 * 5, { download: true });

      if (error) throw error;
      if (!data?.signedUrl) {
        throw new Error("No se pudo generar el enlace seguro del documento.");
      }

      const link = window.document.createElement("a");
      link.href = data.signedUrl;
      link.download = `propuesta-mantenimiento-v${document.version}.pdf`;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      window.document.body.appendChild(link);
      link.click();
      link.remove();
    } catch (error: any) {
      toast.error(error?.message || "No se pudo descargar el PDF de la propuesta.");
    }
  };

  const submitClarificationResponse = async () => {
    if (!proposal || normalize(proposal.status) !== "clarification_requested") return;

    const notes = clarificationResponse.trim();
    if (!notes) {
      toast.error("Escribe la información que quieres enviar a Modira.");
      return;
    }

    setClarificationSaving(true);
    try {
      const { error } = await supabase.rpc("respond_to_custom_maintenance_clarification", {
        p_proposal_id: proposal.id,
        p_informacion_adicional: notes,
        p_request_data: {},
      });

      if (error) throw error;
      toast.success("Información enviada correctamente a Modira.");
      await loadData();
    } catch (error: any) {
      toast.error(error?.message || "No se pudo enviar la información a Modira.");
    } finally {
      setClarificationSaving(false);
    }
  };

 const acknowledgeCustomProposalDocument = async () => {
  if (!proposal) {
    toast.error("No se ha encontrado la propuesta.");
    return false;
  }

  if (normalize(proposal.status) !== "quoted") {
    toast.error("La propuesta ya no está disponible para aceptar.");
    return false;
  }

  if (!proposal.current_document_id) {
    toast.error("La propuesta no tiene un documento PDF disponible.");
    return false;
  }

  const currentDocument = proposalDocuments.find(
    (document) =>
      document.id === proposal.current_document_id &&
      document.proposal_id === proposal.id &&
      document.published_at != null,
  );

  if (!currentDocument) {
    toast.error(
      "El PDF actual de la propuesta no está publicado o no existe.",
    );
    return false;
  }

  if (
    !currentDocument.document_sha256 ||
    !/^[0-9a-fA-F]{64}$/.test(
      String(currentDocument.document_sha256).trim(),
    )
  ) {
    toast.error(
      "El PDF de la propuesta todavía no tiene un SHA-256 válido.",
    );
    return false;
  }

  if (proposalAcknowledged) {
    return true;
  }

  setProposalAcknowledging(true);

  try {
    const { error } = await supabase.rpc(
      "record_maintenance_custom_proposal_document_acknowledgement",
      {
        p_proposal_id: proposal.id,
      },
    );

    if (error) throw error;

    setProposalAcknowledged(true);

    toast.success("Documento leído y aceptación registrada.");

    await loadData();

    return true;
  } catch (error: any) {
    console.error(
      "[ClientMaintenance] Error al registrar aceptación del documento:",
      error,
    );

    toast.error(
      error?.message ||
        "No se pudo registrar la aceptación del documento.",
    );

    return false;
  } finally {
    setProposalAcknowledging(false);
  }
};
const submitIvaRequest = async () => {
  if (!user) return;

  const percentage = Number(ivaRequestPercentage);

  if (
    ivaRequestApplied &&
    (!Number.isFinite(percentage) || percentage < 0 || percentage > 100)
  ) {
    toast.error("Introduce un porcentaje de IVA válido entre 0 y 100.");
    return;
  }

  if (!ivaRequestMessage.trim()) {
    toast.error("Indica el motivo de la solicitud.");
    return;
  }

  setIvaRequestLoading(true);

  try {
    const { error } = await supabase.rpc(
      "request_maintenance_iva_change",
      {
        p_requested_iva_aplicado: ivaRequestApplied,
        p_requested_iva_porcentaje: ivaRequestApplied
          ? percentage
          : 0,
        p_message: ivaRequestMessage.trim(),
        p_maintenance_contract_id:
          contracts.find(
            (contract) =>
              contract.estado === "activo" ||
              contract.estado === "active"
          )?.id ?? null,
      }
    );

    if (error) throw error;

    toast.success(
      "Solicitud de cambio de IVA enviada correctamente."
    );

    setIvaRequestOpen(false);
    setIvaRequestMessage("");
  } catch (error: any) {
    console.error("Error solicitando cambio de IVA:", error);

    toast.error(
      error?.message ||
        "No se ha podido enviar la solicitud de cambio de IVA."
    );
  } finally {
    setIvaRequestLoading(false);
  }
};
const acceptCustomProposal = async () => {
  if (!proposal) {
    toast.error("No se ha encontrado la propuesta.");
    return false;
  }

  if (normalize(proposal.status) !== "quoted") {
    toast.error("La propuesta ya no está disponible para aceptar.");
    return false;
  }

  if (!proposal.current_document_id) {
    toast.error("La propuesta no tiene un documento PDF disponible.");
    return false;
  }

  const currentDocument = proposalDocuments.find(
    (document) =>
      document.id === proposal.current_document_id &&
      document.proposal_id === proposal.id &&
      document.published_at != null,
  );

  if (!currentDocument) {
    toast.error(
      "El PDF actual de la propuesta no está publicado o no existe.",
    );
    return false;
  }

  if (
    !currentDocument.document_sha256 ||
    !/^[0-9a-fA-F]{64}$/.test(
      String(currentDocument.document_sha256).trim(),
    )
  ) {
    toast.error(
      "El PDF de la propuesta todavía no tiene un SHA-256 válido.",
    );
    return false;
  }

  if (!proposalAcknowledged) {
    toast.error(
      "Lee el PDF y marca la aceptación del documento antes de aceptar la propuesta.",
    );
    return false;
  }

  try {
    const { error } = await supabase.rpc(
      "accept_custom_maintenance_proposal",
      {
        p_proposal_id: proposal.id,
      },
    );

    if (error) throw error;

    toast.success("Propuesta aceptada correctamente.");

    await loadData();

    return true;
  } catch (error: any) {
    console.error(
      "[ClientMaintenance] Error al aceptar propuesta:",
      error,
    );

    toast.error(
      error?.message ||
        "No se pudo aceptar la propuesta.",
    );

    return false;
  }
};
const acceptAndCheckout = async (projectId?: string | null) => {
  if (!proposal) return;

  if (!proposal.current_document_id) {
    toast.error("Modira todavía no ha adjuntado el PDF de la propuesta.");
    return;
  }

  if (normalize(proposal.status) !== "accepted") {
    toast.error("Primero debes aceptar la propuesta antes de contratarla.");
    return;
  }

  const availableProjects = companyProjects.filter(
    (project) => !getProjectContract(project.id)
  );

  if (!projectId && availableProjects.length === 0) {
    toast.error(
      "Todos los proyectos de tu empresa ya tienen un mantenimiento activo."
    );
    return;
  }

if (!projectId) {
  setCustomCheckoutProjectId(
    availableProjects.length === 1 ? availableProjects[0].id : null
  );
  setAcceptGeneralConditions(false);
  setAcceptSpecificConditions(false);
  setCustomCheckoutProjectPickerOpen(true);
  return;
}

  if (!projectId) {
    toast.error("Selecciona un proyecto para continuar.");
    return;
  }

  if (getProjectContract(projectId)) {
    toast.error("El proyecto seleccionado ya tiene un mantenimiento activo.");
    return;
  }
if (!acceptGeneralConditions || !acceptSpecificConditions) {
  toast.error(
    "Debes aceptar las condiciones generales y particulares del mantenimiento."
  );
  return;
}
  setCustomCheckoutLoading(true);

  try {
    const { data, error } = await supabase.functions.invoke(
      "maintenance-stripe",
      {
        body: {
          action: "accept_custom_maintenance_proposal",
          proposal_id: proposal.id,
          project_id: projectId,
          accept_general_conditions: acceptGeneralConditions,
accept_specific_conditions: acceptSpecificConditions,
          success_url: `${window.location.origin}/area-cliente/mantenimiento?checkout=success&custom_proposal=${proposal.id}`,
          cancel_url: `${window.location.origin}/area-cliente/mantenimiento?checkout=cancelled&custom_proposal=${proposal.id}`,
        },
      }
    );

    if (error) throw error;

    if (!data?.checkout_url) {
      throw new Error("Stripe no ha devuelto una URL de pago.");
    }

    window.location.assign(data.checkout_url);
  } catch (error: any) {
    toast.error(
      error?.message || "No se pudo iniciar la contratación."
    );
  } finally {
    setCustomCheckoutLoading(false);
  }
};
  if (authLoading || (loading && !customRoute)) {
    return (
      <div className="min-h-screen bg-[#FBFCFE]">
        <div className="flex min-h-screen items-center justify-center">
          <Loader2 className="h-7 w-7 animate-spin text-[#173B8F]" />
        </div>
      </div>
    );
  }

  if (plansRoute) {
    return (
      <MaintenancePlansPage
        plans={plans}
        activeContracts={activeContracts}
        companyProjects={companyProjects}
        getProjectContract={getProjectContract}
        fiscalComplete={fiscalComplete}
        actionLoading={actionLoading}
       onCheckout={(
  plan,
  projectId,
  acceptGeneralConditions,
  acceptSpecificConditions
) =>
  void startCheckout(
    plan,
    projectId,
    acceptGeneralConditions,
    acceptSpecificConditions
  )
}
        onRequestPlanChange={(plan, projectId) => {
          if (!projectId) {
            toast.error("Selecciona el proyecto cuyo mantenimiento quieres cambiar.");
            return;
          }
          const contract = getProjectContract(projectId);
          if (!contract) {
            toast.error("El proyecto seleccionado no tiene un mantenimiento activo.");
            return;
          }
          setSelectedPlan(plan.code);
          void changePlan(contract.id, plan.code);
        }}
        onNavigate={navigate}
        sidebarOpen={sidebarOpen}
        onToggleSidebar={() => setSidebarOpen((value) => !value)}
        location={location}
        onLogout={handleLogout}
      />
    );
  }

  if (customRoute) {
    return (
      <CustomProposalPage
        proposal={null}
        plans={plans}
        companyProjects={companyProjects}
        getProjectContract={getProjectContract}
        loading={loading}
        onReload={loadData}
        onAcknowledgeProposalDocument={acknowledgeCustomProposalDocument}
        onAcceptProposal={acceptCustomProposal}
        proposalAcknowledged={proposalAcknowledged}
        proposalAcknowledging={proposalAcknowledging}
        clarificationResponse={clarificationResponse}
        onClarificationResponseChange={setClarificationResponse}
        clarificationSaving={clarificationSaving}
        onSubmitClarificationResponse={submitClarificationResponse}
        proposalDocuments={proposalDocuments}
        onOpenProposalDocument={openCustomProposalDocument}
        sidebarOpen={sidebarOpen}
        onToggleSidebar={() => setSidebarOpen((value) => !value)}
        location={location}
        onNavigate={navigate}
        onLogout={handleLogout}
      />
    );
  }

  return (
    <div className="min-h-screen bg-[#FBFCFE] text-[#26344A]">
      <ClientAreaSidebar
        isOpen={sidebarOpen}
        onToggle={() => setSidebarOpen((value) => !value)}
        location={location}
        onNavigate={navigate}
        onLogout={handleLogout}
      />

      <main className={[
        sidebarOpen ? "ml-[62px] lg:ml-[236px]" : "ml-[62px]",
        "[scrollbar-gutter:stable]",
      ].join(" ")}>
        <ClientFloatingActions />

        <div className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
          <section className="mb-8 border-b border-[#E6EAF0] pb-8">
            <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">Área de Cliente</p>
                <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">Mantenimiento</h1>
                <p className="mt-1.5 max-w-3xl text-sm leading-6 text-[#718096]">Consulta tu plan, contrato, alcance cubierto, proyectos, facturación y opciones de gestión del mantenimiento.</p>
              </div>
              <button type="button" onClick={() => void loadData()} className="inline-flex h-10 items-center justify-center gap-2 rounded-xl border border-[#DCE2E9] bg-white px-4 text-[12px] font-semibold text-[#526174] hover:bg-[#F7F9FB]"><RefreshCw className="h-3.5 w-3.5" /> Actualizar</button>
            </div>
          </section>

          {error ? <ErrorState error={error} onRetry={() => void loadData()} /> : (
            <>
              <section className="mb-10 grid grid-cols-2 divide-x divide-y divide-[#E5E9EF] border-y border-[#E5E9EF] bg-white/40 lg:grid-cols-4 lg:divide-y-0">
                <StatCell label="Estado" value={activeContracts.length ? `${activeContracts.length} activo${activeContracts.length === 1 ? "" : "s"}` : "Sin plan"} detail={activeContracts.length === 1 ? (plans.find((plan) => plan.id === activeContracts[0]?.plan_id)?.nombre || activeContracts[0]?.nombre_plan || "Mantenimiento") : activeContracts.length > 1 ? "Varios proyectos" : "No contratado"} icon={CheckCircle2} active={activeContracts.length > 0} />
                <StatCell label="Cuota mensual" value={activeContracts.length ? formatCurrency(activeContracts.reduce((sum, contract) => sum + Number(contract.agreed_monthly_price ?? contract.precio ?? 0), 0), activeContracts[0]?.moneda || "EUR") : "—"} detail={activeContracts.length ? `${activeContracts.length} contrato${activeContracts.length === 1 ? "" : "s"}` : "Disponible desde 149 €/mes"} icon={CreditCard} active={activeContracts.length > 0} />
                <StatCell label="Documentos de factura" value={invoiceOnlyDocuments.length} detail={invoiceOnlyDocuments.length === 1 ? "Documento de factura" : "Documentos de factura"} icon={Receipt} active={invoiceOnlyDocuments.length > 0} />
                <StatCell label="Planes disponibles" value={4} detail="Haz clic para ver los planes disponibles" icon={Wrench} onClick={() => navigate("/area-cliente/mantenimiento/planes")} />
              </section>

              {activeContracts.length > 0 && (
                <nav
                  aria-label="Secciones de mantenimiento"
                  className="mb-10 overflow-hidden rounded-[16px] border border-[#E1E7EE] bg-white"
                >
                  <div className="grid grid-cols-3">
                    {[
                      { key: "overview" as const, label: "Mantenimiento" },
                      { key: "billing" as const, label: "Pagos y facturación" },
                      { key: "fiscal" as const, label: "Datos fiscales" },
                    ].map((item) => {
                      const active = maintenanceSection === item.key;
                      return (
                        <button
                          key={item.key}
                          type="button"
                          onClick={() => setMaintenanceSection(item.key)}
                          className={[
                            "relative flex min-h-[52px] items-center justify-center border-b-2 px-3 py-3 text-center text-[12px] font-semibold transition-colors sm:text-[13px]",
                            active
                              ? "border-[#173B8F] bg-[#F8FAFC] text-[#173B8F]"
                              : "border-transparent text-[#718096] hover:bg-[#F8FAFC] hover:text-[#173B8F]",
                          ].join(" ")}
                        >
                          {item.label}
                        </button>
                      );
                    })}
                  </div>
                </nav>
              )}

{(activeContracts.length === 0 || maintenanceSection === "overview") && proposal && ["draft", "submitted", "in_review", "clarification_requested", "quoted", "accepted"].includes(normalize(proposal.status)) && (
                  <section className="mb-10">
                  <SectionTitle
                    eyebrow="Propuesta personalizada"
                    title="Historial de contratación personalizada"
                    action={
                      <span className={["rounded-full border px-2.5 py-1 text-[10px] font-semibold", statusPill(proposal.status)].join(" ")}>
                        {proposalStatusLabel(proposal.status)}
                      </span>
                    }
                  />

                  <div className="grid gap-5 lg:grid-cols-[1.15fr_0.85fr]">
                    <DetailBox title={proposal.titulo || "Solicitud de mantenimiento personalizada"} icon={FileText}>
                      <div className="grid gap-x-8 sm:grid-cols-2">
                        <InfoRow label="Creada" value={formatDate(proposal.created_at)} />
                        <InfoRow label="Enviada" value={formatDate(proposal.submitted_at)} />
                        <InfoRow label="Revisada" value={formatDate(proposal.reviewed_at)} />
                        <InfoRow label="Cotizada" value={formatDate(proposal.quoted_at)} />
                        <InfoRow label="Horas solicitadas" value={proposal.horas_mensuales_solicitadas ? `${proposal.horas_mensuales_solicitadas} h/mes` : "No especificadas"} />
                        <InfoRow label="Tipo de trabajo" value={proposal.tipo_trabajo || "—"} />
                        <InfoRow label="Nivel de soporte solicitado" value={proposal.nivel_soporte_solicitado || "—"} />
                        <InfoRow label="Tiempo de respuesta solicitado" value={proposal.tiempo_respuesta_deseado || "—"} />
                      </div>

                      <div className="border-t border-[#E9EDF2] py-4">
                        <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Solicitud del cliente</p>
                        <div className="mt-3 space-y-0">
                          <InfoRow label="Necesidad" value={proposal.descripcion_necesidad || "—"} />
                          <InfoRow label="Objetivos" value={proposal.objetivos || "—"} />
                          <InfoRow label="Prioridades" value={proposal.prioridades || "—"} />
                          <InfoRow label="Alcance solicitado" value={proposal.alcance_tecnico_solicitado || "—"} />
                          <InfoRow label="Proyectos relacionados" value={proposal.proyectos_relacionados || "—"} />
                          <InfoRow label="Tecnologías" value={proposal.tecnologias || "—"} />
                          <InfoRow label="SLA solicitado" value={proposal.sla_solicitado || "—"} />
                          <InfoRow label="Información adicional" value={proposal.informacion_adicional || "—"} />
                        </div>
                      </div>

                      {proposal.status === "clarification_requested" && proposal.clarification_message && (
                        <div className="border-t border-[#E9EDF2] py-4">
                          <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Información solicitada por Modira</p>
                          <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#526174]">{proposal.clarification_message}</p>

                          <div className="mt-5">
                            <label className="block">
                              <span className="mb-2 block text-[11px] font-semibold uppercase tracking-[0.08em] text-[#7C8797]">Tu respuesta</span>
                              <textarea
                                value={clarificationResponse}
                                onChange={(e) => setClarificationResponse(e.target.value)}
                                disabled={clarificationSaving}
                                className="min-h-[130px] w-full resize-y border border-[#DCE2E9] bg-[#FBFCFE] px-3.5 py-3 text-[13px] leading-5 text-[#344054] outline-none focus:border-[#173B8F] focus:ring-1 focus:ring-[#173B8F] disabled:cursor-not-allowed disabled:bg-[#F6F8FA]"
                                placeholder="Escribe aquí la información adicional que quieres enviar a Modira."
                              />
                            </label>
                            <div className="mt-3 flex justify-end">
                              <button
                                type="button"
                                onClick={() => void submitClarificationResponse()}
                                disabled={clarificationSaving || !clarificationResponse.trim()}
                                className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-[#173B8F] px-4 text-[12px] font-semibold text-white hover:bg-[#102F78] disabled:cursor-not-allowed disabled:opacity-60"
                              >
                                {clarificationSaving ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <ArrowRight className="h-3.5 w-3.5" />}
                                Enviar información a Modira
                              </button>
                            </div>
                          </div>

                          {proposal.response_notes && (
                            <div className="mt-5 border-t border-[#E9EDF2] pt-4">
                              <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Última respuesta enviada</p>
                              <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#526174]">{proposal.response_notes}</p>
                            </div>
                          )}
                        </div>
                      )}

                      {proposal.status === "quoted" && (
                        <div className="border-t border-[#E9EDF2] py-4">
                          <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Condiciones propuestas por Modira</p>
                          <div className="mt-3 grid gap-x-8 sm:grid-cols-2">
                            <InfoRow label="Cuota mensual" value={proposal.quoted_monthly_price != null ? formatCurrency(proposal.quoted_monthly_price, proposal.quoted_currency) : "—"} />
                            <InfoRow label="Horas mensuales" value={proposal.quoted_hours_monthly ? `${proposal.quoted_hours_monthly} h/mes` : "A medida"} />
                            <InfoRow label="Alcance" value={proposal.quoted_scope_level || "A medida"} />
                            <InfoRow label="Nivel de servicio" value={proposal.quoted_service_level || "A medida"} />
                            <InfoRow label="SLA" value={proposal.quoted_sla || "—"} />
                            <InfoRow label="Tiempo de respuesta" value={proposal.quoted_response_time || "—"} />
                            <InfoRow label="Horario de soporte" value={proposal.quoted_support_hours || "—"} />
                            <InfoRow label="Validez" value={formatDate(proposal.quoted_valid_until)} />
                          </div>
                          <div className="mt-4">
                            <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Descripción</p>
                            <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#526174]">{proposal.quoted_description || "—"}</p>
                          </div>
                          {proposal.quoted_terms && (
                            <div className="mt-4">
                              <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Condiciones</p>
                              <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#526174]">{proposal.quoted_terms}</p>
                            </div>
                          )}
                        </div>
                      )}

                     {proposal.status === "accepted" && !proposal.maintenance_contract_id && (
  <div className="border-t border-[#E9EDF2] py-5">
    <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
      <div>
        <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#247A49]">
          Propuesta aceptada
        </p>
        <p className="mt-1 text-[12px] leading-5 text-[#718096]">
          Has aceptado la propuesta. Puedes contratar el mantenimiento cuando quieras.
        </p>
      </div>

      <button
  type="button"
  onClick={() => void acceptAndCheckout()}
  disabled={customCheckoutLoading}
  className="inline-flex h-10 shrink-0 items-center justify-center gap-2 rounded-lg bg-[#173B8F] px-4 text-[11px] font-semibold text-white hover:bg-[#102F78] disabled:cursor-not-allowed disabled:opacity-60"
>
  {customCheckoutLoading ? (
    <Loader2 className="h-3.5 w-3.5 animate-spin" />
  ) : (
    <CreditCard className="h-3.5 w-3.5" />
  )}
  Contratar
</button>
    </div>
  </div>
)}

                    </DetailBox>

                    <div className="space-y-5">
                      <DetailBox title="Comunicaciones y cambios" icon={Clock3}>
                        {proposalEvents.filter((event) => {
  const type = normalize(event.event_type || event.status_to || "");

  return [
    "submitted",
    "in_review",
    "clarification_requested",
    "clarification_responded",
    "quoted",
    "accepted",
    "rejected",
    "cancelled",
    "document_published",
    "document_acknowledged",
  ].includes(type);
}).length ? (
                          <div className="divide-y divide-[#E9EDF2]">
                           {proposalEvents
  .filter((event) => {
    const type = normalize(event.event_type || event.status_to || "");

    return [
      "submitted",
      "in_review",
      "clarification_requested",
      "clarification_responded",
      "quoted",
      "accepted",
      "rejected",
      "cancelled",
      "document_published",
      "document_acknowledged",
    ].includes(type);
  })
                              .map((event) => (
                                <div key={event.id} className="py-4 first:pt-1 last:pb-1">
                                  <div className="flex items-start justify-between gap-3">
                                    <p className="text-[12px] font-semibold text-[#344054]">{proposalEventLabel(event)}</p>
                                    <span className="shrink-0 text-[10px] text-[#8A95A5]">{formatCompactDate(event.created_at)}</span>
                                  </div>
                                  {(event.message || event.notes) && (
                                    <p className="mt-2 whitespace-pre-wrap text-[12px] leading-5 text-[#718096]">{event.message || event.notes}</p>
                                  )}
                                </div>
                              ))}
                          </div>
                        ) : (
                          <EmptyState title="Todavía no hay actualizaciones" text="Los cambios y comunicaciones de la propuesta aparecerán aquí." icon={Clock3} />
                        )}
                      </DetailBox>

                      <DetailBox title="Documentación de la propuesta" icon={FileText}>
                        {proposalDocuments.length ? (
                          <div className="divide-y divide-[#E9EDF2]">
                            {proposalDocuments.map((document) => (
                              <div key={document.id} className="flex items-center justify-between gap-3 py-4 first:pt-1 last:pb-1">
                                <div className="min-w-0">
                                  <p className="text-[12px] font-semibold text-[#344054]">Propuesta PDF · v{document.version}</p>
                                  <p className="mt-1 text-[10px] text-[#8A95A5]">{formatCompactDate(document.published_at || document.document_uploaded_at || document.created_at)}</p>
                                </div>
                                <button type="button" onClick={() => void downloadCustomProposalDocument(document)} className="inline-flex h-9 shrink-0 items-center gap-2 rounded-lg border border-[#DCE2E9] px-3 text-[11px] font-semibold text-[#173B8F] hover:bg-[#F7F9FB]">
                                  <FileText className="h-3.5 w-3.5" /> Descargar PDF
                                </button>
                              </div>
                            ))}
                          </div>
                        ) : (
                          <EmptyState title="Todavía no hay PDF" text="Cuando Modira publique la propuesta formal aparecerá aquí." icon={FileText} />
                        )}
                        {proposal?.status === "quoted" && proposal.current_document_id && (
  <>
    <div className="border-t border-[#E9EDF2] py-4">
      <label className="flex items-start gap-3">
        <input
          type="checkbox"
          checked={proposalAcknowledged}
          disabled={proposalAcknowledged || proposalAcknowledging}
          onChange={() => void acknowledgeCustomProposalDocument()}
          className="mt-0.5 h-4 w-4 rounded border-[#C8D0DA] text-[#173B8F]"
        />

        <span className="text-[12px] leading-5 text-[#526174]">
  Marcando la casilla declaro que he leído el PDF adjunto de la propuesta y acepto sus condiciones.
  <span className="mt-1 block text-[11px] leading-5 text-[#8A95A5]">
    La aceptación de esta propuesta no implica la contratación del servicio de mantenimiento.
    La contratación podrá realizarse posteriormente, cuando lo desees, desde esta misma área.
  </span>
</span>
      </label>

      {proposalAcknowledged && (
        <p className="mt-2 text-[11px] font-medium text-[#247A49]">
          Documento leído y aceptación registrada.
        </p>
      )}
    </div>

    <div className="border-t border-[#E9EDF2] py-4 flex justify-end">
      <button
        type="button"
        onClick={() => void acceptCustomProposal()}
        disabled={!proposalAcknowledged}
        className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-[#173B8F] px-4 text-[11px] font-semibold text-white hover:bg-[#102F78] disabled:cursor-not-allowed disabled:opacity-50"
      >
        <CheckCircle2 className="h-3.5 w-3.5" />
        Aceptar propuesta
      </button>
    </div>
  </>
)}
                      </DetailBox>
                    </div>
                  </div>
                </section>
              )}

              {activeContracts.length > 0 && maintenanceSection === "overview" && (
                <section className="mb-10">
                  <SectionTitle eyebrow="Proyectos con mantenimiento" title="Mantenimiento contratado por proyecto" action={<span className="text-[11px] text-[#8A95A5]">{activeContracts.length} contrato{activeContracts.length === 1 ? "" : "s"}</span>} />
                  <div className="grid gap-5 lg:grid-cols-2">
                    {projectsWithMaintenance.filter((project) => project.contract).map((project) => {
  const contract = project.contract as Contract;
  const plan = plans.find((item) => item.id === contract.plan_id);
  const projectChangeRequest = getProjectChangeRequest(contract.id);

  return (
                        <DetailBox
  key={project.id}
  title={
  <div className="flex items-center gap-2">
    <span>{project.nombre || "Proyecto"}</span>

    {projectChangeRequest && (
      <div className="group relative flex items-center">
      <div className="flex items-center gap-1.5 cursor-help">
  <div className="flex h-5 w-5 items-center justify-center rounded-full border border-[#E5DCC0] bg-[#FFFBF1] text-[#735D2B]">
    <Info className="h-3.5 w-3.5" strokeWidth={2.2} />
  </div>

  <span className="text-[10px] font-semibold text-[#735D2B]">
    Cambio de proyecto próximo
  </span>
</div>

        <div className="pointer-events-none absolute left-0 top-7 z-[100] w-[310px] rounded-xl border border-[#E5DCC0] bg-[#FFFBF1] p-3 opacity-0 shadow-[0_8px_25px_rgba(24,42,69,0.12)] transition-opacity duration-150 group-hover:opacity-100">
          <p className="text-[11px] font-semibold text-[#735D2B]">
            Cambio de proyecto
          </p>

          <p className="mt-1 text-[11px] leading-5 text-[#735D2B]">
            {normalize(projectChangeRequest.status) === "pending"
              ? `Has solicitado trasladar este mantenimiento al proyecto "${getProjectChangeRequestProjectName(
                  projectChangeRequest.requested_project_id
                )}". La solicitud está pendiente de revisión.`
              : `El cambio de proyecto ha sido aprobado. El mantenimiento se trasladará al proyecto "${getProjectChangeRequestProjectName(
                  projectChangeRequest.requested_project_id
                )}" cuando finalice el periodo de facturación actual.`}
          </p>

          {normalize(projectChangeRequest.status) === "approved" &&
            (contract.pending_project_change_effective_at ||
              projectChangeRequest.effective_at) && (
              <p className="mt-2 text-[11px] font-semibold text-[#735D2B]">
                Aplicación:
                {" "}
                {formatDate(
                  contract.pending_project_change_effective_at ||
                    projectChangeRequest.effective_at
                )}
              </p>
            )}
        </div>
      </div>
    )}
  </div>
}
  icon={BriefcaseBusiness}
  action={
    <span
      className={[
        "rounded-full border px-2.5 py-1 text-[10px] font-semibold",
        statusPill(contract.estado || ""),
      ].join(" ")}
    >
      {contractStatusLabel(contract.estado)}
    </span>
  }
>
  <div className="grid gap-x-8 sm:grid-cols-2">
    <InfoRow
      label="Plan"
      value={plan?.nombre || contract.nombre_plan || "Mantenimiento"}
    />

    <InfoRow
      label="Cuota mensual"
      value={formatCurrency(
        contract.agreed_monthly_price ?? contract.precio,
        contract.moneda || "EUR"
      )}
    />
<div className="relative">
  <div className="flex items-center gap-1.5">
    <InfoRow
      label="IVA aplicado"
      value={
        contract.iva_aplicado
          ? `${Number(contract.iva_porcentaje)} %`
          : "No aplicado"
      }
    />
<div className="mt-3">
  <button
    type="button"
    onClick={() => {
      setIvaRequestApplied(contract.iva_aplicado);
      setIvaRequestPercentage(
        contract.iva_aplicado
          ? String(Number(contract.iva_porcentaje))
          : "0"
      );
      setIvaRequestMessage("");
      setIvaRequestOpen(true);
    }}
    className="text-[11px] font-semibold text-[#173B8F] hover:underline"
  >
    Solicitar cambio de IVA
  </button>
</div>
{maintenanceIvaRequest && (
  <div
    className={[
      "mt-3 rounded-lg border px-3 py-2.5",
      maintenanceIvaRequest.status === "pending"
        ? "border-[#E5DCC0] bg-[#FFFBF1]"
        : maintenanceIvaRequest.status === "approved"
          ? "border-[#D7E6DB] bg-[#F5FAF6]"
          : maintenanceIvaRequest.status === "rejected"
            ? "border-[#E8D5D5] bg-[#FFF7F7]"
            : "border-[#E1E7EE] bg-[#F8FAFC]",
    ].join(" ")}
  >
    <p
      className={[
        "text-[11px] font-semibold",
        maintenanceIvaRequest.status === "pending"
          ? "text-[#9A8050]"
          : maintenanceIvaRequest.status === "approved"
            ? "text-[#5E9470]"
            : maintenanceIvaRequest.status === "rejected"
              ? "text-[#A05A5A]"
              : "text-[#667386]",
      ].join(" ")}
    >
      {maintenanceIvaRequest.status === "pending"
        ? "Solicitud de cambio de IVA pendiente de revisión"
        : maintenanceIvaRequest.status === "approved"
          ? `Solicitud de cambio de IVA aprobada · IVA ${maintenanceIvaRequest.requested_iva_aplicado ? `${Number(maintenanceIvaRequest.requested_iva_porcentaje)} %` : "no aplicado"}`
          : maintenanceIvaRequest.status === "rejected"
            ? "Solicitud de cambio de IVA rechazada"
            : `Solicitud de cambio de IVA: ${maintenanceIvaRequest.status}`}
    </p>

    {maintenanceIvaRequest.status === "rejected" &&
      maintenanceIvaRequest.worker_notes && (
        <p className="mt-1 text-[11px] leading-5 text-[#718096]">
          Motivo: {maintenanceIvaRequest.worker_notes}
        </p>
      )}

    {maintenanceIvaRequest.status === "approved" && (
      <p className="mt-1 text-[11px] leading-5 text-[#718096]">
        El tratamiento fiscal del contrato se ha actualizado.
      </p>
    )}
  </div>
)}

    <div className="group relative mt-4">
      <Info className="h-3.5 w-3.5 cursor-help text-[#173B8F]" />

      <div className="pointer-events-none absolute left-1/2 top-6 z-[100] w-[300px] -translate-x-1/2 rounded-xl border border-[#DCE2E9] bg-white p-3 opacity-0 shadow-[0_8px_25px_rgba(24,42,69,0.12)] transition-opacity duration-150 group-hover:opacity-100">
        <p className="text-[11px] font-semibold text-[#344054]">
          Tratamiento fiscal
        </p>

        <p className="mt-1 text-[11px] leading-5 text-[#667386]">
          El IVA mostrado corresponde a la configuración fiscal establecida
          para tu empresa en Modira.
        </p>

        <p className="mt-2 text-[11px] leading-5 text-[#667386]">
          Si consideras que debería aplicarse un tratamiento fiscal diferente,
          contacta con Modira antes de realizar el pago.
        </p>
      </div>
    </div>
  </div>
</div>
    <InfoRow
      label="Próxima renovación"
      value={
        contract.current_period_end
          ? formatDate(contract.current_period_end)
          : "—"
      }
    />

    <InfoRow
      label="Día de renovación"
      value={
        contract.renewal_day
          ? `Día ${contract.renewal_day}`
          : "—"
      }
    />
  </div>

  {(() => {
  const hasPendingProjectChange = Boolean(projectChangeRequest);

  return (
      <>
        <div className="mt-5 flex flex-wrap gap-2">
          <button
            type="button"
            onClick={() => {
              setSelectedPlan(null);
              setPlanChangeContractId(contract.id);
              setShowPlanChange(true);
            }}
            className="inline-flex h-10 items-center gap-2 rounded-xl border border-[#DCE2E9] px-4 text-[11px] font-semibold text-[#173B8F] hover:bg-[#F7F9FB]"
          >
            Cambiar plan
          </button>

          <button
            type="button"
            onClick={() => {
              setProjectChangeContractId(contract.id);
              setProjectChangeProjectId(null);
              setShowProjectChange(true);
            }}
            disabled={
              hasPendingProjectChange ||
              Boolean(contract.cancel_at_period_end)
            }
            className="inline-flex h-10 items-center gap-2 rounded-xl border border-[#DCE2E9] px-4 text-[11px] font-semibold text-[#173B8F] hover:bg-[#F7F9FB] disabled:opacity-50"
          >
            Cambiar proyecto
          </button>

          <button
            type="button"
            onClick={() => {
              setCancelContractId(contract.id);
              setShowCancelConfirm(true);
            }}
            disabled={Boolean(contract.cancel_at_period_end)}
            className="inline-flex h-10 items-center gap-2 rounded-xl border border-[#DCE2E9] px-4 text-[11px] font-semibold text-[#4B3E57] hover:bg-[#F7F9FB] disabled:opacity-50"
          >
            Cancelar
          </button>
        </div>

       
      </>
    );
  })()}
</DetailBox>
                      );
                    })}
                  </div>
                </section>
              )}

              {activeContracts.length > 0 && maintenanceSection === "overview" && (
                <section className="mb-10">
                  <SectionTitle
                    eyebrow="Planes contratados"
                    title="Características de tus planes de mantenimiento"
                    action={<span className="text-[11px] text-[#8A95A5]">Un recuadro por plan contratado</span>}
                  />

                  <div className="grid gap-5 lg:grid-cols-2 xl:grid-cols-3">
                    {fixedPlans
                      .filter((plan) => activeContracts.some((contract) => contract.plan_id === plan.id))
                      .map((plan) => {
                        const planContracts = activeContracts.filter((contract) => contract.plan_id === plan.id);
                        const coverage = MAINTENANCE_PLAN_COVERAGE[plan.code];
                        const projects = planContracts.flatMap((contract) =>
                          contractProjects
                            .filter((row) => row.maintenance_contract_id === contract.id)
                            .map((row) => row.projects?.nombre || row.project_name || row.nombre || row.project?.nombre || row.project_id || "Proyecto")
                        );
                        const uniqueProjects = Array.from(new Set(projects));

                        return (
                          <DetailBox key={plan.id} title={plan.nombre} icon={ShieldCheck}>
                            <div className="py-1">
                              <div className="grid gap-x-8 sm:grid-cols-2">
                                <InfoRow label="Horas incluidas" value={coverage?.hours || "Según contrato"} />
                                <InfoRow label="Nivel de alcance" value={coverage?.scope || "Según contrato"} />
                                <InfoRow label="Cuota" value={formatCurrency(planContracts[0]?.agreed_monthly_price ?? plan.precio, plan.moneda)} />
                                <InfoRow label="Periodo" value={plan.periodicidad || "Mensual"} />
                              </div>

                              <div className="border-t border-[#E9EDF2] py-4">
                                <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Incluye este plan</p>
                                <p className="mt-2 text-[13px] leading-6 text-[#526174]">{coverage?.summary || plan.descripcion || "Cobertura definida en el contrato."}</p>
                                {coverage?.benefits?.length ? (
                                  <ul className="mt-3 space-y-2">
                                    {coverage.benefits.map((benefit) => (
                                      <li key={benefit} className="flex items-start gap-2 text-[12px] text-[#526174]">
                                        <Check className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#247A49]" strokeWidth={2} />
                                        {benefit}
                                      </li>
                                    ))}
                                  </ul>
                                ) : null}
                              </div>

                              <div className="border-t border-[#E9EDF2] py-4">
                                <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Proyecto{uniqueProjects.length === 1 ? "" : "s"} asociado{uniqueProjects.length === 1 ? "" : "s"}</p>
                                <div className="mt-2 space-y-1.5">
                                  {(uniqueProjects.length ? uniqueProjects : ["Proyecto asociado"]).map((projectName) => (
                                    <div key={projectName} className="flex items-center gap-2 text-[13px] font-medium text-[#344054]">
                                      <BriefcaseBusiness className="h-3.5 w-3.5 shrink-0 text-[#173B8F]" strokeWidth={1.8} />
                                      {projectName}
                                    </div>
                                  ))}
                                </div>
                              </div>
                            </div>
                          </DetailBox>
                        );
                      })}

                    {activeContracts
                      .filter((contract) => {
                        const plan = plans.find((item) => item.id === contract.plan_id);
                        return Boolean(plan?.es_personalizado || plan?.code === "custom" || contract.maintenance_custom_proposal_id);
                      })
                      .map((contract) => {
                        const customCoverage = contract.scope_snapshot || {};
                        const projects = contractProjects
                          .filter((row) => row.maintenance_contract_id === contract.id)
                          .map((row) => row.projects?.nombre || row.project_name || row.nombre || row.project?.nombre || row.project_id || "Proyecto");
                        const proposalForContract = contract.maintenance_custom_proposal_id === proposal?.id ? proposal : null;
                        const hours = customCoverage.quoted_hours_monthly ?? proposalForContract?.quoted_hours_monthly;
                        const scope = customCoverage.quoted_scope_level || proposalForContract?.quoted_scope_level || "A medida";
                        const service = customCoverage.quoted_service_level || proposalForContract?.quoted_service_level;
                        const response = customCoverage.quoted_response_time || proposalForContract?.quoted_response_time;
                        const supportHours = customCoverage.quoted_support_hours || proposalForContract?.quoted_support_hours;
                        const sla = customCoverage.quoted_sla || proposalForContract?.quoted_sla;
                        const description = customCoverage.quoted_description || proposalForContract?.quoted_description || contract.descripcion || "Cobertura personalizada acordada en la propuesta.";
                        const terms = customCoverage.quoted_terms || proposalForContract?.quoted_terms;

                        return (
                          <DetailBox key={contract.id} title={contract.nombre_plan || customPlan?.nombre || "Custom"} icon={ShieldCheck}>
                            <div className="py-1">
                              <div className="grid gap-x-8 sm:grid-cols-2">
                                <InfoRow label="Horas mensuales" value={hours ? `${hours} h/mes` : "A medida"} />
                                <InfoRow label="Alcance" value={scope} />
                                {service && <InfoRow label="Nivel de servicio" value={service} />}
                                {response && <InfoRow label="Tiempo de respuesta" value={response} />}
                                {supportHours && <InfoRow label="Horario de soporte" value={supportHours} />}
                                {sla && <InfoRow label="SLA" value={sla} />}
                                <InfoRow label="Cuota mensual" value={formatCurrency(contract.agreed_monthly_price ?? contract.precio, contract.moneda || "EUR")} />
                              </div>
                              <div className="border-t border-[#E9EDF2] py-4">
                                <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Descripción acordada</p>
                                <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#526174]">{description}</p>
                                {terms && (
                                  <div className="mt-4">
                                    <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Condiciones</p>
                                    <p className="mt-2 whitespace-pre-wrap text-[13px] leading-6 text-[#526174]">{terms}</p>
                                  </div>
                                )}
                              </div>
                              <div className="border-t border-[#E9EDF2] py-4">
                                <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Proyecto asociado</p>
                                <div className="mt-2 space-y-1.5">
                                  {(projects.length ? projects : ["Proyecto asociado"]).map((projectName) => (
                                    <div key={projectName} className="flex items-center gap-2 text-[13px] font-medium text-[#344054]">
                                      <BriefcaseBusiness className="h-3.5 w-3.5 shrink-0 text-[#173B8F]" strokeWidth={1.8} />
                                      {projectName}
                                    </div>
                                  ))}
                                </div>
                              </div>
                              {proposalForContract && proposalDocuments.length > 0 && (
                                <div className="border-t border-[#E9EDF2] py-4">
                                  <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-[#8A95A5]">Documento de la propuesta aceptada</p>
                                  <div className="mt-2 space-y-2">
                                    {proposalDocuments.map((document) => (
                                      <div key={document.id} className="flex items-center justify-between gap-3">
                                        <span className="text-[12px] text-[#526174]">Propuesta PDF · v{document.version}</span>
                                        <button type="button" onClick={() => void openCustomProposalDocument(document)} className="inline-flex h-9 items-center gap-2 rounded-lg border border-[#DCE2E9] px-3 text-[11px] font-semibold text-[#173B8F] hover:bg-[#F7F9FB]">
                                          <FileText className="h-3.5 w-3.5" /> Ver PDF
                                        </button>
                                      </div>
                                    ))}
                                  </div>
                                </div>
                              )}
                            </div>
                          </DetailBox>
                        );
                      })}
                  </div>
                </section>
              )}

              {activeContracts.length === 0 && (
                <section className="mb-10">
                  <SectionTitle eyebrow="Modira Care" title="Elige el nivel de mantenimiento que necesitas" action={<span className="text-[11px] text-[#8A95A5]">Facturación mensual</span>} />
                  <div className="grid gap-5 lg:grid-cols-3">
                    {fixedPlans.map((plan) => {
                      return (
                        <article key={plan.id} className="rounded-[20px] border border-[#E1E7EE] bg-white p-6 transition-all hover:-translate-y-[1px] hover:border-[#CDD6E0] hover:shadow-[0_14px_34px_rgba(24,42,69,0.07)]">
                          <div className="flex items-start justify-between gap-4"><div><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Modira Care</p><h3 className="mt-1 text-xl font-semibold text-[#1F3048]">{plan.nombre}</h3></div><span className="rounded-full border border-[#DCE2E9] bg-[#F8FAFC] px-2.5 py-1 text-[10px] font-semibold text-[#667386]">{plan.periodicidad}</span></div>
                          <p className="mt-4 min-h-[44px] text-[13px] leading-5 text-[#718096]">{MAINTENANCE_PLAN_COVERAGE[plan.code]?.summary || plan.descripcion}</p>
                          <div className="mt-5"><span className="text-3xl font-semibold tracking-tight text-[#182A45]">{formatCurrency(plan.precio, plan.moneda)}</span><p className="mt-1 text-[11px] text-[#8A95A5]">
  Precio final, IVA según configuración fiscal de tu empresa
</p><span className="ml-1 text-[12px] text-[#8A95A5]">/mes</span></div>
                          <div className="my-5 border-t border-[#E9EDF2]" />
                          <ul className="space-y-2.5">{(MAINTENANCE_PLAN_COVERAGE[plan.code]?.benefits || []).map((benefit) => <li key={benefit} className="flex items-start gap-2 text-[12px] text-[#526174]"><Check className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#247A49]" strokeWidth={2} />{benefit}</li>)}</ul>
                          <button type="button" onClick={() => navigate("/area-cliente/mantenimiento/planes")} disabled={Boolean(actionLoading)} className="mt-6 inline-flex h-11 w-full items-center justify-center gap-2 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white hover:bg-[#102F78] disabled:opacity-60">{<CreditCard className="h-4 w-4" />} Ver planes y contratar {plan.nombre}</button>
                        </article>
                      );
                    })}
                  </div>

                  <article className="mt-5 rounded-[20px] border border-[#DDD7E5] bg-[#F8F5FA] p-6 sm:p-7">
<div className="flex flex-col gap-5 lg:flex-row lg:items-center lg:justify-between">
  <div>
    <p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C6D88]">
      Soluciones personalizadas
    </p>

    <h3 className="mt-1 text-xl font-semibold text-[#332A3B]">
      ¿Tu ecosistema necesita otro alcance?
    </h3>

    <p className="mt-2 max-w-2xl text-[13px] leading-6 text-[#756A7D]">
      Diseñamos un contrato a medida según soluciones, integraciones,
      dedicación, criticidad, soporte, SLA y necesidades específicas.
    </p>
  </div>

  <button
    type="button"
    onClick={() => setLocation("/area-cliente/mantenimiento/personalizado")}
    className="inline-flex h-11 shrink-0 items-center justify-center gap-2 rounded-xl bg-[#4B3E57] px-5 text-[12px] font-semibold text-white hover:bg-[#3E334A]"
  >
    <ArrowRight className="h-4 w-4" />
    Solicitar propuesta personalizada
  </button>
</div>                  </article>

                  {!fiscalComplete && (
                    <div className="mt-5 flex items-start gap-3 rounded-xl border border-[#E5DCC0] bg-[#FFFBF1] p-4 text-[#735D2B]"><Info className="mt-0.5 h-5 w-5 shrink-0" /><div><p className="text-[13px] font-semibold">Completa los datos fiscales antes de contratar</p><p className="mt-1 text-[12px] leading-5">La contratación de mantenimiento requiere razón social, NIF/CIF/VAT, dirección, código postal, ciudad y país. Si ya tienes una solicitud de cambio fiscal pendiente, aparecerá debajo.</p>{fiscalRequest?.status === "pending" && <p className="mt-2 text-[12px] font-semibold">Tienes una solicitud de cambio fiscal pendiente de revisión.</p>}</div></div>
                  )}
                </section>
              )}

              {activeContracts.length > 0 && maintenanceSection === "billing" && (
                <>
                  <section className="mb-8">
                    <div className="mb-5 flex flex-col gap-3 rounded-[16px] border border-[#E1E7EE] bg-white px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
                      <div>
                        <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#7C8797]">Periodo de facturación</p>
                        <p className="mt-1 text-[12px] text-[#8A95A5]">Consulta facturas, documentos y pagos del periodo que quieras.</p>
                      </div>
                      <select
                        value={selectedBillingMonth}
                        onChange={(event) => setSelectedBillingMonth(event.target.value)}
                        className="h-10 min-w-[210px] rounded-lg border border-[#DCE2E9] bg-white px-3 text-[12px] font-medium text-[#344054] outline-none transition-colors focus:border-[#173B8F]"
                      >
                        <option value="">Todos los periodos</option>
                        {availableBillingMonths.map((month) => (
                          <option key={month} value={month}>
                            {formatMonthLabel(month)}
                          </option>
                        ))}
                      </select>
                    </div>

                    <SectionTitle eyebrow="Facturación de mantenimiento" title="Facturas" action={<span className="text-[11px] text-[#8A95A5]">{filteredContractInvoices.length}{selectedBillingMonth ? ` de ${contractInvoices.length}` : ""} registros</span>} />
                    {filteredContractInvoices.length ? (
                      <div className="overflow-hidden rounded-[18px] border border-[#E1E7EE] bg-white">
                        <div className="max-h-[292px] overflow-auto">
                          <div className="overflow-x-auto"><table className="w-full min-w-[860px] border-collapse"><thead className="sticky top-0 z-10"><tr className="border-b border-[#E8ECF1] bg-[#F8FAFC] text-left"><th className="px-5 py-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Factura</th><th className="px-5 py-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Periodo</th><th className="px-5 py-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Emisión</th><th className="px-5 py-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Estado</th><th className="px-5 py-3 text-right text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Importe</th></tr></thead><tbody>{filteredContractInvoices.map((invoice) => <tr key={invoice.id} className="border-b border-[#EEF1F4] last:border-b-0"><td className="px-5 py-4"><p className="text-[13px] font-semibold text-[#344054]">{invoice.serie}-{invoice.numero}</p><p className="mt-1 max-w-[280px] truncate text-[11px] text-[#8A95A5]">{invoice.descripcion}</p></td><td className="px-5 py-4 text-[12px] text-[#526174]">{formatCompactDate(invoice.periodo_inicio)} - {formatCompactDate(invoice.periodo_fin)}</td><td className="px-5 py-4 text-[12px] text-[#526174]">{formatCompactDate(invoice.fecha_emision)}</td><td className="px-5 py-4"><span className={["rounded-full border px-2.5 py-1 text-[10px] font-semibold", statusPill(invoice.estado)].join(" ")}>{invoiceStatusLabel(invoice.estado)}</span></td><td className="px-5 py-4 text-right text-[13px] font-semibold text-[#1F3048]">{formatCurrency(invoice.importe_a_pagar || invoice.monto, invoice.moneda)}</td></tr>)}</tbody></table></div>
                        </div>
                      </div>
                    ) : <EmptyState title="Todavía no hay facturas de mantenimiento" text="Las facturas periódicas de tu contrato aparecerán aquí cuando sean emitidas." icon={Receipt} />}
                  </section>

                  <section className="mb-8">
                    <SectionTitle
                      eyebrow="Gestión del contrato"
                      title="Documentación"
                      action={
                        <span className="text-[11px] text-[#8A95A5]">
                          {filteredInvoiceOnlyDocuments.length + filteredStripeDocuments.length}{selectedBillingMonth ? ` de ${invoiceOnlyDocuments.length + stripeDocuments.length}` : ""} documentos
                        </span>
                      }
                    />

                    <div className="grid gap-5 lg:grid-cols-2">
                      <DetailBox title="Documentos de factura" icon={FileText}>
                        {filteredInvoiceOnlyDocuments.length ? (
                          <div className="max-h-[270px] overflow-y-auto pr-1">
                            <div className="divide-y divide-[#E9EDF2]">
                              {filteredInvoiceOnlyDocuments.map((document) => (
                                <div
                                  key={`${document.invoice.id}-${document.path}`}
                                  className="flex flex-col gap-4 py-4 first:pt-1 last:pb-1 sm:flex-row sm:items-center sm:justify-between"
                                >
                                  <div className="min-w-0">
                                    <p className="text-[13px] font-semibold text-[#344054]">
                                      {document.invoice.serie}-{document.invoice.numero}
                                    </p>
                                    <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-[#8A95A5]">
                                      <span>{document.label}</span>
                                      <span>Adjuntado por el equipo de Modira</span>
                                      {document.uploadedAt && (
                                        <span>{formatCompactDate(document.uploadedAt)}</span>
                                      )}
                                    </div>
                                  </div>

                                  <button
                                    type="button"
                                    onClick={() => {
                                      void supabase.storage
                                        .from("maintenance-invoices")
                                        .createSignedUrl(document.path, 60 * 5)
                                        .then(({ data, error }) => {
                                          if (error) throw error;
                                          if (data?.signedUrl) {
                                            window.open(data.signedUrl, "_blank", "noopener,noreferrer");
                                          }
                                        })
                                        .catch((error) => {
                                          toast.error(error?.message || "No se pudo abrir el documento.");
                                        });
                                    }}
                                    className="inline-flex h-10 shrink-0 items-center justify-center gap-2 rounded-lg border border-[#DCE2E9] bg-white px-4 text-[12px] font-semibold text-[#173B8F] transition-colors hover:bg-[#F7F9FB]"
                                  >
                                    <FileText className="h-3.5 w-3.5" />
                                    Ver documento
                                  </button>
                                </div>
                              ))}
                            </div>
                          </div>
                        ) : (
                          <EmptyState
                            title="Todavía no hay documentos de factura"
                            text="Cuando exista un PDF asociado a una factura de mantenimiento, aparecerá aquí con acceso seguro."
                            icon={FileText}
                          />
                        )}
                      </DetailBox>

                      <DetailBox title="Justificantes de cobro" icon={CreditCard}>
                        {filteredStripeDocuments.length ? (
                          <div className="max-h-[270px] overflow-y-auto pr-1">
                            <div className="divide-y divide-[#E9EDF2]">
                              {filteredStripeDocuments.map((document) => (
                                <div
                                  key={`${document.invoice.id}-${document.path}`}
                                  className="flex flex-col gap-4 py-4 first:pt-1 last:pb-1 sm:flex-row sm:items-center sm:justify-between"
                                >
                                  <div className="min-w-0">
                                    <p className="text-[13px] font-semibold text-[#344054]">
                                      {document.invoice.serie}-{document.invoice.numero}
                                    </p>
                                    <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-[#8A95A5]">
                                      <span>Justificante de cobro Stripe</span>
                                      <span>Documento generado por Stripe</span>
                                    </div>
                                  </div>

                                  <button
                                    type="button"
                                    onClick={() => {
                                      void supabase.storage
                                        .from("maintenance-invoices")
                                        .createSignedUrl(document.path, 60 * 5)
                                        .then(({ data, error }) => {
                                          if (error) throw error;
                                          if (data?.signedUrl) {
                                            window.open(data.signedUrl, "_blank", "noopener,noreferrer");
                                          }
                                        })
                                        .catch((error) => {
                                          toast.error(error?.message || "No se pudo abrir el documento.");
                                        });
                                    }}
                                    className="inline-flex h-10 shrink-0 items-center justify-center gap-2 rounded-lg border border-[#DCE2E9] bg-white px-4 text-[12px] font-semibold text-[#173B8F] transition-colors hover:bg-[#F7F9FB]"
                                  >
                                    <FileText className="h-3.5 w-3.5" />
                                    Ver documento
                                  </button>
                                </div>
                              ))}
                            </div>
                          </div>
                        ) : (
                          <EmptyState
                            title="Todavía no hay justificantes de cobro"
                            text="Los documentos generados por Stripe asociados a tus cobros aparecerán aquí cuando estén disponibles."
                            icon={CreditCard}
                          />
                        )}
                      </DetailBox>
                    </div>
                  </section>

                  <section className="mb-8">
                    <SectionTitle eyebrow="Pagos" title="Historial de pagos" action={<span className="text-[11px] text-[#8A95A5]">{filteredPayments.length}{selectedBillingMonth ? ` de ${payments.length}` : ""} movimientos</span>} />
                    {filteredPayments.length ? (
                      <div className="overflow-hidden rounded-[18px] border border-[#E1E7EE] bg-white">
                        <div className="max-h-[292px] overflow-auto">
                          <div className="overflow-x-auto"><table className="w-full min-w-[760px] border-collapse"><thead className="sticky top-0 z-10"><tr className="border-b border-[#E8ECF1] bg-[#F8FAFC] text-left"><th className="px-5 py-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Pago</th><th className="px-5 py-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Factura</th><th className="px-5 py-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Estado</th><th className="px-5 py-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Fecha</th><th className="px-5 py-3 text-right text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Importe</th></tr></thead><tbody>{filteredPayments.map((payment) => {
                            const rawAmount = payment.amount ?? payment.importe ?? payment.monto ?? payment.amount_eur ?? 0;
                            const amount = payment.amount != null && payment.importe == null && payment.monto == null
                              ? Number(rawAmount) / 100
                              : Number(rawAmount);
                            const paymentInvoice = contractInvoices.find((invoice) => invoice.id === payment.maintenance_invoice_id);
                            return <tr key={payment.id} className="border-b border-[#EEF1F4] last:border-b-0"><td className="px-5 py-4 text-[12px] font-medium text-[#344054]">{payment.id || "—"}</td><td className="px-5 py-4 text-[12px] text-[#526174]">{paymentInvoice ? `${paymentInvoice.serie}-${paymentInvoice.numero}` : payment.maintenance_invoice_id || "—"}</td><td className="px-5 py-4"><span className={["rounded-full border px-2.5 py-1 text-[10px] font-semibold", statusPill(payment.status || "")].join(" ")}>{payment.status || "—"}</span></td><td className="px-5 py-4 text-[12px] text-[#526174]">{formatCompactDate(payment.paid_at || payment.created_at)}</td><td className="px-5 py-4 text-right text-[13px] font-semibold text-[#1F3048]">{formatCurrency(amount, payment.currency || payment.moneda || "EUR")}</td></tr>;
                          })}</tbody></table></div>
                        </div>
                      </div>
                    ) : <EmptyState title="Todavía no hay pagos registrados" text="Los pagos asociados a las facturas de mantenimiento aparecerán aquí cuando se registren." icon={CreditCard} />}
                  </section>

                </>
              )}

              {activeContracts.length > 0 && maintenanceSection === "fiscal" && (
                <section className="mb-8">
                    <SectionTitle eyebrow="Información fiscal" title="Datos utilizados en la facturación" />
                    <DetailBox title="Datos fiscales actuales" icon={FileText}>
                      <div className="grid gap-x-8 sm:grid-cols-2">
                        <InfoRow label="Razón social" value={company?.legal_name || company?.company_name || "—"} />
                        <InfoRow label="NIF/CIF/VAT" value={company?.cif_vat || "—"} />
                        <InfoRow label="Dirección" value={company?.address || "—"} />
                        <InfoRow label="Código postal" value={company?.postal_code || "—"} />
                        <InfoRow label="Ciudad" value={company?.city || "—"} />
                        <InfoRow label="Provincia" value={company?.province || "—"} />
                        <InfoRow label="País" value={company?.country || "—"} />
                      </div>

                      <div
                        className={[
                          "mt-4 rounded-xl border px-3.5 py-3",
                          fiscalRequest?.status === "pending"
                            ? "border-[#E5DCC0] bg-[#FFFBF1]"
                            : fiscalComplete || fiscalRequest?.status === "approved"
                              ? "border-[#D7E6DB] bg-[#F5FAF6]"
                              : "border-[#E5DCC0] bg-[#FFFBF1]",
                        ].join(" ")}
                      >
                        <p
                          className={[
                            "text-[11px] font-medium",
                            fiscalRequest?.status === "pending"
                              ? "text-[#9A8050]"
                              : fiscalComplete || fiscalRequest?.status === "approved"
                                ? "text-[#5E9470]"
                                : "text-[#9A8050]",
                          ].join(" ")}
                        >
                          {fiscalRequest?.status === "pending"
                            ? "Solicitud de cambio fiscal pendiente de revisión"
                            : fiscalRequest?.status === "approved"
                              ? "Datos fiscales completos · Solicitud aprobada"
                              : fiscalRequest?.status === "rejected"
                                ? "Datos fiscales actuales · Solicitud rechazada"
                                : fiscalComplete
                                  ? "Datos fiscales completos"
                                  : "Datos fiscales incompletos"}
                        </p>
                      </div>
                    </DetailBox>
                </section>
              )}
            </>
          )}
        </div>
      </main>

      {showProjectChange && projectChangeContractId && contracts.find((contract) => contract.id === projectChangeContractId) && (() => {
        const projectChangeContract = contracts.find((contract) => contract.id === projectChangeContractId);
        if (!projectChangeContract) return null;

        const currentProjectId = contractProjects.find(
          (row) => row.maintenance_contract_id === projectChangeContract.id,
        )?.project_id || null;
        const selectableProjects = companyProjects.filter((project) => {
          if (project.id === currentProjectId) return false;
          return !getProjectContract(project.id);
        });

        return (
          <div className="fixed inset-0 z-[80] flex items-center justify-center bg-[#172033]/25 p-5 backdrop-blur-[1px]">
            <div className="w-full max-w-[560px] rounded-[20px] border border-[#E1E7EE] bg-white p-6 shadow-[0_24px_70px_rgba(24,42,69,0.18)] sm:p-7">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Gestión del contrato</p>
                  <h2 className="mt-1 text-xl font-semibold text-[#26344A]">Cambiar proyecto</h2>
                  <p className="mt-1 text-[11px] text-[#8A95A5]">{projectChangeContract.nombre_plan || "Mantenimiento"}</p>
                </div>
                <button type="button" onClick={() => { setShowProjectChange(false); setProjectChangeContractId(null); setProjectChangeProjectId(null); }} className="rounded-lg p-2 text-[#7C8797] hover:bg-[#F5F7F9]"><X className="h-4 w-4" /></button>
              </div>

              <p className="mt-3 text-[13px] leading-6 text-[#718096]">Selecciona el nuevo proyecto. La solicitud quedará pendiente de revisión por Modira y, si se aprueba, se aplicará en la siguiente fecha de facturación disponible sin modificar el periodo actual.</p>

              <div className="mt-5 space-y-2">
                {selectableProjects.length > 0 ? selectableProjects.map((project) => (
                  <button key={project.id} type="button" onClick={() => setProjectChangeProjectId(project.id)} className={["flex w-full items-center justify-between rounded-xl border px-4 py-3 text-left", projectChangeProjectId === project.id ? "border-[#173B8F] bg-[#F1F5FC]" : "border-[#E1E7EE] bg-white hover:bg-[#F8FAFC]"].join(" ")}>
                    <span><span className="block text-[13px] font-semibold text-[#344054]">{project.nombre || "Proyecto"}</span><span className="mt-1 block text-[11px] text-[#8A95A5]">Disponible para el cambio</span></span>
                    {projectChangeProjectId === project.id && <CheckCircle2 className="h-5 w-5 text-[#173B8F]" />}
                  </button>
                )) : (
                  <div className="border border-[#E5DCC0] bg-[#FFFBF1] p-4 text-[12px] leading-5 text-[#735D2B]">No hay otro proyecto disponible para trasladar este mantenimiento. Los proyectos que ya tienen un mantenimiento activo no pueden seleccionarse.</div>
                )}
              </div>

              <div className="mt-6 flex gap-3">
                <button type="button" onClick={() => { setShowProjectChange(false); setProjectChangeContractId(null); setProjectChangeProjectId(null); }} className="h-11 flex-1 rounded-xl border border-[#DCE2E9] text-[12px] font-semibold text-[#526174]">Cancelar</button>
                <button type="button" disabled={!projectChangeProjectId || Boolean(actionLoading)} onClick={() => { const selectedProjectId = projectChangeProjectId; if (!selectedProjectId) return; void requestProjectChange(projectChangeContract.id, selectedProjectId); }} className="h-11 flex-1 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white disabled:opacity-50">{actionLoading === "change-project" ? "Enviando…" : "Solicitar cambio"}</button>
              </div>
            </div>
          </div>
        );
      })()}

      {showPlanChange && planChangeContractId && contracts.find((contract) => contract.id === planChangeContractId) && (
        <div className="fixed inset-0 z-[80] flex items-center justify-center bg-[#172033]/25 p-5 backdrop-blur-[1px]">
          <div className="w-full max-w-[520px] rounded-[20px] border border-[#E1E7EE] bg-white p-6 shadow-[0_24px_70px_rgba(24,42,69,0.18)] sm:p-7">
            {(() => {
              const planChangeContract = contracts.find((contract) => contract.id === planChangeContractId);
              if (!planChangeContract) return null;

              return (
                <>
            <div className="flex items-start justify-between gap-4"><div><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Gestión del contrato</p><h2 className="mt-1 text-xl font-semibold text-[#26344A]">Cambiar de plan</h2><p className="mt-1 text-[11px] text-[#8A95A5]">{planChangeContract.nombre_plan || "Mantenimiento"}</p></div><button type="button" onClick={() => setShowPlanChange(false)} className="rounded-lg p-2 text-[#7C8797] hover:bg-[#F5F7F9]"><X className="h-4 w-4" /></button></div>
            <p className="mt-3 text-[13px] leading-6 text-[#718096]">El cambio se programa mediante Stripe para la siguiente fecha de facturación aplicable. El periodo actual no se prorratea.</p>
            <div className="mt-5 space-y-2">{fixedPlans.filter((plan) => plan.id !== planChangeContract.plan_id).map((plan) => <button key={plan.id} type="button" onClick={() => setSelectedPlan(plan.code)} className={["flex w-full items-center justify-between rounded-xl border px-4 py-3 text-left", selectedPlan === plan.code ? "border-[#173B8F] bg-[#F1F5FC]" : "border-[#E1E7EE] bg-white hover:bg-[#F8FAFC]"].join(" ")}><span><span className="block text-[13px] font-semibold text-[#344054]">{plan.nombre}</span><span className="mt-1 block text-[11px] text-[#8A95A5]">{formatCurrency(plan.precio, plan.moneda)}/mes</span></span>{selectedPlan === plan.code && <CheckCircle2 className="h-5 w-5 text-[#173B8F]" />}</button>)}</div>
            <div className="mt-6 flex gap-3"><button type="button" onClick={() => { setShowPlanChange(false); setPlanChangeContractId(null); }} className="h-11 flex-1 rounded-xl border border-[#DCE2E9] text-[12px] font-semibold text-[#526174]">Cancelar</button><button type="button" disabled={!selectedPlan || actionLoading === "change-plan"} onClick={() => {
                const plan = fixedPlans.find((item) => item.code === selectedPlan) || null;
                if (!plan || !planChangeContract) return;
                setShowPlanChange(false);
                setPlanChangeContractId(null);
                void changePlan(planChangeContract.id, plan.code);
              }} className="h-11 flex-1 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white disabled:opacity-50">{actionLoading === "change-plan" ? "Programando…" : "Confirmar cambio"}</button></div>
                </>
              );
            })()}
          </div>
        </div>
      )}


      {showCancelConfirm && cancelContractId && (() => {
        const cancelTarget = contracts.find((contract) => contract.id === cancelContractId);
        if (!cancelTarget) return null;
        const cancelProjectNames = contractProjects
          .filter((row) => row.maintenance_contract_id === cancelTarget.id)
          .map((row) => row.projects?.nombre || row.project_name || row.nombre || row.project?.nombre || row.project_id || "Proyecto");

        return (
          <div className="fixed inset-0 z-[80] flex items-center justify-center bg-[#172033]/25 p-5 backdrop-blur-[1px]">
            <div className="w-full max-w-[500px] rounded-[20px] border border-[#E1E7EE] bg-white p-6 shadow-[0_24px_70px_rgba(24,42,69,0.18)] sm:p-7">
              <div className="flex items-start justify-between gap-4"><div><p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">Gestión del contrato</p><h2 className="mt-1 text-xl font-semibold text-[#26344A]">Solicitar cancelación</h2><p className="mt-1 text-[11px] text-[#8A95A5]">{cancelTarget.nombre_plan || "Mantenimiento"}</p></div><button type="button" onClick={() => { setShowCancelConfirm(false); setCancelContractId(null); }} className="rounded-lg p-2 text-[#7C8797] hover:bg-[#F5F7F9]"><X className="h-4 w-4" /></button></div>
              <div className="mt-4 border border-[#E5DCC0] bg-[#FFFBF1] p-4 text-[12px] leading-5 text-[#735D2B]"><strong>Contrato seleccionado:</strong> {cancelProjectNames.length ? cancelProjectNames.join(", ") : "Proyecto asociado"}. La Edge Function aplica la regla de 7 días naturales antes de renovación y programa la cancelación directamente en Stripe.</div>
              <p className="mt-4 text-[13px] leading-6 text-[#718096]">¿Quieres solicitar la cancelación de este contrato de mantenimiento?</p>
              <div className="mt-6 flex gap-3"><button type="button" onClick={() => { setShowCancelConfirm(false); setCancelContractId(null); }} className="h-11 flex-1 rounded-xl border border-[#DCE2E9] text-[12px] font-semibold text-[#526174]">Mantener contrato</button><button type="button" disabled={actionLoading === "cancel"} onClick={() => void cancelContract(cancelTarget.id)} className="h-11 flex-1 rounded-xl bg-[#4B3E57] text-[12px] font-semibold text-white disabled:opacity-50">{actionLoading === "cancel" ? "Solicitando…" : "Confirmar cancelación"}</button></div>
            </div>
          </div>
        );
            })()}

      {customCheckoutProjectPickerOpen && proposal && (
        <div className="fixed inset-0 z-[100] flex items-center justify-center bg-[#172033]/25 p-5 backdrop-blur-[1px]">
          <div className="w-full max-w-[560px] rounded-[20px] border border-[#E1E7EE] bg-white p-6 shadow-[0_24px_70px_rgba(24,42,69,0.18)] sm:p-7">

            <div className="flex items-start justify-between gap-4">
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">
                  Mantenimiento personalizado
                </p>
                <h2 className="mt-1 text-xl font-semibold text-[#26344A]">
                  Selecciona el proyecto asociado
                </h2>
              </div>

              <button
                type="button"
                onClick={() => {
                  setCustomCheckoutProjectPickerOpen(false);
                  setCustomCheckoutProjectId(null);
                }}
                className="rounded-lg p-2 text-[#7C8797] hover:bg-[#F5F7F9]"
              >
                <X className="h-4 w-4" />
              </button>
            </div>

            <p className="mt-3 text-[13px] leading-6 text-[#718096]">
              La propuesta personalizada se contratará para el proyecto que
              selecciones. Los proyectos que ya tienen mantenimiento no aparecen aquí.
            </p>

            <div className="mt-5 space-y-2">
              {companyProjects
                .filter((project) => !getProjectContract(project.id))
                .map((project) => (
                  <button
                    key={project.id}
                    type="button"
                    onClick={() => setCustomCheckoutProjectId(project.id)}
                    className={[
                      "flex w-full items-center justify-between rounded-xl border px-4 py-3 text-left",
                      customCheckoutProjectId === project.id
                        ? "border-[#173B8F] bg-[#F1F5FC]"
                        : "border-[#E1E7EE] bg-white hover:bg-[#F8FAFC]",
                    ].join(" ")}
                  >
                    <span>
                      <span className="block text-[13px] font-semibold text-[#344054]">
                        {project.nombre || "Proyecto"}
                      </span>
                      <span className="mt-1 block text-[11px] text-[#8A95A5]">
                        Proyecto de tu empresa
                      </span>
                    </span>

                    {customCheckoutProjectId === project.id && (
                      <CheckCircle2 className="h-5 w-5 text-[#173B8F]" />
                    )}
                  </button>
                ))}
            </div>

            <div className="mt-6 flex gap-3">
              <button
                type="button"
                onClick={() => {
                  setCustomCheckoutProjectPickerOpen(false);
                  setCustomCheckoutProjectId(null);
                }}
                className="h-11 flex-1 rounded-xl border border-[#DCE2E9] text-[12px] font-semibold text-[#526174]"
              >
                Cancelar
              </button>

              <button
                type="button"
                disabled={
  !customCheckoutProjectId ||
  !acceptGeneralConditions ||
  !acceptSpecificConditions ||
  customCheckoutLoading
}
                onClick={() => {
                  const selectedProjectId = customCheckoutProjectId;
                  if (!selectedProjectId) return;

                  setCustomCheckoutProjectPickerOpen(false);
                  setCustomCheckoutProjectId(null);

                  void acceptAndCheckout(selectedProjectId);
                }}
                className="h-11 flex-1 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white disabled:opacity-50"
              >
                {customCheckoutLoading ? "Preparando…" : "Continuar"}
              </button>
            </div>

          </div>
        </div>
      )}
{ivaRequestOpen && (
  <div className="fixed inset-0 z-[200] flex items-center justify-center bg-black/30 px-4">
    <div className="w-[90vw] max-w-[500px] max-h-[90vh] overflow-y-auto rounded-2xl bg-white p-6 shadow-2xl">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-[0.08em] text-[#7C8797]">
            Fiscalidad
          </p>

          <h3 className="mt-1 text-lg font-semibold text-[#26344A]">
            Solicitar cambio de IVA
          </h3>
        </div>

        <button
          type="button"
          onClick={() => setIvaRequestOpen(false)}
          className="rounded-lg p-2 text-[#7C8797] hover:bg-[#F5F7F9]"
        >
          <X className="h-4 w-4" />
        </button>
      </div>

      <p className="mt-3 text-[12px] leading-5 text-[#718096]">
        Si consideras que tu mantenimiento debería tener un tratamiento
        fiscal diferente, puedes solicitarlo aquí. La modificación deberá
        ser revisada y aprobada por Modira.
      </p>

      <div className="mt-5 space-y-4">
        <div>
          <label className="mb-2 block text-[11px] font-semibold text-[#526174]">
            ¿Debe aplicarse IVA?
          </label>

          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => setIvaRequestApplied(true)}
              className={[
                "flex-1 rounded-xl border px-4 py-2.5 text-[12px] font-semibold",
                ivaRequestApplied
                  ? "border-[#173B8F] bg-[#F1F5FC] text-[#173B8F]"
                  : "border-[#DCE2E9] bg-white text-[#526174]",
              ].join(" ")}
            >
              Sí
            </button>

            <button
              type="button"
              onClick={() => {
                setIvaRequestApplied(false);
                setIvaRequestPercentage("0");
              }}
              className={[
                "flex-1 rounded-xl border px-4 py-2.5 text-[12px] font-semibold",
                !ivaRequestApplied
                  ? "border-[#173B8F] bg-[#F1F5FC] text-[#173B8F]"
                  : "border-[#DCE2E9] bg-white text-[#526174]",
              ].join(" ")}
            >
              No
            </button>
          </div>
        </div>

        {ivaRequestApplied && (
          <div>
            <label className="mb-2 block text-[11px] font-semibold text-[#526174]">
              Porcentaje de IVA solicitado
            </label>

            <div className="relative">
              <input
                type="number"
                min="0"
                max="100"
                step="0.01"
                value={ivaRequestPercentage}
                onChange={(event) =>
                  setIvaRequestPercentage(event.target.value)
                }
                className="h-10 w-full rounded-xl border border-[#DCE2E9] px-3 pr-10 text-sm outline-none focus:border-[#173B8F]"
              />

              <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-xs text-[#8A95A5]">
                %
              </span>
            </div>
          </div>
        )}

        <div>
          <label className="mb-2 block text-[11px] font-semibold text-[#526174]">
            Motivo de la solicitud
          </label>

          <textarea
            value={ivaRequestMessage}
            onChange={(event) =>
              setIvaRequestMessage(event.target.value)
            }
            rows={4}
            maxLength={1000}
            placeholder="Explica brevemente por qué necesitas un tratamiento fiscal diferente..."
            className="w-full resize-none rounded-xl border border-[#DCE2E9] px-3 py-2.5 text-[12px] leading-5 outline-none focus:border-[#173B8F]"
          />
        </div>

        <div className="rounded-xl border border-blue-100 bg-blue-50/60 px-3 py-2.5">
          <div className="flex items-start gap-2">
            <Info className="mt-0.5 h-4 w-4 shrink-0 text-[#173B8F]" />

            <p className="text-[11px] leading-5 text-[#667386]">
              La solicitud no modifica el IVA inmediatamente. Un trabajador
              de Modira deberá revisarla y, si corresponde, aprobar el
              tratamiento fiscal solicitado.
            </p>
          </div>
        </div>
      </div>

      <div className="mt-6 flex gap-3">
        <button
          type="button"
          onClick={() => setIvaRequestOpen(false)}
          className="h-11 flex-1 rounded-xl border border-[#DCE2E9] text-[12px] font-semibold text-[#526174]"
        >
          Cancelar
        </button>

        <button
          type="button"
          onClick={submitIvaRequest}
          disabled={ivaRequestLoading}
          className="h-11 flex-1 rounded-xl bg-[#173B8F] text-[12px] font-semibold text-white disabled:opacity-50"
        >
          {ivaRequestLoading
            ? "Enviando…"
            : "Enviar solicitud"}
        </button>
      </div>
    </div>
  </div>
)}
    </div>
  );
}
