import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import ClientFloatingActions from "@/components/ClientFloatingActions";
import {
  AlertCircle,
  ArrowRight,
  BriefcaseBusiness,
  Check,
  CircleHelp,
  Clock3,
  Download,
  FileText,
  Home,
  Info,
  Loader2,
  LogOut,
  Menu,
  Receipt,
  Search,
  ShieldCheck,
  UserRound,
  Wrench,
  X,
} from "lucide-react";
import { Input } from "@/components/ui/input";

type QuotationStatus = "Pendiente" | "Aceptado" | "Rechazado";
type WorkflowStatus = "presented" | "in_review" | "accepted" | "rejected";

interface QuotationWorkflowState {
  quotation_id: string;
  current_version_id: string | null;
  workflow_status: WorkflowStatus;
  updated_at?: string;
}

interface OfficialQuotationVersion {
  id: string;
  quotation_id: string;
  version_label: string;
  content_snapshot: Record<string, unknown>;
  document_path: string | null;
  document_sha256: string | null;
  is_current: boolean;
  published_at: string;
  client_notified_at: string | null;
  client_response: "Aceptado" | "Rechazado" | null;
  responded_at: string | null;
}

interface QuotationChangeRequest {
  id: string;
  quotation_id: string;
  official_version_id: string;
  request_text: string;
  request_status: "open" | "resolved" | "cancelled";
  requested_at: string;
  resolved_at: string | null;
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
  estado: QuotationStatus;
  fecha_emision: string | null;
  fecha_validez: string | null;
  notas: string | null;
  document_path: string | null;
  quotation_version: number | null;
  document_sha256: string | null;
  created_at: string;
  updated_at: string;
  workflow_status?: WorkflowStatus;
  workflow_version_label?: string;
  workflow_waiting_for_document?: boolean;
}

interface Project {
  id: string;
  nombre: string;
  user_id: string | null;
}
interface ProjectOwnerProfile {
  id: string;
  nombre: string | null;
}
interface QuotationService {
  descripcion?: string;
  cantidad?: number | string;
  precio?: number | string;
}

interface QuotationAcceptance {
  quotation_id: string;
  accepted_at: string;
  quotation_version: number;
}
interface QuotationSignedDocument {
  id: string;
  quotation_id: string;
  official_version_id: string;
  signed_document_path: string;
  signed_at: string;
}
const QUOTATION_STATUSES: Array<"all" | QuotationStatus> = [
  "all",
  "Pendiente",
  "Aceptado",
  "Rechazado",
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

const normalize = (value?: string | null) =>
  String(value || "").trim().toLowerCase();

const getQuotationServices = (services: unknown): QuotationService[] => {
  if (Array.isArray(services)) {
    return services.filter(
      (item): item is QuotationService =>
        Boolean(item && typeof item === "object"),
    );
  }

  if (typeof services === "string") {
    try {
      const parsed = JSON.parse(services);

      if (Array.isArray(parsed)) {
        return parsed.filter(
          (item): item is QuotationService =>
            Boolean(item && typeof item === "object"),
        );
      }

      if (parsed && typeof parsed === "object") {
        const nested =
          (parsed as Record<string, unknown>).servicios ??
          (parsed as Record<string, unknown>).services ??
          (parsed as Record<string, unknown>).items;

        if (Array.isArray(nested)) {
          return nested.filter(
            (item): item is QuotationService =>
              Boolean(item && typeof item === "object"),
          );
        }
      }
    } catch {
      return [];
    }
  }

  if (services && typeof services === "object") {
    const nested =
      (services as Record<string, unknown>).servicios ??
      (services as Record<string, unknown>).services ??
      (services as Record<string, unknown>).items;

    if (Array.isArray(nested)) {
      return nested.filter(
        (item): item is QuotationService =>
          Boolean(item && typeof item === "object"),
      );
    }
  }

  return [];
};

const getServiceCount = (services: unknown) =>
  getQuotationServices(services).length;

const statusLabel = (status: string) => {
  const value = normalize(status);

  if (value === "pendiente" || value === "pending") return "Pendiente";
  if (value === "aceptado" || value === "accepted") return "Aceptado";
  if (value === "rechazado" || value === "rejected") return "Rechazado";
  if (value === "in_review" || value === "en revisión") return "En revisión";
  if (value === "presented" || value === "pending") return "Pendiente";
  if (value === "actualizando versión" || value === "updating") return "Actualizando versión";

  return status;
};

const quotationStatusClasses = (status: string) => {
  switch (normalize(status)) {
    case "aceptado":
    case "accepted":
      return "bg-[#ECF8F1] text-[#247A49] border-[#CDE8D8]";
    case "rechazado":
    case "rejected":
      return "bg-[#F4F6F8] text-[#667386] border-[#E0E5EA]";
    case "in_review":
    case "en revisión":
      return "bg-[#FFF7E8] text-[#8B640F] border-[#F0DEB7]";
    case "actualizando versión":
    case "updating":
      return "bg-[#F4F6F8] text-[#667386] border-[#E0E5EA]";
    default:
      return "bg-[#F3F0F6] text-[#4B3E57] border-[#DDD7E5]";
  }
};

const quotationStatusDot = (status: string) => {
  switch (normalize(status)) {
    case "aceptado":
    case "accepted":
      return "bg-[#247A49]";
    case "rechazado":
    case "rejected":
      return "bg-[#98A2B3]";
    case "in_review":
    case "en revisión":
      return "bg-[#A56A00]";
    case "actualizando versión":
    case "updating":
      return "bg-[#98A2B3]";
    default:
      return "bg-[#4B3E57]";
  }
};

const quotationDisplayStatus = (quotation: Quotation): string => {
  if (quotation.workflow_waiting_for_document) return "Actualizando versión";
  switch (quotation.workflow_status) {
    case "presented":
      return "Pendiente";
    case "in_review":
      return "En revisión";
    case "accepted":
      return "Aceptado";
    case "rejected":
      return "Rechazado";
    default:
      return quotation.estado;
  }
};

const latestClientVisibleVersion = (
  versions: OfficialQuotationVersion[],
): OfficialQuotationVersion | undefined =>
  versions
    .filter(
      (version) =>
        Boolean(version.client_notified_at) &&
        Boolean(version.document_path) &&
        Boolean(version.document_sha256),
    )
    .sort(
      (a, b) =>
        new Date(b.published_at).getTime() -
        new Date(a.published_at).getTime(),
    )[0];

const quotationFromOfficialVersion = (
  base: Quotation,
  version: OfficialQuotationVersion,
  state: QuotationWorkflowState,
): Quotation => {
  const snapshot = version.content_snapshot as Partial<Quotation>;
  const workflowWaiting = state.current_version_id !== version.id;
  const stateStatus: QuotationStatus =
    state.workflow_status === "accepted"
      ? "Aceptado"
      : state.workflow_status === "rejected"
        ? "Rechazado"
        : "Pendiente";

  return {
    ...base,
    ...snapshot,
    id: base.id,
    document_path: version.document_path,
    document_sha256: version.document_sha256,
    estado: stateStatus,
    workflow_status: state.workflow_status,
    workflow_version_label: version.version_label,
    workflow_waiting_for_document: workflowWaiting,
  };
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

export default function Quotations() {
  const { user, signOut, loading: authLoading } = useAuth();
  const [location, setLocation] = useLocation();

  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [detailLoading, setDetailLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [quotations, setQuotations] = useState<Quotation[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [projectOwners, setProjectOwners] = useState<ProjectOwnerProfile[]>([]);

  const [acceptances, setAcceptances] = useState<QuotationAcceptance[]>([]);
  const [officialVersions, setOfficialVersions] = useState<Record<string, OfficialQuotationVersion[]>>({});
  const [changeRequests, setChangeRequests] = useState<Record<string, QuotationChangeRequest[]>>({});
  const [signedDocuments, setSignedDocuments] = useState<
  Record<string, QuotationSignedDocument[]>
>({});

  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<
    "all" | QuotationStatus | "En revisión" | "Actualizando versión"
  >("all");

  const [selectedQuotationId, setSelectedQuotationId] = useState<string | null>(
    null,
  );
  const [selectedQuotation, setSelectedQuotation] =
    useState<Quotation | null>(null);

  const [respondingQuotationId, setRespondingQuotationId] = useState<
  string | null
>(null);

const [pdfOpened, setPdfOpened] = useState(false);
const [acknowledged, setAcknowledged] = useState(false);

const isDetailMode = Boolean(selectedQuotationId);

  const navigate = useCallback(
    (path: string) => {
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
    },
    [location, setLocation],
  );

  const handleLogout = async () => {
    const result = await signOut();

    if (result.success) {
      setLocation("/");
    }
  };

  const openQuotation = useCallback((quotationId: string) => {
    const nextUrl = `${window.location.pathname}#quotation=${encodeURIComponent(
      quotationId,
    )}`;

    window.history.pushState(
      {
        modiraQuotationView: true,
        view: "quotation",
        quotationId,
      },
      "",
      nextUrl,
    );

    setSelectedQuotationId(quotationId);
setSelectedQuotation(null);
setError(null);
setPdfOpened(false);
setAcknowledged(false);
window.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

  const closeQuotation = useCallback(() => {
    window.history.replaceState(
      { modiraQuotationView: false, view: "list" },
      "",
      window.location.pathname,
    );

    setSelectedQuotationId(null);
    setSelectedQuotation(null);
    setDetailLoading(false);
    setPdfOpened(false);
setAcknowledged(false);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

  useEffect(() => {
    const syncQuotationView = () => {
      const hash = window.location.hash;

      if (hash.startsWith("#quotation=")) {
  const quotationId = decodeURIComponent(
    hash.slice("#quotation=".length),
  );

  setSelectedQuotationId(quotationId);
  setSelectedQuotation(null);
  setPdfOpened(false);
  setAcknowledged(false);
} else {
        setSelectedQuotationId(null);
        setSelectedQuotation(null);
      }
    };

    syncQuotationView();

    window.addEventListener("popstate", syncQuotationView);
    window.addEventListener("hashchange", syncQuotationView);

    return () => {
      window.removeEventListener("popstate", syncQuotationView);
      window.removeEventListener("hashchange", syncQuotationView);
    };
  }, []);

  const loadQuotations = useCallback(async () => {
    if (!user) return;

    setLoading(true);
    setError(null);

    try {
      const { data, error: quotationError } = await supabase
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
            "document_sha256",
            "quotation_version",
            "created_at",
            "updated_at",
          ].join(","),
        )
        .order("created_at", { ascending: false });

      if (quotationError) throw quotationError;

      const rawQuotations = (data || []) as unknown as Quotation[];
      const quotationIds = rawQuotations.map((quotation) => quotation.id);
      if (quotationIds.length > 0) {
  const { data: signedDocumentData, error: signedDocumentError } =
    await supabase
      .from("quotation_signed_documents")
      .select(
        "id,quotation_id,official_version_id,signer_user_id,signer_name_snapshot,source_document_path,source_document_sha256,signed_document_path,signed_document_sha256,signature_image_sha256,signed_at,user_agent,created_at"
      )
      .in("quotation_id", quotationIds)
      .order("signed_at", { ascending: false });

  if (signedDocumentError) throw signedDocumentError;

  const signedDocumentMap = (
    (signedDocumentData || []) as QuotationSignedDocument[]
  ).reduce<Record<string, QuotationSignedDocument[]>>((acc, document) => {
    (acc[document.quotation_id] ||= []).push(document);
    return acc;
  }, {});

  setSignedDocuments(signedDocumentMap);
} else {
  setSignedDocuments({});
}

      let stateRows: QuotationWorkflowState[] = [];
      let versionRows: OfficialQuotationVersion[] = [];
      let requestRows: QuotationChangeRequest[] = [];

      if (quotationIds.length > 0) {
        const { data: stateData, error: stateError } = await supabase
          .from("quotation_workflow_state")
          .select("quotation_id,current_version_id,workflow_status,updated_at")
          .in("quotation_id", quotationIds);
        if (stateError) throw stateError;
        stateRows = (stateData || []) as QuotationWorkflowState[];

        const workflowIds = stateRows.map((state) => state.quotation_id);
        if (workflowIds.length > 0) {
          const [
            { data: versionData, error: versionError },
            { data: requestData, error: requestError },
          ] = await Promise.all([
            supabase
              .from("quotation_official_versions")
              .select("id,quotation_id,version_label,content_snapshot,document_path,document_sha256,is_current,published_at,client_notified_at,client_response,responded_at")
              .in("quotation_id", workflowIds)
              .order("published_at", { ascending: false }),
            supabase
              .from("quotation_change_requests")
              .select("id,quotation_id,official_version_id,request_text,request_status,requested_at,resolved_at")
              .in("quotation_id", workflowIds)
              .order("requested_at", { ascending: false }),
          ]);
          if (versionError) throw versionError;
          if (requestError) throw requestError;
          versionRows = (versionData || []) as OfficialQuotationVersion[];
          requestRows = (requestData || []) as QuotationChangeRequest[];
        }
      }

      const stateMap = Object.fromEntries(
        stateRows.map((state) => [state.quotation_id, state]),
      ) as Record<string, QuotationWorkflowState>;
      const versionMap = versionRows.reduce<Record<string, OfficialQuotationVersion[]>>(
        (acc, version) => {
          (acc[version.quotation_id] ||= []).push(version);
          return acc;
        },
        {},
      );
      const requestMap = requestRows.reduce<Record<string, QuotationChangeRequest[]>>(
        (acc, request) => {
          (acc[request.quotation_id] ||= []).push(request);
          return acc;
        },
        {},
      );

      const loadedQuotations = rawQuotations.flatMap((quotation) => {
        const workflowState = stateMap[quotation.id];
        if (!workflowState) return [quotation]; // Compatibilidad con presupuestos antiguos.

        const visibleVersion = latestClientVisibleVersion(versionMap[quotation.id] || []);
        if (!visibleVersion) return []; // No mostrar hasta que el PDF/hash oficial esté registrado.

        return [
          quotationFromOfficialVersion(quotation, visibleVersion, workflowState),
        ];
      });

      setOfficialVersions(versionMap);
      setChangeRequests(requestMap);
      setQuotations(loadedQuotations);

      const projectIds = Array.from(
        new Set(
          loadedQuotations
            .map((quotation) => quotation.project_id)
            .filter((id): id is string => Boolean(id)),
        ),
      );

      if (projectIds.length > 0) {
        const { data: projectData, error: projectError } = await supabase
          .from("projects")
          .select("id,nombre,user_id")
          .in("id", projectIds);

        if (projectError) throw projectError;

        setProjects((projectData || []) as Project[]);
const ownerIds = Array.from(
  new Set(
    (projectData || [])
      .map((project) => project.user_id)
      .filter((id): id is string => Boolean(id)),
  ),
);

if (ownerIds.length > 0) {
  const { data: ownerData, error: ownerError } = await supabase.rpc(
    "get_company_profile_names",
    {
      p_user_ids: ownerIds,
    },
  );

  if (ownerError) throw ownerError;

  setProjectOwners((ownerData || []) as ProjectOwnerProfile[]);
} else {
  setProjectOwners([]);
}


      } else {
        setProjects([]);
        setProjectOwners([]);
      }

      if (loadedQuotations.length > 0) {
        const { data: acceptanceData, error: acceptanceError } =
          await supabase
            .from("quotation_acceptances")
            .select("quotation_id,accepted_at,quotation_version")
            .in(
              "quotation_id",
              loadedQuotations.map((quotation) => quotation.id),
            );

        if (acceptanceError) throw acceptanceError;

        setAcceptances((acceptanceData || []) as QuotationAcceptance[]);
      } else {
        setAcceptances([]);
      }
    } catch (loadError) {
      console.error(loadError);
      setError(
        loadError instanceof Error
          ? loadError.message
          : "No se pudieron cargar los presupuestos.",
      );
    } finally {
      setLoading(false);
    }
  }, [user]);

  const loadQuotationDetail = useCallback(
    async (quotationId: string) => {
      if (!user) return;

      setDetailLoading(true);
      setError(null);

      try {
        const { data, error: quotationError } = await supabase
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
              "document_sha256",
              "quotation_version",
              "created_at",
              "updated_at",
            ].join(","),
          )
          .eq("id", quotationId)
          .maybeSingle();

        if (quotationError) throw quotationError;

        if (!data) {
          throw new Error("No se ha encontrado el presupuesto solicitado.");
        }

        const baseQuotation = data as unknown as Quotation;
        const { data: workflowStateData, error: workflowStateError } = await supabase
          .from("quotation_workflow_state")
          .select("quotation_id,current_version_id,workflow_status,updated_at")
          .eq("quotation_id", quotationId)
          .maybeSingle();
        if (workflowStateError) throw workflowStateError;

        let quotation = baseQuotation;
        if (workflowStateData) {
          const state = workflowStateData as QuotationWorkflowState;
          const [
            { data: versionData, error: versionError },
            { data: requestData, error: requestError },
          ] = await Promise.all([
            supabase
              .from("quotation_official_versions")
              .select("id,quotation_id,version_label,content_snapshot,document_path,document_sha256,is_current,published_at,client_notified_at,client_response,responded_at")
              .eq("quotation_id", quotationId)
              .order("published_at", { ascending: false }),
            supabase
              .from("quotation_change_requests")
              .select("id,quotation_id,official_version_id,request_text,request_status,requested_at,resolved_at")
              .eq("quotation_id", quotationId)
              .order("requested_at", { ascending: false }),
          ]);
          if (versionError) throw versionError;
          if (requestError) throw requestError;

          const versions = (versionData || []) as OfficialQuotationVersion[];
          const requests = (requestData || []) as QuotationChangeRequest[];
          const visibleVersion = latestClientVisibleVersion(versions);
          setOfficialVersions((current) => ({ ...current, [quotationId]: versions }));
          setChangeRequests((current) => ({ ...current, [quotationId]: requests }));

          if (!visibleVersion) {
            throw new Error("Este presupuesto todavía no tiene una versión oficial disponible para el cliente.");
          }
          quotation = quotationFromOfficialVersion(baseQuotation, visibleVersion, state);
        }
        setSelectedQuotation(quotation);

        if (
          quotation.project_id &&
          !projects.some((project) => project.id === quotation.project_id)
        ) {
          const { data: projectData, error: projectError } = await supabase
            .from("projects")
            .select("id,nombre,user_id")
            .eq("id", quotation.project_id)
            .maybeSingle();

          if (projectError) throw projectError;

          if (projectData) {
            setProjects((current) => [
              ...current.filter((project) => project.id !== projectData.id),
              projectData as Project,
            ]);

            if (projectData.user_id) {
              const { data: ownerData, error: ownerError } =
                await supabase.rpc("get_company_profile_names", {
                  p_user_ids: [projectData.user_id],
                });

              if (ownerError) throw ownerError;

              setProjectOwners((current) => [
                ...current.filter((owner) => owner.id !== projectData.user_id),
                ...((ownerData || []) as ProjectOwnerProfile[]),
              ]);
            }
          }
        }
      } catch (detailError) {
        console.error(detailError);
        setError(
          detailError instanceof Error
            ? detailError.message
            : "No se pudo cargar el presupuesto.",
        );
        setSelectedQuotation(null);
      } finally {
        setDetailLoading(false);
      }
    },
    [projects, user],
  );

  useEffect(() => {
    if (!user || authLoading) return;
    void loadQuotations();
  }, [user, authLoading, loadQuotations]);

  useEffect(() => {
    if (!selectedQuotationId || !user) return;

    const quotationFromList = quotations.find(
      (quotation) => quotation.id === selectedQuotationId,
    );

    if (quotationFromList) {
      setSelectedQuotation(quotationFromList);
    }

    void loadQuotationDetail(selectedQuotationId);
  }, [
    selectedQuotationId,
    user,
    quotations,
    loadQuotationDetail,
  ]);

  const projectById = useMemo(
    () => new Map(projects.map((project) => [project.id, project])),
    [projects],
  );
const projectOwnerById = useMemo(
  () => new Map(projectOwners.map((owner) => [owner.id, owner])),
  [projectOwners],
);
  const acceptanceByQuotation = useMemo(
    () =>
      new Map(
        acceptances.map((acceptance) => [
          acceptance.quotation_id,
          acceptance,
        ]),
      ),
    [acceptances],
  );

  const counts = useMemo(
    () => ({
      total: quotations.length,
      pending: quotations.filter(
        (quotation) => quotationDisplayStatus(quotation) === "Pendiente",
      ).length,
      accepted: quotations.filter(
        (quotation) => quotationDisplayStatus(quotation) === "Aceptado",
      ).length,
      rejected: quotations.filter(
        (quotation) => quotationDisplayStatus(quotation) === "Rechazado",
      ).length,
    }),
    [quotations],
  );

  const filteredQuotations = useMemo(() => {
    const normalizedSearch = normalize(search);

    return quotations.filter((quotation) => {
      if (
        statusFilter !== "all" &&
        quotationDisplayStatus(quotation) !== statusFilter
      ) {
        return false;
      }

      if (!normalizedSearch) return true;

      const projectName = quotation.project_id
        ? projectById.get(quotation.project_id)?.nombre || ""
        : "";

      return [
        quotation.titulo,
        quotation.numero_presupuesto,
        quotation.descripcion_detallada,
        projectName,
      ]
        .map(normalize)
        .some((value) => value.includes(normalizedSearch));
    });
  }, [projectById, quotations, search, statusFilter]);

  const selectedProjectName = selectedQuotation?.project_id
    ? projectById.get(selectedQuotation.project_id)?.nombre
    : undefined;

  const projectOwnerLabel = (projectId: string | null) => {
    const ownerId = projectId ? projectById.get(projectId)?.user_id : null;

    if (!ownerId) return "Sin responsable asignado";
    if (ownerId === user?.id) return "Tú";

    return projectOwnerById.get(ownerId)?.nombre?.trim() || "Responsable del proyecto";
  };

  const selectedProjectOwnerLabel = projectOwnerLabel(
    selectedQuotation?.project_id ?? null,
  );

  const isProjectOwner = (projectId: string | null) =>
    Boolean(projectId && user?.id && projectById.get(projectId)?.user_id === user.id);

  const selectedAcceptance = selectedQuotation
    ? acceptanceByQuotation.get(selectedQuotation.id)
    : undefined;

  const isQuotationExpired = (quotation: Quotation) => {
    if (
      quotation.estado !== "Pendiente" ||
      !quotation.fecha_validez
    ) {
      return false;
    }

    return new Date(quotation.fecha_validez).getTime() < Date.now();
  };

  const createQuotationSignedUrl = async (
    quotation: Quotation,
    download = false,
  ) => {
    if (!quotation.document_path) {
      toast.error("Este presupuesto no tiene un PDF asociado.");
      return null;
    }

    const { data, error: storageError } = await supabase.storage
      .from("quotations")
      .createSignedUrl(
        quotation.document_path,
        60 * 10,
        download ? { download: true } : undefined,
      );

    if (storageError) {
      console.error(storageError);
      toast.error("No se pudo acceder al PDF del presupuesto.");
      return null;
    }

    if (!data?.signedUrl) {
      toast.error("No se pudo generar el enlace del PDF.");
      return null;
    }

    return data.signedUrl;
  };

const handleViewPdf = async (
  quotation: Quotation,
): Promise<boolean> => {
  const pdfWindow = window.open("", "_blank");

  if (!pdfWindow) {
    toast.error("El navegador ha bloqueado la apertura del PDF.");
    return false;
  }

  const signedUrl = await createQuotationSignedUrl(quotation);

  if (!signedUrl) {
    pdfWindow.close();
    return false;
  }

  pdfWindow.location.href = signedUrl;

  return true;
};

  const handleDownloadPdf = async (quotation: Quotation) => {
    const signedUrl = await createQuotationSignedUrl(quotation, true);

    if (signedUrl) {
      window.location.assign(signedUrl);
    }
  };

  const handleViewVersionPdf = async (version: OfficialQuotationVersion) => {
    if (!version.document_path || !version.document_sha256 || !version.client_notified_at) {
      toast.error("Esta versión todavía no está disponible para el cliente.");
      return;
    }
    const pdfWindow = window.open("", "_blank");
    if (!pdfWindow) {
      toast.error("El navegador ha bloqueado la apertura del PDF.");
      return;
    }
    const { data, error: storageError } = await supabase.storage
      .from("quotations")
      .createSignedUrl(version.document_path, 60 * 10);
    if (storageError || !data?.signedUrl) {
      pdfWindow.close();
      console.error(storageError);
      toast.error("No se pudo acceder al PDF de esta versión.");
      return;
    }
    pdfWindow.location.href = data.signedUrl;
  };

  const handleDownloadVersionPdf = async (version: OfficialQuotationVersion) => {
    if (!version.document_path || !version.document_sha256 || !version.client_notified_at) {
      toast.error("Esta versión todavía no está disponible para el cliente.");
      return;
    }
    const { data, error: storageError } = await supabase.storage
      .from("quotations")
      .createSignedUrl(version.document_path, 60 * 10, { download: true });
    if (storageError || !data?.signedUrl) {
      console.error(storageError);
      toast.error("No se pudo descargar el PDF de esta versión.");
      return;
    }
    window.location.assign(data.signedUrl);
  };
const handleViewSignedDocument = async (
  document: QuotationSignedDocument,
) => {
  const path = document.signed_document_path?.trim();

  if (!path) {
    toast.error("El registro no contiene la ruta del PDF firmado.");
    console.error("Documento firmado sin ruta:", document);
    return;
  }

  console.log("PDF firmado solicitado:", {
    bucket: "quotations",
    path,
    quotation_id: document.quotation_id,
    official_version_id: document.official_version_id,
  });

  const { data, error } = await supabase.storage
    .from("quotations")
    .createSignedUrl(path, 600);

  if (error) {
    console.error("Error al generar URL del PDF firmado:", {
      message: error.message,
      name: error.name,
      path,
      bucket: "quotations",
      document,
    });

    toast.error(`No se pudo abrir el PDF firmado: ${error.message}`);
    return;
  }

  if (!data?.signedUrl) {
    console.error("Supabase no devolvió una URL firmada:", data);
    toast.error("Supabase no ha devuelto la URL del PDF firmado.");
    return;
  }

  window.open(data.signedUrl, "_blank", "noopener,noreferrer");
};

const handleDownloadSignedDocument = async (
  document: QuotationSignedDocument,
) => {
  if (!document.signed_document_path) {
    toast.error("El PDF firmado no está disponible.");
    return;
  }

  const { data, error: storageError } = await supabase.storage
    .from("quotations")
    .createSignedUrl(document.signed_document_path, 60 * 10, {
      download: true,
    });

  if (storageError || !data?.signedUrl) {
    console.error(storageError);
    toast.error("No se pudo descargar el PDF firmado.");
    return;
  }

  window.location.assign(data.signedUrl);
};
  const handleRequestQuotationChanges = async (
    quotation: Quotation,
    requestText: string,
  ) => {
    if (!quotation.workflow_status || quotation.workflow_status !== "presented") {
      throw new Error("Solo puedes solicitar cambios sobre un presupuesto presentado.");
    }
    if (quotation.workflow_waiting_for_document) {
      throw new Error("La nueva versión todavía se está preparando. Inténtalo de nuevo cuando esté disponible.");
    }
    const { error: requestError } = await supabase.rpc("request_quotation_changes", {
      p_quotation_id: quotation.id,
      p_request_text: requestText,
    });
    if (requestError) throw requestError;
    toast.success("La solicitud de cambios se ha enviado correctamente.");
    await loadQuotations();
    await loadQuotationDetail(quotation.id);
  };

const respondToQuotation = async (
  quotation: Quotation,
  nextStatus: "Aceptado" | "Rechazado",
) => {
  // La aceptación solo puede realizarse mediante firma electrónica.
  if (nextStatus === "Aceptado") {
    toast.error("Para aceptar el presupuesto debes firmarlo.");
    return;
  }

  if (quotation.estado !== "Pendiente") {
    toast.error("Este presupuesto ya no admite respuestas.");
    return;
  }

  if (
    quotation.workflow_status &&
    quotation.workflow_status !== "presented"
  ) {
    toast.error("Este presupuesto no admite nuevas respuestas.");
    return;
  }

  if (quotation.workflow_waiting_for_document) {
    toast.error(
      "La nueva versión oficial todavía no está disponible para responder.",
    );
    return;
  }

  if (!isProjectOwner(quotation.project_id)) {
    toast.error(
      "Solo el responsable del proyecto puede responder a este presupuesto.",
    );
    return;
  }

  if (!window.confirm("¿Confirmas que quieres rechazar este presupuesto?")) {
    return;
  }

  setRespondingQuotationId(quotation.id);

  try {
    const { error: rpcError } = await supabase.rpc(
      "respond_to_quotation",
      {
        p_estado: "Rechazado",
        p_quotation_id: quotation.id,
      },
    );

    if (rpcError) {
      throw rpcError;
    }

    toast.success("Presupuesto rechazado correctamente.");

    setPdfOpened(false);
    setAcknowledged(false);

    await loadQuotations();

    if (selectedQuotationId === quotation.id) {
      await loadQuotationDetail(quotation.id);
    }
  } catch (responseError) {
    console.error(responseError);

    toast.error(
      responseError instanceof Error
        ? responseError.message
        : "No se pudo registrar el rechazo.",
    );
  } finally {
    setRespondingQuotationId(null);
  }
};
const handleSignAndAcceptQuotation = async (
  quotation: Quotation,
  signaturePngBase64: string,
) => {
  if (quotation.estado !== "Pendiente") {
    toast.error("Este presupuesto ya no admite aceptación.");
    return;
  }

  if (
    quotation.workflow_status &&
    quotation.workflow_status !== "presented"
  ) {
    toast.error("Este presupuesto no admite nuevas respuestas.");
    return;
  }

  if (quotation.workflow_waiting_for_document) {
    toast.error(
      "La nueva versión oficial todavía no está disponible.",
    );
    return;
  }

  if (!isProjectOwner(quotation.project_id)) {
    toast.error(
      "Solo el responsable del proyecto puede aceptar este presupuesto.",
    );
    return;
  }

  if (!pdfOpened || !acknowledged) {
    toast.error(
      "Debes consultar el PDF y confirmar que lo has leído antes de firmar.",
    );
    return;
  }

  if (!signaturePngBase64) {
    toast.error("Debes dibujar tu firma antes de continuar.");
    return;
  }

  const currentVersion = (
    officialVersions[quotation.id] || []
  ).find(
    (version) =>
      version.is_current &&
      Boolean(version.client_notified_at) &&
      Boolean(version.document_path) &&
      Boolean(version.document_sha256),
  );

  if (!currentVersion) {
    toast.error(
      "No se ha encontrado la versión oficial vigente del presupuesto.",
    );
    return;
  }

  setRespondingQuotationId(quotation.id);

  try {
    /*
     * 1. Registrar que el cliente ha leído el PDF oficial.
     *
     * La RPC obtiene del servidor el documento y su SHA-256.
     * No enviamos esos valores desde el frontend.
     */
    const {
      data: acknowledgement,
      error: acknowledgementError,
    } = await supabase.rpc(
      "record_quotation_document_acknowledgement",
      {
        p_quotation_id: quotation.id,
      },
    );

    if (acknowledgementError) {
      throw acknowledgementError;
    }

    if (!acknowledgement?.id) {
      throw new Error(
        "No se ha podido registrar la lectura del documento.",
      );
    }

    /*
     * 2. Enviar la firma a la Edge Function.
     *
     * La Edge Function genera el PDF firmado y ejecuta
     * finalize_quotation_signed_acceptance.
     */
    const { data, error: signatureError } =
      await supabase.functions.invoke(
        "set-quotation-document-hash",
        {
          body: {
            action: "sign_and_accept_quotation",
            quotation_id: quotation.id,
            official_version_id: currentVersion.id,
            signature_png_base64: signaturePngBase64,
          },
        },
      );

    if (signatureError) {
      throw signatureError;
    }

    if (!data?.success) {
      throw new Error(
        data?.error ||
          "No se ha podido firmar y aceptar el presupuesto.",
      );
    }

    toast.success(
      "Presupuesto firmado y aceptado correctamente.",
    );

    setPdfOpened(false);
    setAcknowledged(false);

    await loadQuotations();
    await loadQuotationDetail(quotation.id);
  } catch (signatureError) {
    console.error(
      "Error firmando el presupuesto:",
      signatureError,
    );

    toast.error(
      signatureError instanceof Error
        ? signatureError.message
        : "No se ha podido firmar y aceptar el presupuesto.",
    );
  } finally {
    setRespondingQuotationId(null);
  }
};

  if (authLoading || loading) {
    return (
      <div className="min-h-screen bg-[#FBFCFE]">
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

          <div className="mx-auto flex min-h-screen max-w-[1380px] items-center justify-center px-5 sm:px-8 lg:px-12">
            <div className="text-center">
              <Loader2 className="mx-auto mb-3 h-7 w-7 animate-spin text-[#173B8F]" />
              <p className="text-[12px] text-[#718096]">
                Cargando presupuestos...
              </p>
            </div>
          </div>
        </main>
      </div>
    );
  }

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
                onClick={closeQuotation}
                className="mb-5 inline-flex items-center gap-1.5 text-[11px] font-medium text-[#718096] transition-colors hover:text-[#173B8F]"
              >
                <ArrowRight className="h-3.5 w-3.5 rotate-180" />
                Volver a mis presupuestos
              </button>

              {detailLoading && !selectedQuotation ? (
                <div className="py-6">
                  <Loader2 className="h-6 w-6 animate-spin text-[#173B8F]" />
                </div>
              ) : selectedQuotation ? (
                <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
                  <div>
                    <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                      Área de Cliente
                    </p>
                    <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">
                      {selectedQuotation.titulo || "Presupuesto"}
                    </h1>
                    <p className="mt-1.5 text-sm text-[#718096]">
                      {selectedQuotation.numero_presupuesto}
                      {selectedProjectName
                        ? ` · ${selectedProjectName}`
                        : ""}
                    </p>
                    {selectedQuotation.project_id && (
                      <p className="mt-1 text-[10px] font-medium uppercase tracking-[0.1em] text-[#98A2B3]">
                        Responsable · {selectedProjectOwnerLabel}
                      </p>
                    )}
                  </div>

                  <span
                    className={[
                      "inline-flex w-fit rounded-full border px-3 py-1.5 text-[10px] font-semibold",
                      quotationStatusClasses(quotationDisplayStatus(selectedQuotation)),
                    ].join(" ")}
                  >
                    <span
                      className={[
                        "mr-2 mt-[3px] h-1.5 w-1.5 rounded-full",
                        quotationStatusDot(quotationDisplayStatus(selectedQuotation)),
                      ].join(" ")}
                    />
                    {statusLabel(quotationDisplayStatus(selectedQuotation))}
                  </span>
                </div>
              ) : null}
            </section>

            {error && !selectedQuotation ? (
              <div className="border-y border-[#E7EBF0] py-8">
                <div className="flex items-start gap-3">
                  <AlertCircle
                    className="mt-0.5 h-5 w-5 shrink-0 text-[#B53A3A]"
                    strokeWidth={1.7}
                  />
                  <div>
                    <p className="text-[13px] font-semibold text-[#26344A]">
                      No se pudo cargar el presupuesto
                    </p>
                    <p className="mt-1 text-[12px] leading-5 text-[#718096]">
                      {error}
                    </p>
                  </div>
                </div>
              </div>
            ) : selectedQuotation ? (
              <QuotationDetail
                quotation={selectedQuotation}
                projectName={selectedProjectName}
                projectOwnerLabel={selectedProjectOwnerLabel}
                isProjectOwner={isProjectOwner(selectedQuotation.project_id)}
                acceptance={selectedAcceptance}
                workflowStatus={selectedQuotation.workflow_status}
                workflowWaitingForDocument={Boolean(selectedQuotation.workflow_waiting_for_document)}
                officialVersions={officialVersions[selectedQuotation.id] || []}
                changeRequests={changeRequests[selectedQuotation.id] || []}
                signedDocuments={signedDocuments[selectedQuotation.id] || []}
                onRequestChanges={(text) => handleRequestQuotationChanges(selectedQuotation, text)}
                onViewVersionPdf={handleViewVersionPdf}
                onDownloadVersionPdf={handleDownloadVersionPdf}
                onViewSignedDocument={handleViewSignedDocument}
                onDownloadSignedDocument={handleDownloadSignedDocument}
  pdfOpened={pdfOpened}
  acknowledged={acknowledged}
  onViewPdf={async () => {
    const opened = await handleViewPdf(selectedQuotation);

    if (opened) {
      setPdfOpened(true);
    }
  }}
  onDownloadPdf={() => handleDownloadPdf(selectedQuotation)}
  onAcknowledgedChange={setAcknowledged}
  onRespond={(status) =>
    respondToQuotation(selectedQuotation, status)
  }
  onSignAndAccept={(signaturePngBase64) =>
  handleSignAndAcceptQuotation(
    selectedQuotation,
    signaturePngBase64,
  )
}
  responding={
    respondingQuotationId === selectedQuotation.id
  }
/>
            ) : (
              <div className="border-y border-[#E7EBF0] py-14 text-center">
                <Loader2 className="mx-auto h-7 w-7 animate-spin text-[#173B8F]" />
              </div>
            )}
          </div>
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
                  Mis presupuestos
                </h1>
                <p className="mt-1.5 max-w-2xl text-sm text-[#718096]">
                  Consulta el estado, importe, documentación y toda la
                  información asociada a tus presupuestos.
                </p>
              </div>
            </div>
          </section>

          <section className="mb-10 grid grid-cols-2 divide-x divide-y divide-[#E5E9EF] border-y border-[#E5E9EF] bg-white/40 lg:grid-cols-4 lg:divide-y-0">
            {[
              {
                label: "Total de presupuestos",
                value: counts.total,
                detail:
                  counts.total === 1
                    ? "Presupuesto registrado"
                    : "Presupuestos registrados",
                icon: FileText,
                active: counts.total > 0,
              },
              {
                label: "Presupuestos pendientes",
                value: counts.pending,
                detail: "Pendientes de respuesta",
                icon: Clock3,
                active: counts.pending > 0,
              },
              {
                label: "Presupuestos aceptados",
                value: counts.accepted,
                detail: "Aceptados",
                icon: Check,
                active: counts.accepted > 0,
              },
              {
                label: "Presupuestos rechazados",
                value: counts.rejected,
                detail: "Rechazados",
                icon: AlertCircle,
                active: counts.rejected > 0,
              },
            ].map((item) => {
              const Icon = item.icon;

              return (
                <div
                  key={item.label}
                  className={[
                    "min-h-[116px] px-5 py-5 sm:px-7",
                    item.active
                      ? "bg-[#173B8F] text-white"
                      : "bg-white/50 text-[#1E2D43]",
                  ].join(" ")}
                >
                  <div className="flex h-full items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p
                        className={[
                          "text-[10px] font-semibold uppercase tracking-[0.13em]",
                          item.active
                            ? "text-white/75"
                            : "text-[#8A95A4]",
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
                          item.active
                            ? "text-white/80"
                            : "text-[#8A95A4]",
                        ].join(" ")}
                      >
                        {item.detail}
                      </p>
                    </div>

                    <Icon
                      className={[
                        "mt-0.5 h-4 w-4 shrink-0",
                        item.active
                          ? "text-white/80"
                          : "text-[#A1AAB7]",
                      ].join(" ")}
                      strokeWidth={1.7}
                    />
                  </div>
                </div>
              );
            })}
          </section>

          <section>
            <SectionTitle
              eyebrow="Cartera de presupuestos"
              title="Todos tus presupuestos"
              action={
                <span className="text-[11px] text-[#8A95A5]">
                  {filteredQuotations.length} de {quotations.length}
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
                  placeholder="Buscar presupuesto por título, número o proyecto..."
                  className="h-full min-w-0 !border-0 !bg-transparent !p-0 text-[13px] text-[#344054] !shadow-none !outline-none placeholder:text-[#9AA4B2] focus:!border-0 focus:!outline-none focus:!ring-0 focus-visible:!border-0 focus-visible:!outline-none focus-visible:!ring-0 focus-visible:ring-offset-0"
                />
              </div>

              <div className="mt-5 flex flex-wrap items-center gap-x-3 gap-y-2.5">
                <span className="mr-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-[#8A95A5]">
                  Estado
                </span>

                {QUOTATION_STATUSES.map((status) => {
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

            {error ? (
              <div className="border-y border-[#E7EBF0] py-8">
                <div className="flex items-start gap-3">
                  <AlertCircle
                    className="mt-0.5 h-5 w-5 shrink-0 text-[#B53A3A]"
                    strokeWidth={1.7}
                  />

                  <div>
                    <p className="text-[13px] font-semibold text-[#26344A]">
                      No se pudieron cargar los presupuestos
                    </p>
                    <p className="mt-1 text-[12px] leading-5 text-[#718096]">
                      {error}
                    </p>
                  </div>
                </div>
              </div>
            ) : filteredQuotations.length === 0 ? (
              <div className="border-y border-[#E7EBF0] py-12 text-center">
                <FileText
                  className="mx-auto mb-4 h-7 w-7 text-[#AAB3BF]"
                  strokeWidth={1.6}
                />

                <p className="text-[14px] font-semibold text-[#344054]">
                  {quotations.length
                    ? "No hay presupuestos que coincidan"
                    : "Todavía no tienes presupuestos"}
                </p>

                <p className="mx-auto mt-2 max-w-md text-[12px] leading-5 text-[#8792A2]">
                  {quotations.length
                    ? "Prueba con otro título, número, proyecto o estado."
                    : "Cuando tengas un presupuesto asociado a tu cuenta aparecerá en este apartado."}
                </p>
              </div>
            ) : (
              <div className="space-y-5">
                {filteredQuotations.map((quotation) => {
                  const projectName = quotation.project_id
                    ? projectById.get(quotation.project_id)?.nombre
                    : undefined;

                  const serviceCount = getServiceCount(
                    quotation.servicios_incluidos,
                  );

                  return (
                    <article
                      key={quotation.id}
                      className="group relative overflow-hidden rounded-[20px] border border-[#E1E7EE] bg-white transition-all duration-200 hover:-translate-y-[1px] hover:border-[#CDD6E0] hover:shadow-[0_14px_34px_rgba(24,42,69,0.07)]"
                    >
                      <div className="relative px-5 py-5 sm:px-7 sm:py-6">
                        <div className="flex items-start gap-6">
                          <div className="min-w-0 flex-1">
                            <div className="flex flex-wrap items-center gap-2.5">
                              <span
                                className={[
                                  "inline-flex h-2 w-2 shrink-0 rounded-full",
                                  quotationStatusDot(quotationDisplayStatus(quotation)),
                                ].join(" ")}
                                aria-hidden="true"
                              />

                              <h3 className="min-w-0 text-[17px] font-semibold leading-tight tracking-[-0.015em] text-[#1F3048] sm:text-[18px]">
                                {quotation.titulo || "Presupuesto"}
                              </h3>

                              <span
                                className={[
                                  "rounded-full border px-2.5 py-1 text-[10px] font-semibold leading-none",
                                  quotationStatusClasses(quotationDisplayStatus(quotation)),
                                ].join(" ")}
                              >
                                {statusLabel(quotationDisplayStatus(quotation))}
                              </span>
                            </div>

                            <p className="mt-2 text-[10px] font-medium uppercase tracking-[0.1em] text-[#98A2B3]">
                              {quotation.numero_presupuesto}
                              {projectName ? ` · ${projectName}` : ""}
                            </p>

                            {quotation.project_id && (
                              <p className="mt-1 text-[10px] font-medium uppercase tracking-[0.1em] text-[#98A2B3]">
                                Responsable · {projectOwnerLabel(quotation.project_id)}
                              </p>
                            )}

                            <p className="mt-3 max-w-3xl text-[12px] leading-5 text-[#718096]">
                              {quotation.descripcion_detallada ||
                                "Este presupuesto todavía no tiene una descripción disponible."}
                            </p>

                            <div className="mt-5 flex flex-wrap items-center gap-x-6 gap-y-3">
                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Emisión
                                </p>
                                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                                  {formatCompactDate(quotation.fecha_emision)}
                                </p>
                              </div>

                              <div className="h-7 w-px bg-[#E8ECF1]" />

                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Validez
                                </p>
                                <p
                                  className={[
                                    "mt-1 text-[11px] font-medium",
                                    isQuotationExpired(quotation)
                                      ? "text-[#A56A00]"
                                      : "text-[#445166]",
                                  ].join(" ")}
                                >
                                  {formatCompactDate(quotation.fecha_validez)}
                                </p>
                              </div>

                              <div className="h-7 w-px bg-[#E8ECF1]" />

                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Servicios
                                </p>
                                <p className="mt-1 text-[11px] font-medium text-[#445166]">
                                  {serviceCount
                                    ? `${serviceCount} ${
                                        serviceCount === 1
                                          ? "servicio"
                                          : "servicios"
                                      }`
                                    : "Sin servicios"}
                                </p>
                              </div>

                              <div className="h-7 w-px bg-[#E8ECF1]" />

                              <div>
                                <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                                  Total
                                </p>
                                <p className="mt-1 text-[11px] font-semibold text-[#26344A]">
                                  {formatCurrency(quotation.precio_total)}
                                </p>
                              </div>
                            </div>

                            <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 border-t border-[#EEF1F4] pt-4 text-[11px]">
                              <span className="inline-flex items-center gap-1.5 text-[#7A8595]">
                                <FileText
                                  className="h-3.5 w-3.5 text-[#9AA4B2]"
                                  strokeWidth={1.7}
                                />
                                Versión{" "}
                                {quotation.workflow_version_label || quotation.quotation_version || 1}
                              </span>

                              {quotation.document_path && (
                                <>
                                  <span className="hidden h-4 w-px bg-[#E5E9EE] sm:block" />

                                  <span className="inline-flex items-center gap-1.5 text-[#7A8595]">
                                    <Download
                                      className="h-3.5 w-3.5 text-[#9AA4B2]"
                                      strokeWidth={1.7}
                                    />
                                    PDF disponible
                                  </span>
                                </>
                              )}

                              <div className="ml-auto flex items-center gap-2">
                                {quotation.document_path && (
                                  <>
                                    <button
                                      type="button"
                                      onClick={() =>
                                        void handleViewPdf(quotation)
                                      }
                                      aria-label={`Ver PDF de ${quotation.numero_presupuesto}`}
                                      title="Ver PDF"
                                      className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-[#DCE2E9] bg-white text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#F3F6FC] hover:text-[#173B8F]"
                                    >
                                      <FileText
                                        className="h-4 w-4"
                                        strokeWidth={1.7}
                                      />
                                    </button>

                                    <button
                                      type="button"
                                      onClick={() =>
                                        void handleDownloadPdf(quotation)
                                      }
                                      aria-label={`Descargar PDF de ${quotation.numero_presupuesto}`}
                                      title="Descargar PDF"
                                      className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-[#DCE2E9] bg-white text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#F3F6FC] hover:text-[#173B8F]"
                                    >
                                      <Download
                                        className="h-4 w-4"
                                        strokeWidth={1.7}
                                      />
                                    </button>
                                  </>
                                )}

                                <button
                                  type="button"
                                  onClick={() => openQuotation(quotation.id)}
                                  className="inline-flex items-center gap-1.5 font-semibold text-[#173B8F] transition-all hover:gap-2 hover:text-[#102A66]"
                                >
                                  Consultar presupuesto
                                  <ArrowRight
                                    className="h-3.5 w-3.5"
                                  />
                                </button>
                              </div>
                            </div>
                          </div>
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

function QuotationDetail({
  quotation,
  projectName,
  projectOwnerLabel,
  isProjectOwner,
  acceptance,
  workflowStatus,
  workflowWaitingForDocument,
  officialVersions,
changeRequests,
signedDocuments,
onRequestChanges,
onViewVersionPdf,
onDownloadVersionPdf,
onViewSignedDocument,
onDownloadSignedDocument,
  pdfOpened,
  acknowledged,
  onViewPdf,
  onDownloadPdf,
  onAcknowledgedChange,
  onRespond,
  onSignAndAccept,
  responding,
}: {
  quotation: Quotation;
  projectName?: string;
  projectOwnerLabel: string;
  isProjectOwner: boolean;
  acceptance?: QuotationAcceptance;
  workflowStatus?: WorkflowStatus;
  workflowWaitingForDocument: boolean;
 officialVersions: OfficialQuotationVersion[];
changeRequests: QuotationChangeRequest[];
signedDocuments: QuotationSignedDocument[];
onRequestChanges: (text: string) => Promise<void>;
onViewVersionPdf: (version: OfficialQuotationVersion) => Promise<void>;
onDownloadVersionPdf: (version: OfficialQuotationVersion) => Promise<void>;
onViewSignedDocument: (
  document: QuotationSignedDocument,
) => Promise<void>;
onDownloadSignedDocument: (
  document: QuotationSignedDocument,
) => Promise<void>;
  pdfOpened: boolean;
  acknowledged: boolean;
  onViewPdf: () => Promise<void>;
  onDownloadPdf: () => void;
  onAcknowledgedChange: (value: boolean) => void;
  onRespond: (status: "Aceptado" | "Rechazado") => void;
onSignAndAccept: (signaturePngBase64: string) => void;
responding: boolean;
}) {
  const [showChangeRequest, setShowChangeRequest] = useState(false);
  const [changeRequestText, setChangeRequestText] = useState("");
  const [submittingChangeRequest, setSubmittingChangeRequest] = useState(false);

  const services = getQuotationServices(quotation.servicios_incluidos);
  const visibleVersions = officialVersions
    .filter(
      (version) =>
        Boolean(version.client_notified_at) &&
        Boolean(version.document_path) &&
        Boolean(version.document_sha256),
    )
    .sort(
      (a, b) =>
        new Date(b.published_at).getTime() -
        new Date(a.published_at).getTime(),
    );
  const currentVisibleVersion = latestClientVisibleVersion(visibleVersions);
  const canRespondToWorkflow =
    !workflowStatus ||
    (workflowStatus === "presented" &&
      !workflowWaitingForDocument &&
      currentVisibleVersion?.id ===
        officialVersions.find((version) => version.is_current)?.id);
  const displayStatus = quotationDisplayStatus(quotation);

  const submitChangeRequest = async () => {
    const text = changeRequestText.trim();
    if (!text) {
      toast.error("Describe los cambios que necesitas solicitar.");
      return;
    }
    setSubmittingChangeRequest(true);
    try {
      await onRequestChanges(text);
      setChangeRequestText("");
      setShowChangeRequest(false);
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : "No se pudo enviar la solicitud de cambios.",
      );
    } finally {
      setSubmittingChangeRequest(false);
    }
  };

  const ivaImporte = Number(quotation.precio_total ?? 0) -
    Number(quotation.precio_base ?? 0);

  const importeAPagar = Number(quotation.precio_total ?? 0) -
    Number(quotation.irpf_importe ?? 0);

  const expired =
    quotation.estado === "Pendiente" &&
    Boolean(quotation.fecha_validez) &&
    new Date(quotation.fecha_validez as string).getTime() < Date.now();

  return (
    <div className="space-y-8">
      <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_320px]">
        <section className="border border-[#E3E8EE] bg-white p-5 sm:p-7">
          <div className="flex items-start justify-between gap-4">
            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
                Detalle del presupuesto
              </p>
              <h2 className="mt-1 text-xl font-semibold tracking-tight text-[#182A45]">
                {quotation.titulo || "Presupuesto"}
              </h2>
            </div>

            {quotation.document_path && (
              <div className="flex shrink-0 items-center gap-2">
                <button
                  type="button"
                  onClick={onViewPdf}
                  aria-label="Ver PDF"
                  title="Ver PDF"
                  className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-[#DCE2E9] bg-white text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#F3F6FC] hover:text-[#173B8F]"
                >
                  <FileText className="h-4 w-4" strokeWidth={1.7} />
                </button>

                <button
                  type="button"
                  onClick={onDownloadPdf}
                  aria-label="Descargar PDF"
                  title="Descargar PDF"
                  className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-[#DCE2E9] bg-white text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#F3F6FC] hover:text-[#173B8F]"
                >
                  <Download className="h-4 w-4" strokeWidth={1.7} />
                </button>
              </div>
            )}
          </div>

          <div className="mt-6 overflow-hidden border border-[#E7EBF0]">
            <div className="grid grid-cols-[minmax(0,1fr)_72px_110px] border-b border-[#E7EBF0] bg-[#F8FAFC] px-4 py-3 text-[9px] font-semibold uppercase tracking-[0.13em] text-[#8A95A5]">
              <span>Servicio</span>
              <span className="text-right">Cantidad</span>
              <span className="text-right">Importe</span>
            </div>

            {services.length > 0 ? (
              <div className="divide-y divide-[#EEF1F4]">
                {services.map((service, index) => {
                  const quantity = Number(service.cantidad ?? 0);
                  const price = Number(service.precio ?? 0);

                  return (
                    <div
                      key={`${service.descripcion || "servicio"}-${index}`}
                      className="grid grid-cols-[minmax(0,1fr)_72px_110px] px-4 py-3.5"
                    >
                      <span className="pr-4 text-[11px] leading-5 text-[#536176]">
                        {service.descripcion || "Servicio"}
                      </span>

                      <span className="text-right text-[11px] font-medium text-[#445166]">
                        {quantity}
                      </span>

                      <span className="text-right text-[11px] font-semibold text-[#26344A]">
                        {formatCurrency(quantity * price)}
                      </span>
                    </div>
                  );
                })}
              </div>
            ) : (
              <div className="px-4 py-7 text-center text-[11px] text-[#8792A2]">
                No hay servicios detallados disponibles.
              </div>
            )}
          </div>

          {quotation.descripcion_detallada && (
            <div className="mt-7 border-t border-[#EEF1F4] pt-6">
              <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                Descripción
              </p>
              <p className="mt-2 whitespace-pre-line text-[12px] leading-5 text-[#718096]">
                {quotation.descripcion_detallada}
              </p>
            </div>
          )}

          {quotation.notas && (
            <div className="mt-6 border-t border-[#EEF1F4] pt-6">
              <p className="text-[9px] font-semibold uppercase tracking-[0.14em] text-[#98A2B3]">
                Notas
              </p>
              <p className="mt-2 whitespace-pre-line text-[12px] leading-5 text-[#718096]">
                {quotation.notas}
              </p>
            </div>
          )}
        </section>

        <aside className="space-y-5">
          <section className="border border-[#E3E8EE] bg-white p-5">
            <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
              Resumen económico
            </p>

            <div className="mt-5 space-y-3">
              <EconomicRow
                label="Base imponible"
                value={formatCurrency(quotation.precio_base)}
              />

              <EconomicRow
                label={`IVA ${Number(quotation.iva_porcentaje ?? 0)}%`}
                value={formatCurrency(ivaImporte)}
              />

              {quotation.irpf_aplicado && (
                <EconomicRow
                  label={`IRPF ${Number(quotation.irpf_porcentaje ?? 0)}%`}
                  value={`− ${formatCurrency(quotation.irpf_importe)}`}
                />
              )}

              <div className="border-t border-[#EEF1F4] pt-4">
                <div className="flex items-end justify-between gap-4">
                  <span className="text-[10px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
                    A pagar
                  </span>
                  <span className="text-[21px] font-semibold tracking-tight text-[#182A45]">
                    {formatCurrency(importeAPagar)}
                  </span>
                </div>
              </div>
            </div>
          </section>

          <section className="border border-[#E3E8EE] bg-white p-5">
            <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
              Información
            </p>

            <div className="mt-5 space-y-4">
              <DetailInfo
                label="Número"
                value={quotation.numero_presupuesto}
              />

              <DetailInfo
                label="Emisión"
                value={formatDate(quotation.fecha_emision)}
              />

              <DetailInfo
                label="Validez"
                value={formatDate(quotation.fecha_validez)}
                valueClass={expired ? "text-[#A56A00]" : undefined}
              />

              {projectName && (
                <DetailInfo label="Proyecto" value={projectName} />
              )}

              <DetailInfo
                label="Responsable"
                value={projectOwnerLabel}
              />

              <DetailInfo
                label="Versión"
                value={quotation.workflow_version_label || String(quotation.quotation_version || 1)}
              />
            </div>
          </section>

          {expired && (
            <div className="border border-[#F0DEB7] bg-[#FFF7E8] px-5 py-4">
              <div className="flex items-start gap-3">
                <AlertCircle
                  className="mt-0.5 h-4 w-4 shrink-0 text-[#A56A00]"
                  strokeWidth={1.7}
                />
                <p className="text-[11px] leading-5 text-[#8B640F]">
                  La fecha de validez de este presupuesto ya ha expirado.
                </p>
              </div>
            </div>
          )}
        </aside>
      </div>

      {workflowStatus && (
        <section className="border border-[#E3E8EE] bg-white p-5 sm:p-7">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
                Historial documental
              </p>
              <h2 className="mt-1 text-[17px] font-semibold tracking-tight text-[#182A45]">
                Versiones oficiales
              </h2>
              <p className="mt-1.5 text-[11px] leading-5 text-[#718096]">
                Aquí se conservan los documentos publicados. Los borradores internos no se muestran en esta sección.
              </p>
            </div>
            {workflowStatus === "presented" &&
              !workflowWaitingForDocument &&
              quotation.estado === "Pendiente" && (
                <button
                  type="button"
                  onClick={() => setShowChangeRequest((value) => !value)}
                  className="inline-flex shrink-0 items-center gap-2 rounded-full border border-[#DCE2E9] bg-white px-4 py-2.5 text-[11px] font-semibold text-[#173B8F] transition-colors hover:border-[#173B8F] hover:bg-[#F3F6FC]"
                >
                  Solicitar cambios
                  <ArrowRight className="h-3.5 w-3.5" />
                </button>
              )}
          </div>

          {workflowWaitingForDocument && (
            <div className="mt-5 border border-[#F0DEB7] bg-[#FFF7E8] px-4 py-3">
              <p className="text-[11px] leading-5 text-[#8B640F]">
                Se está preparando una nueva versión oficial. Mientras tanto, puedes consultar la última versión publicada, pero no responder ni solicitar cambios sobre ella.
              </p>
            </div>
          )}

          {showChangeRequest && (
            <div className="mt-5 border border-[#DCE4F0] bg-[#F8FAFC] p-4 sm:p-5">
              <label className="block text-[10px] font-semibold uppercase tracking-[0.13em] text-[#7C8797]">
                Describe los cambios solicitados
              </label>
              <textarea
                value={changeRequestText}
                onChange={(event) => setChangeRequestText(event.target.value)}
                maxLength={5000}
                rows={4}
                disabled={submittingChangeRequest}
                placeholder="Indica qué aspectos del presupuesto necesitas modificar..."
                className="mt-3 w-full resize-y rounded-lg border border-[#DCE2E9] bg-white px-3.5 py-3 text-[12px] leading-5 text-[#344054] outline-none transition-colors placeholder:text-[#9AA4B2] focus:border-[#173B8F] focus:ring-1 focus:ring-[#173B8F] disabled:opacity-60"
              />
              <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
                <span className="text-[10px] text-[#98A2B3]">
                  {changeRequestText.length}/5000 caracteres
                </span>
                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() => {
                      setShowChangeRequest(false);
                      setChangeRequestText("");
                    }}
                    disabled={submittingChangeRequest}
                    className="rounded-full border border-[#DCE2E9] bg-white px-4 py-2 text-[11px] font-semibold text-[#667386] transition-colors hover:bg-[#F3F5F8] disabled:opacity-50"
                  >
                    Cancelar
                  </button>
                  <button
                    type="button"
                    onClick={() => void submitChangeRequest()}
                    disabled={submittingChangeRequest || !changeRequestText.trim()}
                    className="inline-flex items-center gap-2 rounded-full bg-[#173B8F] px-4 py-2 text-[11px] font-semibold text-white transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {submittingChangeRequest && (
                      <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    )}
                    Enviar solicitud
                  </button>
                </div>
              </div>
            </div>
          )}

          <div className="mt-5 divide-y divide-[#EEF1F4] border-y border-[#EEF1F4]">
            {visibleVersions.length > 0 ? (
              visibleVersions.map((version) => {
                const isCurrent = version.id === currentVisibleVersion?.id;
                return (
                  <div
                    key={version.id}
                    className="flex flex-col gap-3 py-4 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="text-[12px] font-semibold text-[#26344A]">
                          {version.version_label}
                        </span>
                        {isCurrent && (
                          <span className="rounded-full border border-[#CDE8D8] bg-[#ECF8F1] px-2 py-1 text-[9px] font-semibold text-[#247A49]">
                            Última versión publicada
                          </span>
                        )}
                        {version.client_response && (
                          <span className="rounded-full border border-[#E0E5EA] bg-[#F4F6F8] px-2 py-1 text-[9px] font-semibold text-[#667386]">
                            {version.client_response}
                          </span>
                        )}
                      </div>
                      <p className="mt-1 text-[10px] text-[#8792A2]">
                        Publicada el {formatDate(version.published_at)}
                      </p>
                    </div>
                   <div className="flex shrink-0 flex-wrap items-center gap-2">
  {signedDocuments
    .filter((document) => document.official_version_id === version.id)
    .map((document) => (
      <div key={document.id} className="flex items-center gap-2">
        <button
          type="button"
          onClick={() => void onViewSignedDocument(document)}
          title="Consultar PDF firmado"
          aria-label="Consultar PDF firmado"
          className="inline-flex h-9 items-center gap-2 rounded-full border border-[#CDE8D8] bg-[#ECF8F1] px-3 text-[10px] font-semibold text-[#247A49] transition-colors hover:bg-[#DDF3E6]"
        >
          <FileText className="h-4 w-4" strokeWidth={1.7} />
          PDF firmado
        </button>

        <button
          type="button"
          onClick={() => void onDownloadSignedDocument(document)}
          title="Descargar PDF firmado"
          aria-label="Descargar PDF firmado"
          className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-[#CDE8D8] bg-white text-[#247A49] transition-colors hover:bg-[#ECF8F1]"
        >
          <Download className="h-4 w-4" strokeWidth={1.7} />
        </button>
      </div>
    ))}

  <button
    type="button"
    onClick={() => void onViewVersionPdf(version)}
    title={`Consultar PDF original ${version.version_label}`}
    aria-label={`Consultar PDF original ${version.version_label}`}
    className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-[#DCE2E9] bg-white text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#F3F6FC] hover:text-[#173B8F]"
  >
    <FileText className="h-4 w-4" strokeWidth={1.7} />
  </button>

  <button
    type="button"
    onClick={() => void onDownloadVersionPdf(version)}
    title={`Descargar PDF original ${version.version_label}`}
    aria-label={`Descargar PDF original ${version.version_label}`}
    className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-[#DCE2E9] bg-white text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#F3F6FC] hover:text-[#173B8F]"
  >
    <Download className="h-4 w-4" strokeWidth={1.7} />
  </button>
</div>
                  </div>
                );
              })
            ) : (
              <p className="py-5 text-[11px] text-[#8792A2]">
                Todavía no hay versiones oficiales disponibles.
              </p>
            )}
          </div>

          {changeRequests.length > 0 && (
            <div className="mt-6">
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#7C8797]">
                Solicitudes de cambios
              </p>
              <div className="mt-3 space-y-3">
                {changeRequests.map((request) => (
                  <div
                    key={request.id}
                    className="border border-[#E7EBF0] px-4 py-3"
                  >
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="text-[10px] font-semibold text-[#445166]">
                        {formatDate(request.requested_at)}
                      </span>
                      <span className="rounded-full border border-[#E0E5EA] bg-[#F4F6F8] px-2 py-1 text-[9px] font-semibold text-[#667386]">
                        {request.request_status === "open"
                          ? "En revisión"
                          : request.request_status === "resolved"
                            ? "Resuelta"
                            : "Cancelada"}
                      </span>
                    </div>
                    <p className="mt-2 whitespace-pre-line text-[11px] leading-5 text-[#718096]">
                      {request.request_text}
                    </p>
                  </div>
                ))}
              </div>
            </div>
          )}
        </section>
      )}

      {displayStatus === "Pendiente" && canRespondToWorkflow && !isProjectOwner && (
        <div className="border border-[#F0DEB7] bg-[#FFF7E8] px-5 py-4">
          <p className="text-[11px] leading-5 text-[#8B640F]">
            Solo el responsable del proyecto puede aceptar este presupuesto.
          </p>
        </div>
      )}

      {displayStatus === "Pendiente" && canRespondToWorkflow && (
  <QuotationAcceptanceCard
    pdfOpened={pdfOpened}
    acknowledged={acknowledged}
    responding={responding}
    hasPdf={Boolean(quotation.document_path)}
    isProjectOwner={isProjectOwner}
    onOpenPdf={onViewPdf}
    onAcknowledgedChange={onAcknowledgedChange}
    onAccept={onSignAndAccept}
    onReject={() => onRespond("Rechazado")}
  />
)}

      {displayStatus === "Aceptado" && (
        <section className="border border-[#CDE8D8] bg-[#ECF8F1] p-5 sm:p-7">
          <div className="flex items-start gap-3">
            <Check
              className="mt-0.5 h-5 w-5 shrink-0 text-[#247A49]"
              strokeWidth={1.8}
            />

            <div>
              <p className="text-[13px] font-semibold text-[#247A49]">
                Presupuesto aceptado
              </p>
              <p className="mt-1 text-[11px] leading-5 text-[#4F6F5C]">
                La aceptación se ha registrado mediante el flujo contractual
                del presupuesto.
              </p>

              {acceptance && (
                <p className="mt-2 text-[10px] font-medium text-[#5F7E6B]">
                  Aceptado el {formatDate(acceptance.accepted_at)} · Versión{" "}
                  {acceptance.quotation_version}
                </p>
              )}
            </div>
          </div>
        </section>
      )}

      {displayStatus === "Rechazado" && (
        <section className="border border-[#E3E8EE] bg-white p-5 sm:p-7">
          <div className="flex items-start gap-3">
            <AlertCircle
              className="mt-0.5 h-5 w-5 shrink-0 text-[#7B8594]"
              strokeWidth={1.7}
            />

            <div>
              <p className="text-[13px] font-semibold text-[#536176]">
                Presupuesto rechazado
              </p>
              <p className="mt-1 text-[11px] leading-5 text-[#7A8493]">
                Este presupuesto ya ha recibido una respuesta.
              </p>
            </div>
          </div>
        </section>
      )}
    </div>
  );
}
function QuotationAcceptanceCard({
  pdfOpened,
  acknowledged,
  responding,
  hasPdf,
  isProjectOwner,
  onOpenPdf,
  onAcknowledgedChange,
  onAccept,
  onReject,
}: {
  pdfOpened: boolean;
  acknowledged: boolean;
  responding: boolean;
  hasPdf: boolean;
  isProjectOwner: boolean;
  onOpenPdf: () => Promise<void>;
  onAcknowledgedChange: (value: boolean) => void;
  onAccept: (signaturePngBase64: string) => void;
  onReject: () => void;
}) {
  const [showSignaturePanel, setShowSignaturePanel] = useState(false);
  const [hasSignature, setHasSignature] = useState(false);

  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const drawingRef = useRef(false);

  const acceptanceReady =
    isProjectOwner &&
    hasPdf &&
    pdfOpened &&
    acknowledged &&
    !responding;

  const getCanvasPoint = (
    event: React.PointerEvent<HTMLCanvasElement>,
  ) => {
    const canvas = canvasRef.current;

    if (!canvas) {
      return { x: 0, y: 0 };
    }

    const rect = canvas.getBoundingClientRect();

    return {
      x: ((event.clientX - rect.left) / rect.width) * canvas.width,
      y: ((event.clientY - rect.top) / rect.height) * canvas.height,
    };
  };

  const startDrawing = (
    event: React.PointerEvent<HTMLCanvasElement>,
  ) => {
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");

    if (!canvas || !context || responding) return;

    event.preventDefault();

    canvas.setPointerCapture(event.pointerId);

    const point = getCanvasPoint(event);

    context.beginPath();
    context.moveTo(point.x, point.y);
    context.lineWidth = 3;
    context.lineCap = "round";
    context.lineJoin = "round";
    context.strokeStyle = "#182A45";

    drawingRef.current = true;
    setHasSignature(true);
  };

  const draw = (
    event: React.PointerEvent<HTMLCanvasElement>,
  ) => {
    if (!drawingRef.current) return;

    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");

    if (!canvas || !context) return;

    event.preventDefault();

    const point = getCanvasPoint(event);

    context.lineTo(point.x, point.y);
    context.stroke();
  };

  const stopDrawing = () => {
    drawingRef.current = false;
  };

  const clearSignature = () => {
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");

    if (canvas && context) {
      context.clearRect(0, 0, canvas.width, canvas.height);
    }

    setHasSignature(false);
  };

  const cancelSignature = () => {
    setShowSignaturePanel(false);
    clearSignature();
  };

  const submitSignature = () => {
    const canvas = canvasRef.current;

    if (!canvas || !hasSignature) {
      toast.error("Dibuja tu firma antes de continuar.");
      return;
    }

    const dataUrl = canvas.toDataURL("image/png");
    const signaturePngBase64 = dataUrl.split(",")[1];

    if (!signaturePngBase64) {
      toast.error("No se ha podido leer la firma.");
      return;
    }

    onAccept(signaturePngBase64);
  };

  return (
    <section className="border border-[#DCE4F0] bg-white p-5 sm:p-7">
      <div className="flex items-start gap-3">
        <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#F3F6FC] text-[#173B8F]">
          <ShieldCheck
            className="h-4 w-4"
            strokeWidth={1.7}
          />
        </div>

        <div>
          <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
            Aceptación contractual
          </p>

          <h2 className="mt-1 text-[17px] font-semibold tracking-tight text-[#182A45]">
            Aceptar presupuesto
          </h2>

          <p className="mt-1.5 max-w-2xl text-[12px] leading-5 text-[#718096]">
            Consulta el PDF, confirma que lo has leído y firma el
            presupuesto para registrar tu aceptación.
          </p>
        </div>
      </div>

      <div className="mt-5 border border-[#E4E9EF] bg-[#F8FAFC] p-4">
        <div className="flex items-start gap-3">
          <Info
            className="mt-0.5 h-4 w-4 shrink-0 text-[#173B8F]"
            strokeWidth={1.7}
          />

          <p className="text-[11px] leading-5 text-[#667386]">
            La aceptación quedará vinculada a la versión oficial del
            presupuesto. La firma se incorporará a un PDF firmado
            independiente, conservando el documento original.
          </p>
        </div>
      </div>

      <div className="mt-5">
        <button
          type="button"
          onClick={onOpenPdf}
          disabled={!hasPdf || responding}
          className={[
            "inline-flex items-center gap-2 rounded-full border px-4 py-2.5 text-[11px] font-semibold transition-colors",
            hasPdf
              ? "border-[#DCE2E9] bg-white text-[#173B8F] hover:border-[#173B8F] hover:bg-[#F3F6FC]"
              : "cursor-not-allowed border-[#E4E9EF] bg-[#F8FAFC] text-[#98A2B3]",
          ].join(" ")}
        >
          <FileText
            className="h-3.5 w-3.5"
            strokeWidth={1.7}
          />

          {!hasPdf
            ? "PDF no disponible"
            : pdfOpened
              ? "Volver a consultar PDF"
              : "Consultar PDF antes de aceptar"}
        </button>
      </div>

      <div className="mt-5 border-t border-[#EEF1F4] pt-5">
        <label
          className={[
            "flex items-start gap-3",
            pdfOpened && !responding
              ? "cursor-pointer"
              : "cursor-not-allowed",
          ].join(" ")}
        >
          <input
            type="checkbox"
            checked={acknowledged}
            disabled={!pdfOpened || responding}
            onChange={(event) => {
              const checked = event.target.checked;

              onAcknowledgedChange(checked);

              if (!checked) {
                setShowSignaturePanel(false);
                clearSignature();
              }
            }}
            className="mt-0.5 h-4 w-4 shrink-0 rounded border-[#C9D1DB] text-[#173B8F] accent-[#173B8F] disabled:cursor-not-allowed disabled:opacity-50"
          />

          <span
            className={[
              "text-[11px] leading-5",
              pdfOpened
                ? "text-[#536176]"
                : "text-[#A0A9B5]",
            ].join(" ")}
          >
            He leído y revisado el documento PDF correspondiente a
            este presupuesto y declaro haber tenido acceso a su
            contenido, incluidos el alcance de los trabajos, los
            importes y las condiciones.
          </span>
        </label>

        {!pdfOpened && hasPdf && (
          <p className="mt-2 ml-7 text-[10px] text-[#98A2B3]">
            Consulta primero el PDF para poder marcar esta casilla.
          </p>
        )}

        {pdfOpened && !acknowledged && isProjectOwner && (
          <p className="mt-2 ml-7 text-[10px] text-[#A56A00]">
            Marca la casilla para habilitar la aceptación del presupuesto.
          </p>
        )}
      </div>

      {!showSignaturePanel && (
        <div className="mt-6 flex flex-wrap justify-end gap-2">
          <button
            type="button"
            disabled={responding}
            onClick={onReject}
            className="rounded-full border border-[#DCE2E9] bg-white px-5 py-2.5 text-[11px] font-semibold text-[#667386] transition-colors hover:border-[#C6CFDA] hover:bg-[#F7F9FB] disabled:cursor-not-allowed disabled:opacity-50"
          >
            Rechazar
          </button>

          <button
            type="button"
            disabled={!acceptanceReady}
            onClick={() => setShowSignaturePanel(true)}
            className={[
              "inline-flex items-center gap-2 rounded-full px-5 py-2.5 text-[11px] font-semibold text-white transition-opacity",
              acceptanceReady
                ? "bg-[#173B8F] hover:opacity-90"
                : "cursor-not-allowed bg-[#AEB8C7] opacity-70",
            ].join(" ")}
          >
            Aceptar presupuesto
            <ArrowRight className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {showSignaturePanel && (
        <div className="mt-6 border border-[#DCE4F0] bg-[#F8FAFC] p-4 sm:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.15em] text-[#7C8797]">
                Firma del cliente
              </p>

              <h3 className="mt-1 text-[16px] font-semibold text-[#182A45]">
                Firma dentro del recuadro
              </h3>

              <p className="mt-1 text-[11px] leading-5 text-[#718096]">
                Dibuja tu firma con el ratón, el dedo o un lápiz táctil.
                Si no te convence, puedes borrarla y repetirla.
              </p>
            </div>

            <button
              type="button"
              onClick={clearSignature}
              disabled={responding || !hasSignature}
              className="w-fit rounded-full border border-[#DCE2E9] bg-white px-4 py-2 text-[10px] font-semibold text-[#667386] transition-colors hover:border-[#173B8F] hover:text-[#173B8F] disabled:cursor-not-allowed disabled:opacity-50"
            >
              Borrar firma
            </button>
          </div>

          <div className="mt-4 overflow-hidden border border-[#DCE2E9] bg-white">
            <canvas
              ref={canvasRef}
              width={1000}
              height={260}
              aria-label="Área para dibujar la firma"
              onPointerDown={startDrawing}
              onPointerMove={draw}
              onPointerUp={stopDrawing}
              onPointerCancel={stopDrawing}
              onPointerLeave={stopDrawing}
              className="block h-[170px] w-full touch-none sm:h-[210px]"
              style={{ touchAction: "none" }}
            />
          </div>

          <p className="mt-2 text-[10px] text-[#98A2B3]">
            La firma se incorporará al documento PDF de aceptación.
          </p>

          <div className="mt-5 flex flex-wrap justify-end gap-2">
            <button
              type="button"
              onClick={cancelSignature}
              disabled={responding}
              className="rounded-full border border-[#DCE2E9] bg-white px-5 py-2.5 text-[11px] font-semibold text-[#667386] transition-colors hover:bg-[#F3F5F8] disabled:cursor-not-allowed disabled:opacity-50"
            >
              Cancelar
            </button>

            <button
              type="button"
              onClick={submitSignature}
              disabled={responding || !hasSignature}
              className="inline-flex items-center gap-2 rounded-full bg-[#173B8F] px-5 py-2.5 text-[11px] font-semibold text-white transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {responding && (
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
              )}

              Firmar y aceptar
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
function EconomicRow({
  label,
  value,
}: {
  label: string;
  value: string;
}) {
  return (
    <div className="flex items-center justify-between gap-4 text-[11px]">
      <span className="text-[#7A8493]">{label}</span>
      <span className="font-medium text-[#445166]">{value}</span>
    </div>
  );
}

function DetailInfo({
  label,
  value,
  valueClass,
}: {
  label: string;
  value: string;
  valueClass?: string;
}) {
  return (
    <div>
      <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-[#98A2B3]">
        {label}
      </p>
      <p
        className={[
          "mt-1 text-[11px] font-medium text-[#445166]",
          valueClass || "",
        ].join(" ")}
      >
        {value}
      </p>
    </div>
  );
}
