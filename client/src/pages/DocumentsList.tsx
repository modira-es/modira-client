import { useCallback, useEffect, useMemo, useState, type ComponentType } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import ClientFloatingActions from "@/components/ClientFloatingActions";
import {
  AlertCircle,
  BriefcaseBusiness,
  CircleHelp,
  Download,
  ExternalLink,
  FileText,
  Home,
  Loader2,
  LogOut,
  Menu,
  Receipt,
  Search,
  UserRound,
  Wrench,
  X,
} from "lucide-react";
import { Input } from "@/components/ui/input";

type DocumentCategory = "all" | "project" | "quotation" | "invoice";

type Project = {
  id: string;
  nombre: string;
  user_id: string;
  company_id: string | null;
  estado: string;
};

type ProjectDocumentRow = {
  id: string;
  project_id: string;
  file_name: string;
  storage_path: string;
  mime_type: string;
  file_size: number;
  uploaded_by: string | null;
  created_at: string;
  updated_at: string;
};

type QuotationRow = {
  id: string;
  company_id: string | null;
  project_id: string | null;
  client_id: string | null;
  numero_presupuesto: string | null;
  titulo: string | null;
  descripcion_detallada: string | null;
  estado: string;
  fecha_emision: string | null;
  fecha_validez: string | null;
  document_path: string | null;
  quotation_version: number | null;
  created_at: string;
  updated_at: string;
};

type InvoiceRow = {
  id: string;
  company_id: string | null;
  project_id: string | null;
  quotation_id: string | null;
  numero_factura: string;
  fecha_emision: string | null;
  fecha_vencimiento: string | null;
  descripcion: string | null;
  estado: string;
  document_path: string | null;
  created_at: string;
  updated_at: string;
};

type MaintenanceInvoiceRow = {
  id: string;
  company_id: string;
  maintenance_contract_id: string | null;
  numero_factura: string | null;
  serie: string | null;
  descripcion: string | null;
  estado: string;
  fecha_emision: string | null;
  fecha_vencimiento: string | null;
  periodo_inicio: string | null;
  periodo_fin: string | null;
  document_path: string | null;
  document_mime_type: string | null;
  document_file_size: number | null;
  document_uploaded_at: string | null;
  document_uploaded_by: string | null;
  stripe_pdf_storage_path: string | null;
  pdf_storage_path: string | null;
  electronic_document_storage_path: string | null;
  created_at: string;
  updated_at: string;
};

type DocumentItem = {
  id: string;
  category: Exclude<DocumentCategory, "all">;
  fileName: string;
  storagePath: string;
  bucket: "project-documents" | "quotations" | "invoices" | "maintenance-invoices";
  mimeType: string;
  fileSize: number | null;
  reference: string;
  projectName: string | null;
  projectId: string | null;
  status: string | null;
  date: string;
  dateLabel: string;
  description: string | null;
  version: number | null;
  sourceLabel: string;
  isAuxiliary: boolean;
};

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


const normalize = (value: string | null | undefined) =>
  String(value || "").trim().toLowerCase();

const statusLabel = (value: string | null | undefined) => {
  const normalized = normalize(value);
  if (normalized === "pendiente" || normalized === "pending") return "Pendiente";
  if (normalized === "aceptado" || normalized === "accepted") return "Aceptado";
  if (normalized === "rechazado" || normalized === "rejected") return "Rechazado";
  if (normalized === "pagada" || normalized === "paid") return "Pagada";
  if (normalized === "vencida" || normalized === "overdue") return "Vencida";
  if (normalized === "cancelada" || normalized === "cancelled") return "Cancelada";
  if (normalized === "borrador" || normalized === "draft") return "Borrador";
  return value || "Sin estado";
};

const statusClasses = (value: string | null | undefined) => {
  switch (normalize(value)) {
    case "aceptado":
    case "accepted":
    case "pagada":
    case "paid":
      return "border-[#CDE8D8] bg-[#ECF8F1] text-[#247A49]";
    case "rechazado":
    case "rejected":
    case "cancelada":
    case "cancelled":
      return "border-[#F0D0D0] bg-[#FFF0F0] text-[#B53A3A]";
    case "vencida":
    case "overdue":
      return "border-[#F0DEB7] bg-[#FFF7E8] text-[#A56A00]";
    default:
      return "border-[#E0E5EA] bg-[#F4F6F8] text-[#667386]";
  }
};

const categoryLabel = (category: DocumentItem["category"]) => {
  if (category === "project") return "Proyecto";
  if (category === "quotation") return "Presupuesto";
  return "Factura";
};

const categoryClasses = (_category: Exclude<DocumentCategory, "all">) =>
  "border-[#DCE2E9] bg-[#F5F7FA] text-[#64748B]";

const getDocumentDate = (item: DocumentItem) =>
  new Date(item.date || 0).getTime();

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
    { label: "Mis proyectos", path: "/area-cliente/proyectos", icon: BriefcaseBusiness },
    { label: "Mantenimiento", path: "/area-cliente/mantenimiento", icon: Wrench },
    { label: "Presupuestos", path: "/area-cliente/presupuestos", icon: FileText },
    { label: "Facturación", path: "/area-cliente/facturacion", icon: Receipt },
    { label: "Documentos", path: "/area-cliente/documentos", icon: FileText },
    { label: "Soporte técnico", path: "/area-cliente/soporte", icon: Wrench },
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
};

const DocumentStatCard = ({
  label,
  value,
  detail,
  icon: Icon,
  active,
}: {
  label: string;
  value: number;
  detail: string;
  icon: ComponentType<{ className?: string; strokeWidth?: number }>;
  active: boolean;
}) => (
  <div
    className={[
      "min-h-[116px] px-5 py-5 sm:px-7",
      active ? "bg-[#173B8F] text-white" : "bg-white/50 text-[#1E2D43]",
    ].join(" ")}
  >
    <div className="flex h-full items-start justify-between gap-3">
      <div className="min-w-0">
        <p
          className={[
            "text-[10px] font-semibold uppercase tracking-[0.13em]",
            active ? "text-white/75" : "text-[#8A95A4]",
          ].join(" ")}
        >
          {label}
        </p>
        <p
          className={[
            "mt-2 text-2xl font-semibold tracking-tight",
            active ? "text-white" : "text-[#1E2D43]",
          ].join(" ")}
        >
          {value}
        </p>
        <p
          className={[
            "mt-0.5 truncate text-xs",
            active ? "text-white/80" : "text-[#8A95A4]",
          ].join(" ")}
        >
          {detail}
        </p>
      </div>

      <Icon
        className={[
          "mt-0.5 h-4 w-4 shrink-0",
          active ? "text-white/80" : "text-[#A1AAB7]",
        ].join(" ")}
        strokeWidth={1.7}
      />
    </div>
  </div>
);

const DocumentPreview = ({
  document,
  onOpen,
  onDownload,
}: {
  document: DocumentItem;
  onOpen: (document: DocumentItem) => void;
  onDownload: (document: DocumentItem) => void;
}) => {
  return (
    <article className="group border-b border-[#E7EBF0] py-5 last:border-b-0">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:gap-6">
        <div className="flex min-w-0 flex-1 items-start gap-4">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center border border-[#E1E6EC] bg-[#F8FAFC] text-[#718096]">
            <FileText className="h-5 w-5" strokeWidth={1.65} />
          </div>

          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <h3
                className="truncate text-[13px] font-semibold text-[#344054]"
                title={document.fileName}
              >
                {document.fileName}
              </h3>

              <span
                className={[
                  "inline-flex shrink-0 items-center rounded-full border px-2.5 py-1 text-[9px] font-semibold uppercase tracking-[0.08em]",
                  categoryClasses(document.category),
                ].join(" ")}
              >
                {categoryLabel(document.category)}
              </span>

              {document.isAuxiliary && (
                <span className="inline-flex shrink-0 items-center rounded-full border border-[#E0E5EA] bg-[#F7F8FA] px-2.5 py-1 text-[9px] font-semibold uppercase tracking-[0.08em] text-[#7A8493]">
                  Auxiliar
                </span>
              )}
            </div>

            <div className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[10px] text-[#8A95A4]">
              <span>{document.reference}</span>
              {document.projectName && (
                <>
                  <span className="text-[#D0D5DD]">·</span>
                  <span>Proyecto · {document.projectName}</span>
                </>
              )}
            </div>

            <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2">
              <span className="text-[10px] text-[#697689]">
                <strong className="font-semibold text-[#52627A]">{document.dateLabel}:</strong>{" "}
                {formatCompactDate(document.date)}
              </span>

              <span className="text-[10px] text-[#697689]">
                <strong className="font-semibold text-[#52627A]">Formato:</strong>{" "}
                {document.mimeType || "application/pdf"}
              </span>

              {document.fileSize !== null && (
                <span className="text-[10px] text-[#697689]">
                  <strong className="font-semibold text-[#52627A]">Tamaño:</strong>{" "}
                  {formatFileSize(document.fileSize)}
                </span>
              )}

              {document.version !== null && (
                <span className="text-[10px] text-[#697689]">
                  <strong className="font-semibold text-[#52627A]">Versión:</strong>{" "}
                  {document.version}
                </span>
              )}

              {document.status && (
                <span
                  className={[
                    "inline-flex items-center rounded-full border px-2 py-1 text-[9px] font-medium",
                    statusClasses(document.status),
                  ].join(" ")}
                >
                  {statusLabel(document.status)}
                </span>
              )}
            </div>

            {document.description && (
              <p className="mt-2 line-clamp-2 text-[10px] leading-4 text-[#8993A2]">
                {document.description}
              </p>
            )}

          </div>
        </div>

        <div className="flex shrink-0 items-center gap-2 lg:pl-2">
          <button
            type="button"
            onClick={() => onOpen(document)}
            aria-label={`Ver ${document.fileName}`}
            title="Ver documento"
            className="flex h-9 w-9 items-center justify-center rounded-full border border-[#DCE2E9] bg-white text-[#718096] transition-colors hover:border-[#173B8F] hover:bg-[#F5F8FD] hover:text-[#173B8F]"
          >
            <ExternalLink className="h-4 w-4" strokeWidth={1.7} />
          </button>

          <button
            type="button"
            onClick={() => onDownload(document)}
            aria-label={`Descargar ${document.fileName}`}
            title="Descargar documento"
            className="flex h-9 w-9 items-center justify-center rounded-full border border-[#DCE2E9] bg-white text-[#718096] transition-colors hover:border-[#173B8F] hover:bg-[#F5F8FD] hover:text-[#173B8F]"
          >
            <Download className="h-4 w-4" strokeWidth={1.7} />
          </button>
        </div>
      </div>
    </article>
  );
};

function formatCompactDate(value: string | null | undefined) {
  if (!value) return "—";

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) return "—";

  return new Intl.DateTimeFormat("es-ES", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(date);
}

function formatFileSize(bytes: number | null | undefined) {
  if (bytes == null || Number.isNaN(Number(bytes))) return "—";

  const size = Number(bytes);

  if (size < 1024) return `${size} B`;

  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }

  if (size < 1024 * 1024 * 1024) {
    return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  }

  return `${(size / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

export default function ClientDocuments() {
  const { user, signOut, loading: authLoading } = useAuth();
  const [location, setLocation] = useLocation();

  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [projects, setProjects] = useState<Project[]>([]);
  const [projectDocuments, setProjectDocuments] = useState<ProjectDocumentRow[]>([]);
  const [quotations, setQuotations] = useState<QuotationRow[]>([]);
  const [invoices, setInvoices] = useState<InvoiceRow[]>([]);
  const [maintenanceInvoices, setMaintenanceInvoices] = useState<MaintenanceInvoiceRow[]>([]);

  const [search, setSearch] = useState("");
  const [categoryFilter, setCategoryFilter] =
    useState<DocumentCategory>("all");

  const handleLogout = async () => {
    const result = await signOut();
    if (result.success) setLocation("/");
  };

  const navigate = (path: string) => {
    if (path.startsWith("#")) {
      if (location === "/area-cliente") {
        document.querySelector(path)?.scrollIntoView({ behavior: "smooth" });
      } else {
        setLocation(`/area-cliente${path}`);
      }
    } else {
      setLocation(path);
    }
    setSidebarOpen(false);
  };

  const loadDocuments = useCallback(async () => {
    if (!user) {
      setLoading(false);
      return;
    }

    setLoading(true);
    setError(null);

    try {
      /*
       * No se confía en filtros del frontend para la autorización.
       *
       * Las cuatro lecturas están protegidas por las RLS existentes:
       * - project_documents -> acceso del cliente a sus proyectos.
       * - quotations -> acceso del cliente mediante la relación contractual
       *   del presupuesto.
       * - invoices -> acceso del cliente según las políticas de facturación.
       * - maintenance_invoices -> acceso por la empresa actual.
       *
       * El frontend solo normaliza y presenta los registros que Supabase
       * devuelve después de aplicar dichas políticas.
       */
      const [
        projectsResult,
        projectDocumentsResult,
        quotationsResult,
        invoicesResult,
        maintenanceInvoicesResult,
      ] = await Promise.all([
        supabase
          .from("projects")
          .select("id,nombre,user_id,company_id,estado")
          .eq("user_id", user.id)
          .order("created_at", { ascending: false }),

        supabase
          .from("project_documents")
          .select(
            "id,project_id,file_name,storage_path,mime_type,file_size,uploaded_by,created_at,updated_at",
          )
          .order("created_at", { ascending: false }),

        supabase
          .from("quotations")
          .select(
            "id,company_id,project_id,client_id,numero_presupuesto,titulo,descripcion_detallada,estado,fecha_emision,fecha_validez,document_path,quotation_version,created_at,updated_at",
          )
          .order("created_at", { ascending: false }),

        supabase
          .from("invoices")
          .select(
            "id,company_id,project_id,quotation_id,numero_factura,fecha_emision,fecha_vencimiento,descripcion,estado,document_path,created_at,updated_at",
          )
          .order("created_at", { ascending: false }),

        supabase
          .from("maintenance_invoices")
          .select(
            "id,company_id,maintenance_contract_id,numero_factura,serie,descripcion,estado,fecha_emision,fecha_vencimiento,periodo_inicio,periodo_fin,document_path,document_mime_type,document_file_size,document_uploaded_at,document_uploaded_by,stripe_pdf_storage_path,pdf_storage_path,electronic_document_storage_path,created_at,updated_at",
          )
          .order("created_at", { ascending: false }),
      ]);

      if (projectsResult.error) {
        throw projectsResult.error;
      }

      setProjects((projectsResult.data || []) as Project[]);

      if (projectDocumentsResult.error) {
        console.warn(
          "[ClientDocuments] Error cargando documentos de proyectos:",
          projectDocumentsResult.error,
        );
        setProjectDocuments([]);
      } else {
        setProjectDocuments(
          (projectDocumentsResult.data || []) as ProjectDocumentRow[],
        );
      }

      if (quotationsResult.error) {
        console.warn(
          "[ClientDocuments] Error cargando presupuestos:",
          quotationsResult.error,
        );
        setQuotations([]);
      } else {
        setQuotations((quotationsResult.data || []) as QuotationRow[]);
      }

      if (invoicesResult.error) {
        console.warn(
          "[ClientDocuments] Error cargando facturas:",
          invoicesResult.error,
        );
        setInvoices([]);
      } else {
        setInvoices((invoicesResult.data || []) as InvoiceRow[]);
      }

      if (maintenanceInvoicesResult.error) {
        console.warn(
          "[ClientDocuments] Error cargando facturas de mantenimiento:",
          maintenanceInvoicesResult.error,
        );
        setMaintenanceInvoices([]);
      } else {
        setMaintenanceInvoices(
          (maintenanceInvoicesResult.data || []) as MaintenanceInvoiceRow[],
        );
      }
    } catch (err: any) {
      console.error("[ClientDocuments] Error cargando documentos:", err);
      setError(err?.message || "No se pudieron cargar tus documentos.");
    } finally {
      setLoading(false);
    }
  }, [user]);

  useEffect(() => {
    if (!authLoading) {
      loadDocuments();
    }
  }, [authLoading, loadDocuments]);

  const projectById = useMemo(() => {
    const map = new Map<string, Project>();
    projects.forEach((project) => map.set(project.id, project));
    return map;
  }, [projects]);

  const documents = useMemo<DocumentItem[]>(() => {
    const result: DocumentItem[] = [];

    for (const document of projectDocuments) {
      const project = projectById.get(document.project_id);

      result.push({
        id: `project-${document.id}`,
        category: "project",
        fileName: document.file_name || "Documento de proyecto.pdf",
        storagePath: document.storage_path,
        bucket: "project-documents",
        mimeType: document.mime_type || "application/pdf",
        fileSize: Number.isFinite(Number(document.file_size))
          ? Number(document.file_size)
          : null,
        reference: `Documento de proyecto`,
        projectName: project?.nombre || "Proyecto",
        projectId: document.project_id,
        status: project?.estado || null,
        date: document.created_at || document.updated_at,
        dateLabel: "Subido",
        description: null,
        version: null,
        sourceLabel: "Documento de proyecto",
        isAuxiliary: false,
      });
    }

    for (const quotation of quotations) {
      if (!quotation.document_path) continue;

      const project = quotation.project_id
        ? projectById.get(quotation.project_id)
        : undefined;

      result.push({
        id: `quotation-${quotation.id}`,
        category: "quotation",
        fileName: `${quotation.numero_presupuesto || quotation.titulo || "Presupuesto"}.pdf`,
        storagePath: quotation.document_path,
        bucket: "quotations",
        mimeType: "application/pdf",
        fileSize: null,
        reference: `Presupuesto · ${quotation.numero_presupuesto || "Sin número"}`,
        projectName: project?.nombre || null,
        projectId: quotation.project_id,
        status: quotation.estado,
        date: quotation.fecha_emision || quotation.updated_at || quotation.created_at,
        dateLabel: quotation.fecha_emision ? "Fecha emisión" : "Actualizado",
        description: quotation.titulo || quotation.descripcion_detallada,
        version: quotation.quotation_version,
        sourceLabel: "Presupuesto",
        isAuxiliary: false,
      });
    }

    for (const invoice of invoices) {
      if (!invoice.document_path) continue;

      const project = invoice.project_id
        ? projectById.get(invoice.project_id)
        : undefined;

      result.push({
        id: `invoice-${invoice.id}`,
        category: "invoice",
        fileName: `${invoice.numero_factura}.pdf`,
        storagePath: invoice.document_path,
        bucket: "invoices",
        mimeType: "application/pdf",
        fileSize: null,
        reference: `Factura · ${invoice.numero_factura}`,
        projectName: project?.nombre || null,
        projectId: invoice.project_id,
        status: invoice.estado,
        date: invoice.fecha_emision || invoice.updated_at || invoice.created_at,
        dateLabel: invoice.fecha_emision ? "Fecha emisión" : "Actualizado",
        description: invoice.descripcion,
        version: null,
        sourceLabel: "Factura",
        isAuxiliary: false,
      });
    }

    for (const invoice of maintenanceInvoices) {
      const referenceNumber =
        [invoice.serie, invoice.numero_factura].filter(Boolean).join("-") ||
        invoice.numero_factura ||
        "Factura de mantenimiento";

      const maintenancePaths = [
        {
          path: invoice.document_path,
          label: "Factura de mantenimiento",
          auxiliary: false,
        },
        {
          path: invoice.electronic_document_storage_path,
          label: "Documento electrónico",
          auxiliary: true,
        },
        {
          path: invoice.stripe_pdf_storage_path,
          label: "PDF Stripe",
          auxiliary: true,
        },
        {
          path: invoice.pdf_storage_path,
          label: "PDF auxiliar",
          auxiliary: true,
        },
      ].filter(
        (
          item,
        ): item is {
          path: string;
          label: string;
          auxiliary: boolean;
        } => Boolean(item.path),
      );

      const uniquePaths = new Set<string>();

      for (const item of maintenancePaths) {
        if (uniquePaths.has(item.path)) continue;
        uniquePaths.add(item.path);

        result.push({
          id: `maintenance-invoice-${invoice.id}-${item.path}`,
          category: "invoice",
          fileName: `${referenceNumber}${item.auxiliary ? ` · ${item.label}` : ""}.pdf`,
          storagePath: item.path,
          bucket: "maintenance-invoices",
          mimeType: invoice.document_mime_type || "application/pdf",
          fileSize: invoice.document_file_size ?? null,
          reference: `Factura mantenimiento · ${referenceNumber}`,
          projectName: null,
          projectId: null,
          status: invoice.estado,
          date:
            invoice.document_uploaded_at ||
            invoice.fecha_emision ||
            invoice.updated_at ||
            invoice.created_at,
          dateLabel: invoice.document_uploaded_at
            ? "Subido"
            : invoice.fecha_emision
              ? "Fecha emisión"
              : "Actualizado",
          description: invoice.descripcion,
          version: null,
            sourceLabel: item.label,
          isAuxiliary: item.auxiliary,
        });
      }
    }

    return result.sort((a, b) => getDocumentDate(b) - getDocumentDate(a));
  }, [projectDocuments, quotations, invoices, maintenanceInvoices, projectById]);

  const counts = useMemo(
    () => ({
      all: documents.length,
      project: documents.filter((document) => document.category === "project").length,
      quotation: documents.filter((document) => document.category === "quotation").length,
      invoice: documents.filter((document) => document.category === "invoice").length,
    }),
    [documents],
  );

  const filteredDocuments = useMemo(() => {
    const query = normalize(search);

    return documents.filter((document) => {
      const matchesCategory =
        categoryFilter === "all" || document.category === categoryFilter;

      const searchable = [
        document.fileName,
        document.reference,
        document.projectName,
        document.description,
        document.sourceLabel,
      ]
        .filter(Boolean)
        .join(" ");

      return matchesCategory && (!query || normalize(searchable).includes(query));
    });
  }, [documents, categoryFilter, search]);

  const handleOpenDocument = useCallback(async (document: DocumentItem) => {
    try {
      const { data, error: signedUrlError } = await supabase.storage
        .from(document.bucket)
        .createSignedUrl(document.storagePath, 120);

      if (signedUrlError || !data?.signedUrl) {
        throw signedUrlError || new Error("No se ha podido generar el enlace.");
      }

      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    } catch (err) {
      console.error("[ClientDocuments] Error abriendo documento:", err);
      toast.error("No se ha podido abrir el documento.");
    }
  }, []);

  const handleDownloadDocument = useCallback(async (document: DocumentItem) => {
    try {
      const { data, error: signedUrlError } = await supabase.storage
        .from(document.bucket)
        .createSignedUrl(document.storagePath, 120, { download: true });

      if (signedUrlError || !data?.signedUrl) {
        throw signedUrlError || new Error("No se ha podido generar el enlace de descarga.");
      }

      const anchor = window.document.createElement("a");
      anchor.href = data.signedUrl;
      anchor.target = "_blank";
      anchor.rel = "noopener noreferrer";
      anchor.click();
    } catch (err) {
      console.error("[ClientDocuments] Error descargando documento:", err);
      toast.error("No se ha podido descargar el documento.");
    }
  }, []);

  if (authLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-[#FBFCFE]">
        <Loader2 className="h-7 w-7 animate-spin text-[#173B8F]" />
      </div>
    );
  }

  if (!user) return null;

  const categoryFilters: Array<{
    id: DocumentCategory;
    label: string;
  }> = [
    { id: "all", label: "Todos" },
    { id: "project", label: "Proyectos" },
    { id: "quotation", label: "Presupuestos" },
    { id: "invoice", label: "Facturas" },
  ];

  return (
    <div className="min-h-screen bg-[#FBFCFE] text-[#26344A]">
      <ClientAreaSidebar
        isOpen={sidebarOpen}
        onToggle={() => setSidebarOpen((value) => !value)}
        location={location}
        onNavigate={navigate}
        onLogout={handleLogout}
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
            <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                  Área de Cliente
                </p>
                <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">
                  Mis documentos
                </h1>
                <p className="mt-1.5 max-w-2xl text-sm text-[#718096]">
                  Consulta, visualiza y descarga todos los documentos disponibles asociados a tu cuenta.
                </p>
              </div>
            </div>
          </section>

          <section className="mb-10 grid grid-cols-2 divide-x divide-y divide-[#E5E9EF] border-y border-[#E5E9EF] bg-white/40 lg:grid-cols-4 lg:divide-y-0">
            <DocumentStatCard
              label="Total de documentos"
              value={counts.all}
              detail={counts.all === 1 ? "Documento disponible" : "Documentos disponibles"}
              icon={FileText}
              active={counts.all > 0}
            />
            <DocumentStatCard
              label="Proyectos"
              value={counts.project}
              detail={counts.project === 1 ? "Documento de proyecto" : "Documentos de proyectos"}
              icon={BriefcaseBusiness}
              active={counts.project > 0}
            />
            <DocumentStatCard
              label="Presupuestos"
              value={counts.quotation}
              detail={counts.quotation === 1 ? "Documento de presupuesto" : "Documentos de presupuestos"}
              icon={FileText}
              active={counts.quotation > 0}
            />
            <DocumentStatCard
              label="Facturas"
              value={counts.invoice}
              detail={counts.invoice === 1 ? "Documento de factura" : "Documentos de facturas"}
              icon={Receipt}
              active={counts.invoice > 0}
            />
          </section>

          <section>
            <div className="mb-5 flex items-end justify-between gap-4">
              <div className="min-w-0">
                <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                  Archivo documental
                </p>
                <h2 className="text-xl font-semibold tracking-tight text-[#182A45] sm:text-2xl">
                  Todos tus documentos
                </h2>
              </div>

              <span className="shrink-0 text-[11px] text-[#8A95A5]">
                {filteredDocuments.length} de {documents.length}
              </span>
            </div>

            <div className="mb-8 border border-[#E3E8EE] bg-white p-4 sm:p-5">
              <div className="flex h-11 items-center gap-3 rounded-lg border border-[#E3E8EE] bg-[#F8FAFC] px-3.5 transition-all focus-within:border-[#173B8F] focus-within:ring-1 focus-within:ring-[#173B8F]">
                <Search
                  className="h-4 w-4 shrink-0 text-[#8F9AAA]"
                  strokeWidth={1.7}
                />

                <Input
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                  placeholder="Buscar documento por nombre, referencia o proyecto..."
                  className="h-full min-w-0 !border-0 !bg-transparent !p-0 text-[13px] text-[#344054] !shadow-none !outline-none placeholder:text-[#9AA4B2] focus:!border-0 focus:!outline-none focus:!ring-0 focus-visible:!border-0 focus-visible:!outline-none focus-visible:!ring-0 focus-visible:ring-offset-0"
                />
              </div>

              <div className="mt-5 flex flex-wrap items-center gap-x-3 gap-y-2.5">
                <span className="mr-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                  Tipo
                </span>

                {categoryFilters.map((filter) => {
                  const active = categoryFilter === filter.id;

                  return (
                    <button
                      key={filter.id}
                      type="button"
                      onClick={() => setCategoryFilter(filter.id)}
                      className={[
                        "rounded-full border px-[18px] py-2 text-[12px] font-medium transition-all",
                        active
                          ? "border-[#173B8F] bg-[#173B8F] text-white"
                          : "border-[#DCE2E9] bg-white text-[#667386] hover:border-[#C6CFDA] hover:bg-[#F7F9FB] hover:text-[#173B8F]",
                      ].join(" ")}
                    >
                      {filter.label}
                    </button>
                  );
                })}
              </div>
            </div>

            {loading ? (
              <div className="border-y border-[#E7EBF0] py-14 text-center">
                <Loader2 className="mx-auto mb-3 h-7 w-7 animate-spin text-[#173B8F]" />
                <p className="text-[12px] text-[#718096]">
                  Cargando documentos...
                </p>
              </div>
            ) : error ? (
              <div className="border-y border-[#E7EBF0] py-8">
                <div className="flex items-start gap-3">
                  <AlertCircle
                    className="mt-0.5 h-5 w-5 shrink-0 text-[#B53A3A]"
                    strokeWidth={1.7}
                  />
                  <div>
                    <p className="text-[13px] font-semibold text-[#26344A]">
                      No se pudieron cargar los documentos
                    </p>
                    <p className="mt-1 text-[12px] leading-5 text-[#718096]">
                      {error}
                    </p>
                  </div>
                </div>
              </div>
            ) : filteredDocuments.length === 0 ? (
              <div className="border-y border-[#E7EBF0] py-14 text-center">
                <FileText
                  className="mx-auto mb-4 h-7 w-7 text-[#AAB3BF]"
                  strokeWidth={1.6}
                />
                <p className="text-[14px] font-semibold text-[#344054]">
                  {documents.length
                    ? "No hay documentos que coincidan"
                    : "Todavía no tienes documentos disponibles"}
                </p>
                <p className="mx-auto mt-2 max-w-md text-[12px] leading-5 text-[#8792A2]">
                  {documents.length
                    ? "Prueba con otro nombre, referencia, proyecto o tipo de documento."
                    : "Cuando Modira ponga un documento a tu disposición, aparecerá aquí."}
                </p>
              </div>
            ) : (
              <div className="border-y border-[#E7EBF0]">
                {filteredDocuments.map((document) => (
                  <DocumentPreview
                    key={document.id}
                    document={document}
                    onOpen={handleOpenDocument}
                    onDownload={handleDownloadDocument}
                  />
                ))}
              </div>
            )}
          </section>
        </div>
      </main>
    </div>
  );
}
