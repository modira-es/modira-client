import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import {
  AlertCircle,
  ArrowLeft,
  ArrowRight,
  Bell,
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
  const [progress, setProgress] = useState<ProjectProgress[]>([]);
  const [projectDocumentCounts, setProjectDocumentCounts] = useState<Record<string, number>>({});
  const [projectChangeRequests, setProjectChangeRequests] = useState<ProjectChangeRequest[]>([]);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<"all" | ProjectStatus>("all");

  const [detailProject, setDetailProject] = useState<Project | null>(null);
  const [updates, setUpdates] = useState<ProjectUpdate[]>([]);
  const [documents, setDocuments] = useState<ProjectDocument[]>([]);
  const [changeRequests, setChangeRequests] = useState<ProjectChangeRequest[]>([]);
  const [quotations, setQuotations] = useState<Quotation[]>([]);
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);
  const [notifications, setNotifications] = useState<ClientNotification[]>([]);

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

  const closeProjectView = useCallback(() => {
    /*
     * Detail/create se abren con pushState. Volver mediante history.back()
     * elimina esa entrada y devuelve realmente al listado, en lugar de
     * crear otra entrada idéntica en el historial.
     *
     * Si el usuario ha cargado directamente una URL con #project=... o #new,
     * no existe nuestra marca de historial y sustituimos la URL por la base.
     */
    if (window.history.state?.modiraProjectView) {
      window.history.back();
      return;
    }

    window.history.replaceState({}, "", window.location.pathname);
    setSelectedProjectId(null);
    setCreateMode(false);
    setDetailProject(null);
    setError(null);
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
          .eq("user_id", user.id)
          .order("created_at", { ascending: false }),
        supabase
          .from("project_progress")
          .select("project_id,total_milestones,completed_milestones,progress_percentage"),
      ]);

      if (projectsResult.error) throw projectsResult.error;

      const resolvedProjects = (projectsResult.data || []) as unknown as Project[];
      setProjects(resolvedProjects);
      setProgress(
        progressResult.error
          ? []
          : ((progressResult.data || []) as ProjectProgress[]),
      );

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

  const loadNotifications = useCallback(async () => {
    if (!user) return;

    const { data, error } = await supabase
      .from("notifications")
      .select("id,project_id,tipo,titulo,mensaje,metadata,read_at,created_at")
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .limit(50);

    if (!error) setNotifications((data || []) as ClientNotification[]);
  }, [user]);

  const loadProjectDetail = useCallback(async () => {
    if (!user || !projectIdFromUrl) return;

    setDetailLoading(true);
    setError(null);

    try {
      const [
        projectResult,
        progressResult,
        updatesResult,
        documentsResult,
        changesResult,
        quotationsResult,
        invoicesResult,
        paymentsResult,
      ] = await Promise.all([
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
          .eq("id", projectIdFromUrl)
          .eq("user_id", user.id)
          .maybeSingle(),
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
          .eq("project_id", projectIdFromUrl)
          .order("created_at", { ascending: false }),
        supabase
          .from("invoices")
          .select(
            [
              "id",
              "project_id",
              "numero_factura",
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
          .eq("project_id", projectIdFromUrl)
          .order("created_at", { ascending: false }),
        supabase
          .from("payments")
          .select("id,invoice_id,amount,currency,status,description,paid_at,created_at")
          .eq(
            "company_id",
            (
              await supabase
                .from("projects")
                .select("company_id")
                .eq("id", projectIdFromUrl)
                .eq("user_id", user.id)
                .maybeSingle()
            ).data?.company_id ?? "__none__",
          )
          .order("created_at", { ascending: false }),
      ]);

      if (projectResult.error) throw projectResult.error;
      if (!projectResult.data) throw new Error("Proyecto no encontrado o no tienes acceso.");

      setDetailProject(projectResult.data as unknown as Project);
      setUpdates((updatesResult.data || []) as ProjectUpdate[]);
      setDocuments((documentsResult.data || []) as ProjectDocument[]);
      setChangeRequests((changesResult.data || []) as ProjectChangeRequest[]);
      setQuotations((quotationsResult.data || []) as unknown as Quotation[]);
      setInvoices((invoicesResult.data || []) as unknown as Invoice[]);
      setPayments((paymentsResult.data || []) as Payment[]);

      if (progressResult.data) {
        setProgress((current) => {
          const withoutCurrent = current.filter((item) => item.project_id !== projectIdFromUrl);
          return [...withoutCurrent, progressResult.data as ProjectProgress];
        });
      }
    } catch (err: any) {
      console.error("[ClientProjects] Error cargando detalle:", err);
      setError(err?.message || "No se pudo cargar el proyecto.");
    } finally {
      setDetailLoading(false);
    }
  }, [user, projectIdFromUrl]);

  useEffect(() => {
    loadProjects();
    loadNotifications();
  }, [loadProjects, loadNotifications]);

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

  const unreadNotifications = useMemo(
    () => notifications.filter((notification) => !notification.read_at),
    [notifications],
  );

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
      await loadNotifications();
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

      await loadNotifications();
    } catch (err: any) {
      console.error("[ClientProjects] Error respondiendo presupuesto:", err);
      toast.error(err?.message || "No se pudo responder al presupuesto.");
    } finally {
      setRespondingQuotationId(null);
    }
  };

  const handleReadNotification = async (notification: ClientNotification) => {
    if (notification.read_at) return;

    try {
      const { error } = await supabase.rpc("mark_notification_read", {
        p_notification_id: notification.id,
      });
      if (error) throw error;

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
      const { error } = await supabase.rpc("mark_all_notifications_read");
      if (error) throw error;

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
          <div className="fixed right-5 top-5 z-40 flex items-center gap-2 sm:right-7">
            <NotificationsPopover
              unreadCount={unreadNotifications.length}
              notifications={notifications}
              onRead={handleReadNotification}
              onMarkAllRead={handleMarkAllNotificationsRead}
            />
            <CalendarButton />
          </div>

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
          <div className="fixed right-5 top-5 z-40 flex items-center gap-2 sm:right-7">
            <NotificationsPopover
              unreadCount={unreadNotifications.length}
              notifications={notifications}
              onRead={handleReadNotification}
              onMarkAllRead={handleMarkAllNotificationsRead}
            />
            <CalendarButton />
          </div>

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

            </div>

            {detailProject && !detailLoading && (
              <ProjectDetailContent
                project={detailProject}
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
        <div className="fixed right-5 top-5 z-40 flex items-center gap-2 sm:right-7">
          <NotificationsPopover
            unreadCount={unreadNotifications.length}
            notifications={notifications}
            onRead={handleReadNotification}
            onMarkAllRead={handleMarkAllNotificationsRead}
          />
          <CalendarButton />
        </div>

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
              <div className="flex h-11 items-center gap-3 rounded-lg border border-[#E3E8EE] bg-[#F8FAFC] px-3.5 transition-colors focus-within:border-[#C8D2DE] focus-within:bg-white">
                <Search className="h-4 w-4 shrink-0 text-[#8F9AAA]" strokeWidth={1.7} />
                <Input
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                  placeholder="Buscar proyecto por nombre o descripción..."
                  className="h-full min-w-0 border-0 bg-transparent p-0 text-[13px] text-[#344054] shadow-none placeholder:text-[#9AA4B2] focus-visible:ring-0"
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

function CalendarButton() {
  return (
    <button
      type="button"
      aria-label="Abrir calendario"
      title="Calendario"
      className="relative flex h-10 w-10 items-center justify-center rounded-full border border-[#D7DEE7] bg-white text-[#667386] transition-all duration-200 hover:border-[#C7D0DB] hover:bg-[#F3F5F8] hover:text-[#445166]"
      onClick={() => {
        window.dispatchEvent(new CustomEvent("modira:open-calendar"));
        toast.info("El calendario general del área de cliente está disponible desde el botón de calendario.");
      }}
    >
      <CalendarDays className="h-[17px] w-[17px]" strokeWidth={1.8} />
    </button>
  );
}

function NotificationsPopover({
  unreadCount,
  notifications,
  onRead,
  onMarkAllRead,
}: {
  unreadCount: number;
  notifications: ClientNotification[];
  onRead: (notification: ClientNotification) => void;
  onMarkAllRead: () => void;
}) {
  const [open, setOpen] = useState(false);

  return (
    <div className="relative">
      <button
        type="button"
        aria-label="Notificaciones"
        title="Notificaciones"
        onClick={() => setOpen((value) => !value)}
        className="relative flex h-10 w-10 items-center justify-center rounded-full border border-[#D7DEE7] bg-white text-[#667386] transition-all duration-200 hover:border-[#C7D0DB] hover:bg-[#F3F5F8] hover:text-[#445166]"
      >
        <Bell className="h-[17px] w-[17px]" strokeWidth={1.8} />
        {unreadCount > 0 && (
          <span className="absolute -right-1 -top-1 flex h-[18px] min-w-[18px] items-center justify-center rounded-full border-2 border-white bg-[#4B3E57] px-1 text-[9px] font-bold leading-none text-white">
            {unreadCount > 99 ? "99+" : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <>
          <button
            type="button"
            className="fixed inset-0 z-40 cursor-default"
            aria-label="Cerrar notificaciones"
            onClick={() => setOpen(false)}
          />
          <div className="absolute right-0 top-12 z-50 w-[360px] overflow-hidden rounded-xl border border-[#DCE2E9] bg-white shadow-[0_18px_55px_rgba(20,35,60,0.13)]">
            <div className="flex items-center justify-between border-b border-[#EEF1F4] px-4 py-3">
              <div>
                <p className="text-[12px] font-semibold text-[#26344A]">Notificaciones</p>
                <p className="mt-0.5 text-[10px] text-[#98A2B3]">
                  {unreadCount ? `${unreadCount} sin leer` : "Todo al día"}
                </p>
              </div>
              {unreadCount > 0 && (
                <button
                  type="button"
                  onClick={onMarkAllRead}
                  className="text-[10px] font-semibold text-[#173B8F] hover:underline"
                >
                  Marcar todas
                </button>
              )}
            </div>

            <div className="max-h-[430px] overflow-y-auto">
              {notifications.length === 0 ? (
                <div className="px-5 py-10 text-center">
                  <Bell className="mx-auto mb-3 h-6 w-6 text-[#B1BAC6]" />
                  <p className="text-[12px] font-medium text-[#667386]">
                    No tienes notificaciones.
                  </p>
                </div>
              ) : (
                notifications.slice(0, 20).map((notification) => (
                  <button
                    type="button"
                    key={notification.id}
                    onClick={() => onRead(notification)}
                    className={[
                      "flex w-full gap-3 border-b border-[#F0F2F5] px-4 py-3 text-left transition hover:bg-[#F8FAFC]",
                      !notification.read_at ? "bg-[#F8FAFD]" : "bg-white",
                    ].join(" ")}
                  >
                    <span
                      className={[
                        "mt-1 h-2 w-2 shrink-0 rounded-full",
                        notification.read_at ? "bg-[#D6DCE4]" : "bg-[#4B3E57]",
                      ].join(" ")}
                    />
                    <span className="min-w-0">
                      <span className="block text-[11px] font-semibold text-[#344054]">
                        {notification.titulo}
                      </span>
                      <span className="mt-0.5 block text-[10px] leading-4 text-[#7A8595]">
                        {notification.mensaje}
                      </span>
                      <span className="mt-1 block text-[9px] text-[#A0A9B6]">
                        {formatCompactDate(notification.created_at)}
                      </span>
                    </span>
                  </button>
                ))
              )}
            </div>
          </div>
        </>
      )}
    </div>
  );
}

function ProjectDetailContent({
  project,
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
    "novedades" | "documentos" | "cambios" | "presupuestos" | "facturas"
  >("novedades");

  const projectPayments = payments.filter((payment) =>
    invoices.some((invoice) => invoice.id === payment.invoice_id),
  );


  const sections = [
    { id: "novedades" as const, label: "Novedades", count: updates.length },
    { id: "documentos" as const, label: "Documentos", count: documents.length },
    {
      id: "cambios" as const,
      label: "Solicitudes de cambio",
      count: changeRequests.length,
    },
    {
      id: "presupuestos" as const,
      label: "Presupuestos vinculados",
      count: quotations.length,
    },
    { id: "facturas" as const, label: "Facturas", count: invoices.length },
  ];

  return (
    <div className="space-y-7">
      {/* ------------------------------------------------------------
          NAVEGACIÓN — mismo patrón visual que EmployeeProjects.
      ------------------------------------------------------------- */}
      <nav
        className="overflow-x-auto border-y border-[#E3E8EE] bg-white"
        aria-label="Secciones del proyecto"
      >
        <div className="flex min-w-full justify-center px-2">
          <div className="flex w-fit min-w-max items-stretch">
          {sections.map((section) => {
            const active = activeSection === section.id;
            const hasCount = typeof section.count === "number";
            const count = section.count ?? 0;

            return (
              <button
                key={section.id}
                type="button"
                onClick={() => setActiveSection(section.id)}
                className={[
                  "relative flex min-h-[46px] flex-1 items-center justify-center rounded-none px-3.5 pr-9 text-[12px] font-medium leading-tight transition-all sm:px-4 sm:pr-10",
                  active
                    ? "bg-[#173B8F] font-semibold text-white shadow-[0_3px_10px_rgba(23,59,143,0.16)]"
                    : "text-[#667386] hover:bg-[#F6F8FB] hover:text-[#173B8F]",
                ].join(" ")}
              >
                <span>{section.label}</span>
                {hasCount && (
                  <span
                    className={[
                      "absolute right-2 top-1/2 flex h-5 min-w-5 -translate-y-1/2 items-center justify-center rounded-full border px-1 text-[9px] font-bold leading-none transition-all",
                      active
                        ? "border-white/25 bg-white/20 text-white shadow-[0_0_0_3px_rgba(255,255,255,0.04)]"
                        : count > 0
                          ? "border-[#D9E0E8] bg-[#F4F6F9] text-[#687588]"
                          : "border-[#E5E9EE] bg-[#FAFBFC] text-[#A7AFBA]",
                    ].join(" ")}
                  >
                    {count}
                  </span>
                )}
              </button>
            );
          })}
          </div>
        </div>
      </nav>

      {/* ------------------------------------------------------------
          NOVEDADES
      ------------------------------------------------------------- */}
      {activeSection === "novedades" && (
        <section>
          <SectionTitle eyebrow="Comunicación" title="Novedades" />

<div className="overflow-hidden border border-[#E3E8EE] bg-white">

          {updates.length === 0 ? (
            <EmptyPanel
              icon={<MessageSquare className="h-5 w-5" />}
              title="No hay novedades publicadas"
              description="Las novedades que el equipo publique para ti aparecerán aquí."
            />
          ) : (
            <div className="border-t border-[#EEF1F4] p-4 sm:p-5">
              <div className="grid gap-4 md:grid-cols-2">
                {updates.map((update) => (
                  <article
                    key={update.id}
                    className="relative overflow-hidden border border-[#E2E7ED] bg-[#FCFDFE] p-5 transition-colors hover:border-[#CDD6E0]"
                  >
                    <div className="absolute left-0 top-0 h-full w-[3px] bg-[#173B8F]" />
                    <div className="flex items-start justify-between gap-4 pl-2">
                      <div className="min-w-0">
                        <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">Novedad</p>
                        <h3 className="mt-1.5 text-[14px] font-semibold tracking-tight text-[#344054]">
                          {update.titulo}
                        </h3>
                      </div>
                      <time className="shrink-0 text-[10px] font-medium text-[#98A2B3]">
                        {formatCompactDate(update.created_at)}
                      </time>
                    </div>
                    <div className="mt-4 border-t border-[#EEF1F4] pt-4 pl-2">
                      <p className="whitespace-pre-wrap text-[12px] leading-6 text-[#667386]">
                        {update.contenido}
                      </p>
                    </div>
                  </article>
                ))}
              </div>
            </div>
          )}
          </div>
        </section>
      )}

      {/* ------------------------------------------------------------
          DOCUMENTOS
      ------------------------------------------------------------- */}
      {activeSection === "documentos" && (
        <section>
          <SectionTitle
            eyebrow="Archivos"
            title="Documentos del proyecto"
          />

<div className="overflow-hidden border border-[#E3E8EE] bg-white">

          {documents.length === 0 ? (
            <EmptyPanel
              icon={<FileText className="h-5 w-5" />}
              title="No hay documentos"
              description="Los documentos PDF asociados al proyecto aparecerán aquí."
            />
          ) : (
            <div className="divide-y divide-[#EEF1F4] border-t border-[#EEF1F4]">
              {documents.map((document) => (
                <div
                  key={document.id}
                  className="flex flex-col gap-3 px-5 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6"
                >
                  <div className="flex min-w-0 items-center gap-3">
                    <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-[#F1F4F8] text-[#667386]">
                      <FileText className="h-4 w-4" />
                    </div>
                    <div className="min-w-0">
                      <p className="truncate text-[12px] font-semibold text-[#344054]">
                        {document.file_name}
                      </p>
                      <div className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[10px] text-[#98A2B3]">
                        <span className="font-medium text-[#667386]">Documento de proyecto</span>
                        <span>·</span>
                        <span>PDF · {formatFileSize(document.file_size)}</span>
                        <span>·</span>
                        <span>{formatCompactDate(document.created_at)}</span>
                      </div>
                    </div>
                  </div>

                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => onOpenProjectDocument(document)}
                    className="h-8 shrink-0 border-[#D7DEE7] text-[10px]"
                  >
                    <Download className="mr-1.5 h-3.5 w-3.5" />
                    Abrir documento
                  </Button>
                </div>
              ))}
            </div>
          )}
          </div>
        </section>
      )}

      {/* ------------------------------------------------------------
          SOLICITUDES DE CAMBIO
      ------------------------------------------------------------- */}
      {activeSection === "cambios" && (
        <section>
          <SectionTitle
            eyebrow="Cambios"
            title="Solicitudes de cambio"
            action={
              project.change_requests_enabled &&
              (!project.change_requests_deadline ||
                new Date(project.change_requests_deadline).getTime() >= Date.now()) &&
              !activeChangeRequest ? (
                <Button
                  type="button"
                  onClick={onOpenChangeRequest}
                  className="h-9 bg-[#173B8F] text-[11px] hover:bg-[#102A66]"
                >
                  <MessageSquare className="mr-2 h-3.5 w-3.5" />
                  Solicitar cambio
                </Button>
              ) : undefined
            }
          />

<div className="overflow-hidden border border-[#E0E6ED] bg-white shadow-[0_6px_24px_rgba(24,42,69,0.035)]">

          <div className="border-t border-[#EEF1F4]">
            {project.change_requests_enabled ? (
              <div className="border-b border-[#EEF1F4] px-5 py-4 sm:px-6">
                <p className="text-[11px] font-semibold text-[#344054]">
                  Periodo de solicitudes habilitado
                </p>
                <p className="mt-1 text-[10px] leading-5 text-[#8792A2]">
                  {project.change_requests_deadline
                    ? `Puedes solicitar cambios hasta el ${formatDate(
                        project.change_requests_deadline,
                      )}.`
                    : "Puedes solicitar cambios mientras el periodo permanezca habilitado."}
                </p>
              </div>
            ) : (
              <div className="border-b border-[#EEF1F4] px-5 py-4 text-[11px] text-[#8792A2] sm:px-6">
                Las solicitudes de cambio no están habilitadas actualmente para
                este proyecto.
              </div>
            )}

            {changeRequests.length === 0 ? (
              <EmptyInlineProject text="No hay solicitudes de cambio para este proyecto." />
            ) : (
              <div className="divide-y divide-[#EEF1F4]">
                {changeRequests.map((request) => (
                  <article key={request.id} className="relative mx-4 my-4 overflow-hidden border border-[#E1E7EE] bg-[#FCFDFE] p-5 sm:mx-5 sm:p-6">
                    <div className="flex flex-wrap items-start justify-between gap-4">
                      <div>
                        <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">Solicitud de cambio</p>
                        <div className="mt-2">
                          <ChangeRequestPreviewBadge request={request} />
                        </div>
                      </div>
                      <time className="text-[10px] font-medium text-[#98A2B3]">
                        {formatCompactDate(request.created_at)}
                      </time>
                    </div>
                    <div className="mt-4 border-t border-[#EEF1F4] pt-4">
                      <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">Descripción</p>
                      <p className="mt-2 whitespace-pre-wrap text-[12px] leading-6 text-[#667386]">
                        {request.description}
                      </p>
                    </div>
                    {request.review_notes && (
                      <div className="mt-4 border border-[#E5E9EF] bg-white px-4 py-3.5">
                        <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#8A95A5]">Nota de revisión</p>
                        <p className="mt-1.5 whitespace-pre-wrap text-[11px] leading-5 text-[#718096]">
                          {request.review_notes}
                        </p>
                      </div>
                    )}
                  </article>
                ))}
              </div>
            )}
          </div>
          </div>
        </section>
      )}

      {/* ------------------------------------------------------------
          PRESUPUESTOS VINCULADOS
      ------------------------------------------------------------- */}
      {activeSection === "presupuestos" && (
        <section>
          <SectionTitle eyebrow="Presupuestos" title="Presupuestos vinculados" />

          {quotations.length === 0 ? (
            <div className="border-y border-[#E3E8EE] bg-white px-5 py-5 sm:px-6">
              <p className="text-[12px] text-[#8792A2]">No hay presupuestos vinculados a este proyecto.</p>
            </div>
          ) : (
            <div className="overflow-hidden border border-[#E3E8EE] bg-white">
              <div className="divide-y divide-[#EEF1F4]">
                {quotations.map((quotation) => {
                  const pending = normalize(quotation.estado) === "pendiente";

                  return (
                    <div key={quotation.id} className="flex flex-col gap-4 px-5 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6">
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2.5">
                          <span className="text-[12px] font-semibold text-[#344054]">
                            {quotation.numero_presupuesto || "Presupuesto"}
                          </span>
                          <span className="text-[12px] text-[#667386]">
                            {quotation.titulo || "Presupuesto vinculado"}
                          </span>
                          <span className={`rounded-full border px-2.5 py-1 text-[10px] font-semibold ${projectStatusClasses(quotation.estado)}`}>
                            {statusLabel(quotation.estado)}
                          </span>
                        </div>
                        <p className="mt-1 text-[10px] text-[#98A2B3]">
                          {formatCurrency(quotation.precio_total)} · Validez {formatCompactDate(quotation.fecha_validez)}
                        </p>
                      </div>

                      <div className="flex shrink-0 items-center gap-3">
                        {pending && (
                          <span className="text-[10px] text-[#A56A00]">Requiere respuesta</span>
                        )}
                        <a
                          href="/area-cliente/presupuestos"
                          className="inline-flex items-center gap-1.5 text-[11px] font-semibold text-[#173B8F] transition-colors hover:text-[#102A66]"
                        >
                          Ver presupuestos
                          <ExternalLink className="h-3.5 w-3.5" strokeWidth={1.7} />
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

      {/* ------------------------------------------------------------
          FACTURAS
      ------------------------------------------------------------- */}
      {activeSection === "facturas" && (
        <section>
          <SectionTitle eyebrow="Facturación" title="Facturas del proyecto" />

          {invoices.length === 0 ? (
            <div className="border-y border-[#E3E8EE] bg-white px-5 py-5 sm:px-6">
              <p className="text-[12px] text-[#8792A2]">No hay facturas vinculadas a este proyecto.</p>
            </div>
          ) : (
            <div className="overflow-hidden border border-[#E3E8EE] bg-white">
              <div className="divide-y divide-[#EEF1F4]">
                {invoices.map((invoice) => {
                  const invoicePayments = projectPayments.filter(
                    (payment) => payment.invoice_id === invoice.id,
                  );
                  const paid = invoicePayments.some(
                    (payment) => normalize(payment.status) === "succeeded",
                  );

                  return (
                    <div key={invoice.id} className="flex flex-col gap-4 px-5 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6">
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2.5">
                          <span className="text-[12px] font-semibold text-[#344054]">
                            {invoice.numero_factura || "Factura"}
                          </span>
                          <span className="text-[12px] text-[#667386]">
                            {formatCurrency(invoice.importe_a_pagar ?? invoice.monto)}
                          </span>
                          <span className={`rounded-full border px-2.5 py-1 text-[10px] font-semibold ${projectStatusClasses(invoice.estado)}`}>
                            {statusLabel(invoice.estado)}
                          </span>
                          {paid && (
                            <span className="rounded-full border border-[#CDE8D8] bg-[#ECF8F1] px-2.5 py-1 text-[10px] font-semibold text-[#247A49]">
                              Pagada
                            </span>
                          )}
                        </div>
                        <p className="mt-1 text-[10px] text-[#98A2B3]">
                          Emitida {formatCompactDate(invoice.fecha_emision)} · {invoice.fecha_vencimiento ? `Vence ${formatCompactDate(invoice.fecha_vencimiento)}` : "Sin vencimiento"}
                        </p>
                      </div>

                      <a
                        href="/area-cliente/facturacion"
                        className="inline-flex shrink-0 items-center gap-1.5 text-[11px] font-semibold text-[#173B8F] transition-colors hover:text-[#102A66]"
                      >
                        Ver facturación
                        <ExternalLink className="h-3.5 w-3.5" strokeWidth={1.7} />
                      </a>
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
