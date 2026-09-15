import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  AlertCircle,
  AlertTriangle,
  ArrowRight,
  Bell,
  BriefcaseBusiness,
  Building2,
  CalendarDays,
  Check,
  ChevronLeft,
  ChevronRight,
  ClipboardList,
  Edit2,
  ExternalLink,
  FileText,
  Loader2,
  Receipt,
  Send,
} from "lucide-react";
import { supabase } from "@/lib/supabase";
import { toast } from "sonner";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import ClientAreaHeader from "@/components/ClientAreaHeader";

interface UserProfile {
  id: string;
  company_id: string | null;
  nombre: string;
  empresa: string | null;
  telefono: string | null;
  fecha_registro: string;
}

interface CompanyInfo {
  id: string;
  company_name: string;
  subscription_plan: string | null;
  subscription_status: string | null;
}

interface Project {
  id: string;
  user_id: string;
  company_id: string | null;
  nombre: string;
  descripcion: string | null;
  estado: string;
  fecha_inicio: string | null;
  fecha_fin: string | null;
  created_at: string | null;
  updated_at: string | null;
}

type MilestoneStatus = "pendiente" | "en_curso" | "completado";

interface ProjectMilestone {
  id: string;
  project_id: string;
  nombre: string;
  descripcion: string | null;
  fecha_prevista: string;
  orden: number;
  estado: MilestoneStatus;
  completed_at: string | null;
  created_by: string | null;
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

interface ClientNotification {
  id: string;
  user_id: string;
  project_id: string | null;
  tipo: string;
  titulo: string;
  mensaje: string;
  metadata: Record<string, unknown> | null;
  read_at: string | null;
  created_at: string;
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

interface Invoice {
  id: string;
  project_id: string | null;
  company_id: string | null;
  user_id: string | null;
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
  created_at: string;
}

interface Quotation {
  id: string;
  company_id: string | null;
  project_id?: string | null;
  numero_presupuesto?: string | null;
  titulo?: string | null;
  estado: string;
  [key: string]: unknown;
}

interface MaintenanceContract {
  id: string;
  user_id: string;
  company_id: string | null;
  nombre_plan: string;
  descripcion: string | null;
  precio: number;
  periodicidad: string;
  estado: string;
  fecha_inicio: string;
  fecha_fin: string | null;
  created_at: string;
  updated_at: string;
}

interface PendingAction {
  id: string;
  type: "quotation" | "invoice" | "company";
  title: string;
  description: string;
  label: string;
  href?: string;
  invoiceId?: string;
  quotationId?: string;
}

const euro = new Intl.NumberFormat("es-ES", {
  style: "currency",
  currency: "EUR",
  minimumFractionDigits: 2,
});

const longDate = new Intl.DateTimeFormat("es-ES", {
  day: "numeric",
  month: "long",
  year: "numeric",
});

const compactDate = new Intl.DateTimeFormat("es-ES", {
  day: "numeric",
  month: "short",
  year: "numeric",
});

const formatCurrency = (value: number | null | undefined) =>
  euro.format(Number(value ?? 0));

const formatDate = (value?: string | null) =>
  value ? longDate.format(new Date(value)) : "Sin fecha";

const formatCompactDate = (value?: string | null) =>
  value ? compactDate.format(new Date(value)) : "Sin fecha";

const normalizeStatus = (value?: string | null) => {
  const status = (value || "").trim().toLowerCase();
  if (status === "activo" || status.includes("curso")) return "Activo";
  if (status === "pausado") return "Pausado";
  if (status === "entregado") return "Entregado";
  if (status === "completado") return "Completado";
  if (status === "cancelado") return "Cancelado";
  return value || "Pendiente";
};

const ProgressRing = ({
  percentage,
  tone = "active",
}: {
  percentage: number;
  tone?: "active" | "paused";
}) => {
  const value = Math.max(0, Math.min(100, Math.round(percentage)));
  const radius = 46;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference - (value / 100) * circumference;

  return (
    <div className="relative h-28 w-28 shrink-0 sm:h-32 sm:w-32">
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
          className={[
            tone === "paused" ? "text-amber-400" : "text-emerald-500",
            "transition-all duration-700 ease-out",
          ].join(" ")}
          strokeDasharray={circumference}
          strokeDashoffset={offset}
        />
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center">
        <span className="text-2xl font-semibold tracking-tight text-[#102A66] sm:text-3xl">
          {value}%
        </span>
        <span className="mt-0.5 text-[9px] font-medium uppercase tracking-[0.16em] text-[#8A96A8]">
          progreso
        </span>
      </div>
    </div>
  );
};

const MilestoneTimeline = ({
  milestones,
  projectStatus,
}: {
  milestones: ProjectMilestone[];
  projectStatus: string;
}) => {
  if (!milestones.length) {
    return (
      <p className="text-xs leading-5 text-[#8792A3]">
        Todavía no se han definido hitos para este proyecto.
      </p>
    );
  }

  return (
    <div className="overflow-x-auto pb-1">
      <div className="flex min-w-max items-start pt-1">
        {milestones.map((milestone, index) => {
          const completed = milestone.estado === "completado";
          const current = milestone.estado === "en_curso";
          const projectCompleted = projectStatus === "Completado";
          const projectPaused = projectStatus === "Pausado";
          const progressColor = projectCompleted
            ? "bg-emerald-500"
            : projectPaused
              ? "bg-amber-400"
              : "bg-emerald-500";
          const nodeColor = projectCompleted
            ? "border-emerald-500 bg-emerald-500 text-white"
            : projectPaused && completed
              ? "border-amber-400 bg-amber-400 text-white"
              : completed
                ? "border-emerald-500 bg-emerald-500 text-white"
                : current
                  ? projectPaused
                    ? "border-amber-400 text-amber-600 ring-4 ring-amber-400/10"
                    : "border-[#173B8F] text-[#173B8F] ring-4 ring-[#173B8F]/5"
                  : "border-[#CBD3DE] text-[#A1AAB8]";

          return (
            <div key={milestone.id} className="flex items-start">
              <div className="flex w-28 flex-col items-center text-center sm:w-32">
                <div
                  className={[
                    "relative z-10 flex h-7 w-7 items-center justify-center rounded-full border bg-white transition-all duration-500",
                    nodeColor,
                  ].join(" ")}
                >
                  {projectCompleted ? (
                    <Check className="h-3.5 w-3.5" strokeWidth={2.5} />
                  ) : completed ? (
                    <Check className="h-3.5 w-3.5" strokeWidth={2.5} />
                  ) : current ? (
                    <span className={[
                      "h-2 w-2 rounded-full",
                      projectPaused ? "bg-amber-500" : "bg-[#173B8F]",
                    ].join(" ")} />
                  ) : (
                    <span className="h-1.5 w-1.5 rounded-full bg-[#CBD3DE]" />
                  )}
                </div>
                <p
                  className={[
                    "mt-2 line-clamp-2 text-[11px] font-medium leading-4",
                    completed || current ? "text-[#26344A]" : "text-[#707C8D]",
                  ].join(" ")}
                >
                  {milestone.nombre}
                </p>
                <p className="mt-0.5 text-[10px] text-[#9AA4B2]">
                  {formatCompactDate(milestone.fecha_prevista)}
                </p>
              </div>
              {index < milestones.length - 1 && (
                <div
                  className={[
                    "mt-3.5 h-px w-7 shrink-0 sm:w-10",
                    (projectCompleted || completed) ? progressColor : "bg-[#DDE2E9]",
                  ].join(" ")}
                />
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
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

export default function ClientArea() {
  const { user, signOut, loading: authLoading } = useAuth();
  const [, setLocation] = useLocation();

  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [company, setCompany] = useState<CompanyInfo | null>(null);
  const [projects, setProjects] = useState<Project[]>([]);
  const [milestones, setMilestones] = useState<ProjectMilestone[]>([]);
  const [progressByProject, setProgressByProject] = useState<Record<string, ProjectProgress>>({});
  const [updates, setUpdates] = useState<ProjectUpdate[]>([]);
  const [notifications, setNotifications] = useState<ClientNotification[]>([]);
  const [documents, setDocuments] = useState<ProjectDocument[]>([]);
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [quotations, setQuotations] = useState<Quotation[]>([]);
  const [maintenanceContracts, setMaintenanceContracts] = useState<MaintenanceContract[]>([]);

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sectionWarnings, setSectionWarnings] = useState<string[]>([]);

  const [isEditDialogOpen, setIsEditDialogOpen] = useState(false);
  const [isCompanyRequestDialogOpen, setIsCompanyRequestDialogOpen] = useState(false);
  const [isNotificationsOpen, setIsNotificationsOpen] = useState(false);
  const [isCalendarOpen, setIsCalendarOpen] = useState(false);

  const [calendarMonth, setCalendarMonth] = useState(() => {
    const now = new Date();
    return new Date(now.getFullYear(), now.getMonth(), 1);
  });
  const [selectedCalendarDate, setSelectedCalendarDate] = useState<string | null>(null);

  const [requestedCompanyName, setRequestedCompanyName] = useState("");
  const [requestingCompanyChange, setRequestingCompanyChange] = useState(false);
  const [hasPendingCompanyRequest, setHasPendingCompanyRequest] = useState(false);

  const [editForm, setEditForm] = useState({ nombre: "", telefono: "" });

  const fetchDashboard = useCallback(async () => {
    if (!user) {
      setLoading(false);
      return;
    }

    try {
      setLoading(true);
      setError(null);
      setSectionWarnings([]);

      // ------------------------------------------------------------
      // PERFIL — único bloque imprescindible para entrar al dashboard.
      // ------------------------------------------------------------
      const { data: profileData, error: profileError } = await supabase
        .from("profiles")
        .select("id, company_id, nombre, empresa, telefono, fecha_registro")
        .eq("id", user.id)
        .maybeSingle();

      if (profileError) throw profileError;

      let resolvedProfile = profileData as UserProfile | null;

      if (!resolvedProfile) {
        const fallbackName =
          user.user_metadata?.nombre ||
          user.user_metadata?.name ||
          user.email?.split("@")[0] ||
          "Usuario";

        const { data: createdProfile, error: createProfileError } = await supabase
          .from("profiles")
          .insert({
            id: user.id,
            nombre: fallbackName,
            rol: "user",
            fecha_registro: new Date().toISOString(),
            fecha_ultimo_login: new Date().toISOString(),
          })
          .select("id, company_id, nombre, empresa, telefono, fecha_registro")
          .single();

        if (createProfileError) throw createProfileError;
        resolvedProfile = createdProfile as UserProfile;
      }

      setProfile(resolvedProfile);
      setEditForm({
        nombre: resolvedProfile.nombre || "",
        telefono: resolvedProfile.telefono || "",
      });

      let resolvedCompany: CompanyInfo | null = null;

      if (resolvedProfile.company_id) {
        const { data: companyData, error: companyError } = await supabase
          .from("companies")
          .select("id, company_name, subscription_plan, subscription_status")
          .eq("id", resolvedProfile.company_id)
          .maybeSingle();

        if (companyError) {
          console.warn("[ClientArea] Error cargando empresa:", companyError);
          setSectionWarnings((current) => [...current, "empresa"]);
        } else if (companyData) {
          resolvedCompany = companyData as CompanyInfo;
          setCompany(resolvedCompany);
        }
      } else {
        setCompany(null);
      }

      // ------------------------------------------------------------
      // BLOQUES INDEPENDIENTES — un fallo secundario no derriba todo.
      // ------------------------------------------------------------
      const [
        projectsResult,
        notificationsResult,
        invoicesResult,
        quotationsResult,
        pendingCompanyResult,
        maintenanceResult,
      ] = await Promise.all([
        supabase
          .from("projects")
          .select(
            "id, user_id, company_id, nombre, descripcion, estado, fecha_inicio, fecha_fin, created_at, updated_at"
          )
          .eq("user_id", user.id)
          .order("created_at", { ascending: false }),
        supabase
          .from("notifications")
          .select(
            "id, user_id, project_id, tipo, titulo, mensaje, metadata, read_at, created_at"
          )
          .eq("user_id", user.id)
          .order("created_at", { ascending: false })
          .limit(30),
        resolvedCompany?.id
          ? supabase
              .from("invoices")
              .select(
                "id, project_id, company_id, user_id, numero_factura, fecha_emision, fecha_vencimiento, descripcion, subtotal, iva_aplicado, iva_porcentaje, iva_importe, irpf_aplicado, irpf_porcentaje, irpf_importe, monto, importe_a_pagar, estado, created_at"
              )
              .eq("company_id", resolvedCompany.id)
              .order("created_at", { ascending: false })
          : supabase
              .from("invoices")
              .select(
                "id, project_id, company_id, user_id, numero_factura, fecha_emision, fecha_vencimiento, descripcion, subtotal, iva_aplicado, iva_porcentaje, iva_importe, irpf_aplicado, irpf_porcentaje, irpf_importe, monto, importe_a_pagar, estado, created_at"
              )
              .eq("user_id", user.id)
              .order("created_at", { ascending: false }),
        resolvedCompany?.id
          ? supabase
              .from("quotations")
              .select("*")
              .eq("company_id", resolvedCompany.id)
              .order("created_at", { ascending: false })
          : Promise.resolve({ data: [] as Quotation[], error: null }),
        supabase
          .from("company_change_requests")
          .select("id")
          .eq("user_id", user.id)
          .eq("status", "pending")
          .limit(1),
        supabase
          .from("maintenance_contracts")
          .select("id, user_id, company_id, nombre_plan, descripcion, precio, periodicidad, estado, fecha_inicio, fecha_fin, created_at, updated_at")
          .order("created_at", { ascending: false }),
      ]);

      const warnings: string[] = [];

      if (projectsResult.error) {
        console.error("[ClientArea] Error cargando proyectos:", projectsResult.error);
        warnings.push("proyectos");
      } else {
        setProjects((projectsResult.data || []) as Project[]);
      }

      if (notificationsResult.error) {
        console.error("[ClientArea] Error cargando notificaciones:", notificationsResult.error);
        warnings.push("notificaciones");
      } else {
        setNotifications((notificationsResult.data || []) as ClientNotification[]);
      }

      if (invoicesResult.error) {
        console.error("[ClientArea] Error cargando facturas:", invoicesResult.error);
        warnings.push("facturación");
      } else {
        setInvoices((invoicesResult.data || []) as Invoice[]);
      }

      if (quotationsResult.error) {
        console.error("[ClientArea] Error cargando presupuestos:", quotationsResult.error);
        warnings.push("presupuestos");
      } else {
        setQuotations((quotationsResult.data || []) as Quotation[]);
      }

      if (!pendingCompanyResult.error) {
        setHasPendingCompanyRequest(
          Array.isArray(pendingCompanyResult.data) && pendingCompanyResult.data.length > 0
        );
      }

      if (maintenanceResult.error) {
        console.error("[ClientArea] Error cargando mantenimiento:", maintenanceResult.error);
        warnings.push("mantenimiento");
        setMaintenanceContracts([]);
      } else {
        setMaintenanceContracts((maintenanceResult.data || []) as MaintenanceContract[]);
      }

      const resolvedProjects = projectsResult.error
        ? []
        : ((projectsResult.data || []) as Project[]);
      const projectIds = resolvedProjects.map((project) => project.id);

      // ------------------------------------------------------------
      // HITOS / PROGRESO / NOVEDADES / DOCUMENTOS
      // ------------------------------------------------------------
      if (!projectIds.length) {
        setMilestones([]);
        setProgressByProject({});
        setUpdates([]);
        setDocuments([]);
      } else {
        const [milestonesResult, progressResult, updatesResult, documentsResult] =
          await Promise.all([
            supabase
              .from("project_milestones")
              .select(
                "id, project_id, nombre, descripcion, fecha_prevista, orden, estado, completed_at, created_by, created_at, updated_at"
              )
              .in("project_id", projectIds)
              .order("orden", { ascending: true })
              .order("fecha_prevista", { ascending: true }),
            supabase
              .from("project_progress")
              .select("project_id, total_milestones, completed_milestones, progress_percentage")
              .in("project_id", projectIds),
            supabase
              .from("project_updates")
              .select("id, project_id, titulo, contenido, created_by, created_at, updated_at")
              .in("project_id", projectIds)
              .order("created_at", { ascending: false })
              .limit(8),
            supabase
              .from("project_documents")
              .select(
                "id, project_id, file_name, storage_path, mime_type, file_size, uploaded_by, created_at, updated_at"
              )
              .in("project_id", projectIds)
              .order("created_at", { ascending: false })
              .limit(8),
          ]);

        if (milestonesResult.error) {
          console.error("[ClientArea] Error cargando hitos:", milestonesResult.error);
          warnings.push("hitos");
          setMilestones([]);
          setProgressByProject({});
        } else {
          const resolvedMilestones = (milestonesResult.data || []) as ProjectMilestone[];
          setMilestones(resolvedMilestones);

          const progressMap: Record<string, ProjectProgress> = {};
          if (!progressResult.error) {
            for (const row of (progressResult.data || []) as ProjectProgress[]) {
              progressMap[row.project_id] = row;
            }
          } else {
            console.warn("[ClientArea] project_progress no disponible:", progressResult.error);
            warnings.push("progreso");
          }

          // Fallback exactamente sobre la fuente de verdad: project_milestones.
          for (const projectId of projectIds) {
            if (!progressMap[projectId]) {
              const list = resolvedMilestones.filter((item) => item.project_id === projectId);
              const total = list.length;
              const completed = list.filter((item) => item.estado === "completado").length;
              progressMap[projectId] = {
                project_id: projectId,
                total_milestones: total,
                completed_milestones: completed,
                progress_percentage: total ? Math.round((completed / total) * 100) : 0,
              };
            }
          }
          setProgressByProject(progressMap);
        }

        if (updatesResult.error) {
          console.error("[ClientArea] Error cargando novedades:", updatesResult.error);
          warnings.push("novedades");
          setUpdates([]);
        } else {
          setUpdates((updatesResult.data || []) as ProjectUpdate[]);
        }

        if (documentsResult.error) {
          console.error("[ClientArea] Error cargando documentos:", documentsResult.error);
          warnings.push("documentos");
          setDocuments([]);
        } else {
          setDocuments((documentsResult.data || []) as ProjectDocument[]);
        }
      }

      setSectionWarnings(warnings);
      if (warnings.length) {
        setError(null);
      }
    } catch (err: any) {
      console.error("[ClientArea] Error crítico cargando dashboard:", err);
      setError("No se ha podido cargar la información principal de tu área de cliente.");
    } finally {
      setLoading(false);
    }
  }, [user]);

  useEffect(() => {
    if (!authLoading) fetchDashboard();
  }, [authLoading, fetchDashboard]);

  const projectById = useMemo(
    () => new Map(projects.map((project) => [project.id, project])),
    [projects]
  );

  // El dashboard muestra los estados que el cliente necesita conocer.
  // "Entregado" queda fuera deliberadamente: se comporta como si no hubiera
  // proyecto en el centro de control, aunque siga existiendo en la BD.
  const dashboardProjects = useMemo(
    () =>
      projects.filter((project) =>
        ["Pendiente", "Activo", "Pausado", "Completado"].includes(
          normalizeStatus(project.estado)
        )
      ),
    [projects]
  );

  const dashboardProjectIds = useMemo(
    () => new Set(dashboardProjects.map((project) => project.id)),
    [dashboardProjects]
  );

  const milestonesByProject = useMemo(() => {
    const map = new Map<string, ProjectMilestone[]>();
    for (const milestone of milestones) {
      const current = map.get(milestone.project_id) || [];
      current.push(milestone);
      map.set(milestone.project_id, current);
    }
    for (const [projectId, list] of map.entries()) {
      list.sort((a, b) => a.orden - b.orden);
      map.set(projectId, list);
    }
    return map;
  }, [milestones]);

  const nextMilestoneByProject = useMemo(() => {
    const map = new Map<string, ProjectMilestone | null>();
    for (const project of projects) {
      const list = milestonesByProject.get(project.id) || [];
      map.set(
        project.id,
        list.find((item) => item.estado === "en_curso") ||
          list.find((item) => item.estado === "pendiente") ||
          null
      );
    }
    return map;
  }, [projects, milestonesByProject]);

  const phaseByProject = useMemo(() => {
    const map = new Map<string, string>();
    for (const project of projects) {
      const list = milestonesByProject.get(project.id) || [];
      const current =
        list.find((item) => item.estado === "en_curso") ||
        list.find((item) => item.estado === "pendiente") ||
        [...list].reverse().find((item) => item.estado === "completado");
      map.set(project.id, current?.nombre || normalizeStatus(project.estado));
    }
    return map;
  }, [projects, milestonesByProject]);

  const unreadNotifications = useMemo(
    () => notifications.filter((item) => !item.read_at),
    [notifications]
  );

  const pendingInvoices = useMemo(
    () =>
      invoices.filter((invoice) =>
        ["pendiente", "vencida"].includes((invoice.estado || "").trim().toLowerCase())
      ),
    [invoices]
  );

  const pendingQuotations = useMemo(
    () =>
      quotations.filter(
        (quotation) => (quotation.estado || "").trim().toLowerCase() === "pendiente"
      ),
    [quotations]
  );

  const outstandingAmount = useMemo(
    () =>
      pendingInvoices.reduce(
        (sum, invoice) => sum + Number(invoice.importe_a_pagar ?? invoice.monto ?? 0),
        0
      ),
    [pendingInvoices]
  );

  const pendingActions = useMemo<PendingAction[]>(() => {
    const actions: PendingAction[] = [];

    pendingQuotations.slice(0, 4).forEach((quotation) => {
      actions.push({
        id: `quotation-${quotation.id}`,
        type: "quotation",
        title: quotation.titulo ||
          (quotation.numero_presupuesto
            ? `Presupuesto ${quotation.numero_presupuesto}`
            : "Presupuesto pendiente"),
        description: "Tienes un presupuesto pendiente de respuesta.",
        label: "Revisar",
        href: "/area-cliente/presupuestos",
        quotationId: quotation.id,
      });
    });

    pendingInvoices.slice(0, 4).forEach((invoice) => {
      const overdue = (invoice.estado || "").trim().toLowerCase() === "vencida";
      actions.push({
        id: `invoice-${invoice.id}`,
        type: "invoice",
        title: `Factura ${invoice.numero_factura}`,
        description: overdue
          ? `Vencida · ${formatCurrency(invoice.importe_a_pagar ?? invoice.monto)}`
          : `Pendiente · ${formatCurrency(invoice.importe_a_pagar ?? invoice.monto)}`,
        label: "Ver factura",
        href: "/area-cliente/facturacion",
        invoiceId: invoice.id,
      });
    });

    if (hasPendingCompanyRequest) {
      actions.push({
        id: "company-change",
        type: "company",
        title: "Solicitud de empresa en revisión",
        description: "Modira está revisando tu solicitud de cambio de empresa.",
        label: "Ver cuenta",
        href: "#perfil",
      });
    }

    return actions.slice(0, 6);
  }, [pendingQuotations, pendingInvoices, hasPendingCompanyRequest]);

  // "Contratado" incluye un plan activo o temporalmente pausado.
  // Los contratos cancelados o finalizados ya no cuentan en este resumen.
  const contractedMaintenanceContracts = useMemo(
    () =>
      maintenanceContracts.filter((contract) =>
        ["activo", "pausado"].includes((contract.estado || "").trim().toLowerCase())
      ),
    [maintenanceContracts]
  );

  const maintenancePlanNames = useMemo(
    () =>
      contractedMaintenanceContracts
        .map((contract) => contract.nombre_plan)
        .filter(Boolean),
    [contractedMaintenanceContracts]
  );

  const visibleUpdates = useMemo(
    () => updates.filter((update) => dashboardProjectIds.has(update.project_id)),
    [updates, dashboardProjectIds]
  );

  const visibleDocuments = useMemo(
    () => documents.filter((document) => dashboardProjectIds.has(document.project_id)),
    [documents, dashboardProjectIds]
  );

  const calendarEvents = useMemo(
    () =>
      milestones
        .filter(
          (milestone) =>
            milestone.fecha_prevista && dashboardProjectIds.has(milestone.project_id)
        )
        .map((milestone) => {
          const date = new Date(milestone.fecha_prevista);
          return {
            id: milestone.id,
            date,
            dateKey: `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(
              date.getDate()
            ).padStart(2, "0")}`,
            title: milestone.nombre,
            status: milestone.estado,
            projectName: projectById.get(milestone.project_id)?.nombre || "Proyecto",
            projectId: milestone.project_id,
          };
        })
        .sort((a, b) => a.date.getTime() - b.date.getTime()),
    [milestones, projectById, dashboardProjectIds]
  );

  const calendarGrid = useMemo(() => {
    const year = calendarMonth.getFullYear();
    const month = calendarMonth.getMonth();
    const firstDay = new Date(year, month, 1);
    const daysInMonth = new Date(year, month + 1, 0).getDate();
    const mondayOffset = (firstDay.getDay() + 6) % 7;
    const cells: Array<number | null> = Array.from({ length: mondayOffset }, () => null);
    for (let day = 1; day <= daysInMonth; day += 1) cells.push(day);
    while (cells.length % 7 !== 0) cells.push(null);
    return cells;
  }, [calendarMonth]);

  const calendarMonthLabel = useMemo(
    () =>
      new Intl.DateTimeFormat("es-ES", {
        month: "long",
        year: "numeric",
      }).format(calendarMonth),
    [calendarMonth]
  );

  const selectedDayEvents = useMemo(
    () =>
      selectedCalendarDate
        ? calendarEvents.filter((event) => event.dateKey === selectedCalendarDate)
        : [],
    [calendarEvents, selectedCalendarDate]
  );

  const greeting = useMemo(() => {
    const hour = new Date().getHours();
    if (hour < 12) return "Buenos días";
    if (hour < 19) return "Buenas tardes";
    return "Buenas noches";
  }, []);

  const handleOpenCalendar = () => {
    const future = calendarEvents.find((event) => event.date.getTime() >= Date.now());
    if (future) {
      setCalendarMonth(new Date(future.date.getFullYear(), future.date.getMonth(), 1));
      setSelectedCalendarDate(future.dateKey);
    } else {
      const now = new Date();
      setCalendarMonth(new Date(now.getFullYear(), now.getMonth(), 1));
      setSelectedCalendarDate(null);
    }
    setIsCalendarOpen(true);
  };

  const handleMarkNotificationRead = async (notification: ClientNotification) => {
    if (notification.read_at) return;
    try {
      const { data, error: markError } = await supabase.rpc("mark_notification_read", {
        p_notification_id: notification.id,
      });
      if (markError) throw markError;
      const updated = data as ClientNotification;
      setNotifications((current) =>
        current.map((item) => (item.id === updated.id ? updated : item))
      );
    } catch (err) {
      console.error("[ClientArea] Error marcando notificación:", err);
      toast.error("No se ha podido marcar la notificación como leída.");
    }
  };

  const handleMarkAllNotificationsRead = async () => {
    if (!unreadNotifications.length) return;
    try {
      const { error: markError } = await supabase.rpc("mark_all_notifications_read");
      if (markError) throw markError;
      const now = new Date().toISOString();
      setNotifications((current) =>
        current.map((item) => ({ ...item, read_at: item.read_at || now }))
      );
    } catch (err) {
      console.error("[ClientArea] Error marcando notificaciones:", err);
      toast.error("No se han podido marcar las notificaciones.");
    }
  };

  const handleOpenDocument = async (document: ProjectDocument) => {
    try {
      const { data, error: signedUrlError } = await supabase.storage
        .from("project-documents")
        .createSignedUrl(document.storage_path, 60);
      if (signedUrlError || !data?.signedUrl) {
        throw signedUrlError || new Error("No se ha podido generar el enlace.");
      }
      window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    } catch (err) {
      console.error("[ClientArea] Error abriendo documento:", err);
      toast.error("No se ha podido abrir el documento.");
    }
  };

  const handleUpdateProfile = async () => {
    if (!user || !profile) return;
    const nombre = editForm.nombre.trim();
    const telefono = editForm.telefono.trim();
    if (!nombre) {
      toast.error("El nombre no puede estar vacío.");
      return;
    }
    try {
      const { error: updateError } = await supabase
        .from("profiles")
        .update({ nombre, telefono: telefono || null })
        .eq("id", user.id);
      if (updateError) throw updateError;
      toast.success("Perfil actualizado correctamente.");
      setIsEditDialogOpen(false);
      await fetchDashboard();
    } catch (err: any) {
      console.error("[ClientArea] Error actualizando perfil:", err);
      toast.error(`Error al actualizar el perfil: ${err?.message || "Error desconocido"}`);
    }
  };

  const handleRequestCompanyChange = async () => {
    if (!user) return;
    const companyName = requestedCompanyName.trim();
    if (!companyName || companyName.length < 2) {
      toast.error("Introduce un nombre de empresa válido.");
      return;
    }
    if (hasPendingCompanyRequest) {
      toast.info("Ya tienes una solicitud de cambio de empresa pendiente.");
      return;
    }
    try {
      setRequestingCompanyChange(true);
      const { error: requestError } = await supabase.rpc("request_company_change", {
        p_requested_company_name: companyName,
      });
      if (requestError) throw requestError;
      toast.success("Solicitud enviada correctamente. Modira revisará el cambio.");
      setRequestedCompanyName("");
      setIsCompanyRequestDialogOpen(false);
      setHasPendingCompanyRequest(true);
    } catch (err: any) {
      console.error("[ClientArea] Error solicitando cambio de empresa:", err);
      toast.error(
        `No se pudo enviar la solicitud: ${err?.message || "Error desconocido"}`
      );
    } finally {
      setRequestingCompanyChange(false);
    }
  };

  const handleLogout = async () => {
    const result = await signOut();
    if (result.success) setLocation("/");
  };

  if (authLoading || loading) {
    return (
      <div className="min-h-screen bg-[#FBFCFE]">
        <ClientAreaHeader userName="..." onLogout={handleLogout} />
        <div className="flex min-h-[70vh] items-center justify-center px-6">
          <div className="text-center">
            <Loader2 className="mx-auto mb-4 h-8 w-8 animate-spin text-[#173B8F]" />
            <p className="text-sm text-[#667386]">Preparando tu área de cliente...</p>
          </div>
        </div>
      </div>
    );
  }

  if (!user) return null;

  return (
    <div className="min-h-screen bg-[#FBFCFE] text-[#26344A]">
      <ClientAreaHeader
        userName={profile?.nombre || user.email || "Usuario"}
        onLogout={handleLogout}
      />

      {/* Accesos flotantes: deliberadamente pequeños y sin texto. */}
      <div className="fixed right-5 top-[90px] z-40 flex items-center gap-2 sm:right-7">
        <Dialog open={isCalendarOpen} onOpenChange={setIsCalendarOpen}>
          <DialogTrigger asChild>
            <button
              type="button"
              onClick={handleOpenCalendar}
              aria-label="Abrir calendario"
              title="Calendario"
className="relative flex h-10 w-10 items-center justify-center rounded-full border border-[#2855A3] bg-[#173B8F] text-white transition-all duration-200 hover:border-[#3D69B5] hover:bg-[#2855A3] hover:text-white"            >
              <CalendarDays className="h-[17px] w-[17px]" strokeWidth={1.8} />
            </button>
          </DialogTrigger>
          <DialogContent className="sm:max-w-3xl">
            <DialogHeader>
              <DialogTitle className="text-[#182A45]">Calendario</DialogTitle>
              <DialogDescription>
                Fechas relevantes procedentes de los hitos de tus proyectos.
              </DialogDescription>
            </DialogHeader>

            <div className="grid gap-6 md:grid-cols-[1.15fr_0.85fr]">
              <div className="border-b border-[#E7EBF0] pb-5 md:border-b-0 md:border-r md:pr-6">
                <div className="mb-4 flex items-center justify-between">
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    onClick={() =>
                      setCalendarMonth(
                        new Date(calendarMonth.getFullYear(), calendarMonth.getMonth() - 1, 1)
                      )
                    }
                    aria-label="Mes anterior"
                  >
                    <ChevronLeft className="h-4 w-4" />
                  </Button>
                  <p className="text-sm font-semibold capitalize text-[#26344A]">
                    {calendarMonthLabel}
                  </p>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    onClick={() =>
                      setCalendarMonth(
                        new Date(calendarMonth.getFullYear(), calendarMonth.getMonth() + 1, 1)
                      )
                    }
                    aria-label="Mes siguiente"
                  >
                    <ChevronRight className="h-4 w-4" />
                  </Button>
                </div>

                <div className="grid grid-cols-7 text-center text-[10px] font-semibold uppercase tracking-wider text-[#98A1AE]">
                  {['L', 'M', 'X', 'J', 'V', 'S', 'D'].map((day) => (
                    <span key={day} className="py-2">{day}</span>
                  ))}
                </div>
                <div className="grid grid-cols-7 gap-1">
                  {calendarGrid.map((day, index) => {
                    if (!day) return <div key={`empty-${index}`} className="h-10" />;
                    const dateKey = `${calendarMonth.getFullYear()}-${String(
                      calendarMonth.getMonth() + 1
                    ).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
                    const dayEvents = calendarEvents.filter((event) => event.dateKey === dateKey);
                    const selected = selectedCalendarDate === dateKey;
                    return (
                      <button
                        key={dateKey}
                        type="button"
                        onClick={() => setSelectedCalendarDate(dateKey)}
                        className={[
                          'relative flex h-10 items-center justify-center rounded-md text-xs transition',
                          selected
                            ? 'bg-[#173B8F] font-semibold text-white'
                            : 'text-[#445166] hover:bg-[#F2F5F9]',
                        ].join(' ')}
                      >
                        {day}
                        {dayEvents.length > 0 && (
                          <span
                            className={[
                              'absolute bottom-1 h-1 w-1 rounded-full',
                              selected ? 'bg-white' : 'bg-[#173B8F]',
                            ].join(' ')}
                          />
                        )}
                      </button>
                    );
                  })}
                </div>
              </div>

              <div className="min-h-36">
                <p className="mb-4 text-[10px] font-semibold uppercase tracking-[0.16em] text-[#8792A3]">
                  {selectedCalendarDate
                    ? formatDate(`${selectedCalendarDate}T12:00:00`)
                    : 'Selecciona una fecha'}
                </p>
                {selectedDayEvents.length === 0 ? (
                  <p className="text-sm leading-6 text-[#7C8797]">
                    No hay hitos previstos para esta fecha.
                  </p>
                ) : (
                  <div className="space-y-4">
                    {selectedDayEvents.map((event) => (
                      <div key={event.id} className="border-l-2 border-[#D9E1EC] pl-4">
                        <p className="text-sm font-semibold text-[#26344A]">{event.title}</p>
                        <p className="mt-1 text-xs text-[#7B8798]">{event.projectName}</p>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          </DialogContent>
        </Dialog>

        <Dialog open={isNotificationsOpen} onOpenChange={setIsNotificationsOpen}>
          <DialogTrigger asChild>
            <button
              type="button"
              aria-label="Abrir notificaciones"
              title="Notificaciones"
className="relative flex h-10 w-10 items-center justify-center rounded-full border border-[#2855A3] bg-[#173B8F] text-white transition-all duration-200 hover:border-[#3D69B5] hover:bg-[#2855A3] hover:text-white"            >
              <Bell className="h-[17px] w-[17px]" strokeWidth={1.8} />
              {unreadNotifications.length > 0 && (
                <span className="absolute -right-1 -top-1 flex h-[18px] min-w-[18px] items-center justify-center rounded-full border-2 border-white bg-[#173B8F] px-1 text-[9px] font-bold leading-none text-white">
                  {unreadNotifications.length > 99 ? '99+' : unreadNotifications.length}
                </span>
              )}
            </button>
          </DialogTrigger>
          <DialogContent className="max-h-[85vh] overflow-hidden sm:max-w-xl">
            <DialogHeader>
              <div className="flex items-center justify-between gap-4">
                <div>
                  <DialogTitle className="text-[#182A45]">Notificaciones</DialogTitle>
                  <DialogDescription>
                    Avisos importantes relacionados con tus proyectos y tu cuenta.
                  </DialogDescription>
                </div>
                {unreadNotifications.length > 0 && (
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    onClick={handleMarkAllNotificationsRead}
                    className="text-xs text-[#173B8F]"
                  >
                    Marcar todas como leídas
                  </Button>
                )}
              </div>
            </DialogHeader>

            <div className="max-h-[60vh] overflow-y-auto pr-1">
              {notifications.length === 0 ? (
                <div className="py-12 text-center">
                  <Bell className="mx-auto mb-3 h-7 w-7 text-[#B0B8C4]" strokeWidth={1.5} />
                  <p className="text-sm font-semibold text-[#26344A]">No tienes notificaciones</p>
                  <p className="mt-1 text-xs text-[#8792A3]">Aquí aparecerán los avisos importantes.</p>
                </div>
              ) : (
                <div className="divide-y divide-[#EEF1F5]">
                  {notifications.map((notification) => {
                    const projectName = notification.project_id
                      ? projectById.get(notification.project_id)?.nombre
                      : null;
                    return (
                      <button
                        key={notification.id}
                        type="button"
                        onClick={() => handleMarkNotificationRead(notification)}
                        className="flex w-full gap-3 py-4 text-left transition first:pt-1 hover:bg-[#FAFBFC]"
                      >
                        <span
                          className={[
                            'mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full',
                            notification.read_at ? 'bg-transparent' : 'bg-[#173B8F]',
                          ].join(' ')}
                        />
                        <span className="min-w-0 flex-1">
                          <span className="flex flex-col gap-1 sm:flex-row sm:items-start sm:justify-between">
                            <span className="text-sm font-semibold text-[#26344A]">
                              {notification.titulo}
                            </span>
                            <span className="text-[10px] text-[#9AA4B2]">
                              {formatCompactDate(notification.created_at)}
                            </span>
                          </span>
                          <span className="mt-1 block text-xs leading-5 text-[#718096]">
                            {notification.mensaje}
                          </span>
                          {projectName && (
                            <span className="mt-1.5 block text-[10px] font-medium text-[#173B8F]">
                              {projectName}
                            </span>
                          )}
                        </span>
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          </DialogContent>
        </Dialog>
      </div>

      <main className="mx-auto max-w-[1380px] px-5 pb-20 pt-[105px] sm:px-8 lg:px-12">
        {error && (
          <div className="mb-7 flex items-center gap-3 border-b border-red-200 bg-red-50/70 px-4 py-3 text-sm text-red-700">
            <AlertCircle className="h-4 w-4 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {sectionWarnings.length > 0 && !error && (
          <div className="mb-7 flex items-center gap-3 border-b border-[#E9E0C8] bg-[#FFFDF6] px-4 py-3 text-xs text-[#766A4A]">
            <AlertTriangle className="h-4 w-4 shrink-0" />
            <span>Algunos apartados están temporalmente disponibles de forma limitada.</span>
          </div>
        )}

        {/* ------------------------------------------------------------
            CABECERA
        ------------------------------------------------------------ */}
        <section className="mb-8 border-b border-[#E6EAF0] pb-8">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                Área de Cliente
              </p>
              <h1 className="text-2xl font-semibold tracking-tight text-[#182A45] sm:text-3xl">
                {greeting}, {profile?.nombre || 'bienvenido'}
              </h1>
              <p className="mt-1.5 max-w-2xl text-sm text-[#718096]">
                Aquí tienes una visión clara del estado de tus proyectos y de cualquier asunto que requiera tu atención.
              </p>
            </div>
            <div className="hidden text-right sm:block">
              <p className="text-[10px] font-medium uppercase tracking-[0.15em] text-[#A0A8B4]">Empresa</p>
              <p className="mt-1 text-sm font-medium text-[#465267]">{company?.company_name || 'Sin empresa asociada'}</p>
            </div>
          </div>
        </section>

        {/* ------------------------------------------------------------
            PROYECTOS — elemento principal del dashboard.
            Entregado queda fuera; si no hay Pendiente/Activo/Pausado/Completado,
            no se muestra ningún bloque de proyecto.
        ------------------------------------------------------------ */}
        {dashboardProjects.length > 0 && (
          <section className="mb-10">
            <SectionTitle
              eyebrow="Seguimiento"
              title="Mis proyectos"
              action={
                <button
                  type="button"
                  onClick={() => setLocation('/area-cliente/proyectos')}
                  className="flex items-center gap-1 text-[11px] font-medium text-[#173B8F]"
                >
                  Ver proyectos
                  <ArrowRight className="h-3.5 w-3.5" />
                </button>
              }
            />

            <div className="space-y-8">
              {dashboardProjects.map((project) => {
                const projectStatus = normalizeStatus(project.estado);
                const projectMilestones = milestonesByProject.get(project.id) || [];
                const progress =
                  projectStatus === "Completado"
                    ? 100
                    : progressByProject[project.id]?.progress_percentage ?? 0;
                const completed =
                  progressByProject[project.id]?.completed_milestones ??
                  projectMilestones.filter((item) => item.estado === "completado").length;
                const total =
                  progressByProject[project.id]?.total_milestones ?? projectMilestones.length;
                const nextMilestone = nextMilestoneByProject.get(project.id);
                const phase = phaseByProject.get(project.id) || projectStatus;

                if (projectStatus === "Pendiente") {
                  return (
                    <article key={project.id} className="border-y border-[#E3E8EE] bg-white/25">
                      <div className="flex flex-col gap-5 px-2 py-6 sm:flex-row sm:items-center sm:justify-between sm:px-4">
                        <div className="min-w-0">
                          <div className="mb-2 flex flex-wrap items-center gap-2.5">
                            <span className="rounded-full border border-[#DDE3EB] bg-[#F7F8FA] px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.08em] text-[#6E7A8C]">
                              Pendiente
                            </span>
                            <span className="text-[10px] font-medium uppercase tracking-[0.1em] text-[#9AA3AF]">
                              Próximamente
                            </span>
                          </div>
                          <h3 className="text-lg font-semibold tracking-tight text-[#26364D] sm:text-xl">
                            {project.nombre}
                          </h3>
                          <p className="mt-1.5 max-w-2xl text-xs leading-5 text-[#7C8797]">
                            Tu proyecto está pendiente de inicio. Cuando Modira lo active, aquí podrás seguir su progreso y sus hitos.
                          </p>
                        </div>
                        <button
                          type="button"
                          onClick={() => setLocation('/area-cliente/proyectos')}
                          className="flex shrink-0 items-center gap-1.5 text-xs font-medium text-[#173B8F]"
                        >
                          Ver proyecto
                          <ArrowRight className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </article>
                  );
                }

                const progressTone = projectStatus === "Pausado" ? "paused" : "active";

                return (
                  <article key={project.id} className="border-y border-[#E3E8EE] bg-white/25">
                    <div className="px-2 py-6 sm:px-4 sm:py-7">
                      <div className="mb-6 flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                        <div className="min-w-0">
                          <div className="mb-2 flex flex-wrap items-center gap-2.5">
                            <span
                              className={[
                                "rounded-full border px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.08em]",
                                projectStatus === "Pausado"
                                  ? "border-amber-200 bg-amber-50 text-amber-700"
                                  : projectStatus === "Completado"
                                    ? "border-emerald-200 bg-emerald-50 text-emerald-700"
                                    : "border-[#D5E0F5] bg-[#F5F8FF] text-[#173B8F]",
                              ].join(" ")}
                            >
                              {projectStatus}
                            </span>
                            {projectStatus !== "Completado" && (
                              <span className="text-[10px] font-medium uppercase tracking-[0.1em] text-[#909AA8]">
                                Fase · {phase}
                              </span>
                            )}
                          </div>
                          <h3 className="text-lg font-semibold tracking-tight text-[#1F3047] sm:text-xl">
                            {project.nombre}
                          </h3>
                          {project.descripcion && (
                            <p className="mt-1.5 max-w-2xl text-xs leading-5 text-[#788495]">
                              {project.descripcion}
                            </p>
                          )}
                        </div>
                        <button
                          type="button"
                          onClick={() => setLocation('/area-cliente/proyectos')}
                          className="flex shrink-0 items-center gap-1.5 text-xs font-medium text-[#173B8F]"
                        >
                          Ver proyecto
                          <ArrowRight className="h-3.5 w-3.5" />
                        </button>
                      </div>

                      <div className="grid gap-7 lg:grid-cols-[auto_minmax(0,1fr)_220px] lg:items-center">
                        <div className="flex justify-center lg:justify-start">
                          <ProgressRing percentage={progress} tone={progressTone} />
                        </div>

                        <div className="min-w-0">
                          <div className="mb-4 flex items-center justify-between gap-4">
                            <div>
                              <p className="text-xs font-semibold text-[#354359]">Recorrido del proyecto</p>
                              <p className="mt-1 text-[11px] text-[#8B95A4]">
                                {completed} de {total} hitos completados
                              </p>
                            </div>
                          </div>
                          <MilestoneTimeline
                            milestones={projectMilestones}
                            projectStatus={projectStatus}
                          />
                        </div>

                        <div className="border-l-0 border-[#E7EBF0] pt-1 lg:border-l lg:pl-6">
                          {projectStatus === "Pausado" ? (
                            <>
                              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-amber-700">Estado</p>
                              <p className="mt-2 text-sm font-semibold text-[#2D3B50]">Proyecto pausado</p>
                              <p className="mt-1 text-xs leading-5 text-[#7D8898]">
                                El progreso se conserva hasta que el proyecto vuelva a estar activo.
                              </p>
                            </>
                          ) : projectStatus === "Completado" ? (
                            <>
                              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-emerald-700">Estado</p>
                              <p className="mt-2 text-sm font-semibold text-[#2D3B50]">Proyecto completado</p>
                              <p className="mt-1 text-xs leading-5 text-[#7D8898]">Todos los hitos del proyecto están completados.</p>
                            </>
                          ) : (
                            <>
                              <div className="flex items-center gap-2">
                                <CalendarDays className="h-4 w-4 text-[#7E8998]" strokeWidth={1.7} />
                                <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8993A2]">Próximo hito</p>
                              </div>
                              {nextMilestone ? (
                                <>
                                  <p className="mt-2 text-sm font-semibold text-[#2D3B50]">{nextMilestone.nombre}</p>
                                  <p className="mt-1 text-xs text-[#7D8898]">{formatDate(nextMilestone.fecha_prevista)}</p>
                                </>
                              ) : projectMilestones.length ? (
                                <p className="mt-2 text-xs leading-5 text-[#7D8898]">Todos los hitos definidos están completados.</p>
                              ) : (
                                <p className="mt-2 text-xs leading-5 text-[#7D8898]">Aún no hay un próximo hito definido.</p>
                              )}
                            </>
                          )}
                        </div>
                      </div>
                    </div>
                  </article>
                );
              })}
            </div>
          </section>
        )}

        {/* ------------------------------------------------------------
            RESUMEN — cuatro indicadores ligeros.
        ------------------------------------------------------------ */}
        <section className="mb-10 grid grid-cols-2 divide-x divide-y divide-[#E5E9EF] border-y border-[#E5E9EF] bg-white/40 lg:grid-cols-4 lg:divide-y-0">
          {[
            {
              label: "Proyectos",
              value: dashboardProjects.length,
              detail: dashboardProjects.length === 1 ? "Proyecto visible" : "Proyectos visibles",
              icon: BriefcaseBusiness,
              href: "/area-cliente/proyectos",
              active: dashboardProjects.length > 0,
            },
            {
              label: "Planes de mantenimiento",
              value: contractedMaintenanceContracts.length,
              detail: maintenancePlanNames.length
                ? maintenancePlanNames.slice(0, 2).join(" · ")
                : "Ninguno",
              icon: ClipboardList,
              href: "/area-cliente/mantenimiento",
              active: contractedMaintenanceContracts.length > 0,
            },
            {
              label: "Presupuestos pendientes",
              value: pendingQuotations.length,
              detail: pendingQuotations.length === 1 ? "Pendiente de respuesta" : "Pendientes de respuesta",
              icon: FileText,
              href: "/area-cliente/presupuestos",
              active: pendingQuotations.length > 0,
            },
            {
              label: "Facturación pendiente",
              value: pendingInvoices.length,
              detail: pendingInvoices.length ? formatCurrency(outstandingAmount) : "Todo al día",
              icon: Receipt,
              href: "/area-cliente/facturacion",
              active: pendingInvoices.length > 0,
            },
          ].map((item) => {
            const Icon = item.icon;
            return (
              <button
                key={item.label}
                type="button"
                onClick={() => setLocation(item.href)}
                className={[
                  "group min-h-[116px] px-5 py-5 text-left transition sm:px-7",
                  item.active ? "bg-[#2855A3] text-white hover:bg-[#234A91]" : "bg-white/50 text-[#1E2D43] hover:bg-white",
                ].join(" ")}
              >
                <div className="flex h-full items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className={[
                      "text-[10px] font-semibold uppercase tracking-[0.13em]",
                      item.active ? "text-white/75" : "text-[#8A95A4]",
                    ].join(" ")}>
                      {item.label}
                    </p>
                    <p className={[
                      "mt-2 text-2xl font-semibold tracking-tight",
                      item.active ? "text-white" : "text-[#1E2D43]",
                    ].join(" ")}>
                      {item.value}
                    </p>
                    <p className={[
                      "mt-0.5 truncate text-xs",
                      item.active ? "text-white/80" : "text-[#8A95A4]",
                    ].join(" ")}>
                      {item.detail}
                    </p>
                  </div>
                  <Icon
                    className={[
                      "mt-0.5 h-4 w-4 shrink-0",
                      item.active ? "text-white/80" : "text-[#A1AAB7] group-hover:text-[#173B8F]",
                    ].join(" ")}
                    strokeWidth={1.7}
                  />
                </div>
              </button>
            );
          })}
        </section>

        {/* ------------------------------------------------------------
            ACCIONES PENDIENTES
        ------------------------------------------------------------ */}
        <section id="acciones" className="mb-10">
          <SectionTitle
            eyebrow="Atención"
            title="Acciones pendientes"
            action={
              pendingActions.length > 0 ? (
                <span className="flex h-6 min-w-6 items-center justify-center rounded-full bg-[#173B8F] px-2 text-[10px] font-semibold text-white">
                  {pendingActions.length > 99 ? "99+" : pendingActions.length}
                </span>
              ) : undefined
            }
          />

          {pendingActions.length === 0 ? (
            <div className="border-y border-[#E7EBF0] py-6">
              <div className="flex items-center gap-3">
                <div className="flex h-8 w-8 items-center justify-center rounded-full bg-[#F1F7F2] text-[#5E9470]">
                  <Check className="h-4 w-4" />
                </div>
                <div>
                  <p className="text-sm font-medium text-[#344156]">No tienes acciones pendientes</p>
                  <p className="mt-0.5 text-xs text-[#8993A2]">No hay presupuestos, facturas o solicitudes que requieran tu atención.</p>
                </div>
              </div>
            </div>
          ) : (
            <div className="divide-y divide-[#E7EBF0] border-y border-[#E7EBF0] bg-white/35">
              {pendingActions.map((action) => (
                <button
                  key={action.id}
                  type="button"
                  onClick={() => {
                    if (action.href?.startsWith('#')) {
                      document.getElementById(action.href.slice(1))?.scrollIntoView({ behavior: 'smooth' });
                    } else if (action.href) {
                      setLocation(action.href);
                    }
                  }}
                  className="group flex w-full items-center gap-4 px-3 py-4 text-left transition hover:bg-white sm:px-4"
                >
                  <div
                    className={[
                      'flex h-9 w-9 shrink-0 items-center justify-center rounded-full',
                      action.type === 'invoice' ? 'bg-[#F8F3EE] text-[#9A6C45]' :
                        action.type === 'quotation' ? 'bg-[#F2F5FB] text-[#173B8F]' :
                          'bg-[#F5F5F2] text-[#6E705E]',
                    ].join(' ')}
                  >
                    {action.type === 'invoice' ? <Receipt className="h-4 w-4" strokeWidth={1.7} /> :
                      action.type === 'quotation' ? <FileText className="h-4 w-4" strokeWidth={1.7} /> :
                        <Building2 className="h-4 w-4" strokeWidth={1.7} />}
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium text-[#2F3D52]">{action.title}</p>
                    <p className="mt-0.5 truncate text-xs text-[#8792A3]">{action.description}</p>
                  </div>
                  <span className="hidden text-[10px] font-semibold uppercase tracking-[0.1em] text-[#173B8F] sm:block">
                    {action.label}
                  </span>
                  <ArrowRight className="h-4 w-4 shrink-0 text-[#A2ABB8] transition group-hover:translate-x-0.5 group-hover:text-[#173B8F]" />
                </button>
              ))}
            </div>
          )}
        </section>

        {/* ------------------------------------------------------------
            NOVEDADES + DOCUMENTOS
            2/3 izquierda · 1/3 derecha. Facturación ya vive en el resumen.
        ------------------------------------------------------------ */}
        <section className="mb-14 grid gap-10 xl:grid-cols-[minmax(0,2fr)_minmax(260px,1fr)]">
          <div>
            <SectionTitle eyebrow="Actualidad" title="Últimas novedades" />
            {visibleUpdates.length === 0 ? (
              <div className="border-y border-[#E7EBF0] py-7">
                <p className="text-sm font-medium text-[#445166]">Todavía no hay novedades publicadas.</p>
                <p className="mt-1 text-xs text-[#8993A2]">Cuando Modira publique una actualización, aparecerá aquí.</p>
              </div>
            ) : (
              <div className="relative border-y border-[#E7EBF0] py-2">
                <div className="absolute bottom-5 left-[7px] top-5 w-px bg-[#E0E5EB]" />
                <div className="divide-y divide-[#EEF1F5]">
                  {visibleUpdates.slice(0, 5).map((update) => (
                    <article key={update.id} className="relative py-5 pl-7">
                      <span className="absolute left-0 top-[26px] h-[15px] w-[15px] rounded-full border-4 border-[#FBFCFE] bg-[#173B8F] shadow-[0_0_0_1px_#D8DEE6]" />
                      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                        <span className="text-[10px] font-semibold uppercase tracking-[0.12em] text-[#7E8998]">
                          {formatCompactDate(update.created_at)}
                        </span>
                        {projectById.get(update.project_id)?.nombre && (
                          <span className="text-[10px] text-[#A0A8B4]">
                            {projectById.get(update.project_id)?.nombre}
                          </span>
                        )}
                      </div>
                      <h3 className="mt-1.5 text-sm font-semibold text-[#334157]">{update.titulo}</h3>
                      <p className="mt-1 text-xs leading-5 text-[#778395]">{update.contenido}</p>
                    </article>
                  ))}
                </div>
              </div>
            )}
          </div>

          <div>
            <SectionTitle
                eyebrow="Archivos"
                title="Documentos recientes"
                action={<FileText className="h-4 w-4 text-[#8A95A4]" strokeWidth={1.7} />}
              />
              {visibleDocuments.length === 0 ? (
                <div className="border-y border-[#E7EBF0] py-6">
                  <p className="text-xs text-[#8993A2]">No hay documentos disponibles todavía.</p>
                </div>
              ) : (
                <div className="divide-y divide-[#EEF1F5] border-y border-[#E7EBF0]">
                  {visibleDocuments.slice(0, 4).map((document) => (
                    <button
                      key={document.id}
                      type="button"
                      onClick={() => handleOpenDocument(document)}
                      className="group flex w-full items-center gap-3 py-3 text-left transition hover:bg-white"
                    >
                      <FileText className="h-4 w-4 shrink-0 text-[#8A95A4] group-hover:text-[#173B8F]" strokeWidth={1.7} />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-xs font-medium text-[#445166]">{document.file_name}</span>
                        <span className="mt-0.5 block text-[10px] text-[#9AA4B2]">{formatCompactDate(document.created_at)}</span>
                      </span>
                      <ExternalLink className="h-3.5 w-3.5 shrink-0 text-[#A4ADB9]" strokeWidth={1.6} />
                    </button>
                  ))}
                </div>
              )}
              <button
                type="button"
                onClick={() => setLocation('/area-cliente/documentos')}
                className="mt-3 flex items-center gap-1 text-[11px] font-medium text-[#173B8F]"
              >
                Ver documentos
                <ArrowRight className="h-3.5 w-3.5" />
              </button>
          </div>
        </section>

        {/* ------------------------------------------------------------
            MI CUENTA — conservado, pero mucho más ligero visualmente.
        ------------------------------------------------------------ */}
        <section id="perfil" className="mb-8">
          <SectionTitle
            eyebrow="Cuenta"
            title="Mi cuenta"
            action={
              <Dialog open={isEditDialogOpen} onOpenChange={setIsEditDialogOpen}>
                <DialogTrigger asChild>
                  <Button
                    type="button"
                    variant="outline"
                    className="h-8 border-[#D9E0E8] px-3 text-[11px] font-medium text-[#4E5B6F] hover:bg-white"
                  >
                    <Edit2 className="mr-1.5 h-3.5 w-3.5" />
                    Editar
                  </Button>
                </DialogTrigger>
                <DialogContent>
                  <DialogHeader>
                    <DialogTitle>Editar perfil</DialogTitle>
                    <DialogDescription>
                      Actualiza tu información personal y de contacto.
                    </DialogDescription>
                  </DialogHeader>
                  <div className="grid gap-4 py-4">
                    <div className="grid gap-2">
                      <Label htmlFor="client-name">Nombre</Label>
                      <Input
                        id="client-name"
                        value={editForm.nombre}
                        onChange={(event) => setEditForm({ ...editForm, nombre: event.target.value })}
                      />
                    </div>
                    <div className="grid gap-2">
                      <Label htmlFor="client-phone">Teléfono</Label>
                      <Input
                        id="client-phone"
                        value={editForm.telefono}
                        onChange={(event) => setEditForm({ ...editForm, telefono: event.target.value })}
                      />
                    </div>
                    <div className="border-t border-[#E8ECF2] pt-4">
                      <p className="text-xs font-semibold text-[#52627A]">Empresa</p>
                      <p className="mt-1 text-sm font-medium text-[#26344A]">{company?.company_name || 'Sin definir'}</p>
                      <p className="mt-1 text-xs text-[#8792A3]">La empresa asociada se gestiona mediante el flujo seguro de Modira.</p>
                    </div>
                  </div>
                  <DialogFooter>
                    <Button type="button" variant="outline" onClick={() => setIsEditDialogOpen(false)}>Cancelar</Button>
                    <Button type="button" className="bg-[#173B8F] text-white hover:bg-[#102A66]" onClick={handleUpdateProfile}>Guardar cambios</Button>
                  </DialogFooter>
                </DialogContent>
              </Dialog>
            }
          />

          {profile && (
            <div className="grid gap-x-10 gap-y-5 border-y border-[#E7EBF0] py-6 sm:grid-cols-2 lg:grid-cols-4">
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">Nombre</p>
                <p className="mt-1 text-xs font-medium text-[#445166]">{profile.nombre}</p>
              </div>
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">Correo</p>
                <p className="mt-1 truncate text-xs font-medium text-[#445166]">{user.email}</p>
              </div>
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">Empresa</p>
                <p className="mt-1 text-xs font-medium text-[#445166]">{company?.company_name || 'Sin definir'}</p>
              </div>
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">Registro</p>
                <p className="mt-1 text-xs font-medium text-[#445166]">{formatCompactDate(profile.fecha_registro)}</p>
              </div>
            </div>
          )}

          <div className="mt-5 flex flex-col gap-3 border-b border-[#EEF1F5] pb-5 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p className="text-xs font-medium text-[#4A586D]">¿Necesitas cambiar de empresa?</p>
              <p className="mt-0.5 text-[11px] text-[#8993A2]">La solicitud será revisada por Modira antes de realizar cualquier cambio.</p>
              {hasPendingCompanyRequest && (
                <p className="mt-1.5 text-[11px] font-medium text-[#173B8F]">Solicitud pendiente de revisión.</p>
              )}
            </div>
            <Dialog open={isCompanyRequestDialogOpen} onOpenChange={setIsCompanyRequestDialogOpen}>
              <DialogTrigger asChild>
                <Button
                  type="button"
                  variant="outline"
                  disabled={hasPendingCompanyRequest}
                  className="h-8 shrink-0 border-[#D9E0E8] px-3 text-[11px] font-medium text-[#4E5B6F] hover:bg-white disabled:opacity-50"
                >
                  <Send className="mr-1.5 h-3.5 w-3.5" />
                  {hasPendingCompanyRequest ? 'Solicitud pendiente' : 'Solicitar cambio'}
                </Button>
              </DialogTrigger>
              <DialogContent>
                <DialogHeader>
                  <DialogTitle>Solicitar cambio de empresa</DialogTitle>
                  <DialogDescription>
                    Indica la empresa a la que quieres solicitar que Modira asocie tu cuenta.
                  </DialogDescription>
                </DialogHeader>
                <div className="grid gap-4 py-4">
                  <div className="border-b border-[#E8ECF2] pb-4">
                    <p className="text-xs font-semibold text-[#52627A]">Empresa actual</p>
                    <p className="mt-1 text-sm font-medium text-[#26344A]">{company?.company_name || 'Sin definir'}</p>
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="requested-company">Nueva empresa</Label>
                    <Input
                      id="requested-company"
                      placeholder="Ej. Empresa S.L."
                      value={requestedCompanyName}
                      onChange={(event) => setRequestedCompanyName(event.target.value)}
                      disabled={requestingCompanyChange}
                    />
                  </div>
                </div>
                <DialogFooter>
                  <Button type="button" variant="outline" disabled={requestingCompanyChange} onClick={() => setIsCompanyRequestDialogOpen(false)}>Cancelar</Button>
                  <Button
                    type="button"
                    className="bg-[#173B8F] text-white hover:bg-[#102A66]"
                    disabled={requestingCompanyChange || !requestedCompanyName.trim()}
                    onClick={handleRequestCompanyChange}
                  >
                    {requestingCompanyChange ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <Send className="mr-2 h-4 w-4" />}
                    {requestingCompanyChange ? 'Enviando...' : 'Enviar solicitud'}
                  </Button>
                </DialogFooter>
              </DialogContent>
            </Dialog>
          </div>
        </section>
      </main>

      <footer className="border-t border-[#E4E8EE] bg-white py-7">
        <div className="mx-auto flex max-w-[1380px] flex-col gap-2 px-5 text-xs text-[#9AA3AF] sm:flex-row sm:items-center sm:justify-between sm:px-8 lg:px-12">
          <p>© {new Date().getFullYear()} Modira. Todos los derechos reservados.</p>
          <p>Área de Cliente</p>
        </div>
      </footer>
    </div>
  );
}
