import { useCallback, useEffect, useMemo, useState } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import {
  ArrowLeft,
  ArrowRight,
  Bell,
  BriefcaseBusiness,
  CalendarDays,
  Check,
  ChevronDown,
  CircleHelp,
  ClipboardList,
  Download,
  ExternalLink,
  FileText,
  Home,
  Loader2,
  LogOut,
  Menu,
  MessageSquare,
  Receipt,
  RefreshCw,
  Send,
  UserRound,
  Wrench,
  X,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";

type ProjectStatus =
  | "Pendiente"
  | "Activo"
  | "Pausado"
  | "Entregado"
  | "Completado";

type MilestoneStatus = "pendiente" | "en_curso" | "completado";

interface Project {
  id: string;
  user_id: string;
  company_id: string | null;
  client_id?: string | null;
  nombre: string;
  descripcion: string | null;
  estado: ProjectStatus | string;
  fecha_inicio: string | null;
  fecha_fin: string | null;
  change_requests_enabled: boolean;
  change_requests_deadline: string | null;
  created_at: string | null;
  updated_at: string | null;
}

interface Milestone {
  id: string;
  project_id: string;
  nombre: string;
  descripcion: string | null;
  fecha_prevista: string;
  orden: number;
  estado: MilestoneStatus;
  completed_at: string | null;
  created_at: string;
  updated_at: string;
}

interface ProjectProgress {
  project_id: string;
  total_milestones: number;
  completed_milestones: number;
  progress_percentage: number;
}

interface ProjectUpdate {
  id: string;
  project_id: string;
  titulo: string;
  contenido: string;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}

interface ProjectDocument {
  id: string;
  project_id: string;
  file_name: string;
  storage_path: string;
  mime_type: string;
  file_size: number;
  uploaded_by: string | null;
  created_at: string;
  updated_at: string;
}

interface ProjectChangeRequest {
  id: string;
  project_id: string;
  user_id: string;
  company_id: string | null;
  client_id: string | null;
  description: string;
  status: string;
  reviewed_at: string | null;
  review_notes: string | null;
  accepted_at: string | null;
  completed_at: string | null;
  created_at: string;
  updated_at: string;
}

interface Quotation {
  id: string;
  company_id: string | null;
  user_id?: string | null;
  project_id: string | null;
  client_id?: string | null;
  numero_presupuesto: string | null;
  titulo: string | null;
  descripcion_detallada?: string | null;
  estado: string;
  fecha_emision: string | null;
  fecha_validez: string | null;
  precio_total?: number | null;
  subtotal?: number | null;
  iva_importe?: number | null;
  irpf_importe?: number | null;
  document_path: string | null;
  created_at: string;
  updated_at?: string | null;
}

interface Invoice {
  id: string;
  project_id: string | null;
  company_id: string | null;
  user_id: string | null;
  numero_factura: string;
  fecha_emision: string | null;
  fecha_vencimiento: string | null;
  fecha_pago?: string | null;
  descripcion: string | null;
  subtotal: number | null;
  iva_aplicado: boolean | null;
  iva_porcentaje: number | null;
  iva_importe: number | null;
  irpf_aplicado: boolean | null;
  irpf_porcentaje: number | null;
  irpf_importe: number | null;
  monto: number | null;
  importe_a_pagar: number | null;
  estado: string;
  document_path: string | null;
  created_at: string;
  updated_at?: string | null;
}

interface Payment {
  id: string;
  invoice_id: string | null;
  amount: number;
  currency: string;
  status: string;
  description: string | null;
  paid_at: string | null;
  created_at: string;
}

interface ClientNotification {
  id: string;
  project_id: string | null;
  tipo: string;
  titulo: string;
  mensaje: string;
  read_at: string | null;
  created_at: string;
}

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

const formatCurrency = (value: number | null | undefined) =>
  euro.format(Number(value ?? 0));

const formatDate = (value?: string | null) =>
  value ? dateFormatter.format(new Date(value)) : "Sin fecha";

const formatCompactDate = (value?: string | null) =>
  value ? compactDateFormatter.format(new Date(value)) : "Sin fecha";

const formatFileSize = (bytes: number) => {
  if (!bytes) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
};

const normalize = (value?: string | null) =>
  String(value || "").trim().toLowerCase();

const statusLabel = (status?: string | null) => {
  const value = normalize(status);
  if (value === "pendiente" || value === "pending") return "Pendiente";
  if (value === "activo") return "Activo";
  if (value === "pausado") return "Pausado";
  if (value === "entregado") return "Entregado";
  if (value === "completado") return "Completado";
  if (value === "en_curso") return "En curso";
  if (value === "in_review") return "En revisión";
  if (value === "accepted" || value === "aceptado") return "Aceptada";
  if (value === "rejected" || value === "rechazado") return "Rechazada";
  if (value === "completed") return "Completada";
  return status || "Pendiente";
};

const projectStatusClasses = (status: string) => {
  switch (normalize(status)) {
    case "activo":
      return "border-[#D8E1F5] bg-[#EEF3FF] text-[#173B8F]";
    case "pausado":
      return "border-[#F0DEB7] bg-[#FFF7E8] text-[#A56A00]";
    case "entregado":
      return "border-[#DDD8E7] bg-[#F3F1F8] text-[#4B3E57]";
    case "completado":
      return "border-[#CDE8D8] bg-[#ECF8F1] text-[#247A49]";
    default:
      return "border-[#E0E5EA] bg-[#F4F6F8] text-[#667386]";
  }
};

const changeRequestClasses = (status: string) => {
  switch (normalize(status)) {
    case "accepted":
      return "border-[#CDE8D8] bg-[#ECF8F1] text-[#247A49]";
    case "completed":
      return "border-[#D8E1F5] bg-[#EEF3FF] text-[#173B8F]";
    case "rejected":
      return "border-[#F0D0D0] bg-[#FFF0F0] text-[#B53A3A]";
    case "in_review":
      return "border-[#F0DEB7] bg-[#FFF7E8] text-[#A56A00]";
    default:
      return "border-[#E0E5EA] bg-[#F4F6F8] text-[#667386]";
  }
};

const SectionTitle = ({
  eyebrow,
  title,
  action,
}: {
  eyebrow?: string;
  title: string;
  action?: React.ReactNode;
}) => (
  <div className="mb-5 flex items-end justify-between gap-4">
    <div>
      {eyebrow && (
        <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
          {eyebrow}
        </p>
      )}
      <h2 className="text-xl font-semibold tracking-tight text-[#182A45] sm:text-2xl">
        {title}
      </h2>
    </div>
    {action}
  </div>
);

function ClientAreaSidebar({
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
}) {
  const navigationItems = [
    { label: "Inicio", path: "/area-cliente", icon: Home },
    { label: "Mi perfil", path: "#perfil", icon: UserRound },
    { label: "Mis proyectos", path: "/area-cliente/proyectos", icon: BriefcaseBusiness },
    { label: "Mantenimiento", path: "/area-cliente/mantenimiento", icon: ClipboardList },
    { label: "Presupuestos", path: "/area-cliente/presupuestos", icon: FileText },
    { label: "Facturación", path: "/area-cliente/facturacion", icon: Receipt },
    { label: "Documentos", path: "/area-cliente/documentos", icon: FileText },
    { label: "Soporte técnico", path: "/area-cliente/soporte", icon: Wrench },
    { label: "Ayuda", path: "#ayuda", icon: CircleHelp },
  ];

  const isActive = (path: string) => {
    if (path.startsWith("#")) return false;
    if (path === "/area-cliente") return location === path;
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
                className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-[#718096] hover:bg-[#F2F5F9] hover:text-[#173B8F]"
              >
                <X className="h-4 w-4" strokeWidth={1.8} />
              </button>
            </>
          ) : (
            <button
              type="button"
              onClick={onToggle}
              aria-label="Abrir menú"
              className="flex h-8 w-full items-center justify-center rounded-md text-[#718096] hover:bg-[#F2F5F9] hover:text-[#173B8F]"
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
                    isOpen ? "gap-3 px-3 py-2.5" : "justify-center px-2 py-2.5",
                    active
                      ? "bg-[#173B8F] text-white"
                      : "text-[#647187] hover:bg-[#F3F5F8] hover:text-[#173B8F]",
                  ].join(" ")}
                >
                  <Icon className="h-[17px] w-[17px] shrink-0" strokeWidth={1.75} />
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
              isOpen ? "gap-3 px-3 py-2.5" : "justify-center px-2 py-2.5",
            ].join(" ")}
          >
            <LogOut className="h-[17px] w-[17px] shrink-0" strokeWidth={1.75} />
            {isOpen && <span className="text-[12px] font-medium">Cerrar sesión</span>}
          </button>
        </div>
      </aside>
    </>
  );
}

function ProjectProgressRing({
  percentage,
  status,
}: {
  percentage: number;
  status: string;
}) {
  const value = Math.max(0, Math.min(100, Math.round(percentage)));
  const radius = 46;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference - (value / 100) * circumference;

  const tone =
    normalize(status) === "pausado" || normalize(status) === "pendiente"
      ? "text-amber-400"
      : normalize(status) === "completado"
        ? "text-[#8B78A0]"
        : normalize(status) === "entregado"
          ? "text-[#CBD1D9]"
          : "text-emerald-500";

  return (
    <div className="relative h-28 w-28 shrink-0">
      <svg viewBox="0 0 120 120" className="h-full w-full -rotate-90">
        <circle
          cx="60"
          cy="60"
          r={radius}
          fill="none"
          stroke="currentColor"
          strokeWidth="5"
          className="text-[#E8ECF2]"
        />
        <circle
          cx="60"
          cy="60"
          r={radius}
          fill="none"
          stroke="currentColor"
          strokeWidth="5"
          strokeLinecap="round"
          className={`${tone} transition-all duration-700`}
          strokeDasharray={circumference}
          strokeDashoffset={offset}
        />
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center">
        <span className="text-2xl font-semibold tracking-tight text-[#102A66]">
          {value}%
        </span>
        <span className="mt-0.5 text-[9px] font-medium uppercase tracking-[0.16em] text-[#8A96A8]">
          progreso
        </span>
      </div>
    </div>
  );
}

function ProjectMilestoneTimeline({
  project,
  milestones,
}: {
  project: Project;
  milestones: Milestone[];
}) {
  const ordered = [...milestones].sort((a, b) => a.orden - b.orden);
  const projectCompleted =
    normalize(project.estado) === "completado" ||
    normalize(project.estado) === "entregado";
  const paused = normalize(project.estado) === "pausado";
  const accent = paused ? "#F2B84B" : "#247A49";

  return (
    <section>
      <SectionTitle
        eyebrow="Seguimiento"
        title="Hitos del proyecto"
        action={
          <span className="text-[10px] font-medium text-[#8A95A5]">
            {ordered.filter((item) => item.estado === "completado").length} de{" "}
            {ordered.length} completados
          </span>
        }
      />

      <div className="border border-[#E1E7EE] bg-white px-5 py-6 sm:px-7 sm:py-8">
        {ordered.length === 0 ? (
          <p className="text-[11px] leading-5 text-[#8792A3]">
            Todavía no se han definido hitos para este proyecto.
          </p>
        ) : (
          <ol>
            {ordered.map((milestone, index) => {
              const completed =
                milestone.estado === "completado" || projectCompleted;
              const current =
                !completed && milestone.estado === "en_curso";
              const isLast = index === ordered.length - 1;

              return (
                <li
                  key={milestone.id}
                  className="relative grid grid-cols-[48px_minmax(0,1fr)] gap-4 sm:grid-cols-[52px_minmax(0,1fr)_190px] sm:gap-5"
                >
                  {!isLast && (
                    <span
                      aria-hidden="true"
                      className="absolute left-[23px] top-[44px] z-0 h-[calc(100%-10px)] w-[2px] bg-[#E5E9EF] sm:left-[25px]"
                    >
                      {completed && (
                        <span
                          className="absolute left-0 top-0 h-full w-full rounded-full"
                          style={{ backgroundColor: accent }}
                        />
                      )}
                    </span>
                  )}

                  <div className="relative z-10 flex justify-center">
                    <span
                      className={[
                        "flex h-11 w-11 items-center justify-center rounded-full bg-white shadow-[0_0_0_5px_rgba(255,255,255,1)] sm:h-12 sm:w-12",
                        completed
                          ? "text-white"
                          : current
                            ? "border-[3px] text-[#173B8F]"
                            : "border-2 text-[#8994A4]",
                      ].join(" ")}
                      style={
                        completed
                          ? { backgroundColor: accent }
                          : current
                            ? { borderColor: "#173B8F" }
                            : { borderColor: "#D5DCE5" }
                      }
                    >
                      {completed ? (
                        <Check className="h-4 w-4" strokeWidth={2.7} />
                      ) : current ? (
                        <span className="h-3 w-3 rounded-full bg-[#173B8F]" />
                      ) : (
                        <span className="text-[10px] font-semibold">
                          {index + 1}
                        </span>
                      )}
                    </span>
                  </div>

                  <div className="min-w-0 pb-8 sm:pb-9">
                    <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-6">
                      <div className="min-w-0 pr-2">
                        <div className="flex flex-wrap items-center gap-2">
                          <h3 className="text-[14px] font-semibold tracking-tight text-[#26364D]">
                            {milestone.nombre}
                          </h3>
                          <span
                            className={[
                              "rounded-full border px-2 py-0.5 text-[8px] font-semibold uppercase tracking-[0.08em]",
                              completed
                                ? "border-[#CDE8D8] bg-[#ECF8F1] text-[#247A49]"
                                : current
                                  ? "border-[#D8E1F5] bg-[#EEF3FF] text-[#173B8F]"
                                  : "border-[#E1E6EC] bg-[#F7F8FA] text-[#7A8595]",
                            ].join(" ")}
                          >
                            {completed
                              ? "Completado"
                              : current
                                ? "En curso"
                                : "Pendiente"}
                          </span>
                        </div>
                        <p className="mt-1.5 max-w-3xl whitespace-pre-wrap text-[11px] leading-5 text-[#718096]">
                          {milestone.descripcion || "Sin descripción adicional."}
                        </p>
                      </div>

                      <div className="shrink-0 sm:min-w-[120px] sm:text-right">
                        <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">
                          Fecha prevista
                        </p>
                        <p className="mt-1 text-[11px] font-medium text-[#445166]">
                          {formatCompactDate(milestone.fecha_prevista)}
                        </p>
                      </div>
                    </div>
                  </div>
                </li>
              );
            })}
          </ol>
        )}
      </div>
    </section>
  );
}

function ProjectNavigation({
  active,
  counts,
  onChange,
}: {
  active: string;
  counts: Record<string, number>;
  onChange: (id: string) => void;
}) {
  const sections = [
    { id: "novedades", label: "Novedades" },
    { id: "documentos", label: "Documentos" },
    { id: "cambios", label: "Solicitudes de cambio" },
    { id: "presupuestos", label: "Presupuestos vinculados" },
    { id: "facturas", label: "Facturas" },
  ];

  return (
    <nav
      className="sticky top-0 z-20 -mx-1 overflow-x-auto bg-[#FBFCFE]/95 px-1 py-2 backdrop-blur"
      aria-label="Secciones del proyecto"
    >
      <div className="mx-auto flex min-w-max w-fit items-stretch gap-1.5 rounded-[22px] border border-[#DDE4EC] bg-white p-2 shadow-[0_8px_28px_rgba(24,42,69,0.045)] lg:min-w-[1040px]">
        {sections.map((section) => {
          const isActive = active === section.id;
          const count = counts[section.id] ?? 0;

          return (
            <button
              key={section.id}
              type="button"
              onClick={() => onChange(section.id)}
              className={[
                "relative flex min-h-[52px] flex-1 items-center justify-center rounded-[16px] px-5 pr-12 text-[12px] font-medium leading-tight transition-all duration-200 sm:px-6 sm:pr-12",
                isActive
                  ? "bg-[#173B8F] font-semibold text-white shadow-[0_5px_14px_rgba(23,59,143,0.18)]"
                  : "text-[#667386] hover:bg-[#F6F8FB] hover:text-[#173B8F]",
              ].join(" ")}
            >
              <span className="whitespace-nowrap">{section.label}</span>
              <span
                className={[
                  "absolute right-2.5 top-2 flex h-[21px] min-w-[21px] items-center justify-center rounded-full border px-1 text-[8px] font-bold leading-none",
                  isActive
                    ? "border-white/25 bg-white text-[#173B8F] shadow-[0_0_0_3px_rgba(255,255,255,0.10)]"
                    : count > 0
                      ? "border-[#D8E0EA] bg-[#F3F6FA] text-[#5F6E82]"
                      : "border-[#E5E9EE] bg-[#FAFBFC] text-[#A7AFBA]",
                ].join(" ")}
              >
                {count}
              </span>
            </button>
          );
        })}
      </div>
    </nav>
  );
}

function EmptyPanel({
  icon,
  title,
  description,
}: {
  icon: React.ReactNode;
  title: string;
  description: string;
}) {
  return (
    <div className="border border-[#E1E7EE] bg-white px-6 py-12 text-center">
      <div className="mx-auto flex h-10 w-10 items-center justify-center rounded-full bg-[#F3F5F8] text-[#718096]">
        {icon}
      </div>
      <h3 className="mt-4 text-sm font-semibold text-[#344054]">{title}</h3>
      <p className="mx-auto mt-1 max-w-md text-[11px] leading-5 text-[#98A2B3]">
        {description}
      </p>
    </div>
  );
}

function ProjectDetailContent({
  project,
  milestones,
  progress,
  updates,
  documents,
  changeRequests,
  quotations,
  invoices,
  payments,
  onOpenChangeRequest,
  onOpenProjectDocument,
  onOpenQuotationDocument,
  onOpenInvoiceDocument,
  onQuotationResponse,
  respondingQuotationId,
}: {
  project: Project;
  milestones: Milestone[];
  progress?: ProjectProgress;
  updates: ProjectUpdate[];
  documents: ProjectDocument[];
  changeRequests: ProjectChangeRequest[];
  quotations: Quotation[];
  invoices: Invoice[];
  payments: Payment[];
  onOpenChangeRequest: () => void;
  onOpenProjectDocument: (document: ProjectDocument) => void;
  onOpenQuotationDocument: (quotation: Quotation) => void;
  onOpenInvoiceDocument: (invoice: Invoice) => void;
  onQuotationResponse: (
    quotation: Quotation,
    response: "Aceptado" | "Rechazado",
  ) => void;
  respondingQuotationId: string | null;
}) {
  const [activeSection, setActiveSection] = useState<
    "novedades" | "documentos" | "cambios" | "presupuestos" | "facturas"
  >("novedades");

  const projectPayments = payments.filter((payment) =>
    invoices.some((invoice) => invoice.id === payment.invoice_id),
  );

  const totalInvoiced = invoices.reduce(
    (sum, invoice) =>
      sum + Number(invoice.importe_a_pagar ?? invoice.monto ?? 0),
    0,
  );

  const pendingChanges = changeRequests.filter((request) =>
    ["pending", "in_review"].includes(normalize(request.status)),
  ).length;

  const percentage =
    normalize(project.estado) === "completado" ||
    normalize(project.estado) === "entregado"
      ? 100
      : Math.max(0, Math.min(100, Number(progress?.progress_percentage ?? 0)));

  const counts = {
    novedades: updates.length,
    documentos: documents.length,
    cambios: changeRequests.length,
    presupuestos: quotations.length,
    facturas: invoices.length,
  };

  return (
    <div className="space-y-8">
      {/* La zona superior se divide en seguimiento + ficha del proyecto.
          Esto sustituye al antiguo Resumen como pestaña. */}
      <section className="grid gap-6 lg:grid-cols-[minmax(0,1.25fr)_minmax(320px,0.75fr)]">
        <ProjectMilestoneTimeline project={project} milestones={milestones} />

        <section className="lg:pt-[30px]">
          <div className="border border-[#E1E7EE] bg-white">
            <div className="border-b border-[#EEF1F4] px-5 py-5 sm:px-6">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <p className="text-[9px] font-semibold uppercase tracking-[0.17em] text-[#8A95A5]">
                    Estado del proyecto
                  </p>
                  <div className="mt-2 flex flex-wrap items-center gap-2">
                    <span
                      className={`rounded-full border px-2.5 py-1 text-[9px] font-semibold ${projectStatusClasses(project.estado)}`}
                    >
                      {statusLabel(project.estado)}
                    </span>
                    <span className="text-[10px] text-[#9AA4B2]">
                      {percentage}% completado
                    </span>
                  </div>
                </div>
                <ProjectProgressRing percentage={percentage} status={project.estado} />
              </div>
            </div>

            <div className="grid divide-y divide-[#EEF1F4] sm:grid-cols-2 sm:divide-x sm:divide-y-0">
              <div className="px-5 py-4 sm:px-6">
                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                  Inicio
                </p>
                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                  {formatCompactDate(project.fecha_inicio)}
                </p>
              </div>
              <div className="px-5 py-4 sm:px-6">
                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                  Fecha de fin
                </p>
                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                  {formatCompactDate(project.fecha_fin)}
                </p>
              </div>
            </div>

            <div className="border-t border-[#EEF1F4] px-5 py-5 sm:px-6">
              <div className="grid grid-cols-2 gap-x-6 gap-y-5">
                <div>
                  <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                    Hitos
                  </p>
                  <p className="mt-1 text-[17px] font-semibold text-[#26344A]">
                    {milestones.length}
                  </p>
                  <p className="text-[10px] text-[#98A2B3]">
                    {milestones.filter((m) => m.estado === "completado").length}{" "}
                    completados
                  </p>
                </div>
                <div>
                  <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                    Novedades
                  </p>
                  <p className="mt-1 text-[17px] font-semibold text-[#26344A]">
                    {updates.length}
                  </p>
                  <p className="text-[10px] text-[#98A2B3]">
                    comunicaciones
                  </p>
                </div>
                <div>
                  <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                    Solicitudes
                  </p>
                  <p className="mt-1 text-[17px] font-semibold text-[#26344A]">
                    {changeRequests.length}
                  </p>
                  <p className="text-[10px] text-[#98A2B3]">
                    {pendingChanges ? `${pendingChanges} pendientes` : "sin pendientes"}
                  </p>
                </div>
                <div>
                  <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                    Facturación
                  </p>
                  <p className="mt-1 text-[15px] font-semibold text-[#26344A]">
                    {formatCurrency(totalInvoiced)}
                  </p>
                  <p className="text-[10px] text-[#98A2B3]">
                    {invoices.length} facturas
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>
      </section>

      <ProjectNavigation
        active={activeSection}
        counts={counts}
        onChange={(id) =>
          setActiveSection(
            id as "novedades" | "documentos" | "cambios" | "presupuestos" | "facturas",
          )
        }
      />

      {activeSection === "novedades" && (
        <section>
          <SectionTitle eyebrow="Comunicación" title="Novedades" />
          {updates.length === 0 ? (
            <EmptyPanel
              icon={<MessageSquare className="h-5 w-5" />}
              title="No hay novedades publicadas"
              description="Las novedades que el equipo publique para este proyecto aparecerán aquí."
            />
          ) : (
            <div className="space-y-3">
              {updates.map((update) => (
                <article
                  key={update.id}
                  className="border border-[#E1E7EE] bg-white px-5 py-5 sm:px-6 sm:py-6"
                >
                  <div className="flex items-start gap-4">
                    <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-[#F2F5F9] text-[#173B8F]">
                      <MessageSquare className="h-4 w-4" strokeWidth={1.7} />
                    </div>
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <h3 className="text-[13px] font-semibold text-[#344054]">
                          {update.titulo}
                        </h3>
                        <span className="text-[9px] text-[#9AA4B2]">
                          {formatCompactDate(update.created_at)}
                        </span>
                      </div>
                      <p className="mt-2 whitespace-pre-wrap text-[11px] leading-5 text-[#718096]">
                        {update.contenido}
                      </p>
                    </div>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      )}

      {activeSection === "documentos" && (
        <section>
          <SectionTitle eyebrow="Archivos" title="Documentos del proyecto" />
          {documents.length === 0 ? (
            <EmptyPanel
              icon={<FileText className="h-5 w-5" />}
              title="No hay documentos"
              description="Los documentos asociados específicamente a este proyecto aparecerán aquí."
            />
          ) : (
            <div className="overflow-hidden border border-[#E1E7EE] bg-white">
              <div className="divide-y divide-[#EEF1F4]">
                {documents.map((document) => (
                  <div
                    key={document.id}
                    className="flex flex-col gap-4 px-5 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6"
                  >
                    <div className="flex min-w-0 items-center gap-3.5">
                      <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-[#F3F5F8] text-[#667386]">
                        <FileText className="h-4 w-4" strokeWidth={1.65} />
                      </span>
                      <div className="min-w-0">
                        <p className="truncate text-[12px] font-semibold text-[#344054]">
                          {document.file_name}
                        </p>
                        <p className="mt-0.5 text-[10px] text-[#8792A2]">
                          {formatFileSize(document.file_size)} · PDF ·{" "}
                          {formatCompactDate(document.created_at)}
                        </p>
                      </div>
                    </div>
                    <Button
                      type="button"
                      variant="outline"
                      onClick={() => onOpenProjectDocument(document)}
                      className="h-8 shrink-0 border-[#D7DEE7] bg-white px-3 text-[10px] font-semibold text-[#173B8F] hover:bg-[#F4F7FC]"
                    >
                      <Download className="mr-1.5 h-3.5 w-3.5" />
                      Abrir documento
                    </Button>
                  </div>
                ))}
              </div>
            </div>
          )}
        </section>
      )}

      {activeSection === "cambios" && (
        <section>
          <SectionTitle
            eyebrow="Gestión"
            title="Solicitudes de cambio"
            action={
              project.change_requests_enabled &&
              (!project.change_requests_deadline ||
                new Date(project.change_requests_deadline).getTime() > Date.now()) ? (
                <Button
                  type="button"
                  onClick={onOpenChangeRequest}
                  className="h-9 bg-[#173B8F] px-3.5 text-[10px] font-semibold text-white hover:bg-[#102A66]"
                >
                  <Wrench className="mr-1.5 h-3.5 w-3.5" />
                  Solicitar cambio
                </Button>
              ) : null
            }
          />

          {changeRequests.length === 0 ? (
            <EmptyPanel
              icon={<Wrench className="h-5 w-5" />}
              title="No hay solicitudes"
              description={
                project.change_requests_enabled
                  ? "Todavía no has registrado solicitudes de cambio para este proyecto."
                  : "El periodo de solicitudes de cambio no está habilitado para este proyecto."
              }
            />
          ) : (
            <div className="space-y-3">
              {changeRequests.map((request) => (
                <article
                  key={request.id}
                  className="border border-[#E1E7EE] bg-white px-5 py-5 sm:px-6"
                >
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <span
                          className={`rounded-full border px-2.5 py-1 text-[9px] font-semibold ${changeRequestClasses(request.status)}`}
                        >
                          {statusLabel(request.status)}
                        </span>
                        <span className="text-[9px] text-[#9AA4B2]">
                          {formatCompactDate(request.created_at)}
                        </span>
                      </div>
                      <p className="mt-3 whitespace-pre-wrap text-[11px] leading-5 text-[#59677B]">
                        {request.description}
                      </p>
                      {request.review_notes && (
                        <div className="mt-4 border-l-2 border-[#DCE3EC] pl-3">
                          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">
                            Respuesta de Modira
                          </p>
                          <p className="mt-1 text-[10px] leading-5 text-[#718096]">
                            {request.review_notes}
                          </p>
                        </div>
                      )}
                    </div>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      )}

      {activeSection === "presupuestos" && (
        <section>
          <SectionTitle eyebrow="Comercial" title="Presupuestos vinculados" />
          {quotations.length === 0 ? (
            <EmptyPanel
              icon={<FileText className="h-5 w-5" />}
              title="No hay presupuestos vinculados"
              description="Los presupuestos asociados mediante project_id a este proyecto aparecerán aquí."
            />
          ) : (
            <div className="overflow-hidden border border-[#E1E7EE] bg-white">
              <div className="divide-y divide-[#EEF1F4]">
                {quotations.map((quotation) => {
                  const pending = normalize(quotation.estado) === "pendiente";
                  return (
                    <div
                      key={quotation.id}
                      className="flex flex-col gap-4 px-5 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6"
                    >
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2.5">
                          <span className="text-[12px] font-semibold text-[#344054]">
                            {quotation.numero_presupuesto || "Presupuesto"}
                          </span>
                          <span
                            className={`rounded-full border px-2.5 py-1 text-[9px] font-semibold ${changeRequestClasses(quotation.estado)}`}
                          >
                            {statusLabel(quotation.estado)}
                          </span>
                        </div>
                        <p className="mt-1 text-[12px] font-medium text-[#445166]">
                          {quotation.titulo || "Sin título"}
                        </p>
                        <p className="mt-0.5 text-[10px] text-[#98A2B3]">
                          {quotation.fecha_emision
                            ? `Emitido ${formatCompactDate(quotation.fecha_emision)}`
                            : "Sin fecha de emisión"}
                          {quotation.fecha_validez
                            ? ` · Válido hasta ${formatCompactDate(quotation.fecha_validez)}`
                            : ""}
                        </p>
                      </div>

                      <div className="flex shrink-0 flex-wrap items-center gap-2">
                        {quotation.document_path && (
                          <Button
                            type="button"
                            variant="outline"
                            onClick={() => onOpenQuotationDocument(quotation)}
                            className="h-8 border-[#D7DEE7] px-3 text-[10px] font-semibold text-[#173B8F]"
                          >
                            <ExternalLink className="mr-1.5 h-3.5 w-3.5" />
                            Ver PDF
                          </Button>
                        )}
                        {pending && (
                          <>
                            <Button
                              type="button"
                              disabled={respondingQuotationId === quotation.id}
                              onClick={() => onQuotationResponse(quotation, "Rechazado")}
                              variant="outline"
                              className="h-8 border-[#E7CACA] px-3 text-[10px] font-semibold text-[#A05252]"
                            >
                              Rechazar
                            </Button>
                            <Button
                              type="button"
                              disabled={respondingQuotationId === quotation.id}
                              onClick={() => onQuotationResponse(quotation, "Aceptado")}
                              className="h-8 bg-[#247A49] px-3 text-[10px] font-semibold text-white hover:bg-[#1D633C]"
                            >
                              Aceptar
                            </Button>
                          </>
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </section>
      )}

      {activeSection === "facturas" && (
        <section>
          <SectionTitle eyebrow="Facturación" title="Facturas del proyecto" />
          {invoices.length === 0 ? (
            <EmptyPanel
              icon={<Receipt className="h-5 w-5" />}
              title="No hay facturas vinculadas"
              description="Las facturas cuyo project_id coincide con este proyecto aparecerán aquí."
            />
          ) : (
            <div className="overflow-hidden border border-[#E1E7EE] bg-white">
              <div className="divide-y divide-[#EEF1F4]">
                {invoices.map((invoice) => {
                  const paid = projectPayments.some(
                    (payment) =>
                      payment.invoice_id === invoice.id &&
                      normalize(payment.status) === "succeeded",
                  );

                  return (
                    <div
                      key={invoice.id}
                      className="flex flex-col gap-4 px-5 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6"
                    >
                      <div className="flex min-w-0 items-center gap-3.5">
                        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-[#F3F5F8] text-[#667386]">
                          <Receipt className="h-4 w-4" strokeWidth={1.65} />
                        </span>
                        <div className="min-w-0">
                          <div className="flex flex-wrap items-center gap-2">
                            <p className="text-[12px] font-semibold text-[#344054]">
                              {invoice.numero_factura || "Factura"}
                            </p>
                            {paid && (
                              <span className="rounded-full border border-[#CDE8D8] bg-[#ECF8F1] px-2 py-0.5 text-[8px] font-semibold text-[#247A49]">
                                Pagada
                              </span>
                            )}
                          </div>
                          <p className="mt-0.5 text-[10px] text-[#8792A2]">
                            {formatCurrency(invoice.importe_a_pagar ?? invoice.monto)} ·{" "}
                            {invoice.fecha_emision
                              ? `Emitida ${formatCompactDate(invoice.fecha_emision)}`
                              : "Sin fecha"}
                            {invoice.fecha_vencimiento
                              ? ` · Vence ${formatCompactDate(invoice.fecha_vencimiento)}`
                              : ""}
                          </p>
                        </div>
                      </div>

                      <div className="flex shrink-0 items-center gap-2">
                        {invoice.document_path && (
                          <Button
                            type="button"
                            variant="outline"
                            onClick={() => onOpenInvoiceDocument(invoice)}
                            className="h-8 border-[#D7DEE7] px-3 text-[10px] font-semibold text-[#173B8F]"
                          >
                            <ExternalLink className="mr-1.5 h-3.5 w-3.5" />
                            Ver PDF
                          </Button>
                        )}
                        <a
                          href="/area-cliente/facturacion"
                          className="inline-flex items-center gap-1.5 text-[10px] font-semibold text-[#173B8F] hover:text-[#102A66]"
                        >
                          Ver facturación
                          <ArrowRight className="h-3.5 w-3.5" />
                        </a>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </section>
      )}
    </div>
  );
}

export default function ProjectsList() {
  const { user, signOut, loading: authLoading } = useAuth();
  const [location, setLocation] = useLocation();

  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [projects, setProjects] = useState<Project[]>([]);
  const [progress, setProgress] = useState<ProjectProgress[]>([]);
  const [notifications, setNotifications] = useState<ClientNotification[]>([]);

  const [detailProject, setDetailProject] = useState<Project | null>(null);
  const [detailMilestones, setDetailMilestones] = useState<Milestone[]>([]);
  const [detailProgress, setDetailProgress] = useState<ProjectProgress | undefined>();
  const [detailUpdates, setDetailUpdates] = useState<ProjectUpdate[]>([]);
  const [detailDocuments, setDetailDocuments] = useState<ProjectDocument[]>([]);
  const [detailChangeRequests, setDetailChangeRequests] = useState<ProjectChangeRequest[]>([]);
  const [detailQuotations, setDetailQuotations] = useState<Quotation[]>([]);
  const [detailInvoices, setDetailInvoices] = useState<Invoice[]>([]);
  const [detailPayments, setDetailPayments] = useState<Payment[]>([]);

  const [loading, setLoading] = useState(true);
  const [detailLoading, setDetailLoading] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<"all" | ProjectStatus>("all");

  const [isChangeRequestOpen, setIsChangeRequestOpen] = useState(false);
  const [changeDescription, setChangeDescription] = useState("");
  const [submittingChangeRequest, setSubmittingChangeRequest] = useState(false);

  const [respondingQuotationId, setRespondingQuotationId] = useState<string | null>(null);

  const [isCreateProjectOpen, setIsCreateProjectOpen] = useState(false);
  const [createDescription, setCreateDescription] = useState("");
  const [createStartDate, setCreateStartDate] = useState("");
  const [createEndDate, setCreateEndDate] = useState("");
  const [creatingProject, setCreatingProject] = useState(false);

  const projectIdFromUrl = useMemo(() => {
    const match = location.match(/^\/area-cliente\/proyectos\/([^/?#]+)$/);
    return match?.[1] || null;
  }, [location]);

  const isDetailMode = Boolean(projectIdFromUrl);

  const navigate = useCallback(
    (path: string) => {
      if (path.startsWith("#")) return;
      setSidebarOpen(false);
      setLocation(path);
    },
    [setLocation],
  );

  const handleLogout = useCallback(async () => {
    await signOut();
    setLocation("/login");
  }, [setLocation, signOut]);

  const loadProjects = useCallback(
    async (silent = false) => {
      if (!user) return;

      try {
        if (silent) setRefreshing(true);
        else setLoading(true);
        setError(null);

        const { data, error: projectsError } = await supabase
          .from("projects")
          .select(
            "id,user_id,company_id,client_id,nombre,descripcion,estado,fecha_inicio,fecha_fin,change_requests_enabled,change_requests_deadline,created_at,updated_at",
          )
          .eq("user_id", user.id)
          .order("created_at", { ascending: false });

        if (projectsError) throw projectsError;

        const resolvedProjects = (data || []) as Project[];
        setProjects(resolvedProjects);

        if (resolvedProjects.length) {
          const ids = resolvedProjects.map((project) => project.id);

          const { data: progressData, error: progressError } = await supabase
            .from("project_progress")
            .select("project_id,total_milestones,completed_milestones,progress_percentage")
            .in("project_id", ids);

          if (!progressError) {
            setProgress((progressData || []) as ProjectProgress[]);
          }
        } else {
          setProgress([]);
        }
      } catch (err: any) {
        console.error("[ClientProjects] Error cargando proyectos:", err);
        setError(err?.message || "No se pudieron cargar tus proyectos.");
      } finally {
        setLoading(false);
        setRefreshing(false);
      }
    },
    [user],
  );

  const loadNotifications = useCallback(async () => {
    if (!user) return;

    const { data, error: notificationError } = await supabase
      .from("notifications")
      .select("id,project_id,tipo,titulo,mensaje,read_at,created_at")
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .limit(50);

    if (!notificationError) {
      setNotifications((data || []) as ClientNotification[]);
    }
  }, [user]);

  const loadProjectDetail = useCallback(async () => {
    if (!user || !projectIdFromUrl) return;

    setDetailLoading(true);
    setError(null);

    try {
      const [
        projectResult,
        milestonesResult,
        progressResult,
        updatesResult,
        documentsResult,
        changesResult,
        quotationsResult,
        invoicesResult,
      ] = await Promise.all([
        supabase
          .from("projects")
          .select(
            "id,user_id,company_id,client_id,nombre,descripcion,estado,fecha_inicio,fecha_fin,change_requests_enabled,change_requests_deadline,created_at,updated_at",
          )
          .eq("id", projectIdFromUrl)
          .eq("user_id", user.id)
          .maybeSingle(),

        supabase
          .from("project_milestones")
          .select(
            "id,project_id,nombre,descripcion,fecha_prevista,orden,estado,completed_at,created_at,updated_at",
          )
          .eq("project_id", projectIdFromUrl)
          .order("orden", { ascending: true }),

        supabase
          .from("project_progress")
          .select("project_id,total_milestones,completed_milestones,progress_percentage")
          .eq("project_id", projectIdFromUrl)
          .maybeSingle(),

        supabase
          .from("project_updates")
          .select("id,project_id,titulo,contenido,created_by,created_at,updated_at")
          .eq("project_id", projectIdFromUrl)
          .order("created_at", { ascending: false }),

        supabase
          .from("project_documents")
          .select(
            "id,project_id,file_name,storage_path,mime_type,file_size,uploaded_by,created_at,updated_at",
          )
          .eq("project_id", projectIdFromUrl)
          .order("created_at", { ascending: false }),

        supabase
          .from("project_change_requests")
          .select(
            "id,project_id,user_id,company_id,client_id,description,status,reviewed_at,review_notes,accepted_at,completed_at,created_at,updated_at",
          )
          .eq("project_id", projectIdFromUrl)
          .eq("user_id", user.id)
          .order("created_at", { ascending: false }),

        supabase
          .from("quotations")
          .select(
            "id,company_id,user_id,project_id,client_id,numero_presupuesto,titulo,descripcion_detallada,estado,fecha_emision,fecha_validez,precio_total,subtotal,iva_importe,irpf_importe,document_path,created_at,updated_at",
          )
          .eq("project_id", projectIdFromUrl)
          .order("created_at", { ascending: false }),

        supabase
          .from("invoices")
          .select(
            "id,project_id,company_id,user_id,numero_factura,fecha_emision,fecha_vencimiento,fecha_pago,descripcion,subtotal,iva_aplicado,iva_porcentaje,iva_importe,irpf_aplicado,irpf_porcentaje,irpf_importe,monto,importe_a_pagar,estado,document_path,created_at,updated_at",
          )
          .eq("project_id", projectIdFromUrl)
          .order("created_at", { ascending: false }),
      ]);

      if (projectResult.error) throw projectResult.error;
      if (!projectResult.data) {
        throw new Error("Proyecto no encontrado o no tienes acceso.");
      }

      const resolvedProject = projectResult.data as Project;
      const resolvedInvoices = (invoicesResult.data || []) as Invoice[];

      setDetailProject(resolvedProject);
      setDetailMilestones((milestonesResult.data || []) as Milestone[]);
      setDetailProgress((progressResult.data || undefined) as ProjectProgress | undefined);
      setDetailUpdates((updatesResult.data || []) as ProjectUpdate[]);
      setDetailDocuments((documentsResult.data || []) as ProjectDocument[]);
      setDetailChangeRequests((changesResult.data || []) as ProjectChangeRequest[]);
      setDetailQuotations((quotationsResult.data || []) as Quotation[]);
      setDetailInvoices(resolvedInvoices);

      if (resolvedInvoices.length) {
        const invoiceIds = resolvedInvoices.map((invoice) => invoice.id);
        const { data: paymentsData, error: paymentsError } = await supabase
          .from("payments")
          .select("id,invoice_id,amount,currency,status,description,paid_at,created_at")
          .in("invoice_id", invoiceIds)
          .order("created_at", { ascending: false });

        if (paymentsError) {
          console.warn("[ClientProjects] No se pudieron cargar pagos:", paymentsError);
          setDetailPayments([]);
        } else {
          setDetailPayments((paymentsData || []) as Payment[]);
        }
      } else {
        setDetailPayments([]);
      }
    } catch (err: any) {
      console.error("[ClientProjects] Error cargando detalle:", err);
      setError(err?.message || "No se pudo cargar el proyecto.");
      setDetailProject(null);
    } finally {
      setDetailLoading(false);
    }
  }, [user, projectIdFromUrl]);

  useEffect(() => {
    if (!authLoading && user) {
      void loadProjects();
      void loadNotifications();
    }
  }, [authLoading, user, loadProjects, loadNotifications]);

  useEffect(() => {
    if (projectIdFromUrl) {
      void loadProjectDetail();
    } else {
      setDetailProject(null);
    }
  }, [projectIdFromUrl, loadProjectDetail]);

  const progressByProject = useMemo(
    () => new Map(progress.map((item) => [item.project_id, item])),
    [progress],
  );

  const filteredProjects = useMemo(() => {
    const query = normalize(search);

    return projects.filter((project) => {
      const matchesSearch =
        !query ||
        normalize(project.nombre).includes(query) ||
        normalize(project.descripcion).includes(query);

      const matchesStatus =
        statusFilter === "all" || project.estado === statusFilter;

      return matchesSearch && matchesStatus;
    });
  }, [projects, search, statusFilter]);

  const createSignedUrl = async (bucket: string, path: string) => {
    const { data, error: signedUrlError } = await supabase.storage
      .from(bucket)
      .createSignedUrl(path, 60 * 10);

    if (signedUrlError) throw signedUrlError;
    if (!data?.signedUrl) throw new Error("No se pudo generar el enlace.");
    return data.signedUrl;
  };

  const openProjectDocument = async (document: ProjectDocument) => {
    try {
      const url = await createSignedUrl("project-documents", document.storage_path);
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (err: any) {
      toast.error(err?.message || "No se pudo abrir el documento.");
    }
  };

  const openQuotationDocument = async (quotation: Quotation) => {
    if (!quotation.document_path) {
      toast.info("Este presupuesto todavía no tiene un documento asociado.");
      return;
    }

    try {
      const url = await createSignedUrl("quotations", quotation.document_path);
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (err: any) {
      toast.error(err?.message || "No se pudo abrir el presupuesto.");
    }
  };

  const openInvoiceDocument = async (invoice: Invoice) => {
    if (!invoice.document_path) {
      toast.info("Esta factura todavía no tiene un documento asociado.");
      return;
    }

    try {
      const url = await createSignedUrl("invoices", invoice.document_path);
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (err: any) {
      toast.error(err?.message || "No se pudo abrir la factura.");
    }
  };

  const handleReadNotification = async (notification: ClientNotification) => {
    if (notification.read_at) return;

    try {
      const { error: markError } = await supabase.rpc("mark_notification_read", {
        p_notification_id: notification.id,
      });

      if (markError) throw markError;

      setNotifications((current) =>
        current.map((item) =>
          item.id === notification.id
            ? { ...item, read_at: new Date().toISOString() }
            : item,
        ),
      );
    } catch (err) {
      console.error("[ClientProjects] Error marcando notificación:", err);
    }
  };

  const handleMarkAllNotificationsRead = async () => {
    try {
      const { error: markError } = await supabase.rpc("mark_all_notifications_read");
      if (markError) throw markError;

      setNotifications((current) =>
        current.map((item) =>
          item.read_at
            ? item
            : { ...item, read_at: new Date().toISOString() },
        ),
      );
      toast.success("Notificaciones marcadas como leídas.");
    } catch (err: any) {
      toast.error(err?.message || "No se pudieron marcar las notificaciones.");
    }
  };

  const handleRequestChange = async () => {
    if (!user || !projectIdFromUrl) return;

    const description = changeDescription.trim();

    if (!description) {
      toast.error("Describe el cambio que necesitas solicitar.");
      return;
    }

    if (description.length > 5000) {
      toast.error("La descripción no puede superar los 5.000 caracteres.");
      return;
    }

    try {
      setSubmittingChangeRequest(true);

      const { error: requestError } = await supabase.rpc("request_project_change", {
        p_project_id: projectIdFromUrl,
        p_description: description,
      });

      if (requestError) throw requestError;

      toast.success("Solicitud de cambio enviada.");
      setChangeDescription("");
      setIsChangeRequestOpen(false);
      await loadProjectDetail();
      await loadNotifications();
    } catch (err: any) {
      toast.error(err?.message || "No se pudo enviar la solicitud.");
    } finally {
      setSubmittingChangeRequest(false);
    }
  };

  const handleQuotationResponse = async (
    quotation: Quotation,
    response: "Aceptado" | "Rechazado",
  ) => {
    try {
      setRespondingQuotationId(quotation.id);

      const { error: responseError } = await supabase.rpc("respond_to_quotation", {
        p_response: response,
        p_quotation_id: quotation.id,
      });

      if (responseError) throw responseError;

      toast.success(
        response === "Aceptado"
          ? "Presupuesto aceptado."
          : "Presupuesto rechazado.",
      );

      await loadProjectDetail();
      await loadProjects();
      await loadNotifications();
    } catch (err: any) {
      toast.error(err?.message || "No se pudo registrar la respuesta.");
    } finally {
      setRespondingQuotationId(null);
    }
  };

  const handleCreateProject = async () => {
    if (!createDescription.trim()) {
      toast.error("La descripción del proyecto es obligatoria.");
      return;
    }

    try {
      setCreatingProject(true);

      const { data, error: createError } = await supabase.rpc("create_project", {
        p_descripcion: createDescription.trim(),
        p_fecha_inicio: createStartDate || null,
        p_fecha_fin: createEndDate || null,
      });

      if (createError) throw createError;

      const created = Array.isArray(data) ? data[0] : data;
      const createdId = created?.id;

      toast.success("Proyecto creado correctamente.");
      setIsCreateProjectOpen(false);
      setCreateDescription("");
      setCreateStartDate("");
      setCreateEndDate("");

      await loadProjects();

      if (createdId) {
        setLocation(`/area-cliente/proyectos/${createdId}`);
      }
    } catch (err: any) {
      toast.error(err?.message || "No se pudo crear el proyecto.");
    } finally {
      setCreatingProject(false);
    }
  };

  if (authLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#FBFCFE]">
        <Loader2 className="h-7 w-7 animate-spin text-[#173B8F]" />
      </div>
    );
  }

  if (!user) return null;

  const unreadNotifications = notifications.filter((item) => !item.read_at);

  if (isDetailMode) {
    return (
      <div className="min-h-screen bg-[#FBFCFE] text-[#26344A]">
        <ClientAreaSidebar
          isOpen={sidebarOpen}
          onToggle={() => setSidebarOpen((value) => !value)}
          location={location}
          onNavigate={navigate}
          onLogout={handleLogout}
        />

        <main className={sidebarOpen ? "ml-[62px] lg:ml-[236px]" : "ml-[62px]"}>
          <div className="fixed right-5 top-5 z-40 flex items-center gap-2 sm:right-7">
            <div className="relative">
              <button
                type="button"
                onClick={() => {
                  if (unreadNotifications.length) {
                    void handleMarkAllNotificationsRead();
                  }
                }}
                className="relative flex h-9 w-9 items-center justify-center rounded-full border border-[#E0E6ED] bg-white text-[#667386] shadow-[0_5px_18px_rgba(24,42,69,0.05)] hover:text-[#173B8F]"
                title="Notificaciones"
              >
                <Bell className="h-[17px] w-[17px]" strokeWidth={1.8} />
                {unreadNotifications.length > 0 && (
                  <span className="absolute -right-1 -top-1 flex h-[18px] min-w-[18px] items-center justify-center rounded-full border-2 border-white bg-[#4B3E57] px-1 text-[9px] font-bold leading-none text-white">
                    {unreadNotifications.length}
                  </span>
                )}
              </button>
            </div>
            <button
              type="button"
              className="flex h-9 w-9 items-center justify-center rounded-full border border-[#E0E6ED] bg-white text-[#667386] shadow-[0_5px_18px_rgba(24,42,69,0.05)] hover:text-[#173B8F]"
              title="Calendario"
            >
              <CalendarDays className="h-[17px] w-[17px]" strokeWidth={1.8} />
            </button>
          </div>

          <div className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
            <div className="mb-7">
              <button
                type="button"
                onClick={() => setLocation("/area-cliente/proyectos")}
                className="mb-4 inline-flex items-center gap-2 text-[12px] font-medium text-[#718096] hover:text-[#173B8F]"
              >
                <ArrowLeft className="h-4 w-4" />
                Volver a mis proyectos
              </button>

              {detailLoading ? (
                <div className="flex items-center gap-2 text-sm text-[#718096]">
                  <Loader2 className="h-4 w-4 animate-spin text-[#173B8F]" />
                  Cargando proyecto...
                </div>
              ) : detailProject ? (
                <>
                  <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
                    <div>
                      <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                        Mis proyectos
                      </p>
                      <h1 className="text-[27px] font-semibold tracking-tight text-[#182A45] sm:text-3xl">
                        {detailProject.nombre}
                      </h1>
                      <p className="mt-2 max-w-4xl text-[13px] leading-6 text-[#718096]">
                        {detailProject.descripcion ||
                          "Este proyecto todavía no tiene descripción."}
                      </p>
                    </div>

                    <button
                      type="button"
                      onClick={() => setIsCreateProjectOpen(true)}
                      className="inline-flex shrink-0 items-center gap-2 rounded-md border border-[#D7DEE7] bg-white px-3 py-2 text-[11px] font-medium text-[#445166] hover:border-[#C5CED9] hover:bg-[#F8FAFC]"
                    >
                      <BriefcaseBusiness className="h-4 w-4" />
                      Nuevo proyecto
                    </button>
                  </div>
                </>
              ) : (
                <div className="rounded-lg border border-[#F0D0D0] bg-[#FFF7F7] p-4 text-[12px] text-[#B53A3A]">
                  {error || "No se ha encontrado el proyecto."}
                </div>
              )}
            </div>

            {detailProject && !detailLoading && (
              <ProjectDetailContent
                project={detailProject}
                milestones={detailMilestones}
                progress={detailProgress}
                updates={detailUpdates}
                documents={detailDocuments}
                changeRequests={detailChangeRequests}
                quotations={detailQuotations}
                invoices={detailInvoices}
                payments={detailPayments}
                onOpenChangeRequest={() => setIsChangeRequestOpen(true)}
                onOpenProjectDocument={openProjectDocument}
                onOpenQuotationDocument={openQuotationDocument}
                onOpenInvoiceDocument={openInvoiceDocument}
                onQuotationResponse={handleQuotationResponse}
                respondingQuotationId={respondingQuotationId}
              />
            )}
          </div>

          <Dialog
            open={isChangeRequestOpen}
            onOpenChange={setIsChangeRequestOpen}
          >
            <DialogContent className="sm:max-w-lg">
              <DialogHeader>
                <DialogTitle className="text-[#182A45]">
                  Solicitar un cambio
                </DialogTitle>
                <DialogDescription className="text-[12px] leading-5">
                  La solicitud quedará asociada exclusivamente a este proyecto.
                </DialogDescription>
              </DialogHeader>

              <div className="space-y-2">
                <Label
                  htmlFor="change-description"
                  className="text-[12px] font-semibold text-[#344054]"
                >
                  Describe el cambio
                </Label>
                <textarea
                  id="change-description"
                  value={changeDescription}
                  onChange={(event) => setChangeDescription(event.target.value)}
                  maxLength={5000}
                  rows={7}
                  placeholder="Explica qué necesitas cambiar..."
                  className="w-full rounded-md border border-[#D7DEE7] px-3 py-3 text-[13px] leading-6 outline-none focus:border-[#173B8F] focus:ring-2 focus:ring-[#173B8F]/10"
                />
                <p className="text-right text-[10px] text-[#98A2B3]">
                  {changeDescription.length}/5.000
                </p>
              </div>

              <DialogFooter>
                <Button
                  variant="outline"
                  onClick={() => setIsChangeRequestOpen(false)}
                  className="text-[11px]"
                >
                  Cancelar
                </Button>
                <Button
                  onClick={handleRequestChange}
                  disabled={submittingChangeRequest}
                  className="bg-[#173B8F] text-[11px] hover:bg-[#102A66]"
                >
                  {submittingChangeRequest ? (
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  ) : (
                    <Send className="mr-2 h-4 w-4" />
                  )}
                  Enviar solicitud
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>

          <CreateProjectDialog
            open={isCreateProjectOpen}
            onOpenChange={setIsCreateProjectOpen}
            description={createDescription}
            setDescription={setCreateDescription}
            startDate={createStartDate}
            setStartDate={setCreateStartDate}
            endDate={createEndDate}
            setEndDate={setCreateEndDate}
            saving={creatingProject}
            onSubmit={handleCreateProject}
          />
        </main>
      </div>
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

      <main className={sidebarOpen ? "ml-[62px] lg:ml-[236px]" : "ml-[62px]"}>
        <div className="fixed right-5 top-5 z-40 flex items-center gap-2 sm:right-7">
          <button
            type="button"
            onClick={() => {
              if (unreadNotifications.length) {
                void handleMarkAllNotificationsRead();
              }
            }}
            className="relative flex h-9 w-9 items-center justify-center rounded-full border border-[#E0E6ED] bg-white text-[#667386] shadow-[0_5px_18px_rgba(24,42,69,0.05)] hover:text-[#173B8F]"
            title="Marcar notificaciones como leídas"
          >
            <Bell className="h-[17px] w-[17px]" strokeWidth={1.8} />
            {unreadNotifications.length > 0 && (
              <span className="absolute -right-1 -top-1 flex h-[18px] min-w-[18px] items-center justify-center rounded-full border-2 border-white bg-[#4B3E57] px-1 text-[9px] font-bold leading-none text-white">
                {unreadNotifications.length}
              </span>
            )}
          </button>
          <button
            type="button"
            className="flex h-9 w-9 items-center justify-center rounded-full border border-[#E0E6ED] bg-white text-[#667386] shadow-[0_5px_18px_rgba(24,42,69,0.05)] hover:text-[#173B8F]"
            title="Calendario"
          >
            <CalendarDays className="h-[17px] w-[17px]" strokeWidth={1.8} />
          </button>
        </div>

        <div className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
          <section className="mb-8 border-b border-[#E6EAF0] pb-8">
            <div className="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                  Área de Cliente
                </p>
                <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">
                  Mis proyectos
                </h1>
                <p className="mt-1.5 max-w-2xl text-sm text-[#718096]">
                  Consulta el estado, progreso, hitos y toda la información asociada a tus proyectos.
                </p>
              </div>

              <Button
                type="button"
                onClick={() => setIsCreateProjectOpen(true)}
                className="h-9 bg-[#173B8F] px-4 text-[11px] font-semibold text-white hover:bg-[#102A66]"
              >
                <BriefcaseBusiness className="mr-1.5 h-3.5 w-3.5" />
                Nuevo proyecto
              </Button>
            </div>
          </section>

          <section className="mb-6 grid gap-3 sm:grid-cols-3">
            <div className="rounded-xl border border-[#E3E8EE] bg-white px-4 py-4 shadow-[0_8px_30px_rgba(25,40,65,0.025)]">
              <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                Proyectos
              </p>
              <p className="mt-2 text-[23px] font-semibold tracking-tight text-[#26344A]">
                {projects.length}
              </p>
            </div>
            <div className="rounded-xl border border-[#E3E8EE] bg-white px-4 py-4 shadow-[0_8px_30px_rgba(25,40,65,0.025)]">
              <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                Activos
              </p>
              <p className="mt-2 text-[23px] font-semibold tracking-tight text-[#26344A]">
                {projects.filter((project) => normalize(project.estado) === "activo").length}
              </p>
            </div>
            <div className="rounded-xl border border-[#E3E8EE] bg-white px-4 py-4 shadow-[0_8px_30px_rgba(25,40,65,0.025)]">
              <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                Completados
              </p>
              <p className="mt-2 text-[23px] font-semibold tracking-tight text-[#26344A]">
                {projects.filter((project) => normalize(project.estado) === "completado").length}
              </p>
            </div>
          </section>

          <section className="mb-7 flex flex-col gap-3 md:flex-row">
            <input
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Buscar proyecto..."
              className="h-10 flex-1 rounded-md border border-[#D7DEE7] bg-white px-3 text-[12px] text-[#344054] outline-none placeholder:text-[#A1AAB7] focus:border-[#173B8F] focus:ring-2 focus:ring-[#173B8F]/10"
            />
            <div className="relative">
              <select
                value={statusFilter}
                onChange={(event) =>
                  setStatusFilter(event.target.value as "all" | ProjectStatus)
                }
                className="h-10 min-w-[180px] appearance-none rounded-md border border-[#D7DEE7] bg-white pl-3 pr-9 text-[12px] text-[#445166] outline-none focus:border-[#173B8F]"
              >
                <option value="all">Todos los estados</option>
                <option value="Pendiente">Pendiente</option>
                <option value="Activo">Activo</option>
                <option value="Pausado">Pausado</option>
                <option value="Entregado">Entregado</option>
                <option value="Completado">Completado</option>
              </select>
              <ChevronDown className="pointer-events-none absolute right-3 top-3 h-4 w-4 text-[#8792A3]" />
            </div>
            <Button
              type="button"
              variant="outline"
              onClick={() => void loadProjects(true)}
              disabled={refreshing}
              className="h-10 border-[#D7DEE7] bg-white px-3 text-[11px] text-[#667386]"
            >
              <RefreshCw className={`mr-1.5 h-3.5 w-3.5 ${refreshing ? "animate-spin" : ""}`} />
              Actualizar
            </Button>
          </section>

          {error && !detailProject && (
            <div className="mb-5 rounded-md border border-[#F0D0D0] bg-[#FFF7F7] px-4 py-3 text-[11px] text-[#B53A3A]">
              {error}
            </div>
          )}

          {loading ? (
            <div className="flex items-center justify-center py-20 text-[#718096]">
              <Loader2 className="mr-2 h-5 w-5 animate-spin text-[#173B8F]" />
              Cargando proyectos...
            </div>
          ) : filteredProjects.length === 0 ? (
            <EmptyPanel
              icon={<BriefcaseBusiness className="h-5 w-5" />}
              title={projects.length ? "No hay proyectos que coincidan" : "Todavía no tienes proyectos"}
              description={
                projects.length
                  ? "Prueba con otro texto o cambia el filtro de estado."
                  : "Cuando se cree un proyecto para tu cuenta aparecerá en esta zona."
              }
            />
          ) : (
            <div className="space-y-4">
              {filteredProjects.map((project) => {
                const projectProgress = progressByProject.get(project.id);
                const percentage =
                  normalize(project.estado) === "completado" ||
                  normalize(project.estado) === "entregado"
                    ? 100
                    : Number(projectProgress?.progress_percentage || 0);

                return (
                  <article
                    key={project.id}
                    className="overflow-hidden border border-[#E1E7EE] bg-white transition-all hover:border-[#CDD6E1] hover:shadow-[0_10px_28px_rgba(24,42,69,0.045)]"
                  >
                    <div className="grid lg:grid-cols-[minmax(0,1fr)_220px]">
                      <div className="min-w-0 px-5 py-5 sm:px-6 sm:py-6">
                        <div className="flex flex-wrap items-center gap-2">
                          <span
                            className={`rounded-full border px-2.5 py-1 text-[9px] font-semibold ${projectStatusClasses(project.estado)}`}
                          >
                            {statusLabel(project.estado)}
                          </span>
                          {project.fecha_fin && (
                            <span className="inline-flex items-center gap-1 text-[9px] text-[#8A95A5]">
                              <CalendarDays className="h-3 w-3" />
                              Fin {formatCompactDate(project.fecha_fin)}
                            </span>
                          )}
                        </div>

                        <h2 className="mt-3 text-[17px] font-semibold tracking-tight text-[#26364D]">
                          {project.nombre}
                        </h2>

                        <p className="mt-1.5 max-w-3xl text-[11px] leading-5 text-[#718096]">
                          {project.descripcion || "Este proyecto todavía no tiene descripción."}
                        </p>

                        <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 border-t border-[#EEF1F5] pt-4">
                          <span className="text-[10px] text-[#8A95A5]">
                            Inicio{" "}
                            <strong className="font-medium text-[#667386]">
                              {formatCompactDate(project.fecha_inicio)}
                            </strong>
                          </span>
                          <span className="text-[10px] text-[#8A95A5]">
                            Actualizado{" "}
                            <strong className="font-medium text-[#667386]">
                              {formatCompactDate(project.updated_at)}
                            </strong>
                          </span>
                          <button
                            type="button"
                            onClick={() =>
                              setLocation(`/area-cliente/proyectos/${project.id}`)
                            }
                            className="ml-auto inline-flex items-center gap-1.5 text-[11px] font-semibold text-[#173B8F] hover:text-[#102A66]"
                          >
                            Consultar proyecto
                            <ArrowRight className="h-3.5 w-3.5" />
                          </button>
                        </div>
                      </div>

                      <div className="flex min-h-[180px] flex-col items-center justify-center border-t border-[#EEF1F5] bg-[#FCFDFE] px-5 py-6 lg:border-l lg:border-t-0">
                        <ProjectProgressRing
                          percentage={percentage}
                          status={project.estado}
                        />
                        <p className="mt-3 text-[9px] font-semibold uppercase tracking-[0.16em] text-[#9AA4B2]">
                          Progreso del proyecto
                        </p>
                      </div>
                    </div>
                  </article>
                );
              })}
            </div>
          )}
        </div>
      </main>

      <CreateProjectDialog
        open={isCreateProjectOpen}
        onOpenChange={setIsCreateProjectOpen}
        description={createDescription}
        setDescription={setCreateDescription}
        startDate={createStartDate}
        setStartDate={setCreateStartDate}
        endDate={createEndDate}
        setEndDate={setCreateEndDate}
        saving={creatingProject}
        onSubmit={handleCreateProject}
      />
    </div>
  );
}

function CreateProjectDialog({
  open,
  onOpenChange,
  description,
  setDescription,
  startDate,
  setStartDate,
  endDate,
  setEndDate,
  saving,
  onSubmit,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  description: string;
  setDescription: (value: string) => void;
  startDate: string;
  setStartDate: (value: string) => void;
  endDate: string;
  setEndDate: (value: string) => void;
  saving: boolean;
  onSubmit: () => void;
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle className="text-[#182A45]">Nuevo proyecto</DialogTitle>
          <DialogDescription className="text-[12px] leading-5">
            El proyecto se creará como pendiente y quedará asociado automáticamente a tu cuenta y a tu empresa actual.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-5 py-2">
          <div className="space-y-2">
            <Label className="text-[11px] font-semibold text-[#344054]">
              Descripción del proyecto
            </Label>
            <textarea
              value={description}
              onChange={(event) => setDescription(event.target.value)}
              maxLength={10000}
              rows={6}
              placeholder="Cuéntanos qué necesitas..."
              className="w-full rounded-md border border-[#D7DEE7] px-3 py-3 text-[13px] leading-6 outline-none focus:border-[#173B8F] focus:ring-2 focus:ring-[#173B8F]/10"
            />
            <p className="text-right text-[10px] text-[#98A2B3]">
              {description.length}/10.000
            </p>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label className="text-[11px] font-semibold text-[#344054]">
                Fecha de inicio
              </Label>
              <input
                type="date"
                value={startDate}
                onChange={(event) => setStartDate(event.target.value)}
                className="h-10 w-full rounded-md border border-[#D7DEE7] px-3 text-[12px] text-[#445166] outline-none focus:border-[#173B8F]"
              />
            </div>
            <div className="space-y-2">
              <Label className="text-[11px] font-semibold text-[#344054]">
                Fecha de fin
              </Label>
              <input
                type="date"
                value={endDate}
                onChange={(event) => setEndDate(event.target.value)}
                className="h-10 w-full rounded-md border border-[#D7DEE7] px-3 text-[12px] text-[#445166] outline-none focus:border-[#173B8F]"
              />
            </div>
          </div>
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={saving}
            className="text-[11px]"
          >
            Cancelar
          </Button>
          <Button
            type="button"
            onClick={onSubmit}
            disabled={saving}
            className="bg-[#173B8F] text-[11px] hover:bg-[#102A66]"
          >
            {saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            Crear proyecto
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
