import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import ClientFloatingActions from "@/components/ClientFloatingActions";
import {
  AlertCircle,
  ArrowLeft,
  ArrowRight,
  BriefcaseBusiness,
  CalendarDays,
  Check,
  CircleHelp,
  Clock3,
  Download,
  ExternalLink,
  FileText,
  Home,
  Loader2,
  LogOut,
  Menu,
  MessageSquare,
  Receipt,
  Search,
  UserRound,
  Wrench,
  X,
} from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

type ProjectStatus = "Pendiente" | "Activo" | "Pausado" | "Entregado" | "Completado";
type MilestoneStatus = "pendiente" | "en_curso" | "completado";
type ChangeRequestStatus = "pending" | "in_review" | "accepted" | "rejected" | "completed";

interface Project {
  id: string;
  user_id: string;
  company_id: string | null;
  client_id: string | null;
  nombre: string;
  descripcion: string | null;
  estado: ProjectStatus;
  fecha_inicio: string | null;
  fecha_fin: string | null;
  change_requests_enabled: boolean;
  change_requests_deadline: string | null;
  created_at: string;
  updated_at: string;
}
interface Company {
  id: string;
  company_name: string;
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
  status: ChangeRequestStatus;
  reviewed_at: string | null;
  review_notes: string | null;
  accepted_at: string | null;
  completed_at: string | null;
  created_at: string;
  updated_at: string;
}

interface Quotation {
  id: string;
  project_id: string | null;
  numero_presupuesto: string;
  titulo: string | null;
  descripcion_detallada: string | null;
  servicios_incluidos: unknown;
  precio_base: number | null;
  iva_porcentaje: number | null;
  precio_total: number | null;
  irpf_aplicado: boolean | null;
  irpf_porcentaje: number | null;
  irpf_importe: number | null;
  estado: string;
  fecha_emision: string | null;
  fecha_validez: string | null;
  notas: string | null;
  document_path: string | null;
  quotation_version?: number | null;
  created_at: string;
  updated_at: string;
}

interface Invoice {
  id: string;
  project_id: string | null;
  quotation_id: string | null;
  numero_factura: string;
  fecha_emision: string | null;
  fecha_vencimiento: string | null;
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
  updated_at: string;
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
  metadata: Record<string, unknown> | null;
  read_at: string | null;
  created_at: string;
}

const PROJECT_STATUSES: Array<"all" | ProjectStatus> = [
  "all",
  "Pendiente",
  "Activo",
  "Pausado",
  "Entregado",
  "Completado",
];

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
type QuotationService = {
  descripcion?: string;
  cantidad?: number | string;
  precio?: number | string;
};

const getQuotationServices = (
  services: unknown,
): QuotationService[] => {
  if (!Array.isArray(services)) return [];

  return services.filter(
    (item): item is QuotationService =>
      Boolean(item && typeof item === "object"),
  );
};
const getServiceCount = (services: unknown): number | null => {
  if (Array.isArray(services)) {
    return services.length;
  }

  if (typeof services === "string") {
    try {
      const parsed = JSON.parse(services);
      if (Array.isArray(parsed)) return parsed.length;

      if (parsed && typeof parsed === "object") {
        const value =
          (parsed as Record<string, unknown>).servicios ??
          (parsed as Record<string, unknown>).services ??
          (parsed as Record<string, unknown>).items;

        if (Array.isArray(value)) return value.length;
      }
    } catch {
      return null;
    }
  }

  if (services && typeof services === "object") {
    const value =
      (services as Record<string, unknown>).servicios ??
      (services as Record<string, unknown>).services ??
      (services as Record<string, unknown>).items;

    if (Array.isArray(value)) return value.length;
  }

  return null;
};

const getInvoiceServiceQuantity = (description: string | null) => {
  if (!description) return null;

  const match = description.match(/cantidad\s*[:\-]?\s*(\d+)/i);
  return match ? Number(match[1]) : null;
};
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

const statusLabel = (status: string) => {
  const value = normalize(status);
  if (value === "pendiente" || value === "pending") return "Pendiente";
  if (value === "activo") return "Activo";
  if (value === "pausado") return "Pausado";
  if (value === "entregado") return "Entregado";
  if (value === "completado") return "Completado";
  if (value === "in_review") return "En revisión";
  if (value === "accepted" || value === "aceptado") return "Aceptada";
  if (value === "rejected" || value === "rechazado") return "Rechazada";
  if (value === "completed") return "Completada";
  return status;
};

const projectStatusClasses = (status: string) => {
  switch (normalize(status)) {
    case "activo":
      return "bg-[#EEF3FF] text-[#173B8F] border-[#D8E1F5]";
    case "pausado":
      return "bg-[#FFF7E8] text-[#A56A00] border-[#F0DEB7]";
    case "entregado":
      return "bg-[#F3F1F8] text-[#4B3E57] border-[#DDD8E7]";
    case "completado":
      return "bg-[#ECF8F1] text-[#247A49] border-[#CDE8D8]";
    default:
      return "bg-[#F4F6F8] text-[#667386] border-[#E0E5EA]";
  }
};

const changeRequestClasses = (status: string) => {
  switch (normalize(status)) {
    case "accepted":
      return "bg-[#ECF8F1] text-[#247A49] border-[#CDE8D8]";
    case "completed":
      return "bg-[#EEF3FF] text-[#173B8F] border-[#D8E1F5]";
    case "rejected":
      return "bg-[#FFF0F0] text-[#B53A3A] border-[#F0D0D0]";
    case "in_review":
      return "bg-[#FFF7E8] text-[#A56A00] border-[#F0DEB7]";
    default:
      return "bg-[#F4F6F8] text-[#667386] border-[#E0E5EA]";
  }
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

function useQueryParams() {
  const [params, setParams] = useState(() =>
    typeof window === "undefined"
      ? new URLSearchParams()
      : new URLSearchParams(window.location.search),
  );

  useEffect(() => {
    const sync = () =>
      setParams(new URLSearchParams(window.location.search));
    window.addEventListener("popstate", sync);
    return () => window.removeEventListener("popstate", sync);
  }, []);

  return params;
}

export default function ClientProjects() {
  const { user, signOut, loading: authLoading } = useAuth();
  const [location, setLocation] = useLocation();
  // El detalle y la creación se gestionan dentro de /area-cliente/proyectos.
  // El hash mantiene la misma ruta y permite utilizar el botón Atrás del navegador.
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
  const [createMode, setCreateMode] = useState(false);
  const projectIdFromUrl = selectedProjectId;
  const createFromUrl = createMode;
  const isDetailMode = Boolean(selectedProjectId) || createMode;

  useEffect(() => {
    const syncProjectView = () => {
      const hash = window.location.hash;

      if (hash.startsWith("#project=")) {
        setSelectedProjectId(decodeURIComponent(hash.slice("#project=".length)));
        setCreateMode(false);
      } else if (hash === "#new") {
        setSelectedProjectId(null);
        setCreateMode(true);
      } else {
        setSelectedProjectId(null);
        setCreateMode(false);
      }
    };

    syncProjectView();
    window.addEventListener("popstate", syncProjectView);
    window.addEventListener("hashchange", syncProjectView);

    return () => {
      window.removeEventListener("popstate", syncProjectView);
      window.removeEventListener("hashchange", syncProjectView);
    };
  }, []);

  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [detailLoading, setDetailLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [projects, setProjects] = useState<Project[]>([]);
  const [companies, setCompanies] = useState<Company[]>([]);
  const [progress, setProgress] = useState<ProjectProgress[]>([]);
  const [projectDocumentCounts, setProjectDocumentCounts] = useState<Record<string, number>>({});
  const [projectChangeRequests, setProjectChangeRequests] = useState<ProjectChangeRequest[]>([]);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<"all" | ProjectStatus>("all");

  const [detailProject, setDetailProject] = useState<Project | null>(null);
  const [milestones, setMilestones] = useState<Milestone[]>([]);
  const [updates, setUpdates] = useState<ProjectUpdate[]>([]);
  const [documents, setDocuments] = useState<ProjectDocument[]>([]);
  const [changeRequests, setChangeRequests] = useState<ProjectChangeRequest[]>([]);
  const [quotations, setQuotations] = useState<Quotation[]>([]);
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);

  const [isChangeRequestOpen, setIsChangeRequestOpen] = useState(false);
  const [changeDescription, setChangeDescription] = useState("");
  const [submittingChangeRequest, setSubmittingChangeRequest] = useState(false);

  const [createDescription, setCreateDescription] = useState("");
  const [createStartDate, setCreateStartDate] = useState("");
  const [createEndDate, setCreateEndDate] = useState("");
  const [creatingProject, setCreatingProject] = useState(false);

  const [respondingQuotationId, setRespondingQuotationId] = useState<string | null>(null);

  const openProject = useCallback((projectId: string) => {
    const nextUrl = `${window.location.pathname}#project=${encodeURIComponent(projectId)}`;

    window.history.pushState(
      { modiraProjectView: true, view: "project", projectId },
      "",
      nextUrl,
    );

    setSelectedProjectId(projectId);
    setCreateMode(false);
    setDetailProject(null);
    setError(null);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

  const openCreateProject = useCallback(() => {
    window.history.pushState(
      { modiraProjectView: true, view: "create" },
      "",
      `${window.location.pathname}#new`,
    );

    setSelectedProjectId(null);
    setCreateMode(true);
    setDetailProject(null);
    setError(null);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

  const closeProjectView = useCallback(() => {
    /*
     * El botón "Volver a mis proyectos" debe llevar siempre al listado.
     * No dependemos de history.back(), porque el usuario puede haber llegado
     * directamente a un hash de detalle/creación o haber abierto "Nuevo
     * proyecto" desde otro proyecto.
     *
     * El botón Atrás del navegador sigue funcionando porque las aperturas
     * de detalle/creación se hacen con pushState.
     */
    window.history.replaceState(
      { modiraProjectView: false, view: "list" },
      "",
      window.location.pathname,
    );

    setSelectedProjectId(null);
    setCreateMode(false);
    setDetailProject(null);
    setError(null);
    setChangeDescription("");
    setIsChangeRequestOpen(false);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

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

  const loadProjects = useCallback(async () => {
    if (!user || isDetailMode) return;

    setLoading(true);
    setError(null);

    try {
      const [projectsResult, progressResult] = await Promise.all([
        supabase
          .from("projects")
          .select(
            [
              "id",
              "user_id",
              "company_id",
              "client_id",
              "nombre",
              "descripcion",
              "estado",
              "fecha_inicio",
              "fecha_fin",
              "change_requests_enabled",
              "change_requests_deadline",
              "created_at",
              "updated_at",
            ].join(","),
          )
          .order("created_at", { ascending: false }),
        supabase
          .from("project_progress")
          .select("project_id,total_milestones,completed_milestones,progress_percentage"),
      ]);

      if (projectsResult.error) throw projectsResult.error;

      const resolvedProjects = (projectsResult.data || []) as unknown as Project[];
      setProjects(resolvedProjects);
const companyIds = Array.from(
  new Set(
    resolvedProjects
      .map((project) => project.company_id)
      .filter((companyId): companyId is string => Boolean(companyId)),
  ),
);

if (companyIds.length) {
  const { data: companyRows, error: companyError } = await supabase
    .from("companies")
    .select("id,company_name")
    .in("id", companyIds);

  if (companyError) {
    console.warn(
      "[ClientProjects] No se pudieron cargar las empresas de los proyectos:",
      companyError,
    );
    setCompanies([]);
  } else {
    setCompanies((companyRows || []) as Company[]);
  }
} else {
  setCompanies([]);
}

      const loadedProgress = progressResult.error
        ? []
        : ((progressResult.data || []) as ProjectProgress[]);

      if (loadedProgress.length || !resolvedProjects.length) {
        setProgress(loadedProgress);
      } else {
        const { data: milestoneRows } = await supabase
          .from("project_milestones")
          .select("project_id,estado")
          .in("project_id", resolvedProjects.map((project) => project.id));

        const fallbackMap = new Map<string, { total: number; completed: number }>();

        for (const row of (milestoneRows || []) as Array<{
          project_id: string;
          estado: MilestoneStatus;
        }>) {
          const current = fallbackMap.get(row.project_id) || { total: 0, completed: 0 };
          current.total += 1;
          if (row.estado === "completado") current.completed += 1;
          fallbackMap.set(row.project_id, current);
        }

        setProgress(
          resolvedProjects.map((project) => {
            const item = fallbackMap.get(project.id) || { total: 0, completed: 0 };
            return {
              project_id: project.id,
              total_milestones: item.total,
              completed_milestones: item.completed,
              progress_percentage: item.total
                ? Math.round((item.completed / item.total) * 100)
                : 0,
            };
          }),
        );
      }

      if (resolvedProjects.length) {
        const projectIds = resolvedProjects.map((project) => project.id);

        const [requestsResult, documentsResult] = await Promise.all([
          supabase
            .from("project_change_requests")
            .select(
              "id,project_id,user_id,company_id,client_id,description,status,reviewed_at,review_notes,accepted_at,completed_at,created_at,updated_at",
            )
            .in("project_id", projectIds)
            .order("created_at", { ascending: false }),

          supabase
            .from("project_documents")
            .select("project_id")
            .in("project_id", projectIds),
        ]);

        const { data: requestsData, error: requestsError } = requestsResult;

        if (!documentsResult.error) {
          const counts: Record<string, number> = {};

          for (const row of documentsResult.data || []) {
            const projectId = row.project_id as string;

            if (projectId) {
              counts[projectId] = (counts[projectId] || 0) + 1;
            }
          }

          setProjectDocumentCounts(counts);
        } else {
          console.warn(
            "[ClientProjects] No se pudieron cargar los documentos de los proyectos:",
            documentsResult.error,
          );
          setProjectDocumentCounts({});
        }

        if (requestsError) {
          console.warn(
            "[ClientProjects] No se pudieron cargar las solicitudes de cambio:",
            requestsError,
          );
          setProjectChangeRequests([]);
        } else {
          setProjectChangeRequests(
            (requestsData || []) as ProjectChangeRequest[],
          );
        }
      } else {
        setProjectChangeRequests([]);
        setProjectDocumentCounts({});
      }
    } catch (err: any) {
      console.error("[ClientProjects] Error cargando proyectos:", err);
      setError(err?.message || "No se pudieron cargar tus proyectos.");
    } finally {
      setLoading(false);
    }
  }, [user, isDetailMode]);

 

  const loadProjectDetail = useCallback(async () => {
    if (!user || !projectIdFromUrl) return;

    setDetailLoading(true);
    setError(null);

    try {
      const projectResult = await supabase
        .from("projects")
        .select(
          [
            "id",
            "user_id",
            "company_id",
            "client_id",
            "nombre",
            "descripcion",
            "estado",
            "fecha_inicio",
            "fecha_fin",
            "change_requests_enabled",
            "change_requests_deadline",
            "created_at",
            "updated_at",
            " project_documents:project_documents(count)",
          ].join(","),
        )
                .eq("id", projectIdFromUrl)
        .maybeSingle()
        

      if (projectResult.error) throw projectResult.error;
      if (!projectResult.data) {
        throw new Error("Proyecto no encontrado o no tienes acceso.");
      }

      const project = projectResult.data as unknown as Project;
      if (project.company_id) {
  const { data: companyRow, error: companyError } = await supabase
    .from("companies")
    .select("id,company_name")
    .eq("id", project.company_id)
    .maybeSingle();

  if (companyError) {
    console.warn(
      "[ClientProjects] No se pudo cargar la empresa del proyecto:",
      companyError,
    );
  } else if (companyRow) {
    setCompanies((current) => {
      const exists = current.some((company) => company.id === companyRow.id);

      return exists
        ? current.map((company) =>
            company.id === companyRow.id
              ? (companyRow as Company)
              : company,
          )
        : [...current, companyRow as Company];
    });
  }
}

      const [
        milestonesResult,
        progressResult,
        updatesResult,
        documentsResult,
        changesResult,
        quotationsResult,
        invoicesResult,
      ] = await Promise.all([
        supabase
          .from("project_milestones")
          .select(
            "id,project_id,nombre,descripcion,fecha_prevista,orden,estado,completed_at,created_at,updated_at",
          )
          .eq("project_id", project.id)
          .order("orden", { ascending: true }),

        supabase
          .from("project_progress")
          .select(
            "project_id,total_milestones,completed_milestones,progress_percentage",
          )
          .eq("project_id", project.id)
          .maybeSingle(),

        supabase
          .from("project_updates")
          .select(
            "id,project_id,titulo,contenido,created_by,created_at,updated_at",
          )
          .eq("project_id", project.id)
          .order("created_at", { ascending: false }),

        supabase
          .from("project_documents")
          .select(
            "id,project_id,file_name,storage_path,mime_type,file_size,uploaded_by,created_at,updated_at",
          )
          .eq("project_id", project.id)
          .order("created_at", { ascending: false }),

        supabase
          .from("project_change_requests")
          .select(
            "id,project_id,user_id,company_id,client_id,description,status,reviewed_at,review_notes,accepted_at,completed_at,created_at,updated_at",
          )
          .eq("project_id", project.id)
          .order("created_at", { ascending: false }),

        supabase
          .from("quotations")
          .select(
            [
              "id",
              "project_id",
              "numero_presupuesto",
              "titulo",
              "descripcion_detallada",
              "servicios_incluidos",
              "precio_base",
              "iva_porcentaje",
              "precio_total",
              "irpf_aplicado",
              "irpf_porcentaje",
              "irpf_importe",
              "estado",
              "fecha_emision",
              "fecha_validez",
              "notas",
              "document_path",
              "quotation_version",
              "created_at",
              "updated_at",
            ].join(","),
          )
          .eq("project_id", project.id)
          .order("created_at", { ascending: false }),

        supabase
          .from("invoices")
          .select(
            [
              "id",
              "project_id",
              "numero_factura",
              "quotation_id",
              "fecha_emision",
              "fecha_vencimiento",
              "descripcion",
              "subtotal",
              "iva_aplicado",
              "iva_porcentaje",
              "iva_importe",
              "irpf_aplicado",
              "irpf_porcentaje",
              "irpf_importe",
              "monto",
              "importe_a_pagar",
              "estado",
              "document_path",
              "created_at",
              "updated_at",
            ].join(","),
          )
          .eq("project_id", project.id)
          .order("created_at", { ascending: false }),
      ]);

      setDetailProject(project);

      const loadedMilestones = (milestonesResult.data || []) as Milestone[];
      setMilestones(loadedMilestones);
      setUpdates((updatesResult.data || []) as ProjectUpdate[]);
      setDocuments((documentsResult.data || []) as ProjectDocument[]);
      setChangeRequests((changesResult.data || []) as ProjectChangeRequest[]);
      setQuotations((quotationsResult.data || []) as unknown as Quotation[]);
      setInvoices((invoicesResult.data || []) as unknown as Invoice[]);

      /*
       * project_progress es la fuente de verdad definida por las migraciones.
       * Si la vista no devuelve fila, calculamos solo como fallback visual
       * a partir de los mismos hitos, sin guardar el porcentaje.
       */
      if (progressResult.data) {
        setProgress((current) => [
          ...current.filter((item) => item.project_id !== project.id),
          progressResult.data as ProjectProgress,
        ]);
      } else {
        const total = loadedMilestones.length;
        const completed = loadedMilestones.filter(
          (milestone) => milestone.estado === "completado",
        ).length;

        setProgress((current) => [
          ...current.filter((item) => item.project_id !== project.id),
          {
            project_id: project.id,
            total_milestones: total,
            completed_milestones: completed,
            progress_percentage: total
              ? Math.round((completed / total) * 100)
              : 0,
          },
        ]);
      }

      /*
       * payments.amount está expresado en céntimos según el modelo de Stripe.
       * Solo consultamos por company_id una vez verificado el proyecto.
       * Si la política de lectura no permite consultar pagos, el detalle del
       * proyecto sigue funcionando: las facturas continúan mostrándose.
       */
      if (project.company_id) {
        const paymentsResult = await supabase
          .from("payments")
          .select(
            "id,invoice_id,amount,currency,status,description,paid_at,created_at",
          )
          .eq("company_id", project.company_id)
          .order("created_at", { ascending: false });

        if (paymentsResult.error) {
          console.warn(
            "[ClientProjects] No se pudieron cargar los pagos:",
            paymentsResult.error,
          );
          setPayments([]);
        } else {
          setPayments((paymentsResult.data || []) as Payment[]);
        }
      } else {
        setPayments([]);
      }
    } catch (err: any) {
      console.error("[ClientProjects] Error cargando detalle:", err);
      setError(err?.message || "No se pudo cargar el proyecto.");
      setDetailProject(null);
      setMilestones([]);
      setUpdates([]);
      setDocuments([]);
      setChangeRequests([]);
      setQuotations([]);
      setInvoices([]);
      setPayments([]);
    } finally {
      setDetailLoading(false);
    }
  }, [user, projectIdFromUrl]);
  useEffect(() => {
    loadProjects();
  }, [loadProjects]);

  useEffect(() => {
    if (projectIdFromUrl) loadProjectDetail();
  }, [projectIdFromUrl, loadProjectDetail]);

  const filteredProjects = useMemo(() => {
    const query = normalize(search);

    const result = projects.filter((project) => {
      const matchesSearch =
        !query ||
        normalize(project.nombre).includes(query) ||
        normalize(project.descripcion).includes(query);

      const matchesStatus =
        statusFilter === "all" || project.estado === statusFilter;

      return matchesSearch && matchesStatus;
    });

    // Orden predeterminado de la cartera:
    // 1. Pendientes
    // 2. Activos + pausados, mezclados cronológicamente
    // 3. Completados
    // 4. Entregados
    // Dentro de cada bloque, los más recientes aparecen primero.
    const statusOrder: Record<ProjectStatus, number> = {
      Pendiente: 0,
      Activo: 1,
      Pausado: 1,
      Completado: 2,
      Entregado: 3,
    };

    const projectDate = (project: Project) =>
      new Date(project.fecha_inicio || project.created_at || project.fecha_fin || 0).getTime();

    result.sort((a, b) => {
      const statusDifference = statusOrder[a.estado] - statusOrder[b.estado];
      if (statusDifference !== 0) return statusDifference;

      const dateDifference = projectDate(b) - projectDate(a);
      if (dateDifference !== 0) return dateDifference;

      return new Date(b.created_at || 0).getTime() - new Date(a.created_at || 0).getTime();
    });

    return result;
  }, [projects, search, statusFilter]);
const companyById = useMemo(() => {
  const map = new Map<string, Company>();

  companies.forEach((company) => {
    map.set(company.id, company);
  });

  return map;
}, [companies]);
  const progressByProject = useMemo(() => {
    const map = new Map<string, ProjectProgress>();
    progress.forEach((item) => map.set(item.project_id, item));
    return map;
  }, [progress]);

  const changeRequestsByProject = useMemo(() => {
    const map = new Map<string, ProjectChangeRequest[]>();

    for (const request of projectChangeRequests) {
      const current = map.get(request.project_id) || [];
      current.push(request);
      map.set(request.project_id, current);
    }

    return map;
  }, [projectChangeRequests]);

  const getProjectChangeRequestSummary = useCallback(
    (projectId: string) => {
      const requests = [...(changeRequestsByProject.get(projectId) || [])];

      if (!requests.length) return null;

      const requestStatusOrder: Record<ChangeRequestStatus, number> = {
        pending: 0,
        in_review: 1,
        accepted: 2,
        completed: 3,
        rejected: 4,
      };

      requests.sort((a, b) => {
        const statusDifference =
          requestStatusOrder[a.status] - requestStatusOrder[b.status];

        if (statusDifference !== 0) return statusDifference;

        return (
          new Date(b.created_at || 0).getTime() -
          new Date(a.created_at || 0).getTime()
        );
      });

      return requests[0] || null;
    },
    [changeRequestsByProject],
  );


  const detailProgress = detailProject
    ? progressByProject.get(detailProject.id)
    : undefined;

  const activeChangeRequest = useMemo(
    () =>
      changeRequests.find((request) =>
        ["pending", "in_review", "accepted"].includes(normalize(request.status)),
      ),
    [changeRequests],
  );

  const handleCreateProject = async () => {
    if (!createDescription.trim()) {
      toast.error("La descripción del proyecto es obligatoria.");
      return;
    }

    if (
      createStartDate &&
      createEndDate &&
      new Date(createEndDate).getTime() < new Date(createStartDate).getTime()
    ) {
      toast.error("La fecha de fin no puede ser anterior a la fecha de inicio.");
      return;
    }

    setCreatingProject(true);

    try {
      const { data, error } = await supabase.rpc("create_project", {
        p_descripcion: createDescription.trim(),
        p_fecha_inicio: createStartDate || null,
        p_fecha_fin: createEndDate || null,
      });

      if (error) throw error;

      const createdProject = Array.isArray(data) ? data[0] : data;
      toast.success("Proyecto creado correctamente.");

      if (createdProject?.id) {
        /*
         * Sustituimos la entrada #new por la del proyecto recién creado.
         * Así, al pulsar "Volver a mis proyectos" o el botón Atrás, el
         * usuario vuelve directamente al listado y no a la pantalla de
         * creación anterior.
         */
        window.history.replaceState(
          {
            modiraProjectView: true,
            view: "project",
            projectId: createdProject.id,
          },
          "",
          `${window.location.pathname}#project=${encodeURIComponent(
            createdProject.id,
          )}`,
        );
        setCreateMode(false);
        setSelectedProjectId(createdProject.id);
        setDetailProject(null);
        setError(null);
        window.scrollTo({ top: 0, behavior: "smooth" });
      } else {
        closeProjectView();
      }
    } catch (err: any) {
      console.error("[ClientProjects] Error creando proyecto:", err);
      toast.error(err?.message || "No se pudo crear el proyecto.");
    } finally {
      setCreatingProject(false);
    }
  };

  const handleRequestChange = async () => {
    if (!detailProject) return;

    if (!detailProject.change_requests_enabled) {
      toast.error("Las solicitudes de cambio no están habilitadas para este proyecto.");
      return;
    }

    if (
      detailProject.change_requests_deadline &&
      new Date(detailProject.change_requests_deadline).getTime() < Date.now()
    ) {
      toast.error("El plazo para solicitar cambios ya ha terminado.");
      return;
    }

    if (!changeDescription.trim()) {
      toast.error("Describe el cambio que necesitas solicitar.");
      return;
    }

    setSubmittingChangeRequest(true);

    try {
      const { data, error } = await supabase.rpc("request_project_change", {
        p_project_id: detailProject.id,
        p_description: changeDescription.trim(),
      });

      if (error) throw error;

      setChangeRequests((current) => [
        data as ProjectChangeRequest,
        ...current,
      ]);
      setChangeDescription("");
      setIsChangeRequestOpen(false);
      toast.success("Solicitud de cambio enviada.");
    } catch (err: any) {
      console.error("[ClientProjects] Error solicitando cambio:", err);
      toast.error(err?.message || "No se pudo enviar la solicitud.");
    } finally {
      setSubmittingChangeRequest(false);
    }
  };

  const handleQuotationResponse = async (
    quotation: Quotation,
    response: "Aceptado" | "Rechazado",
  ) => {
    if (normalize(quotation.estado) !== "pendiente") {
      toast.info("Este presupuesto ya no está pendiente.");
      return;
    }

    setRespondingQuotationId(quotation.id);

    try {
      const { data, error } = await supabase.rpc("respond_to_quotation", {
        p_estado: response,
        p_quotation_id: quotation.id,
      });

      if (error) throw error;

      setQuotations((current) =>
        current.map((item) =>
          item.id === quotation.id
            ? ({ ...item, ...(data as Quotation) } as Quotation)
            : item,
        ),
      );

      toast.success(
        response === "Aceptado"
          ? "Presupuesto aceptado correctamente."
          : "Presupuesto rechazado.",
      );

    } catch (err: any) {
      console.error("[ClientProjects] Error respondiendo presupuesto:", err);
      toast.error(err?.message || "No se pudo responder al presupuesto.");
    } finally {
      setRespondingQuotationId(null);
    }
  };

  const createSignedUrl = async (bucket: string, path: string) => {
    const { data, error } = await supabase.storage
      .from(bucket)
      .createSignedUrl(path, 60 * 10);

    if (error) throw error;
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

  if (authLoading) {
    return (
      <div className="min-h-screen bg-[#FBFCFE] flex items-center justify-center">
        <Loader2 className="h-7 w-7 animate-spin text-[#173B8F]" />
      </div>
    );
  }

  if (!user) return null;

  if (createFromUrl) {
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

          <div className="mx-auto max-w-[1280px] px-6 pb-12 pt-10 lg:px-8">
            <div className="mb-7 flex items-center justify-between gap-4">
              <div>
                <button
                  type="button"
                  onClick={closeProjectView}
                  className="mb-4 inline-flex items-center gap-2 text-[12px] font-medium text-[#718096] hover:text-[#173B8F]"
                >
                  <ArrowLeft className="h-4 w-4" />
                  Volver a mis proyectos
                </button>
                <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                  Mis proyectos
                </p>
                <h1 className="text-[27px] font-semibold tracking-tight text-[#182A45]">
                  Crear proyecto
                </h1>
                <p className="mt-2 max-w-2xl text-[13px] leading-6 text-[#718096]">
                  Crea una nueva solicitud de proyecto. El proyecto se registra como
                  Pendiente y queda asociado automáticamente a tu cuenta y a tu empresa actual.
                </p>
              </div>
            </div>

            <div className="max-w-[780px] rounded-xl border border-[#E3E8EE] bg-white p-6 shadow-[0_8px_30px_rgba(25,40,65,0.04)]">
              <div className="space-y-6">
                <div>
                  <Label htmlFor="project-description" className="text-[12px] font-semibold text-[#344054]">
                    Descripción del proyecto
                  </Label>
                  <textarea
                    id="project-description"
                    value={createDescription}
                    onChange={(event) => setCreateDescription(event.target.value)}
                    maxLength={10000}
                    rows={8}
                    placeholder="Describe qué necesitas, objetivos, alcance inicial o cualquier información útil..."
                    className="mt-2 w-full rounded-md border border-[#D7DEE7] bg-white px-3 py-3 text-[13px] leading-6 text-[#26344A] outline-none transition focus:border-[#173B8F] focus:ring-2 focus:ring-[#173B8F]/10"
                  />
                  <div className="mt-1 text-right text-[10px] text-[#98A2B3]">
                    {createDescription.length}/10.000
                  </div>
                </div>

                <div className="grid gap-5 sm:grid-cols-2">
                  <div>
                    <Label htmlFor="project-start" className="text-[12px] font-semibold text-[#344054]">
                      Fecha de inicio
                    </Label>
                    <Input
                      id="project-start"
                      type="date"
                      value={createStartDate}
                      onChange={(event) => setCreateStartDate(event.target.value)}
                      className="mt-2 h-10 border-[#D7DEE7] text-[12px]"
                    />
                  </div>

                  <div>
                    <Label htmlFor="project-end" className="text-[12px] font-semibold text-[#344054]">
                      Fecha de fin
                    </Label>
                    <Input
                      id="project-end"
                      type="date"
                      value={createEndDate}
                      onChange={(event) => setCreateEndDate(event.target.value)}
                      className="mt-2 h-10 border-[#D7DEE7] text-[12px]"
                    />
                  </div>
                </div>

                <div className="rounded-lg border border-[#E7EBF0] bg-[#F8FAFC] p-4">
                  <p className="text-[11px] font-semibold text-[#344054]">
                    ¿Qué ocurrirá al crear el proyecto?
                  </p>
                  <ul className="mt-2 space-y-1.5 text-[11px] leading-5 text-[#718096]">
                    <li>• Se creará con estado Pendiente.</li>
                    <li>• Se asociará automáticamente a tu usuario.</li>
                    <li>• Se utilizará tu empresa actual, si tienes una asociada.</li>
                    <li>• El proyecto podrá recibir hitos, novedades, documentos y solicitudes de cambio desde el área de cliente.</li>
                  </ul>
                </div>

                <div className="flex justify-end gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    onClick={closeProjectView}
                    className="h-10 border-[#D7DEE7] text-[12px]"
                  >
                    Cancelar
                  </Button>
                  <Button
                    type="button"
                    disabled={creatingProject}
                    onClick={handleCreateProject}
                    className="h-10 bg-[#173B8F] text-[12px] hover:bg-[#173B8F]/90"
                  >
                    {creatingProject ? (
                      <>
                        <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                        Creando...
                      </>
                    ) : (
                      <>
                        Crear proyecto
                        <ArrowRight className="ml-2 h-4 w-4" />
                      </>
                    )}
                  </Button>
                </div>
              </div>
            </div>
          </div>
        </main>
      </div>
    );
  }

  if (projectIdFromUrl) {
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
            <div className="mb-8 flex items-start justify-between gap-5 border-b border-[#E6EAF0] pb-8 pr-28">
              <div className="min-w-0">
                <button
                  type="button"
                  onClick={closeProjectView}
                  className="mb-4 inline-flex items-center gap-2 text-[12px] font-medium text-[#718096] hover:text-[#173B8F]"
                >
                  <ArrowLeft className="h-4 w-4" />
                  Todos los proyectos
                </button>

                {detailLoading ? (
                  <div className="flex items-center gap-2 text-sm text-[#718096]">
                    <Loader2 className="h-4 w-4 animate-spin text-[#173B8F]" />
                    Cargando proyecto...
                  </div>
                ) : detailProject ? (
                  <>
                    <p className="text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                      Proyecto
                    </p>
                    <h1 className="mt-1 text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">
                      {detailProject.nombre}
                    </h1>
                    {detailProject.company_id && companyById.get(detailProject.company_id) && (
  <p className="mt-2 inline-flex items-center gap-1.5 text-[11px] font-medium text-[#8A95A5]">
    <BriefcaseBusiness
      className="h-3.5 w-3.5 text-[#A1AAB7]"
      strokeWidth={1.7}
    />
    {companyById.get(detailProject.company_id)?.company_name}
  </p>
)}
                    <p className="mt-2 max-w-3xl text-[13px] leading-6 text-[#718096]">
                      {detailProject.descripcion || "Este proyecto todavía no tiene descripción."}
                    </p>
                  </>
                ) : (
                  <div className="rounded-lg border border-[#F0D0D0] bg-[#FFF7F7] p-4 text-[12px] text-[#B53A3A]">
                    {error || "No se ha encontrado el proyecto."}
                  </div>
                )}
              </div>

              {detailProject && (
                <button
                  type="button"
                  onClick={() => openCreateProject()}
                  className="mt-8 hidden shrink-0 items-center gap-2 rounded-md border border-[#D7DEE7] bg-white px-3 py-2 text-[11px] font-medium text-[#445166] hover:border-[#C5CED9] hover:bg-[#F8FAFC] sm:flex"
                >
                  <BriefcaseBusiness className="h-4 w-4" />
                  Nuevo proyecto
                </button>
              )}
            </div>

            {detailProject && !detailLoading && (
              <ProjectDetailContent
              key={detailProject.id}
                project={detailProject}
                milestones={milestones}
                progress={detailProgress}
                updates={updates}
                documents={documents}
                changeRequests={changeRequests}
                quotations={quotations}
                invoices={invoices}
                payments={payments}
                activeChangeRequest={activeChangeRequest}
                onOpenChangeRequest={() => setIsChangeRequestOpen(true)}
                onOpenProjectDocument={openProjectDocument}
                onOpenQuotationDocument={openQuotationDocument}
                onOpenInvoiceDocument={openInvoiceDocument}
                onQuotationResponse={handleQuotationResponse}
                respondingQuotationId={respondingQuotationId}
              />
            )}
          </div>

          <Dialog open={isChangeRequestOpen} onOpenChange={setIsChangeRequestOpen}>
            <DialogContent className="sm:max-w-lg">
              <DialogHeader>
                <DialogTitle className="text-[#182A45]">
                  Solicitar un cambio
                </DialogTitle>
                <DialogDescription className="text-[12px] leading-5">
                  La solicitud se registrará como pendiente y quedará asociada a este proyecto.
                </DialogDescription>
              </DialogHeader>

              <div className="space-y-2">
                <Label htmlFor="change-description" className="text-[12px] font-semibold text-[#344054]">
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
                  className="text-[12px]"
                >
                  Cancelar
                </Button>
                <Button
                  onClick={handleRequestChange}
                  disabled={submittingChangeRequest}
                  className="bg-[#173B8F] text-[12px] hover:bg-[#173B8F]/90"
                >
                  {submittingChangeRequest && (
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  )}
                  Enviar solicitud
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
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

      <main className={[
          sidebarOpen ? "ml-[62px] lg:ml-[236px]" : "ml-[62px]",
          "[scrollbar-gutter:stable]",
        ].join(" ")}>
        <ClientFloatingActions />

        <div className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
          <section className="mb-8 border-b border-[#E6EAF0] pb-8">
            <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
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

            </div>
          </section>

          {/* ----------------------------------------------------------
              RESUMEN — mismo lenguaje visual que el dashboard:
              cuatro bloques rectos, sin esquinas redondeadas.
          ---------------------------------------------------------- */}
          <section className="mb-10 grid grid-cols-2 divide-x divide-y divide-[#E5E9EF] border-y border-[#E5E9EF] bg-white/40 lg:grid-cols-4 lg:divide-y-0">
            {[
              {
                label: "Total de proyectos",
                value: projects.length,
                detail: projects.length === 1 ? "Proyecto registrado" : "Proyectos registrados",
                icon: BriefcaseBusiness,
                active: projects.length > 0,
              },
              {
                label: "Proyectos activos",
                value: projects.filter((project) => project.estado === "Activo").length,
                detail: "En ejecución",
                icon: Clock3,
                active: projects.some((project) => project.estado === "Activo"),
              },
              {
                label: "Proyectos en pausa",
                value: projects.filter((project) => project.estado === "Pausado").length,
                detail: "Seguimiento conservado",
                icon: AlertCircle,
                active: projects.some((project) => project.estado === "Pausado"),
              },
              {
                label: "Proyectos completados",
                value: projects.filter((project) => project.estado === "Completado").length,
                detail: "Finalizados",
                icon: Check,
                active: projects.some((project) => project.estado === "Completado"),
              },
            ].map((item) => {
              const Icon = item.icon;
              return (
                <div
                  key={item.label}
                  className={[
                    "min-h-[116px] px-5 py-5 sm:px-7",
                    item.active ? "bg-[#173B8F] text-white" : "bg-white/50 text-[#1E2D43]",
                  ].join(" ")}
                >
                  <div className="flex h-full items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p
                        className={[
                          "text-[10px] font-semibold uppercase tracking-[0.13em]",
                          item.active ? "text-white/75" : "text-[#8A95A4]",
                        ].join(" ")}
                      >
                        {item.label}
                      </p>
                      <p
                        className={[
                          "mt-2 text-2xl font-semibold tracking-tight",
                          item.active ? "text-white" : "text-[#1E2D43]",
                        ].join(" ")}
                      >
                        {item.value}
                      </p>
                      <p
                        className={[
                          "mt-0.5 truncate text-xs",
                          item.active ? "text-white/80" : "text-[#8A95A4]",
                        ].join(" ")}
                      >
                        {item.detail}
                      </p>
                    </div>
                    <Icon
                      className={[
                        "mt-0.5 h-4 w-4 shrink-0",
                        item.active ? "text-white/80" : "text-[#A1AAB7]",
                      ].join(" ")}
                      strokeWidth={1.7}
                    />
                  </div>
                </div>
              );
            })}
          </section>

          {/* ----------------------------------------------------------
              CARTERA — sin tarjetas flotantes. El buscador y los
              proyectos siguen las líneas, separadores y espacios del
              dashboard.
          ---------------------------------------------------------- */}
          <section>
            <SectionTitle
              eyebrow="Cartera de proyectos"
              title="Todos tus proyectos"
              action={
                <span className="text-[11px] text-[#8A95A5]">
                  {filteredProjects.length} de {projects.length}
                </span>
              }
            />

            <div className="mb-8 border border-[#E3E8EE] bg-white p-4 sm:p-5">
<div className="flex h-11 items-center gap-3 rounded-lg border border-[#E3E8EE] bg-[#F8FAFC] px-3.5 transition-all focus-within:border-[#173B8F] focus-within:ring-1 focus-within:ring-[#173B8F]">
  <Search
    className="h-4 w-4 shrink-0 text-[#8F9AAA]"
    strokeWidth={1.7}
  />

  <Input
    value={search}
    onChange={(event) => setSearch(event.target.value)}
    placeholder="Buscar proyecto por nombre o descripción..."
    className="h-full min-w-0 !border-0 !bg-transparent !p-0 text-[13px] text-[#344054] !shadow-none !outline-none placeholder:text-[#9AA4B2] focus:!border-0 focus:!outline-none focus:!ring-0 focus-visible:!border-0 focus-visible:!outline-none focus-visible:!ring-0 focus-visible:ring-offset-0"
  />
</div>

              <div className="mt-5 flex flex-wrap items-center gap-x-3 gap-y-2.5">
                <span className="mr-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                  Estado
                </span>
                {PROJECT_STATUSES.map((status) => {
                  const active = statusFilter === status;
                  const label = status === "all" ? "Todos" : status;

                  return (
                    <button
                      key={status}
                      type="button"
                      onClick={() => setStatusFilter(status)}
                      className={[
                        "rounded-full border px-[18px] py-2 text-[12px] font-medium transition-all",
                        active
                          ? "border-[#173B8F] bg-[#173B8F] text-white"
                          : "border-[#DCE2E9] bg-white text-[#667386] hover:border-[#C6CFDA] hover:bg-[#F7F9FB] hover:text-[#173B8F]",
                      ].join(" ")}
                    >
                      {label}
                    </button>
                  );
                })}
              </div>
            </div>

            {loading ? (
              <div className="border-y border-[#E7EBF0] py-14 text-center">
                <Loader2 className="mx-auto mb-3 h-7 w-7 animate-spin text-[#173B8F]" />
                <p className="text-[12px] text-[#718096]">Cargando proyectos...</p>
              </div>
            ) : error ? (
              <div className="border-y border-[#E7EBF0] py-8">
                <div className="flex items-start gap-3">
                  <AlertCircle className="mt-0.5 h-5 w-5 shrink-0 text-[#B53A3A]" strokeWidth={1.7} />
                  <div>
                    <p className="text-[13px] font-semibold text-[#26344A]">
                      No se pudieron cargar los proyectos
                    </p>
                    <p className="mt-1 text-[12px] leading-5 text-[#718096]">{error}</p>
                  </div>
                </div>
              </div>
            ) : filteredProjects.length === 0 ? (
              <div className="border-y border-[#E7EBF0] py-12 text-center">
                <BriefcaseBusiness className="mx-auto mb-4 h-7 w-7 text-[#AAB3BF]" strokeWidth={1.6} />
                <p className="text-[14px] font-semibold text-[#344054]">
                  {projects.length ? "No hay proyectos que coincidan" : "Todavía no tienes proyectos"}
                </p>
                <p className="mx-auto mt-2 max-w-md text-[12px] leading-5 text-[#8792A2]">
                  {projects.length
                    ? "Prueba con otro nombre, descripción o estado."
                    : "Puedes crear una nueva solicitud de proyecto desde este apartado."}
                </p>
              </div>
            ) : (
              <div className="space-y-5">
                {filteredProjects.map((project) => {
                  const projectProgress = progressByProject.get(project.id);
                  const rawPercentage = Math.max(
                    0,
                    Math.min(100, Number(projectProgress?.progress_percentage || 0)),
                  );
                  const percentage =
                    project.estado === "Entregado" || project.estado === "Completado"
                      ? 100
                      : rawPercentage;
                  const completedMilestones = Number(projectProgress?.completed_milestones || 0);
                  const totalMilestones = Number(projectProgress?.total_milestones || 0);
                  const changeRequest = getProjectChangeRequestSummary(project.id);
                  const projectCompany = project.company_id
  ? companyById.get(project.company_id)
  : undefined;

                  const nextProjectDate = project.fecha_fin
                    ? formatCompactDate(project.fecha_fin)
                    : "Sin fecha";

                  return (
                    <article
                      key={project.id}
                      className="group relative overflow-hidden rounded-[20px] border border-[#E1E7EE] bg-white transition-all duration-200 hover:-translate-y-[1px] hover:border-[#CDD6E0] hover:shadow-[0_14px_34px_rgba(24,42,69,0.07)]"
                    >
                      <div className="relative px-5 py-5 sm:px-7 sm:py-6">
                        <div className="flex items-start gap-6">
                          <div className="min-w-0 flex-1">
                            <div className="flex flex-wrap items-center gap-2.5">
                              <span
                                className={[
                                  "inline-flex h-2 w-2 shrink-0 rounded-full",
                                  project.estado === "Activo"
                                    ? "bg-[#22C55E]"
                                    : project.estado === "Pendiente"
                                      ? "bg-[#F59E0B]"
                                      : project.estado === "Pausado"
                                        ? "bg-[#F59E0B]"
                                        : project.estado === "Entregado"
                                          ? "bg-[#4B3E57]"
                                          : "bg-[#247A49]",
                                ].join(" ")}
                                aria-hidden="true"
                              />
                              <h3 className="min-w-0 text-[17px] font-semibold leading-tight tracking-[-0.015em] text-[#1F3048] sm:text-[18px]">
                                {project.nombre}
                              </h3>
                              {projectCompany && (
  <span className="inline-flex items-center gap-1.5 text-[10px] font-medium text-[#8A95A5]">
    <BriefcaseBusiness
      className="h-3 w-3 text-[#A1AAB7]"
      strokeWidth={1.7}
    />
    {projectCompany.company_name}
  </span>
)}
                              <span
                                className={[
                                  "rounded-full border px-2.5 py-1 text-[10px] font-semibold leading-none",
                                  projectStatusClasses(project.estado),
                                ].join(" ")}
                              >
                                {statusLabel(project.estado)}
                              </span>
                            </div>

                            <p className="mt-2 max-w-3xl text-[12px] leading-5 text-[#718096]">
                              {project.descripcion ||
                                "Este proyecto todavía no tiene una descripción disponible."}
                            </p>

                            <div className="mt-5 flex flex-wrap items-center gap-x-6 gap-y-3">
                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Inicio
                                </p>
                                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                                  {project.fecha_inicio
                                    ? formatCompactDate(project.fecha_inicio)
                                    : "Sin definir"}
                                </p>
                              </div>

                              <div className="h-7 w-px bg-[#E8ECF1]" />

                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Finalización
                                </p>
                                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                                  {nextProjectDate}
                                </p>
                              </div>

                              <div className="h-7 w-px bg-[#E8ECF1]" />

                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Hitos
                                </p>
                                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                                  {totalMilestones
                                    ? `${completedMilestones}/${totalMilestones} completados`
                                    : "Sin hitos"}
                                </p>
                              </div>

                              <div className="h-7 w-px bg-[#E8ECF1]" />

                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Actualización
                                </p>
                                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                                  {formatCompactDate(project.updated_at)}
                                </p>
                              </div>
                            </div>

                            <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 border-t border-[#EEF1F4] pt-4 text-[11px]">
                              <span className="inline-flex items-center gap-1.5 text-[#7A8595]">
                                <MessageSquare
                                  className="h-3.5 w-3.5 text-[#9AA4B2]"
                                  strokeWidth={1.7}
                                />
                                <span>Solicitud de cambio</span>
                                <ChangeRequestPreviewBadge request={changeRequest} />
                              </span>

                              <span className="hidden h-4 w-px bg-[#E5E9EE] sm:block" />
                              <span className="inline-flex items-center gap-1.5 text-[#7A8595]">
                                <FileText
                                  className="h-3.5 w-3.5 text-[#9AA4B2]"
                                  strokeWidth={1.7}
                                />
                                {projectDocumentCounts[project.id] ?? 0}{" "}
                                {projectDocumentCounts[project.id] === 1
                                  ? "documento"
                                  : "documentos"}
                              </span>

                              <button
                                type="button"
                                onClick={() => openProject(project.id)}
                                className="ml-auto inline-flex items-center gap-1.5 font-semibold text-[#173B8F] transition-all hover:gap-2 hover:text-[#102A66]"
                              >
                                Consultar proyecto
                                <ArrowRight className="h-3.5 w-3.5" />
                              </button>
                            </div>
                          </div>

                          <button
                            type="button"
                            onClick={() => openProject(project.id)}
                            aria-label={`Abrir ${project.nombre}`}
                            className="flex w-[68px] shrink-0 flex-col items-center justify-center self-stretch gap-2 rounded-full outline-none transition-transform duration-200 hover:scale-[1.03] focus-visible:ring-2 focus-visible:ring-[#173B8F]/20 sm:w-[82px]"
                          >
                            <span className="text-[8px] font-semibold uppercase tracking-[0.13em] text-[#98A2B3]">
                              Progreso
                            </span>
                            <ProjectProgressRing
                              percentage={percentage}
                              status={project.estado}
                              compact
                            />
                          </button>
                        </div>
                      </div>
                    </article>
                  );
                })}
              </div>
            )}
          </section>
        </div>
      </main>
    </div>
  );
}

function ProjectStatCard({
  label,
  value,
  icon,
}: {
  label: string;
  value: number;
  icon: ReactNode;
}) {
  return (
    <div className="rounded-xl border border-[#E3E8EE] bg-white px-4 py-4 shadow-[0_8px_30px_rgba(25,40,65,0.025)]">
      <div className="flex items-center justify-between">
        <span className="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
          {label}
        </span>
        <span className="text-[#718096]">{icon}</span>
      </div>
      <p className="mt-2 text-[23px] font-semibold tracking-tight text-[#26344A]">{value}</p>
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
  activeChangeRequest,
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
  activeChangeRequest?: ProjectChangeRequest;
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
  "novedades" | "documentos" | "cambios" | "presupuestos" | "facturas" | "alcance"
>(() => {
  const storageKey = `project-active-section-${project.id}`;
  const savedSection = sessionStorage.getItem(storageKey);

  const validSections = [
    "novedades",
    "documentos",
    "cambios",
    "presupuestos",
    "facturas",
    "alcance",
  ] as const;

  if (
    savedSection &&
    validSections.includes(savedSection as (typeof validSections)[number])
  ) {
    return savedSection as (typeof validSections)[number];
  }

  return "novedades";
});

useEffect(() => {
  sessionStorage.setItem(
    `project-active-section-${project.id}`,
    activeSection
  );
}, [project.id, activeSection]);

// Alcance oficial del proyecto
const [scopeLoading, setScopeLoading] = useState(true);

const [scopeVersion, setScopeVersion] = useState<{
  id: string;
  project_id: string;
  version_number: number;
  status: string;
  content_snapshot: Record<string, unknown>;
  document_path: string | null;
  document_sha256: string | null;
  published_at: string | null;
  is_current: boolean;
} | null>(null);

const [scopePdfOpened, setScopePdfOpened] = useState(false);
const [scopeAcknowledged, setScopeAcknowledged] = useState(false);
const [scopeComments, setScopeComments] = useState("");
const [scopeSubmitting, setScopeSubmitting] = useState(false);
useEffect(() => {
  let cancelled = false;

  const loadScopeVersion = async () => {
    setScopeLoading(true);

    try {
      const { data, error } = await supabase
        .from("project_scope_versions")
        .select(
          "id,project_id,version_number,status,content_snapshot,document_path,document_sha256,published_at,is_current"
        )
        .eq("project_id", project.id)
        .eq("is_current", true)
        .maybeSingle();

      if (error) {
        throw error;
      }

      if (!cancelled) {
        setScopeVersion(
          data
            ? {
                ...data,
                content_snapshot:
                  data.content_snapshot as Record<string, unknown>,
              }
            : null
        );
      }
    } catch (error) {
      console.error(
        "[ClientProjects] Error cargando el alcance:",
        error
      );

      if (!cancelled) {
        setScopeVersion(null);
      }
    } finally {
      if (!cancelled) {
        setScopeLoading(false);
      }
    }
  };

  void loadScopeVersion();

  return () => {
    cancelled = true;
  };
}, [project.id]);
useEffect(() => {
  if (!scopeVersion?.id) {
    setScopePdfOpened(false);
    setScopeAcknowledged(false);
    return;
  }

  const storageKey = `project-scope-pdf-opened-${scopeVersion.id}`;
  const hasOpenedPdf = sessionStorage.getItem(storageKey) === "true";

  setScopePdfOpened(hasOpenedPdf);
  setScopeAcknowledged(false);
}, [scopeVersion?.id]);

const [, setLocation] = useLocation();
  const pendingChangeRequests = changeRequests.filter((request) =>
    ["pending", "in_review"].includes(normalize(request.status)),
  ).length;

  const projectPayments = payments.filter((payment) =>
    invoices.some((invoice) => invoice.id === payment.invoice_id),
  );

  const totalInvoiced = invoices.reduce(
    (sum, invoice) =>
      sum + Number(invoice.importe_a_pagar ?? invoice.monto ?? 0),
    0,
  );

  const totalPaid = projectPayments
    .filter((payment) => normalize(payment.status) === "succeeded")
    .reduce(
      (sum, payment) => sum + Number(payment.amount || 0) / 100,
      0,
    );

  /*
   * IMPORTANTE:
   *
   * quotations = presupuestos del proyecto.
   * budgets es otra entidad de la base de datos y no sustituye
   * a quotations para este apartado.
   *
   * Los PDFs de quotations utilizan:
   *   quotation.document_path
   *   bucket "quotations"
   *
   * Las facturas utilizan:
   *   invoice.document_path
   *   bucket "invoices"
   *
   * Los documentos de proyecto utilizan:
   *   document.storage_path
   *   bucket "project-documents"
   */

  const sections = [
    {
      id: "novedades" as const,
      label: "Novedades",
      count: updates.length,
    },
    {
      id: "documentos" as const,
      label: "Documentos",
      count: documents.length,
    },
    {
      id: "cambios" as const,
      label: "Solicitudes de cambio",
      count: changeRequests.length,
    },
    {
      id: "presupuestos" as const,
      label: "Presupuestos",
      count: quotations.length,
    },
    {
      id: "facturas" as const,
      label: "Facturas",
      count: invoices.length,
    },
    {
  id: "alcance" as const,
  label: "Alcance",
  count: scopeVersion ? 1 : 0,
},
  ];

  return (
    <div className="space-y-7">
      {/* ============================================================
          SEGUIMIENTO DEL PROYECTO
          ============================================================ */}
      <ProjectMilestoneTimeline
  project={project}
  milestones={milestones}
/>

      {/* ============================================================
          NAVEGACIÓN DEL PROYECTO

          Sin "Resumen".

          Mismo concepto visual:
          - contenedor limpio
          - pestaña activa en azul oscuro
          - contador circular
          - separación generosa
          - scroll horizontal en móvil
          ============================================================ */}
      <nav
  className="flex justify-center"
  aria-label="Secciones del proyecto"
>
      
        <div className="mx-auto flex min-w-max items-center gap-1.5 rounded-[20px] border border-[#DDE4EC] bg-white p-1.5 shadow-[0_6px_24px_rgba(24,42,69,0.035)] lg:min-w-0">
          {sections.map((section) => {
            const active = activeSection === section.id;

            return (
              <button
                key={section.id}
                type="button"
                onClick={() => setActiveSection(section.id)}
                className={[
                  "relative flex min-h-[46px] shrink-0 items-center justify-center gap-2 rounded-[14px] px-4 text-[11px] font-medium transition-all duration-200 sm:px-5 sm:text-[12px]",
                  active
                    ? "bg-[#173B8F] font-semibold text-white shadow-[0_4px_12px_rgba(23,59,143,0.16)]"
                    : "text-[#667386] hover:bg-[#F6F8FA] hover:text-[#173B8F]",
                ].join(" ")}
              >
                <span>{section.label}</span>

                <span
                  className={[
                    "flex h-[20px] min-w-[20px] items-center justify-center rounded-full px-1.5 text-[9px] font-semibold leading-none transition-colors",
                    active
                      ? "bg-white/15 text-white"
                      : section.count > 0
                        ? "bg-[#F1F4F8] text-[#687588]"
                        : "bg-[#F8F9FB] text-[#A5AEB9]",
                  ].join(" ")}
                >
                  {section.count}
                </span>
              </button>
            );
          })}
        </div>
      </nav>

      {/* ============================================================
          NOVEDADES
          ============================================================ */}
      {/* ============================================================
    ALCANCE OFICIAL DEL PROYECTO
    ============================================================ */}
{activeSection === "alcance" && (
  <section className="space-y-5">
    <SectionTitle
      eyebrow="Definición del proyecto"
      title="Alcance del proyecto"
      action={
        scopeVersion ? (
          <span className="text-[10px] text-[#98A2B3]">
            Versión {scopeVersion.version_number}
          </span>
        ) : undefined
      }
    />

    {scopeLoading ? (
      <div className="flex items-center justify-center gap-3 rounded-2xl border border-[#E1E7EE] bg-white px-6 py-12">
        <Loader2 className="h-5 w-5 animate-spin text-[#173B8F]" />
        <span className="text-sm text-[#667386]">
          Cargando el alcance del proyecto...
        </span>
      </div>
    ) : !scopeVersion ||
      !scopeVersion.published_at ||
      !scopeVersion.document_path ? (
      <EmptyPanel
        icon={<FileText className="h-5 w-5" />}
        title="Todavía no hay un alcance publicado"
        description="Cuando el equipo de Modira publique el documento oficial del alcance, podrás consultarlo aquí."
      />
    ) : (
      <div className="space-y-5">
        {/* Estado del alcance */}
        <div className="rounded-2xl border border-[#E1E7EE] bg-white p-5 shadow-[0_4px_18px_rgba(24,42,69,0.025)] sm:p-6">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div className="flex items-start gap-3">
              <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-[#F1F4FA] text-[#173B8F]">
                <FileText className="h-5 w-5" />
              </div>

              <div>
                <h3 className="text-sm font-semibold text-[#243247]">
                  Documento oficial del alcance
                </h3>

                <p className="mt-1 text-xs leading-5 text-[#778396]">
                  Versión {scopeVersion.version_number}
                  {scopeVersion.published_at
                    ? ` · Publicado el ${new Date(
                        scopeVersion.published_at
                      ).toLocaleDateString("es-ES")}`
                    : ""}
                </p>
              </div>
            </div>

            <span
              className={[
                "inline-flex w-fit items-center rounded-full px-3 py-1.5 text-[11px] font-semibold",
                scopeVersion.status === "accepted"
                  ? "bg-emerald-50 text-emerald-700"
                  : scopeVersion.status === "changes_requested"
                    ? "bg-amber-50 text-amber-700"
                    : scopeVersion.status === "pending_client"
                      ? "bg-blue-50 text-blue-700"
                      : "bg-gray-100 text-gray-600",
              ].join(" ")}
            >
              {scopeVersion.status === "accepted"
                ? "Alcance aceptado"
                : scopeVersion.status === "changes_requested"
                  ? "Cambios solicitados"
                  : scopeVersion.status === "pending_client"
                    ? "Pendiente de revisión"
                    : scopeVersion.status}
            </span>
          </div>

          <div className="mt-5 border-t border-[#EEF1F4] pt-5">
            <p className="text-sm leading-6 text-[#667386]">
              Consulta el documento para conocer los objetivos,
              los trabajos incluidos y excluidos, los entregables,
              las condiciones y las responsabilidades acordadas
              para este proyecto.
            </p>

            <Button
  type="button"
  className="mt-4 bg-[#173B8F] text-white hover:bg-[#102A66]"
  onClick={async () => {
    if (!scopeVersion?.document_path) {
      toast.error("No hay un PDF oficial disponible.");
      return;
    }

    // Abrimos una ventana de forma síncrona para evitar
    // que el navegador bloquee la apertura del PDF.
    const pdfWindow = window.open("about:blank", "_blank");

    if (!pdfWindow) {
      toast.error(
        "El navegador ha bloqueado la apertura del PDF. Permite las ventanas emergentes e inténtalo de nuevo."
      );
      return;
    }

    pdfWindow.opener = null;

    try {
      const { data, error } = await supabase.storage
        .from("project-scope-documents")
        .createSignedUrl(scopeVersion.document_path, 600);

      if (error) {
        throw error;
      }

      if (!data?.signedUrl) {
        throw new Error(
          "No se ha podido generar el enlace al documento."
        );
      }

      // Cargamos el PDF en la ventana que acabamos de abrir.
      pdfWindow.location.href = data.signedUrl;

      // Solo después de generar correctamente la URL
      // permitimos marcar la casilla de lectura.
      sessionStorage.setItem(
  `project-scope-pdf-opened-${scopeVersion.id}`,
  "true"
);
setScopePdfOpened(true);
      setScopeAcknowledged(false);
    } catch (error: any) {
      pdfWindow.close();

      console.error(
        "[ClientProjects] Error abriendo el PDF del alcance:",
        error
      );

      toast.error(
        error?.message ||
          "No se ha podido abrir el documento del alcance."
      );
    }
  }}
>
  <ExternalLink className="mr-2 h-4 w-4" />
  {scopePdfOpened ? "Volver a abrir PDF oficial" : "Ver PDF oficial"}
</Button>
          </div>
        </div>

        {/* Aceptación del alcance */}
        {scopeVersion.status === "pending_client" && (
          <div className="rounded-2xl border border-[#DDE4EC] bg-white p-5 shadow-[0_4px_18px_rgba(24,42,69,0.025)] sm:p-6">
            <h3 className="text-sm font-semibold text-[#243247]">
              Revisión y aceptación
            </h3>

            <p className="mt-2 text-sm leading-6 text-[#667386]">
              Revisa el PDF oficial antes de aceptar el alcance.
              La aceptación quedará registrada para esta versión
              concreta del documento.
            </p>

          <label
  className={[
    "mt-5 flex items-start gap-3 rounded-xl border p-4 transition-colors",
    scopePdfOpened
      ? "cursor-pointer border-[#E1E7EE] bg-[#FAFBFD]"
      : "cursor-not-allowed border-[#E8ECF1] bg-[#F5F7FA] opacity-70",
  ].join(" ")}
>
  <input
    type="checkbox"
    checked={scopeAcknowledged}
    disabled={!scopePdfOpened || scopeSubmitting}
    onChange={(event) =>
      setScopeAcknowledged(event.target.checked)
    }
    className="mt-1 h-4 w-4 accent-[#173B8F] disabled:cursor-not-allowed"
  />

  <span className="text-sm leading-6 text-[#465469]">
    He leído el PDF oficial del alcance y acepto
    el contenido de esta versión.
    {!scopePdfOpened && (
      <span className="mt-1 block text-xs text-[#8792A2]">
        Primero debes abrir el PDF oficial para poder confirmar la lectura.
      </span>
    )}
  </span>
</label>

            <Button
              type="button"
             disabled={
  !scopePdfOpened ||
  !scopeAcknowledged ||
  scopeSubmitting
}
              className="mt-4 bg-[#173B8F] text-white hover:bg-[#102A66]"
              onClick={async () => {
  if (
    !scopePdfOpened ||
    !scopeAcknowledged ||
    scopeSubmitting ||
    !scopeVersion
  ) {
    return;
  }

  setScopeSubmitting(true);

  try {
                  // 1. Registrar la confirmación de lectura del PDF oficial.
const {
  data: acknowledgement,
  error: acknowledgementError,
} = await supabase.rpc(
  "record_project_scope_document_acknowledgement",
  {
    p_version_id: scopeVersion.id,
    p_user_agent: window.navigator.userAgent,
  }
);

if (acknowledgementError) {
  throw acknowledgementError;
}

if (!acknowledgement?.id) {
  throw new Error(
    "No se ha podido registrar la confirmación de lectura del documento."
  );
}

// 2. Aceptar el alcance después de registrar la confirmación.
// La función SQL comprobará que la confirmación corresponde
// a esta versión, usuario, empresa y documento.
const { error: acceptanceError } = await supabase.rpc(
  "accept_project_scope",
  {
    p_version_id: scopeVersion.id,
    p_acknowledged: true,
    p_user_agent: window.navigator.userAgent,
  }
);

if (acceptanceError) {
  throw acceptanceError;
}

                 setScopeVersion((current) =>
  current
    ? {
        ...current,
        status: "accepted",
      }
    : current
);

sessionStorage.removeItem(
  `project-scope-pdf-opened-${scopeVersion.id}`
);

setScopePdfOpened(false);
setScopeAcknowledged(false);

toast.success(
  "El alcance del proyecto se ha aceptado correctamente."
);
                } catch (error: any) {
                  console.error(
                    "[ClientProjects] Error aceptando el alcance:",
                    error
                  );

                  toast.error(
                    error?.message ||
                      "No se ha podido registrar la aceptación del alcance."
                  );
                } finally {
                  setScopeSubmitting(false);
                }
              }}
            >
              {scopeSubmitting ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : (
                <Check className="mr-2 h-4 w-4" />
              )}

              Aceptar alcance
            </Button>

            {/* Solicitud de cambios */}
            <div className="mt-7 border-t border-[#EEF1F4] pt-5">
              <h4 className="text-sm font-semibold text-[#243247]">
                ¿Necesitas modificar algún aspecto?
              </h4>

              <p className="mt-2 text-sm leading-6 text-[#667386]">
                Explica qué puntos del alcance deben revisarse.
                El equipo de Modira recibirá tu solicitud.
              </p>

              <textarea
                value={scopeComments}
                onChange={(event) =>
                  setScopeComments(event.target.value)
                }
                rows={4}
                maxLength={5000}
                placeholder="Describe los cambios que necesitas..."
                className="mt-4 w-full resize-y rounded-xl border border-[#DDE4EC] bg-white px-4 py-3 text-sm text-[#243247] outline-none transition focus:border-[#173B8F] focus:ring-2 focus:ring-[#173B8F]/10"
              />

              <p className="mt-1 text-right text-xs text-[#98A2B3]">
                {scopeComments.length}/5000 caracteres
              </p>

              <Button
                type="button"
                variant="outline"
                disabled={
                  scopeSubmitting ||
                  scopeComments.trim().length < 10 ||
                  scopeComments.trim().length > 5000
                }
                className="mt-3 border-[#DDE4EC] text-[#465469]"
                onClick={async () => {
                  if (
                    scopeSubmitting ||
                    scopeComments.trim().length < 10 ||
                    scopeComments.trim().length > 5000
                  ) {
                    return;
                  }

                  setScopeSubmitting(true);

                  try {
                    const { error } = await supabase.rpc(
                      "request_project_scope_changes",
                      {
                        p_version_id: scopeVersion.id,
                        p_comments: scopeComments.trim(),
                        p_user_agent: window.navigator.userAgent,
                      }
                    );

                    if (error) {
                      throw error;
                    }

                    setScopeVersion((current) =>
                      current
                        ? {
                            ...current,
                            status: "changes_requested",
                          }
                        : current
                    );
  setScopeComments("");
sessionStorage.removeItem(
  `project-scope-pdf-opened-${scopeVersion.id}`
);
setScopePdfOpened(false);
setScopeAcknowledged(false);
                    toast.success(
                      "Tu solicitud de cambios se ha enviado correctamente."
                    );
                  } catch (error: any) {
                    console.error(
                      "[ClientProjects] Error solicitando cambios en el alcance:",
                      error
                    );

                    toast.error(
                      error?.message ||
                        "No se ha podido enviar la solicitud de cambios."
                    );
                  } finally {
                    setScopeSubmitting(false);
                  }
                }}
              >
                Solicitar cambios
              </Button>
            </div>
          </div>
        )}

        {/* Estado cuando el cliente ya ha aceptado */}
        {scopeVersion.status === "accepted" && (
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50/60 p-5 sm:p-6">
            <div className="flex items-start gap-3">
              <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-emerald-100 text-emerald-700">
                <Check className="h-5 w-5" />
              </div>

              <div>
                <h3 className="text-sm font-semibold text-emerald-800">
                  Alcance aceptado
                </h3>

                <p className="mt-1 text-sm leading-6 text-emerald-800/80">
                  Esta versión del alcance ya ha sido aceptada.
                  Puedes volver a consultar el PDF oficial cuando
                  lo necesites.
                </p>
              </div>
            </div>
          </div>
        )}

        {/* Estado cuando ya se han solicitado cambios */}
        {scopeVersion.status === "changes_requested" && (
          <div className="rounded-2xl border border-amber-200 bg-amber-50/60 p-5 sm:p-6">
            <h3 className="text-sm font-semibold text-amber-800">
              Solicitud de cambios enviada
            </h3>

            <p className="mt-1 text-sm leading-6 text-amber-800/80">
              El equipo de Modira debe revisar los cambios solicitados.
              Cuando publique una nueva versión del alcance, podrás
              consultar el nuevo documento y revisarlo.
            </p>
          </div>
        )}
      </div>
    )}
  </section>
)}
      {activeSection === "novedades" && (
        <section>
          <SectionTitle
            eyebrow="Comunicación"
            title="Novedades"
            action={
              <span className="text-[10px] text-[#98A2B3]">
                {updates.length}{" "}
                {updates.length === 1 ? "actualización" : "actualizaciones"}
              </span>
            }
          />

          {updates.length === 0 ? (
            <EmptyPanel
              icon={<MessageSquare className="h-5 w-5" />}
              title="No hay novedades publicadas"
              description="Las novedades que el equipo publique para ti aparecerán aquí."
            />
          ) : (
            <div className="overflow-hidden rounded-2xl border border-[#E1E7EE] bg-white shadow-[0_4px_18px_rgba(24,42,69,0.025)]">
              <div className="divide-y divide-[#EEF1F4]">
                {updates.map((update, index) => (
                  <article
                    key={update.id}
                    className="group px-5 py-5 transition-colors hover:bg-[#FBFCFE] sm:px-6 sm:py-6"
                  >
                    <div className="flex items-start gap-4">
                      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-[#F2F5F9] text-[#173B8F]">
                        <MessageSquare
                          className="h-4 w-4"
                          strokeWidth={1.65}
                        />
                      </div>

                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
                          <p className="text-[9px] font-semibold uppercase tracking-[0.15em] text-[#8A95A5]">
                            Actualización{" "}
                            {String(index + 1).padStart(2, "0")}
                          </p>

                          <time className="text-[10px] font-medium text-[#98A2B3]">
                            {formatCompactDate(update.created_at)}
                          </time>
                        </div>

                        <h3 className="mt-1.5 text-[14px] font-semibold tracking-tight text-[#26364D] sm:text-[15px]">
                          {update.titulo}
                        </h3>

                        <p className="mt-2.5 whitespace-pre-wrap text-[12px] leading-6 text-[#718096]">
                          {update.contenido}
                        </p>
                      </div>
                    </div>
                  </article>
                ))}
              </div>
            </div>
          )}
        </section>
      )}

      {/* ============================================================
          DOCUMENTOS
          ============================================================ */}
      {activeSection === "documentos" && (
        <section>
          <SectionTitle
            eyebrow="Archivos"
            title="Documentos del proyecto"
            action={
              <span className="text-[10px] text-[#98A2B3]">
                {documents.length}{" "}
                {documents.length === 1 ? "documento" : "documentos"}
              </span>
            }
          />

          {documents.length === 0 ? (
            <EmptyPanel
              icon={<FileText className="h-5 w-5" />}
              title="No hay documentos"
              description="Los documentos asociados al proyecto aparecerán aquí."
            />
          ) : (
            <div className="overflow-hidden rounded-2xl border border-[#E1E7EE] bg-white shadow-[0_4px_18px_rgba(24,42,69,0.025)]">
              <div className="divide-y divide-[#EEF1F4]">
                {documents.map((document) => (
                  <div
                    key={document.id}
                    className="group flex flex-col gap-4 px-5 py-4 transition-colors hover:bg-[#FBFCFE] sm:flex-row sm:items-center sm:px-6"
                  >
                    <div className="flex min-w-0 flex-1 items-center gap-3.5">
                      <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-[#F3F5F8] text-[#173B8F]">
                        <FileText
                          className="h-4 w-4"
                          strokeWidth={1.65}
                        />
                      </div>

                      <div className="min-w-0">
                        <p className="truncate text-[12px] font-semibold text-[#34445A]">
                          {document.file_name}
                        </p>

                        <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[9px] text-[#98A2B3]">
                          <span>
                            {formatFileSize(document.file_size)}
                          </span>

                          <span className="hidden h-3 w-px bg-[#E2E7EC] sm:block" />

                          <span>
                            {formatCompactDate(document.created_at)}
                          </span>
                        </div>
                      </div>
                    </div>

                    <button
                      type="button"
                      onClick={() => onOpenProjectDocument(document)}
                      className="inline-flex shrink-0 items-center justify-center gap-1.5 rounded-lg border border-[#DCE2E9] bg-white px-3.5 py-2 text-[10px] font-semibold text-[#173B8F] transition-colors hover:border-[#C8D2DE] hover:bg-[#F7F9FB]"
                    >
                      Abrir documento
                      <ArrowRight
                        className="h-3 w-3"
                        strokeWidth={1.8}
                      />
                    </button>
                  </div>
                ))}
              </div>
            </div>
          )}
        </section>
      )}

      {/* ============================================================
          SOLICITUDES DE CAMBIO
          ============================================================ */}
      {activeSection === "cambios" && (
        <section>
          <SectionTitle
            eyebrow="Gestión"
            title="Solicitudes de cambio"
            action={
              <button
                type="button"
                onClick={onOpenChangeRequest}
                className="inline-flex items-center gap-1.5 rounded-lg bg-[#173B8F] px-3.5 py-2 text-[10px] font-semibold text-white transition-colors hover:bg-[#102A66]"
              >
                Solicitar un cambio
                <ArrowRight
                  className="h-3 w-3"
                  strokeWidth={1.8}
                />
              </button>
            }
          />

          {changeRequests.length === 0 ? (
            <EmptyPanel
              icon={<MessageSquare className="h-5 w-5" />}
              title="No hay solicitudes de cambio"
              description="Puedes solicitar un cambio relacionado con este proyecto cuando lo necesites."
            />
          ) : (
            <div className="space-y-3">
              {changeRequests.map((request) => {
                const status = normalize(request.status);

                return (
                  <article
                    key={request.id}
                    className="rounded-2xl border border-[#E1E7EE] bg-white px-5 py-5 shadow-[0_4px_18px_rgba(24,42,69,0.025)] sm:px-6 sm:py-6"
                  >
                    <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <p className="text-[12px] font-semibold text-[#34445A]">
                            Solicitud de cambio
                          </p>

                          <span
                            className={[
                              "rounded-full border px-2.5 py-1 text-[9px] font-semibold",
                              changeRequestClasses(request.status),
                            ].join(" ")}
                          >
                            {statusLabel(request.status)}
                          </span>
                        </div>

                        <p className="mt-2 whitespace-pre-wrap text-[12px] leading-5 text-[#718096]">
                          {request.description}
                        </p>
                      </div>

                      <div className="shrink-0 text-left sm:text-right">
                        <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                          Solicitud
                        </p>
                        <p className="mt-1 text-[10px] font-medium text-[#445166]">
                          {formatCompactDate(request.created_at)}
                        </p>
                      </div>
                    </div>

                    {request.review_notes && (
                      <div className="mt-5 border-t border-[#EEF1F4] pt-4">
                        <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                          Respuesta de Modira
                        </p>

                        <p className="mt-1.5 whitespace-pre-wrap text-[11px] leading-5 text-[#718096]">
                          {request.review_notes}
                        </p>
                      </div>
                    )}

                    {status === "pending" && (
                      <div className="mt-4 flex items-center gap-2 border-t border-[#EEF1F4] pt-4 text-[10px] text-[#98A2B3]">
                        <Clock3
                          className="h-3.5 w-3.5"
                          strokeWidth={1.7}
                        />
                        Pendiente de revisión
                      </div>
                    )}
                  </article>
                );
              })}
            </div>
          )}

          {pendingChangeRequests > 0 && (
            <p className="mt-3 text-[10px] text-[#98A2B3]">
              {pendingChangeRequests}{" "}
              {pendingChangeRequests === 1
                ? "solicitud requiere"
                : "solicitudes requieren"}{" "}
              seguimiento.
            </p>
          )}
        </section>
      )}

      {/* ============================================================
          PRESUPUESTOS VINCULADOS
          ============================================================ */}
      {activeSection === "presupuestos" && (
        <section>
          <SectionTitle
            eyebrow="Propuesta económica"
            title="Presupuestos vinculados"
            action={
              <span className="text-[10px] text-[#98A2B3]">
                {quotations.length}{" "}
                {quotations.length === 1 ? "presupuesto" : "presupuestos"}
              </span>
            }
          />

          {quotations.length === 0 ? (
            <EmptyPanel
              icon={<FileText className="h-5 w-5" />}
              title="No hay presupuestos vinculados"
              description="Los presupuestos asociados específicamente a este proyecto aparecerán aquí."
            />
          ) : (
            <div className="space-y-3">
              {quotations.map((quotation) => {
                const quotationStatus = normalize(quotation.estado);

               const serviceCount = getServiceCount(
  quotation.servicios_incluidos,
); 
const quotationServices = getQuotationServices(
  quotation.servicios_incluidos,
);

                return (
                  <article
                    key={quotation.id}
                    className="overflow-hidden rounded-2xl border border-[#E1E7EE] bg-white shadow-[0_4px_18px_rgba(24,42,69,0.025)]"
                  >
                    <div className="px-5 py-5 sm:px-6 sm:py-6">
  <div className="flex flex-col gap-6 lg:flex-row lg:items-start lg:justify-between">

    {/* INFORMACIÓN */}
    <div className="min-w-0 flex-1">

      {/* CABECERA */}
      <div className="flex flex-wrap items-center gap-2.5">
        <span className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8A95A5]">
          {quotation.numero_presupuesto}
        </span>

        <span
          className={[
            "rounded-full border px-2.5 py-1 text-[9px] font-semibold",
            projectStatusClasses(quotation.estado),
          ].join(" ")}
        >
          {statusLabel(quotation.estado)}
        </span>

        {quotation.quotation_version && (
          <span className="text-[9px] text-[#A0A9B6]">
            v{quotation.quotation_version}
          </span>
        )}
      </div>

      {/* TÍTULO */}
      <h3 className="mt-3 text-[16px] font-semibold tracking-tight text-[#26364D]">
        {quotation.titulo || "Presupuesto"}
      </h3>

      {/* DESCRIPCIÓN */}
      {quotation.descripcion_detallada && (
        <div className="mt-4">
          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
            Descripción
          </p>

          <p className="mt-1.5 max-w-4xl whitespace-pre-line text-[11px] leading-5 text-[#718096]">
            {quotation.descripcion_detallada}
          </p>
        </div>
      )}

      {/* SERVICIOS */}
      <div className="mt-5">
        <div className="flex items-center gap-2">
          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
            Servicios incluidos
          </p>

          <span className="rounded-full bg-[#F1F4F8] px-2 py-0.5 text-[9px] font-semibold text-[#687588]">
            {quotationServices.length}
          </span>
        </div>

        {quotationServices.length > 0 ? (
          <div className="mt-3 space-y-2.5">
            {quotationServices.map((service, index) => {
              const quantity = Number(service.cantidad || 0);
              const unitPrice = Number(service.precio || 0);
              const serviceTotal = quantity * unitPrice;

              return (
                <div
                  key={index}
                  className="flex flex-col gap-2 rounded-xl border border-[#EEF1F4] bg-[#FAFBFD] px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div className="min-w-0">
                    <p className="text-[11px] font-semibold text-[#34445A]">
                      {service.descripcion || "Servicio"}
                    </p>

                    <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-[10px] text-[#7A8595]">
                      <span>
                        Cantidad: {quantity}
                      </span>

                      <span>
                        Precio unitario:{" "}
                        {formatCurrency(unitPrice)}
                      </span>
                    </div>
                  </div>

                  <span className="shrink-0 text-[11px] font-semibold text-[#26364D]">
                    {formatCurrency(serviceTotal)}
                  </span>
                </div>
              );
            })}
          </div>
        ) : (
          <p className="mt-2 text-[10px] text-[#98A2B3]">
            No hay servicios incluidos.
          </p>
        )}
      </div>

      {/* DATOS ECONÓMICOS */}
      <div className="mt-5 flex flex-wrap gap-x-7 gap-y-3 border-t border-[#EEF1F4] pt-4">

        <div>
          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
            Emisión
          </p>

          <p className="mt-1 text-[11px] font-medium text-[#445166]">
            {formatCompactDate(quotation.fecha_emision)}
          </p>
        </div>

        <div>
          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
            Validez
          </p>

          <p className="mt-1 text-[11px] font-medium text-[#445166]">
            {formatCompactDate(quotation.fecha_validez)}
          </p>
        </div>

        <div>
          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
            Base imponible
          </p>

          <p className="mt-1 text-[11px] font-medium text-[#445166]">
            {formatCurrency(quotation.precio_base)}
          </p>
        </div>

        <div>
          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
            IVA
          </p>

          <p className="mt-1 text-[11px] font-medium text-[#445166]">
            {quotation.iva_porcentaje ?? 0}%
          </p>
        </div>

        <div>
          <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
            Total
          </p>

          <p className="mt-1 text-[11px] font-semibold text-[#26364D]">
            {formatCurrency(quotation.precio_total)}
          </p>
        </div>
      </div>
    </div>

    {/* ACCIONES */}
    <div className="flex shrink-0 flex-wrap gap-2 lg:max-w-[220px] lg:justify-end">

      <button
        type="button"
        onClick={() =>
          setLocation("/area-cliente/presupuestos")
        }
        className="inline-flex items-center gap-1.5 rounded-lg border border-[#DCE2E9] bg-white px-3.5 py-2 text-[10px] font-semibold text-[#173B8F] transition-colors hover:border-[#C8D2DE] hover:bg-[#F7F9FB]"
      >
        Ir a presupuestos
        <ArrowRight
          className="h-3 w-3"
          strokeWidth={1.8}
        />
      </button>

      

    </div>
  </div>
</div>
                  </article>
                );
              })}
            </div>
          )}
        </section>
      )}

      {/* ============================================================
          FACTURAS
          ============================================================ */}
      {activeSection === "facturas" && (
        <section>
          <SectionTitle
            eyebrow="Facturación"
            title="Facturas vinculadas"
            action={
              <span className="text-[10px] text-[#98A2B3]">
                {formatCurrency(totalInvoiced)} facturado
              </span>
            }
          />

          {invoices.length === 0 ? (
            <EmptyPanel
              icon={<Receipt className="h-5 w-5" />}
              title="No hay facturas vinculadas"
              description="Las facturas asociadas específicamente a este proyecto aparecerán aquí."
            />
          ) : (
            <div className="space-y-3">
              {invoices.map((invoice) => {
                const invoicePayments = projectPayments.filter(
                  (payment) => payment.invoice_id === invoice.id,
                );

                const paid =
                  normalize(invoice.estado) === "pagada" ||
                  invoicePayments.some(
                    (payment) =>
                      normalize(payment.status) === "succeeded",
                  );

                const invoiceAmount = Number(
                  invoice.importe_a_pagar ?? invoice.monto ?? 0,
                );
                const linkedQuotation = invoice.quotation_id
  ? quotations.find(
      (quotation) =>
        quotation.id === invoice.quotation_id,
    )
  : undefined;

const invoiceServices = linkedQuotation
  ? getQuotationServices(
      linkedQuotation.servicios_incluidos,
    )
  : [];
const serviceQuantity = getInvoiceServiceQuantity(
  invoice.descripcion,
);
                const paidAmount = invoicePayments
                  .filter(
                    (payment) =>
                      normalize(payment.status) === "succeeded",
                  )
                  .reduce(
                    (sum, payment) =>
                      sum + Number(payment.amount || 0) / 100,
                    0,
                  );

                return (
                  <article
                    key={invoice.id}
                    className="overflow-hidden rounded-2xl border border-[#E1E7EE] bg-white shadow-[0_4px_18px_rgba(24,42,69,0.025)]"
                  >
                    <div className="px-5 py-5 sm:px-6 sm:py-6">
                      <div className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-center gap-2.5">
                            <span className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8A95A5]">
                              {invoice.numero_factura}
                            </span>

                            <span
                              className={[
                                "rounded-full border px-2.5 py-1 text-[9px] font-semibold",
                                paid
                                  ? "border-[#CDE8D8] bg-[#ECF8F1] text-[#247A49]"
                                  : invoice.estado === "vencida"
                                    ? "border-[#F0D0D0] bg-[#FFF0F0] text-[#B53A3A]"
                                    : "border-[#D8E1F5] bg-[#EEF3FF] text-[#173B8F]",
                              ].join(" ")}
                            >
                              {paid
                                ? "Pagada"
                                : statusLabel(invoice.estado)}
                            </span>
                          </div>
<div className="mt-5">
  <div className="flex items-center gap-2">
    <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
      Servicios facturados
    </p>

    <span className="rounded-full bg-[#F1F4F8] px-2 py-0.5 text-[9px] font-semibold text-[#687588]">
      {invoiceServices.length}
    </span>
  </div>

  {invoiceServices.length > 0 ? (
    <div className="mt-3 space-y-2.5">
      {invoiceServices.map((service, index) => {
        const quantity = Number(service.cantidad || 0);
        const unitPrice = Number(service.precio || 0);
        const serviceTotal = quantity * unitPrice;

        return (
          <div
            key={index}
            className="flex flex-col gap-2 rounded-xl border border-[#EEF1F4] bg-[#FAFBFD] px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
          >
            <div className="min-w-0">
              <p className="text-[11px] font-semibold text-[#34445A]">
                {service.descripcion || "Servicio"}
              </p>

              <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-[10px] text-[#7A8595]">
                <span>
                  Cantidad: {quantity}
                </span>

                <span>
                  Precio unitario:{" "}
                  {formatCurrency(unitPrice)}
                </span>
              </div>
            </div>

            <span className="shrink-0 text-[11px] font-semibold text-[#26364D]">
              {formatCurrency(serviceTotal)}
            </span>
          </div>
        );
      })}
    </div>
  ) : (
    <p className="mt-2 text-[10px] text-[#98A2B3]">
      No hay servicios estructurados asociados a esta factura.
    </p>
  )}
</div>
                          <h3 className="mt-3 text-[16px] font-semibold tracking-tight text-[#26364D]">
  {linkedQuotation?.titulo || "Factura"}
</h3>

{linkedQuotation?.descripcion_detallada ? (
  <div className="mt-4">
    <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
      Descripción
    </p>

    <p className="mt-1.5 max-w-4xl whitespace-pre-line text-[11px] leading-5 text-[#718096]">
      {linkedQuotation.descripcion_detallada}
    </p>
  </div>
) : invoice.descripcion ? (
  <div className="mt-4">
    <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
      Descripción
    </p>

    <p className="mt-1.5 max-w-4xl whitespace-pre-line text-[11px] leading-5 text-[#718096]">
      {invoice.descripcion}
    </p>
  </div>
) : null}

                          <div className="mt-5 flex flex-wrap gap-x-7 gap-y-3 border-t border-[#EEF1F4] pt-4">

  <div>
    <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
      Emisión
    </p>

    <p className="mt-1 text-[11px] font-medium text-[#445166]">
      {formatCompactDate(invoice.fecha_emision)}
    </p>
  </div>

  <div>
    <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
      Vencimiento
    </p>

    <p className="mt-1 text-[11px] font-medium text-[#445166]">
      {formatCompactDate(invoice.fecha_vencimiento)}
    </p>
  </div>

  <div>
    <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
      Base imponible
    </p>

    <p className="mt-1 text-[11px] font-medium text-[#445166]">
      {formatCurrency(invoice.subtotal)}
    </p>
  </div>

  <div>
    <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
      IVA
    </p>

    <p className="mt-1 text-[11px] font-medium text-[#445166]">
      {invoice.iva_aplicado
        ? `${invoice.iva_porcentaje ?? 0}%`
        : "No aplicado"}
    </p>
  </div>

  <div>
    <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
      Importe
    </p>

    <p className="mt-1 text-[11px] font-semibold text-[#26364D]">
      {formatCurrency(invoiceAmount)}
    </p>
  </div>

  {paidAmount > 0 && (
    <div>
      <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
        Pagado
      </p>

      <p className="mt-1 text-[11px] font-medium text-[#247A49]">
        {formatCurrency(paidAmount)}
      </p>
    </div>
  )}
</div>
                        </div>
<button
  type="button"
  onClick={() =>
    setLocation("/area-cliente/facturacion")
  }
  className="inline-flex shrink-0 items-center justify-center gap-1.5 rounded-lg border border-[#DCE2E9] bg-white px-3.5 py-2 text-[10px] font-semibold text-[#173B8F] transition-colors hover:border-[#C8D2DE] hover:bg-[#F7F9FB]"
>
  Ir a facturación
  <ArrowRight
    className="h-3 w-3"
    strokeWidth={1.8}
  />
</button>
                        {invoice.document_path && (
                          <button
                            type="button"
                            onClick={() =>
                              onOpenInvoiceDocument(invoice)
                            }
                            className="inline-flex shrink-0 items-center justify-center gap-1.5 rounded-lg border border-[#DCE2E9] bg-white px-3.5 py-2 text-[10px] font-semibold text-[#173B8F] transition-colors hover:border-[#C8D2DE] hover:bg-[#F7F9FB]"
                          >
                            Ver factura
                            <ArrowRight
                              className="h-3 w-3"
                              strokeWidth={1.8}
                            />
                          </button>
                        )}
                      </div>
                    </div>
                  </article>
                );
              })}
            </div>
          )}

          {invoices.length > 0 && totalPaid > 0 && (
            <div className="mt-4 flex items-center justify-between border-t border-[#EEF1F4] pt-4">
              <span className="text-[10px] text-[#98A2B3]">
                Total recibido
              </span>

              <span className="text-[12px] font-semibold text-[#247A49]">
                {formatCurrency(totalPaid)}
              </span>
            </div>
          )}
        </section>
      )}
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
  const completedCount = ordered.filter((milestone) => milestone.estado === "completado").length;
const [selectedMilestone, setSelectedMilestone] =
  useState<Milestone | null>(null);
  const accent =
    project.estado === "Pausado"
      ? {
          solid: "#F59E0B",
          soft: "#FFF7E8",
          text: "#A56A00",
        }
      : project.estado === "Entregado"
        ? {
            solid: "#4B3E57",
            soft: "#F3F1F8",
            text: "#4B3E57",
          }
        : project.estado === "Completado"
          ? {
              solid: "#247A49",
              soft: "#ECF8F1",
              text: "#247A49",
            }
          : project.estado === "Activo"
            ? {
                solid: "#22C55E",
                soft: "#ECF8F1",
                text: "#247A49",
              }
            : {
                solid: "#F59E0B",
                soft: "#FFF7E8",
                text: "#A56A00",
              };

  return (

<section className="overflow-hidden">
    <div className="px-5 py-6 sm:px-7 sm:py-7">
    {/* Cabecera */}
    <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
     

      {/* Fechas del proyecto */}
      <div className="flex items-center gap-2 text-right">
  <span className="text-[12px] font-medium text-[#667386] sm:text-[12px]">
    {formatCompactDate(project.fecha_inicio)}
  </span>

  <span className="text-[12px] text-[#AAB3BF] sm:text-[13px]">
    -
  </span>

  <span className="text-[12px] font-medium text-[#667386] sm:text-[12px]">
    {formatCompactDate(project.fecha_fin)}
  </span>
</div>
    </div>

    {!ordered.length ? (
      <div className="px-0 py-10 text-center">
        <span className="mx-auto flex h-11 w-11 items-center justify-center rounded-full bg-[#F5F7FA] text-[#AAB3BF]">
          <CalendarDays className="h-5 w-5" strokeWidth={1.6} />
        </span>

        <p className="mt-3 text-[12px] font-semibold text-[#667386]">
          Todavía no hay hitos definidos
        </p>

        <p className="mx-auto mt-1.5 max-w-md text-[11px] leading-5 text-[#98A2B3]">
          Los hitos aparecerán aquí cuando el equipo de Modira los configure.
        </p>
      </div>
    ) : (
      <div className="pt-9 sm:pt-10">
        {/* Timeline horizontal */}
        <div className="relative">
          {/* Línea base */}
          {ordered.length > 1 && (
            <div
              aria-hidden="true"
              className="absolute left-[23px] right-[23px] top-[22px] h-[3px] rounded-full bg-[#E8ECF1] sm:left-[24px] sm:right-[24px]"
            >
              {/* Tramo completado */}
              <div
                className="h-full rounded-full transition-all duration-500"
                style={{
                  width:
                    ordered.length > 1
                      ? `${Math.min(
                          100,
                          (Math.max(completedCount - 1, 0) /
                            (ordered.length - 1)) *
                            100
                        )}%`
                      : "0%",
                  backgroundColor: accent.solid,
                }}
              />
            </div>
          )}

          {/* Círculos de los hitos */}
          <div
            className={[
              "relative flex justify-between",
              ordered.length === 1 ? "justify-center" : "",
            ].join(" ")}
          >
            {ordered.map((milestone, index) => {
              const completed = milestone.estado === "completado";
              const current = milestone.estado === "en_curso";

              return (
                <div
  key={milestone.id}
  className={[
    "relative flex min-w-0 flex-1 flex-col items-center",
    "max-w-[clamp(95px,14vw,190px)]",
    ordered.length === 1 ? "max-w-xs" : "",
  ].join(" ")}
>
                  {/* Círculo */}
                  <div className="relative z-10 flex h-[46px] w-[46px] items-center justify-center">
                    {completed ? (
                      <span
                        className="flex h-[46px] w-[46px] items-center justify-center rounded-full border-[4px] border-white text-white shadow-[0_2px_10px_rgba(24,42,69,0.12)]"
                        style={{
                          backgroundColor: accent.solid,
                        }}
                      >
                        <Check
                          className="h-[17px] w-[17px]"
                          strokeWidth={2.8}
                        />
                      </span>
                    ) : current ? (
                      <span
                        className="relative flex h-[46px] w-[46px] items-center justify-center rounded-full border-[3px] bg-white shadow-[0_2px_10px_rgba(24,42,69,0.08)]"
                        style={{
                          borderColor: accent.solid,
                        }}
                      >
                        <span
                          className="h-[12px] w-[12px] rounded-full"
                          style={{
                            backgroundColor: accent.solid,
                          }}
                        />
                      </span>
                    ) : (
                      <span className="flex h-[46px] w-[46px] items-center justify-center rounded-full border-[2px] border-[#D5DCE5] bg-white text-[11px] font-semibold text-[#8A95A5] shadow-[0_2px_8px_rgba(24,42,69,0.04)]">
                        {index + 1}
                      </span>
                    )}
                  </div>

                  {/* Información del hito */}
                  <div className="mt-4 w-full px-1 text-center">
                    <div className="flex flex-col items-center">
                      <h3
                        className={[
                          "max-w-[170px] text-[12px] font-semibold leading-5 tracking-tight sm:max-w-[190px] sm:text-[13px]",
                          completed || current
                            ? "text-[#26364D]"
                            : "text-[#697587]",
                        ].join(" ")}
                      >
                        {milestone.nombre}
                      </h3>

                      <div className="mt-2 flex items-center justify-center gap-1.5">
                        <CalendarDays
                          className="h-3 w-3 shrink-0 text-[#A1AAB7]"
                          strokeWidth={1.7}
                        />

                        <span className="text-[9px] font-medium text-[#8994A4] sm:text-[10px]">
                          {formatCompactDate(milestone.fecha_prevista)}
                        </span>
                      </div>

                      {milestone.descripcion && (
  <div className="mt-2 hidden w-full max-w-[clamp(95px,14vw,190px)] sm:block">
    <p className="break-all line-clamp-2 text-[10px] leading-4 text-[#8994A4]">
      {milestone.descripcion}
    </p>

    <button
      type="button"
      onClick={() => setSelectedMilestone(milestone)}
      className="mt-1 text-[9px] font-semibold text-[#173B8F] transition-colors hover:text-[#102A66] hover:underline"
    >
      Ver más
    </button>
  </div>
)}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        {/* Descripciones en móvil */}
        <div className="mt-7 space-y-3 border-t border-[#EEF1F4] pt-5 sm:hidden">
          {ordered.map((milestone, index) => {
            const completed = milestone.estado === "completado";
            const current = milestone.estado === "en_curso";

            return (
              <div
                key={milestone.id}
                className="rounded-xl border border-[#EEF1F4] bg-[#FAFBFC] px-3.5 py-3"
              >
                <div className="flex items-start gap-3">
                  <span
                    className={[
                      "flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[9px] font-semibold",
                      completed
                        ? "text-white"
                        : current
                          ? "border-2 bg-white"
                          : "border border-[#D5DCE5] bg-white text-[#8A95A5]",
                    ].join(" ")}
                    style={
                      completed
                        ? { backgroundColor: accent.solid }
                        : current
                          ? {
                              borderColor: accent.solid,
                              color: accent.solid,
                            }
                          : undefined
                    }
                  >
                    {completed ? (
                      <Check className="h-3 w-3" strokeWidth={2.8} />
                    ) : (
                      index + 1
                    )}
                  </span>

                  <div className="min-w-0">
                    <p className="text-[11px] font-semibold text-[#34445A]">
                      {milestone.nombre}
                    </p>

                    {milestone.descripcion && (
  <div className="mt-1">
    <p className="break-words line-clamp-3 text-[10px] leading-4 text-[#8994A4]">
      {milestone.descripcion}
    </p>

    <button
      type="button"
      onClick={() => setSelectedMilestone(milestone)}
      className="mt-1 text-[9px] font-semibold text-[#173B8F] hover:text-[#102A66] hover:underline"
    >
      Ver más
    </button>
  </div>
)}

                    {milestone.fecha_prevista && (
                      <div className="mt-1.5 flex items-center gap-1.5">
                        <CalendarDays
                          className="h-3 w-3 text-[#A1AAB7]"
                          strokeWidth={1.7}
                        />

                        <span className="text-[9px] font-medium text-[#8994A4]">
                          {formatCompactDate(milestone.fecha_prevista)}
                        </span>
                      </div>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    )}
  </div>
        {selectedMilestone && (
        <div
          className="fixed inset-0 z-[100] flex items-center justify-center bg-[#182230]/35 px-4 py-6 backdrop-blur-[2px]"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) {
              setSelectedMilestone(null);
            }
          }}
        >
          <div className="max-h-[85vh] w-full max-w-lg overflow-y-auto rounded-2xl border border-[#E1E7EE] bg-white shadow-[0_18px_60px_rgba(24,42,69,0.18)]">

            {/* CABECERA */}
            <div className="flex items-start justify-between border-b border-[#EEF1F4] px-6 py-5">
              <div className="min-w-0 pr-4">
                <p className="text-[9px] font-semibold uppercase tracking-[0.16em] text-[#7C8797]">
                  Detalle del hito
                </p>

                <h3 className="mt-1.5 text-[18px] font-semibold tracking-tight text-[#26364D]">
                  {selectedMilestone.nombre}
                </h3>
              </div>

              <button
                type="button"
                onClick={() => setSelectedMilestone(null)}
                className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-[#8A95A5] transition-colors hover:bg-[#F4F6F9] hover:text-[#26364D]"
                aria-label="Cerrar"
              >
                <X className="h-4 w-4" strokeWidth={2} />
              </button>
            </div>

            {/* CONTENIDO */}
            <div className="space-y-5 px-6 py-6">

              {/* FECHA */}
              <div>
                <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                  Fecha prevista
                </p>

                <div className="mt-1.5 flex items-center gap-2">
                  <CalendarDays
                    className="h-3.5 w-3.5 text-[#8A95A5]"
                    strokeWidth={1.7}
                  />

                  <span className="text-[12px] font-medium text-[#445166]">
                    {formatCompactDate(
                      selectedMilestone.fecha_prevista,
                    )}
                  </span>
                </div>
              </div>

              {/* ESTADO */}
              <div>
                <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                  Estado
                </p>

                <div className="mt-1.5">
                  <span
                    className="inline-flex rounded-full px-2.5 py-1 text-[10px] font-semibold"
                    style={{
                      backgroundColor: accent.soft,
                      color: accent.text,
                    }}
                  >
                    {selectedMilestone.estado === "completado"
                      ? "Completado"
                      : selectedMilestone.estado === "en_curso"
                        ? "En curso"
                        : "Pendiente"}
                  </span>
                </div>
              </div>

              {/* DESCRIPCIÓN */}
              <div>
                <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                  Descripción
                </p>

                <div className="mt-2 rounded-xl border border-[#EEF1F4] bg-[#FAFBFC] px-4 py-4">
                  <p className="whitespace-pre-wrap break-words text-[11px] leading-5 text-[#667386]">
                    {selectedMilestone.descripcion ||
                      "Este hito no tiene una descripción."}
                  </p>
                </div>
              </div>
            </div>

            {/* PIE */}
            <div className="flex justify-end border-t border-[#EEF1F4] bg-[#FAFBFD] px-6 py-4">
              <button
                type="button"
                onClick={() => setSelectedMilestone(null)}
                className="rounded-lg bg-[#173B8F] px-4 py-2 text-[10px] font-semibold text-white transition-colors hover:bg-[#102A66]"
              >
                Cerrar
              </button>
            </div>
          </div>
        </div>
      )}
</section>

 );
}

function ProjectProgressRing({
  percentage,
  status,
  compact = false,
}: {
  percentage: number;
  status: ProjectStatus;
  compact?: boolean;
}) {
  const value = Math.max(0, Math.min(100, Math.round(percentage)));
  const radius = 48;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference - (value / 100) * circumference;

  // El color se aplica directamente al SVG para que el anillo conserve
  // siempre el color del estado aunque Tailwind purgue clases dinámicas.
  const tone =
    status === "Activo"
      ? "#22C55E"
      : status === "Pendiente"
        ? "#F59E0B"
        : status === "Pausado"
          ? "#F59E0B"
          : status === "Entregado"
            ? "#4B3E57"
            : "#247A49";

  const sizeClass = compact ? "h-[56px] w-[56px]" : "h-28 w-28";
  const valueClass = compact
    ? "text-[12px] font-bold tracking-tight"
    : "text-2xl font-semibold tracking-tight sm:text-3xl";

  return (
    <div className={`relative ${sizeClass} shrink-0`} style={{ color: tone }}>
      <svg
        viewBox="0 0 120 120"
        className="h-full w-full -rotate-90"
        role="img"
        aria-label={`${value}% de progreso`}
      >
        <circle
          cx="60"
          cy="60"
          r={radius}
          fill="none"
          stroke="#E5E9EF"
          strokeWidth={compact ? "5" : "6"}
        />
        <circle
          cx="60"
          cy="60"
          r={radius}
          fill="none"
          stroke={tone}
          strokeWidth={compact ? "5" : "6"}
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={offset}
          className="transition-all duration-700 ease-out"
        />
      </svg>

      <div className="absolute inset-0 flex items-center justify-center">
        <span className={valueClass} style={{ color: tone }}>
          {value}%
        </span>
      </div>
    </div>
  );
}

function projectProgressBarClass(status: ProjectStatus) {
  switch (status) {
    case "Activo":
      return "bg-[#22C55E]";
    case "Pendiente":
      return "bg-[#F59E0B]";
    case "Entregado":
      return "bg-[#7A8595]";
    case "Completado":
      return "bg-[#4B3E57]";
    case "Pausado":
      return "bg-[#F59E0B]";
    default:
      return "bg-[#173B8F]";
  }
}

function ChangeRequestPreviewBadge({
  request,
}: {
  request: ProjectChangeRequest | null;
}) {
  if (!request) {
    return (
      <span className="text-[10px] text-[#98A2B3]">
        Sin solicitudes
      </span>
    );
  }

  const meta: Record<
    ChangeRequestStatus,
    { label: string; className: string }
  > = {
    pending: {
      label: "Pendiente",
      className: "text-[#A56A00]",
    },
    in_review: {
      label: "En revisión",
      className: "text-[#173B8F]",
    },
    accepted: {
      label: "Aceptada",
      className: "text-[#247A49]",
    },
    rejected: {
      label: "Rechazada",
      className: "text-[#B53A3A]",
    },
    completed: {
      label: "Completada",
      className: "text-[#4B3E57]",
    },
  };

  const status = meta[request.status];

  return (
    <span className={`text-[10px] font-semibold ${status.className}`}>
      {status.label}
    </span>
  );
}

function EmptyInlineProject({ text }: { text: string }) {
  return (
    <div className="border-y border-[#EEF1F4] py-5 text-[11px] text-[#98A2B3]">
      {text}
    </div>
  );
}

function InfoMiniCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-md border border-[#EEF1F4] bg-[#FAFBFC] px-3 py-3">
      <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
        {label}
      </p>
      <p className="mt-1 truncate text-[11px] font-medium text-[#445166]" title={value}>
        {value}
      </p>
    </div>
  );
}

function SummaryRow({
  icon,
  label,
  value,
}: {
  icon: ReactNode;
  label: string;
  value: string;
}) {
  return (
    <div className="flex items-center justify-between border-b border-[#EEF1F4] pb-3 last:border-b-0 last:pb-0">
      <div className="flex items-center gap-2.5">
        <span className="text-[#7A8595]">{icon}</span>
        <span className="text-[11px] text-[#718096]">{label}</span>
      </div>
      <span className="text-[12px] font-semibold text-[#344054]">{value}</span>
    </div>
  );
}

function EmptyPanel({
  icon,
  title,
  description,
}: {
  icon: ReactNode;
  title: string;
  description: string;
}) {
  return (
    <div className="border border-dashed border-[#D8DEE7] bg-white px-6 py-10 text-center">
      <span className="mx-auto flex h-9 w-9 items-center justify-center bg-[#F3F5F8] text-[#8994A4]">
        {icon}
      </span>
      <p className="mt-3 text-[12px] font-semibold text-[#344054]">{title}</p>
      <p className="mx-auto mt-1.5 max-w-lg text-[11px] leading-5 text-[#8792A2]">
        {description}
      </p>
    </div>
  );
}
