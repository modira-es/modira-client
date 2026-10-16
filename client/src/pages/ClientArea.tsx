import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useAuth } from "@/contexts/AuthContext";
import { useLocation } from "wouter";
import { Button } from "@/components/ui/button";
import ClientFloatingActions from "@/components/ClientFloatingActions";
import {
  AlertCircle,
  AlertTriangle,
  ArrowRight,
  Bell,
  CircleHelp,
  BriefcaseBusiness,
  Home,
  CalendarDays,
  Check,
  ChevronLeft,
  ChevronRight,
  ClipboardList,
  Edit2,
  ExternalLink,
  FileText,
  Loader2,
  LogOut,
  Menu,
  Receipt,
  Send,
  Trash2,
  UserRound,
  Wrench,
  Building2,
  Clock3,
  X,
  Percent,
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

interface UserProfile {
  id: string;
  company_id: string | null;
  nombre: string;
  empresa: string | null;
  telefono: string | null;
  fecha_registro: string;
  fecha_ultimo_login: string;
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
  change_requests_enabled: boolean;
  change_requests_deadline: string | null;
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
  document_path?: string | null;
  created_at: string;
  updated_at?: string | null;
}

interface Quotation {
  id: string;
  company_id: string | null;
  project_id?: string | null;
  numero_presupuesto?: string | null;
  titulo?: string | null;
  estado: string;
  fecha_emision?: string | null;
  fecha_validez?: string | null;
  document_path?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
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


interface SupportTicket {
  id: string;
  user_id: string;
  company_id: string | null;
  titulo: string;
  descripcion: string | null;
  prioridad: string;
  estado: "abierto" | "en_progreso" | "cerrado" | string;
  created_at: string;
  updated_at: string;
}

interface ProjectChangeRequest {
  id: string;
  project_id: string;
  user_id: string;
  description: string;
  status: "pending" | "in_review" | "accepted" | "rejected" | "completed" | string;
  created_at: string;
  updated_at: string;
}

interface PendingAction {
  id: string;
  type:
    | "ticket"
    | "project"
    | "completion"
    | "quotation"
    | "invoice"
    | "project_change"
    | "company"
    | "account";
  title: string;
  description: string;
  label: string;
  href?: string;
  createdAt?: string | null;
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

const dialogCancelClass =
  "h-9 min-w-[120px] justify-center border-[#D9E0E8] bg-white px-4 text-[11px] font-semibold text-[#4E5B6F] hover:border-[#C7D0DB] hover:bg-[#F3F5F8] hover:text-[#445166]";

const dialogPrimaryClass =
  "h-9 min-w-[120px] justify-center bg-[#173B8F] px-4 text-[11px] font-semibold text-white hover:bg-[#102A66]";

const dialogDangerClass =
  "h-9 min-w-[120px] justify-center bg-[#9E5555] px-4 text-[11px] font-semibold text-white hover:bg-[#874747]";

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

  const projectCompleted = projectStatus === "Completado";
  const projectPaused = projectStatus === "Pausado";

  return (
    <div className="w-full overflow-x-auto pb-1">
      <div
        className="mx-auto grid w-full max-w-5xl"
        style={{
          gridTemplateColumns: `repeat(${milestones.length}, minmax(0, 1fr))`,
        }}
      >
        {milestones.map((milestone, index) => {
          const completed = milestone.estado === "completado";
          const current = milestone.estado === "en_curso";

          /*
           * MUY IMPORTANTE:
           *
           * La línea que sale de este hito y llega al siguiente
           * NO depende de que este hito esté completado.
           *
           * La línea pertenece al tramo:
           *
           *      Hito anterior ---- Hito actual
           *
           * Por eso, para pintar el tramo anterior, comprobamos
           * si ESTE hito está completado.
           */

          const lineToPreviousIsCompleted =
            index > 0 &&
            (completed || projectCompleted);

          const lineColor = projectPaused
            ? lineToPreviousIsCompleted
              ? "bg-amber-400"
              : "bg-[#DDE2E9]"
            : lineToPreviousIsCompleted
              ? "bg-emerald-500"
              : "bg-[#DDE2E9]";

          const nodeColor = projectCompleted
            ? "border-emerald-500 bg-emerald-500 text-white"
            : projectPaused && completed
              ? "border-amber-400 bg-amber-400 text-white"
              : completed
                ? "border-emerald-500 bg-emerald-500 text-white"
                : current
                  ? projectPaused
                    ? "border-amber-400 bg-white text-amber-600 ring-4 ring-amber-400/10"
                    : "border-[#173B8F] bg-white text-[#173B8F] ring-4 ring-[#173B8F]/5"
                  : "border-[#CBD3DE] bg-white text-[#A1AAB8]";

          return (
            <div
              key={milestone.id}
              className="relative min-w-0"
            >
              {/* --------------------------------------------------
                  LÍNEA QUE UNE CON EL HITO ANTERIOR
                  -------------------------------------------------- */}

              {index > 0 && (
                <div
                  className={[
                    "absolute left-0 right-1/2 top-3.5 h-px transition-colors duration-500",
                    lineColor,
                  ].join(" ")}
                />
              )}

              {/* --------------------------------------------------
                  LÍNEA QUE UNE CON EL SIGUIENTE HITO
                  --------------------------------------------------

                  IMPORTANTE:
                  Este tramo solo se colorea cuando el SIGUIENTE
                  hito está completado.

                  Así:

                  ○ Hito 1 ---- ○ Hito 2 ---- ○ Hito 3
                       VERDE          GRIS

                  Si Hito 2 está completado:

                  ✓ Hito 1 ---- ✓ Hito 2 ---- ○ Hito 3
                       VERDE          GRIS
                  -------------------------------------------------- */}

              {index < milestones.length - 1 && (
                <div
                  className={[
                    "absolute left-1/2 right-0 top-3.5 h-px transition-colors duration-500",
                    milestones[index + 1].estado === "completado" ||
                    projectCompleted
                      ? projectPaused
                        ? "bg-amber-400"
                        : "bg-emerald-500"
                      : "bg-[#DDE2E9]",
                  ].join(" ")}
                />
              )}

              {/* --------------------------------------------------
                  CONTENIDO DEL HITO
                  -------------------------------------------------- */}

              <div className="relative z-10 flex min-w-0 flex-col items-center text-center px-1 sm:px-2">

                {/* CÍRCULO */}

                <div
                  className={[
                    "relative flex h-6 w-6 shrink-0 items-center justify-center rounded-full border transition-all duration-500",
                    nodeColor,
                  ].join(" ")}
                >
                  {projectCompleted || completed ? (
                    <Check
                      className="h-3 w-3"
                      strokeWidth={2.5}
                    />
                  ) : current ? (
                    <span
                      className={[
                        "h-1.5 w-1.5 rounded-full",
                        projectPaused
                          ? "bg-amber-500"
                          : "bg-[#173B8F]",
                      ].join(" ")}
                    />
                  ) : (
                    <span className="h-1.5 w-1.5 rounded-full bg-[#CBD3DE]" />
                  )}
                </div>

                {/* NOMBRE */}

                <p
                  className={[
                    "mt-2 w-full max-w-[110px] truncate text-[11px] font-medium leading-4",
                    completed || current
                      ? "text-[#26344A]"
                      : "text-[#707C8D]",
                  ].join(" ")}
                  title={milestone.nombre}
                >
                  {milestone.nombre}
                </p>

                {/* FECHA */}

                <p className="mt-0.5 whitespace-nowrap text-[10px] text-[#9AA4B2]">
                  {formatCompactDate(milestone.fecha_prevista)}
                </p>

              </div>
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
    { label: "Mantenimiento", path: "/area-cliente/mantenimiento", icon: ClipboardList },
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
                <span className="modira-font text-lg tracking-wide text-[#26344A]">MODIRA</span>
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
                    <span className="truncate text-[12px] font-medium">{item.label}</span>
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

const CompanySection = ({
  companyId,
  companyName,
  userId,
  onSaved,
}: {
  companyId: string | null;
  companyName: string | null;
  userId: string | null;
  onSaved: () => void | Promise<void>;
}) => {
  const [isOpen, setIsOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);

  const [pendingRequest, setPendingRequest] = useState<{
    id: string;
    status: string;
    created_at: string;
    requested_company_name: string | null;
    apply_to_active_projects: boolean;
    review_notes: string | null;
  } | null>(null);

  const [form, setForm] = useState({
    company_name: "",
    legal_name: "",
    cif_vat: "",
    billing_email: "",
    address: "",
    postal_code: "",
    city: "",
    province: "",
    country: "ES",
    reason: "",
    apply_to_active_projects: false,
  });

  const fiscalComplete =
    Boolean(form.legal_name.trim()) &&
    Boolean(form.cif_vat.trim()) &&
    Boolean(form.address.trim()) &&
    Boolean(form.postal_code.trim()) &&
    Boolean(form.city.trim());

  const loadCompanyData = async () => {
    if (!companyId) return;

    try {
      setLoading(true);

      const [companyResult, requestResult] = await Promise.all([
        supabase
          .from("companies")
          .select(
            "company_name, legal_name, cif_vat, billing_email, address, postal_code, city, province, country"
          )
          .eq("id", companyId)
          .maybeSingle(),
        userId
          ? supabase
              .from("company_change_requests")
              .select(
                "id, status, created_at, requested_company_name, apply_to_active_projects, review_notes"
              )
              .eq("user_id", userId)
              .order("created_at", { ascending: false })
              .limit(1)
              .maybeSingle()
          : Promise.resolve({ data: null, error: null }),
      ]);

      if (companyResult.error) throw companyResult.error;
      if (requestResult.error) throw requestResult.error;

      const data = companyResult.data;

      setForm((current) => ({
        ...current,
        company_name: data?.company_name || "",
        legal_name: data?.legal_name || "",
        cif_vat: data?.cif_vat || "",
        billing_email: data?.billing_email || "",
        address: data?.address || "",
        postal_code: data?.postal_code || "",
        city: data?.city || "",
        province: data?.province || "",
        country: data?.country || "ES",
        reason: "",
        apply_to_active_projects: false,
      }));

      setPendingRequest(
        requestResult.data
          ? (requestResult.data as {
              id: string;
              status: string;
              created_at: string;
              requested_company_name: string | null;
              apply_to_active_projects: boolean;
              review_notes: string | null;
            })
          : null
      );
    } catch (err: any) {
      console.error("[ClientArea] Error cargando datos de empresa:", err);

      toast.error(
        `No se pudieron cargar los datos de empresa: ${
          err?.message || "Error desconocido"
        }`
      );
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (!companyId) return;

    loadCompanyData();
  }, [companyId, userId]);

  const handleOpen = async () => {
    if (!companyId) {
      toast.error("No tienes una empresa asociada a tu cuenta.");
      return;
    }

    await loadCompanyData();
    setIsOpen(true);
  };

  const handleSave = async () => {
    if (!companyId) {
      toast.error("No tienes una empresa asociada.");
      return;
    }

    if (pendingRequest?.status === "pending") {
      toast.info(
        "Ya tienes una solicitud de cambio de empresa y datos fiscales pendiente de revisión."
      );
      return;
    }

    const companyNameValue = form.company_name.trim();
    const legalName = form.legal_name.trim();
    const cifVat = form.cif_vat.trim().toUpperCase();
    const billingEmail = form.billing_email.trim().toLowerCase();
    const address = form.address.trim();
    const postalCode = form.postal_code.trim();
    const city = form.city.trim();
    const province = form.province.trim();
    const country = form.country.trim().toUpperCase();
    const reason = form.reason.trim();

    if (!companyNameValue) {
      toast.error("El nombre de empresa es obligatorio.");
      return;
    }

    if (!legalName) {
      toast.error("La razón social es obligatoria.");
      return;
    }

    if (!cifVat) {
      toast.error("El NIF/CIF es obligatorio.");
      return;
    }

    if (!address) {
      toast.error("La dirección fiscal es obligatoria.");
      return;
    }

    if (!postalCode) {
      toast.error("El código postal es obligatorio.");
      return;
    }

    if (!city) {
      toast.error("La localidad es obligatoria.");
      return;
    }

    if (billingEmail) {
      const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

      if (!emailPattern.test(billingEmail)) {
        toast.error("Introduce un correo de facturación válido.");
        return;
      }
    }

    if (!country || country.length !== 2) {
      toast.error("El país debe indicarse mediante su código ISO de 2 letras.");
      return;
    }

    try {
      setSaving(true);

      /*
       * El cliente NO actualiza companies directamente.
       * La modificación completa de empresa + datos fiscales se registra
       * como una única solicitud y debe ser revisada por Modira mediante
       * la RPC SECURITY DEFINER.
       */
      const { error } = await supabase.rpc(
        "request_company_change_with_projects",
        {
          p_requested_company_name: companyNameValue,
          p_requested_legal_name: legalName,
          p_requested_cif_vat: cifVat,
          p_requested_billing_email: billingEmail || null,
          p_requested_address: address,
          p_requested_postal_code: postalCode,
          p_requested_city: city,
          p_requested_province: province || null,
          p_requested_country: country,
          p_reason: reason || null,
          p_apply_to_active_projects: form.apply_to_active_projects,
        }
      );

      if (error) throw error;

      toast.success(
        "Solicitud enviada. Modira revisará los cambios antes de aplicarlos."
      );

      setIsOpen(false);

      // Recarga la solicitud real creada por la RPC; no se inventa ningún UUID local.
      await loadCompanyData();
      await onSaved();
    } catch (err: any) {
      console.error(
        "[ClientArea] Error solicitando cambio de empresa y datos fiscales:",
        err
      );

      toast.error(
        `No se pudo enviar la solicitud: ${
          err?.message || "Error desconocido"
        }`
      );
    } finally {
      setSaving(false);
    }
  };

  if (!companyId) {
    return (
      <div className="min-w-0">
        <div className="border-y border-[#E7EBF0] py-6 lg:border-y-0 lg:border-l lg:pl-8">
          <p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#8792A3]">
            Empresa
          </p>

          <h3 className="mt-1 text-sm font-semibold text-[#344156]">
            No hay una empresa asociada
          </h3>

          <p className="mt-1 text-xs leading-5 text-[#8993A2]">
            Para utilizar los servicios de empresa de Modira,
            primero necesitas tener una empresa asociada a tu cuenta.
          </p>
        </div>
      </div>
    );
  }

  const requestPending = pendingRequest?.status === "pending";
  const requestRejected = pendingRequest?.status === "rejected";

  return (
    <div className="min-w-0">
      <div className="border-y border-[#E7EBF0] py-6 lg:border-y-0 lg:border-l lg:pl-8">
        <div className="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#8792A3]">
              Empresa
            </p>

            <h3 className="mt-1 text-sm font-semibold text-[#344156]">
              Datos fiscales
            </h3>

            <p className="mt-1 text-xs leading-5 text-[#8993A2]">
              Información utilizada para la documentación comercial y la
              facturación.
            </p>
          </div>

          <Button
            type="button"
            variant="outline"
            onClick={handleOpen}
            disabled={loading || requestPending}
            className="h-9 shrink-0 justify-center border-[#D7DEE7] bg-white px-3 text-[11px] font-semibold text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#173B8F] hover:text-white disabled:opacity-50"
          >
            <Edit2 className="mr-1.5 h-3.5 w-3.5" />

            {requestPending
              ? "Solicitud pendiente"
              : loading
                ? "Cargando..."
                : "Editar datos"}
          </Button>
        </div>

        <div className="mt-5 space-y-4">
          <div>
            <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
              Empresa
            </p>

            <p className="mt-1 truncate text-xs font-medium text-[#445166]">
              {companyName || "Sin definir"}
            </p>
          </div>

          <div className="grid gap-x-8 gap-y-4 sm:grid-cols-2">
            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                Razón social
              </p>

              <p
                className={[
                  "mt-1 truncate text-xs font-medium",
                  form.legal_name
                    ? "text-[#445166]"
                    : "text-[#A0A8B4]",
                ].join(" ")}
              >
                {form.legal_name || "Pendiente"}
              </p>
            </div>

            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                NIF/CIF
              </p>

              <p
                className={[
                  "mt-1 truncate text-xs font-medium",
                  form.cif_vat
                    ? "text-[#445166]"
                    : "text-[#A0A8B4]",
                ].join(" ")}
              >
                {form.cif_vat || "Pendiente"}
              </p>
            </div>

            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                Correo de facturación 
              </p>

              <p
                className={[
                  "mt-1 truncate text-xs font-medium",
                  form.billing_email
                    ? "text-[#445166]"
                    : "text-[#A0A8B4]",
                ].join(" ")}
              >
                {form.billing_email || "No definido"}
              </p>
            </div>

            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                Código postal
              </p>

              <p
                className={[
                  "mt-1 truncate text-xs font-medium",
                  form.postal_code
                    ? "text-[#445166]"
                    : "text-[#A0A8B4]",
                ].join(" ")}
              >
                {form.postal_code || "Pendiente"}
              </p>
            </div>

            <div className="sm:col-span-2">
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                Dirección fiscal
              </p>

              <p
                className={[
                  "mt-1 truncate text-xs font-medium",
                  form.address
                    ? "text-[#445166]"
                    : "text-[#A0A8B4]",
                ].join(" ")}
              >
                {form.address || "Pendiente"}
              </p>
            </div>

            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                Localidad
              </p>

              <p
                className={[
                  "mt-1 truncate text-xs font-medium",
                  form.city
                    ? "text-[#445166]"
                    : "text-[#A0A8B4]",
                ].join(" ")}
              >
                {form.city || "Pendiente"}
              </p>
            </div>

            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                Provincia
              </p>

              <p
                className={[
                  "mt-1 truncate text-xs font-medium",
                  form.province
                    ? "text-[#445166]"
                    : "text-[#A0A8B4]",
                ].join(" ")}
              >
                {form.province || "No definida"}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2 border-t border-[#EEF1F5] pt-4">
            <span
              className={[
                "h-1.5 w-1.5 rounded-full",
                fiscalComplete
                  ? "bg-emerald-500"
                  : "bg-amber-400",
              ].join(" ")}
            />

            <p
              className={[
                "text-[11px] font-medium",
                fiscalComplete
                  ? "text-[#5E9470]"
                  : "text-[#9A8050]",
              ].join(" ")}
            >
              {fiscalComplete
                ? "Datos fiscales completos"
                : "Faltan datos fiscales necesarios"}
            </p>
          </div>

          {requestPending && (
            <div className="flex items-start gap-2.5 border-t border-[#EEF1F5] pt-4">
              <Clock3
                className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#173B8F]"
                strokeWidth={1.8}
              />

              <div>
                <p className="text-[11px] font-medium text-[#173B8F]">
                  Cambio de empresa y datos fiscales pendiente de revisión
                </p>

                <p className="mt-0.5 text-[10px] leading-4 text-[#8993A2]">
                  Los datos actuales seguirán siendo los oficiales hasta
                  que Modira apruebe la solicitud.
                </p>
              </div>
            </div>
          )}

          {requestRejected && pendingRequest?.review_notes && (
            <div className="border-t border-[#EEF1F5] pt-4">
              <p className="text-[11px] font-medium text-[#7B8798]">
                La última solicitud fue rechazada.
              </p>

              <p className="mt-1 text-[10px] leading-4 text-[#8993A2]">
                Motivo: {pendingRequest.review_notes}
              </p>
            </div>
          )}
        </div>
      </div>

      <Dialog open={isOpen} onOpenChange={setIsOpen}>
        <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
          <DialogHeader>
            <DialogTitle className="text-[#182A45]">
              Solicitar cambio de empresa y datos fiscales
            </DialogTitle>

            <DialogDescription>
              Los cambios serán enviados a Modira para su revisión antes
              de aplicarse.
            </DialogDescription>
          </DialogHeader>

          {loading ? (
            <div className="flex items-center justify-center py-10">
              <Loader2 className="h-6 w-6 animate-spin text-[#173B8F]" />
            </div>
          ) : (
            <div className="grid gap-5 py-4">
              <div className="flex items-start gap-3 border-b border-[#E8ECF2] pb-4">
                <div className="grid gap-2 sm:col-span-2">
                  <Label htmlFor="company-name">
                    Nombre de empresa <span className="text-red-500">*</span>
                  </Label>

                  <Input
                    id="company-name"
                    value={form.company_name}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        company_name: event.target.value,
                      }))
                    }
                    disabled={saving}
                    placeholder="Ej. Empresa S.L."
                  />
                </div>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="grid gap-2 sm:col-span-2">
                  <Label htmlFor="company-legal-name">
                    Razón social <span className="text-red-500">*</span>
                  </Label>

                  <Input
                    id="company-legal-name"
                    value={form.legal_name}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        legal_name: event.target.value,
                      }))
                    }
                    disabled={saving}
                    placeholder="Ej. Empresa S.L."
                  />
                </div>

                <div className="grid gap-2">
                  <Label htmlFor="company-cif">
                    NIF/CIF <span className="text-red-500">*</span>
                  </Label>

                  <Input
                    id="company-cif"
                    value={form.cif_vat}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        cif_vat: event.target.value.toUpperCase(),
                      }))
                    }
                    disabled={saving}
                    placeholder="Ej. B12345678"
                    maxLength={30}
                  />
                </div>

                <div className="grid gap-2">
                  <Label htmlFor="company-billing-email">
                    Correo de facturación
                  </Label>

                  <Input
                    id="company-billing-email"
                    type="email"
                    value={form.billing_email}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        billing_email: event.target.value,
                      }))
                    }
                    disabled={saving}
                    placeholder="facturacion@empresa.es"
                  />
                </div>

                <div className="grid gap-2 sm:col-span-2">
                  <Label htmlFor="company-address">
                    Dirección fiscal <span className="text-red-500">*</span>
                  </Label>

                  <Input
                    id="company-address"
                    value={form.address}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        address: event.target.value,
                      }))
                    }
                    disabled={saving}
                    placeholder="Calle, número, planta..."
                  />
                </div>

                <div className="grid gap-2">
                  <Label htmlFor="company-postal-code">
                    Código postal <span className="text-red-500">*</span>
                  </Label>

                  <Input
                    id="company-postal-code"
                    value={form.postal_code}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        postal_code: event.target.value,
                      }))
                    }
                    disabled={saving}
                    placeholder="28001"
                    maxLength={20}
                  />
                </div>

                <div className="grid gap-2">
                  <Label htmlFor="company-city">
                    Localidad <span className="text-red-500">*</span>
                  </Label>

                  <Input
                    id="company-city"
                    value={form.city}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        city: event.target.value,
                      }))
                    }
                    disabled={saving}
                    placeholder="Madrid"
                  />
                </div>

                <div className="grid gap-2">
                  <Label htmlFor="company-province">
                    Provincia
                  </Label>

                  <Input
                    id="company-province"
                    value={form.province}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        province: event.target.value,
                      }))
                    }
                    disabled={saving}
                    placeholder="Madrid"
                  />
                </div>

                <div className="grid gap-2">
                  <Label htmlFor="company-country">
                    País <span className="text-red-500">*</span>
                  </Label>

                  <Input
                    id="company-country"
                    value={form.country}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        country: event.target.value.toUpperCase(),
                      }))
                    }
                    disabled={saving}
                    placeholder="ES"
                    maxLength={2}
                  />
                </div>
              </div>

              <div className="border-t border-[#E8ECF2] pt-4">
                <p className="text-[11px] font-semibold text-[#52627A]">
                  Proyectos existentes
                </p>

                <p className="mt-1 text-[10px] leading-4 text-[#8993A2]">
                  Puedes aplicar el cambio también a proyectos Pendientes,
                  Activos o Pausados que todavía no hayan tenido ninguna
                  factura normal.
                </p>

                <label className="mt-3 flex cursor-pointer items-start gap-2.5 text-[11px] text-[#52627A]">
                  <input
                    type="checkbox"
                    checked={form.apply_to_active_projects}
                    onChange={(event) =>
                      setForm((current) => ({
                        ...current,
                        apply_to_active_projects: event.target.checked,
                      }))
                    }
                    disabled={saving}
                    className="mt-0.5 h-3.5 w-3.5 rounded border-[#C7D0DB] text-[#173B8F] focus:ring-[#173B8F]"
                  />
                  <span>
                    Aplicar también el cambio a los proyectos existentes que
                    cumplan estas condiciones.
                  </span>
                </label>

                {!form.apply_to_active_projects && (
                  <p className="mt-2 text-[10px] leading-4 text-[#8993A2]">
                    Los proyectos existentes conservarán su empresa actual.
                    Los nuevos proyectos utilizarán la nueva empresa una vez
                    aprobada la solicitud.
                  </p>
                )}
              </div>

              <div className="grid gap-2">
                <Label htmlFor="company-change-reason">
                  Motivo del cambio
                </Label>

                <Input
                  id="company-change-reason"
                  value={form.reason}
                  onChange={(event) =>
                    setForm((current) => ({
                      ...current,
                      reason: event.target.value,
                    }))
                  }
                  disabled={saving}
                  placeholder="Indica brevemente el motivo del cambio"
                  maxLength={1000}
                />
              </div>

              <div className="border-t border-[#E8ECF2] pt-4">
                <p className="text-[11px] leading-5 text-[#8993A2]">
                  Los datos de empresa y fiscales deben corresponder a la
                  empresa que quedará asociada a tu cuenta. La solicitud
                  quedará registrada y será revisada por Modira antes de
                  modificar los datos oficiales.
                </p>
              </div>
            </div>
          )}

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={saving}
              onClick={() => setIsOpen(false)}
              className={dialogCancelClass}
            >
              Cancelar
            </Button>

            <Button
              type="button"
              disabled={saving || loading || requestPending}
              onClick={handleSave}
              className={dialogPrimaryClass}
            >
              {saving ? (
                <>
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  Enviando...
                </>
              ) : (
                <>
                  <Send className="mr-2 h-4 w-4" />
                  Solicitar cambio
                </>
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      
    </div>
    
  );
};
const CompanyIvaSection = ({
  companyId,
  userId,
}: {
  companyId: string | null;
  userId: string | null;
}) => {
  const [isOpen, setIsOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);

  const [ivaApplied, setIvaApplied] = useState(true);
  const [ivaPercentage, setIvaPercentage] = useState("21");
  const [reason, setReason] = useState("");

  const [effectiveIva, setEffectiveIva] = useState<{
    iva_aplicado: boolean;
    iva_porcentaje: number;
    source: string;
  } | null>(null);

  const [pendingRequest, setPendingRequest] = useState<{
    id: string;
    status: string;
    requested_iva_aplicado: boolean;
    requested_iva_porcentaje: number;
    reason: string;
    created_at: string;
    worker_notes: string | null;
  } | null>(null);

  const loadIvaData = async () => {
    if (!companyId || !userId) return;

    try {
      setLoading(true);

      const [ivaResult, requestResult] = await Promise.all([
        supabase.rpc("get_company_effective_iva", {
          p_company_id: companyId,
        }),

        supabase
          .from("company_iva_change_requests")
          .select(
            "id, status, requested_iva_aplicado, requested_iva_porcentaje, reason, created_at, worker_notes"
          )
          .eq("company_id", companyId)
          .eq("user_id", userId)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle(),
      ]);

      if (ivaResult.error) throw ivaResult.error;

      if (ivaResult.data) {
        const data = Array.isArray(ivaResult.data)
          ? ivaResult.data[0]
          : ivaResult.data;

        if (data) {
          setEffectiveIva({
            iva_aplicado: Boolean(data.iva_aplicado),
            iva_porcentaje: Number(data.iva_porcentaje ?? 21),
            source: data.source || "default",
          });
        }
      }

      if (requestResult.error) {
        console.warn(
          "[ClientArea] Error cargando solicitud de IVA:",
          requestResult.error
        );
        setPendingRequest(null);
      } else {
        setPendingRequest(
          requestResult.data
            ? (requestResult.data as {
                id: string;
                status: string;
                requested_iva_aplicado: boolean;
                requested_iva_porcentaje: number;
                reason: string;
                created_at: string;
                worker_notes: string | null;
              })
            : null
        );
      }
    } catch (err) {
      console.error("[ClientArea] Error cargando configuración de IVA:", err);
      toast.error("No se pudo cargar la información del IVA.");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (!companyId || !userId) return;

    loadIvaData();
  }, [companyId, userId]);

  const handleOpen = async () => {
    if (!companyId || !userId) {
      toast.error("No tienes una empresa asociada a tu cuenta.");
      return;
    }

    await loadIvaData();

    const currentPercentage = effectiveIva?.iva_porcentaje ?? 21;
    const currentApplied = effectiveIva?.iva_aplicado ?? true;

    setIvaApplied(currentApplied);
    setIvaPercentage(String(currentPercentage));
    setReason("");

    setIsOpen(true);
  };

  const handleSave = async () => {
    if (!companyId || !userId) {
      toast.error("No tienes una empresa asociada.");
      return;
    }

    if (pendingRequest?.status === "pending") {
      toast.info(
        "Ya tienes una solicitud de cambio de IVA pendiente de revisión."
      );
      return;
    }

    const percentage = Number(ivaPercentage);

    if (ivaApplied) {
      if (!Number.isFinite(percentage) || percentage < 0 || percentage > 100) {
        toast.error("Introduce un porcentaje de IVA válido entre 0 y 100.");
        return;
      }
    }

    const trimmedReason = reason.trim();

    if (!trimmedReason) {
      toast.error("Indica el motivo de la solicitud.");
      return;
    }

    if (trimmedReason.length > 2000) {
      toast.error("La justificación no puede superar los 2000 caracteres.");
      return;
    }

    try {
      setSaving(true);

      const { error } = await supabase.rpc(
        "request_company_iva_change",
        {
          p_requested_iva_aplicado: ivaApplied,
          p_requested_iva_porcentaje: ivaApplied ? percentage : 0,
          p_reason: trimmedReason,
        }
      );

      if (error) throw error;

      toast.success(
        "Solicitud de cambio de IVA enviada para revisión."
      );

      setIsOpen(false);

      await loadIvaData();
    } catch (err: any) {
      console.error(
        "[ClientArea] Error solicitando cambio de IVA:",
        err
      );

      toast.error(
        `No se pudo enviar la solicitud: ${
          err?.message || "Error desconocido"
        }`
      );
    } finally {
      setSaving(false);
    }
  };

  if (!companyId) {
    return null;
  }

  const requestPending = pendingRequest?.status === "pending";
  const requestApproved = pendingRequest?.status === "approved";
  const requestRejected = pendingRequest?.status === "rejected";

  return (
    <>
      <div className="mt-10 border-t border-[#E8ECF2] pt-8">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div className="max-w-3xl">
            <div className="flex items-center gap-2">
              <Percent
                className="h-4 w-4 text-[#8A95A4]"
                strokeWidth={1.7}
              />

              <p className="text-xs font-semibold text-[#4A586D]">
                Tratamiento de IVA
              </p>
            </div>

            <p className="mt-1.5 text-[11px] leading-5 text-[#8993A2]">
              El IVA general de tu empresa se utiliza como referencia para
              presupuestos y facturas. Si necesitas un tratamiento fiscal
              diferente, puedes solicitarlo para que Modira lo revise.
            </p>

            <div className="mt-4 grid gap-3 sm:grid-cols-2">
              <div className="border-y border-[#E8ECF2] py-3">
                <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                  IVA actualmente aplicado
                </p>

                <p className="mt-1 text-sm font-semibold text-[#445166]">
                  {effectiveIva
                    ? effectiveIva.iva_aplicado
                      ? `${Number(effectiveIva.iva_porcentaje)} %`
                      : "No aplicado"
                    : "21 %"}
                </p>
              </div>

              <div className="border-y border-[#E8ECF2] py-3">
                <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                  Solicitud
                </p>

                <p
                  className={[
                    "mt-1 text-[11px] font-medium",
                    requestPending
                      ? "text-[#9A8050]"
                      : requestApproved
                        ? "text-[#5E9470]"
                        : requestRejected
                          ? "text-[#A05A5A]"
                          : "text-[#667386]",
                  ].join(" ")}
                >
                  {requestPending
                    ? "Pendiente de revisión"
                    : requestApproved
                      ? "Última solicitud aprobada"
                      : requestRejected
                        ? "Última solicitud rechazada"
                        : "Sin solicitud pendiente"}
                </p>
              </div>
            </div>

            {requestPending && (
              <div className="mt-4 flex items-start gap-2.5 border-t border-[#EEF1F5] pt-4">
                <Clock3
                  className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#173B8F]"
                  strokeWidth={1.8}
                />

                <div>
                  <p className="text-[11px] font-medium text-[#173B8F]">
                    Solicitud de cambio de IVA pendiente de revisión
                  </p>

                  <p className="mt-0.5 text-[10px] leading-4 text-[#8993A2]">
                    Tu tratamiento fiscal actual seguirá aplicándose hasta
                    que Modira revise y resuelva la solicitud.
                  </p>
                </div>
              </div>
            )}

            {requestRejected && pendingRequest?.worker_notes && (
              <div className="mt-4 border-t border-[#EEF1F5] pt-4">
                <p className="text-[11px] font-medium text-[#7B8798]">
                  La última solicitud de IVA fue rechazada.
                </p>

                <p className="mt-1 text-[10px] leading-4 text-[#8993A2]">
                  Motivo: {pendingRequest.worker_notes}
                </p>
              </div>
            )}

            {requestApproved && (
              <div className="mt-4 border-t border-[#EEF1F5] pt-4">
                <p className="text-[11px] font-medium text-[#5E9470]">
                  La última solicitud de IVA ha sido aprobada.
                </p>

                <p className="mt-1 text-[10px] leading-4 text-[#8993A2]">
                  El tratamiento aprobado queda disponible como referencia
                  general para la documentación comercial de la empresa.
                </p>
              </div>
            )}
          </div>

          <Button
            type="button"
            variant="outline"
            onClick={handleOpen}
            disabled={loading || requestPending}
            className="h-9 shrink-0 justify-center border-[#D7DEE7] bg-white px-3 text-[11px] font-semibold text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#173B8F] hover:text-white disabled:opacity-50"
          >
            <Percent className="mr-1.5 h-3.5 w-3.5" />

            {requestPending
              ? "Solicitud pendiente"
              : "Solicitar cambio de IVA"}
          </Button>
        </div>
      </div>

      <Dialog open={isOpen} onOpenChange={setIsOpen}>
        <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-lg">
          <DialogHeader>
            <DialogTitle className="text-[#182A45]">
              Solicitar cambio de IVA
            </DialogTitle>

            <DialogDescription>
              Puedes solicitar un tratamiento de IVA diferente para tu
              empresa. La solicitud será revisada por Modira antes de
              aplicarse.
            </DialogDescription>
          </DialogHeader>

          {loading ? (
            <div className="flex items-center justify-center py-10">
              <Loader2 className="h-6 w-6 animate-spin text-[#173B8F]" />
            </div>
          ) : (
            <div className="grid gap-5 py-4">
              <div className="border-b border-[#E8ECF2] pb-4">
                <div className="flex items-start gap-3">
                  <div className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center border border-[#E1E7EE] bg-[#F8FAFC] text-[#173B8F]">
                    <Clock3 className="h-4 w-4" strokeWidth={1.8} />
                  </div>

                  <div>
                    <p className="text-[11px] font-semibold text-[#445166]">
                      ¿Cómo funciona esta solicitud?
                    </p>

                    <p className="mt-1 text-[10px] leading-5 text-[#8993A2]">
                      Indica el tratamiento de IVA que necesitas y explica
                      brevemente el motivo. La solicitud quedará pendiente
                      hasta que un empleado de Modira la revise. Mientras
                      tanto, se mantendrá el tratamiento fiscal actual.
                    </p>

                    <p className="mt-1.5 text-[10px] leading-5 text-[#8993A2]">
                      Si se aprueba, el nuevo tratamiento pasará a ser la
                      referencia general de la empresa. Los contratos y
                      facturas de mantenimiento ya existentes mantienen su
                      configuración histórica.
                    </p>
                  </div>
                </div>
              </div>

              <div className="grid gap-2">
                <Label htmlFor="company-iva-percentage">
                  Porcentaje de IVA
                </Label>

                <div className="flex items-center gap-2">
                  <Input
                    id="company-iva-percentage"
                    type="number"
                    min="0"
                    max="100"
                    step="0.01"
                    value={ivaApplied ? ivaPercentage : "0"}
                    onChange={(event) =>
                      setIvaPercentage(event.target.value)
                    }
                    disabled={saving || !ivaApplied}
                    placeholder="21"
                    className="max-w-[180px]"
                  />

                  <span className="text-xs text-[#8993A2]">
                    %
                  </span>
                </div>
              </div>

              <label className="flex cursor-pointer items-start gap-3 border border-[#E1E7EE] bg-[#FAFBFC] p-3">
                <input
                  type="checkbox"
                  checked={!ivaApplied}
                  onChange={(event) =>
                    setIvaApplied(!event.target.checked)
                  }
                  disabled={saving}
                  className="mt-0.5 h-4 w-4 accent-[#173B8F]"
                />

                <span>
                  <span className="block text-[11px] font-medium text-[#445166]">
                    Solicitar que el IVA no se aplique
                  </span>

                  <span className="mt-0.5 block text-[10px] leading-4 text-[#8993A2]">
                    Marca esta opción únicamente si tu situación fiscal
                    requiere no aplicar IVA.
                  </span>
                </span>
              </label>

              <div className="grid gap-2">
                <div className="flex items-center justify-between gap-3">
                  <Label htmlFor="company-iva-reason">
                    Justificación <span className="text-red-500">*</span>
                  </Label>

                  <span className="text-[10px] text-[#9AA3AF]">
                    {reason.length}/2000
                  </span>
                </div>

                <textarea
                  id="company-iva-reason"
                  value={reason}
                  onChange={(event) =>
                    setReason(event.target.value.slice(0, 2000))
                  }
                  disabled={saving}
                  maxLength={2000}
                  rows={5}
                  placeholder="Explica brevemente el motivo de la solicitud y, si procede, la situación fiscal que la justifica."
                  className="w-full resize-none border border-[#D7DEE7] bg-white px-3 py-2.5 text-xs text-[#445166] outline-none transition-colors placeholder:text-[#A4ACB8] focus:border-[#173B8F]"
                />
              </div>
            </div>
          )}

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setIsOpen(false)}
              disabled={saving}
              className="border-[#D7DEE7] text-[#667386]"
            >
              Cancelar
            </Button>

            <Button
              type="button"
              onClick={handleSave}
              disabled={saving || loading}
              className="bg-[#173B8F] text-white hover:bg-[#102F73]"
            >
              {saving ? (
                <>
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  Enviando...
                </>
              ) : (
                <>
                  <Send className="mr-2 h-4 w-4" />
                  Enviar solicitud
                </>
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
};
export default function ClientArea() {
  const { user, signOut, loading: authLoading } = useAuth();
  const [location, setLocation] = useLocation();

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
  const [tickets, setTickets] = useState<SupportTicket[]>([]);
  const [projectChangeRequests, setProjectChangeRequests] = useState<ProjectChangeRequest[]>([]);
  const [contentSince, setContentSince] = useState<string | null>(null);
  const [isSidebarOpen, setIsSidebarOpen] = useState(false);

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sectionWarnings, setSectionWarnings] = useState<string[]>([]);
const [isAccountDeletionDialogOpen, setIsAccountDeletionDialogOpen] = useState(false);
  const [isEditDialogOpen, setIsEditDialogOpen] = useState(false);
  const [hasPendingCompanyRequest, setHasPendingCompanyRequest] = useState(false);

const [deletionRequestStatus, setDeletionRequestStatus] = useState<string | null>(null);
const [requestingAccountDeletion, setRequestingAccountDeletion] = useState(false);

const [editForm, setEditForm] = useState({ nombre: "", telefono: "" });

  const fetchDashboard = useCallback(async () => {
    if (!user) {
      setLoading(false);
      return;
    }

    try {
      const lastLocalVisit = typeof window !== "undefined"
        ? window.localStorage.getItem(`modira_client_area_last_visit_${user.id}`)
        : null;

      setLoading(true);
      setError(null);
      setSectionWarnings([]);

      // ------------------------------------------------------------
      // PERFIL — único bloque imprescindible para entrar al dashboard.
      // ------------------------------------------------------------
      const { data: profileData, error: profileError } = await supabase
        .from("profiles")
        .select("id, company_id, nombre, empresa, telefono, fecha_registro, fecha_ultimo_login")
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
          .select("id, company_id, nombre, empresa, telefono, fecha_registro, fecha_ultimo_login")
          .single();

        if (createProfileError) throw createProfileError;
        resolvedProfile = createdProfile as UserProfile;
      }

      setProfile(resolvedProfile);
      setEditForm({
        nombre: resolvedProfile.nombre || "",
        telefono: resolvedProfile.telefono || "",
      });

      const lastRelevantConnection = lastLocalVisit || resolvedProfile.fecha_ultimo_login || null;
      setContentSince(lastRelevantConnection);

// ------------------------------------------------------------
// SOLICITUD DE ELIMINACIÓN DE CUENTA
// ------------------------------------------------------------
const { data: deletionRequestData, error: deletionRequestError } =
  await supabase
    .from("account_deletion_requests")
    .select("id, status, requested_at, reviewed_at")
    .eq("user_id", user.id)
    .order("requested_at", { ascending: false })
    .limit(1)
    .maybeSingle();

if (deletionRequestError) {
  console.warn(
    "[ClientArea] Error cargando solicitud de eliminación:",
    deletionRequestError
  );
  setDeletionRequestStatus(null);
} else {
  setDeletionRequestStatus(
    deletionRequestData?.status || null
  );
}

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
        ticketsResult,
        maintenanceResult,
        projectChangeRequestsResult,
        
      ] = await Promise.all([
        supabase
          .from("projects")
          .select(
            "id, user_id, company_id, nombre, descripcion, estado, fecha_inicio, fecha_fin, change_requests_enabled, change_requests_deadline, created_at, updated_at"
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
                "id, project_id, company_id, user_id, numero_factura, fecha_emision, fecha_vencimiento, descripcion, subtotal, iva_aplicado, iva_porcentaje, iva_importe, irpf_aplicado, irpf_porcentaje, irpf_importe, monto, importe_a_pagar, estado, document_path, created_at, updated_at"
              )
              .eq("company_id", resolvedCompany.id)
              .order("created_at", { ascending: false })
          : supabase
              .from("invoices")
              .select(
                "id, project_id, company_id, user_id, numero_factura, fecha_emision, fecha_vencimiento, descripcion, subtotal, iva_aplicado, iva_porcentaje, iva_importe, irpf_aplicado, irpf_porcentaje, irpf_importe, monto, importe_a_pagar, estado, document_path, created_at, updated_at"
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
  .select(`
    id,
    status,
    created_at,
    requested_company_name,
    requested_legal_name,
    requested_cif_vat,
    requested_billing_email,
    requested_address,
    requested_postal_code,
    requested_city,
    requested_province,
    requested_country,
    reason,
    apply_to_active_projects
  `)
  .eq("user_id", user.id)
  .eq("status", "pending")
  .order("created_at", { ascending: false })
  .limit(1)
  .maybeSingle(),
        supabase
          .from("support_tickets")
          .select("id, user_id, company_id, titulo, descripcion, prioridad, estado, created_at, updated_at")
          .eq(resolvedCompany?.id ? "company_id" : "user_id", resolvedCompany?.id || user.id)
          .order("created_at", { ascending: false }),
        supabase
          .from("maintenance_contracts")
          .select("id, user_id, company_id, nombre_plan, descripcion, precio, periodicidad, estado, fecha_inicio, fecha_fin, created_at, updated_at")
          .order("created_at", { ascending: false }),
        supabase
          .from("project_change_requests")
          .select("id, project_id, user_id, description, status, created_at, updated_at")
          .eq("user_id", user.id)
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
        setHasPendingCompanyRequest(Boolean(pendingCompanyResult.data));
      }

      if (maintenanceResult.error) {
        console.error("[ClientArea] Error cargando mantenimiento:", maintenanceResult.error);
        warnings.push("mantenimiento");
        setMaintenanceContracts([]);
      } else {
        setMaintenanceContracts((maintenanceResult.data || []) as MaintenanceContract[]);
      }

      if (ticketsResult.error) {
        console.error("[ClientArea] Error cargando tickets:", ticketsResult.error);
        warnings.push("soporte");
        setTickets([]);
      } else {
        setTickets((ticketsResult.data || []) as SupportTicket[]);
      }

      if (projectChangeRequestsResult.error) {
        console.error("[ClientArea] Error cargando solicitudes de cambio de proyecto:", projectChangeRequestsResult.error);
        warnings.push("solicitudes de cambio");
        setProjectChangeRequests([]);
      } else {
        setProjectChangeRequests((projectChangeRequestsResult.data || []) as ProjectChangeRequest[]);
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
              .limit(30),
            supabase
              .from("project_documents")
              .select(
                "id, project_id, file_name, storage_path, mime_type, file_size, uploaded_by, created_at, updated_at"
              )
              .in("project_id", projectIds)
              .order("created_at", { ascending: false })
              .limit(30),
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
      if (typeof window !== "undefined") {
        window.localStorage.setItem(`modira_client_area_last_visit_${user.id}`, new Date().toISOString());
      }
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

  const activeProjects = useMemo(
    () => projects.filter((project) => normalizeStatus(project.estado) === "Activo"),
    [projects]
  );

  const pausedProjects = useMemo(
    () => projects.filter((project) => normalizeStatus(project.estado) === "Pausado"),
    [projects]
  );

  const operationalProjects = useMemo(
    () => [...activeProjects, ...pausedProjects],
    [activeProjects, pausedProjects]
  );

  const pendingProjects = useMemo(
    () => projects.filter((project) => normalizeStatus(project.estado) === "Pendiente"),
    [projects]
  );

  const projectSummaryDetail = useMemo(() => {
    const parts: string[] = [];

    if (pendingProjects.length > 0) {
      parts.push(`${pendingProjects.length} ${pendingProjects.length === 1 ? "pendiente" : "pendientes"}`);
    }
    if (pausedProjects.length > 0) {
      parts.push(`${pausedProjects.length} ${pausedProjects.length === 1 ? "pausado" : "pausados"}`);
    }
    if (activeProjects.length > 0) {
      parts.push(`${activeProjects.length} ${activeProjects.length === 1 ? "activo" : "activos"}`);
    }

    return parts.length ? parts.join(" · ") : "Sin proyectos";
  }, [pendingProjects, pausedProjects, activeProjects]);

  const completedProjectsWithoutInvoice = useMemo(
    () =>
      projects.filter(
        (project) =>
          normalizeStatus(project.estado) === "Completado" &&
          !invoices.some((invoice) => invoice.project_id === project.id)
      ),
    [projects, invoices]
  );

  const pendingActions = useMemo<PendingAction[]>(() => {
    const actions: PendingAction[] = [];

    tickets
      .filter((ticket) => ["abierto", "en_progreso"].includes((ticket.estado || "").trim().toLowerCase()))
      .forEach((ticket) => {
        actions.push({
          id: `ticket-${ticket.id}`,
          type: "ticket",
          title: ticket.titulo || "Solicitud de soporte",
          description:
            (ticket.estado || "").trim().toLowerCase() === "en_progreso"
              ? "Tu solicitud está siendo atendida por Modira."
              : "Tienes una solicitud de soporte técnico abierta.",
          label: "Ver soporte",
          href: "/area-cliente/soporte",
          createdAt: ticket.updated_at || ticket.created_at,
        });
      });

    projects
      .filter((project) => normalizeStatus(project.estado) === "Pendiente")
      .forEach((project) => {
        actions.push({
          id: `project-pending-${project.id}`,
          type: "project",
          title: project.nombre,
          description: "Tu proyecto está pendiente de inicio.",
          label: "Ver proyecto",
          href: "/area-cliente/proyectos",
          createdAt: project.updated_at || project.created_at,
        });
      });

    completedProjectsWithoutInvoice.forEach((project) => {
      actions.push({
        id: `project-completed-${project.id}`,
        type: "completion",
        title: `${project.nombre} finalizado`,
        description: "El proyecto ha finalizado. La factura se emitirá próximamente.",
        label: "Ver facturación",
        href: "/area-cliente/facturacion",
        createdAt: project.updated_at || project.created_at,
      });
    });

    pendingQuotations.forEach((quotation) => {
      actions.push({
        id: `quotation-${quotation.id}`,
        type: "quotation",
        title: quotation.titulo || (quotation.numero_presupuesto ? `Presupuesto ${quotation.numero_presupuesto}` : "Presupuesto pendiente"),
        description: "Tienes un presupuesto pendiente de respuesta.",
        label: "Revisar",
        href: "/area-cliente/presupuestos",
        createdAt: quotation.created_at || null,
      });
    });

    pendingInvoices.forEach((invoice) => {
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
        createdAt: invoice.created_at,
      });
    });

    projectChangeRequests
      .filter((request) => ["pending", "in_review", "accepted"].includes((request.status || "").trim().toLowerCase()))
      .forEach((request) => {
        const projectName = projectById.get(request.project_id)?.nombre || "tu proyecto";
        const status = (request.status || "").trim().toLowerCase();
        const description =
          status === "in_review"
            ? "Tu solicitud está siendo revisada por Modira."
            : status === "accepted"
              ? "La solicitud ha sido aceptada y está pendiente de completar."
              : "Tu solicitud de cambio está pendiente de revisión.";
        actions.push({
          id: `project-change-${request.id}`,
          type: "project_change",
          title: `Cambio solicitado · ${projectName}`,
          description,
          label: "Ver proyecto",
          href: "/area-cliente/proyectos",
          createdAt: request.updated_at || request.created_at,
        });
      });

    if (hasPendingCompanyRequest) {
      actions.push({
        id: "company-change",
        type: "company",
        title: "Cambio de empresa y datos fiscales pendiente de revisión",
        description: "Modira está revisando tu solicitud de cambio de empresa y datos fiscales.",
        label: "Ver cuenta",
        href: "#perfil",
        createdAt: null,
      });
    }

    if (deletionRequestStatus === "pending" || deletionRequestStatus === "approved") {
      actions.push({
        id: "account-deletion",
        type: "account",
        title: deletionRequestStatus === "approved" ? "Eliminación de cuenta aprobada" : "Eliminación de cuenta pendiente de revisión",
        description: deletionRequestStatus === "approved"
          ? "La solicitud ha sido aprobada y está pendiente de completar las comprobaciones finales."
          : "Tu solicitud de eliminación está siendo revisada por Modira.",
        label: "Ver cuenta",
        href: "#perfil",
        createdAt: null,
      });
    }

    return actions.sort((a, b) => {
      const aTime = a.createdAt ? new Date(a.createdAt).getTime() : 0;
      const bTime = b.createdAt ? new Date(b.createdAt).getTime() : 0;
      return bTime - aTime;
    });
  }, [
    tickets,
    projects,
    completedProjectsWithoutInvoice,
    pendingQuotations,
    pendingInvoices,
    projectChangeRequests,
    hasPendingCompanyRequest,
    deletionRequestStatus,
    projectById,
  ]);

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
    () =>
      updates.filter(
        (update) =>
          dashboardProjectIds.has(update.project_id) &&
          (!contentSince || new Date(update.created_at).getTime() > new Date(contentSince).getTime())
      ),
    [updates, dashboardProjectIds, contentSince]
  );

  type RecentDocument =
    | (ProjectDocument & { source: "project"; reference: string })
    | {
        id: string;
        file_name: string;
        storage_path: string;
        source: "invoice" | "quotation";
        reference: string;
        created_at: string;
      };

  const recentDocuments = useMemo<RecentDocument[]>(() => {
    const projectDocs: RecentDocument[] = documents
      .filter((document) => projectById.has(document.project_id))
      .map((document) => ({
        ...document,
        source: "project",
        reference: `Proyecto · ${projectById.get(document.project_id)?.nombre || "Proyecto"}`,
      }));

    const invoiceDocs: RecentDocument[] = invoices
      .filter((invoice) => Boolean((invoice as Invoice & { document_path?: string | null }).document_path))
      .map((invoice) => ({
        id: `invoice-${invoice.id}`,
        file_name: `${invoice.numero_factura}.pdf`,
        storage_path: (invoice as Invoice & { document_path: string }).document_path,
        source: "invoice",
        reference: `Factura · ${invoice.numero_factura}`,
        created_at: invoice.updated_at || invoice.created_at,
      }));

    const quotationDocs: RecentDocument[] = quotations
      .filter((quotation) => Boolean(quotation.document_path))
      .map((quotation) => ({
        id: `quotation-${quotation.id}`,
        file_name: `${quotation.numero_presupuesto || quotation.titulo || "Presupuesto"}.pdf`,
        storage_path: quotation.document_path as string,
        source: "quotation",
        reference: `Presupuesto · ${quotation.titulo || quotation.numero_presupuesto || "Presupuesto"}`,
        created_at: quotation.updated_at || quotation.created_at || new Date(0).toISOString(),
      }));

    return [...projectDocs, ...invoiceDocs, ...quotationDocs]
      .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
      .slice(0, 3);
  }, [documents, invoices, quotations, dashboardProjectIds, projectById]);

 

  const greeting = useMemo(() => {
    const hour = new Date().getHours();
    if (hour < 12) return "Buenos días";
    if (hour < 19) return "Buenas tardes";
    return "Buenas noches";
  }, []);



  const handleOpenDocument = async (document: { storage_path: string; source: "project" | "invoice" | "quotation" }) => {
    try {
      const bucket =
        document.source === "project"
          ? "project-documents"
          : document.source === "invoice"
            ? "invoices"
            : "quotations";
      const { data, error: signedUrlError } = await supabase.storage
        .from(bucket)
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

  
const handleRequestAccountDeletion = async () => {
  if (!user) return;

  if (deletionRequestStatus === "pending") {
    toast.info("Ya tienes una solicitud de eliminación pendiente de revisión.");
    return;
  }

  if (deletionRequestStatus === "approved") {
    toast.info("Tu solicitud de eliminación ya ha sido aprobada y está en proceso.");
    return;
  }

  try {
    setRequestingAccountDeletion(true);

    const { error: requestError } = await supabase.rpc(
      "request_account_deletion"
    );

    if (requestError) throw requestError;

    setDeletionRequestStatus("pending");
    setIsAccountDeletionDialogOpen(false);


    toast.success(
      "Solicitud de eliminación enviada correctamente."
    );
  } catch (err: any) {
    console.error(
      "[ClientArea] Error solicitando eliminación de cuenta:",
      err
    );

    toast.error(
      `No se pudo enviar la solicitud: ${
        err?.message || "Error desconocido"
      }`
    );
  } finally {
    setRequestingAccountDeletion(false);
  }
};
  const handleLogout = async () => {
    const result = await signOut();
    if (result.success) setLocation("/");
  };

  if (authLoading || loading) {
    return (
      <div className="min-h-screen bg-[#FBFCFE]">
        <ClientAreaSidebar
          isOpen={isSidebarOpen}
          onToggle={() => setIsSidebarOpen((current) => !current)}
          location={location}
          onNavigate={(path) => {
            if (path.startsWith("#")) {
              if (location === "/area-cliente") {
                document.querySelector(path)?.scrollIntoView({ behavior: "smooth" });
              } else {
                setLocation(`/area-cliente${path}`);
                window.setTimeout(() => {
                  document.querySelector(path)?.scrollIntoView({ behavior: "smooth" });
                }, 150);
              }
            } else {
              setLocation(path);
            }
            setIsSidebarOpen(false);
          }}
          onLogout={handleLogout}
        />
        <div className="flex min-h-screen items-center justify-center pl-[62px] px-6 lg:pl-[62px]">
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
      <ClientAreaSidebar
        isOpen={isSidebarOpen}
        onToggle={() => setIsSidebarOpen((current) => !current)}
        location={location}
        onNavigate={(path) => {
          if (path.startsWith("#")) {
            if (location === "/area-cliente") {
              document.querySelector(path)?.scrollIntoView({ behavior: "smooth" });
            } else {
              setLocation(`/area-cliente${path}`);
              window.setTimeout(() => {
                document.querySelector(path)?.scrollIntoView({ behavior: "smooth" });
              }, 150);
            }
          } else {
            setLocation(path);
          }
          setIsSidebarOpen(false);
        }}
        onLogout={handleLogout}
      />

      <div
        className={[
          "min-h-screen transition-[margin] duration-200 ease-out",
          isSidebarOpen ? "ml-[62px] lg:ml-[236px]" : "ml-[62px]",
        ].join(" ")}
      >

      {/* Accesos flotantes: deliberadamente pequeños y sin texto. */}
      <ClientFloatingActions />

<main className="mx-auto max-w-[1380px] px-5 pb-20 pt-10 sm:px-8 lg:px-12">
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
          <div className="mb-10">
            

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
  <MilestoneTimeline
    milestones={projectMilestones}
    projectStatus={projectStatus}
  />
</div>

                        <div className="border-l-0 border-[#E7EBF0] pt-1 lg:border-l lg:pl-6">
  {projectStatus === "Pausado" ? (
    <>
      <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-amber-700">
        Estado
      </p>

      <p className="mt-2 text-sm font-semibold text-[#2D3B50]">
        Proyecto pausado
      </p>

      <p className="mt-1 text-xs leading-5 text-[#7D8898]">
        El progreso se conserva hasta que el proyecto vuelva a estar activo.
      </p>
    </>
  ) : projectStatus === "Completado" ? (
    <>
      <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-emerald-700">
        Estado
      </p>

      <p className="mt-2 text-sm font-semibold text-[#2D3B50]">
        Proyecto completado
      </p>

      <p className="mt-1 text-xs leading-5 text-[#7D8898]">
        Todos los hitos del proyecto están completados.
      </p>
    </>
  ) : (
    <>
      <div className="flex items-center gap-2">
        <CalendarDays
          className="h-4 w-4 text-[#7E8998]"
          strokeWidth={1.7}
        />

        <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#8993A2]">
          Próximo hito
        </p>
      </div>

      {nextMilestone ? (
        <>
          <p className="mt-2 text-sm font-semibold text-[#2D3B50]">
            {nextMilestone.nombre}
          </p>

          <p className="mt-1 text-xs text-[#7D8898]">
            {formatDate(nextMilestone.fecha_prevista)}
          </p>
        </>
      ) : projectMilestones.length ? (
        <p className="mt-2 text-xs leading-5 text-[#7D8898]">
          Todos los hitos definidos están completados.
        </p>
      ) : (
        <p className="mt-2 text-xs leading-5 text-[#7D8898]">
          Aún no hay un próximo hito definido.
        </p>
      )}
    </>
  )}

  {/* ----------------------------------------------------------
    HITOS COMPLETADOS
    ---------------------------------------------------------- */}

{projectStatus !== "Completado" && (
  <div className="mt-5 flex items-center gap-2">
    <p className="text-xs font-medium text-[#667386]">
      {completed} de {total} hitos completados
    </p>
  </div>
)}

</div>
                      </div>
                    </div>
                  </article>
                );
              })}
            </div>
          </div>
        )}

        {/* ------------------------------------------------------------
            RESUMEN — cuatro indicadores ligeros.
        ------------------------------------------------------------ */}
        <section className="mb-10 grid grid-cols-2 divide-x divide-y divide-[#E5E9EF] border-y border-[#E5E9EF] bg-white/40 lg:grid-cols-4 lg:divide-y-0">
          {[
            {
              label: "Proyectos en curso",
              value: operationalProjects.length,
              detail: projectSummaryDetail,
              icon: BriefcaseBusiness,
              href: "/area-cliente/proyectos",
              active: operationalProjects.length > 0,
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
                  item.active
                    ? "bg-[#173B8F] text-white hover:bg-[#102A66]"
                    : "bg-white/50 text-[#1E2D43] hover:bg-white",
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
                  <p className="mt-0.5 text-xs text-[#8993A2]">Todo está al día. Aquí aparecerán los asuntos que requieran seguimiento hasta que queden resueltos.</p>
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
                      action.type === 'ticket' ? 'bg-[#F2F5FB] text-[#173B8F]' :
                        action.type === 'project' ? 'bg-[#F5F5F2] text-[#6E705E]' :
                          action.type === 'quotation' ? 'bg-[#F5F2FA] text-[#6B5A8E]' :
                            action.type === 'invoice' ? 'bg-[#FBF2F2] text-[#9E5555]' :
                              action.type === 'project_change' ? 'bg-[#FBF7ED] text-[#9A7130]' :
                                action.type === 'company' ? 'bg-[#F3F6FC] text-[#173B8F]' :
                                  action.type === 'account' ? 'bg-[#FBF2F2] text-[#9E5555]' :
                                    'bg-[#F1F7F2] text-[#5E9470]',
                    ].join(' ')}
                  >
                    {action.type === 'ticket' ? <Wrench className="h-4 w-4" strokeWidth={1.7} /> :
                      action.type === 'project' ? <BriefcaseBusiness className="h-4 w-4" strokeWidth={1.7} /> :
                        action.type === 'quotation' ? <FileText className="h-4 w-4" strokeWidth={1.7} /> :
                          action.type === 'invoice' ? <Receipt className="h-4 w-4" strokeWidth={1.7} /> :
                            action.type === 'project_change' ? <ClipboardList className="h-4 w-4" strokeWidth={1.7} /> :
                              action.type === 'company' ? <Building2 className="h-4 w-4" strokeWidth={1.7} /> :
                                action.type === 'account' ? <Trash2 className="h-4 w-4" strokeWidth={1.7} /> :
                                  <Check className="h-4 w-4" strokeWidth={1.8} />}
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium text-[#2F3D52]">{action.title}</p>
                    <p className="mt-0.5 text-xs leading-5 text-[#8792A3]">{action.description}</p>
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
        <section className="mb-14 grid gap-10 xl:grid-cols-[minmax(0,2fr)_minmax(300px,1fr)] xl:divide-x xl:divide-[#E2E7ED]">
          <div className="min-w-0 xl:pr-10">
            <SectionTitle eyebrow="Actualidad" title="Últimas novedades" />
            {visibleUpdates.length === 0 ? (
              <div className="border-y border-[#E7EBF0] py-7">
                <p className="text-sm font-medium text-[#445166]">No hay novedades nuevas desde tu última conexión.</p>
                <p className="mt-1 text-xs text-[#8993A2]">Cuando Modira publique una actualización, aparecerá aquí.</p>
              </div>
            ) : (
              <div className="relative max-h-[360px] overflow-y-auto border-y border-[#E7EBF0] py-2 pr-2">
                <div className="absolute bottom-5 left-[7px] top-5 w-px bg-[#E0E5EB]" />
                <div className="divide-y divide-[#EEF1F5]">
                  {visibleUpdates.map((update) => (
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

          <div className="min-w-0 xl:pl-10">
            <SectionTitle
              eyebrow="Archivos"
              title="Documentos recientes"
              action={<FileText className="h-4 w-4 text-[#8A95A4]" strokeWidth={1.7} />}
            />
            {recentDocuments.length === 0 ? (
              <div className="border-y border-[#E7EBF0] py-7">
                <p className="text-xs text-[#8993A2]">No hay documentos disponibles todavía.</p>
              </div>
            ) : (
              <div className="border-y border-[#E7EBF0]">
                <div className="divide-y divide-[#EEF1F5]">
                  {recentDocuments.map((document) => (
                    <button
                      key={document.id}
                      type="button"
                      onClick={() => handleOpenDocument(document)}
                      className="group flex w-full items-center gap-3 py-3 text-left transition hover:bg-white"
                    >
                      <FileText className="h-4 w-4 shrink-0 text-[#8A95A4] group-hover:text-[#173B8F]" strokeWidth={1.7} />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-xs font-medium text-[#445166]">{document.file_name}</span>
                        <span className="mt-1 flex flex-wrap items-center gap-2">
                          <span className="text-[10px] text-[#9AA4B2]">{formatCompactDate(document.created_at)}</span>
                          <span className="text-[10px] text-[#D0D5DD]">·</span>
                          <span className="text-[10px] font-medium text-[#173B8F]">{document.reference}</span>
                        </span>
                      </span>
                      <ExternalLink className="h-3.5 w-3.5 shrink-0 text-[#A4ADB9]" strokeWidth={1.6} />
                    </button>
                  ))}
                </div>
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
        <section id="perfil" className="mt-16 mb-10 scroll-mt-8">
          <SectionTitle
            eyebrow="Cuenta"
            title="Mi cuenta"
          />

  {/* ------------------------------------------------------------
      DATOS PERSONALES + DATOS FISCALES
      50% / 50% en escritorio · apilado en móvil
  ------------------------------------------------------------ */}
  <div className="grid gap-0 border-y border-[#E7EBF0] lg:grid-cols-2">

    {/* ----------------------------------------------------------
        IZQUIERDA — DATOS PERSONALES
    ---------------------------------------------------------- */}
    <div className="min-w-0 py-6 lg:pr-8">
  <div className="flex items-start justify-between gap-4">
    <div className="min-w-0">
      <p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-[#8792A3]">
        Perfil
      </p>

      <h3 className="mt-1 text-sm font-semibold text-[#344156]">
        Datos personales
      </h3>

      <p className="mt-1 text-xs leading-5 text-[#8993A2]">
        Información asociada a tu cuenta de acceso a Modira.
      </p>
    </div>

    <Dialog
      open={isEditDialogOpen}
      onOpenChange={setIsEditDialogOpen}
    >
      <DialogTrigger asChild>
        <Button
          type="button"
          variant="outline"
          className="h-9 min-w-[120px] shrink-0 justify-center border-[#D7DEE7] bg-white px-3 text-[11px] font-semibold text-[#667386] transition-colors hover:border-[#173B8F] hover:bg-[#173B8F] hover:text-white"
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
            <Label htmlFor="client-name">
              Nombre
            </Label>

            <Input
              id="client-name"
              value={editForm.nombre}
              onChange={(event) =>
                setEditForm({
                  ...editForm,
                  nombre: event.target.value,
                })
              }
            />
          </div>

          <div className="grid gap-2">
            <Label htmlFor="client-phone">
              Teléfono
            </Label>

            <Input
              id="client-phone"
              value={editForm.telefono}
              onChange={(event) =>
                setEditForm({
                  ...editForm,
                  telefono: event.target.value,
                })
              }
            />
          </div>

          <div className="border-t border-[#E8ECF2] pt-4">
            <p className="text-xs font-semibold text-[#52627A]">
              Empresa
            </p>

            <p className="mt-1 text-sm font-medium text-[#26344A]">
              {company?.company_name || "Sin definir"}
            </p>

            <p className="mt-1 text-xs text-[#8792A3]">
              La empresa asociada se gestiona mediante el flujo seguro
              de Modira.
            </p>
          </div>
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            className={dialogCancelClass}
            onClick={() => setIsEditDialogOpen(false)}
          >
            Cancelar
          </Button>

          <Button
            type="button"
            className={dialogPrimaryClass}
            onClick={handleUpdateProfile}
          >
            Guardar cambios
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>

      {profile && (
        <div className="mt-5 space-y-5">
          <div>
            <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
              Nombre
            </p>

            <p className="mt-1 text-xs font-medium text-[#445166]">
              {profile.nombre}
            </p>
          </div>

          <div>
            <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
              Correo
            </p>

            <p className="mt-1 truncate text-xs font-medium text-[#445166]">
              {user.email}
            </p>
          </div>

          <div>
            <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
              Empresa asociada
            </p>

            <p className="mt-1 text-xs font-medium text-[#445166]">
              {company?.company_name || "Sin definir"}
            </p>
          </div>

          <div>
            <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
              Registro
            </p>

            <p className="mt-1 text-xs font-medium text-[#445166]">
              {formatCompactDate(profile.fecha_registro)}
            </p>
          </div>

          {profile.telefono && (
            <div>
              <p className="text-[10px] font-semibold uppercase tracking-[0.13em] text-[#9AA3AF]">
                Teléfono
              </p>

              <p className="mt-1 text-xs font-medium text-[#445166]">
                {profile.telefono}
              </p>
            </div>
          )}
        </div>
      )}
    </div>

    {/* ----------------------------------------------------------
        DERECHA — DATOS FISCALES
    ---------------------------------------------------------- */}
       <CompanySection
      companyId={profile?.company_id || null}
      companyName={company?.company_name || null}
      userId={user?.id || null}
      onSaved={fetchDashboard}
    />
  </div>

  {/* ------------------------------------------------------------
      IVA GENERAL DE LA EMPRESA
  ------------------------------------------------------------ */}
  <CompanyIvaSection
    companyId={profile?.company_id || null}
    userId={user?.id || null}
  />


          {/* ------------------------------------------------------------
    ELIMINACIÓN DE CUENTA
------------------------------------------------------------ */}
<div className="mt-10 border-t border-[#E8ECF2] pt-8">
  <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
    <div className="max-w-3xl">
      <div className="flex items-center gap-2">
        <Trash2
          className="h-4 w-4 text-[#8A95A4]"
          strokeWidth={1.7}
        />
        <p className="text-xs font-semibold text-[#4A586D]">
          Eliminar cuenta
        </p>
      </div>

      <p className="mt-1.5 text-[11px] leading-5 text-[#8993A2]">
        Puedes solicitar la eliminación de tu cuenta de Modira.
        La solicitud será revisada antes de ejecutarse.
      </p>

      <p className="mt-2 text-[11px] leading-5 text-[#8993A2]">
        La cuenta podrá eliminarse cuando no existan proyectos
        activos, pausados o completados, ni facturas pendientes
        o vencidas. Los proyectos pendientes o entregados y las
        facturas pagadas o canceladas no impiden la eliminación.
      </p>

      {deletionRequestStatus === "pending" && (
        <p className="mt-2 text-[11px] font-medium text-[#173B8F]">
          Tu solicitud está pendiente de revisión por Modira.
        </p>
      )}

      {deletionRequestStatus === "approved" && (
        <p className="mt-2 text-[11px] font-medium text-[#173B8F]">
          Tu solicitud ha sido aprobada y está pendiente de
          completar las comprobaciones finales.
        </p>
      )}

      {deletionRequestStatus === "blocked" && (
        <p className="mt-2 text-[11px] font-medium text-[#9A6C45]">
          La eliminación está bloqueada porque actualmente no se
          cumplen las condiciones necesarias.
        </p>
      )}

      {deletionRequestStatus === "rejected" && (
        <p className="mt-2 text-[11px] font-medium text-[#7B8798]">
          Tu solicitud anterior fue rechazada. Puedes volver a
          solicitar la eliminación si lo necesitas.
        </p>
      )}

      {deletionRequestStatus === "failed" && (
        <p className="mt-2 text-[11px] font-medium text-[#9A6C45]">
          Se produjo un problema técnico al procesar la solicitud.
          Puedes volver a solicitar la eliminación.
        </p>
      )}

      {deletionRequestStatus === "completed" && (
        <p className="mt-2 text-[11px] font-medium text-[#5E9470]">
          La eliminación de la cuenta se ha completado.
        </p>
      )}
    </div>

    <Dialog
  open={isAccountDeletionDialogOpen}
  onOpenChange={setIsAccountDeletionDialogOpen}
>
      <DialogTrigger asChild>
        <Button
          type="button"
          variant="outline"
          disabled={
            requestingAccountDeletion ||
            deletionRequestStatus === "pending" ||
            deletionRequestStatus === "approved" ||
            deletionRequestStatus === "completed"
          }
          className="h-9 min-w-[138px] shrink-0 justify-center border-[#D7DEE7] bg-white px-3 text-[11px] font-semibold text-[#667386] transition-colors hover:bg-[#9E5555] hover:border-[#9E5555] hover:text-white disabled:opacity-50"
        >
          <Trash2 className="mr-1.5 h-3.5 w-3.5" />

          {deletionRequestStatus === "pending"
            ? "Solicitud pendiente"
            : deletionRequestStatus === "approved"
              ? "Solicitud aprobada"
              : deletionRequestStatus === "completed"
                ? "Cuenta eliminada"
                : "Solicitar eliminación"}
        </Button>
      </DialogTrigger>

      <DialogContent>
        <DialogHeader>
          <DialogTitle>Solicitar eliminación de cuenta</DialogTitle>

          <DialogDescription>
            Esta acción inicia una solicitud que será revisada por
            Modira antes de eliminar tu cuenta.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-4">
          <div className="border-y border-[#E8ECF2] py-4">
            <p className="text-xs font-semibold text-[#52627A]">
              Antes de eliminar la cuenta
            </p>

            <p className="mt-2 text-xs leading-5 text-[#7C8797]">
              La eliminación solo podrá completarse si no existen
              proyectos en estado Activo, Pausado o Completado, ni
              facturas en estado pendiente o vencida.
            </p>

            <p className="mt-2 text-xs leading-5 text-[#7C8797]">
              Los proyectos Pendientes o Entregados y las facturas
              pagadas o canceladas no bloquean la eliminación.
            </p>
          </div>

          <div className="flex gap-3 border-b border-[#E8ECF2] pb-4">
            <AlertTriangle
              className="mt-0.5 h-4 w-4 shrink-0 text-[#9A6C45]"
              strokeWidth={1.7}
            />

            <p className="text-xs leading-5 text-[#7C8797]">
              Al completar la eliminación, perderás el acceso a tu
              cuenta y a la información asociada a ella.
            </p>
          </div>
        </div>

        <DialogFooter>
          <Button
  type="button"
  variant="outline"
  disabled={requestingAccountDeletion}
  onClick={() => setIsAccountDeletionDialogOpen(false)}
  className={dialogCancelClass}
>
  Cancelar
</Button>

          <Button
  type="button"
  disabled={requestingAccountDeletion}
  className={dialogDangerClass}
  onClick={handleRequestAccountDeletion}
>
  {requestingAccountDeletion ? (
    <>
      <Loader2 className="mr-2 h-4 w-4 animate-spin" />
      Enviando...
    </>
  ) : (
    <>
      <Trash2 className="mr-2 h-4 w-4" />
      Enviar solicitud
    </>
  )}
</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  </div>
</div>
        </section>

        <section id="ayuda" className="mt-12 mb-10 border-y border-[#E3E8EE] py-8">
          <div className="flex flex-col gap-5 sm:flex-row sm:items-center sm:justify-between">
            <div className="max-w-2xl">
              <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-[#7C8797]">
                Ayuda
              </p>
              <h2 className="text-xl font-semibold tracking-tight text-[#182A45]">
                ¿Necesitas ayuda con algo?
              </h2>
              <p className="mt-2 text-sm leading-6 text-[#718096]">
                Si tienes cualquier problema o necesitas ayuda antes de continuar, puedes contactar directamente con Modira.
              </p>
            </div>
            <a
              href={`mailto:info@modira.es?subject=${encodeURIComponent("Necesito ayuda con mi área de cliente")}&body=${encodeURIComponent(`Hola Modira,\n\nNecesito ayuda con mi área de cliente.\n\nMi correo de acceso es: ${user.email || ""}\n\nGracias.`)}`}
              className="inline-flex h-9 shrink-0 items-center justify-center gap-2 rounded-md border border-[#173B8F] bg-[#173B8F] px-4 text-[11px] font-semibold text-white transition-colors hover:border-[#102A66] hover:bg-[#102A66]"
            >
              <CircleHelp className="h-3.5 w-3.5" strokeWidth={1.8} />
              Contactar con Modira
            </a>
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
    </div>
  );
}
